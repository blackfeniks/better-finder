import Darwin
import Foundation

struct Node: Hashable, Sendable {
	let volume: String
	let dir: Int32
}

final class Tree: @unchecked Sendable {
	let disk: DiskScan?
	let others: [String: (info: OtherVolume, scan: VolumeScan)]

	private var extra: [String: [Int32: UInt64]] = [:]
	private var extraFiles: [String: [Int32: UInt64]] = [:]
	private var computing: Set<String> = []
	private var overlapBytes: UInt64 = 0
	private var overlapNode: Node?

	init(disk: DiskScan?, others: [String: (info: OtherVolume, scan: VolumeScan)]) {
		self.disk = disk
		self.others = others
		for v in volumeKeys { _ = extras(v) }
	}

	private var volumeKeys: [String] { Array(disk?.scans.keys ?? [:].keys) + Array(others.keys) }

	func scan(_ volume: String) -> VolumeScan? { disk?.scans[volume] ?? others[volume]?.scan }

	var systemDevice: String? { disk?.systemVolume?.device }
	var dataDevice: String? { disk?.dataVolume?.device }

	var bootRoot: Node? { systemDevice.flatMap { scan($0) != nil ? Node(volume: $0, dir: 0) : nil } }

	func root(of volume: String) -> Node { Node(volume: volume, dir: 0) }

	func path(_ n: Node) -> String {
		guard let s = has(n) else { return "" }
		if let disk, disk.scans[n.volume] === s { return disk.logicalPath(s, Int(n.dir)) }
		return s.path(Int(n.dir))
	}

	func realPath(_ n: Node) -> String { has(n)?.path(Int(n.dir)) ?? "" }

	private func has(_ n: Node) -> VolumeScan? {
		guard let s = scan(n.volume), n.dir >= 0, Int(n.dir) < s.count else { return nil }
		return s
	}

	func name(_ n: Node) -> String {
		guard let s = has(n) else { return "" }
		if n.dir == 0 {
			if n.volume == systemDevice { return "Macintosh HD" }
			if let o = others[n.volume] { return o.info.name }
			if let v = disk?.container.volumes.first(where: { $0.device == n.volume }) { return v.name }
		}
		return s.names[Int(n.dir)]
	}

	func generation(_ volume: String) -> Int? { scan(volume)?.generation }

	func flags(_ n: Node) -> DirFlags { has(n)?.flags[Int(n.dir)] ?? [] }

	func isLive(_ n: Node) -> Bool {
		guard let s = has(n) else { return false }
		var j = Int(n.dir)
		while j >= 0 {
			if s.flags[j].contains(.gone) { return false }
			j = Int(s.parents[j])
		}
		return true
	}

	func locate(_ path: String) -> Node? {
		for (key, o) in others where path == o.info.mount || path.hasPrefix(o.info.mount + "/") {
			let rel = String(path.dropFirst(o.info.mount.count))
			return o.scan.find(rel).map { Node(volume: key, dir: Int32($0)) }
		}
		guard let disk, let (s, i) = disk.locate(path), let key = disk.scans.first(where: { $0.value === s })?.key else { return nil }
		return Node(volume: key, dir: Int32(i))
	}

	func resolve(_ n: Node) -> Node? {
		guard let s = has(n) else { return nil }
		guard s.flags[Int(n.dir)].contains(.elsewhere) else { return n }
		guard let target = locate(path(n)), target != n else { return nil }
		if others[target.volume] != nil && others[n.volume] == nil { return nil }
		return target
	}

	func mountPath(_ n: Node) -> String? {
		guard let s = has(n), s.flags[Int(n.dir)].contains(.elsewhere) else { return nil }
		return path(n)
	}

	func size(_ n: Node) -> UInt64 {
		guard let s = has(n) else { return 0 }
		return s.total[Int(n.dir)] + (extras(n.volume)[n.dir] ?? 0)
	}

