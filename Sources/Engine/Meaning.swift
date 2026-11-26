import Foundation

enum Marks {
	static let git: UInt16 = 1
	static let node: UInt16 = 2
	static let rust: UInt16 = 4
	static let go: UInt16 = 8
	static let python: UInt16 = 16
	static let swift: UInt16 = 32
	static let build: UInt16 = 64
	static let notes: UInt16 = 128
	static let readme: UInt16 = 256
	static let strong: UInt16 = git | node | rust | go | python | swift | build | notes

	private static let table: [String: UInt16] = [
		".git": git, "package.json": node, "Cargo.toml": rust, "go.mod": go,
		"pyproject.toml": python, "requirements.txt": python, "setup.py": python,
		"Package.swift": swift, "build.sh": build, "Makefile": build, "CMakeLists.txt": build,
		"CLAUDE.md": notes, "AGENTS.md": notes, "README.md": readme, "README": readme,
	]

	static func of(_ name: String) -> UInt16 {
		if let b = table[name] { return b }
		if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") { return swift }
		return 0
	}
}

enum Category: Int, CaseIterable, Sendable {
	case apps, games, projects, models, developer, messages, media, macOS, trash, other, hidden

	var symbol: String {
		switch self {
		case .apps: "square.grid.2x2"
		case .games: "gamecontroller"
		case .projects: "hammer"
		case .models: "cpu"
		case .developer: "terminal"
		case .messages: "bubble.left.and.bubble.right"
		case .media: "photo.on.rectangle"
		case .macOS: "apple.logo"
		case .trash: "trash"
		case .other: "doc.on.doc"
		case .hidden: "eye.slash"
		}
	}

	var title: String {
		switch self {
		case .apps: "Apps"
		case .games: "Games"
		case .projects: "Projects"
		case .models: "AI models"
		case .developer: "Developer"
		case .messages: "Messages"
		case .media: "Photos, music & video"
		case .macOS: "macOS"
		case .trash: "Trash"
		case .other: "Other files"
		case .hidden: "Not visible as files"
		}
	}
}

enum Kind: Int, CaseIterable, Sendable {
	case files, models, media, dependencies, build, git, archives

	var title: String {
		switch self {
		case .files: "Files"
		case .models: "Models"
		case .media: "Media"
		case .dependencies: "Dependencies"
		case .build: "Build output"
		case .git: "Git history"
		case .archives: "Archives"
		}
	}

	static func folder(_ name: String) -> Kind? {
		switch name {
		case "node_modules", ".venv", "venv", "Pods", ".pnpm-store", "site-packages", "Vendor", "vendor", ".gradle":
			.dependencies
		case ".build", "build", "dist", "target", "DerivedData", ".next", ".nuxt", ".output", "out":
			.build
		case ".git":
			.git
		case "Models", "models", "checkpoints", "weights":
			.models
		default:
			nil
		}
	}

	static func file(_ name: String) -> Kind? {
		let ext = (name as NSString).pathExtension.lowercased()
		switch ext {
		case "gguf", "safetensors", "onnx", "pt", "pth", "ckpt", "mlmodel", "tflite", "npz", "ggml", "mlx": return .models
		case "bin" where name.lowercased().contains("model") || name.hasPrefix("ggml"): return .models
		case "mp4", "mov", "mkv", "avi", "m4v", "webm", "png", "jpg", "jpeg", "heic", "tif", "tiff", "psd", "exr",
		     "wav", "mp3", "m4a", "flac", "aif", "aiff", "blend": return .media
		case "zip", "dmg", "pkg", "tar", "gz", "tgz", "7z", "rar", "iso", "xip": return .archives
		default: return nil
		}
	}
}

final class Item: @unchecked Sendable {
	let id: String
	let name: String
	let group: Category
	var detail: String
	var bytes: UInt64 = 0
	var files: UInt64 = 0
	var parts: [Part] = []
	var kinds: [Kind: UInt64] = [:]
	var bundle: String?

	struct Part: Sendable {
		let label: String
		let path: String
		var bytes: UInt64
	}

