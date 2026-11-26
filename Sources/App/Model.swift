import AppKit
import Observation
import SwiftUI

enum Mode: Hashable { case meaning, folders }

struct Hover: Equatable {
	enum Source { case ring, list, bar }
	var piece: String?
	var row: String?
	var source: Source
	var group: Category?
}

struct TrashRequest: Identifiable {
	let id = UUID()
	let title: String
	let items: [(path: String, bytes: UInt64)]
	var clears: Set<String> = []
	var forever = false
	var emptyAfter = false
	var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

enum Sheet: Identifiable {
	case cleanup
	case trash(TrashRequest)
	case emptyTrash
	case password
	case claudeKey
	var id: String {
		switch self {
		case .cleanup: "cleanup"
		case .password: "password"
		case .trash(let r): r.id.uuidString
		case .emptyTrash: "empty"
		case .claudeKey: "claude-key"
		}
	}
}

struct Explanation: Equatable {
	enum State: Equatable {
		case asking
		case answer(String, cost: Double, saved: Bool)
		case failed(String, key: Bool)
	}
	let row: Row
	var state: State
	static func == (a: Explanation, b: Explanation) -> Bool { a.row.id == b.row.id && a.state == b.state }
}

struct Toast: Equatable {
	let id = UUID()
	let text: String
	var action: String?
	var run: (@MainActor () -> Void)?
	static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct Freed: Identifiable {
	enum Kind: String { case trash, empty, delete }
	let id: String
	let date: Date
	let kind: Kind
	var items: [(path: String, bytes: UInt64, now: String)]
	var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

@MainActor
@Observable
final class AppModel {
	let engine = Engine()

	private(set) var snap: Snapshot?
	private(set) var phase: Engine.Phase = .starting
	private(set) var disks: [OtherVolume] = []
	private(set) var disk: String?
	private(set) var mode: Mode = .meaning
	private var stacks: [String: [Step]] = [:]
	private var turns: [Place: Double] = [:]

	private(set) var ring = RingContent.empty
	private(set) var ringVersion = 0
	private(set) var ringTransition = RingView.Transition.none
	private(set) var panel: PanelContent?
	private(set) var listing: Listing?

	private(set) var hover: Hover?
	var sheet: Sheet?
	private(set) var toast: Toast?
	private(set) var otherProgress: [String: (files: Int, bytes: UInt64)] = [:]
	private var walkBegan: [String: Date] = [:]
	private var etaSmooth: [String: Double] = [:]
	private(set) var needsFullDiskAccess = false
	var fdaDismissed = false
	var fullScreen = false

	private(set) var selection: Set<String> = []
	private var anchor: String?
	private(set) var scrollTarget: String?

	private(set) var hasAdmin = false
	private(set) var adminStale = false
	private(set) var adminBusy = false
	private(set) var passwordChecking = false
	var passwordError: String?

	private var cleanupTicked: Set<String> = []
	private var cleanupUnticked: Set<String> = []
	private(set) var emptyTrashToo = false
	private(set) var emptying = false
	private(set) var freed: [Freed] = []

	private(set) var panelWidth: CGFloat = Theme.panelDefault

	private(set) var explanation: Explanation?
	private(set) var hasClaudeKey = false
	private var explainCache: [String: ExplainCache.Entry] = [:]
	private var explainTask: Task<Void, Never>?

	init(start: Bool = true) {
		engine.onSnapshot = { [weak self] s in self?.received(s) }
		engine.onPhase = { [weak self] p in self?.phase = p }
		engine.onOtherProgress = { [weak self] key, files, bytes in self?.progress(key, files, bytes) }
		engine.onAdmin = { [weak self] e in self?.admin(e) }
		loadSettings()
		freed = FreedLog.read()
		explainCache = ExplainCache.load()
		if start {
			hasClaudeKey = Claude.hasKey
			hasAdmin = Privileged.hasPassword
			engine.start()
			refreshDisks()
			needsFullDiskAccess = Self.checkFullDiskAccess()
			let nc = NSWorkspace.shared.notificationCenter
			for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
				nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
					MainActor.assumeIsolated { self?.refreshDisks() }
				}
			}
		}
	}

	func adopt(_ s: Snapshot) { received(s) }

