import CoreServices
import Darwin
import Foundation

final class Store: @unchecked Sendable {
	let folder: URL
	private static let magic: UInt32 = 0x4246_5331
	private static let version: UInt32 = 2

	init() {
		if let env = ProcessInfo.processInfo.environment["BETTERFINDER_CACHE"] {
			folder = URL(fileURLWithPath: env)
		} else if let project = Bundle.main.object(forInfoDictionaryKey: "BFProjectFolder") as? String, !project.isEmpty {
			folder = URL(fileURLWithPath: project).appendingPathComponent("cache")
		} else {
			var root = Bundle.main.bundleURL
			if root.pathExtension != "app" { root = Bundle.main.executableURL!.deletingLastPathComponent() }
			folder = root.deletingLastPathComponent().appendingPathComponent("cache")
		}
	}

	struct Target: Sendable {
		let uuid: String
		let mount: String
		let role: String
		var views: Set<String> { DiskScan.views(for: role) }
		var stamp: String = ""

		init(uuid: String, mount: String, role: String, inUse: UInt64 = 0) {
			self.uuid = uuid; self.mount = mount; self.role = role
			if role == "System" {
				let build = (NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String) ?? "?"
				stamp = "\(build)/\(inUse)"
			}
		}

		init?(_ v: APFSVolume) {
			guard let m = v.mount else { return nil }
			self.init(uuid: v.uuid, mount: m, role: v.role, inUse: v.inUse)
		}

		var cached: Bool { !uuid.isEmpty && (role == "System" || role == "Data" || role.isEmpty) }
	}

	struct Header: Sendable {
		var root: String
		var eventsUUID: String
		var lastEvent: UInt64
		var stamp: String
		var date: Date
	}

	private func file(_ uuid: String) -> URL { folder.appendingPathComponent(uuid + ".scan") }

	@discardableResult
	func save(_ s: VolumeScan, _ t: Target, lastEvent: UInt64) throws -> Int {
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		let h = Header(root: s.root, eventsUUID: Self.eventsUUID(s.dev), lastEvent: lastEvent, stamp: t.stamp, date: Date())
		let c = s.copy()
		c.compact()
		guard let packed = try? (Self.encode(c, h) as NSData).compressed(using: .lzfse) as Data else { throw BulkError.read(EIO) }
		try packed.write(to: file(t.uuid), options: .atomic)
		return packed.count
	}

	static func encode(_ s: VolumeScan, _ h: Header) -> Data {
		var w = Writer()
		w.u32(magic); w.u32(version)
		w.str(h.root); w.str(h.eventsUUID); w.u64(h.lastEvent); w.str(h.stamp); w.f64(h.date.timeIntervalSince1970)
		w.u64(UInt64(s.count))
		w.str(s.names.joined(separator: "\0"))
		w.array(s.parents); w.array(s.flags.map(\.rawValue)); w.array(s.mtimes)
		w.array(s.own); w.array(s.ownLogical); w.array(s.ownFiles); w.array(s.ownPurgeable); w.array(s.marks)
		w.array(s.extraHard); w.array(s.extraClone); w.array(s.partialShared); w.array(s.cloudOnly)
		w.u64(UInt64(s.big.count))
		for b in s.big {
			w.i32(b.dir); w.u64(b.counted); w.u64(b.size); w.i64(b.mtime); w.u8(b.purgeable ? 1 : 0); w.str(b.name)
		}
		for carriers in [s.hardLinks.all, s.clones.all] {
			w.array(carriers.map(\.0)); w.str(carriers.map(\.1).joined(separator: "\0"))
		}
		return w.data
	}

	func load(_ t: Target) -> (scan: VolumeScan, header: Header)? {
		guard let packed = try? Data(contentsOf: file(t.uuid)),
		      let raw = try? (packed as NSData).decompressed(using: .lzfse) as Data,
		      let probe = try? VolumeScan(root: t.mount, views: t.views),
		      let (s, h) = Self.decode(raw, root: t.mount, dev: probe.dev, views: t.views), h.root == t.mount else { return nil }
		return (s, h)
	}

	static func root(of raw: Data) -> String? {
		var r = Reader(raw)
		guard r.u32() == magic, r.u32() == version else { return nil }
		let root = r.str()
		return r.ok ? root : nil
	}

