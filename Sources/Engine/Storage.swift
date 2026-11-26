import Foundation
import IOKit

enum Storage: CustomStringConvertible {
	case ssd(external: Bool)
	case rotational
	case unknownExternal
	case network

	var threads: Int {
		switch self {
		case .ssd: max(8, ProcessInfo.processInfo.activeProcessorCount * 2)
		case .rotational, .unknownExternal: 4
		case .network: 16
		}
	}

	var description: String {
		switch self {
		case .ssd(let ext): ext ? "external SSD" : "internal SSD"
		case .rotational: "hard disk"
		case .unknownExternal: "external drive (type not reported, read as a hard disk)"
		case .network: "network volume"
		}
	}

	static func kind(of path: String) -> Storage {
		var s = statfs()
		guard statfs(path, &s) == 0 else { return .unknownExternal }
		let type = withUnsafeBytes(of: &s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
		if ["smbfs", "afpfs", "nfs", "webdav"].contains(type) { return .network }
		let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
		guard from.hasPrefix("/dev/") else { return .unknownExternal }
		var bsd = String(from.dropFirst(5))
		if let r = bsd.range(of: #"^disk\d+s\d+"#, options: .regularExpression) { bsd = String(bsd[r]) }
		return medium(bsd: bsd)
	}

	private static func medium(bsd: String) -> Storage {
		guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return .unknownExternal }
		let media = IOServiceGetMatchingService(kIOMainPortDefault, match)
		guard media != 0 else { return .unknownExternal }
		var entry = media
		IOObjectRetain(entry)
		defer { IOObjectRelease(media) }
		var mediumType: String?
		var external: Bool?
		for _ in 0..<40 {
			if mediumType == nil,
			   let dc = IORegistryEntryCreateCFProperty(entry, "Device Characteristics" as CFString, kCFAllocatorDefault, 0)?
				.takeRetainedValue() as? [String: Any] {
				mediumType = dc["Medium Type"] as? String
				if mediumType == nil { mediumType = "" }
			}
			if external == nil,
			   let pc = IORegistryEntryCreateCFProperty(entry, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
				.takeRetainedValue() as? [String: Any],
			   let location = pc["Physical Interconnect Location"] as? String {
				external = location != "Internal"
			}
			if mediumType != nil && external != nil { break }
			var parent: io_registry_entry_t = 0
			let r = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
			IOObjectRelease(entry)
			guard r == KERN_SUCCESS else { entry = 0; break }
			entry = parent
		}
		if entry != 0 { IOObjectRelease(entry) }
		switch mediumType {
		case "Solid State": return .ssd(external: external ?? false)
		case "Rotational": return .rotational
		default: return external == false ? .ssd(external: false) : .unknownExternal
		}
	}
}
