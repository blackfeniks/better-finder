import CoreServices
import Foundation
import Synchronization

final class Snapshot: @unchecked Sendable {
	let id: Int
	let disk: DiskScan
	let meaning: Meaning
	let cleanup: [Candidate]
	let tree: Tree
	let others: [String: (info: OtherVolume, scan: VolumeScan)]
	let walking: Set<String>

	init(id: Int, disk: DiskScan, others: [String: (info: OtherVolume, scan: VolumeScan)], walking: Set<String>) {
		self.id = id
		self.disk = disk
		self.others = others
		self.walking = walking
		meaning = Meaning(disk: disk)
		cleanup = Cleanup.candidates(disk, meaning)
		tree = Tree(disk: disk, others: others)
	}

	var container: APFSContainer { disk.container }

	var notVisible: UInt64 {
		let used = disk.container.used
		guard let r = tree.bootRoot else { return 0 }
		let seen = tree.size(r)
		return used > seen ? used - seen : 0
	}
}

final class Engine: @unchecked Sendable {
	enum Phase: Equatable, Sendable {
		case starting
		case walking(disk: String, files: Int, folders: Int, bytes: UInt64, used: UInt64)
		case catchingUp
		case ready
		case failed(String)
	}

	var onSnapshot: (@MainActor (Snapshot) -> Void)?
	var onPhase: (@MainActor (Phase) -> Void)?
	var onOtherProgress: (@MainActor (String, Int, UInt64) -> Void)?

	private let q = DispatchQueue(label: "com.ilya.betterfinder.engine", qos: .userInitiated)
	private let busy = Atomic<Int>(0)
	private func long<T>(_ body: () -> T) -> T {
		busy.add(1, ordering: .relaxed)
		defer { busy.subtract(1, ordering: .relaxed) }
		return body()
	}
	private let store = Store()
	private var disk: DiskScan?
	private var targets: [String: Store.Target] = [:]
	private var current: [String: UInt64] = [:]
	private var others: [String: (info: OtherVolume, scan: VolumeScan)] = [:]
	private var walking: Set<String> = []
	private var watchers: [String: Watcher] = [:]
	private var pending: [String: [Store.Change]] = [:]
	private var applyScheduled = false
	private var lastApply = Date.distantPast
	private var counter = 0
	private var started = false

