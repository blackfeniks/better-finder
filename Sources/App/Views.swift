import AppKit
import SwiftUI

struct RootView: View {
	@Bindable var model: AppModel

	var body: some View {
		GeometryReader { geo in
			let room = geo.size.width - Theme.stageMin - 1
			let panel = max(min(Theme.panelMin, room), min(model.panelWidth, room))
			VStack(spacing: 0) {
				TopBar(model: model)
				Hairline()
				HStack(spacing: 0) {
					Stage(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
					Rectangle().fill(Theme.hair).frame(width: 0.5)
						.overlay { SplitHandle(model: model, limit: room).frame(width: 9) }
						.zIndex(2)
					PanelView(model: model).frame(width: panel)
				}
				Hairline()
				DiskBar(model: model)
			}
			.background(LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom))
			.overlay { SheetHost(model: model) }
			.overlay(alignment: .bottom) { ToastView(model: model).padding(.bottom, 86) }
		}
		.environment(\.colorScheme, .dark)
		.ignoresSafeArea()
	}
}

struct Hairline: View {
	var body: some View { Rectangle().fill(Theme.hair).frame(height: 0.5) }
}

struct SplitHandle: NSViewRepresentable {
	let model: AppModel
	let limit: CGFloat

	final class Handle: NSView {
		var width: (() -> CGFloat)?
		var set: ((CGFloat, Bool) -> Void)?
		var limit: CGFloat = .infinity
		private var startX: CGFloat = 0
		private var startWidth: CGFloat = 0

		override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
		override func mouseDown(with e: NSEvent) {
			if e.clickCount == 2 { set?(Theme.panelDefault, true); return }
			startX = e.locationInWindow.x
			startWidth = min(width?() ?? Theme.panelDefault, limit)
		}
		override func mouseDragged(with e: NSEvent) { set?(min(limit, startWidth - (e.locationInWindow.x - startX)), false) }
		override func mouseUp(with e: NSEvent) {
			guard e.clickCount < 2 else { return }
			set?(min(limit, startWidth - (e.locationInWindow.x - startX)), true)
		}
	}

	func makeNSView(context: Context) -> Handle {
		let h = Handle()
		h.width = { [weak model] in model?.panelWidth ?? Theme.panelDefault }
		h.set = { [weak model] w, save in model?.setPanelWidth(w, save: save) }
		return h
	}

	func updateNSView(_ h: Handle, context: Context) {
		h.limit = limit
		h.window?.invalidateCursorRects(for: h)
	}
}

struct TopBar: View {
	@Bindable var model: AppModel

	var body: some View {
		HStack(spacing: 8) {
			Color.clear.frame(width: model.fullScreen ? 6 : 82, height: 1)
			IconButton(symbol: "chevron.left", help: "Back (Esc)", enabled: model.canGoBack) { model.back() }
			Crumbs(model: model)
			Spacer(minLength: 12)
			if !model.disks.isEmpty { DiskMenu(model: model) }
			if model.disk == nil {
				Segmented(items: [("By meaning", Mode.meaning), ("Folders", Mode.folders)], selection: model.mode) { model.setMode($0) }
			}
			Button {
				model.sheet = .cleanup
			} label: {
				ViewThatFits(in: .horizontal) {
					Text(model.cleanupSafe > 0 ? "Free up \(Fmt.size(model.cleanupSafe))" : "Free up space")
					Text("Free up")
				}
			}
			.buttonStyle(PrimaryButton())
			.disabled(model.snap == nil)
			.help("Caches, logs, leftovers and the Trash — every folder is named before anything moves")
		}
		.padding(.trailing, 14)
		.frame(height: Theme.barHeight)
		.background(WindowDragArea())
	}
}

struct Crumbs: View {
	let model: AppModel

	var body: some View {
		let all = model.crumbs
		let shown: [(String, Int)?] = all.count > 4 ? [all[0], nil] + all.suffix(2).map { Optional($0) } : all.map { Optional($0) }
		HStack(spacing: 2) {
			ForEach(Array(shown.enumerated()), id: \.offset) { k, c in
				if k > 0 { Text("›").font(Theme.font(14)).foregroundStyle(Theme.t4).padding(.horizontal, 2) }
				if let (name, depth) = c {
					let here = depth == all.count - 1
					Button { model.pop(to: depth) } label: {
						Text(name).font(Theme.font(14, .semibold)).lineLimit(1).truncationMode(.middle)
							.foregroundStyle(here ? Theme.t1 : Theme.t3)
					}
					.buttonStyle(CrumbButton(here: here))
					.disabled(here)
					.layoutPriority(here ? 1 : 0)
				} else {
					Text("…").font(Theme.font(14, .semibold)).foregroundStyle(Theme.t4)
				}
			}
		}
		.lineLimit(1)
		.layoutPriority(-1)
	}
}

