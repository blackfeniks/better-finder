import AppKit
import SwiftUI

struct SheetHost: View {
	@Bindable var model: AppModel

	var body: some View {
		ZStack {
			if let sheet = model.sheet {
				Rectangle().fill(Color.black.opacity(0.55))
					.background(.ultraThinMaterial.opacity(0.6))
					.onTapGesture { model.sheet = nil }
					.transition(.opacity)
				Group {
					switch sheet {
					case .cleanup: CleanupCard(model: model)
					case .trash(let r): TrashCard(model: model, request: r)
					case .emptyTrash: EmptyTrashCard(model: model)
					case .password: PasswordCard(model: model)
					case .claudeKey: ClaudeKeyCard(model: model)
					}
				}
				.padding(.top, Theme.barHeight + 24).padding(.bottom, 24).padding(.horizontal, 24)
				.transition(.opacity.combined(with: .scale(scale: 0.98)))
			}
		}
		.animation(.easeOut(duration: 0.18), value: model.sheet?.id)
	}
}

struct Card<Content: View>: View {
	let width: CGFloat
	@ViewBuilder let content: () -> Content

	var body: some View {
		VStack(alignment: .leading, spacing: 0) { content() }
			.frame(maxWidth: width)
			.background(RoundedRectangle(cornerRadius: 16).fill(Theme.card))
			.overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.edge, lineWidth: 0.5))
			.shadow(color: .black.opacity(0.5), radius: 40, y: 20)
			.frame(maxHeight: .infinity, alignment: .top)
	}
}

struct CleanupCard: View {
	@Bindable var model: AppModel
	@State private var open: Set<String> = []
	@State private var history = false

	private var list: [Candidate] { model.snap?.cleanup ?? [] }

	private var rows: some View {
		VStack(alignment: .leading, spacing: 1) {
			ForEach([Candidate.Safety.safe, .check, .careful], id: \.self) { safety in
				let part = list.filter { $0.safety == safety }
				if !part.isEmpty {
					HStack {
						Text(safety.title).font(Theme.font(13, .semibold)).foregroundStyle(Theme.t1)
						Text(safety.longHint).font(Theme.font(12.5)).foregroundStyle(Theme.t3).lineLimit(1)
						Spacer()
						Text(Fmt.size(part.reduce(0) { $0 + $1.bytes })).font(Theme.font(12.5)).foregroundStyle(Theme.t3)
					}
					.padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 6)
					ForEach(part, id: \.title) { c in
						CandidateRow(model: model, c: c, expanded: open.contains(AppModel.id(c))) {
							let id = AppModel.id(c)
							if open.contains(id) { open.remove(id) } else { open.insert(id) }
						}
					}
				}
			}
			if list.isEmpty {
				Text("Nothing obvious to remove: no big caches, logs, leftovers or old installers.")
					.font(Theme.font(13)).foregroundStyle(Theme.t3).padding(22)
			}
			if !model.freed.isEmpty { FreedList(model: model, expanded: $history) }
		}
		.padding(.horizontal, 10).padding(.bottom, 8)
	}

	var body: some View {
		let all = list.reduce(UInt64(0)) { $0 + $1.bytes }
		Card(width: 760) {
			HStack(alignment: .lastTextBaseline) {
				Text(Fmt.size(all)).font(.system(size: 34, weight: .light)).monospacedDigit().foregroundStyle(Theme.t1)
				Text("you may not need").font(Theme.font(14)).foregroundStyle(Theme.t3)
				Spacer()
				Text("Chosen \(Fmt.size(model.cleanupChosenBytes))").font(Theme.font(13)).foregroundStyle(Theme.t2)
			}
			.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 6)
			Text("Kept up to date while Better Finder is open. Ticked rows go to the Trash (Put Back works); tick “Empty the Trash” to free the space right away.")
				.font(Theme.font(13)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
				.padding(.horizontal, 22).padding(.bottom, 8)
			ViewThatFits(in: .vertical) {
				rows
				ScrollView { rows }
			}
			Hairline()
			HStack(spacing: 8) {
				Text(model.emptyTrashToo ? "Frees the space now: the Trash is emptied at the end" : "Frees the space once the Trash is emptied")
					.font(Theme.font(12.5)).foregroundStyle(Theme.t3).lineLimit(2).layoutPriority(-1)
				Spacer()
				Button("Close") { model.sheet = nil }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
				Button("Free up \(Fmt.size(model.cleanupChosenBytes))…") { model.cleanupGo() }
					.buttonStyle(PrimaryButton())
					.disabled(model.cleanupChosenBytes == 0 || model.emptying)
			}
			.padding(.horizontal, 18).padding(.vertical, 14)
		}
	}
}

