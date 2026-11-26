import Darwin
import Foundation
import Synchronization

struct DirFlags: OptionSet, Sendable {
	let rawValue: UInt8
	static let denied = DirFlags(rawValue: 1)
	static let elsewhere = DirFlags(rawValue: 2)
	static let dataless = DirFlags(rawValue: 4)
	static let partial = DirFlags(rawValue: 8)
	static let hidden = DirFlags(rawValue: 16)
	static let view = DirFlags(rawValue: 32)
	static let gone = DirFlags(rawValue: 64)
}

struct BigFile: Sendable {
	var dir: Int32
	var name: String
	var counted: UInt64
	var size: UInt64
	var mtime: Int64
	var purgeable: Bool
}

final class Carriers: @unchecked Sendable {
	private final class Shard {
		var lock = os_unfair_lock()
		var map: [UInt64: String] = [:]
	}
	private let shards: [Shard] = (0..<64).map { _ in Shard() }

	private func shard(_ key: UInt64) -> Shard { shards[Int((key &* 0x9E37_79B9_7F4A_7C15) >> 58)] }

	func claim(_ key: UInt64, _ candidate: String, alive: ((String) -> Bool)? = nil) -> Bool {
		let s = shard(key)
		os_unfair_lock_lock(&s.lock)
		guard let owner = s.map[key] else {
			s.map[key] = candidate
			os_unfair_lock_unlock(&s.lock)
			return true
		}
		os_unfair_lock_unlock(&s.lock)
		if owner == candidate { return true }
		guard let alive, !alive(owner) else { return false }
		os_unfair_lock_lock(&s.lock); defer { os_unfair_lock_unlock(&s.lock) }
		if s.map[key] == owner { s.map[key] = candidate }
		return s.map[key] == candidate
	}

	func owner(_ key: UInt64) -> String? {
		let s = shard(key)
		os_unfair_lock_lock(&s.lock); defer { os_unfair_lock_unlock(&s.lock) }
		return s.map[key]
	}

	var all: [(UInt64, String)] {
		shards.flatMap { s in
			os_unfair_lock_lock(&s.lock); defer { os_unfair_lock_unlock(&s.lock) }
			return s.map.map { ($0.key, $0.value) }
		}
	}

	func load(_ pairs: [(UInt64, String)], keep: Bool = false) {
		for (k, v) in pairs {
			let s = shard(k)
			os_unfair_lock_lock(&s.lock)
			if !keep || s.map[k] == nil { s.map[k] = v }
			os_unfair_lock_unlock(&s.lock)
		}
	}
}

final class VolumeScan: @unchecked Sendable {
	let root: String
	let dev: dev_t
	let views: Set<String>
	static let bigFile: UInt64 = 1 << 20

	var names: [String] = []
	var parents: [Int32] = []
	var flags: [DirFlags] = []
	var mtimes: [Int64] = []
	var own: [UInt64] = []
	var ownLogical: [UInt64] = []
	var ownFiles: [UInt32] = []
	var ownPurgeable: [UInt64] = []
	var marks: [UInt16] = []
	var extraHard: [UInt64] = []
	var extraClone: [UInt64] = []
	var partialShared: [UInt64] = []
	var cloudOnly: [UInt64] = []
	var big: [BigFile] = []

	private(set) var total: [UInt64] = []
	private(set) var totalFiles: [UInt64] = []
	private(set) var totalPurgeable: [UInt64] = []
	private(set) var childStart: [Int32] = []
	private(set) var childList: [Int32] = []

	struct Counters {
		var hardLink: UInt64 = 0
		var cloneShared: UInt64 = 0
		var partialClone: UInt64 = 0
		var dataless: UInt64 = 0
		var files: UInt64 = 0
	}
	private(set) var counters = Counters()
	private(set) var seconds: Double = 0

	let hardLinks: Carriers
	let clones: Carriers

	private(set) var generation = VolumeScan.nextGeneration()
	private static let generations = Atomic<Int>(0)
	private static func nextGeneration() -> Int { generations.wrappingAdd(1, ordering: .relaxed).newValue }

	let progressFiles = Atomic<Int>(0)
	let progressFolders = Atomic<Int>(0)
	let progressBytes = Atomic<Int>(0)

	init(root: String, views: Set<String> = []) throws {
		self.root = root
		self.views = views
		hardLinks = Carriers(); clones = Carriers()
		let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard fd >= 0 else { throw BulkError.open(errno) }
		defer { close(fd) }
		guard let d = realDevice(fd) else { throw BulkError.open(errno) }
		dev = d
	}