struct DiskMenu: View {
	let model: AppModel

	var body: some View {
		Menu {
			Button { model.selectDisk(nil) } label: {
				Label("Macintosh HD", systemImage: model.disk == nil ? "checkmark" : "internaldrive")
			}
			Divider()
			ForEach(model.disks, id: \.device) { d in
				Button { model.selectDisk(d.device) } label: {
					Label("\(d.name) — \(Fmt.size(d.used)) of \(Fmt.size(d.size))",
					      systemImage: model.disk == d.device ? "checkmark" : "externaldrive")
				}
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: model.disk == nil ? "internaldrive" : "externaldrive")
				Text(model.disk.flatMap { k in model.disks.first { $0.device == k }?.name } ?? "Macintosh HD")
					.lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
				Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
			}
			.font(Theme.font(13, .medium))
			.foregroundStyle(Theme.t2)
			.padding(.horizontal, 10).padding(.vertical, 6)
			.background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()
		.help("Which disk")
	}
}

struct Segmented<T: Hashable>: View {
	let items: [(String, T)]
	let selection: T
	let pick: (T) -> Void

	var body: some View {
		HStack(spacing: 2) {
			ForEach(items, id: \.1) { title, value in
				Button { pick(value) } label: {
					Text(title).font(Theme.font(13, .medium))
						.foregroundStyle(value == selection ? Theme.t1 : Theme.t2)
						.padding(.horizontal, 12).padding(.vertical, 6)
						.background(RoundedRectangle(cornerRadius: 7).fill(value == selection ? Color.white.opacity(0.14) : .clear))
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
		.padding(2)
		.background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
		.fixedSize()
	}
}

struct Stage: View {
	@Bindable var model: AppModel

	var body: some View {
		ZStack(alignment: .top) {
			RingStage(model: model)
			if model.needsFullDiskAccess && !model.fdaDismissed {
				AccessBanner(model: model).padding(.top, 14).padding(.horizontal, 18)
			}
		}
		.frame(minWidth: Theme.stageMin, maxWidth: .infinity, maxHeight: .infinity)
		.clipped()
	}
}

struct RingStage: NSViewRepresentable {
	let model: AppModel

	final class Coordinator { var version = -1 }

	func makeCoordinator() -> Coordinator { Coordinator() }

	func makeNSView(context: Context) -> RingView {
		let v = RingView(frame: .zero)
		v.onHover = { [weak model] key in model?.hoverRing(key) }
		v.onClick = { [weak model] p in model?.ringClicked(p) }
		v.onCenterClick = { [weak model] in model?.back() }
		return v
	}

	func updateNSView(_ v: RingView, context: Context) {
		let version = model.ringVersion
		if context.coordinator.version != version {
			context.coordinator.version = version
			v.show(model.ring, model.ringTransition)
		}
		v.centerIsBack = model.canGoBack
		v.setLoading(model.isLoading)
		v.setHover(model.hover?.piece)
		v.setCenter(model.centerNow)
	}
}

struct AccessBanner: View {
	let model: AppModel

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: "lock").font(.system(size: 15)).foregroundStyle(Theme.t2).padding(.top, 2)
			VStack(alignment: .leading, spacing: 3) {
				Text("Mail, Messages, Safari and some app data are closed to Better Finder")
					.font(Theme.font(13, .medium)).foregroundStyle(Theme.t1).fixedSize(horizontal: false, vertical: true)
				Text("In Full Disk Access switch on Better Finder (or click + and choose it in Applications) and let macOS reopen it. Until then those folders count as “not visible”.")
					.font(Theme.font(12.5)).foregroundStyle(Theme.t3).fixedSize(horizontal: false, vertical: true)
			}
			Spacer(minLength: 8)
			VStack(alignment: .trailing, spacing: 6) {
				IconButton(symbol: "xmark", help: "Not now", enabled: true) { model.fdaDismissed = true }
				Button("Open Settings") { model.openPrivacySettings() }.buttonStyle(GhostButton())
			}
		}
		.padding(14)
		.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.edge, lineWidth: 0.5))
		.frame(maxWidth: 640)
	}
}