	static func decode(_ raw: Data, root: String, dev: dev_t, views: Set<String>) -> (VolumeScan, Header)? {
		var r = Reader(raw)
		guard r.u32() == magic, r.u32() == version else { return nil }
		let h = Header(root: r.str(), eventsUUID: r.str(), lastEvent: r.u64(), stamp: r.str(),
		               date: Date(timeIntervalSince1970: r.f64()))
		let s = VolumeScan(root: root, dev: dev, views: views)
		guard let n = Int(exactly: r.u64()) else { return nil }
		s.names = r.str().components(separatedBy: "\0")
		s.parents = r.array(); s.flags = (r.array() as [UInt8]).map(DirFlags.init); s.mtimes = r.array()
		s.own = r.array(); s.ownLogical = r.array(); s.ownFiles = r.array(); s.ownPurgeable = r.array(); s.marks = r.array()
		s.extraHard = r.array(); s.extraClone = r.array(); s.partialShared = r.array(); s.cloudOnly = r.array()
		let lengths = [s.names.count, s.parents.count, s.flags.count, s.mtimes.count, s.own.count, s.ownLogical.count,
		               s.ownFiles.count, s.ownPurgeable.count, s.marks.count, s.extraHard.count, s.extraClone.count,
		               s.partialShared.count, s.cloudOnly.count]
		guard n > 0, lengths.allSatisfy({ $0 == n }), s.parents[0] == -1,
		      (1..<n).allSatisfy({ s.parents[$0] >= 0 && Int(s.parents[$0]) < $0 }) else { return nil }
		guard let bigCount = Int(exactly: r.u64()), bigCount < 100_000_000 else { return nil }
		s.big.reserveCapacity(bigCount)
		for _ in 0..<bigCount {
			let dir = r.i32(), counted = r.u64(), size = r.u64(), mtime = r.i64(), purgeable = r.u8() == 1, name = r.str()
			guard dir >= 0, Int(dir) < n else { return nil }
			s.big.append(BigFile(dir: dir, name: name, counted: counted, size: size, mtime: mtime, purgeable: purgeable))
		}
		for carriers in [s.hardLinks, s.clones] {
			let keys: [UInt64] = r.array()
			let paths = r.str()
			let values = keys.isEmpty ? [] : paths.components(separatedBy: "\0")
			guard values.count == keys.count else { return nil }
			carriers.load(Array(zip(keys, values)))
		}
		guard r.ok else { return nil }
		s.finish()
		return (s, h)
	}

	struct CatchUp {
		var changes: Int
		var reread: Int
		var deep: Int
		var next: UInt64
	}

	func stillExact(_ h: Header, _ t: Target) -> Bool { !t.stamp.isEmpty && h.stamp == t.stamp }

	func catchUp(_ scan: VolumeScan, _ h: Header) -> CatchUp? {
		guard !h.eventsUUID.isEmpty, h.eventsUUID == Self.eventsUUID(scan.dev), h.lastEvent > 0 else { return nil }
		let next = FSEventsGetCurrentEventId()
		guard let changes = Self.changes(on: scan.dev, since: h.lastEvent) else { return nil }
		let (changed, deep, _) = Self.resolve(changes, in: scan)
		if deep.contains(0) { return nil }
		if !changed.isEmpty || !deep.isEmpty { scan.rescan(changed, deep: deep) }
		return CatchUp(changes: changes.count, reread: changed.count, deep: deep.count, next: next)
	}

	func open(_ disk: DiskScan) -> [String] {
		var log: [String] = []
		for v in disk.container.volumes {
			guard let t = Target(v) else { continue }
			let t0 = Date()
			if t.cached, let (scan, h) = load(t) {
				let loaded = Self.took(t0)
				if stillExact(h, t) {
					disk.adopt(scan, for: v.device)
					log.append("\(v.name): from cache (sealed, unchanged)" + loaded)
					continue
				}
				if t.stamp.isEmpty, let c = catchUp(scan, h) {
					_ = try? save(scan, t, lastEvent: c.next)
					disk.adopt(scan, for: v.device)
					log.append("\(v.name): from cache\(loaded) + \(c.changes) changes since \(Self.age(h.date)) → " +
					           "\(c.reread) folders read again, \(c.deep) in full" + Self.took(t0))
					continue
				}
				log.append("\(v.name): cache out of date, walking again")
			}
			guard let scan = try? VolumeScan(root: t.mount, views: t.views) else { continue }
			let event = FSEventsGetCurrentEventId()
			scan.run()
			disk.adopt(scan, for: v.device)
			if t.cached { _ = try? save(scan, t, lastEvent: event) }
			log.append("\(v.name): walked, \(scan.counters.files) files" + Self.took(t0))
		}
		return log
	}

	static func took(_ t0: Date) -> String { String(format: " (%.2f s)", Date().timeIntervalSince(t0)) }

	static func age(_ d: Date) -> String {
		let s = Int(Date().timeIntervalSince(d))
		return s < 120 ? "\(s) s ago" : s < 7200 ? "\(s / 60) min ago" : s < 172_800 ? "\(s / 3600) h ago" : "\(s / 86400) days ago"
	}

	static func eventsUUID(_ dev: dev_t) -> String {
		guard let u = FSEventsCopyUUIDForDevice(dev) else { return "" }
		return CFUUIDCreateString(nil, u) as String
	}