	init(root: String, dev: dev_t, views: Set<String>, hardLinks: Carriers = Carriers(), clones: Carriers = Carriers()) {
		self.root = root
		self.dev = dev
		self.views = views
		self.hardLinks = hardLinks
		self.clones = clones
	}

	func copy() -> VolumeScan {
		let c = VolumeScan(root: root, dev: dev, views: views, hardLinks: hardLinks, clones: clones)
		c.names = names; c.parents = parents; c.flags = flags; c.mtimes = mtimes
		c.own = own; c.ownLogical = ownLogical; c.ownFiles = ownFiles; c.ownPurgeable = ownPurgeable; c.marks = marks
		c.extraHard = extraHard; c.extraClone = extraClone; c.partialShared = partialShared; c.cloudOnly = cloudOnly
		c.big = big
		c.total = total; c.totalFiles = totalFiles; c.totalPurgeable = totalPurgeable
		c.childStart = childStart; c.childList = childList
		c.counters = counters; c.seconds = seconds
		c.generation = generation
		return c
	}

	private struct Job {
		var index: Int32
		var path: String
		var inView: Bool
		var refresh = false
	}
	private let cond = NSCondition()
	private var jobs: [Job] = []
	private var active = 0
	static let defaultThreads = max(8, ProcessInfo.processInfo.activeProcessorCount * 2)

	func run(threads: Int = VolumeScan.defaultThreads) {
		let start = Date()
		append(name: (root as NSString).lastPathComponent, parent: -1, flags: [], mtime: 0)
		deferShared = true
		walk([Job(index: 0, path: root, inView: false)], threads: threads)
		deferShared = false
		settleShared()
		finish()
		seconds = Date().timeIntervalSince(start)
	}

	func rescan(_ changed: [Int], deep: Set<Int> = []) {
		let start = Date()
		keptClosed = []
		for i in deep where !flags[i].contains(.gone) && !isUnderGone(i) { markSubtreeGone(below: i) }
		var seeds: [Job] = []
		for i in Set(changed).union(deep) where !flags[i].contains(.gone) && !isUnderGone(i) {
			seeds.append(Job(index: Int32(i), path: path(i), inView: isInView(i), refresh: true))
		}
		let reread = Set(seeds.map(\.index))
		let before = big.filter { reread.contains($0.dir) }
		big.removeAll { reread.contains($0.dir) }
		walk(seeds, threads: VolumeScan.defaultThreads)
		if !keptClosed.isEmpty {
			let kept = Set(keptClosed)
			big += before.filter { kept.contains($0.dir) }
		}
		finish()
		seconds = Date().timeIntervalSince(start)
	}

	private func walk(_ seeds: [Job], threads: Int) {
		jobs = seeds
		active = 0
		var results = Array(repeating: ([BigFile](), [Shared]()), count: threads)
		DispatchQueue.concurrentPerform(iterations: threads) { t in
			let reader = BulkReader()
			var local: [BigFile] = []
			var shared: [Shared] = []
			while let job = next() { process(job, reader: reader, big: &local, shared: &shared) }
			cond.lock(); results[t] = (local, shared); cond.unlock()
		}
		for (b, sh) in results { big += b; pending += sh }
	}

	private struct Shared {
		var hard: Bool
		var key: UInt64
		var dir: Int32
		var name: String
		var bytes: UInt64
		var purgeable: Bool
		var allShared: Bool
	}
	private var deferShared = false
	private var pending: [Shared] = []
	private(set) var keptClosed: [Int32] = []

	private func settleShared() {
		var pathOf: [Int32: String] = [:]
		func path(_ s: Shared) -> String {
			let p = pathOf[s.dir] ?? relativePath(Int(s.dir))
			pathOf[s.dir] = p
			return p.isEmpty ? s.name : p + "/" + s.name
		}
		var bigAt: [String: Int] = [:]
		for (k, b) in big.enumerated() { bigAt["\(b.dir)/\(b.name)"] = k }

		var groups: [UInt64: [Shared]] = [:]
		for s in pending { groups[s.key &* 2 &+ (s.hard ? 1 : 0), default: []].append(s) }
		for (_, group) in groups {
			let carrier = group.min { path($0) < path($1) }!
			let i = Int(carrier.dir)
			own[i] += carrier.bytes
			if carrier.purgeable { ownPurgeable[i] += carrier.bytes }
			if let k = bigAt["\(carrier.dir)/\(carrier.name)"] { big[k].counted += carrier.bytes }
			let me = path(carrier)
			(carrier.hard ? hardLinks : clones).load([(carrier.key, me)])
			var others = group
			others.removeAll { $0.dir == carrier.dir && $0.name == carrier.name }
			for o in others {
				if o.hard { extraHard[Int(o.dir)] += o.bytes } else { extraClone[Int(o.dir)] += o.bytes }
			}
			if !carrier.hard && group.count == 1 && !carrier.allShared { partialShared[i] += carrier.bytes }
		}
		pending = []
	}

