import AppKit
import Foundation

enum Place: Hashable, Sendable {
	case overview
	case group(Category)
	case item(String)
	case folder(Node)
}

struct Step: Hashable, Sendable {
	let place: Place
	let via: String?
	var path: String? = nil
	var generation: Int? = nil
}

struct Piece: Sendable {
	enum Kind: Sendable { case normal, files, more, free, hidden, view }

	let key: String
	let ring: Int
	var a0: Double
	var a1: Double
	let tone: Double
	let kind: Kind
	let name: String
	let bytes: UInt64
	let detail: String
	let parent: String?
	let open: Place?
	let otherDisk: String?
	let row: String?
}

struct RingContent: Sendable {
	let place: Place
	let pieces: [Piece]
	let labelRing: Int
	let title: String
	let size: String
	let sub: String
	let whole: UInt64
	let wholeName: String
	let pieceOfRow: [String: String]
	var rotation: Double = 0
	var bytes: UInt64? = nil

	static let empty = RingContent(place: .overview, pieces: [], labelRing: 1, title: "", size: "", sub: "",
	                               whole: 1, wholeName: "", pieceOfRow: [:])
}

struct Row: Identifiable, Sendable {
	enum Icon: Sendable {
		case file(String)
		case symbol(String)
	}
	let id: String
	let icon: Icon
	let name: String
	let detail: String
	let bytes: UInt64
	let share: String
	let open: Place?
	let otherDisk: String?
	let paths: [String]
	let dim: Bool
	let canTrash: Bool
}

struct PanelContent: Sendable {
	let back: (label: String, depth: Int)?
	let title: String
	let icon: Row.Icon?
	let meta: String
	let kinds: [(String, UInt64)]
	let rows: [Row]
	let footnote: String?
	let paths: [String]
	let trashTitle: String?
	let canTrash: Bool
	var closed = false
	var isTrash = false
	var isFolder = false
}

enum Content {
	static let minOuter = 0.024
	static let minInner = 0.012

	static func ring(_ s: Snapshot, _ place: Place, rotation: Double? = nil) -> RingContent {
		var b = RingContent.empty
		switch place {
		case .overview: b = overview(s, rotation)
		case .group(let g): b = group(s, g, rotation)
		case .item(let id): b = item(s, id, rotation)
		case .folder(let n): b = folder(s, n, rotation)
		}
		return b
	}

	static var trashPath: String { NSHomeDirectory() + "/.Trash" }

	static func overview(_ s: Snapshot, _ rotation: Double?) -> RingContent {
		let c = s.container
		var b = Builder(whole: c.size)
		for (k, (g, items)) in orderedGroups(s).enumerated() {
			let total = s.meaning.total(g)
			let tone = toneOf(g, k)
			let key = "g:\(g.rawValue)"
			if g == .trash, let n = s.tree.locate(trashPath) {
				b.inner(Piece(key: key, ring: 1, a0: 0, a1: 0, tone: tone, kind: .normal, name: g.title, bytes: total,
				              detail: "Deleted, still taking space until the Trash is emptied", parent: nil, open: .folder(n),
				              otherDisk: nil, row: key), keep: true)
				b.outer(of: key, tone: tone, folderOuter(s, n, parent: key), parentOpen: .folder(n))
				continue
			}
			b.inner(Piece(key: key, ring: 1, a0: 0, a1: 0, tone: tone, kind: g == .hidden ? .hidden : .normal,
			              name: g.title, bytes: total, detail: topNames(items), parent: nil, open: .group(g),
			              otherDisk: nil, row: key))
			b.outer(of: key, tone: tone, items.map { it in
				Piece(key: "i:\(it.id)", ring: 2, a0: 0, a1: 0, tone: 0, kind: g == .hidden ? .hidden : .normal,
				      name: it.name, bytes: it.bytes, detail: it.detail, parent: key, open: g == .hidden ? nil : .item(it.id),
				      otherDisk: nil, row: key)
			}, parentOpen: .group(g))
		}
		b.free(c.free)
		return b.done(place: .overview, title: "Macintosh HD", size: Fmt.size(c.used), sub: "used of \(Fmt.size(c.size))",
		              whole: c.used, wholeName: "used", bytes: c.used, rotation: rotation)
	}