	init(id: String, name: String, group: Category, detail: String) {
		self.id = id; self.name = name; self.group = group; self.detail = detail
	}
}

final class Meaning: @unchecked Sendable {
	let disk: DiskScan
	let home: String
	private(set) var items: [Item] = []
	private var byID: [String: Int] = [:]

	private var claims: [String: [Int32: (item: Int, label: String)]] = [:]
	private(set) var owners: [String: [Int32]] = [:]

	init(disk: DiskScan, home: String = NSHomeDirectory()) {
		self.disk = disk
		self.home = home
		build()
	}

	var groups: [(Category, [Item])] {
		Category.allCases.map { g in (g, items.filter { $0.group == g && $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }) }
	}

	func total(_ g: Category) -> UInt64 { items.filter { $0.group == g }.reduce(0) { $0 + $1.bytes } }
	var total: UInt64 { items.reduce(0) { $0 + $1.bytes } }

	func item(id: String) -> Item? { byID[id].map { items[$0] } }

	func hasOtherClaims(_ scan: VolumeScan, _ dir: Int, besides item: Item) -> Bool {
		guard let dev = device(of: scan), let list = claims[dev] else { return false }
		for (d, c) in list where items[c.item] !== item {
			var j = Int(d)
			while j > dir { j = Int(scan.parents[j]) }
			if j == dir { return true }
		}
		return false
	}

	func owner(_ scan: VolumeScan, _ dir: Int) -> Item? {
		guard let dev = device(of: scan), let list = owners[dev], dir < list.count, list[dir] >= 0 else { return nil }
		return items[Int(list[dir])]
	}

	private func build() {
		claimVolumes()
		claimHome()
		claimApps()
		claimKnown()
		claimProjects()
		claimTrash()
		assign()
		addHidden()
		for it in items { it.parts.sort { $0.bytes > $1.bytes } }
	}

	@discardableResult
	private func item(_ id: String, _ name: String, _ group: Category, detail: String = "") -> Int {
		if let i = byID[id] { return i }
		items.append(Item(id: id, name: name, group: group, detail: detail))
		byID[id] = items.count - 1
		return items.count - 1
	}

	private func device(of scan: VolumeScan) -> String? {
		disk.scans.first { $0.value === scan }?.key
	}

	@discardableResult
	private func claim(_ path: String, _ item: Int, _ label: String? = nil) -> Bool {
		let logical = expand(path)
		guard let (scan, dir) = disk.locate(logical), let dev = device(of: scan) else { return false }
		claims[dev, default: [:]][Int32(dir)] = (item, label ?? display(logical))
		return true
	}

	private func claim(_ scan: VolumeScan, _ dir: Int, _ item: Int, _ label: String) {
		guard let dev = device(of: scan) else { return }
		claims[dev, default: [:]][Int32(dir)] = (item, label)
	}

	private func expand(_ p: String) -> String { p.hasPrefix("~") ? home + p.dropFirst() : p }

	func display(_ path: String) -> String {
		path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
	}

	private func subfolders(_ path: String) -> [(VolumeScan, Int, String)] {
		guard let (scan, dir) = disk.locate(expand(path)) else { return [] }
		return scan.children(of: dir).map { (scan, Int($0), scan.names[Int($0)]) }
	}

	private func logical(_ scan: VolumeScan, _ i: Int) -> String { disk.logicalPath(scan, i) }