	private func received(_ s: Snapshot) {
		let first = snap == nil
		let before = currentNode.flatMap { n in snap.map { ($0.tree.ownBytes(n), $0.tree.ownFiles(n)) } }
		snap = s
		trimStacks()
		refresh(first ? .reveal : .update)
		let after = currentNode.map { (s.tree.ownBytes($0), s.tree.ownFiles($0)) }
		if listing?.node != currentNode || before == nil || after == nil || before! != after! { loadListing() }
	}

	private func trimStacks() {
		guard let s = snap else { return }
		for (k, steps) in stacks {
			var keep: [Step] = []
			for var step in steps {
				var ok: Bool
				switch step.place {
				case .overview, .group: ok = true
				case .item(let id): ok = s.meaning.item(id: id) != nil
				case .folder(let n):
					if let g = step.generation, g != s.tree.generation(n.volume) {
						if let path = step.path, let found = s.tree.locate(path) {
							step = Step(place: .folder(found), via: step.via.map { _ in "n:\(found.volume):\(found.dir)" },
							            path: path, generation: s.tree.generation(found.volume))
							ok = true
						} else {
							ok = false
						}
					} else {
						ok = s.tree.isLive(n)
					}
				}
				if !ok { break }
				keep.append(step)
			}
			stacks[k] = keep.isEmpty ? nil : keep
		}
	}

	private func step(_ p: Place, via: String?) -> Step {
		guard case .folder(let n) = p, let s = snap else { return Step(place: p, via: via) }
		return Step(place: p, via: via, path: s.tree.path(n), generation: s.tree.generation(n.volume))
	}

	private var stackKey: String { (disk ?? "boot") + "|" + (mode == .meaning ? "m" : "f") }

	private var rootStep: Step? {
		guard let s = snap else { return nil }
		if let disk { return s.others[disk] != nil ? step(.folder(Node(volume: disk, dir: 0)), via: nil) : nil }
		if mode == .meaning { return Step(place: .overview, via: nil) }
		return s.tree.bootRoot.map { step(.folder($0), via: nil) }
	}

	var steps: [Step] {
		if let st = stacks[stackKey], !st.isEmpty { return st }
		return rootStep.map { [$0] } ?? []
	}

	var place: Place? { steps.last?.place }

	var canGoBack: Bool { steps.count > 1 }

	var crumbs: [(String, Int)] {
		guard let s = snap else { return [] }
		return steps.enumerated().map { (Content.title(s, $0.element.place), $0.offset) }
	}

	private func setSteps(_ list: [Step], _ t: RingView.Transition) {
		stacks[stackKey] = list
		placeChanged()
		refresh(t)
		loadListing()
	}

	private func placeChanged() {
		clearTask?.cancel()
		hover = nil
		selection = []
		anchor = nil
		closeExplanation()
	}

	private func refresh(_ t: RingView.Transition) {
		guard let s = snap, let place else {
			panel = nil
			ring = .empty
			ringVersion += 1
			return
		}
		ring = Content.ring(s, place, rotation: turns[place])
		turns[place] = ring.rotation
		ringTransition = t
		ringVersion += 1
		setPanel(Content.panel(s, steps, listing: listing?.node == currentNode ? listing : nil, mounts: mounts))
	}

	private func setPanel(_ p: PanelContent?) {
		panel = p
		guard !selection.isEmpty else { return }
		let ids = Set(p?.rows.map(\.id) ?? [])
		let kept = selection.intersection(ids)
		if kept != selection { selection = kept }
		if let a = anchor, !ids.contains(a) { anchor = nil }
	}

	private var currentNode: Node? { if case .folder(let n)? = place { return n } else { return nil } }

	func open(_ p: Place, via: String?) {
		guard place != p else { return }
		let t: RingView.Transition = via.map { k in ring.pieces.contains { $0.key == k } ? .zoomIn(k) : .fade } ?? .fade
		setSteps(steps + [step(p, via: via)], t)
	}

	func back() {
		guard steps.count > 1 else { return }
		pop(to: steps.count - 2)
	}

	func pop(to depth: Int) {
		let st = steps
		guard depth >= 0, depth < st.count - 1 else { return }
		let focus = st[depth + 1].via
		setSteps(Array(st.prefix(depth + 1)), focus.map { .zoomOut($0) } ?? .fade)
	}

	func setMode(_ m: Mode) {
		guard m != mode, disk == nil else { return }
		mode = m
		placeChanged()
		refresh(.fade)
		loadListing()
	}

	func selectDisk(_ key: String?) {
		guard key != disk else { return }
		disk = key
		placeChanged()
		if let key, let v = disks.first(where: { $0.device == key }), snap?.others[key] == nil {
			engine.open(v, key: key)
		}
		refresh(.fade)
		loadListing()
	}

