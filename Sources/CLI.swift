import Darwin
import Foundation

enum CLI {
	static func run(_ args: [String]) -> Int32 {
		guard let mode = args.first else { usage(); return 2 }
		let rest = Array(args.dropFirst())
		switch mode {
		case "report": return report(json: rest.contains("--json"))
		case "item": return item(rest.first ?? "")
		case "scan": return scan(rest)
		case "cache": return cacheCheck()
		case "update": return update()
		case "cleanup": return cleanup()
		case "folders": return folders(rest.first ?? "/")
		case "icon": return AppIcon.write(rest.first ?? "AppIcon.iconset")
		case "helper": return Privileged.helper(asUser: rest.contains("--as-user"))
		case "graft-check": return graftCheck(rest)
		case "safety-check": return safetyCheck()
		case "trash-check": return TrashCheck.run(rest.first ?? NSTemporaryDirectory())
		case "claude-key": return claudeKey()
		case "explain-check": return explainCheck(rest.first ?? NSHomeDirectory() + "/.DS_Store")
		case "live-check": return MainActor.assumeIsolated { liveCheck(rest.first ?? NSTemporaryDirectory()) }
		default: usage(); return 2
		}
	}

	static func claudeKey() -> Int32 {
		let data = FileHandle.standardInput.readDataToEndOfFile()
		guard let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
			print("no key on stdin"); return 1
		}
		let ok = Claude.save(key)
		print(ok ? "✓ key saved in the keychain (\(key.count) characters)" : "✗ could not save the key")
		return ok ? 0 : 1
	}

	static func explainCheck(_ path: String) -> Int32 {
		guard let container = Disks.boot() else { return 1 }
		let disk = DiskScan(container: container)
		_ = Store().open(disk)
		let snap = Snapshot(id: 1, disk: disk, others: [:], walking: [])
		let text = Describe.path(snap, path)
		print("— sent:\n" + text)
		let done = DispatchSemaphore(value: 0)
		nonisolated(unsafe) var result: Result<Claude.Answer, Claude.Failure> = .failure(.other("no answer"))
		let t0 = Date()
		Task.detached {
			result = await Claude.ask(text)
			done.signal()
		}
		done.wait()
		switch result {
		case .success(let a):
			print(String(format: "— answer (%.1f s, %d in / %d out tokens, %.2f¢):", Date().timeIntervalSince(t0), a.inputTokens, a.outputTokens, a.cost * 100))
			print(a.text)
			return 0
		case .failure(let f):
			print("✗ " + f.text)
			return 1
		}
	}

	static func usage() {
		print("""
		usage: BetterFinder report [--json] | item ID | scan PATH [--threads N] [--top N] | cache | update | cleanup | folders PATH
		""")
	}

	static func size(_ b: UInt64) -> String {
		let v = Double(b)
		if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
		if v >= 1e9 { return String(format: "%.1f GB", v / 1e9) }
		if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
		if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
		return "\(b) B"
	}

	static func size(_ b: Int64) -> String { b < 0 ? "−" + size(UInt64(-b)) : size(UInt64(b)) }

	private static func pad(_ s: String, _ n: Int) -> String {
		s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
	}

	static func walkDisk(verbose: Bool = true) -> DiskScan? {
		guard let container = Disks.boot() else { print("no boot APFS container found"); return nil }
		let disk = DiskScan(container: container)
		disk.run { v, s in
			if verbose {
				print("  walked \(v.name) (\(v.role)) — \(s.counters.files) files, \(s.count) folders, " +
				      String(format: "%.1f s", s.seconds))
			}
		}
		return disk
	}

	static func report(json: Bool) -> Int32 {
		guard let disk = walkDisk(verbose: !json) else { return 1 }
		let meaning = Meaning(disk: disk)
		if json {
			printJSON(disk, meaning)
			return 0
		}
		let c = disk.container
		print("\nDisk \(c.device): \(size(c.size)) — used \(size(c.used)), free \(size(c.free))" +
		      (disk.purgeable > 0 ? " (+ \(size(disk.purgeable)) macOS can free by itself)" : ""))
		print("\nVolumes: what APFS says each takes vs what its files add up to")
		for a in disk.accounts {
			let files = a.files.map(size) ?? "not mounted"
			print("  \(pad(a.volume.name, 22))  APFS \(pad(size(a.volume.inUse), 9))  files \(pad(files, 11))  unexplained \(pad(size(a.unexplained), 8))")
			if let s = disk.scans[a.volume.device] {
				let k = s.counters
				var notes: [String] = []
				if k.hardLink > 0 { notes.append("hard links counted once: −\(size(k.hardLink))") }
				if k.cloneShared > 0 { notes.append("APFS copies sharing space: −\(size(k.cloneShared))") }
				if k.partialClone > 0 { notes.append("partly shared copies: \(size(k.partialClone))") }
				if k.dataless > 0 { notes.append("in iCloud only (takes no space): \(size(k.dataless))") }
				let closed = s.flagged(.denied).count
				if closed > 0 { notes.append("\(closed) closed folders") }
				if !notes.isEmpty { print("  " + String(repeating: " ", count: 24) + notes.joined(separator: " · ")) }
			}
		}
		print("  container bookkeeping: \(size(c.overhead))")

		print("\nBy meaning (sums to \(size(meaning.total)) of \(size(c.used)) used)")
		for (g, list) in meaning.groups where !list.isEmpty {
			print("\n  \(g.title) — \(size(meaning.total(g)))")
			for it in list.prefix(12) {
				let detail = it.detail.isEmpty ? "" : "   \(it.detail)"
				print("    \(pad(size(it.bytes), 9))  \(it.name)\(detail)   [\(it.id)]")
			}
			if list.count > 12 {
				let rest = list.dropFirst(12)
				print("    \(pad(size(rest.reduce(0) { $0 + $1.bytes }), 9))  \(rest.count) more")
			}
		}
		let diff = Int64(c.used) - Int64(meaning.total)
		print("\nCheck: used − sum of items = \(size(diff))")
		return 0
	}

	static func item(_ id: String) -> Int32 {
		guard let disk = walkDisk(verbose: false) else { return 1 }
		let meaning = Meaning(disk: disk)
		guard let it = meaning.item(id: id) else { print("no item \(id)"); return 1 }
		print("\(it.name) — \(size(it.bytes)), \(it.files) files   [\(it.group.title)]  \(it.detail)")
		for p in it.parts where p.bytes > 0 {
			print("  \(pad(size(p.bytes), 9))  \(p.label)   \(meaning.display(p.path))")
		}
		if !it.kinds.isEmpty {
			print("  kinds:")
			for (k, b) in it.kinds.sorted(by: { $0.value > $1.value }) where b > 0 { print("  \(pad(size(b), 9))  \(k.title)") }
		}
		return 0
	}

	static func cleanup() -> Int32 {
		guard let disk = walkDisk(verbose: false) else { return 1 }
		let meaning = Meaning(disk: disk)
		let list = Cleanup.candidates(disk, meaning)
		for safety in [Candidate.Safety.safe, .check, .careful] {
			let part = list.filter { $0.safety == safety }
			guard !part.isEmpty else { continue }
			print("\n\(safety.title) — \(safety.hint): \(size(part.reduce(0) { $0 + $1.bytes }))")
			for c in part {
				print("  \(pad(size(c.bytes), 9))  \(c.title)   \(c.detail)" + (c.action.map { "   → \($0)" } ?? ""))
			}
		}
		return 0
	}

	static func folders(_ path: String) -> Int32 {
		guard let container = Disks.boot() else { return 1 }
		let disk = DiskScan(container: container)
		_ = Store().open(disk)
		let tree = Tree(disk: disk, others: [:])
		guard let n = tree.locate(path) else { print("no folder \(path)"); return 1 }
		let list = tree.entries(n)
		let sum = list.reduce(UInt64(0)) { $0 + $1.bytes } + tree.ownBytes(n)
		print("\(tree.path(n)) [\(n.volume) #\(n.dir)]: \(size(tree.size(n))) — subfolders + own files = \(size(sum))" +
		      (sum == tree.size(n) ? " ✓" : " ✗ \(Int64(tree.size(n)) - Int64(sum)) B"))
		for e in list.prefix(40) {
			let note = e.note.map { " (\($0))" } ?? ""
			let full = e.full != e.bytes ? " of \(size(e.full))" : ""
			print("  \(pad(size(e.bytes), 9))\(full)  \(e.name)\(note)" + (e.node.map { " → \(tree.path($0))" } ?? ""))
		}
		print("  \(pad(size(tree.ownBytes(n)), 9))  files here (\(tree.ownFiles(n)))")
		return 0
	}

	static func safetyCheck() -> Int32 {
		guard let container = Disks.boot() else { return 1 }
		let disk = DiskScan(container: container)
		_ = Store().open(disk)
		let s = Snapshot(id: 1, disk: disk, others: [:], walking: [])
		let h = NSHomeDirectory()
		let never = ["/", "/Applications", "/Applications/Utilities", "/Library", "/Library/LaunchDaemons", "/Library/LaunchDaemons/x.plist",
		             "/Library/Keychains", "/Library/Application Support", "/Library/Application Support/Apple/x", "/System",
		             "/System/Library/Caches", "/Users", "/Users/Shared", "/Users/Shared/x", "/Volumes", "/Volumes/Recovery",
		             "/Volumes/Recovery/x", "/System/Volumes/Preboot/x", "/private/var/root", "/private/var/log/x", "/private/etc/hosts",
		             "/usr", "/usr/bin", "/usr/local", "/opt/homebrew", "/bin/ls", h, h + "/Library", h + "/Library/Caches",
		             h + "/Library/Application Support", h + "/Downloads", h + "/.Trash", "/System/Volumes/Data/Users/x"]
		let may = [h + "/Downloads/x.zip", h + "/Library/Caches/com.spotify.client", h + "/.npm", "/Applications/Blender.app",
		           "/Library/Application Support/Adobe", "/Library/Caches/x", "/opt/homebrew/Cellar", "/usr/local/lib",
		           "/private/var/folders/vb/m4mp/C/org.blenderfoundation.blender", "/cores/core.123"]
		var bad = 0
		for p in never where Safety.canTrash(path: p, s) { print("  ✗ offered: \(p)"); bad += 1 }
		for p in may where !Safety.canTrash(path: p, s) { print("  ✗ not offered: \(p)"); bad += 1 }
		var items = 0, offered: [String] = []
		for it in s.meaning.items where it.bytes > 0 {
			items += 1
			if Safety.canTrash(item: it, s) { offered.append(it.name) }
		}
		let apple = s.meaning.items.filter { ($0.bundle ?? "").hasPrefix("/System/") && Safety.canTrash(item: $0, s) }
		for it in apple { print("  ✗ Apple app offered: \(it.name)"); bad += 1 }
		for id in ["app:com.valvesoftware.steam", "app:ai.elementlabs.lmstudio"] {
			if let it = s.meaning.item(id: id), Safety.canTrash(item: it, s) { print("  ✗ item holding other items offered: \(it.name)"); bad += 1 }
		}
		print("items that may go as a whole: \(offered.count) of \(items) — e.g. " + offered.prefix(8).joined(separator: ", "))
		print(bad == 0 ? "✓ safety rules hold" : "✗ \(bad) wrong")
		return bad == 0 ? 0 : 1
	}

	static func graftCheck(_ paths: [String]) -> Int32 {
		guard let container = Disks.boot() else { return 1 }
		let disk = DiskScan(container: container)
		_ = Store().open(disk)
		let tree = Tree(disk: disk, others: [:])
		var failed = 0
		let t0 = Date()
		guard case .walks(let parts) = Privileged.walk(paths, password: nil, asUser: true) else { print("helper did not start"); return 1 }
		print(String(format: "helper: %d walks in %.2f s", parts.count, Date().timeIntervalSince(t0)))
		for p in paths {
			guard let n = tree.locate(p), let scan = tree.scan(n.volume), let part = parts[p] else { print("  \(p): no folder or no walk"); failed += 1; continue }
			let copy = scan.copy()
			let before = (copy.total[0], copy.total[Int(n.dir)], copy.count)
			copy.graft(part, at: Int(n.dir))
			let after = (copy.total[0], copy.total[Int(n.dir)])
			let d = Int64(after.1) - Int64(before.1)
			print("  \(p): \(size(before.1)) → \(size(after.1)) (\(d) B), volume \(size(before.0)) → \(size(after.0)), " +
			      "folders \(before.2) → \(copy.count) (old ones gone: \(copy.flagged(.gone).count))")
			if abs(d) > 1_000_000 { failed += 1 }
			copy.compact()
			if copy.total[0] != after.0 { print("    ✗ compaction changed the total"); failed += 1 }
		}
		print(failed == 0 ? "✓ grafts keep the sums" : "✗ \(failed) failed")
		return failed == 0 ? 0 : 1
	}

	@MainActor
	static func liveCheck(_ dir: String) -> Int32 {
		let engine = Engine()
		var snap: Snapshot?
		var phase = Engine.Phase.starting
		engine.onSnapshot = { s in snap = s }
		engine.onPhase = { p in phase = p; print("  phase: \(p)") }
		let t0 = Date()
		engine.start()
		func wait(_ seconds: Double, until done: () -> Bool) -> Bool {
			let end = Date().addingTimeInterval(seconds)
			while Date() < end {
				RunLoop.main.run(until: Date().addingTimeInterval(0.05))
				if done() { return true }
			}
			return done()
		}
		guard wait(120, until: { phase == .ready && snap != nil }) else { print("✗ not ready"); return 1 }
		print(String(format: "ready in %.2f s, snapshot %d", Date().timeIntervalSince(t0), snap!.id))
		let folder = (dir as NSString).appendingPathComponent("bf-live-check")
		try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
		RunLoop.main.run(until: Date().addingTimeInterval(3))
		func sizeNow() -> UInt64 { snap.flatMap { s in s.tree.locate(folder).map { s.tree.size($0) } } ?? 0 }
		let before = sizeNow()
		let file = (folder as NSString).appendingPathComponent("blob.bin")
		FileManager.default.createFile(atPath: file, contents: Data(count: 30_000_000))
		let t1 = Date()
		let grew = wait(15) { sizeNow() >= before + 29_000_000 }
		print(String(format: "  after writing 30 MB: %@ → %@ in %.1f s %@", size(before), size(sizeNow()),
		             Date().timeIntervalSince(t1), grew ? "✓" : "✗"))
		try? FileManager.default.removeItem(atPath: folder)
		let t2 = Date()
		let gone = wait(15) { snap.map { s in s.tree.locate(folder) == nil } ?? false }
		print(String(format: "  after removing it: folder %@ in %.1f s", gone ? "gone ✓" : "still there ✗", Date().timeIntervalSince(t2)))
		let t3 = Date()
		engine.saveNow()
		print(String(format: "  saved in %.2f s", Date().timeIntervalSince(t3)))
		let s = snap!
		print("  used \(size(s.container.used)), by meaning \(size(s.meaning.total)), difference \(size(Int64(s.container.used) - Int64(s.meaning.total)))")
		return grew && gone ? 0 : 1
	}

	static func scan(_ args: [String]) -> Int32 {
		guard let path = args.first else { usage(); return 2 }
		var threads: Int?
		var top = 20
		if let i = args.firstIndex(of: "--threads"), i + 1 < args.count { threads = Int(args[i + 1]) }
		if let i = args.firstIndex(of: "--top"), i + 1 < args.count { top = Int(args[i + 1]) ?? top }
		let kind = Storage.kind(of: path)
		guard let s = try? VolumeScan(root: path) else { print("cannot open \(path)"); return 1 }
		let n = threads ?? kind.threads
		s.run(threads: n)
		let k = s.counters
		print("\(path): \(size(s.total[0])) in \(k.files) files, \(s.count) folders — " +
		      String(format: "%.2f s", s.seconds) + ", \(n) threads, \(kind)")
		print("  hard links −\(size(k.hardLink)) · copies −\(size(k.cloneShared)) · purgeable \(size(s.totalPurgeable[0])) · " +
		      "closed \(s.flagged(.denied).count) · elsewhere \(s.flagged(.elsewhere).count)")
		for c in s.children(of: 0).sorted(by: { s.total[Int($0)] > s.total[Int($1)] }).prefix(top) {
			print("  \(pad(size(s.total[Int(c)]), 9))  \(s.names[Int(c)])")
		}
		return 0
	}

	static func cacheCheck() -> Int32 {
		guard let disk = walkDisk() else { return 1 }
		let store = Store()
		for (dev, scan) in disk.scans {
			let t0 = Date()
			guard let v = disk.container.volumes.first(where: { $0.device == dev }), let t = Store.Target(v), t.cached else { continue }
			do {
				scan.compact()
				let bytes = try store.save(scan, t, lastEvent: 0)
				let t1 = Date()
				guard let back = store.load(t) else { print("  \(v.name): load failed"); return 1 }
				let t2 = Date()
				let same = back.scan.count == scan.count && back.scan.total[0] == scan.total[0]
					&& back.scan.names == scan.names && back.scan.own == scan.own && back.scan.big.count == scan.big.count
				print("  \(v.name): \(size(UInt64(bytes))) on disk, save " + String(format: "%.2f s, load %.2f s", t1.timeIntervalSince(t0), t2.timeIntervalSince(t1)) +
				      (same ? " — identical" : " — DIFFERENT"))
				if !same { return 1 }
			} catch {
				print("  \(v.name): \(error)")
				return 1
			}
		}
		return 0
	}

	static func update() -> Int32 {
		guard let container = Disks.boot() else { return 1 }
		let disk = DiskScan(container: container)
		let store = Store()
		let t0 = Date()
		let result = store.open(disk)
		for line in result { print("  " + line) }
		print(String(format: "ready in %.2f s", Date().timeIntervalSince(t0)))
		for a in disk.accounts { if let f = a.files { print("  \(a.volume.name): files \(f) bytes") } }
		let t1 = Date()
		let meaning = Meaning(disk: disk)
		let t2 = Date()
		let cleanup = Cleanup.candidates(disk, meaning)
		let t3 = Date()
		let tree = Tree(disk: disk, others: [:])
		let t4 = Date()
		print(String(format: "meaning %.2f s, cleanup %.2f s (%d), tree %.2f s", t2.timeIntervalSince(t1), t3.timeIntervalSince(t2),
		             cleanup.count, t4.timeIntervalSince(t3)))
		if let r = tree.bootRoot {
			let hidden = Int64(container.used) - Int64(tree.size(r))
			print("folders: / = \(size(tree.size(r))), not visible as files = \(size(hidden))")
		}
		print("used \(size(container.used)), items \(size(meaning.total)), difference \(size(Int64(container.used) - Int64(meaning.total)))")
		return 0
	}

	private static func printJSON(_ disk: DiskScan, _ meaning: Meaning) {
		let c = disk.container
		let groups: [[String: Any]] = meaning.groups.map { g, list in
			["group": g.title, "bytes": meaning.total(g),
			 "items": list.map { it -> [String: Any] in
				["id": it.id, "name": it.name, "detail": it.detail, "bytes": it.bytes, "files": it.files,
				 "parts": it.parts.filter { $0.bytes > 0 }.map { ["label": $0.label, "path": meaning.display($0.path), "bytes": $0.bytes] },
				 "kinds": Dictionary(uniqueKeysWithValues: it.kinds.filter { $0.value > 0 }.map { ($0.key.title, $0.value) })]
			 }]
		}
		let volumes: [[String: Any]] = disk.accounts.map { a in
			["name": a.volume.name, "role": a.volume.role, "apfs": a.volume.inUse, "files": a.files ?? 0]
		}
		let cleanup: [[String: Any]] = Cleanup.candidates(disk, meaning).map { c in
			["title": c.title, "detail": c.detail, "bytes": c.bytes, "safety": c.safety.title, "action": c.action ?? "",
			 "paths": c.paths.map(meaning.display)]
		}
		let root: [String: Any] = ["size": c.size, "used": c.used, "free": c.free, "purgeable": disk.purgeable,
		                           "volumes": volumes, "groups": groups, "cleanup": cleanup]
		if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
			FileHandle.standardOutput.write(data)
			print()
		}
	}
}