	private func claimVolumes() {
		for v in disk.container.volumes {
			guard let scan = disk.scans[v.device] else { continue }
			switch v.role {
			case "Data":
				claim(scan, 0, item("other:/", "Loose files at the disk's root", .other), "/")
				for (s, i, name) in subfolders("/System/Volumes/Data") {
					claim(s, i, item("other:/" + name, "/" + name, .other), "/" + name)
				}
			case "System":
				claim(scan, 0, item("macos:system", "macOS itself", .macOS, detail: "sealed system volume"), "System volume")
			case "Preboot":
				claim(scan, 0, item("macos:preboot", "Boot files & system images", .macOS, detail: "Safari, system libraries, Rosetta"), "Preboot volume")
			case "Recovery":
				claim(scan, 0, item("macos:recovery", "Recovery", .macOS), "Recovery volume")
			case "VM":
				claim(scan, 0, item("macos:vm", "Swap", .macOS), "VM volume")
			default:
				claim(scan, 0, item("macos:" + v.role.lowercased(), v.name, .macOS), v.name)
			}
		}
		let sysData = item("macos:data", "System data", .macOS, detail: "/private")
		claim("/private", sysData, "/private")
		claim("/private/var/folders", item("macos:temp", "Temporary files & caches", .macOS, detail: "/private/var/folders"))
		claim("/private/var/vm", item("macos:swap", "Swap & sleep image", .macOS, detail: "/private/var/vm"))
		claim("/private/var/db", item("macos:db", "System databases & diagnostics", .macOS, detail: "/private/var/db"))
		claim("/private/var/log", item("macos:logs", "Logs", .macOS))
		claim("/Library/Logs", item("macos:logs", "Logs", .macOS))
		claim("/System/Volumes/Data/System", item("macos:assets", "Apple downloaded assets", .macOS,
		                                         detail: "Siri, Apple Intelligence, voices, language data"))
		claim("/System/Volumes/Data/.Spotlight-V100", item("macos:spotlight", "Spotlight index", .macOS))
		claim("/Library/Updates", item("macos:updates", "macOS updates", .macOS))
		claim("/Library/Application Support/Apple", item("macos:apple", "Apple apps' data", .macOS))
		claim("/Applications", item("apps:other", "Other apps", .apps, detail: "/Applications"))
		claim("/opt", item("dev:opt", "/opt", .developer))
		claim("/opt/homebrew", item("dev:homebrew", "Homebrew", .developer, detail: "/opt/homebrew"))
		claim("/usr/local", item("dev:usrlocal", "/usr/local", .developer))
	}

	private func claimHome() {
		claim("~", item("other:~", "Home folder (loose files)", .other, detail: "~"))
		let hiddenHome = item("other:~hidden", "Hidden folders in home", .other, detail: "~/.…")
		let lib = item("other:~/Library", "Other app & system data", .other, detail: "~/Library")
		for (s, i, name) in subfolders("~") {
			if name == "Library" {
				claim(s, i, lib, "~/Library")
				for (s2, j, sub) in subfolders("~/Library") { claim(s2, j, lib, "~/Library/" + sub) }
			} else if name.hasPrefix(".") {
				claim(s, i, hiddenHome, "~/" + name)
			} else {
				claim(s, i, item("other:~/" + name, "~/" + name, .other, detail: "~/" + name), "~/" + name)
			}
		}
	}

	private struct App {
		let item: Int
		let id: String
		let names: [String]
		let vendor: String
	}
	private var apps: [App] = []