	struct Change { var path: String; var flags: FSEventStreamEventFlags; var id: UInt64 = 0 }

	private final class Collector: @unchecked Sendable {
		var changes: [Change] = []
		var broken = false
		let done = DispatchSemaphore(value: 0)
	}

	static func changes(on dev: dev_t, since: UInt64, timeout: Double = 30) -> [Change]? {
		let box = Collector()
		var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
		                                   retain: nil, release: nil, copyDescription: nil)
		let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
			let box = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
			let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
			for i in 0..<count {
				let f = flags[i]
				if f & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { box.done.signal(); continue }
				if f & FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
					box.broken = true
				}
				if i < list.count { box.changes.append(Change(path: list[i], flags: f, id: ids[i])) }
			}
		}
		guard let stream = FSEventStreamCreateRelativeToDevice(
			nil, callback, &context, dev, ["" as CFString] as CFArray, since, 0,
			FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return nil }
		let queue = DispatchQueue(label: "fsevents.history")
		FSEventStreamSetDispatchQueue(stream, queue)
		guard FSEventStreamStart(stream) else {
			FSEventStreamInvalidate(stream)
			FSEventStreamRelease(stream)
			return nil
		}
		let finished = box.done.wait(timeout: .now() + timeout) == .success
		FSEventStreamStop(stream)
		FSEventStreamInvalidate(stream)
		FSEventStreamRelease(stream)
		return queue.sync { finished && !box.broken ? box.changes : nil }
	}

	static func resolve(_ changes: [Change], in scan: VolumeScan) -> (changed: [Int], deep: Set<Int>, unknown: Int) {
		var changed = Set<Int>(), deep = Set<Int>(), unknown = 0
		let mustScan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
			| kFSEventStreamEventFlagKernelDropped)
		var memo: [String: Int] = [:]
		for c in changes {
			var rel = c.path
			while rel.hasPrefix("/") { rel.removeFirst() }
			while rel.hasSuffix("/") { rel.removeLast() }
			var probe = rel
			var found: Int?
			while true {
				if let m = memo[probe] { found = m; break }
				if let i = scan.find(probe) { memo[probe] = i; found = i; break }
				if probe.isEmpty { break }
				guard let slash = probe.lastIndex(of: "/") else { probe = ""; continue }
				probe = String(probe[..<slash])
			}
			guard let i = found else { continue }
			if probe != rel { unknown += 1 }
			if c.flags & mustScan != 0 { deep.insert(i) } else { changed.insert(i) }
		}
		return (Array(changed.subtracting(deep)), deep, unknown)
	}
}

private struct Writer {
	var data = Data()
	mutating func u8(_ v: UInt8) { data.append(v) }
	mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
	mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
	mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
	mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
	mutating func f64(_ v: Double) { u64(v.bitPattern) }
	mutating func str(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); data.append(contentsOf: b) }
	mutating func array<T: FixedWidthInteger>(_ a: [T]) {
		u64(UInt64(a.count))
		a.withUnsafeBytes { data.append(contentsOf: $0) }
	}
}

private struct Reader {
	let data: Data
	var at = 0
	var ok = true
	init(_ d: Data) { data = d }

	private mutating func take(_ n: Int) -> Data? {
		guard ok, n >= 0, at + n <= data.count else { ok = false; return nil }
		defer { at += n }
		return data.subdata(in: data.startIndex + at..<data.startIndex + at + n)
	}
	private mutating func int<T: FixedWidthInteger>(_: T.Type) -> T {
		guard let d = take(MemoryLayout<T>.size) else { return 0 }
		return T(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
	}
	mutating func u8() -> UInt8 { int(UInt8.self) }
	mutating func u32() -> UInt32 { int(UInt32.self) }
	mutating func i32() -> Int32 { int(Int32.self) }
	mutating func u64() -> UInt64 { int(UInt64.self) }
	mutating func i64() -> Int64 { int(Int64.self) }
	mutating func f64() -> Double { Double(bitPattern: u64()) }
	mutating func str() -> String {
		let n = u64()
		guard n <= UInt64(Int.max), let d = take(Int(n)) else { ok = false; return "" }
		return String(decoding: d, as: UTF8.self)
	}
	mutating func array<T: FixedWidthInteger>() -> [T] {
		let n = u64()
		let size = UInt64(MemoryLayout<T>.size)
		guard n < UInt64(Int.max) / size, let d = take(Int(n * size)) else { ok = false; return [] }
		return d.withUnsafeBytes { raw in
			var out = [T](repeating: 0, count: Int(n))
			out.withUnsafeMutableBytes { $0.copyMemory(from: raw) }
			for i in 0..<out.count { out[i] = T(littleEndian: out[i]) }
			return out
		}
	}
}
