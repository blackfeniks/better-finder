import Foundation
import Security

enum Claude {
	static let model = "claude-sonnet-5-5"
	static let price = (input: 2.0, output: 10.0)
	private static let service = "com.ilya.betterfinder.claude"

	static var key: String? {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName(), kSecReturnData as String: true,
		                        kSecMatchLimit as String: kSecMatchLimitOne]
		var out: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
		      let s = String(data: d, encoding: .utf8), !s.isEmpty else { return nil }
		return s
	}

	static var hasKey: Bool { key != nil }

	@discardableResult
	static func save(_ key: String) -> Bool {
		let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !k.isEmpty else { return false }
		forget()
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName(), kSecValueData as String: Data(k.utf8),
		                        kSecAttrLabel as String: "Better Finder — Claude API key (What is this?)"]
		return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
	}

	static func forget() {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName()]
		SecItemDelete(q as CFDictionary)
	}

	struct Answer: Sendable {
		let text: String
		let inputTokens: Int
		let outputTokens: Int
		var cost: Double { Double(inputTokens) * price.input / 1e6 + Double(outputTokens) * price.output / 1e6 }
	}

	enum Failure: Error, Sendable {
		case noKey
		case badKey
		case declined
		case busy
		case other(String)

		var text: String {
			switch self {
			case .noKey: "No Claude API key yet."
			case .badKey: "Claude refused the API key — it may be wrong or switched off."
			case .declined: "Claude declined to explain this one."
			case .busy: "Claude is busy right now — try again in a minute."
			case .other(let s): s
			}
		}
		var isKey: Bool { if case .noKey = self { true } else if case .badKey = self { true } else { false } }
	}

	static let system = """
	You explain to a Mac user what a file or folder on their disk is. You get a description of it \
	(name, path, size, what is inside, which app it seems to belong to), never its contents.
	Answer in Russian, in plain words for a non-programmer, in two or three short sentences: what it \
	is and which app or part of macOS makes or uses it; then whether removing it is safe and what \
	would happen (comes back by itself, an app loses its settings, your own files are lost…).
	If you are not sure, say what it most likely is and that you are not sure. No markdown, no lists, \
	no greeting.
	"""

	static func ask(_ description: String) async -> Result<Answer, Failure> {
		guard let key else { return .failure(.noKey) }
		var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 60)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "content-type")
		req.setValue(key, forHTTPHeaderField: "x-api-key")
		req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
		req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
		let body: [String: Any] = [
			"model": model,
			"max_tokens": 600,
			"thinking": ["type": "between_tools"],
			"output_config": ["effort": "low"],
			"fallbacks": "default",
			"system": system,
			"messages": [["role": "user", "content": description]],
		]
		req.httpBody = try? JSONSerialization.data(withJSONObject: body)
		let data: Data, response: URLResponse
		do { (data, response) = try await URLSession.shared.data(for: req) } catch {
			return .failure(.other("No connection to Claude: \(error.localizedDescription)"))
		}
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		guard status == 200, let json else {
			let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
			switch status {
			case 401, 403: return .failure(.badKey)
			case 429, 529: return .failure(.busy)
			default: return .failure(.other("Claude answered with an error: \(message)"))
			}
		}
		if (json["stop_reason"] as? String) == "refusal" { return .failure(.declined) }
		let blocks = json["content"] as? [[String: Any]] ?? []
		let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
			.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return .failure(.other("Claude sent an empty answer.")) }
		let usage = json["usage"] as? [String: Any] ?? [:]
		return .success(Answer(text: text, inputTokens: usage["input_tokens"] as? Int ?? 0,
		                       outputTokens: usage["output_tokens"] as? Int ?? 0))
	}
}

enum ExplainCache {
	struct Entry: Codable { let text: String; let bytes: UInt64; let date: Date; let cost: Double }
	private static var file: URL { Store().folder.appendingPathComponent("explain.json") }