extension Candidate.Safety {
	var longHint: String {
		switch self {
		case .safe: "comes back by itself"
		case .check: "your own files — look first"
		case .careful: "works without it, a long download to get back"
		}
	}

	var after: String {
		switch self {
		case .safe: "The app makes it again when it needs it; the first launch after may be a bit slower."
		case .check: "Your own data: look before removing."
		case .careful: "Works without it, but getting it back is a long download."
		}
	}
}

struct CandidateRow: View {
	@Bindable var model: AppModel
	let c: Candidate
	let expanded: Bool
	let toggle: () -> Void

	var body: some View {
		let tickable = AppModel.tickable(c)
		VStack(alignment: .leading, spacing: 6) {
			HStack(alignment: .center, spacing: 10) {
				if tickable {
					CheckBox(on: model.isChosen(c)) { model.toggle(c) }
				} else {
					Image(systemName: "hand.point.up.left").font(.system(size: 12)).foregroundStyle(Theme.t3).frame(width: 18)
				}
				Image(systemName: c.isTrash ? "trash" : "folder").font(.system(size: 13)).foregroundStyle(Theme.t3).frame(width: 18)
				VStack(alignment: .leading, spacing: 1) {
					Text(c.title).font(Theme.font(14)).foregroundStyle(Theme.t1).lineLimit(1)
					Text(c.detail).font(Theme.font(12.5)).foregroundStyle(Theme.t3).lineLimit(1).truncationMode(.middle)
				}
				Spacer(minLength: 8)
				VStack(alignment: .trailing, spacing: 2) {
					Text(Fmt.size(c.bytes)).font(Theme.font(14)).foregroundStyle(Theme.t1)
					if c.isTrash {
						Button("Look inside ›") { model.sheet = nil; model.showGroup(.trash) }.buttonStyle(LinkButton())
					} else if tickable {
						Button(expanded ? "Hide" : "What exactly ›", action: toggle).buttonStyle(LinkButton())
					} else if c.action != nil {
						Button(expanded ? "Hide" : "How ›", action: toggle).buttonStyle(LinkButton())
					}
				}
			}
			if expanded {
				VStack(alignment: .leading, spacing: 5) {
					Text(c.action ?? c.safety.after).font(Theme.font(12.5)).foregroundStyle(Theme.t2)
					ForEach(c.paths, id: \.self) { p in
						HStack(alignment: .firstTextBaseline, spacing: 12) {
							Text(Fmt.home(p)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.t3)
								.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
							Spacer(minLength: 8)
							Button("Show in Finder") { model.reveal([p]) }.buttonStyle(LinkButton())
						}
					}
				}
				.padding(.leading, 56).padding(.top, 2).padding(.bottom, 4)
			}
		}
		.padding(.horizontal, 12).padding(.vertical, 8)
		.background(RoundedRectangle(cornerRadius: Theme.corner).fill(expanded ? Color.white.opacity(0.035) : .clear))
	}
}

struct FreedList: View {
	let model: AppModel
	@Binding var expanded: Bool

