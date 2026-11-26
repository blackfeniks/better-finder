import Darwin
import Foundation

struct FileEntry: Sendable, Identifiable {
	var id: String { name }
	let name: String
	let bytes: UInt64
	let size: UInt64
	let mtime: Int64
	let isLink: Bool
	let hidden: Bool
	let note: Note?

	enum Note: Sendable {
		case hardLink(carrier: String)
		case clone(shared: UInt64, carrier: String?)
		case cloud
		case purgeable
	}
}

struct Listing: Sendable {
	let node: Node
	let files: [FileEntry]
	let error: Int32

	static func read(_ node: Node, tree: Tree) -> Listing {
		guard let scan = tree.scan(node.volume), Int(node.dir) < scan.count else { return Listing(node: node, files: [], error: ENOENT) }
		let dir = Int(node.dir)
		let path = scan.path(dir)
		let rel = scan.relativePath(dir)
		let inView = isInView(scan, dir)
		let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else { return Listing(node: node, files: [], error: errno) }
		defer { close(fd) }
		var files: [FileEntry] = []
		let reader = BulkReader()
		let err = reader.read(fd: fd) { e in
			guard !e.isDir else { return }
			let me = rel.isEmpty ? e.name : rel + "/" + e.name
			var counted = e.alloc
			var note: FileEntry.Note?
			if inView {
			} else if e.links > 1 && e.isFile {
				if let owner = scan.hardLinks.owner(e.fileID), owner != me {
					counted = 0
					note = .hardLink(carrier: owner)
				}
			} else if counted > 0 && e.mayShareBlocks, let priv = e.privateSize, priv < counted {
				let owner = scan.clones.owner(e.cloneID)
				if owner != me {
					note = .clone(shared: counted - priv, carrier: owner)
					counted = priv
				}
			}
			if note == nil {
				if e.isDataless { note = .cloud } else if e.isPurgeable { note = .purgeable }
			}
			files.append(FileEntry(name: e.name, bytes: counted, size: e.size, mtime: e.mtime, isLink: e.isLink,
			                       hidden: e.flags & UInt32(UF_HIDDEN) != 0 || e.name.hasPrefix("."), note: note))
		}
		files.sort { ($0.bytes, $0.size) > ($1.bytes, $1.size) }
		return Listing(node: node, files: files, error: err)
	}

	private static func isInView(_ s: VolumeScan, _ i: Int) -> Bool {
		var j = i
		while j >= 0 { if s.flags[j].contains(.view) { return true }; j = Int(s.parents[j]) }
		return false
	}
}