	static func load() -> [String: Entry] {
		guard let d = try? Data(contentsOf: file) else { return [:] }
		return (try? JSONDecoder().decode([String: Entry].self, from: d)) ?? [:]
	}

	static func save(_ all: [String: Entry]) {
		try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		if let d = try? JSONEncoder().encode(all) { try? d.write(to: file, options: .atomic) }
	}

	static func fresh(_ e: Entry, bytes: UInt64) -> Bool {
		let a = Double(max(e.bytes, 1)), b = Double(max(bytes, 1))
		return max(a, b) / min(a, b) < 2
	}
}

enum Describe {
	static func path(_ s: Snapshot, _ path: String) -> String {
		let fm = FileManager.default
		let name = (path as NSString).lastPathComponent
		var lines: [String] = []
		let t = s.tree
		if let n = t.locate(path) {
			lines.append("Folder: \(name)")
			lines.append("Path: \(Fmt.home(path))")
			lines.append("Size on disk: \(Fmt.size(t.size(n))), \(Fmt.plural(Int(t.files(n)), "file")) inside")
			if let app = owner(s, path) { lines.append("Better Finder thinks it belongs to: \(app)") }
			let subs = t.entries(n).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }
			if !subs.isEmpty {
				lines.append("Biggest folders inside (\(subs.count) in all):")
				for e in subs.prefix(15) { lines.append("  \(e.name) — \(Fmt.size(e.bytes))") }
			}
			let listing = Listing.read(n, tree: t)
			let files = listing.files.sorted { $0.bytes > $1.bytes }
			if !files.isEmpty {
				lines.append("Files directly inside: \(files.count), \(Fmt.size(t.ownBytes(n))); the biggest:")
				for f in files.prefix(10) { lines.append("  \(f.name) — \(Fmt.size(f.bytes)), changed \(Fmt.date(f.mtime))") }
			}
		} else {
			let url = URL(fileURLWithPath: path)
			let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey,
			                                          .localizedTypeDescriptionKey])
			lines.append("\(v?.isDirectory == true ? "Folder" : "File"): \(name)")
			lines.append("Path: \(Fmt.home(path))")
			if let kind = v?.localizedTypeDescription { lines.append("Kind (as Finder says): \(kind)") }
			let bytes = UInt64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
			lines.append("Size on disk: \(Fmt.size(bytes))")
			if let d = v?.contentModificationDate { lines.append("Last changed: \(Fmt.when(d))") }
			let parent = (path as NSString).deletingLastPathComponent
			if let app = owner(s, parent) { lines.append("Its folder belongs to: \(app)") }
			let siblings = ((try? fm.contentsOfDirectory(atPath: parent)) ?? []).filter { $0 != name }.prefix(12)
			if !siblings.isEmpty { lines.append("Next to it: " + siblings.joined(separator: ", ")) }
		}
		if let known = Explain.known(name) { lines.append("Better Finder's own note: \(known)") }
		return lines.joined(separator: "\n")
	}

	static func item(_ s: Snapshot, _ it: Item) -> String {
		var lines = ["Item: \(it.name) (Better Finder files it under \"\(it.group.title)\")",
		             "Size on disk: \(Fmt.size(it.bytes)) in \(Fmt.plural(it.parts.filter { $0.bytes > 0 }.count, "place"))"]
		if let b = it.bundle { lines.append("App: \(Fmt.home(b))") }
		lines.append("Its places:")
		for p in it.parts.filter({ $0.bytes > 0 }).prefix(15) { lines.append("  \(Fmt.home(p.path)) — \(Fmt.size(p.bytes))") }
		return lines.joined(separator: "\n")
	}

	private static func owner(_ s: Snapshot, _ path: String) -> String? {
		guard let (scan, dir) = s.disk.locate(path), let it = s.meaning.owner(scan, dir) else { return nil }
		if it.group == .other || it.id == "apps:other" { return nil }
		return "\(it.name) (\(it.group.title))"
	}
}