	static func folderOuter(_ s: Snapshot, _ n: Node, parent: String) -> [Piece] {
		let t = s.tree
		var out: [Piece] = t.entries(n).filter { $0.bytes > 0 }.map { g in
			Piece(key: entryKey(g), ring: 2, a0: 0, a1: 0, tone: 0, kind: .normal, name: g.name, bytes: g.bytes,
			      detail: Fmt.home(g.node.map(t.path) ?? ""), parent: parent, open: .folder(n), otherDisk: nil, row: parent)
		}
		let own = t.ownBytes(n)
		if own > 0 {
			out.append(Piece(key: "files:\(n.volume):\(n.dir)", ring: 2, a0: 0, a1: 0, tone: 0, kind: .files,
			                 name: "Files in \(t.name(n))", bytes: own, detail: Fmt.plural(Int(t.ownFiles(n)), "file"),
			                 parent: parent, open: .folder(n), otherDisk: nil, row: parent))
		}
		return out.sorted { $0.bytes > $1.bytes }
	}

	static func orderedGroups(_ s: Snapshot) -> [(Category, [Item])] {
		let list = s.meaning.groups.filter { !$0.1.isEmpty && ($0.0 != .trash || s.meaning.total(.trash) > 0) }
		let sorted = list.filter { $0.0 != .hidden && $0.0 != .trash }.sorted { s.meaning.total($0.0) > s.meaning.total($1.0) }
		return sorted + list.filter { $0.0 == .trash } + list.filter { $0.0 == .hidden }
	}

	static func toneOf(_ g: Category, _ index: Int) -> Double {
		switch g {
		case .hidden: 0.34
		case .trash: 0.52
		case .other: 0.46
		default: index % 2 == 0 ? 0.95 : 0.64
		}
	}

	static func topNames(_ items: [Item]) -> String {
		items.prefix(3).map(\.name).joined(separator: ", ")
	}

	static func group(_ s: Snapshot, _ g: Category, _ rotation: Double?) -> RingContent {
		let items = s.meaning.groups.first { $0.0 == g }?.1 ?? []
		let total = s.meaning.total(g)
		var b = Builder(whole: total)
		for (k, it) in items.enumerated() {
			let key = "i:\(it.id)"
			let tone = k % 2 == 0 ? 0.95 : 0.64
			b.inner(Piece(key: key, ring: 1, a0: 0, a1: 0, tone: tone, kind: g == .hidden ? .hidden : .normal,
			              name: it.name, bytes: it.bytes, detail: it.detail, parent: nil, open: g == .hidden ? nil : .item(it.id),
			              otherDisk: nil, row: key))
			b.outer(of: key, tone: tone, it.parts.filter { $0.bytes > 0 }.map { p in
				Piece(key: "p:\(it.id)|\(p.path)", ring: 2, a0: 0, a1: 0, tone: 0, kind: .normal, name: p.label,
				      bytes: p.bytes, detail: Fmt.home(p.path), parent: key, open: g == .hidden ? nil : .item(it.id),
				      otherDisk: nil, row: key)
			}, parentOpen: g == .hidden ? nil : .item(it.id))
		}
		return b.done(place: .group(g), title: g.title, size: Fmt.size(total),
		              sub: Fmt.share(total, of: s.container.used) + " of used", whole: total, wholeName: g.title,
		              bytes: total, rotation: rotation)
	}

	static func item(_ s: Snapshot, _ id: String, _ rotation: Double?) -> RingContent {
		guard let it = s.meaning.item(id: id) else { return .empty }
		var b = Builder(whole: max(it.bytes, 1))
		let parts = it.parts.filter { $0.bytes > 0 }
		for (k, p) in parts.enumerated() {
			let node = s.tree.locate(p.path)
			let key = "p:\(it.id)|\(p.path)"
			b.inner(Piece(key: key, ring: 3, a0: 0, a1: 0, tone: k % 2 == 0 ? 0.95 : 0.62, kind: .normal, name: p.label,
			              bytes: p.bytes, detail: Fmt.home(p.path), parent: nil, open: node.map { .folder($0) },
			              otherDisk: nil, row: key), min: minOuter)
		}
		let places = parts.count
		return b.done(place: .item(id), title: it.name, size: Fmt.size(it.bytes),
		              sub: places > 1 ? "in \(places) places" : Fmt.home(it.detail), whole: it.bytes, wholeName: it.name,
		              labelRing: 3, bytes: it.bytes, rotation: rotation)
	}