	func ownBytes(_ n: Node) -> UInt64 { has(n).map { $0.own[Int(n.dir)] } ?? 0 }
	func ownFiles(_ n: Node) -> UInt64 { has(n).map { UInt64($0.ownFiles[Int(n.dir)]) } ?? 0 }

	func files(_ n: Node) -> UInt64 {
		guard let s = has(n) else { return 0 }
		_ = extras(n.volume)
		return s.totalFiles[Int(n.dir)] + (extraFiles[n.volume]?[n.dir] ?? 0)
	}

	private func extras(_ volume: String) -> [Int32: UInt64] {
		if let e = extra[volume] { return e }
		guard let s = scan(volume), !computing.contains(volume) else { return [:] }
		computing.insert(volume)
		defer { computing.remove(volume) }
		var e: [Int32: UInt64] = [:], f: [Int32: UInt64] = [:]
		for i in s.flagged(.elsewhere) {
			let n = Node(volume: volume, dir: Int32(i))
			guard let t = resolve(n), t.volume != volume else { continue }
			let add = added(from: n, to: t)
			guard add > 0 else { continue }
			let addFiles = isOverlap(n) ? 0 : files(t)
			var j = i
			while j >= 0 {
				e[Int32(j), default: 0] += add
				f[Int32(j), default: 0] += addFiles
				j = Int(s.parents[j])
			}
		}
		extra[volume] = e
		extraFiles[volume] = f
		return e
	}

	private func added(from n: Node, to t: Node) -> UInt64 {
		let full = size(t)
		guard t.dir == 0, t.volume == dataDevice, n.volume == systemDevice, let disk, let data = scan(t.volume) else { return full }
		var targets: [Int] = []
		for rel in Set(disk.firmlinks.values) {
			guard let i = data.find(rel), i != 0 else { continue }
			targets.append(i)
		}
		let set = Set(targets)
		var shown: UInt64 = 0
		for i in targets {
			var j = Int(data.parents[i]), inside = false
			while j > 0 { if set.contains(j) { inside = true; break }; j = Int(data.parents[j]) }
			if !inside { shown += size(Node(volume: t.volume, dir: Int32(i))) }
		}
		overlapNode = n
		overlapBytes = full > shown ? full - shown : 0
		return overlapBytes
	}

	func isOverlap(_ n: Node) -> Bool { n == overlapNode }

	struct Entry: Sendable {
		enum Note: Sendable {
			case overlap
			case closed
			case view
			case cloud
			case notWalked
		}
		let node: Node?
		let at: Node
		let name: String
		let bytes: UInt64
		let full: UInt64
		let files: UInt64
		let hidden: Bool
		let note: Note?
	}

	func entries(_ n: Node) -> [Entry] {
		guard let s = has(n) else { return [] }
		var out: [Entry] = []
		for c in s.children(of: Int(n.dir)) {
			let i = Int(c)
			let at = Node(volume: n.volume, dir: c)
			let f = s.flags[i]
			let hidden = f.contains(.hidden)
			if f.contains(.elsewhere) {
				if let t = resolve(at), t.volume != n.volume {
					let full = size(t)
					let add = isOverlap(at) ? overlapBytes : full
					out.append(Entry(node: t, at: at, name: s.names[i], bytes: add, full: full, files: files(t), hidden: hidden,
					                 note: isOverlap(at) ? .overlap : nil))
				} else {
					out.append(Entry(node: nil, at: at, name: s.names[i], bytes: 0, full: 0, files: 0, hidden: hidden, note: .notWalked))
				}
				continue
			}
			let note: Entry.Note? = f.contains(.view) ? .view : f.contains(.denied) ? .closed : f.contains(.dataless) ? .cloud : nil
			let full = size(at)
			out.append(Entry(node: at, at: at, name: s.names[i], bytes: f.contains(.view) ? 0 : full, full: full,
			                 files: files(at), hidden: hidden, note: note))
		}
		return out.sorted { ($0.bytes, $0.full) > ($1.bytes, $1.full) }
	}
}