	func showGroup(_ g: Category) {
		if disk != nil { disk = nil }
		mode = .meaning
		let base = [Step(place: .overview, via: nil)]
		let key = "g:\(g.rawValue)"
		let target: Place = g == .trash ? (trashNode.map { .folder($0) } ?? .group(g)) : .group(g)
		let t: RingView.Transition = place == .overview ? .zoomIn(key) : .fade
		setSteps(base + [step(target, via: key)], t)
	}

	private var trashNode: Node? { snap?.tree.locate(Content.trashPath) }

	func ringClicked(_ p: Piece) {
		if let d = p.otherDisk { return selectDisk(d) }
		guard let target = p.open else { return }
		if case .group(let g) = target, place != .overview { return showGroup(g) }
		let parent = p.parent.flatMap { k in ring.pieces.first { $0.key == k } }
		open(target, via: parent?.open == target ? parent!.key : p.key)
	}

	func activate(_ r: Row) {
		if let d = r.otherDisk { return selectDisk(d) }
		guard let target = r.open else {
			if r.id.hasPrefix("f:"), let p = r.paths.first { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
			return
		}
		if case .group(let g) = target, place != .overview { return showGroup(g) }
		open(target, via: ring.pieceOfRow[r.id] ?? r.id)
	}

	func escape() {
		if sheet != nil { sheet = nil }
		else if explanation != nil { closeExplanation() }
		else if !selection.isEmpty { selection = []; anchor = nil }
		else { back() }
	}

	private var listingTask: Task<Void, Never>?

	private func loadListing() {
		guard let s = snap, let n = currentNode else { return }
		listingTask?.cancel()
		let tree = s.tree
		listingTask = Task { [weak self] in
			let l = await Task.detached(priority: .userInitiated) { Listing.read(n, tree: tree) }.value
			guard let self, !Task.isCancelled, self.currentNode == n else { return }
			self.listing = l
			if let s = self.snap { self.setPanel(Content.panel(s, self.steps, listing: l, mounts: self.mounts)) }
		}
	}

	func loadListingNow() {
		guard let s = snap, let n = currentNode else { return }
		listing = Listing.read(n, tree: s.tree)
		setPanel(Content.panel(s, steps, listing: listing, mounts: mounts))
	}

	private var clearTask: Task<Void, Never>?

	private func light(_ h: Hover) {
		clearTask?.cancel()
		clearTask = nil
		if hover != h { hover = h }
	}

	private func unlight(_ source: Hover.Source) {
		guard hover?.source == source, clearTask == nil else { return }
		clearTask = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(110))
			guard !Task.isCancelled, let self else { return }
			self.clearTask = nil
			if self.hover?.source == source { self.hover = nil }
		}
	}

	func hoverRing(_ key: String?) {
		guard let key, let p = ring.pieces.first(where: { $0.key == key }) else { return unlight(.ring) }
		light(Hover(piece: key, row: p.row, source: .ring))
	}

	func hoverRow(_ r: Row?) {
		guard let r else { return unlight(.list) }
		light(Hover(piece: piece(for: r), row: r.id, source: .list))
	}

	private func piece(for r: Row) -> String? {
		var piece = ring.pieceOfRow[r.id]
		if piece == nil, r.id.hasPrefix("f:"), let n = currentNode { piece = "files:\(n.volume):\(n.dir)" }
		if piece == nil, ring.pieces.contains(where: { $0.key == r.id }) { piece = r.id }
		return piece
	}

	func hoverBar(_ g: Category?) {
		guard let g else { return unlight(.bar) }
		let key = "g:\(g.rawValue)"
		let here = place == .overview
		light(Hover(piece: here ? key : nil, row: here ? key : nil, source: .bar, group: g))
	}

	func center(_ p: Piece) -> RingView.Center {
		let share: String
		if p.kind == .free, let s = snap {
			let size = disk.flatMap { s.others[$0]?.info.size } ?? s.container.size
			share = Fmt.share(p.bytes, of: size) + " of the disk"
		} else {
			share = Fmt.share(p.bytes, of: ring.whole) + " of " + ring.wholeName
		}
		return RingView.Center(title: p.name, bytes: p.bytes, sub: share, hint: p.detail)
	}