	static func folder(_ s: Snapshot, _ n: Node, _ rotation: Double?) -> RingContent {
		let t = s.tree
		let isBootRoot = n == t.bootRoot
		let other = n.dir == 0 ? s.others[n.volume] : nil
		let size = t.size(n)
		let whole: UInt64 = isBootRoot ? s.container.size : other.map { $0.info.size } ?? size
		var b = Builder(whole: max(whole, 1))
		var k = 0
		for e in t.entries(n) where e.bytes > 0 {
			let key = entryKey(e)
			let tone = k % 2 == 0 ? 0.95 : 0.64
			k += 1
			let owner = e.note == nil ? e.node.flatMap { ownerName(s, $0, parent: n) } : nil
			b.inner(Piece(key: key, ring: 1, a0: 0, a1: 0, tone: tone, kind: e.note == .view ? .view : .normal, name: e.name,
			              bytes: e.bytes, detail: owner ?? entryDetail(s, e), parent: nil, open: e.node.map { .folder($0) },
			              otherDisk: nil, row: key))
			guard let child = e.node else { continue }
			var outer: [Piece] = t.entries(child).filter { $0.bytes > 0 }.map { g in
				Piece(key: entryKey(g), ring: 2, a0: 0, a1: 0, tone: 0, kind: .normal, name: g.name, bytes: g.bytes,
				      detail: Fmt.home(g.node.map(t.path) ?? ""), parent: key, open: e.node.map { .folder($0) },
				      otherDisk: nil, row: key)
			}
			let own = t.ownBytes(child)
			if own > 0 {
				outer.append(Piece(key: "files:\(child.volume):\(child.dir)", ring: 2, a0: 0, a1: 0, tone: 0, kind: .files,
				                   name: "Files in \(e.name)", bytes: own, detail: Fmt.plural(Int(t.ownFiles(child)), "file"),
				                   parent: key, open: .folder(child), otherDisk: nil, row: key))
			}
			b.outer(of: key, tone: tone, outer.sorted { $0.bytes > $1.bytes }, parentOpen: e.node.map { .folder($0) })
		}
		let own = t.ownBytes(n)
		if own > 0 {
			let key = "files:\(n.volume):\(n.dir)"
			b.inner(Piece(key: key, ring: 1, a0: 0, a1: 0, tone: 0.5, kind: .files, name: "Files here", bytes: own,
			              detail: Fmt.plural(Int(t.ownFiles(n)), "file") + " directly in this folder", parent: nil, open: nil,
			              otherDisk: nil, row: key))
		}
		if isBootRoot {
			let hidden = s.notVisible
			if hidden > 0 {
				b.inner(Piece(key: "hidden", ring: 1, a0: 0, a1: 0, tone: 0.34, kind: .hidden, name: "Not visible as files",
				              bytes: hidden, detail: "Closed system folders, file-system bookkeeping", parent: nil,
				              open: .group(.hidden), otherDisk: nil, row: "hidden"))
			}
			b.free(s.container.free)
			return b.done(place: .folder(n), title: "Macintosh HD", size: Fmt.size(s.container.used),
			              sub: "used of \(Fmt.size(s.container.size))", whole: s.container.used, wholeName: "used",
			              bytes: s.container.used, rotation: rotation)
		}
		if let other {
			let used = other.info.used
			let seen = t.size(n)
			if used > seen {
				b.inner(Piece(key: "hidden", ring: 1, a0: 0, a1: 0, tone: 0.34, kind: .hidden, name: "Not visible as files",
				              bytes: used - seen, detail: "Closed folders, file-system bookkeeping", parent: nil, open: nil,
				              otherDisk: nil, row: "hidden"))
			}
			b.free(other.info.free)
			return b.done(place: .folder(n), title: other.info.name, size: Fmt.size(used),
			              sub: "used of \(Fmt.size(other.info.size))", whole: used, wholeName: "used",
			              bytes: used, rotation: rotation)
		}
		return b.done(place: .folder(n), title: t.name(n), size: Fmt.size(size),
		              sub: Fmt.plural(Int(t.files(n)), "file"), whole: size, wholeName: t.name(n), bytes: size,
		              rotation: rotation)
	}