struct PanelView: View {
	@Bindable var model: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let p = model.panel {
				PanelHeader(model: model, panel: p)
				if !p.kinds.isEmpty {
					Flow(spacing: 14, lineSpacing: 4) {
						ForEach(p.kinds, id: \.0) { k in
							HStack(spacing: 5) {
								Text(k.0).font(Theme.font(12.5, .medium)).foregroundStyle(Theme.t2)
								Text(Fmt.size(k.1)).font(Theme.font(12.5)).foregroundStyle(Theme.t3)
							}
						}
					}
					.padding(.horizontal, 22).padding(.bottom, 10)
				}
				RowList(model: model, rows: p.rows, inTrash: p.isTrash)
				if let note = p.footnote {
					Text(note).font(Theme.font(12.5)).foregroundStyle(Theme.t3)
						.fixedSize(horizontal: false, vertical: true)
						.padding(.horizontal, 22).padding(.vertical, 10)
				}
				if p.closed { ClosedFolders(model: model).padding(.horizontal, 22).padding(.bottom, 12) }
				if let e = model.explanation {
					ExplainCard(model: model, e: e).padding(.horizontal, 12).padding(.bottom, 10)
						.transition(.opacity.combined(with: .move(edge: .bottom)))
				}
				PanelFooter(model: model, panel: p)
			} else {
				VStack(alignment: .leading, spacing: 6) {
					Text(model.snap == nil ? "Reading the disk" : "Reading \(model.disks.first { $0.device == model.disk }?.name ?? "the disk")")
						.font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.t1)
						.lineLimit(2)
					Text(model.snap == nil
						? "The first time, Better Finder reads every folder — about 15 seconds. After that it opens in a second and keeps up with changes by itself."
						: "Every folder is read once; next time it opens at once. The ring shows how far it is.")
						.font(Theme.font(13)).foregroundStyle(Theme.t3).fixedSize(horizontal: false, vertical: true)
				}
				.padding(.horizontal, 22).padding(.top, 18)
				Spacer()
			}
		}
		.frame(maxHeight: .infinity, alignment: .top)
		.animation(.easeOut(duration: 0.18), value: model.explanation)
	}
}

struct ExplainCard: View {
	let model: AppModel
	let e: Explanation

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "sparkles").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.t2)
				Text(e.row.name).font(Theme.font(13, .semibold)).foregroundStyle(Theme.t1).lineLimit(1).truncationMode(.middle)
				Spacer(minLength: 6)
				IconButton(symbol: "xmark", help: "Close (Esc)", enabled: true, size: 22) { model.closeExplanation() }
			}
			switch e.state {
			case .asking:
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Asking Claude…").font(Theme.font(13)).foregroundStyle(Theme.t2)
				}
			case .answer(let text, let cost, let saved):
				Text(text).font(Theme.font(13)).foregroundStyle(Theme.t1).fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
				HStack(spacing: 10) {
					Text(saved ? "Answered before · no charge" : "Claude Sonnet · \(Self.cents(cost))")
						.font(Theme.font(12)).foregroundStyle(Theme.t4)
					Spacer()
					Button("Ask again") { model.explain(e.row, again: true) }.buttonStyle(LinkButton())
				}
			case .failed(let why, let key):
				Text(why).font(Theme.font(13)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
				HStack(spacing: 10) {
					if key { Button("Enter the key…") { model.sheet = .claudeKey }.buttonStyle(LinkButton()) }
					Spacer()
					Button("Try again") { model.explain(e.row, again: true) }.buttonStyle(LinkButton())
				}
			}
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.055)))
		.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.edge, lineWidth: 0.5))
	}

	static func cents(_ dollars: Double) -> String {
		let c = dollars * 100
		return c < 0.1 ? "under 0.1¢" : String(format: "%.1f¢", c)
	}
}

struct ClosedFolders: View {
	let model: AppModel

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if model.adminBusy {
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					Text("Reading closed folders…").font(Theme.font(12.5)).foregroundStyle(Theme.t2)
				}
			} else if model.hasAdmin && model.adminStale {
				Text("The saved Mac password no longer works (it was changed).")
					.font(Theme.font(12.5)).foregroundStyle(Theme.t3).fixedSize(horizontal: false, vertical: true)
				Button("Enter the new password…") {
					model.passwordError = nil
					model.sheet = .password
				}
				.buttonStyle(GhostButton())
			} else if model.hasAdmin {
				Text("Closed system folders are read with your Mac password, kept in your keychain.")
					.font(Theme.font(12.5)).foregroundStyle(Theme.t3).fixedSize(horizontal: false, vertical: true)
				Button("Forget the password") { model.forgetAdmin() }.buttonStyle(LinkButton())
			} else {
				Button("Read closed folders with your password…") {
					model.passwordError = nil
					model.sheet = .password
				}
				.buttonStyle(GhostButton())
			}
		}
	}
}

struct PanelHeader: View {
	let model: AppModel
	let panel: PanelContent

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			if let back = panel.back {
				IconButton(symbol: "chevron.left", help: "Back to \(back.label)", enabled: true, size: 30) { model.pop(to: back.depth) }
					.padding(.leading, -8)
			}
			VStack(alignment: .leading, spacing: 3) {
				HStack(spacing: 10) {
					if let icon = panel.icon { RowIconView(icon: icon, size: 28) }
					Text(panel.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.t1)
						.lineLimit(panel.title.contains(" ") ? 2 : 1).truncationMode(.middle)
						.minimumScaleFactor(panel.title.contains(" ") ? 1 : 0.8)
				}
				Text(panel.meta).font(Theme.font(13)).foregroundStyle(Theme.t3).lineLimit(2).truncationMode(.middle)
			}
		}
		.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 12)
	}
}