	private func claimApps() {
		for base in ["/Applications", "~/Applications"] {
			for (s, i, name) in subfolders(base) {
				let path = expand(base) + "/" + name
				if name.hasSuffix(".app") {
					addApp(bundle: path, claimAt: (s, i))
				} else if name.hasSuffix(".appdownload") {
					let it = item("apps:download:" + name, name.replacingOccurrences(of: ".appdownload", with: "") + " (unfinished download)",
					              .apps, detail: display(path))
					claim(s, i, it, display(path))
				} else {
					let inner = s.children(of: i).map { s.names[Int($0)] }.filter { $0.hasSuffix(".app") }
					if let main = inner.first(where: { name.hasPrefix(($0 as NSString).deletingPathExtension) }) ?? inner.first {
						addApp(bundle: path + "/" + main, claimAt: (s, i))
					}
				}
			}
		}
		let fm = FileManager.default
		for base in ["/System/Applications", "/System/Applications/Utilities", "/System/Cryptexes/App/System/Applications"] {
			for name in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where name.hasSuffix(".app") {
				addApp(bundle: base + "/" + name, claimAt: nil)
			}
		}

		for (id, name, group, detail, ids, names) in Self.pseudoApps {
			let it = item(id, name, group, detail: detail)
			for b in ids { apps.append(App(item: it, id: b, names: names, vendor: "")) }
		}

		let userLib = ["Application Support", "Caches", "Containers", "Category Containers", "Logs",
		               "Saved Application State", "HTTPStorages", "WebKit", "Application Scripts"]
		var places = userLib.map { "~/Library/" + $0 }
		places += ["/Library/Application Support", "/Library/Caches", "/Library/Logs"]
		places += [Self.userDir(_CS_DARWIN_USER_CACHE_DIR), Self.userDir(_CS_DARWIN_USER_TEMP_DIR)].compactMap { $0 }
		let appleData = item("macos:appledata", "Apple apps' data", .macOS)
		claim("~/Library/Daemon Containers", appleData, "~/Library/Daemon Containers")
		let leftovers = item("apps:leftovers", "Data of apps not installed", .apps,
		                     detail: "folders in ~/Library no installed app claims")
		for place in places {
			let label = place.hasPrefix("/private/var/folders") ? (place.hasSuffix("/C") ? "System cache folder" : "System temp folder")
				: place.replacingOccurrences(of: "~/Library/", with: "").replacingOccurrences(of: "/Library/", with: "System ")
			for (s, i, name) in subfolders(place) {
				if let app = match(name, groupContainer: place.hasSuffix("Category Containers")) {
					claim(s, i, app, label)
				} else if Self.isApple(name) {
					claim(s, i, appleData, display(logical(s, i)))
				} else if place.hasPrefix("~"), s.total[i] >= 100_000_000, !name.hasPrefix(".") {
					claim(s, i, leftovers, display(logical(s, i)))
				}
			}
		}
		for (dot, bundleID) in [(".vscode", "com.microsoft.vscode"), (".lmstudio", "ai.elementlabs.lmstudio"),
		                        (".cursor", "com.todesktop.230313mzl4w4u92"), (".docker", "com.docker.docker")] {
			if let app = apps.first(where: { $0.id == bundleID }) { claim("~/" + dot, app.item, "~/" + dot) }
		}
	}

	static func isApple(_ name: String) -> Bool {
		let n = name.lowercased()
		if n.hasPrefix("com.apple.") || n.hasPrefix("group.com.apple.") || n.hasPrefix("apple") { return true }
		return ["geoservices", "cloudkit", "knowledge", "familycircle", "addressbook", "callhistorydb", "biome",
		        "differentialprivacy", "dock", "icloud", "animoji", "crashreporter", "diskimages", "fileprovider",
		        "mobile documents", "syncservices", "accounts", "assistant", "personalizationportrait", "spotlight",
		        "trial", "mediaanalysis", "siri", "speechmodels", "metadata", "photos", "safari", "mail", "messages",
		        "callservices", "homekit", "contextstoreagent", "identityservices", "keychains", "liveFiles"
			.lowercased(), "networkserviceproxy", "quicklook", "sharedfilelist", "suggestions", "translation",
		        "weather", "wallpaper", "voicetrigger", "studentd", "screentime", "ckassets", "cloudstorage"].contains(n)
	}

	static let pseudoApps: [(String, String, Category, String, [String], [String])] = [
		("game:minecraft", "Minecraft", .games, "", ["com.mojang.minecraftlauncher", "net.minecraft"], ["minecraft", "tlauncher"]),
		("game:yaagl", "Genshin Impact", .games, "Yaagl launcher", ["com.mihoyo.genshinimpact", "com.3shain.yaagl.os"], ["yaagl os", "genshin impact"]),
	]

	static func userDir(_ name: Int32) -> String? {
		var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
		guard confstr(name, &buf, buf.count) > 0 else { return nil }
		var p = String(cString: buf)
		while p.hasSuffix("/") { p.removeLast() }
		if p.hasPrefix("/var/") { p = "/private" + p }
		return p
	}