	func start() {
		q.async { [self] in
			guard !started else { return }
			started = true
			guard let container = Disks.boot() else { return phase(.failed("No APFS startup disk found")) }
			let d = DiskScan(container: container)
			disk = d
			var catchUp: [(String, Store.Header)] = []
			var walk: [APFSVolume] = []
			for v in container.volumes.sorted(by: { $0.inUse < $1.inUse }) {
				guard let t = Store.Target(v) else { continue }
				targets[v.device] = t
				if t.cached, let (scan, h) = store.load(t) {
					d.adopt(scan, for: v.device)
					if store.stillExact(h, t) { continue }
					if t.stamp.isEmpty { catchUp.append((v.device, h)) } else { walk.append(v) }
				} else if t.cached {
					walk.append(v)
				} else if let scan = try? VolumeScan(root: t.mount, views: t.views) {
					scan.run()
					d.adopt(scan, for: v.device)
				}
			}
			let haveBoth = d.dataVolume.map { d.scans[$0.device] != nil } ?? false
				&& d.systemVolume.map { d.scans[$0.device] != nil } ?? false
			if haveBoth { publish() }
			phase(haveBoth ? .catchingUp : .starting)

			var base: (Int, Int, UInt64) = (0, 0, 0)
			let used = container.used
			for v in walk {
				let b = base
				guard let t = targets[v.device], let scan = walkVolume(t, key: v.device, progress: { files, folders, bytes in
					self.phase(.walking(disk: "Macintosh HD", files: b.0 + files, folders: b.1 + folders, bytes: b.2 + bytes, used: used))
				}) else { continue }
				d.adopt(scan, for: v.device)
				base = (base.0 + Int(scan.counters.files), base.1 + scan.count, base.2 + UInt64(scan.progressBytes.load(ordering: .relaxed)))
			}
			if !walk.isEmpty { publish() }
			for (dev, h) in catchUp {
				guard let t = targets[dev], let cached = d.scans[dev] else { continue }
				let scan = cached.copy()
				if let c = long({ store.catchUp(scan, h) }) {
					d.adopt(scan, for: dev)
					current[dev] = c.next
				} else if let fresh = walkVolume(t, key: dev, progress: { files, folders, bytes in
					if !haveBoth { self.phase(.walking(disk: "Macintosh HD", files: files, folders: folders, bytes: bytes, used: container.used)) }
				}) {
					d.adopt(fresh, for: dev)
				}
			}
			for (dev, s) in d.scans where targets[dev]?.stamp.isEmpty ?? false {
				let reader = BulkReader()
				let reopen = s.flagged(.denied).filter { i in
					let fd = Darwin.open(s.path(i), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
					guard fd >= 0 else { return false }
					defer { close(fd) }
					return reader.read(fd: fd) { _ in } == 0
				}
				guard !reopen.isEmpty else { continue }
				let c = s.copy()
				c.rescan(reopen)
				d.adopt(c, for: dev)
			}
			d.refreshNumbers()
			publish()
			phase(.ready)
			if Privileged.hasPassword {
				adminOn = true
				fillClosed(force: true)
			}
			for (dev, t) in targets where t.cached {
				guard let s = d.scans[dev] else { continue }
				if t.stamp.isEmpty || walk.contains(where: { $0.device == dev }) {
					_ = try? store.save(s, t, lastEvent: current[dev] ?? FSEventsGetCurrentEventId())
				}
				if t.stamp.isEmpty { watch(dev, scan: s) }
			}
		}
	}

	private func walkVolume(_ t: Store.Target, key: String, threads: Int? = nil,
	                        progress: @escaping @Sendable (Int, Int, UInt64) -> Void) -> VolumeScan? {
		guard let scan = try? VolumeScan(root: t.mount, views: t.views) else { return nil }
		let event = FSEventsGetCurrentEventId()
		let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
		timer.schedule(deadline: .now(), repeating: .milliseconds(120))
		timer.setEventHandler {
			progress(scan.progressFiles.load(ordering: .relaxed), scan.progressFolders.load(ordering: .relaxed),
			         UInt64(scan.progressBytes.load(ordering: .relaxed)))
		}
		timer.resume()
		long { scan.run(threads: threads ?? VolumeScan.defaultThreads) }
		timer.cancel()
		current[key] = event
		return scan
	}

	func open(_ v: OtherVolume, key: String) {
		q.async { [self] in
			guard others[key] == nil, !walking.contains(key) else { return }
			let t = Store.Target(uuid: v.uuid, mount: v.mount, role: "")
			targets[key] = t
			if t.cached, let (scan, h) = store.load(t) {
				others[key] = (v, scan)
				publish()
				let copy = scan.copy()
				if let c = long({ store.catchUp(copy, h) }) {
					others[key] = (v, copy)
					current[key] = c.next
					publish()
					_ = try? store.save(copy, t, lastEvent: c.next)
					watch(key, scan: copy)
					return
				}
			}
			walking.insert(key)
			publish()
			let threads = Storage.kind(of: v.mount).threads
			guard let scan = walkVolume(t, key: key, threads: threads, progress: { files, _, bytes in
				DispatchQueue.main.async { MainActor.assumeIsolated { self.onOtherProgress?(key, files, bytes) } }
			}) else {
				walking.remove(key)
				publish()
				return
			}
			walking.remove(key)
			others[key] = (v, scan)
			publish()
			if t.cached { _ = try? store.save(scan, t, lastEvent: current[key] ?? FSEventsGetCurrentEventId()) }
			watch(key, scan: scan)
		}
	}

	func forget(_ key: String) {
		q.async { [self] in
			watchers.removeValue(forKey: key)?.stop()
			pending[key] = nil
			if others.removeValue(forKey: key) != nil { publish() }
		}
	}

	func changed(_ paths: [String]) {
		q.async { [self] in
			guard let snap = lastSnapshot else { return }
			var byVolume: [String: Set<Int>] = [:]
			for p in paths {
				var up = (p as NSString).deletingLastPathComponent
				while !up.isEmpty {
					if let n = snap.tree.locate(up) { byVolume[n.volume, default: []].insert(Int(n.dir)); break }
					if up == "/" { break }
					up = (up as NSString).deletingLastPathComponent
				}
			}
			for (key, dirs) in byVolume {
				guard let s = scanFor(key)?.copy() else { continue }
				s.rescan(Array(dirs))
				replace(key, with: s)
			}
			disk?.refreshNumbers()
			publish()
		}
	}

	private func scanFor(_ key: String) -> VolumeScan? { disk?.scans[key] ?? others[key]?.scan }

	private func replace(_ key: String, with s: VolumeScan) {
		if disk?.scans[key] != nil { disk?.adopt(s, for: key) } else if let o = others[key] { others[key] = (o.info, s) }
	}

	private func watch(_ key: String, scan: VolumeScan) {
		watchers[key]?.stop()
		let since = current[key] ?? FSEventsGetCurrentEventId()
		watchers[key] = Watcher(dev: scan.dev, since: since, queue: q) { [weak self] changes in
			self?.received(key, changes)
		}
	}

	private func received(_ key: String, _ changes: [Store.Change]) {
		pending[key, default: []] += changes
		guard !applyScheduled else { return }
		applyScheduled = true
		let wait = max(0.4, 2 - Date().timeIntervalSince(lastApply))
		q.asyncAfter(deadline: .now() + wait) { [self] in applyPending() }
	}

	private func applyPending() {
		applyScheduled = false
		lastApply = Date()
		let batch = pending
		pending = [:]
		var any = false
		for (key, changes) in batch where !changes.isEmpty {
			guard let old = scanFor(key) else { continue }
			let (changed, deep, _) = Store.resolve(changes, in: old)
			let s: VolumeScan
			if deep.contains(0), let t = targets[key] {
				guard let fresh = try? VolumeScan(root: t.mount, views: t.views) else { continue }
				let event = FSEventsGetCurrentEventId()
				long { fresh.run(threads: others[key] != nil ? Storage.kind(of: t.mount).threads : VolumeScan.defaultThreads) }
				current[key] = event
				s = fresh
			} else {
				s = old.copy()
				s.rescan(changed, deep: deep)
				if !s.keptClosed.isEmpty { needRoot[key, default: []].formUnion(s.keptClosed) }
			}
			replace(key, with: s)
			if !deep.contains(0) { current[key] = max(current[key] ?? 0, changes.map(\.id).max() ?? 0) }
			any = true
		}
		guard any else { return }
		if adminOn && (!needRoot.isEmpty || disk?.scans.values.contains { !$0.flagged(.denied).isEmpty } == true) { fillClosed() }
		disk?.refreshNumbers()
		for (key, o) in others {
			var info = o.info
			var st = statfs()
			if statfs(info.mount, &st) == 0 {
				info.size = UInt64(st.f_blocks) * UInt64(st.f_bsize)
				info.free = UInt64(st.f_bavail) * UInt64(st.f_bsize)
				others[key] = (info, o.scan)
			}
		}
		publish()
	}

	enum AdminEvent: Sendable {
		case reading(Int)
		case done(added: UInt64)
		case wrongPassword
		case failed
	}
	var onAdmin: (@MainActor (AdminEvent) -> Void)?

	private var adminOn = false
	private var needRoot: [String: Set<Int32>] = [:]
	private var rootFailed: Set<String> = []
	private var lastFill = Date.distantPast
	private var filling = false
	private var fillScheduled = false
	private let helperQueue = DispatchQueue(label: "com.ilya.betterfinder.helper", qos: .utility)

	func setAdmin(_ on: Bool) {
		q.async { [self] in
			adminOn = on
			rootFailed = []
			if on { fillClosed(force: true) }
		}
	}

	private func fillClosed(force: Bool = false) {
		guard adminOn, !filling, let disk else { return }
		let wait = 60 - Date().timeIntervalSince(lastFill)
		if !force && wait > 0 {
			if !fillScheduled {
				fillScheduled = true
				q.asyncAfter(deadline: .now() + wait) { [self] in fillScheduled = false; fillClosed() }
			}
			return
		}
		var jobs: [(key: String, dir: Int, path: String)] = []
		for (key, s) in disk.scans {
			for i in s.flagged(.denied) {
				let p = s.path(i)
				if !rootFailed.contains(p) { jobs.append((key, i, p)) }
			}
			for i in needRoot[key] ?? [] where Int(i) < s.count && !s.flags[Int(i)].contains(.gone) {
				jobs.append((key, Int(i), s.path(Int(i))))
			}
		}
		needRoot = [:]
		guard !jobs.isEmpty else { return }
		filling = true
		lastFill = Date()
		let before = lastSnapshot?.notVisible ?? 0
		emit(.reading(jobs.count))
		helperQueue.async { [self] in
			let outcome = Privileged.walk(jobs.map(\.path), password: Privileged.savedPassword())
			q.async { [self] in
				filling = false
				let result: [String: VolumeScan]
				switch outcome {
				case .walks(let w): result = w
				case .wrongPassword:
					adminOn = false
					return emit(.wrongPassword)
				case .failed:
					for j in jobs where needRoot[j.key] == nil { needRoot[j.key] = [] }
					return emit(.failed)
				}
				var copies: [String: VolumeScan] = [:]
				for j in jobs {
					guard let part = result[j.path], part.count > 0, !part.flags[0].contains(.denied) else {
						rootFailed.insert(j.path)
						continue
					}
					guard let s = copies[j.key] ?? scanFor(j.key)?.copy(), j.dir < s.count, !s.flags[j.dir].contains(.gone),
					      s.path(j.dir) == j.path else { continue }
					s.graft(part, at: j.dir, settle: false)
					copies[j.key] = s
				}
				for (k, s) in copies {
					s.finish()
					replace(k, with: s)
				}
				if !copies.isEmpty { publish() }
				let after = lastSnapshot?.notVisible ?? 0
				emit(.done(added: before > after ? before - after : 0))
			}
		}
	}

	private func emit(_ e: AdminEvent) {
		DispatchQueue.main.async { MainActor.assumeIsolated { self.onAdmin?(e) } }
	}

	func saveNow() {
		guard busy.load(ordering: .relaxed) == 0 else { return }
		q.sync {
			for w in watchers.values { w.stop() }
			watchers = [:]
			for (key, t) in targets where t.cached && t.stamp.isEmpty {
				guard let s = scanFor(key), let event = current[key] else { continue }
				_ = try? store.save(s, t, lastEvent: event)
			}
		}
	}

	private var lastSnapshot: Snapshot?

	private func publish() {
		guard let disk else { return }
		counter += 1
		let snap = Snapshot(id: counter, disk: disk.copy(), others: others, walking: walking)
		lastSnapshot = snap
		DispatchQueue.main.async { MainActor.assumeIsolated { self.onSnapshot?(snap) } }
	}

	private func phase(_ p: Phase) {
		DispatchQueue.main.async { MainActor.assumeIsolated { self.onPhase?(p) } }
	}
}

final class Watcher: @unchecked Sendable {
	private var stream: FSEventStreamRef?
	private let deliver: ([Store.Change]) -> Void

	init?(dev: dev_t, since: UInt64, queue: DispatchQueue, deliver: @escaping ([Store.Change]) -> Void) {
		self.deliver = deliver
		var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
		                                   retain: nil, release: nil, copyDescription: nil)
		let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
			let me = Unmanaged<Watcher>.fromOpaque(info!).takeUnretainedValue()
			let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
			var out: [Store.Change] = []
			let skip = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
			for i in 0..<min(count, list.count) where flags[i] & skip == 0 {
				out.append(Store.Change(path: list[i], flags: flags[i], id: ids[i]))
			}
			if !out.isEmpty { me.deliver(out) }
		}
		guard let s = FSEventStreamCreateRelativeToDevice(
			nil, callback, &context, dev, ["" as CFString] as CFArray, since, 1.0,
			FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
		stream = s
		FSEventStreamSetDispatchQueue(s, queue)
		guard FSEventStreamStart(s) else {
			FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil
			return nil
		}
	}

	func stop() {
		guard let s = stream else { return }
		stream = nil
		FSEventStreamStop(s)
		FSEventStreamInvalidate(s)
		FSEventStreamRelease(s)
	}

	deinit { stop() }
}