	var centerNow: RingView.Center {
		if let h = hover, let c = center(for: h) { return c }
		if case .walking(_, let files, _, let bytes, let used) = phase, snap == nil {
			return reading("Macintosh HD", key: "boot", files: files, bytes: bytes, used: used,
			               note: "First time only — next time it opens in a second")
		}
		if let d = disk, snap?.others[d] == nil {
			let v = disks.first { $0.device == d }
			let p = otherProgress[d] ?? (0, 0)
			return reading(v?.name ?? "the disk", key: d, files: p.files, bytes: p.bytes, used: v?.used ?? 0,
			               note: "Read once; next time it opens at once")
		}
		if snap == nil { return RingView.Center(title: "Opening") }
		return RingView.Center(title: ring.title, bytes: ring.bytes, size: ring.size, sub: ring.sub, hint: canGoBack ? "‹ back" : "")
	}

	private func center(for h: Hover) -> RingView.Center? {
		if h.source == .bar, let g = h.group, let s = snap, place != .overview {
			let total = s.meaning.total(g)
			return RingView.Center(title: g.title, bytes: total, sub: Fmt.share(total, of: s.container.used) + " of used",
			                       hint: g == .hidden ? "Closed system folders, file-system bookkeeping" : "")
		}
		if h.source == .list, let id = h.row, let r = panel?.rows.first(where: { $0.id == id }) {
			return RingView.Center(title: r.name, bytes: r.bytes, sub: r.share + " of " + ring.wholeName, hint: r.detail)
		}
		if let k = h.piece, let p = ring.pieces.first(where: { $0.key == k }) { return center(p) }
		return nil
	}

	private func reading(_ name: String, key: String, files: Int, bytes: UInt64, used: UInt64, note: String) -> RingView.Center {
		guard used > 0, bytes > 0 else {
			return RingView.Center(title: "Reading \(name)", size: Fmt.count(UInt64(files)), sub: "files so far", hint: note)
		}
		let f = min(0.99, Double(bytes) / Double(used))
		var hint = note
		if let left = etaSmooth[key] { hint = Fmt.duration(left) + " left" }
		return RingView.Center(title: "Reading \(name)", size: "\(Int(f * 100))%",
		                       sub: "\(Fmt.count(UInt64(files))) files · \(Fmt.size(bytes)) of \(Fmt.size(used))",
		                       hint: hint, progress: f)
	}

	private func progress(_ key: String, _ files: Int, _ bytes: UInt64) {
		otherProgress[key] = (files, bytes)
		if walkBegan[key] == nil { walkBegan[key] = Date() }
		let began = walkBegan[key]!
		let elapsed = Date().timeIntervalSince(began)
		guard let used = disks.first(where: { $0.device == key })?.used, used > bytes, elapsed > 4, bytes > used / 50 else { return }
		let left = Double(used - bytes) / (Double(bytes) / elapsed)
		etaSmooth[key] = etaSmooth[key].map { $0 * 0.85 + left * 0.15 } ?? left
	}

	var readingFraction: Double? {
		if case .walking(_, _, _, let bytes, let used) = phase, snap == nil, used > 0 { return min(0.99, Double(bytes) / Double(used)) }
		if let d = disk, snap?.others[d] == nil {
			let used = disks.first { $0.device == d }?.used ?? 0
			let bytes = otherProgress[d]?.bytes ?? 0
			return used > 0 ? min(0.99, Double(bytes) / Double(used)) : 0
		}
		return nil
	}

	var isLoading: Bool { snap == nil || (disk != nil && snap?.others[disk!] == nil) }

	func debugPhase(_ p: Engine.Phase) { phase = p }

	private var rows: [Row] { panel?.rows ?? [] }

	func click(_ r: Row, command: Bool, shift: Bool) {
		if shift, let a = anchor, let i = rows.firstIndex(where: { $0.id == a }), let j = rows.firstIndex(where: { $0.id == r.id }) {
			let range = Set(rows[min(i, j)...max(i, j)].map(\.id))
			selection = command ? selection.union(range) : range
		} else if command {
			if selection.contains(r.id) { selection.remove(r.id) } else { selection.insert(r.id) }
			anchor = r.id
		} else {
			selection = [r.id]
			anchor = r.id
		}
	}

	func choose(rows a: Int, to b: Int, adding base: Set<String>) {
		let list = rows
		guard !list.isEmpty else { return }
		let lo = max(0, min(a, b)), hi = min(list.count - 1, max(a, b))
		var set = base
		if lo <= hi { for r in list[lo...hi] { set.insert(r.id) } }
		if set != selection { selection = set }
		if lo <= hi { anchor = list[lo].id }
	}