struct Flow: Layout {
	var spacing: CGFloat = 12
	var lineSpacing: CGFloat = 4

	func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
		let width = proposal.width ?? .infinity
		var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
		for s in subviews {
			let size = s.sizeThatFits(.unspecified)
			if x > 0 && x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
			x += size.width + spacing
			line = max(line, size.height)
			widest = max(widest, x - spacing)
		}
		return CGSize(width: proposal.width ?? widest, height: y + line)
	}

	func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
		var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
		for s in subviews {
			let size = s.sizeThatFits(.unspecified)
			if x > bounds.minX && x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
			s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
			x += size.width + spacing
			line = max(line, size.height)
		}
	}
}

struct RowList: View {
	@Bindable var model: AppModel
	let rows: [Row]
	let inTrash: Bool

	private struct Band { var start: CGPoint; var now: CGPoint; var base: Set<String> }
	@State private var band: Band?

	var body: some View {
		GeometryReader { geo in
			ScrollViewReader { proxy in
				ScrollView {
					VStack(spacing: 0) {
						LazyVStack(spacing: 0) {
							ForEach(rows) { r in
								RowView(model: model, row: r, hot: model.hover?.row == r.id, chosen: model.selection.contains(r.id),
								        inTrash: inTrash, many: model.selection.count > 1 && model.selection.contains(r.id))
									.equatable()
									.id(r.id)
							}
						}
						if rows.isEmpty {
							Text(inTrash ? "The Trash is empty" : "Nothing here").font(Theme.font(13)).foregroundStyle(Theme.t3).padding(.top, 30)
						}
						Spacer(minLength: 0)
					}
					.padding(.horizontal, 10)
					.frame(minHeight: geo.size.height, alignment: .top)
					.background(Color.clear.contentShape(Rectangle()).onTapGesture { model.clearSelection() })
					.overlay(alignment: .topLeading) { bandView }
					.coordinateSpace(name: "rows")
					.simultaneousGesture(drag)
				}
				.scrollIndicators(.automatic)
				.onChange(of: model.hover?.row) { _, id in
					guard let id, model.hover?.source != .list else { return }
					withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id) }
				}
				.onChange(of: model.scrollTarget) { _, id in
					guard let id else { return }
					proxy.scrollTo(id)
				}
			}
		}
	}

	private var drag: some Gesture {
		DragGesture(minimumDistance: 4, coordinateSpace: .named("rows"))
			.onChanged { v in
				if band == nil {
					band = Band(start: v.startLocation, now: v.location,
					            base: NSEvent.modifierFlags.contains(.command) ? model.selection : [])
				}
				band?.now = v.location
				let a = Int(floor(v.startLocation.y / Theme.rowHeight)), b = Int(floor(v.location.y / Theme.rowHeight))
				model.choose(rows: a, to: b, adding: band?.base ?? [])
			}
			.onEnded { _ in band = nil }
	}

	@ViewBuilder private var bandView: some View {
		if let b = band {
			let r = CGRect(x: min(b.start.x, b.now.x), y: min(b.start.y, b.now.y),
			               width: abs(b.now.x - b.start.x), height: abs(b.now.y - b.start.y))
			Rectangle().fill(Color.white.opacity(0.06))
				.overlay(Rectangle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
				.frame(width: r.width, height: r.height)
				.offset(x: r.minX, y: r.minY)
				.allowsHitTesting(false)
		}
	}
}

struct RowView: View, Equatable {
	let model: AppModel
	let row: Row
	let hot: Bool
	let chosen: Bool
	let inTrash: Bool
	let many: Bool

	static func == (a: RowView, b: RowView) -> Bool {
		a.row.id == b.row.id && a.row.bytes == b.row.bytes && a.row.name == b.row.name && a.row.detail == b.row.detail
			&& a.row.share == b.row.share && a.row.dim == b.row.dim && a.row.canTrash == b.row.canTrash
			&& (a.row.open == nil) == (b.row.open == nil) && a.hot == b.hot && a.chosen == b.chosen && a.inTrash == b.inTrash
			&& a.many == b.many
	}

	private var opens: Bool { row.open != nil || row.otherDisk != nil }