	static func entryKey(_ e: Tree.Entry) -> String {
		let n = e.node ?? e.at
		return "n:\(n.volume):\(n.dir)"
	}

	static func entryDetail(_ s: Snapshot, _ e: Tree.Entry) -> String {
		if let known = Explain.known(e.name) { return known }
		switch e.note {
		case .overlap: return "The Data volume again — only what /Users, /Applications … don’t show is counted here"
		case .closed: return "Closed to Better Finder"
		case .view: return "Inside a system image, counted where the image is"
		case .cloud: return "In iCloud only — takes no space here"
		case .notWalked: return "Another disk or volume — not part of these numbers"
		case nil: return e.node.map { Fmt.home(s.tree.path($0)) } ?? ""
		}
	}

	static func panel(_ s: Snapshot, _ steps: [Step], listing: Listing?, mounts: [String: String] = [:]) -> PanelContent {
		let place = steps.last?.place ?? .overview
		let back: (String, Int)? = steps.count > 1 ? (title(s, steps[steps.count - 2].place), steps.count - 2) : nil
		switch place {
		case .overview:
			let c = s.container
			let trash = s.tree.locate(trashPath)
			let rows = orderedGroups(s).enumerated().map { k, gi -> Row in
				let (g, items) = gi
				let total = s.meaning.total(g)
				let detail = g == .hidden ? "Closed system folders, file-system bookkeeping"
					: g == .trash ? "Deleted, still taking space until emptied" : topNames(items)
				return Row(id: "g:\(g.rawValue)", icon: .symbol(g.symbol), name: g.title, detail: detail,
				           bytes: total, share: Fmt.share(total, of: c.used),
				           open: g == .trash ? trash.map { .folder($0) } : .group(g), otherDisk: nil, paths: [],
				           dim: false, canTrash: false)
			}
			return PanelContent(back: back, title: "By meaning", icon: nil,
			                    meta: "\(Fmt.size(c.used)) used · \(Fmt.size(c.free)) free of \(Fmt.size(c.size))",
			                    kinds: [], rows: rows, footnote: nil, paths: [], trashTitle: nil, canTrash: false)

		case .group(let g):
			let items = s.meaning.groups.first { $0.0 == g }?.1 ?? []
			let total = s.meaning.total(g)
			let rows = items.enumerated().map { k, it -> Row in
				let paths = it.parts.map(\.path)
				return Row(id: "i:\(it.id)", icon: itemIcon(it),
				           name: it.name, detail: itemDetail(it), bytes: it.bytes, share: Fmt.share(it.bytes, of: total),
				           open: g == .hidden ? nil : .item(it.id), otherDisk: nil, paths: g == .hidden ? [] : paths, dim: false,
				           canTrash: Safety.canTrash(item: it, s))
			}
			return PanelContent(back: back, title: g.title, icon: nil,
			                    meta: "\(Fmt.size(total)) · \(Fmt.share(total, of: s.container.used)) of used · \(Fmt.plural(items.count, "item"))",
			                    kinds: [], rows: rows, footnote: g == .hidden ? hiddenNote(s) : nil, paths: [], trashTitle: nil, canTrash: false,
			                    closed: g == .hidden)

		case .item(let id):
			guard let it = s.meaning.item(id: id) else { return emptyPanel(back) }
			let parts = it.parts.filter { $0.bytes > 0 }
			let rows = parts.enumerated().map { k, p -> Row in
				Row(id: "p:\(it.id)|\(p.path)", icon: .file(p.path), name: p.label, detail: Fmt.home(p.path), bytes: p.bytes,
				    share: Fmt.share(p.bytes, of: it.bytes), open: s.tree.locate(p.path).map { .folder($0) }, otherDisk: nil,
				    paths: [p.path], dim: false, canTrash: Safety.canTrash(path: p.path, s))
			}
			let kinds = it.kinds.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key.title, $0.value) }
			let n = parts.count
			let meta = [Fmt.size(it.bytes), n > 1 ? "in \(n) places" : nil, Fmt.plural(Int(it.files), "file"), it.group.title]
				.compactMap { $0 }.joined(separator: " · ")
			return PanelContent(back: back, title: it.name, icon: it.bundle.map { .file($0) }, meta: meta, kinds: kinds, rows: rows,
			                    footnote: nil, paths: parts.map(\.path),
			                    trashTitle: it.group == .apps || it.group == .games || it.group == .messages ? "Remove \(it.name) and its data…" : "Move to Trash…",
			                    canTrash: Safety.canTrash(item: it, s))