	private func next() -> Job? {
		cond.lock(); defer { cond.unlock() }
		while jobs.isEmpty {
			if active == 0 { return nil }
			cond.wait()
		}
		active += 1
		return jobs.removeLast()
	}

	private func append(name: String, parent: Int32, flags f: DirFlags, mtime: Int64) {
		names.append(name); parents.append(parent); flags.append(f); mtimes.append(mtime)
		own.append(0); ownLogical.append(0); ownFiles.append(0); ownPurgeable.append(0); marks.append(0)
		extraHard.append(0); extraClone.append(0); partialShared.append(0); cloudOnly.append(0)
	}

	private struct Child { var name: String; var flags: DirFlags; var mtime: Int64 }

	private func process(_ job: Job, reader: BulkReader, big: inout [BigFile], shared: inout [Shared]) {
		var c = Counters()
		var mark: DirFlags = []
		var found: [Child] = []
		var sum: UInt64 = 0, logical: UInt64 = 0, count: UInt32 = 0, purgeable: UInt64 = 0
		var marked: UInt16 = 0

		let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		if fd < 0, job.refresh, errno == EACCES || errno == EPERM {
			cond.lock()
			let i = Int(job.index)
			let wasOpen = !flags[i].contains(.denied)
			if wasOpen {
				keptClosed.append(job.index)
				active -= 1
				if jobs.isEmpty && active == 0 { cond.broadcast() }
				cond.unlock()
				return
			}
			cond.unlock()
		}
		if fd < 0 {
			mark.insert(job.refresh && (errno == ENOENT || errno == ENOTDIR) ? .gone
				: errno == EACCES || errno == EPERM ? .denied : .partial)
		} else {
			if let d = realDevice(fd), d != dev {
				mark.insert(.elsewhere)
			} else {
				let err = reader.read(fd: fd) { e in
					marked |= Marks.of(e.name)
					if e.isDir {
						var f: DirFlags = []
						if e.isDataless { f.insert(.dataless) }
						if e.flags & UInt32(UF_HIDDEN) != 0 || e.name.hasPrefix(".") { f.insert(.hidden) }
						found.append(Child(name: e.name, flags: f, mtime: e.mtime))
						return
					}
					count += 1
					logical += e.size
					if e.isDataless { c.dataless += e.size }
					let counted = job.inView ? e.alloc : countedBytes(e, dir: job.index, path: job.path, counters: &c, shared: &shared)
					sum += counted
					if e.isPurgeable { purgeable += counted }
					if counted >= Self.bigFile || e.alloc >= Self.bigFile {
						big.append(BigFile(dir: job.index, name: e.name, counted: counted, size: e.size,
						                   mtime: e.mtime, purgeable: e.isPurgeable))
					}
				}
				if err == EACCES || err == EPERM { mark.insert(.denied) } else if err != 0 { mark.insert(.partial) }
			}
			close(fd)
		}
		progressFiles.add(Int(count), ordering: .relaxed)
		progressFolders.add(1, ordering: .relaxed)
		progressBytes.add(Int(clamping: sum), ordering: .relaxed)
		cond.lock()
		let i = Int(job.index)
		own[i] = sum; ownLogical[i] = logical; ownFiles[i] = count; ownPurgeable[i] = purgeable; marks[i] = marked
		extraHard[i] = c.hardLink; extraClone[i] = c.cloneShared; partialShared[i] = c.partialClone; cloudOnly[i] = c.dataless
		flags[i].remove([.denied, .partial, .elsewhere])
		flags[i].formUnion(mark)
		var known: [String: Int] = [:]
		if job.refresh {
			for k in children(of: i) where !flags[Int(k)].contains(.gone) { known[names[Int(k)]] = Int(k) }
		}
		let here = views.isEmpty ? "" : relativePath(i)
		var pushed = 0
		for child in found {
			if let k = known.removeValue(forKey: child.name) {
				let was = flags[k].contains(.dataless), now = child.flags.contains(.dataless)
				if was && !now {
					flags[k].remove(.dataless)
					jobs.append(Job(index: Int32(k), path: job.path == "/" ? "/" + child.name : job.path + "/" + child.name,
					                inView: job.inView || flags[k].contains(.view), refresh: true))
					pushed += 1
				} else if !was && now {
					flags[k].insert(.dataless)
					markSubtreeGone(below: k)
					own[k] = 0; ownLogical[k] = 0; ownFiles[k] = 0; ownPurgeable[k] = 0
					extraHard[k] = 0; extraClone[k] = 0; partialShared[k] = 0; cloudOnly[k] = 0
				}
				continue
			}
			let index = Int32(names.count)
			var f = child.flags
			if !views.isEmpty && views.contains(here.isEmpty ? child.name : here + "/" + child.name) { f.insert(.view) }
			let inView = job.inView || f.contains(.view)
			append(name: child.name, parent: job.index, flags: f, mtime: child.mtime)
			if !child.flags.contains(.dataless) {
				jobs.append(Job(index: index, path: job.path == "/" ? "/" + child.name : job.path + "/" + child.name, inView: inView))
				pushed += 1
			}
		}
		for (_, k) in known { flags[k].insert(.gone) }
		active -= 1
		if pushed > 1 || (jobs.isEmpty && active == 0) { cond.broadcast() } else if pushed == 1 { cond.signal() }
		cond.unlock()
	}

