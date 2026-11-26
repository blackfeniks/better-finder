import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
	private var window: NSWindow!
	private var model: AppModel!
	private var keys: Any?

	static func run() {
		let app = NSApplication.shared
		let delegate = AppDelegate()
		app.delegate = delegate
		app.setActivationPolicy(.regular)
		withExtendedLifetime(delegate) { app.run() }
	}

	func applicationDidFinishLaunching(_ note: Notification) {
		model = AppModel()
		window = Self.makeWindow(RootView(model: model))
		window.delegate = self
		if let f = Self.savedFrame() { window.setFrame(f, display: false) } else { window.center() }
		buildMenu()
		window.makeKeyAndOrderFront(nil)
		NSApp.activate()
		keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
			guard let self, e.window === self.window else { return e }
			return self.key(e) ? nil : e
		}
	}

	private func key(_ e: NSEvent) -> Bool {
		let m = model!
		let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
		if e.keyCode == 53 && mods.isEmpty { m.escape(); return true }
		guard m.sheet == nil else { return false }
		switch (e.keyCode, mods) {
		case (126, .command): m.back()
		case (125, .command), (36, []), (76, []): m.openSelection()
		case (126, []), (126, .shift): m.moveSelection(-1, extend: mods == .shift)
		case (125, []), (125, .shift): m.moveSelection(1, extend: mods == .shift)
		case (51, .command), (117, []):
			guard !m.selection.isEmpty else { return false }
			m.askTrashChosen()
		case (34, .command): m.explainChosen()
		case (0, .command): m.selectAll()
		default: return false
		}
		return true
	}

	func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
		Self.clamp(sender, frameSize)
	}

	static func clamp(_ w: NSWindow, _ size: NSSize) -> NSSize {
		let min = w.frameRect(forContentRect: NSRect(origin: .zero, size: Theme.windowMin)).size
		return NSSize(width: max(size.width, min.width), height: max(size.height, min.height))
	}

	func windowWillEnterFullScreen(_ notification: Notification) {
		window.toolbar = nil
		model.fullScreen = true
	}

	func windowWillExitFullScreen(_ notification: Notification) {
		window.toolbar = Self.toolbar()
		model.fullScreen = false
	}

	private static func toolbar() -> NSToolbar {
		let tb = NSToolbar(identifier: "bar")
		tb.displayMode = .iconOnly
		return tb
	}

	static func makeWindow<V: View>(_ root: V) -> NSWindow {
		let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
		                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
		                 backing: .buffered, defer: false)
		w.titlebarAppearsTransparent = true
		w.titleVisibility = .hidden
		w.title = "Better Finder"
		w.toolbar = toolbar()
		w.toolbarStyle = .unified
		w.titlebarSeparatorStyle = .none
		w.appearance = NSAppearance(named: .darkAqua)
		w.backgroundColor = NSColor(red: 0.045, green: 0.045, blue: 0.052, alpha: 1)
		w.isReleasedWhenClosed = false
		w.tabbingMode = .disallowed
		w.collectionBehavior.insert(.fullScreenPrimary)
		let host = NSHostingView(rootView: root)
		host.sizingOptions = []
		w.contentView = host
		w.contentMinSize = Theme.windowMin
		w.minSize = Theme.windowMin
		return w
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		Self.saveFrame(window.frame)
		model.engine.saveNow()
		return .terminateNow
	}

	private static var frameFile: URL { Store().folder.appendingPathComponent("window.txt") }

	static func savedFrame() -> NSRect? {
		guard let s = try? String(contentsOf: frameFile, encoding: .utf8) else { return nil }
		let r = NSRectFromString(s)
		guard r.width >= Theme.windowMin.width, r.height >= Theme.windowMin.height,
		      NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) else { return nil }
		return r
	}

	static func saveFrame(_ r: NSRect) {
		try? FileManager.default.createDirectory(at: frameFile.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? NSStringFromRect(r).write(to: frameFile, atomically: true, encoding: .utf8)
	}

	private func buildMenu() {
		let main = NSMenu()
		let appItem = NSMenuItem()
		let appMenu = NSMenu()
		appMenu.addItem(withTitle: "About Better Finder", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
		appMenu.addItem(.separator())
		appMenu.addItem(withTitle: "Hide Better Finder", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
		appMenu.addItem(withTitle: "Quit Better Finder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		appItem.submenu = appMenu
		main.addItem(appItem)

		let fileItem = NSMenuItem()
		let file = NSMenu(title: "File")
		file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
		fileItem.submenu = file
		main.addItem(fileItem)

		let editItem = NSMenuItem()
		let edit = NSMenu(title: "Edit")
		edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
		editItem.submenu = edit
		main.addItem(editItem)

		let viewItem = NSMenuItem()
		let view = NSMenu(title: "View")
		view.addItem(item("By Meaning", "1") { $0.setMode(.meaning) })
		view.addItem(item("Folders", "2") { $0.setMode(.folders) })
		view.addItem(.separator())
		view.addItem(item("Back", "[") { $0.back() })
		view.addItem(item("Free Up Space…", "k", [.command, .shift]) { $0.sheet = .cleanup })
		view.addItem(item("Empty Trash…", "\u{8}", [.command, .shift]) { $0.sheet = .emptyTrash })
		viewItem.submenu = view
		main.addItem(viewItem)

		let winItem = NSMenuItem()
		let win = NSMenu(title: "Window")
		win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
		win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
		let fs = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
		fs.keyEquivalentModifierMask = [.command, .control]
		win.addItem(fs)
		winItem.submenu = win
		main.addItem(winItem)
		NSApp.mainMenu = main
		NSApp.windowsMenu = win
	}

	private var actions: [MenuAction] = []

	private func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
	                  _ act: @escaping @MainActor (AppModel) -> Void) -> NSMenuItem {
		let a = MenuAction { [weak self] in if let m = self?.model { act(m) } }
		actions.append(a)
		let i = NSMenuItem(title: title, action: #selector(MenuAction.fire), keyEquivalent: key)
		i.keyEquivalentModifierMask = mods
		i.target = a
		return i
	}
}

@MainActor
final class MenuAction: NSObject {
	let body: () -> Void
	init(_ body: @escaping () -> Void) { self.body = body }
	@objc func fire() { body() }
}

@MainActor
enum Shots {
	static func run(_ dir: String) -> Int32 {
		_ = NSApplication.shared
		NSApp.setActivationPolicy(.prohibited)
		RingView.instant = true
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		guard let container = Disks.boot() else { print("no boot disk"); return 1 }
		let disk = DiskScan(container: container)
		for line in Store().open(disk) { print("  " + line) }
		let snap = Snapshot(id: 1, disk: disk, others: [:], walking: [])
		let model = AppModel(start: false)
		model.adopt(snap)
		let home = NSHomeDirectory()
		let biggestApp = snap.meaning.groups.first { $0.0 == .apps }?.1.first?.id ?? ""

		var states: [(String, () -> Void)] = [
			("01-overview", {}),
			("02-overview-hover", { model.hoverRing("g:\(Category.apps.rawValue)") }),
			("03-overview-hover-item", { model.hoverRing("i:\(biggestApp)") }),
			("04-group-apps", { model.open(.group(.apps), via: "g:\(Category.apps.rawValue)") }),
			("05-item", { model.open(.item(biggestApp), via: "i:\(biggestApp)") }),
			("06-group-macos", { model.pop(to: 0); model.open(.group(.macOS), via: "g:\(Category.macOS.rawValue)") }),
			("07-folders-root", { model.pop(to: 0); model.setMode(.folders) }),
		]
		if let n = snap.tree.locate(home + "/Downloads") {
			states.append(("08-folder-downloads", { model.open(.folder(n), via: nil); model.loadListingNow() }))
		}
		if let n = snap.tree.locate(home + "/Library/Application Support") {
			states.append(("09-folder-appsupport", { model.open(.folder(n), via: nil); model.loadListingNow() }))
		}
		if let n = snap.tree.locate(home + "/.Trash") {
			states.append(("10-trash", { model.pop(to: 0); model.setMode(.meaning); model.open(.folder(n), via: "g:\(Category.trash.rawValue)"); model.loadListingNow() }))
		}
		states.append(("11-chosen", {
			model.pop(to: 0); model.setMode(.folders)
			if let n = snap.tree.locate(home + "/Library/Application Support") { model.open(.folder(n), via: nil); model.loadListingNow() }
			model.choose(rows: 1, to: 4, adding: [])
		}))
		if let n = snap.tree.locate(home + "/Library/Group Containers"),
		   let e = snap.tree.entries(n).first(where: { $0.name.contains("keepcoder.Telegram") }) {
			states.append(("11b-long-name", {
				model.clearSelection(); model.pop(to: 0); model.setMode(.folders)
				model.open(.folder(n), via: nil); model.loadListingNow()
				model.hoverRing(Content.entryKey(e))
			}))
			states.append(("11c-explain", {
				if let r = model.panel?.rows.first(where: { $0.name.contains("keepcoder.Telegram") }) {
					model.debugExplanation(Explanation(row: r, state: .answer("Это общая папка Telegram для macOS: здесь хранятся кэш медиа из чатов, база сообщений и настройки. Если удалить, Telegram скачает всё заново при входе, но пропадут локальные черновики и загруженные файлы.", cost: 0.0024, saved: false)))
				}
			}))
		}
		states.append(("12-cleanup", { model.closeExplanation(); model.clearSelection(); model.sheet = .cleanup }))
		states.append(("13-cleanup-confirm", { model.sheet = .cleanup; model.cleanupGo() }))
		states.append(("14-empty-trash", { model.sheet = .emptyTrash }))

		let size = NSSize(width: 1320, height: 860)
		let root = RootView(model: model)
		let host = NSHostingView(rootView: root)
		let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
		window.appearance = NSAppearance(named: .darkAqua)
		window.contentView = host
		host.frame = NSRect(origin: .zero, size: size)
		func shoot(_ name: String) {
			for _ in 0..<4 {
				host.layoutSubtreeIfNeeded()
				RunLoop.current.run(until: Date().addingTimeInterval(0.06))
			}
			guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
			host.cacheDisplay(in: host.bounds, to: rep)
			let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".jpg")
			try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.86])?.write(to: url)
			print("✓ \(url.path)")
		}
		for (name, setup) in states {
			setup()
			shoot(name)
		}
		model.sheet = nil
		model.clearSelection()
		for (w, h) in [(Theme.windowMin.width, Theme.windowMin.height), (1000, 680), (1512, 945), (2200, 1300)] {
			let sz = NSSize(width: w, height: h)
			window.setContentSize(sz)
			host.frame = NSRect(origin: .zero, size: sz)
			model.pop(to: 0); model.setMode(.meaning)
			shoot("size-\(Int(w))x\(Int(h))-overview")
			model.setMode(.folders)
			if let n = snap.tree.locate(home + "/Library/Application Support") { model.open(.folder(n), via: nil); model.loadListingNow() }
			shoot("size-\(Int(w))x\(Int(h))-folder")
			model.pop(to: 0); model.setMode(.meaning)
		}
		window.setContentSize(size); host.frame = NSRect(origin: .zero, size: size)
		model.setPanelWidth(Theme.panelMax, save: false); shoot("panel-wide")
		model.setPanelWidth(Theme.panelMin, save: false); shoot("panel-narrow")
		model.setPanelWidth(Theme.panelDefault, save: false)
		let reading = AppModel(start: false)
		reading.debugPhase(.walking(disk: "Macintosh HD", files: 812_345, folders: 90_000, bytes: 141_000_000_000, used: 221_000_000_000))
		host.rootView = RootView(model: reading)
		shoot("15-reading")
		host.rootView = RootView(model: model)
		model.sheet = nil
		model.setMode(.meaning)
		model.pop(to: 0)
		for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
		func ring(_ v: NSView) -> RingView? { (v as? RingView) ?? v.subviews.lazy.compactMap(ring).first }
		for (name, go) in [("12-zoom-in", { model.open(.group(.apps), via: "g:\(Category.apps.rawValue)") }),
		                   ("13-zoom-out", { model.back() })] as [(String, () -> Void)] {
			RingView.instant = false
			go()
			for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
			for t in [0.2, 0.45, 0.7] {
				ring(host)?.freeze(at: t)
				host.layoutSubtreeIfNeeded()
				guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
				host.cacheDisplay(in: host.bounds, to: rep)
				let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(Int(t * 100)).jpg")
				try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])?.write(to: url)
				print("✓ \(url.path)")
			}
			ring(host)?.freeze(at: 1)
		}
		return 0
	}
}