	var body: some View {
		HStack(spacing: 10) {
			RowIconView(icon: row.icon, size: 22)
			VStack(alignment: .leading, spacing: 1) {
				Text(row.name).font(Theme.font(14)).foregroundStyle(row.dim ? Theme.t2 : Theme.t1)
					.lineLimit(1).truncationMode(.middle)
				if !row.detail.isEmpty && row.detail != row.name {
					Text(row.detail)
						.font(Theme.font(12.5)).foregroundStyle(Theme.t3).lineLimit(1)
						.truncationMode(row.detail.hasPrefix("/") || row.detail.hasPrefix("~") ? .middle : .tail)
				}
			}
			Spacer(minLength: 6)
			if hot && (!row.paths.isEmpty || model.canExplain(row)) {
				HStack(spacing: 2) {
					if model.canExplain(row) {
						IconButton(symbol: "sparkles", help: "What is this? — Claude explains (⌘I)", enabled: true, size: 24) { model.explain(row) }
					}
					if !row.paths.isEmpty {
						IconButton(symbol: "folder", help: "Show in Finder", enabled: true, size: 24) { model.reveal(row.paths) }
					}
					if row.canTrash {
						IconButton(symbol: inTrash ? "xmark.bin" : "trash", help: inTrash ? "Delete for good…" : "Move to Trash…",
						           enabled: true, size: 24) {
							model.askTrash(row.paths, title: row.name, forever: inTrash)
						}
					}
				}
			}
			VStack(alignment: .trailing, spacing: 1) {
				Text(Fmt.size(row.bytes)).font(Theme.font(14)).foregroundStyle(row.dim ? Theme.t2 : Theme.t1)
				Text(row.share).font(Theme.font(12)).foregroundStyle(Theme.t3)
			}
			.fixedSize()
			if opens {
				Button { model.activate(row) } label: {
					Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(hot ? Theme.t2 : Theme.t4)
						.frame(width: 22, height: Theme.rowHeight).contentShape(Rectangle())
				}
				.buttonStyle(.plain)
				.help("Open")
			} else {
				Color.clear.frame(width: 22)
			}
		}
		.padding(.leading, 12).padding(.trailing, 4)
		.frame(height: Theme.rowHeight)
		.background(RoundedRectangle(cornerRadius: Theme.corner).fill(chosen ? Theme.pick : hot ? Theme.hover : .clear))
		.contentShape(Rectangle())
		.onHover { model.hoverRow($0 ? row : nil) }
		.simultaneousGesture(TapGesture().onEnded {
			let m = NSEvent.modifierFlags
			model.click(row, command: m.contains(.command), shift: m.contains(.shift))
		})
		.onTapGesture(count: 2) { model.activate(row) }
		.contextMenu {
			if opens { Button("Open") { model.activate(row) } }
			if model.canExplain(row) && !many { Button("What Is This?") { model.explain(row) } }
			if many {
				Button("Show \(model.selection.count) in Finder") { model.reveal(model.chosenRows.flatMap(\.paths)) }
				Divider()
				Button(inTrash ? "Delete \(model.selection.count) for Good…" : "Move \(model.selection.count) to Trash…") { model.askTrashChosen() }
			} else {
				if !row.paths.isEmpty {
					Button("Show in Finder") { model.reveal(row.paths) }
					Button("Copy Path") { model.copyPath(row.paths[0]) }
				}
				if row.canTrash {
					Divider()
					Button(inTrash ? "Delete for Good…" : "Move to Trash…") { model.askTrash(row.paths, title: row.name, forever: inTrash) }
				}
			}
		}
	}
}

struct PanelFooter: View {
	let model: AppModel
	let panel: PanelContent

	var body: some View {
		let chosen = model.chosenRows
		let acting = model.actionRows
		let bytes = acting.reduce(UInt64(0)) { $0 + $1.bytes }
		let hasRows = !panel.rows.isEmpty
		if !chosen.isEmpty || panel.isFolder || panel.isTrash || !panel.paths.isEmpty || (hasRows && acting.count > 0) {
			Hairline()
			HStack(spacing: 8) {
				if !chosen.isEmpty {
					IconButton(symbol: "xmark", help: "Choose none (Esc)", enabled: true, size: 26) { model.clearSelection() }
						.padding(.leading, -6)
					VStack(alignment: .leading, spacing: 0) {
						Text("\(chosen.count) chosen").font(Theme.font(13, .medium)).foregroundStyle(Theme.t1)
						Text(Fmt.size(chosen.reduce(0) { $0 + $1.bytes })).font(Theme.font(12)).foregroundStyle(Theme.t3)
					}
					.lineLimit(1)
					Spacer(minLength: 6)
					if chosen.count == 1, model.canExplain(chosen[0]) {
						IconButton(symbol: "sparkles", help: "What is this? — Claude explains (⌘I)", enabled: true) { model.explain(chosen[0]) }
					}
					IconButton(symbol: "folder", help: "Show in Finder", enabled: chosen.contains { !$0.paths.isEmpty }) {
						model.reveal(chosen.flatMap(\.paths))
					}
					Button(panel.isTrash ? "Delete for good…" : "Move to Trash…") { model.askTrashChosen() }
						.buttonStyle(GhostButton())
						.disabled(acting.isEmpty)
						.help(acting.isEmpty ? "Nothing chosen here may be moved" : "Asks first and lists every path")
				} else if panel.isTrash {
					Button("Show in Finder") { model.reveal(panel.paths) }.buttonStyle(GhostButton())
					Spacer(minLength: 6)
					Button(model.emptying ? "Emptying…" : "Empty Trash… · \(Fmt.size(model.trashBytes))") { model.sheet = .emptyTrash }
						.buttonStyle(GhostButton())
						.disabled(model.trashBytes == 0 || model.emptying)
				} else {
					if !panel.paths.isEmpty {
						IconButton(symbol: "folder", help: "Show in Finder", enabled: true) { model.reveal(panel.paths) }
							.padding(.leading, -6)
					}
					ViewThatFits(in: .horizontal) {
						Text("Click to choose · double-click opens")
						Text("Double-click opens")
						Color.clear.frame(width: 0, height: 0)
					}
					.font(Theme.font(12)).foregroundStyle(Theme.t4).lineLimit(1)
					.layoutPriority(-1)
					Spacer(minLength: 6)
					if panel.isFolder {
						if !acting.isEmpty {
							Button { model.askTrashChosen() } label: {
								ViewThatFits(in: .horizontal) {
									Text("Move all to Trash… · \(Fmt.size(bytes))")
									Text("Move all to Trash…")
								}
							}
							.buttonStyle(GhostButton())
							.help("Everything listed here (not the folder itself) — asks first and lists every path")
						}
					} else if panel.canTrash, let t = panel.trashTitle {
						Button(t) { model.askTrash(panel.paths, title: panel.title) }.buttonStyle(GhostButton())
					}
				}
			}
			.padding(.horizontal, 18).padding(.vertical, 10)
			.frame(minHeight: 52)
		}
	}
}