		case .folder(let n):
			return folderPanel(s, n, back: back, listing: listing, mounts: mounts)
		}
	}

	static func itemIcon(_ it: Item) -> Row.Icon {
		if let b = it.bundle { return .file(b) }
		let parts = it.parts.filter { $0.bytes > 0 }
		if parts.count == 1, it.group != .macOS, it.group != .hidden, !parts[0].path.hasPrefix("/private/var/folders") {
			return .file(parts[0].path)
		}
		return .symbol(it.group.symbol)
	}

	static func itemDetail(_ it: Item) -> String {
		let d = itemPlace(it)
		return d == it.name ? "" : d
	}

	static func itemPlace(_ it: Item) -> String {
		let n = it.parts.filter { $0.bytes > 0 }.count
		if n > 1 { return "\(Fmt.home(it.detail.isEmpty ? it.parts.first?.path ?? "" : it.detail)) · \(n) places" }
		return Fmt.home(it.detail.isEmpty ? it.parts.first?.path ?? "" : it.detail)
	}

	static func hiddenNote(_ s: Snapshot) -> String {
		"APFS says this much is used, but no file Better Finder can open adds up to it: folders macOS keeps closed, and the file system’s own bookkeeping."
	}

	static func emptyPanel(_ back: (String, Int)?) -> PanelContent {
		PanelContent(back: back, title: "Gone", icon: nil, meta: "It is no longer on the disk", kinds: [], rows: [], footnote: nil,
		             paths: [], trashTitle: nil, canTrash: false)
	}

	static let fileLimit = 2000

	static func folderPanel(_ s: Snapshot, _ n: Node, back: (String, Int)?, listing: Listing?, mounts: [String: String]) -> PanelContent {
		let t = s.tree
		let isBootRoot = n == t.bootRoot
		let total = t.size(n)
		let path = t.path(n)
		let isTrash = path == trashPath
		let mount = Safety.mountPoint(path)
		var rows: [Row] = []
		for e in t.entries(n) {
			let key = entryKey(e)
			let p = e.node.map(t.path) ?? (path == "/" ? "/" + e.name : path + "/" + e.name)
			var detail = entryDetail(s, e)
			if e.note == nil, let node = e.node, let owner = ownerName(s, node, parent: n) { detail = owner }
			if e.note == nil, e.node != nil, detail == Fmt.home(p) { detail = e.files > 0 ? Fmt.plural(Int(e.files), "file") : "Empty" }
			let otherDisk = e.note == .notWalked ? mounts[p] : nil
			rows.append(Row(id: key, icon: .file(e.node.map(t.realPath) ?? p), name: e.name, detail: detail, bytes: e.bytes,
			                share: Fmt.share(e.bytes, of: total), open: e.node.map { .folder($0) }, otherDisk: otherDisk,
			                paths: [p], dim: e.bytes == 0 || e.hidden, canTrash: Safety.canTrash(path: p, s)))
		}
		var footnote: String?
		var closed = false
		if let listing, listing.node == n {
			if listing.error == EACCES || listing.error == EPERM {
				footnote = t.flags(n).contains(.denied) ? "macOS keeps this folder closed to Better Finder."
					: "Read with admin rights; listing its files needs them too."
				closed = t.flags(n).contains(.denied)
			}
			let shown = listing.files.prefix(fileLimit)
			for f in shown {
				let p = path == "/" ? "/" + f.name : path + "/" + f.name
				let detail = Explain.known(f.name).map { Fmt.date(f.mtime) + " · " + $0 } ?? fileDetail(f)
				rows.append(Row(id: "f:\(n.volume):\(n.dir):\(f.name)", icon: .file(p), name: f.name, detail: detail,
				                bytes: f.bytes, share: Fmt.share(f.bytes, of: total), open: nil, otherDisk: nil, paths: [p],
				                dim: f.hidden || f.bytes == 0, canTrash: Safety.canTrash(path: p, s, mount: mount)))
			}
			if listing.files.count > fileLimit {
				let rest = listing.files.dropFirst(fileLimit)
				let bytes = rest.reduce(UInt64(0)) { $0 + $1.bytes }
				rows.append(Row(id: "f:more", icon: .symbol("ellipsis"), name: "\(Fmt.count(UInt64(rest.count))) smaller files",
				                detail: "Open the folder in Finder to see them all", bytes: bytes, share: Fmt.share(bytes, of: total),
				                open: nil, otherDisk: nil, paths: [], dim: true, canTrash: false))
			}
		} else if t.ownBytes(n) > 0 {
			rows.append(Row(id: "files:\(n.volume):\(n.dir)", icon: .symbol("doc.on.doc"), name: "Files here",
			                detail: "Reading…", bytes: t.ownBytes(n), share: Fmt.share(t.ownBytes(n), of: total), open: nil,
			                otherDisk: nil, paths: [], dim: true, canTrash: false))
		}
		if isBootRoot, s.notVisible > 0 {
			rows.append(Row(id: "hidden", icon: .symbol(Category.hidden.symbol), name: "Not visible as files",
			                detail: "Closed system folders, file-system bookkeeping", bytes: s.notVisible,
			                share: Fmt.share(s.notVisible, of: s.container.used), open: .group(.hidden), otherDisk: nil, paths: [],
			                dim: false, canTrash: false))
		}
		rows.sort { $0.bytes > $1.bytes }
		let name = isBootRoot ? "Macintosh HD" : t.name(n)
		var meta = [Fmt.size(total), Fmt.plural(Int(t.files(n)), "file")]
		if !isBootRoot && n.dir != 0 { meta.append(Fmt.home(path)) }
		if isBootRoot { meta = ["\(Fmt.size(s.container.used)) used", "\(Fmt.size(s.container.free)) free of \(Fmt.size(s.container.size))"] }
		if s.walking.contains(n.volume) { meta = ["Reading the disk…"] }
		return PanelContent(back: back, title: isTrash ? "Trash" : name, icon: isTrash ? .symbol("trash") : .file(t.realPath(n)),
		                    meta: meta.joined(separator: " · "), kinds: [],
		                    rows: rows, footnote: footnote, paths: [path], trashTitle: "Move to Trash…",
		                    canTrash: Safety.canTrash(path: path, s), closed: closed, isTrash: isTrash, isFolder: true)
	}

	static func ownerName(_ s: Snapshot, _ n: Node, parent: Node) -> String? {
		guard let scan = s.tree.scan(n.volume), let owner = s.meaning.owner(scan, Int(n.dir)) else { return nil }
		if let pscan = s.tree.scan(parent.volume), let p = s.meaning.owner(pscan, Int(parent.dir)), p === owner { return nil }
		if owner.group == .other || owner.id == "apps:other" { return nil }
		return owner.group == .projects ? "Project" : owner.name
	}

	static func fileDetail(_ f: FileEntry) -> String {
		var parts: [String] = [Fmt.date(f.mtime)]
		switch f.note {
		case .hardLink(let carrier)?: parts.append("hard link — counted at \(carrier)")
		case .clone(let shared, let carrier)?:
			parts.append("APFS copy: \(Fmt.size(shared)) shared" + (carrier.map { " with \(($0 as NSString).lastPathComponent)" } ?? ""))
		case .cloud?: parts.append("in iCloud only")
		case .purgeable?: parts.append("macOS may remove it when space runs low")
		case nil: if f.size > f.bytes * 2 && f.size > 1_000_000 { parts.append("\(Fmt.size(f.size)) long, sparse") }
		}
		if f.isLink { parts.append("link") }
		return parts.joined(separator: " · ")
	}

	static func title(_ s: Snapshot, _ p: Place) -> String {
		switch p {
		case .overview: "Macintosh HD"
		case .group(let g): g.title
		case .item(let id): s.meaning.item(id: id)?.name ?? "Gone"
		case .folder(let n): n == s.tree.bootRoot ? "Macintosh HD" : s.tree.name(n)
		}
	}
}

