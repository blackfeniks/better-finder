import Darwin

struct BulkEntry {
	var name: String
	var type: UInt32
	var flags: UInt32
	var fileID: UInt64
	var mtime: Int64
	var links: UInt32 = 1
	var size: UInt64 = 0
	var alloc: UInt64 = 0
	var privateSize: UInt64? = nil
	var cloneID: UInt64 = 0
	var extFlags: UInt64 = 0

	var isDir: Bool { type == VDIR.rawValue }
	var isFile: Bool { type == VREG.rawValue }
	var isLink: Bool { type == VLNK.rawValue }
	var isDataless: Bool { flags & UInt32(SF_DATALESS) != 0 }
	var mayShareBlocks: Bool { extFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0 }
	var isPurgeable: Bool { extFlags & UInt64(EF_IS_PURGEABLE) != 0 }
}

func realDevice(_ fd: Int32) -> dev_t? {
	var list = attrlist()
	list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
	list.commonattr = attrgroup_t(ATTR_CMN_DEVID)
	var buffer = (UInt32(0), Int32(0))
	let r = withUnsafeMutableBytes(of: &buffer) {
		fgetattrlist(fd, &list, $0.baseAddress, $0.count, UInt32(FSOPT_RETURN_REALDEV))
	}
	return r == 0 ? buffer.1 : nil
}

enum BulkError: Error {
	case open(Int32)
	case read(Int32)
}

final class BulkReader {
	private var list = attrlist()
	private let buffer: UnsafeMutableRawPointer
	private let bufferSize = 256 * 1024
	private let options = UInt64(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)

	private static let common: attrgroup_t = attrgroup_t(bitPattern: Int32(bitPattern:
		UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_OBJTYPE)
			| UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_FLAGS) | UInt32(ATTR_CMN_FILEID)))
	private static let file: attrgroup_t = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
	private static let ext: attrgroup_t = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)

	init() {
		buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
		list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
		list.commonattr = Self.common
		list.fileattr = Self.file
		list.forkattr = Self.ext
	}

	deinit { buffer.deallocate() }

	func read(fd: Int32, _ body: (inout BulkEntry) -> Void) -> Int32 {
		while true {
			let count = getattrlistbulk(fd, &list, buffer, bufferSize, options)
			if count < 0 { return errno }
			if count == 0 { return 0 }
			var p = UnsafeRawPointer(buffer)
			for _ in 0..<count {
				let length = Int(p.loadUnaligned(as: UInt32.self))
				var entry = Self.parse(p)
				body(&entry)
				p += length
			}
		}
	}

	private static func parse(_ start: UnsafeRawPointer) -> BulkEntry {
		var p = start + 4
		let rCommon = p.loadUnaligned(as: UInt32.self)
		let rFile = (p + 12).loadUnaligned(as: UInt32.self)
		let rExt = (p + 16).loadUnaligned(as: UInt32.self)
		p += 20

		var e = BulkEntry(name: "", type: 0, flags: 0, fileID: 0, mtime: 0)
		if rCommon & UInt32(ATTR_CMN_NAME) != 0 {
			let offset = Int(p.loadUnaligned(as: Int32.self))
			e.name = String(cString: (p + offset).assumingMemoryBound(to: CChar.self))
			p += 8
		}
		if rCommon & UInt32(ATTR_CMN_OBJTYPE) != 0 { e.type = p.loadUnaligned(as: UInt32.self); p += 4 }
		if rCommon & UInt32(ATTR_CMN_MODTIME) != 0 { e.mtime = p.loadUnaligned(as: Int64.self); p += 16 }
		if rCommon & UInt32(ATTR_CMN_FLAGS) != 0 { e.flags = p.loadUnaligned(as: UInt32.self); p += 4 }
		if rCommon & UInt32(ATTR_CMN_FILEID) != 0 { e.fileID = p.loadUnaligned(as: UInt64.self); p += 8 }

		if rFile & UInt32(ATTR_FILE_LINKCOUNT) != 0 { e.links = p.loadUnaligned(as: UInt32.self); p += 4 }
		if rFile & UInt32(ATTR_FILE_TOTALSIZE) != 0 { e.size = UInt64(p.loadUnaligned(as: Int64.self)); p += 8 }
		if rFile & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { e.alloc = UInt64(p.loadUnaligned(as: Int64.self)); p += 8 }

		if rExt & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 { e.privateSize = UInt64(p.loadUnaligned(as: Int64.self)); p += 8 }
		if rExt & UInt32(ATTR_CMNEXT_CLONEID) != 0 { e.cloneID = p.loadUnaligned(as: UInt64.self); p += 8 }
		if rExt & UInt32(ATTR_CMNEXT_EXT_FLAGS) != 0 { e.extFlags = p.loadUnaligned(as: UInt64.self); p += 8 }
		return e
	}
}
