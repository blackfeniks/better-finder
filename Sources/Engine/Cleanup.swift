import Foundation

struct Candidate: Sendable {
	enum Safety: Int, Comparable, Sendable {
		case safe, check, careful
		static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }
		var title: String { ["Safe", "Check", "Careful"][rawValue] }
		var hint: String { ["comes back by itself", "your own files", "a long download to get back"][rawValue] }
	}

	let title: String
	let detail: String
	let paths: [String]
	let bytes: UInt64
	let safety: Safety
	var action: String? = nil
	var isTrash = false
}

enum Cleanup {
	static let devCaches: [(String, String)] = [
		("~/.npm", "npm cache"), ("~/.cache/uv", "uv cache"), ("~/.cache/pip", "pip cache"),
		("~/Library/Caches/pip", "pip cache"), ("~/.pnpm-store", "pnpm store"),
		("~/Library/pnpm/store", "pnpm store"), ("~/.cache/node-gyp", "node-gyp cache"),
		("~/Library/Developer/Xcode/DerivedData", "Xcode build data"),
		("~/Library/Developer/Xcode/iOS DeviceSupport", "iOS device support files"),
	]

	static func isLoose(_ path: String, owner: Item?) -> Bool {
		if owner?.group == .projects || owner?.group == .apps || owner?.group == .games { return false }
		let parts = path.split(separator: "/").dropLast()
		for part in parts {
			if part == ".git" { return false }
			let ext = (String(part) as NSString).pathExtension.lowercased()
			if !ext.isEmpty && packageExtensions.contains(ext) { return false }
		}
		return true
	}

	static let packageExtensions: Set<String> = [
		"app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band",
		"pvm", "utm", "vmwarevm", "parallels", "bundle", "framework", "plugin", "kext", "xcarchive",
		"sparsebundle", "dmgpart", "lrlibrary", "lrdata", "aplibrary", "pages", "numbers", "key", "rtfd",
	]