@MainActor
enum WindowCheck {
	static func run(_ dir: String) -> Int32 {
		_ = NSApplication.shared
		NSApp.setActivationPolicy(.prohibited)
		RingView.instant = true
		guard let container = Disks.boot() else { return 1 }
		let disk = DiskScan(container: container)
		_ = Store().open(disk)
		let model = AppModel(start: false)
		model.adopt(Snapshot(id: 1, disk: disk, others: [:], walking: []))
		let w = AppDelegate.makeWindow(RootView(model: model))
		w.setFrame(NSRect(x: 0, y: 0, width: 1320, height: 860), display: false)
		guard let host = w.contentView, let frame = host.superview else { return 1 }
		for _ in 0..<4 { frame.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
		var failed = 0
		let y = w.frame.height - 26
		for (name, x) in [("back", 92.0), ("crumb", 150.0), ("mode switch", 1110.0), ("free up", 1250.0), ("empty bar", 700.0)] {
			let hit = frame.hitTest(NSPoint(x: x, y: y))
			let inHost = hit.map { $0.isDescendant(of: host) } ?? false
			print("  \(name) at x=\(Int(x)): \(hit.map { String(describing: type(of: $0)) } ?? "nothing") — \(inHost ? "our content ✓" : "title bar ✗")")
			if !inHost && name != "empty bar" { failed += 1 }
		}
		for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
			if let v = w.standardWindowButton(b) {
				let r = v.convert(v.bounds, to: nil)
				print("  window button \(b.rawValue): x \(Int(r.minX))…\(Int(r.maxX)), centre \(Int(w.frame.height - r.midY)) pt from the top")
			}
		}
		let tiny = AppDelegate.clamp(w, NSSize(width: 200, height: 150))
		let content = w.contentRect(forFrameRect: NSRect(origin: .zero, size: tiny)).size
		print("  dragged to 200×150 the window stays \(Int(tiny.width))×\(Int(tiny.height)) (content \(Int(content.width))×\(Int(content.height)))")
		if content.width < Theme.windowMin.width - 1 || content.height < Theme.windowMin.height - 1 {
			failed += 1; print("  ✗ the window could get smaller than the layout allows")
		}
		if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
			frame.cacheDisplay(in: frame.bounds, to: rep)
			try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
			let url = URL(fileURLWithPath: dir).appendingPathComponent("window.jpg")
			try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])?.write(to: url)
			print("  ✓ \(url.path)")
		}
		return failed == 0 ? 0 : 1
	}
}