	func clearSelection() {
		selection = []
		anchor = nil
	}

	func selectAll() {
		selection = Set(rows.map(\.id))
		anchor = rows.first?.id
	}

	func moveSelection(_ delta: Int, extend: Bool) {
		let list = rows
		guard !list.isEmpty else { return }
		let at = cursor.flatMap { c in list.firstIndex { $0.id == c } }
		let next = at.map { max(0, min(list.count - 1, $0 + delta)) } ?? (delta > 0 ? 0 : list.count - 1)
		let r = list[next]
		if extend, let a = anchor, let i = list.firstIndex(where: { $0.id == a }) {
			selection = Set(list[min(i, next)...max(i, next)].map(\.id))
		} else {
			selection = [r.id]
			anchor = r.id
		}
		cursor = r.id
		scrollTarget = r.id
		light(Hover(piece: piece(for: r), row: r.id, source: .list))
	}

	private var cursor: String?

	func openSelection() {
		guard selection.count == 1, let r = rows.first(where: { selection.contains($0.id) }) else { return }
		activate(r)
	}

	var chosenRows: [Row] { rows.filter { selection.contains($0.id) } }

	private var mounts: [String: String] { Dictionary(disks.map { ($0.mount, $0.device) }, uniquingKeysWith: { a, _ in a }) }

	func refreshDisks() {
		let list = Disks.others(boot: snap?.container ?? Disks.boot())
		let gone = Set(disks.map(\.device)).subtracting(list.map(\.device))
		disks = list
		for key in gone { engine.forget(key) }
		if let d = disk, gone.contains(d) { selectDisk(nil) }
	}

	func reveal(_ paths: [String]) {
		let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
		guard !urls.isEmpty else { return say("It is not there any more") }
		NSWorkspace.shared.activateFileViewerSelecting(urls)
	}

	func copyPath(_ path: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(path, forType: .string)
		say("Path copied")
	}

	var actionRows: [Row] {
		let pool = selection.isEmpty ? rows : chosenRows
		return pool.filter { $0.canTrash && !$0.paths.isEmpty }
	}

	func askTrashChosen() {
		let list = actionRows
		guard !list.isEmpty, let p = panel else { return }
		let title = selection.isEmpty ? "Everything in \(p.title)" : list.count == 1 ? list[0].name : "\(list.count) items in \(p.title)"
		askTrash(list.flatMap(\.paths), title: title, forever: p.isTrash)
	}