	static let knownCaches: [String: String] = [
		"com.apple.metal": "Metal shader cache", "clang": "Compiler cache (clang)",
		"dxmt": "Game shader cache (DirectX → Metal)", "d3dm": "Game shader cache (Direct3D)",
		"GeoServices": "Maps cache", "com.apple.WebKit.GPU": "WebKit GPU cache",
	]
	static func candidates(_ disk: DiskScan, _ meaning: Meaning) -> [Candidate] {
		var out: [Candidate] = []
		let home = meaning.home
		func total(_ path: String) -> UInt64 {
			guard let (s, i) = disk.locate(path.hasPrefix("~") ? home + path.dropFirst() : path) else { return 0 }
			return s.total[i]
		}
		func show(_ p: String) -> String { meaning.display(p) }

		let trash = total("~/.Trash")
		if trash >= 1_000_000 {
			out.append(Candidate(title: "Empty the Trash", detail: "Deleted for good — the only row that cannot be put back",
			                     paths: [], bytes: trash, safety: .safe, isTrash: true))
		}

		if let (s, dir) = disk.locate(home + "/Library/Logs"), s.total[dir] >= 100_000_000 {
			let inside = s.children(of: dir).filter { s.total[Int($0)] >= 1_000_000 }
			let bytes = inside.reduce(UInt64(0)) { $0 + s.total[Int($1)] }
			if bytes >= 100_000_000 {
				out.append(Candidate(title: "Logs", detail: "\(inside.count) folders in " + show(home + "/Library/Logs"),
				                     paths: inside.map { disk.logicalPath(s, Int($0)) }, bytes: bytes, safety: .safe))
			}
		}

		let devCaches = Set(Self.devCaches.map { home + $0.0.dropFirst() })
		let cacheDirs = ["~/Library/Caches", Meaning.userDir(_CS_DARWIN_USER_CACHE_DIR)].compactMap { $0 }
		for base in cacheDirs {
			guard let (s, dir) = disk.locate(base.hasPrefix("~") ? home + base.dropFirst() : base) else { continue }
			for c in s.children(of: dir) where s.total[Int(c)] >= 200_000_000 {
				let path = disk.logicalPath(s, Int(c))
				let folder = s.names[Int(c)]
				let owner = meaning.owner(s, Int(c))
				if devCaches.contains(path) || owner?.group == .models { continue }
				if let owner, meaning.hasOtherClaims(s, Int(c), besides: owner) { continue }
				let title = Self.knownCaches[folder]
					?? (owner.map { $0.group == .macOS || $0.group == .other ? folder : $0.name } ?? folder) + " cache"
				let detail = base.hasPrefix("/private/var/folders") ? "macOS's cache folder for your apps" : show(path)
				out.append(Candidate(title: title, detail: detail, paths: [path], bytes: s.total[Int(c)], safety: .safe))
			}
		}

		for (path, name) in Self.devCaches {
			let b = total(path)
			if b >= 100_000_000 {
				out.append(Candidate(title: name, detail: show(home + path.dropFirst()), paths: [home + path.dropFirst()], bytes: b, safety: .safe))
			}
		}

		if let (s, dir) = disk.locate(home + "/.vscode/extensions") {
			var byID: [String: [(version: [Int], index: Int)]] = [:]
			for c in s.children(of: dir) {
				let name = s.names[Int(c)]
				guard let r = name.range(of: #"-\d+(\.\d+)+"#, options: .regularExpression) else { continue }
				let id = String(name[..<r.lowerBound])
				let version = name[r].dropFirst().split(separator: ".").compactMap { Int($0) }
				byID[id, default: []].append((version, Int(c)))
			}
			for (id, list) in byID where list.count > 1 {
				let sorted = list.sorted { $0.version.lexicographicallyPrecedes($1.version) }
				let old = sorted.dropLast()
				let bytes = old.reduce(0) { $0 + s.total[$1.index] }
				guard bytes >= 50_000_000 else { continue }
				let newest = sorted.last!.version.map(String.init).joined(separator: ".")
				out.append(Candidate(title: "Old \(id) extension", detail: "\(old.count) older version\(old.count > 1 ? "s" : "") — \(newest) is the one in use",
				                     paths: old.map { disk.logicalPath(s, $0.index) }, bytes: bytes, safety: .safe))
			}
		}

		for base in [home + "/Downloads", home + "/Desktop"] {
			guard let (s, dir) = disk.locate(base) else { continue }
			let prefix = disk.logicalPath(s, dir)
			var files: [(String, UInt64)] = []
			for b in s.big where b.counted >= 50_000_000 {
				let ext = (b.name as NSString).pathExtension.lowercased()
				guard ["dmg", "pkg", "iso", "xip", "zip"].contains(ext) || b.name.hasSuffix(".download") || b.name.hasSuffix(".crdownload") else { continue }
				let p = disk.logicalPath(s, Int(b.dir)) + "/" + b.name
				guard p.hasPrefix(prefix + "/"), Self.isLoose(p, owner: meaning.owner(s, Int(b.dir))) else { continue }
				files.append((p, b.counted))
			}
			if !files.isEmpty {
				let sum = files.reduce(0) { $0 + $1.1 }
				out.append(Candidate(title: "Installers & archives in \(show(prefix))", detail: "\(files.count) file\(files.count > 1 ? "s" : ""): " +
				                     files.sorted { $0.1 > $1.1 }.prefix(3).map { ($0.0 as NSString).lastPathComponent }.joined(separator: ", "),
				                     paths: files.map(\.0), bytes: sum, safety: .check))
			}
		}
		for it in meaning.items where it.id.hasPrefix("apps:download:") && it.bytes >= 10_000_000 {
			out.append(Candidate(title: it.name, detail: it.detail, paths: it.parts.map(\.path), bytes: it.bytes, safety: .safe))
		}

		if let left = meaning.item(id: "apps:leftovers") {
			for p in left.parts {
				guard let (s, i) = disk.locate(p.path), s.total[i] >= 100_000_000,
				      !meaning.hasOtherClaims(s, i, besides: left) else { continue }
				out.append(Candidate(title: (p.path as NSString).lastPathComponent, detail: "No installed app uses it — " + show(p.path),
				                     paths: [p.path], bytes: s.total[i], safety: .check))
			}
		}

		if let tg = meaning.item(id: "app:ru.keepcoder.telegram"), let media = tg.parts.first(where: { $0.label == "Category Containers" }), media.bytes >= 300_000_000 {
			out.append(Candidate(title: "Telegram media", detail: "Downloaded photos and videos from chats", paths: [], bytes: media.bytes,
			                     safety: .check, action: "Clear in Telegram: Settings › Data and Storage"))
		}

		if let data = disk.dataVolume.flatMap({ disk.scans[$0.device] }) {
			let yearAgo = Int64(Date().addingTimeInterval(-365 * 86400).timeIntervalSince1970)
			var old: [(String, UInt64)] = []
			for b in data.big where b.counted >= 1_000_000_000 && b.mtime < yearAgo {
				let p = disk.logicalPath(data, Int(b.dir)) + "/" + b.name
				guard p.hasPrefix(home + "/"), !p.hasPrefix(home + "/Library/"), !p.hasPrefix(home + "/."),
				      Self.isLoose(p, owner: meaning.owner(data, Int(b.dir))) else { continue }
				old.append((p, b.counted))
			}
			for (p, b) in old.sorted(by: { $0.1 > $1.1 }).prefix(10) {
				out.append(Candidate(title: (p as NSString).lastPathComponent, detail: "Not changed for over a year — " + show((p as NSString).deletingLastPathComponent),
				                     paths: [p], bytes: b, safety: .check))
			}
		}

		return out.sorted { ($0.safety, -Int64($0.bytes)) < ($1.safety, -Int64($1.bytes)) }
	}
}