struct Builder {
	let whole: UInt64
	private var at = 0.0
	private var pieces: [Piece] = []
	private var pending: [Piece] = []
	private var rowMap: [String: String] = [:]

	init(whole: UInt64) { self.whole = max(whole, 1) }

	private func span(_ b: UInt64) -> Double { Double(b) / Double(whole) * 2 * .pi }

	mutating func inner(_ p: Piece, min: Double = Content.minInner, keep: Bool = false) {
		var p = p
		let s = span(p.bytes)
		if s < min && p.kind != .hidden && !keep {
			pending.append(p)
			return
		}
		p.a0 = at; p.a1 = at + s
		at += s
		pieces.append(p)
		if let r = p.row { rowMap[r] = rowMap[r] ?? p.key }
	}

	mutating func outer(of parent: String, tone: Double, _ list: [Piece], parentOpen: Place?) {
		guard let host = pieces.last(where: { $0.key == parent }) else { return }
		let total = list.reduce(UInt64(0)) { $0 + $1.bytes }
		guard total > 0 else { return }
		let width = host.a1 - host.a0
		let scale = Double(host.bytes) > 0 ? min(1, Double(total) / Double(host.bytes)) : 1
		var a = host.a0
		var rest: [Piece] = []
		var k = 0
		for p in list {
			let s = width * scale * Double(p.bytes) / Double(total)
			if s < Content.minOuter { rest.append(p); continue }
			var q = Piece(key: p.key, ring: p.ring, a0: a, a1: a + s, tone: tone * (k % 2 == 0 ? 0.80 : 0.50), kind: p.kind,
			              name: p.name, bytes: p.bytes, detail: p.detail, parent: parent, open: p.open, otherDisk: p.otherDisk,
			              row: p.row)
			if p.kind == .files { q = q.with(tone: tone * 0.42) }
			pieces.append(q)
			a += s
			k += 1
		}
		if !rest.isEmpty {
			let bytes = rest.reduce(UInt64(0)) { $0 + $1.bytes }
			let s = width * scale * Double(bytes) / Double(total)
			if s >= 0.004 {
				pieces.append(Piece(key: "more:\(parent)", ring: 2, a0: a, a1: a + s, tone: tone * 0.36, kind: .more,
				                    name: "\(rest.count) more", bytes: bytes, detail: rest.prefix(3).map(\.name).joined(separator: ", "),
				                    parent: parent, open: parentOpen, otherDisk: nil, row: host.row))
			}
		}
	}