	private func countedBytes(_ e: BulkEntry, dir: Int32, path: String, counters c: inout Counters, shared: inout [Shared]) -> UInt64 {
		var counted = e.alloc
		if e.links > 1 && e.isFile {
			if deferShared {
				shared.append(Shared(hard: true, key: e.fileID, dir: dir, name: e.name, bytes: counted, purgeable: e.isPurgeable, allShared: false))
				return 0
			}
			let id = e.fileID
			if !hardLinks.claim(id, relative(path, e.name), alive: { [self] p in
				var st = stat()
				return lstat(absolute(p), &st) == 0 && UInt64(st.st_ino) == id
			}) {
				c.hardLink += counted
				return 0
			}
			return counted
		}
		if counted > 0 && e.mayShareBlocks, let priv = e.privateSize, priv < counted {
			if deferShared {
				shared.append(Shared(hard: false, key: e.cloneID, dir: dir, name: e.name, bytes: counted - priv,
				                     purgeable: e.isPurgeable, allShared: e.extFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0))
				return priv
			}
			if clones.claim(e.cloneID, relative(path, e.name), alive: { [self] p in
				var st = stat()
				return lstat(absolute(p), &st) == 0
			}) {
				if e.extFlags & UInt64(EF_SHARES_ALL_BLOCKS) == 0 { c.partialClone += counted - priv }
			} else {
				c.cloneShared += counted - priv
				counted = priv
			}
		}
		return counted
	}

	private func relative(_ folder: String, _ name: String) -> String {
		let rel = folder == root ? "" : String(folder.dropFirst(root == "/" ? 1 : root.count + 1))
		return rel.isEmpty ? name : rel + "/" + name
	}

	private func absolute(_ rel: String) -> String { root == "/" ? "/" + rel : root + "/" + rel }

	private func isInView(_ i: Int) -> Bool {
		var j = i
		while j >= 0 { if flags[j].contains(.view) { return true }; j = Int(parents[j]) }
		return false
	}

	private func isUnderGone(_ i: Int) -> Bool {
		var j = Int(parents[i])
		while j >= 0 { if flags[j].contains(.gone) { return true }; j = Int(parents[j]) }
		return false
	}

	private func markSubtreeGone(below i: Int) {
		var dead: Set<Int32> = [Int32(i)]
		for k in i + 1..<names.count where dead.contains(parents[k]) {
			dead.insert(Int32(k))
			flags[k].insert(.gone)
		}
		big.removeAll { dead.contains($0.dir) }
	}

	func finish() {
		let n = names.count
		total = own; totalFiles = ownFiles.map(UInt64.init); totalPurgeable = ownPurgeable
		var childCount = [Int32](repeating: 0, count: n + 1)
		var dead = [Bool](repeating: false, count: n)
		for i in 0..<n {
			dead[i] = flags[i].contains(.gone) || (i > 0 && dead[Int(parents[i])])
		}
		big.removeAll { dead[Int($0.dir)] }
		var k = Counters()
		for i in 0..<n where !dead[i] && !flags[i].contains(.view) {
			k.hardLink += extraHard[i]; k.cloneShared += extraClone[i]
			k.partialClone += partialShared[i]; k.dataless += cloudOnly[i]
		}
		for i in stride(from: n - 1, through: 1, by: -1) where !dead[i] {
			let p = Int(parents[i])
			childCount[p] += 1
			if flags[i].contains(.view) { continue }
			total[p] += total[i]; totalFiles[p] += totalFiles[i]; totalPurgeable[p] += totalPurgeable[i]
		}
		k.files = n > 0 ? totalFiles[0] : 0
		counters = k
		childStart = [Int32](repeating: 0, count: n + 1)
		for i in 0..<n { childStart[i + 1] = childStart[i] + childCount[i] }
		childList = [Int32](repeating: 0, count: Int(childStart[n]))
		var fill = Array(childStart.prefix(n))
		for i in 1..<max(n, 1) where !dead[i] {
			let p = Int(parents[i])
			childList[Int(fill[p])] = Int32(i)
			fill[p] += 1
		}
	}