struct RowIconView: View {
	let icon: Row.Icon
	let size: CGFloat

	var body: some View {
		Group {
			switch icon {
			case .file(let path):
				Image(nsImage: Icons.shared.icon(path)).resizable().interpolation(.high)
			case .symbol(let name):
				Image(systemName: name).font(.system(size: size * 0.62)).foregroundStyle(Theme.t2)
			}
		}
		.frame(width: size, height: size)
	}
}

struct DiskBar: View {
	@Bindable var model: AppModel
	@State private var hot: Int?

	struct Segment {
		let name: String
		let bytes: UInt64
		let tone: Double
		let kind: Piece.Kind
		let group: Category?
	}

	private var segments: (list: [Segment], size: UInt64, used: UInt64, free: UInt64) {
		guard let s = model.snap else { return ([], 1, 0, 0) }
		if let d = model.disk {
			guard let o = s.others[d] else { return ([], 1, 0, 0) }
			let t = s.tree
			let root = Node(volume: d, dir: 0)
			let entries = t.entries(root).filter { $0.bytes > 0 }
			var list = entries.prefix(8).enumerated().map { k, e in
				Segment(name: e.name, bytes: e.bytes, tone: k % 2 == 0 ? 0.95 : 0.64, kind: .normal, group: nil)
			}
			let rest = entries.dropFirst(8).reduce(UInt64(0)) { $0 + $1.bytes } + t.ownBytes(root)
			if rest > 0 { list.append(Segment(name: "Everything else", bytes: rest, tone: 0.46, kind: .normal, group: nil)) }
			let seen = t.size(root)
			if o.info.used > seen {
				list.append(Segment(name: "Not visible as files", bytes: o.info.used - seen, tone: 0.34, kind: .hidden, group: nil))
			}
			return (list, max(o.info.size, 1), o.info.used, o.info.free)
		}
		let c = s.container
		let list = Content.orderedGroups(s).enumerated().map { k, gi in
			Segment(name: gi.0.title, bytes: s.meaning.total(gi.0), tone: Content.toneOf(gi.0, k),
			        kind: gi.0 == .hidden ? .hidden : .normal, group: gi.0)
		}
		return (list, max(c.size, 1), c.used, c.free)
	}

	private var reading: (name: String, used: UInt64, size: UInt64)? {
		guard model.readingFraction != nil else { return nil }
		if let d = model.disk, let v = model.disks.first(where: { $0.device == d }) { return (v.name, v.used, max(v.size, 1)) }
		if case .walking(_, _, _, _, let used) = model.phase { return ("Macintosh HD", used, max(used, 1)) }
		return nil
	}

	var body: some View {
		VStack(spacing: 9) {
			if let r = reading, let f = model.readingFraction {
				readingBar(r, f)
			} else {
				bar(segments)
			}
		}
		.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
	}