	var body: some View {
		let shown = expanded ? Array(model.freed.prefix(20)) : Array(model.freed.prefix(4))
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text("Freed before").font(Theme.font(13, .semibold)).foregroundStyle(Theme.t1)
				Text("by Better Finder").font(Theme.font(12.5)).foregroundStyle(Theme.t3)
				Spacer()
				if model.freed.count > 4 {
					Button(expanded ? "Less" : "All \(min(20, model.freed.count))") { expanded.toggle() }.buttonStyle(LinkButton())
				}
			}
			.padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 6)
			ForEach(shown) { f in
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Text(Fmt.when(f.date)).font(Theme.font(12.5)).foregroundStyle(Theme.t3).frame(width: 104, alignment: .leading)
					VStack(alignment: .leading, spacing: 1) {
						Text(Self.what(f)).font(Theme.font(13)).foregroundStyle(Theme.t2).lineLimit(1)
						Text(Self.names(f)).font(Theme.font(12)).foregroundStyle(Theme.t3).lineLimit(1).truncationMode(.tail)
					}
					Spacer(minLength: 8)
					Text(Fmt.size(f.total)).font(Theme.font(13)).foregroundStyle(Theme.t2)
					if model.canPutBack(f) {
						Button("Put Back") { model.putBack(f) }.buttonStyle(LinkButton())
					}
				}
				.padding(.horizontal, 12).padding(.vertical, 5)
			}
		}
	}

	static func what(_ f: Freed) -> String {
		switch f.kind {
		case .trash: "Moved to the Trash"
		case .empty: "Emptied the Trash"
		case .delete: "Deleted for good"
		}
	}

	static func names(_ f: Freed) -> String {
		if f.kind == .empty { return "everything that was in the Trash" }
		let names = f.items.map { ($0.path as NSString).lastPathComponent }
		return names.prefix(4).joined(separator: ", ") + (names.count > 4 ? " and \(names.count - 4) more" : "")
	}
}

struct CheckBox: View {
	let on: Bool
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			ZStack {
				RoundedRectangle(cornerRadius: 5).fill(on ? Theme.t1 : .clear)
				RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Theme.t1 : Color.white.opacity(0.3), lineWidth: 1.5)
				if on { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(white: 0.05)) }
			}
			.frame(width: 18, height: 18)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}
}

struct LinkButton: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		LinkBody(configuration: configuration)
	}
	private struct LinkBody: View {
		let configuration: Configuration
		@State private var over = false
		var body: some View {
			configuration.label
				.font(Theme.font(12.5, .medium))
				.foregroundStyle(over ? Theme.t1 : Theme.t2)
				.lineLimit(1)
				.fixedSize()
				.onHover { over = $0 }
		}
	}
}

struct TrashCard: View {
	@Bindable var model: AppModel
	let request: TrashRequest

	var body: some View {
		let trash = model.trashBytes
		Card(width: 640) {
			VStack(alignment: .leading, spacing: 4) {
				Text(request.forever ? "Delete for good?" : request.emptyAfter ? "Free up space?" : "Move to Trash?")
					.font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.t1)
				Text(request.items.count == 1 ? request.title : "\(request.title) — \(Fmt.plural(request.items.count, "item"))")
					.font(Theme.font(13)).foregroundStyle(Theme.t3).lineLimit(2)
			}
			.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
			let list = VStack(alignment: .leading, spacing: 6) {
				ForEach(request.items, id: \.path) { it in
					HStack(alignment: .firstTextBaseline) {
						Text(Fmt.home(it.path)).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Theme.t2)
							.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
						Spacer(minLength: 12)
						Text(Fmt.size(it.bytes)).font(Theme.font(13)).foregroundStyle(Theme.t1)
					}
				}
			}
			.padding(.horizontal, 22)
			if request.items.count > 12 {
				ScrollView { list }.frame(maxHeight: 340)
			} else {
				list
			}
			Group {
				if request.forever {
					Text("They are removed from the Trash and cannot be put back.")
				} else if request.emptyAfter {
					Text("They go to the Trash, then the Trash is emptied — \(Fmt.size(trash + request.total)) deleted for good, including what was already there. This cannot be undone.")
				} else {
					Text("You can put them back from the Trash (or from Free up › Freed before) until it is emptied. Apps that are open may need quitting first.")
				}
			}
			.font(Theme.font(12.5)).foregroundStyle(request.forever || request.emptyAfter ? Theme.t2 : Theme.t3)
			.fixedSize(horizontal: false, vertical: true)
			.padding(.horizontal, 22).padding(.vertical, 12)
			Hairline()
			HStack(spacing: 8) {
				Spacer()
				Button("Cancel") { model.sheet = nil }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
				Button(request.forever ? "Delete for good · \(Fmt.size(request.total))"
				       : request.emptyAfter ? "Move and empty the Trash · \(Fmt.size(trash + request.total))"
				       : "Move to Trash · \(Fmt.size(request.total))") {
					model.confirm(request)
				}
				.buttonStyle(PrimaryButton())
			}
			.padding(.horizontal, 18).padding(.vertical, 14)
		}
		.frame(maxHeight: .infinity, alignment: .top)
	}
}