	func askTrash(_ paths: [String], title: String, clears: Set<String> = [], forever: Bool = false, emptyAfter: Bool = false) {
		guard let s = snap else { return }
		let here = paths.filter { FileManager.default.fileExists(atPath: $0) || FileManager.default.destinationOfSymbolicLinkSafe($0) }
		guard !here.isEmpty || emptyAfter else { return say("It is not there any more") }
		let items = here.map { p -> (String, UInt64) in
			if let n = s.tree.locate(p) { return (p, s.tree.size(n)) }
			let bytes = (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
			return (p, UInt64(bytes))
		}
		sheet = .trash(TrashRequest(title: title, items: items, clears: clears, forever: forever, emptyAfter: emptyAfter))
	}

	func confirm(_ r: TrashRequest) {
		sheet = nil
		let paths = r.items.map(\.path)
		let sizes = Dictionary(r.items.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
		if r.forever {
			deleteForever(paths, sizes: sizes)
		} else if paths.isEmpty {
			if r.emptyAfter { emptyTrash() }
		} else {
			trash(paths, sizes: sizes, offerEmpty: !r.emptyAfter) { [weak self] in
				self?.cleanupTicked.subtract(r.clears)
				if r.emptyAfter { self?.emptyTrash() }
			}
		}
		clearSelection()
	}

	func trash(_ paths: [String], sizes: [String: UInt64] = [:], offerEmpty: Bool = true, done: (() -> Void)? = nil) {
		let urls = paths.map { URL(fileURLWithPath: $0) }
		NSWorkspace.shared.recycle(urls) { [weak self] moved, error in
			DispatchQueue.main.async { MainActor.assumeIsolated {
				guard let self else { return }
				let n = moved.count
				let items = moved.map { (path: $0.key.path, bytes: sizes[$0.key.path] ?? 0, now: $0.value.path) }
				let bytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
				if !items.isEmpty { self.remember(.trash, items) }
				let what = n == 1 ? (moved.first.map { $0.key.lastPathComponent } ?? "1 item") : Fmt.plural(n, "item")
				if n == urls.count {
					self.say("Moved to the Trash: \(what) · \(Fmt.size(bytes))", action: offerEmpty ? "Empty Trash…" : nil) { [weak self] in
						self?.sheet = .emptyTrash
					}
				} else {
					self.say("Moved \(n) of \(urls.count). " + (error?.localizedDescription ?? ""))
				}
				self.engine.changed(paths + [Content.trashPath + "/x"])
				done?()
			} }
		}
	}

	var trashBytes: UInt64 {
		guard let s = snap, let n = s.tree.locate(Content.trashPath) else { return 0 }
		return s.tree.size(n)
	}

	var otherTrashes: [(name: String, path: String)] {
		disks.compactMap { d in
			let p = d.mount + "/.Trashes/\(getuid())"
			let items = (try? FileManager.default.contentsOfDirectory(atPath: p))?.filter { $0 != ".DS_Store" } ?? []
			return items.isEmpty ? nil : (d.name, p)
		}
	}

	func emptyTrash() {
		guard !emptying else { return }
		emptying = true
		let before = trashBytes
		let folders = [Content.trashPath] + otherTrashes.map(\.path)
		DispatchQueue.global(qos: .userInitiated).async {
			var failed = 0
			for f in folders { failed += Remover.empty(f) }
			DispatchQueue.main.async { MainActor.assumeIsolated {
				self.emptying = false
				self.remember(.empty, [(path: "Trash", bytes: before, now: "")])
				self.say(failed == 0 ? "The Trash is empty — \(Fmt.size(before)) freed"
					: "Emptied, but \(Fmt.plural(failed, "item")) could not be removed")
				self.engine.changed(folders.map { $0 + "/x" })
			} }
		}
	}

	func deleteForever(_ paths: [String], sizes: [String: UInt64]) {
		emptying = true
		DispatchQueue.global(qos: .userInitiated).async {
			var failed = 0
			for p in paths { failed += Remover.remove(p) }
			DispatchQueue.main.async { MainActor.assumeIsolated {
				self.emptying = false
				let items = paths.map { (path: $0, bytes: sizes[$0] ?? 0, now: "") }
				self.remember(.delete, items)
				let bytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
				self.say(failed == 0 ? "Deleted for good · \(Fmt.size(bytes))" : "\(Fmt.plural(failed, "item")) could not be deleted")
				self.engine.changed(paths)
			} }
		}
	}

	func putBack(_ f: Freed) {
		let fm = FileManager.default
		var back = 0, failed = 0
		for it in f.items where !it.now.isEmpty {
			guard fm.fileExists(atPath: it.now), !fm.fileExists(atPath: it.path) else { failed += 1; continue }
			do {
				try fm.createDirectory(atPath: (it.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
				try fm.moveItem(atPath: it.now, toPath: it.path)
				back += 1
			} catch { failed += 1 }
		}
		freed.removeAll { $0.id == f.id }
		FreedLog.write(freed)
		say(failed == 0 ? "Put back: \(Fmt.plural(back, "item"))" : "Put back \(back); \(failed) were no longer in the Trash")
		engine.changed(f.items.map(\.path) + f.items.map(\.now).filter { !$0.isEmpty })
	}

	func canPutBack(_ f: Freed) -> Bool {
		f.kind == .trash && f.items.contains { !$0.now.isEmpty && FileManager.default.fileExists(atPath: $0.now) }
	}

	private func remember(_ kind: Freed.Kind, _ items: [(path: String, bytes: UInt64, now: String)]) {
		freed.insert(Freed(id: UUID().uuidString, date: Date(), kind: kind, items: items), at: 0)
		if freed.count > 60 { freed.removeLast(freed.count - 60) }
		FreedLog.write(freed)
	}

	static func id(_ c: Candidate) -> String { c.title + "|" + c.paths.joined(separator: "|") }

	static func tickable(_ c: Candidate) -> Bool { c.isTrash || (c.action == nil && !c.paths.isEmpty) }

	func isChosen(_ c: Candidate) -> Bool {
		guard Self.tickable(c) else { return false }
		if c.isTrash { return emptyTrashToo }
		let id = Self.id(c)
		return c.safety == .safe ? !cleanupUnticked.contains(id) : cleanupTicked.contains(id)
	}

	func toggle(_ c: Candidate) {
		if c.isTrash {
			emptyTrashToo.toggle()
			saveSettings()
			return
		}
		let id = Self.id(c)
		if isChosen(c) {
			cleanupTicked.remove(id); if c.safety == .safe { cleanupUnticked.insert(id) }
		} else {
			cleanupUnticked.remove(id); if c.safety != .safe { cleanupTicked.insert(id) }
		}
	}

	var cleanupSafe: UInt64 {
		snap?.cleanup.filter { $0.safety == .safe && Self.tickable($0) }.reduce(0) { $0 + $1.bytes } ?? 0
	}

	var cleanupChosenBytes: UInt64 {
		snap?.cleanup.filter(isChosen).reduce(0) { $0 + $1.bytes } ?? 0
	}

	func cleanupGo() {
		guard let s = snap else { return }
		let chosen = s.cleanup.filter(isChosen)
		let empty = chosen.contains { $0.isTrash }
		let paths = chosen.filter { !$0.isTrash }.flatMap(\.paths)
		guard !paths.isEmpty || empty else { return }
		if paths.isEmpty { sheet = .emptyTrash; return }
		askTrash(paths, title: "Free up space", clears: Set(chosen.map(Self.id)), emptyAfter: empty)
	}

	func canExplain(_ r: Row) -> Bool { r.id.hasPrefix("i:") || (!r.paths.isEmpty && !r.id.hasPrefix("g:")) }

	func explain(_ r: Row, again: Bool = false) {
		guard let s = snap, canExplain(r) else { return }
		let cacheKey: String
		let describe: @Sendable () -> String
		if r.id.hasPrefix("i:"), let it = s.meaning.item(id: String(r.id.dropFirst(2))) {
			cacheKey = "item:" + it.id
			describe = { Describe.item(s, it) }
		} else if let p = r.paths.first {
			cacheKey = p
			describe = { Describe.path(s, p) }
		} else { return }
		explainTask?.cancel()
		if !again, let e = explainCache[cacheKey], ExplainCache.fresh(e, bytes: r.bytes) {
			explanation = Explanation(row: r, state: .answer(e.text, cost: e.cost, saved: true))
			return
		}
		guard hasClaudeKey else {
			explanation = Explanation(row: r, state: .failed(Claude.Failure.noKey.text, key: true))
			return
		}
		explanation = Explanation(row: r, state: .asking)
		let bytes = r.bytes
		explainTask = Task { [weak self] in
			let text = await Task.detached(priority: .userInitiated) { describe() }.value
			let result = await Claude.ask(text)
			guard let self, !Task.isCancelled, self.explanation?.row.id == r.id else { return }
			switch result {
			case .success(let a):
				self.explainCache[cacheKey] = ExplainCache.Entry(text: a.text, bytes: bytes, date: Date(), cost: a.cost)
				ExplainCache.save(self.explainCache)
				self.explanation?.state = .answer(a.text, cost: a.cost, saved: false)
			case .failure(let f):
				self.explanation?.state = .failed(f.text, key: f.isKey)
			}
		}
	}

	func debugExplanation(_ e: Explanation) { explanation = e }

	func explainChosen() {
		guard selection.count == 1, let r = chosenRows.first else { return }
		explain(r)
	}

	func closeExplanation() {
		explainTask?.cancel()
		explanation = nil
	}

	func setClaudeKey(_ key: String) {
		guard Claude.save(key) else { return say("The key could not be saved in the keychain") }
		hasClaudeKey = true
		sheet = nil
		if let e = explanation, case .failed(_, true) = e.state { explain(e.row, again: true) }
	}

	func setPanelWidth(_ w: CGFloat, save: Bool) {
		panelWidth = max(Theme.panelMin, min(Theme.panelMax, w.rounded()))
		if save { saveSettings() }
	}

	private static var settingsFile: URL { Store().folder.appendingPathComponent("settings.txt") }

	private func loadSettings() {
		guard let text = try? String(contentsOf: Self.settingsFile, encoding: .utf8) else { return }
		for line in text.split(separator: "\n") {
			let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
			guard kv.count == 2 else { continue }
			switch kv[0] {
			case "panel": if let v = Double(kv[1]) { panelWidth = max(Theme.panelMin, min(Theme.panelMax, CGFloat(v))) }
			case "emptyTrash": emptyTrashToo = kv[1] == "1"
			default: break
			}
		}
	}

	private func saveSettings() {
		let text = "panel=\(Int(panelWidth))\nemptyTrash=\(emptyTrashToo ? 1 : 0)\n"
		try? FileManager.default.createDirectory(at: Self.settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? text.write(to: Self.settingsFile, atomically: true, encoding: .utf8)
	}

	func allowAdmin(_ password: String) {
		guard !password.isEmpty, !passwordChecking else { return }
		passwordChecking = true
		passwordError = nil
		Task { [weak self] in
			let ok = await Task.detached { Privileged.check(password) && Privileged.save(password) }.value
			guard let self else { return }
			self.passwordChecking = false
			guard ok else {
				self.passwordError = "That password did not work. It is the one you use to log in to this Mac (an administrator’s)."
				return
			}
			self.hasAdmin = true
			self.adminStale = false
			self.sheet = nil
			self.engine.setAdmin(true)
		}
	}

	func forgetAdmin() {
		Privileged.forget()
		hasAdmin = false
		adminStale = false
		engine.setAdmin(false)
		say("Password forgotten. Closed folders stay as they were read until the next launch.")
	}

	private func admin(_ e: Engine.AdminEvent) {
		switch e {
		case .reading: adminBusy = true
		case .done(let added):
			adminBusy = false
			if added > 0 { say("Closed folders read: \(Fmt.size(added)) more is now explained") }
		case .wrongPassword:
			adminBusy = false
			adminStale = true
			say("The saved Mac password no longer works — enter the new one to read closed folders")
		case .failed:
			adminBusy = false
		}
	}

	private var toastTask: Task<Void, Never>?

	func say(_ text: String, action: String? = nil, run: (@MainActor () -> Void)? = nil) {
		toast = Toast(text: text, action: action, run: run)
		toastTask?.cancel()
		toastTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(action == nil ? 2.8 : 7))
			guard !Task.isCancelled else { return }
			self?.toast = nil
		}
	}

	func dismissToast() { toast = nil }

	static func checkFullDiskAccess() -> Bool {
		let home = NSHomeDirectory()
		for p in ["/Library/Application Support/com.apple.TCC", home + "/Library/Safari", home + "/Library/Mail", home + "/Library/Messages"] {
			let fd = Darwin.open(p, O_RDONLY | O_DIRECTORY)
			if fd >= 0 { close(fd); return false }
			if errno == EPERM || errno == EACCES { return true }
		}
		return false
	}

	func openPrivacySettings() {
		if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
			NSWorkspace.shared.open(u)
		}
	}
}

extension FileManager {
	func destinationOfSymbolicLinkSafe(_ path: String) -> Bool { (try? destinationOfSymbolicLink(atPath: path)) != nil }
}

enum Remover {
	static func empty(_ folder: String) -> Int {
		let fm = FileManager()
		guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return fm.fileExists(atPath: folder) ? 1 : 0 }
		return names.reduce(0) { $0 + remove(folder + "/" + $1) }
	}

	static func remove(_ path: String) -> Int {
		let fm = FileManager()
		if (try? fm.removeItem(atPath: path)) != nil { return 0 }
		_ = lchflags(path, 0)
		if let e = fm.enumerator(atPath: path) {
			while let rel = e.nextObject() as? String { _ = lchflags(path + "/" + rel, 0) }
		}
		return (try? fm.removeItem(atPath: path)) != nil ? 0 : 1
	}
}

enum FreedLog {
	private static var file: URL { Store().folder.appendingPathComponent("freed.log") }

	static func read() -> [Freed] {
		guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
		var out: [Freed] = []
		var index: [String: Int] = [:]
		for line in text.split(separator: "\n") {
			let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
			guard f.count >= 6, let t = Double(f[1]), let kind = Freed.Kind(rawValue: f[2]), let bytes = UInt64(f[3]) else { continue }
			let item = (path: f[4], bytes: bytes, now: f[5])
			if let i = index[f[0]] { out[i].items.append(item); continue }
			index[f[0]] = out.count
			out.append(Freed(id: f[0], date: Date(timeIntervalSince1970: t), kind: kind, items: [item]))
		}
		return out
	}

	static func write(_ list: [Freed]) {
		var text = ""
		for f in list {
			for it in f.items where !it.path.contains("\t") && !it.path.contains("\n") {
				text += "\(f.id)\t\(f.date.timeIntervalSince1970)\t\(f.kind.rawValue)\t\(it.bytes)\t\(it.path)\t\(it.now)\n"
			}
		}
		try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? text.write(to: file, atomically: true, encoding: .utf8)
	}
}