	@ViewBuilder private func bar(_ seg: (list: [Segment], size: UInt64, used: UInt64, free: UInt64)) -> some View {
		GeometryReader { geo in
			let gaps = CGFloat(seg.list.count) * 2
			let width = max(0, geo.size.width - gaps)
			HStack(spacing: 2) {
				ForEach(Array(seg.list.enumerated()), id: \.offset) { k, sg in
					let w = max(2, width * CGFloat(Double(sg.bytes) / Double(seg.size)))
					let lit = hot == nil || hot == k || barLit(sg)
					BarPiece(tone: sg.tone, kind: sg.kind)
						.frame(width: w)
						.opacity(lit ? 1 : 0.35)
						.animation(.easeOut(duration: 0.15), value: lit)
						.contentShape(Rectangle().inset(by: -1.5))
						.onHover { on in
							hot = on ? k : (hot == k ? nil : hot)
							if let g = sg.group { model.hoverBar(on ? g : nil) }
						}
						.onTapGesture { if let g = sg.group { model.showGroup(g) } }
						.overlay(alignment: .bottom) {
							if hot == k { BarTip(name: sg.name, bytes: sg.bytes, used: seg.used).offset(y: -18).fixedSize() }
						}
						.zIndex(hot == k ? 1 : 0)
				}
				BarPiece(tone: 0.3, kind: .free).frame(maxWidth: .infinity)
			}
		}
		.frame(height: 10)
		HStack(alignment: .firstTextBaseline) {
			if model.snap != nil { legendLeft(seg.used, seg.free).layoutPriority(1) }
			Spacer(minLength: 12)
			legendRight
		}
		.font(Theme.font(12.5))
		.foregroundStyle(Theme.t3)
		.lineLimit(1)
	}

	@ViewBuilder private func readingBar(_ r: (name: String, used: UInt64, size: UInt64), _ f: Double) -> some View {
		GeometryReader { geo in
			let usedW = max(4, (geo.size.width - 2) * CGFloat(Double(r.used) / Double(r.size)))
			HStack(spacing: 2) {
				ZStack(alignment: .leading) {
					BarPiece(tone: 0.45, kind: .hidden)
					Rectangle().fill(Color.white.opacity(0.8)).frame(width: usedW * CGFloat(f))
						.animation(.linear(duration: 0.15), value: f)
				}
				.frame(width: usedW)
				BarPiece(tone: 0.3, kind: .free).frame(maxWidth: .infinity)
			}
		}
		.frame(height: 10)
		HStack(alignment: .firstTextBaseline) {
			Text("Reading \(r.name) · \(Int(f * 100))%").foregroundStyle(Theme.t2).truncationMode(.middle)
			Spacer(minLength: 12)
			Text("Used \(Fmt.size(r.used))" + (r.size > r.used ? "  ·  Free \(Fmt.size(r.size - r.used))" : ""))
		}
		.font(Theme.font(12.5))
		.foregroundStyle(Theme.t3)
		.lineLimit(1)
	}

	private func barLit(_ sg: Segment) -> Bool {
		guard let g = sg.group, let piece = model.hover?.piece else { return false }
		return piece == "g:\(g.rawValue)"
	}

	@ViewBuilder private func legendLeft(_ used: UInt64, _ free: UInt64) -> some View {
		let u = Text(Fmt.size(used)).foregroundColor(Theme.t1)
		let f = Text(Fmt.size(free)).foregroundColor(Theme.t1)
		if let s = model.snap, model.disk == nil {
			let hidden = s.notVisible
			ViewThatFits(in: .horizontal) {
				Text("Used \(u) = \(Fmt.size(used - min(used, hidden))) in files + \(Fmt.size(hidden)) not visible as files   ·   Free \(f)")
				Text("Used \(u)   ·   Free \(f)")
			}
		} else {
			Text("Used \(u)   ·   Free \(f)")
		}
	}

	@ViewBuilder private var legendRight: some View {
		if let s = model.snap, model.disk == nil, s.disk.purgeable > 100_000_000 {
			ViewThatFits(in: .horizontal) {
				Text("macOS can free \(Fmt.size(s.disk.purgeable)) more by itself when space runs low")
				Text("macOS can free \(Fmt.size(s.disk.purgeable)) more itself")
				Color.clear.frame(width: 0, height: 0)
			}
			.help("Its own caches, iCloud copies and snapshots: “available” in Finder counts them as free")
		} else {
			Text(statusLine).truncationMode(.tail)
		}
	}

	private var statusLine: String {
		switch model.phase {
		case .catchingUp: "Catching up with changes…"
		case .walking: "Reading the disk…"
		case .failed(let why): why
		default: ""
		}
	}
}

struct BarPiece: View {
	let tone: Double
	let kind: Piece.Kind

	var body: some View {
		switch kind {
		case .free:
			Rectangle().fill(.clear).overlay(
				Canvas { ctx, size in
					var x: CGFloat = 0
					while x < size.width {
						ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(.white.opacity(0.1)))
						x += 6
					}
				})
		case .hidden:
			Rectangle().fill(Color.white.opacity(tone * 0.5)).overlay(
				Canvas { ctx, size in
					var x: CGFloat = -size.height
					while x < size.width {
						var p = Path()
						p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
						ctx.stroke(p, with: .color(.black.opacity(0.45)), lineWidth: 1.5)
						x += 4
					}
				})
		default:
			Rectangle().fill(Color.white.opacity(tone * 0.85))
		}
	}
}