struct EmptyTrashCard: View {
	@Bindable var model: AppModel

	var body: some View {
		let others = model.otherTrashes
		Card(width: 520) {
			VStack(alignment: .leading, spacing: 6) {
				Text("Empty the Trash?").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.t1)
				Text("Everything in it, \(Fmt.size(model.trashBytes)), is deleted for good. This can’t be undone."
				     + (others.isEmpty ? "" : " The Trash on \(others.map(\.name).joined(separator: ", ")) is emptied too."))
					.font(Theme.font(13)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
			}
			.padding(22)
			Hairline()
			HStack(spacing: 8) {
				Button("Show the Trash") { model.sheet = nil; model.showGroup(.trash) }.buttonStyle(GhostButton())
				Spacer()
				Button("Cancel") { model.sheet = nil }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
				Button("Empty Trash") {
					model.sheet = nil
					model.emptyTrash()
				}
				.buttonStyle(PrimaryButton())
			}
			.padding(.horizontal, 18).padding(.vertical, 14)
		}
	}
}

struct ClaudeKeyCard: View {
	@Bindable var model: AppModel
	@State private var key = ""
	@FocusState private var focused: Bool

	var body: some View {
		Card(width: 540) {
			VStack(alignment: .leading, spacing: 8) {
				Text("Claude API key").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.t1)
				Text("“What is this?” sends Claude a description of the file or folder — its name, path, size and what is inside, never the contents — and shows the answer. About half a cent per question; answers are kept, so asking again is free. The key is kept in your keychain.")
					.font(Theme.font(13)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
				SecureField("sk-ant-…", text: $key)
					.textFieldStyle(.plain)
					.font(Theme.font(14))
					.padding(.horizontal, 12).padding(.vertical, 9)
					.background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge, lineWidth: 0.5))
					.focused($focused)
					.onSubmit { model.setClaudeKey(key) }
					.padding(.top, 6)
			}
			.padding(22)
			Hairline()
			HStack(spacing: 8) {
				Spacer()
				Button("Cancel") { model.sheet = nil }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
				Button("Save") { model.setClaudeKey(key) }.buttonStyle(PrimaryButton()).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
			}
			.padding(.horizontal, 18).padding(.vertical, 14)
		}
		.onAppear { focused = true }
	}
}

struct PasswordCard: View {
	@Bindable var model: AppModel
	@State private var password = ""
	@FocusState private var focused: Bool

	var body: some View {
		Card(width: 540) {
			VStack(alignment: .leading, spacing: 8) {
				Text("See inside closed system folders").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.t1)
				Text("macOS keeps some of its folders closed to every app, even with Full Disk Access: system databases, logs, Spotlight’s index. With your Mac password Better Finder can read them — only read, it never changes anything there. The password is kept in your keychain, so it is asked once.")
					.font(Theme.font(13)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
				SecureField("Mac password", text: $password)
					.textFieldStyle(.plain)
					.font(Theme.font(14))
					.padding(.horizontal, 12).padding(.vertical, 9)
					.background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
					.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.edge, lineWidth: 0.5))
					.focused($focused)
					.onSubmit { model.allowAdmin(password) }
					.padding(.top, 6)
				if let e = model.passwordError {
					Text(e).font(Theme.font(12.5)).foregroundStyle(Theme.t2).fixedSize(horizontal: false, vertical: true)
				}
			}
			.padding(22)
			Hairline()
			HStack(spacing: 8) {
				if model.passwordChecking { ProgressView().controlSize(.small) }
				Spacer()
				Button("Cancel") { model.sheet = nil }.buttonStyle(GhostButton()).keyboardShortcut(.cancelAction)
				Button("Allow") { model.allowAdmin(password) }
					.buttonStyle(PrimaryButton())
					.disabled(password.isEmpty || model.passwordChecking)
			}
			.padding(.horizontal, 18).padding(.vertical, 14)
		}
		.onAppear { focused = true }
	}
}
