import Darwin
import Foundation

struct APFSVolume: Sendable {
	let device: String
	let uuid: String
	let name: String
	let roles: [String]
	let inUse: UInt64
	var mount: String?

	var role: String { roles.first ?? "" }
}

struct OtherVolume: Sendable, Hashable {
	let device: String
	let mount: String
	let name: String
	let uuid: String
	let type: String
	var size: UInt64
	var free: UInt64
	let isInternal: Bool

	var used: UInt64 { size > free ? size - free : 0 }
}

struct APFSContainer: Sendable {
	let device: String
	let size: UInt64
	let free: UInt64
	let stores: [String]
	let volumes: [APFSVolume]

	var used: UInt64 { size - free }
	var overhead: Int64 { Int64(used) - Int64(volumes.reduce(0) { $0 + $1.inUse }) }
}

enum Disks {
	static func containers() -> [APFSContainer] {
		guard let data = run("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
		      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
		      let list = plist["Containers"] as? [[String: Any]] else { return [] }
		let mounts = mountPoints()
		return list.map { c in
			let vols = (c["Volumes"] as? [[String: Any]] ?? []).map { v -> APFSVolume in
				let dev = v["DeviceIdentifier"] as? String ?? ""
				return APFSVolume(device: dev, uuid: v["APFSVolumeUUID"] as? String ?? "",
				                  name: v["Name"] as? String ?? dev, roles: v["Roles"] as? [String] ?? [],
				                  inUse: (v["CapacityInUse"] as? NSNumber)?.uint64Value ?? 0,
				                  mount: mounts[dev])
			}
			return APFSContainer(device: c["ContainerReference"] as? String ?? "",
			                     size: (c["CapacityCeiling"] as? NSNumber)?.uint64Value ?? 0,
			                     free: (c["CapacityFree"] as? NSNumber)?.uint64Value ?? 0,
			                     stores: (c["PhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["DeviceIdentifier"] as? String },
			                     volumes: vols)
		}
	}

	static func boot() -> APFSContainer? {
		containers().first { $0.volumes.contains { $0.mount == "/" } }
	}

	static func mountPoints() -> [String: String] {
		var buf: UnsafeMutablePointer<statfs>?
		let n = getmntinfo(&buf, MNT_NOWAIT)
		guard n > 0, let buf else { return [:] }
		var map: [String: String] = [:]
		for i in 0..<Int(n) {
			var s = buf[i]
			let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			let on = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			guard from.hasPrefix("/dev/disk") else { continue }
			var dev = String(from.dropFirst(5))
			if let r = dev.range(of: #"^disk\d+s\d+"#, options: .regularExpression) { dev = String(dev[r]) }
			if map[dev] == nil || on == "/" { map[dev] = on }
		}
		return map
	}

	static func purgeable(_ path: String) -> UInt64? {
		let keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
		guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
		      let important = v.volumeAvailableCapacityForImportantUsage, let plain = v.volumeAvailableCapacity
		else { return nil }
		return UInt64(max(0, important - Int64(plain)))
	}

	static func snapshots(_ device: String) -> [String] {
		guard let data = run("/usr/sbin/diskutil", ["apfs", "listSnapshots", device, "-plist"]),
		      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
		      let list = plist["Snapshots"] as? [[String: Any]] else { return [] }
		return list.compactMap { $0["SnapshotName"] as? String }
	}

	static func others(boot: APFSContainer?) -> [OtherVolume] {
		var buf: UnsafeMutablePointer<statfs>?
		let n = getmntinfo(&buf, MNT_NOWAIT)
		guard n > 0, let buf else { return [] }
		let mine = Set(boot?.volumes.compactMap(\.mount) ?? [])
		var out: [OtherVolume] = []
		for i in 0..<Int(n) {
			var s = buf[i]
			let on = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			let type = withUnsafeBytes(of: &s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
			guard s.f_flags & UInt32(MNT_LOCAL) != 0, from.hasPrefix("/dev/disk"), on.hasPrefix("/Volumes/"),
			      !mine.contains(on), s.f_flags & UInt32(MNT_DONTBROWSE) == 0 else { continue }
			let url = URL(fileURLWithPath: on)
			let v = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsInternalKey])
			let size = UInt64(s.f_blocks) * UInt64(s.f_bsize)
			let free = UInt64(s.f_bavail) * UInt64(s.f_bsize)
			out.append(OtherVolume(device: String(from.dropFirst(5)), mount: on, name: v?.volumeLocalizedName ?? url.lastPathComponent,
			                       uuid: v?.volumeUUIDString ?? "", type: type, size: size, free: free,
			                       isInternal: v?.volumeIsInternal ?? false))
		}
		return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
	}

	static func run(_ tool: String, _ args: [String]) -> Data? {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: tool)
		p.arguments = args
		let out = Pipe()
		p.standardOutput = out
		p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { return nil }
		let data = out.fileHandleForReading.readDataToEndOfFile()
		p.waitUntilExit()
		return p.terminationStatus == 0 ? data : nil
	}
}

final class DiskScan: @unchecked Sendable {
	private(set) var container: APFSContainer
	private(set) var scans: [String: VolumeScan] = [:]
	let firmlinks: [String: String]
	private(set) var purgeable: UInt64

	static func views(for role: String) -> Set<String> {
		role == "Preboot" ? ["Cryptexes"] : []
	}

	init(container: APFSContainer) {
		self.container = container
		var links: [String: String] = [:]
		if let text = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8) {
			for line in text.split(separator: "\n") {
				let parts = line.split(separator: "\t")
				if parts.count == 2 { links[String(parts[0])] = String(parts[1]) }
			}
		}
		firmlinks = links
		purgeable = Disks.purgeable("/") ?? 0
	}

	func run(progress: ((APFSVolume, VolumeScan) -> Void)? = nil) {
		for v in container.volumes.sorted(by: { $0.inUse < $1.inUse }) {
			guard let mount = v.mount, let scan = try? VolumeScan(root: mount, views: Self.views(for: v.role)) else { continue }
			scan.run()
			scans[v.device] = scan
			progress?(v, scan)
		}
	}

	func adopt(_ scan: VolumeScan, for device: String) { scans[device] = scan }

	private init(container: APFSContainer, firmlinks: [String: String], purgeable: UInt64, scans: [String: VolumeScan]) {
		self.container = container; self.firmlinks = firmlinks; self.purgeable = purgeable; self.scans = scans
	}

	func copy() -> DiskScan { DiskScan(container: container, firmlinks: firmlinks, purgeable: purgeable, scans: scans) }

	func refreshNumbers() {
		if let c = Disks.containers().first(where: { $0.device == container.device }) { container = c }
		purgeable = Disks.purgeable("/") ?? purgeable
	}

	var dataVolume: APFSVolume? { container.volumes.first { $0.role == "Data" } }
	var systemVolume: APFSVolume? { container.volumes.first { $0.role == "System" } }

	struct Account {
		let volume: APFSVolume
		let files: UInt64?
		var unexplained: Int64 { Int64(volume.inUse) - Int64(files ?? 0) }
	}

	var accounts: [Account] {
		container.volumes.map { v in Account(volume: v, files: scans[v.device].map { $0.total[0] }) }
	}

	func logicalPath(_ scan: VolumeScan, _ i: Int) -> String {
		guard let data = dataVolume.flatMap({ scans[$0.device] }), scan === data else { return scan.path(i) }
		let rel = scan.relativePath(i)
		for (link, target) in firmlinks.sorted(by: { $0.value.count > $1.value.count })
		where rel == target || rel.hasPrefix(target + "/") {
			return link + rel.dropFirst(target.count)
		}
		return scan.path(i)
	}

	func locate(_ logical: String) -> (VolumeScan, Int)? {
		let path = logical.count > 1 && logical.hasSuffix("/") ? String(logical.dropLast()) : logical
		var best: (String, VolumeScan)?
		for v in container.volumes {
			guard let m = v.mount, m != "/", let s = scans[v.device] else { continue }
			if path == m || path.hasPrefix(m + "/"), m.count > (best?.0.count ?? 0) { best = (m, s) }
		}
		if let (m, s) = best {
			return s.find(String(path.dropFirst(m.count))).map { (s, $0) }
		}
		if let data = dataVolume.flatMap({ scans[$0.device] }) {
			for (link, target) in firmlinks.sorted(by: { $0.key.count > $1.key.count })
			where path == link || path.hasPrefix(link + "/") {
				return data.find(target + path.dropFirst(link.count)).map { (data, $0) }
			}
		}
		guard let sys = systemVolume.flatMap({ scans[$0.device] }) else { return nil }
		return sys.find(String(path.dropFirst())).map { (sys, $0) }
	}
}