	private func addApp(bundle: String, claimAt: (VolumeScan, Int)?) {
		guard let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist") as? [String: Any] else { return }
		let file = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
		let bundleID = (info["CFBundleIdentifier"] as? String ?? "").lowercased()
		let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? file
		let category = info["LSApplicationCategoryType"] as? String ?? ""
		var group: Category = .apps
		if category.contains("games") || bundleID.contains("steam") || bundleID.contains("crossover") { group = .games }
		let exec = info["CFBundleExecutable"] as? String ?? ""
		if bundleID.isEmpty, exec.hasSuffix(".sh"),
		   let script = try? String(contentsOfFile: bundle + "/Contents/MacOS/" + exec, encoding: .utf8), script.contains("steam://run/") {
			group = .games
		}
		if category.contains("social-networking") || ["telegram", "whatsapp", "discord", "signal", "messenger"].contains(where: bundleID.contains) {
			group = .messages
		}
		let id = "app:" + (bundleID.isEmpty ? bundle : bundleID)
		if byID[id] != nil, claimAt == nil { return }
		let it = item(id, file, group, detail: group == .games && bundleID.isEmpty ? "Steam shortcut" : display(bundle))
		items[it].bundle = bundle
		if let (s, i) = claimAt { claim(s, i, it, "App") }
		let names = Set([name, file, info["CFBundleName"] as? String, info["CFBundleExecutable"] as? String]
			.compactMap { $0?.lowercased() }.filter { $0.count > 2 })
		let parts = bundleID.split(separator: ".")
		apps.append(App(item: it, id: bundleID, names: Array(names), vendor: parts.count > 2 ? String(parts[1]) : ""))
	}