struct BarTip: View {
	let name: String
	let bytes: UInt64
	let used: UInt64

	var body: some View {
		HStack(spacing: 6) {
			Text(name).foregroundStyle(Theme.t1)
			Text(Fmt.size(bytes)).foregroundStyle(Theme.t2)
			Text(Fmt.share(bytes, of: used) + " of used").foregroundStyle(Theme.t3)
		}
		.font(Theme.font(12.5, .medium))
		.padding(.horizontal, 10).padding(.vertical, 6)
		.background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.16)))
		.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge, lineWidth: 0.5))
		.allowsHitTesting(false)
	}
}

struct ToastView: View {
	let model: AppModel

	var body: some View {
		Group {
			if let t = model.toast {
				HStack(spacing: 12) {
					Text(t.text).font(Theme.font(13)).foregroundStyle(Theme.t1).lineLimit(2)
					if let a = t.action, let run = t.run {
						Button(a) { model.dismissToast(); run() }.buttonStyle(LinkButton())
					}
				}
				.padding(.horizontal, 14).padding(.vertical, 8)
				.background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.16)))
				.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.edge, lineWidth: 0.5))
				.padding(.horizontal, 20)
				.transition(.opacity.combined(with: .offset(y: 8)))
				.allowsHitTesting(t.action != nil)
				.id(t.id)
			}
		}
		.animation(.easeOut(duration: 0.2), value: model.toast)
	}
}

struct IconButton: View {
	let symbol: String
	let help: String
	let enabled: Bool
	var size: CGFloat = 28
	let action: () -> Void
	@State private var over = false

	var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: size * 0.5, weight: .medium))
				.foregroundStyle(over && enabled ? Theme.t1 : Theme.t2)
				.frame(width: size, height: size)
				.background(RoundedRectangle(cornerRadius: 7).fill(over && enabled ? Theme.hover : .clear))
				.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.opacity(enabled ? 1 : 0.3)
		.onHover { over = $0 }
		.help(help)
	}
}

struct PrimaryButton: ButtonStyle {
	@Environment(\.isEnabled) private var enabled

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(Theme.font(13, .semibold))
			.foregroundStyle(Color(white: 0.05))
			.padding(.horizontal, 13).padding(.vertical, 7)
			.background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(configuration.isPressed ? 0.8 : 0.95)))
			.opacity(enabled ? 1 : 0.35)
			.lineLimit(1)
			.fixedSize(horizontal: false, vertical: true)
	}
}

struct GhostButton: ButtonStyle {
	@Environment(\.isEnabled) private var enabled

	func makeBody(configuration: Configuration) -> some View {
		GhostBody(configuration: configuration, enabled: enabled)
	}

	private struct GhostBody: View {
		let configuration: Configuration
		let enabled: Bool
		@State private var over = false
		var body: some View {
			configuration.label
				.font(Theme.font(13, .medium))
				.foregroundStyle(over && enabled ? Theme.t1 : Theme.t2)
				.padding(.horizontal, 13).padding(.vertical, 7)
				.background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(configuration.isPressed ? 0.16 : over && enabled ? 0.11 : 0.07)))
				.opacity(enabled ? 1 : 0.35)
				.lineLimit(1)
				.fixedSize(horizontal: false, vertical: true)
				.onHover { over = $0 }
		}
	}
}

struct CrumbButton: ButtonStyle {
	let here: Bool
	func makeBody(configuration: Configuration) -> some View {
		CrumbBody(configuration: configuration, here: here)
	}
	private struct CrumbBody: View {
		let configuration: Configuration
		let here: Bool
		@State private var over = false
		var body: some View {
			configuration.label
				.padding(.horizontal, 6).padding(.vertical, 4)
				.background(RoundedRectangle(cornerRadius: 6).fill(over && !here ? Theme.hover : .clear))
				.onHover { over = $0 }
		}
	}
}

struct WindowDragArea: NSViewRepresentable {
	final class DragView: NSView {
		override func mouseDown(with event: NSEvent) {
			if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
		}
	}
	func makeNSView(context: Context) -> NSView { DragView() }
	func updateNSView(_ nsView: NSView, context: Context) {}
}

final class Icons: @unchecked Sendable {
	static let shared = Icons()
	private let cache = NSCache<NSString, NSImage>()

	func icon(_ path: String) -> NSImage {
		if let i = cache.object(forKey: path as NSString) { return i }
		let i = NSWorkspace.shared.icon(forFile: path)
		cache.setObject(i, forKey: path as NSString)
		return i
	}
}