	mutating func free(_ bytes: UInt64) {
		mergePending()
		let s = span(bytes)
		pieces.append(Piece(key: "free", ring: 1, a0: at, a1: min(2 * .pi, at + s), tone: 0.3, kind: .free, name: "Free",
		                    bytes: bytes, detail: "Free space on the disk", parent: nil, open: nil, otherDisk: nil, row: nil))
		at += s
	}

	private mutating func mergePending() {
		guard !pending.isEmpty else { return }
		let bytes = pending.reduce(UInt64(0)) { $0 + $1.bytes }
		let s = span(bytes)
		let ring = pending[0].ring
		let p = Piece(key: "more:inner", ring: ring, a0: at, a1: at + s, tone: 0.36, kind: .more,
		              name: "\(pending.count) more", bytes: bytes, detail: pending.prefix(3).map(\.name).joined(separator: ", "),
		              parent: nil, open: nil, otherDisk: nil, row: nil)
		for q in pending { if let r = q.row { rowMap[r] = p.key } }
		pending = []
		if s >= 0.002 { pieces.append(p); at += s }
	}

	mutating func done(place: Place, title: String, size: String, sub: String, whole: UInt64, wholeName: String,
	                   labelRing: Int = 1, bytes: UInt64? = nil, rotation: Double? = nil) -> RingContent {
		mergePending()
		let turn = rotation ?? Self.bestRotation(pieces, labelRing: labelRing)
		if turn != 0 { for i in pieces.indices { pieces[i].a0 += turn; pieces[i].a1 += turn } }
		return RingContent(place: place, pieces: pieces, labelRing: labelRing, title: title, size: size, sub: sub,
		                   whole: max(whole, 1), wholeName: wholeName, pieceOfRow: rowMap, rotation: turn, bytes: bytes)
	}