	private func match(_ folder: String, groupContainer: Bool) -> Int? {
		var n = folder.lowercased()
		for suffix in [".savedstate", ".binarycookies"] where n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)) }
		if groupContainer {
			if let r = n.range(of: #"^[0-9a-z]{10}\."#, options: .regularExpression) { n = String(n[r.upperBound...]) }
			if n.hasPrefix("group.") { n = String(n.dropFirst(6)) }
		}
		if let a = apps.first(where: { !$0.id.isEmpty && $0.id == n }) { return a.item }
		if let a = apps.filter({ !$0.id.isEmpty && n.hasPrefix($0.id + ".") }).max(by: { $0.id.count < $1.id.count }) { return a.item }
		if let a = apps.first(where: { $0.names.contains(n) }) { return a.item }
		let parts = n.split(separator: ".")
		let vendor = parts.count > 2 && ["com", "org", "net", "io", "ai", "ru", "co", "app"].contains(String(parts[0])) ? String(parts[1]) : n
		let squeezed = parts.map { $0.filter { $0.isLetter || $0.isNumber } }
		if parts.count > 2, let game = apps.first(where: { a in
			items[a.item].group == .games && a.names.contains { name in
				let g = name.filter { $0.isLetter || $0.isNumber }
				return squeezed.dropFirst(2).contains { $0.count >= 6 && (g.hasPrefix($0) || $0.hasPrefix(g)) }
			}
		}) { return game.item }
		let byVendor = apps.filter { $0.vendor == vendor && !["apple", "github", "electron"].contains(vendor) }
		if byVendor.count == 1 { return byVendor[0].item }
		if byVendor.count > 1 {
			let title = vendor.prefix(1).uppercased() + vendor.dropFirst()
			return item("apps:vendor:" + vendor, title + " (shared by \(byVendor.count) apps)", .apps)
		}
		return nil
	}

	private func claimKnown() {
		let minecraft = item("game:minecraft", "Minecraft", .games)
		claim("~/Library/Application Support/minecraft", minecraft, "Game data")
		claim("~/Library/Application Support/tlauncher", minecraft, "TLauncher")
		claim("/Applications/TLauncher", minecraft, "TLauncher app")
		claim("~/Library/Application Support/Yaagl OS", item("game:yaagl", "Genshin Impact", .games, detail: "Yaagl launcher"), "Yaagl launcher")
		for (s, i, name) in subfolders("~/Library/Application Support/Steam/steamapps/common") where s.total[i] > 0 {
			claim(s, i, item("game:steam:" + name, name, .games, detail: "Steam"), "Steam library")
		}
		for (s, i, name) in subfolders("~/Library/Application Support/CrossOver/Bottles") {
			claim(s, i, item("game:bottle:" + name, name, .games, detail: "CrossOver bottle"), "CrossOver bottle")
		}

		let hf = item("model:hf", "Hugging Face models", .models, detail: "~/.cache/huggingface")
		claim("~/.cache/huggingface", hf)
		claim("~/Library/Caches/huggingface", hf)
		claim("~/.ollama", item("model:ollama", "Ollama models", .models))
		claim("~/.lmstudio/models", item("model:lmstudio", "LM Studio models", .models))
		claim("~/.cache/lm-studio/models", item("model:lmstudio", "LM Studio models", .models))
		claim("~/.cache/whisper", item("model:whisper", "Whisper models", .models))
		claim("~/.cache/torch", item("model:torch", "PyTorch models", .models))

		let claude = item("dev:claudecode", "Claude Code", .developer, detail: "sessions, memory, versions")
		claim("~/.claude", claude, "~/.claude")
		claim("~/.local/share/claude", claude, "~/.local/share/claude")
		for (path, name) in [("~/.npm", "npm cache"), ("~/.pnpm-store", "pnpm store"), ("~/Library/pnpm", "pnpm"),
		                     ("~/Library/Caches/pnpm", "pnpm cache"), ("~/.cache/uv", "uv cache"), ("~/.cache/pip", "pip cache"),
		                     ("~/Library/Caches/pip", "pip cache"), ("~/.cargo", "Rust (cargo)"), ("~/.rustup", "Rust toolchains"),
		                     ("~/go", "Go"), ("~/.gradle", "Gradle"), ("~/.m2", "Maven"), ("~/.bun", "Bun"), ("~/.deno", "Deno"),
		                     ("~/.nvm", "Node versions"), ("~/.pyenv", "Python versions"), ("~/miniconda3", "Conda"),
		                     ("~/anaconda3", "Conda"), ("~/.conda", "Conda"), ("~/.cache/node-gyp", "node-gyp"),
		                     ("~/Library/Developer", "Developer data"),
		                     ("~/Library/Developer/Xcode/DerivedData", "Xcode build data"),
		                     ("~/Library/Developer/Xcode/Archives", "Xcode archives"),
		                     ("~/Library/Developer/Xcode/iOS DeviceSupport", "iOS device support"),
		                     ("~/Library/Developer/CoreSimulator", "iOS Simulator"),
		                     ("/Library/Developer/CommandLineTools", "Command Line Tools"),
		                     ("/Library/Frameworks/Python.framework", "Python")] {
			claim(path, item("dev:" + name, name, .developer, detail: display(expand(path))))
		}

		claim("~/Library/Messages", item("msg:messages", "Messages", .messages))
		claim("~/Library/Mail", item("msg:mail", "Mail", .messages))
		claim("~/Music", item("media:music", "Music", .media, detail: "~/Music"))
		claim("~/Movies", item("media:movies", "Movies", .media, detail: "~/Movies"))
		claim("~/Pictures", item("media:pictures", "Pictures", .media, detail: "~/Pictures"))
		for (s, i, name) in subfolders("~/Pictures") where name.hasSuffix(".photoslibrary") {
			claim(s, i, item("media:photos:" + name, (name as NSString).deletingPathExtension, .media, detail: "Photos library"), "~/Pictures/" + name)
		}
		claim("~/Library/Application Support/MobileSync/Backup", item("media:backups", "iPhone & iPad backups", .media))

		claim("~/Library/Metadata/CoreSpotlight", item("macos:spotlightuser", "Spotlight data", .macOS, detail: "~/Library/Metadata"))
		claim("~/Library/Application Support/com.apple.wallpaper", item("macos:wallpaper", "Wallpaper videos", .macOS))
	}

	private func claimProjects() {
		guard let data = disk.dataVolume.flatMap({ disk.scans[$0.device] }),
		      let (scanHome, homeDir) = disk.locate(home), scanHome === data else { return }
		var stack: [Int] = data.children(of: homeDir).map(Int.init).filter {
			let n = data.names[$0]
			return n != "Library" && !n.hasPrefix(".") && n != "Applications"
		}
		let dev = device(of: data) ?? ""
		while let i = stack.popLast() {
			if let c = claims[dev]?[Int32(i)], items[c.item].group != .other { continue }
			if data.marks[i] & Marks.strong != 0 {
				let path = logical(data, i)
				let parent = display((path as NSString).deletingLastPathComponent)
				claim(data, i, item("project:" + path, data.names[i], .projects, detail: parent), "Project")
			}
			for c in data.children(of: i) {
				let n = data.names[Int(c)]
				if Kind.folder(n) != nil || n.hasSuffix(".app") || data.flags[Int(c)].contains(.view) { continue }
				stack.append(Int(c))
			}
		}
	}

	private func claimTrash() {
		let trash = item("trash", "Trash", .trash, detail: "~/.Trash")
		claim("~/.Trash", trash, "Trash")
		for (s, i, name) in subfolders("~/.Trash") { claim(s, i, trash, name) }
	}

	private func assign() {
		var partIndex: [String: Int] = [:]
		for (dev, scan) in disk.scans {
			let claimed = claims[dev] ?? [:]
			let n = scan.count
			var owner = [Int32](repeating: -1, count: n)
			var root = [Int32](repeating: -1, count: n)
			var kind = [Int8](repeating: 0, count: n)
			var bigByDir: [Int32: [BigFile]] = [:]
			for b in scan.big { bigByDir[b.dir, default: []].append(b) }

			for i in 0..<n {
				let p = i == 0 ? -1 : Int(scan.parents[i])
				if scan.flags[i].contains(.gone) || scan.flags[i].contains(.view) || (p >= 0 && owner[p] == -2) {
					owner[i] = -2
					continue
				}
				if let c = claimed[Int32(i)] {
					owner[i] = Int32(c.item); root[i] = Int32(i)
					kind[i] = Int8(Kind.folder(scan.names[i])?.rawValue ?? 0)
				} else if p >= 0 {
					owner[i] = owner[p]; root[i] = root[p]
					kind[i] = Int8(Kind.folder(scan.names[i])?.rawValue ?? Int(kind[p]))
				}
				guard owner[i] >= 0 else { continue }
				let it = items[Int(owner[i])]
				it.bytes += scan.own[i]
				it.files += UInt64(scan.ownFiles[i])

				let key = "\(owner[i])|\(dev)|\(root[i])"
				if let k = partIndex[key] {
					it.parts[k].bytes += scan.own[i]
				} else {
					let label = claimed[root[i]]?.label ?? ""
					it.parts.append(Item.Part(label: label, path: logical(scan, Int(root[i])), bytes: scan.own[i]))
					partIndex[key] = it.parts.count - 1
				}

				if it.group == .projects {
					var rest = scan.own[i]
					for b in bigByDir[Int32(i)] ?? [] {
						if let k = Kind.file(b.name), b.counted <= rest {
							it.kinds[k, default: 0] += b.counted
							rest -= b.counted
						}
					}
					it.kinds[Kind(rawValue: Int(kind[i])) ?? .files, default: 0] += rest
				}
			}
			owners[dev] = owner
		}
	}

	private func addHidden() {
		for a in disk.accounts {
			if a.files == nil {
				let it = items[item("macos:" + a.volume.device, a.volume.name, .macOS, detail: "not mounted")]
				it.bytes += a.volume.inUse
				continue
			}
			guard a.unexplained > 0 else { continue }
			let scan = disk.scans[a.volume.device]!
			let closed = scan.flagged(.denied).count
			let detail = closed > 0 ? "\(closed) folders macOS keeps closed, and file-system bookkeeping" : "file-system bookkeeping"
			let it = items[item("hidden:" + a.volume.device, a.volume.role.isEmpty ? a.volume.name : a.volume.role + " volume", .hidden, detail: detail)]
			it.bytes += UInt64(a.unexplained)
		}
		if disk.container.overhead > 0 {
			items[item("hidden:container", "Container bookkeeping", .hidden)].bytes += UInt64(disk.container.overhead)
		}
	}
}