	func graft(_ part: VolumeScan, at dir: Int, settle: Bool = true) {
		guard dir < count, part.count > 0 else { return }
		markSubtreeGone(below: dir)
		big.removeAll { $0.dir == Int32(dir) }
		let base = Int32(names.count) - 1
		func map(_ k: Int32) -> Int32 { k == 0 ? Int32(dir) : base + k }
		own[dir] = part.own[0]; ownLogical[dir] = part.ownLogical[0]; ownFiles[dir] = part.ownFiles[0]
		ownPurgeable[dir] = part.ownPurgeable[0]; marks[dir] = part.marks[0]
		extraHard[dir] = part.extraHard[0]; extraClone[dir] = part.extraClone[0]
		partialShared[dir] = part.partialShared[0]; cloudOnly[dir] = part.cloudOnly[0]
		flags[dir].remove([.denied, .partial])
		flags[dir].formUnion(part.flags[0].intersection([.denied, .partial]))
		for k in 1..<part.count {
			append(name: part.names[k], parent: map(part.parents[k]), flags: part.flags[k], mtime: part.mtimes[k])
			let i = names.count - 1
			own[i] = part.own[k]; ownLogical[i] = part.ownLogical[k]; ownFiles[i] = part.ownFiles[k]
			ownPurgeable[i] = part.ownPurgeable[k]; marks[i] = part.marks[k]
			extraHard[i] = part.extraHard[k]; extraClone[i] = part.extraClone[k]
			partialShared[i] = part.partialShared[k]; cloudOnly[i] = part.cloudOnly[k]
		}
		for b in part.big { var c = b; c.dir = map(b.dir); big.append(c) }
		let prefix = relativePath(dir)
		for (from, to) in [(part.hardLinks, hardLinks), (part.clones, clones)] {
			to.load(from.all.map { ($0.0, prefix.isEmpty ? $0.1 : prefix + "/" + $0.1) }, keep: true)
		}
		if settle { finish() }
	}

	func compact() {
		let n = names.count
		var map = [Int32](repeating: -1, count: n)
		var next: Int32 = 0
		for i in 0..<n {
			let dead = flags[i].contains(.gone) || (i > 0 && map[Int(parents[i])] < 0)
			if !dead { map[i] = next; next += 1 }
		}
		guard Int(next) < n else { return }
		generation = Self.nextGeneration()
		func keep<T>(_ a: [T]) -> [T] { (0..<n).compactMap { map[$0] >= 0 ? a[$0] : nil } }
		names = keep(names); flags = keep(flags); mtimes = keep(mtimes)
		own = keep(own); ownLogical = keep(ownLogical); ownFiles = keep(ownFiles); ownPurgeable = keep(ownPurgeable)
		marks = keep(marks); extraHard = keep(extraHard); extraClone = keep(extraClone)
		partialShared = keep(partialShared); cloudOnly = keep(cloudOnly)
		parents = keep(parents).map { $0 < 0 ? $0 : map[Int($0)] }
		big = big.compactMap { b in map[Int(b.dir)] < 0 ? nil : { var c = b; c.dir = map[Int(b.dir)]; return c }() }
		finish()
	}

	var count: Int { names.count }

	func children(of i: Int) -> ArraySlice<Int32> {
		childList[Int(childStart[i])..<Int(childStart[i + 1])]
	}

	func relativePath(_ i: Int) -> String {
		var parts: [String] = []
		var j = i
		while j > 0 { parts.append(names[j]); j = Int(parents[j]) }
		return parts.reversed().joined(separator: "/")
	}

	func path(_ i: Int) -> String {
		let rel = relativePath(i)
		if rel.isEmpty { return root }
		return root == "/" ? "/" + rel : root + "/" + rel
	}

	func find(_ relative: String) -> Int? {
		var i = 0
		for part in relative.split(separator: "/") where !part.isEmpty {
			guard let next = children(of: i).first(where: { names[Int($0)] == part }) else { return nil }
			i = Int(next)
		}
		return i
	}

	func flagged(_ f: DirFlags) -> [Int] {
		(0..<count).filter { !flags[$0].intersection(f).isEmpty && !flags[$0].contains(.gone) }
	}
}