	static func bestRotation(_ pieces: [Piece], labelRing: Int) -> Double {
		let list = pieces.filter { ($0.ring == labelRing || ($0.kind == .free && labelRing == 1)) && $0.a1 - $0.a0 >= 0.045 }
		guard list.count > 3 else { return 0 }
		func score(_ turn: Double) -> Double {
			LabelPlacer.score(list.map { .init(key: $0.key, mid: ($0.a0 + $0.a1) / 2 + turn, priority: 0, weight: 1) })
		}
		var best = (score: score(0), turn: 0.0)
		if best.score >= Double(list.count) - 0.5 { return 0 }
		for k in 1...18 {
			for sign in [1.0, -1.0] where !(k == 18 && sign < 0) {
				let turn = sign * Double(k) * .pi / 18
				let sc = score(turn)
				if sc > best.score + 0.5 { best = (sc, turn) }
			}
		}
		return best.turn
	}
}

extension Piece {
	func with(tone: Double) -> Piece {
		Piece(key: key, ring: ring, a0: a0, a1: a1, tone: tone, kind: kind, name: name, bytes: bytes, detail: detail,
		      parent: parent, open: open, otherDisk: otherDisk, row: row)
	}
}

enum Safety {
	static func mountPoint(_ path: String) -> String? {
		var st = statfs()
		guard statfs(path, &st) == 0 else { return nil }
		return withUnsafeBytes(of: &st.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
	}

	static func canTrash(path: String, _ s: Snapshot, mount: String? = nil) -> Bool {
		let home = NSHomeDirectory()
		let p = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
		let parts = p.split(separator: "/").map(String.init)
		guard p.hasPrefix("/"), parts.count >= 2, !parts.contains(".."), !parts.contains(".") else { return false }
		if let on = mount ?? mountPoint(p) {
			if on == p { return false }
			let bootMounts = Set(s.container.volumes.compactMap(\.mount))
			if bootMounts.contains(on) && on != "/" && on != s.disk.dataVolume?.mount { return false }
		}
		let homeFixed: Set<String> = [home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads",
		                              home + "/Movies", home + "/Music", home + "/Pictures", home + "/Public",
		                              home + "/Applications", home + "/.Trash"]
		if homeFixed.contains(p) { return false }
		if p.hasPrefix(home + "/") {
			return (p as NSString).deletingLastPathComponent != home + "/Library"
		}
		switch parts[0] {
		case "Applications":
			return !(parts.count == 2 && parts[1] == "Utilities")
		case "Library":
			return parts.count >= 3 && ["Application Support", "Caches", "Logs", "Developer", "Audio"].contains(parts[1])
				&& !(parts[1] == "Application Support" && parts[2] == "Apple")
		case "private":
			return parts.count >= 7 && parts[1] == "var" && parts[2] == "folders" && ["C", "T"].contains(parts[5])
		case "opt", "usr":
			return parts.count >= 3 && (parts[0] == "opt" || parts[1] == "local") && !(parts[0] == "opt" && parts.count == 2)
				&& !(parts[0] == "usr" && parts.count == 2)
		case "cores":
			return parts.count == 2
		case "Volumes":
			return parts.count >= 3 && !bootVolumePath(p, s)
		default:
			return false
		}
	}

	private static func bootVolumePath(_ p: String, _ s: Snapshot) -> Bool {
		s.container.volumes.contains { v in v.mount.map { p == $0 || p.hasPrefix($0 + "/") && $0 != "/" } ?? false }
	}

	static func canTrash(item it: Item, _ s: Snapshot) -> Bool {
		guard ![.macOS, .hidden, .other].contains(it.group) || it.id.hasPrefix("other:~/") else { return false }
		if let b = it.bundle, b.hasPrefix("/System/") { return false }
		let parts = it.parts.filter { $0.bytes > 0 }
		guard !parts.isEmpty else { return false }
		for p in parts {
			guard canTrash(path: p.path, s) else { return false }
			if let (scan, dir) = s.disk.locate(p.path), s.meaning.hasOtherClaims(scan, dir, besides: it) { return false }
		}
		return true
	}
}
