import AppKit

@MainActor
enum RingCheck {
	static func run(_ dir: String) -> Int32 {
		_ = NSApplication.shared
		NSApp.setActivationPolicy(.prohibited)
		RingView.instant = true
		guard let container = Disks.boot() else { print("no boot disk"); return 1 }
		let disk = DiskScan(container: container)
		let store = Store()
		_ = store.open(disk)
		var others: [String: (info: OtherVolume, scan: VolumeScan)] = [:]
		for v in Disks.others(boot: container) {
			let t = Store.Target(uuid: v.uuid, mount: v.mount, role: "")
			if t.cached, let (scan, _) = store.load(t) { others[v.device] = (v, scan) }
		}
		let snap = Snapshot(id: 1, disk: disk, others: others, walking: [])
		let home = NSHomeDirectory()
		var places: [(String, Place)] = [("overview", .overview), ("Apps", .group(.apps)), ("macOS", .group(.macOS))]
		if let it = snap.meaning.groups.first(where: { $0.0 == .apps })?.1.first { places.append(("item \(it.name)", .item(it.id))) }
		for p in [home, home + "/Library/Application Support", home + "/Downloads", "/"] {
			if let n = snap.tree.locate(p) { places.append((Fmt.home(p), .folder(n))) }
		}
		if let n = lopsided(snap, from: snap.tree.locate(home)) { places.append(("one big folder: " + Fmt.home(snap.tree.path(n)), .folder(n))) }
		for (key, o) in others {
			let root = Node(volume: key, dir: 0)
			places.append((o.info.name, .folder(root)))
			for e in snap.tree.entries(root) where e.name.lowercased().hasPrefix("исходники") {
				if let n = e.node { places.append((o.info.name + "/" + e.name, .folder(n))) }
			}
			if let n = lopsided(snap, from: root) { places.append(("one big folder: " + snap.tree.path(n), .folder(n))) }
		}
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

		var failed = 0
		let quick = ProcessInfo.processInfo.environment["BF_QUICK"] != nil
		for (w, h) in quick ? [] : [(880.0, 760.0), (1300.0, 1000.0), (520.0, 470.0)] {
			print("— stage \(Int(w))×\(Int(h))")
			for (name, place) in places {
				let v = RingView(frame: NSRect(x: 0, y: 0, width: w, height: h))
				let content = Content.ring(snap, place)
				v.show(content, .none)
				let r = check(v, content)
				failed += r.problems
				print(String(format: "  %@ %@: turn %d°, %d labels (%d cut), still mouse %d/%d, dead %d, flip-backs %d, label overlaps %d, label hover %d/%d, draw %.1f ms",
				             r.problems == 0 ? "✓" : "✗", name, Int((content.rotation * 180 / .pi).rounded()), r.labels, r.cut,
				             r.stillBad, r.stillAll, r.dead, r.flips, r.overlaps, r.labelBad, r.labelAll, r.drawMs))
				for e in r.examples.prefix(3) { print("      " + e) }
				if w == 880 {
					let file = String(name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" })
					try? v.picture(scale: 1.5)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ring-\(file).jpg"))
					if let big = content.pieces.filter({ $0.ring != 2 && $0.kind != .free }).max(by: { $0.bytes < $1.bytes }) {
						v.settle(hover: big.key)
						try? v.picture(scale: 1.5)?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ring-\(file)-hover.jpg"))
						v.settle(hover: nil)
					}
				}
			}
		}
		do {
			let v = RingView(frame: NSRect(x: 0, y: 0, width: 880, height: 760))
			let content = Content.ring(snap, .overview)
			v.show(content, .none)
			let key = content.pieces.first { $0.ring == 1 }?.key ?? ""
			v.settle(hover: key)
			RingView.instant = false
			v.show(content, .update)
			let same = v.lift(key) ?? 0
			let moved = RingContent(place: content.place, pieces: content.pieces.map { p in
				var q = p; q.a0 *= 0.97; q.a1 *= 0.97; return q
			}, labelRing: content.labelRing, title: content.title, size: content.size, sub: content.sub, whole: content.whole,
			   wholeName: content.wholeName, pieceOfRow: content.pieceOfRow, rotation: content.rotation, bytes: content.bytes)
			v.show(moved, .update)
			let after = v.lift(key) ?? 0
			RingView.instant = true
			let ok = same > 0.99 && after > 0.99
			if !ok { failed += 1 }
			print(String(format: "%@ live update keeps the hover: same numbers lift %.2f, moved numbers lift %.2f", ok ? "✓" : "✗", same, after))
		}
		do {
			RingView.instant = false
			let v = RingView(frame: NSRect(x: 0, y: 0, width: 880, height: 760))
			let content = Content.ring(snap, .group(.apps))
			v.show(content, .none)
			var worst = 0.0
			for key in [nil, content.pieces.first { $0.ring == 1 }?.key] as [String?] {
				v.settle(hover: key)
				guard let (a, w, h) = v.layerPixels(), let (b, _, _) = v.drawnPixels() else { failed += 1; print("✗ no layer picture"); break }
				var diff = 0.0
				a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in
					let x = pa.bindMemory(to: UInt8.self), y = pb.bindMemory(to: UInt8.self)
					for i in stride(from: 0, to: w * h * 4, by: 4) {
						diff += Double(abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2])))
					}
				} }
				worst = max(worst, diff / Double(w * h * 3))
				for (name, px) in [("layers", a), ("drawn", b)] {
					let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
					                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
					px.copyBytes(to: rep.bitmapData!, count: w * h * 4)
					try? rep.representation(using: .jpeg, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("compare-\(name)-\(key == nil ? "plain" : "hover").jpg"))
				}
			}
			RingView.instant = true
			let ok = worst < 2.5
			if !ok { failed += 1 }
			print(String(format: "%@ layers match the drawn ring: mean difference %.2f of 255", ok ? "✓" : "✗", worst))
		}
		print(failed == 0 ? "✓ ring-check passed" : "✗ ring-check: \(failed) problems")
		return failed == 0 ? 0 : 1
	}

	struct Result {
		var stillAll = 0, stillBad = 0, dead = 0, flips = 0, overlaps = 0, labels = 0, cut = 0, labelAll = 0, labelBad = 0
		var drawMs = 0.0
		var examples: [String] = []
		var problems: Int { stillBad + dead + flips + overlaps + labelBad }
	}

	static func check(_ v: RingView, _ content: RingContent) -> Result {
		var r = Result()
		let R = v.ringRadius, C = v.ringCenter
		let outer: CGFloat = content.pieces.contains { $0.ring != 1 } ? 1.0 : 0.82
		func pt(_ rad: CGFloat, _ a: CGFloat) -> NSPoint { NSPoint(x: C.x + sin(a) * rad, y: C.y - cos(a) * rad) }
		func covered(_ a: CGFloat) -> Bool {
			content.pieces.contains { p in
				let x = CGFloat(p.a0) + CGFloat(LabelPlacer.norm(Double(a) - p.a0))
				return x < CGFloat(p.a1)
			}
		}
		var a: CGFloat = 0
		while a < .pi * 2 {
			var rad = 0.5 * R
			while rad < (outer + 0.12) * R {
				v.resetHover()
				let p = v.probeRing(pt(rad, a))
				r.stillAll += 1
				if p.first != p.settled {
					r.stillBad += 1
					if r.examples.count < 6 { r.examples.append(String(format: "still mouse at r=%.3fR %.1f°: %@ → %@", rad / R, a * 180 / .pi, p.first ?? "nothing", p.settled ?? "nothing")) }
				}
				rad += 2.5
			}
			a += .pi / 180 * 1.5
		}
		a = 0.003
		while a < .pi * 2 {
			guard covered(a) else { a += .pi / 360; continue }
			for inward in [false, true] {
				v.resetHover()
				var seen: [String?] = []
				var rad = inward ? outer * R - 1 : 0.565 * R
				while inward ? rad > 0.565 * R : rad < outer * R - 1 {
					let k = v.probeRing(pt(rad, a)).settled
					if k == nil {
						r.dead += 1
						if r.examples.count < 6 { r.examples.append(String(format: "nothing at r=%.3fR %.1f°", rad / R, a * 180 / .pi)) }
					}
					if seen.last != k {
						if seen.contains(k) {
							r.flips += 1
							if r.examples.count < 6 { r.examples.append(String(format: "back to %@ at r=%.3fR %.1f°", k ?? "nothing", rad / R, a * 180 / .pi)) }
						}
						seen.append(k)
					}
					rad += inward ? -1 : 1
				}
			}
			a += .pi / 360
		}
		for f in [0.71, 0.828, 0.835, 0.842, 0.93] as [CGFloat] where f < outer {
			v.resetHover()
			var b: CGFloat = 0.001
			var last: String?? = .none
			var keys: [String?] = []
			while b < .pi * 2 {
				let k = v.probeRing(pt(f * R, b)).settled
				if covered(b) && k == nil {
					r.dead += 1
					if r.examples.count < 6 { r.examples.append(String(format: "nothing on the circle r=%.3fR at %.1f°", f, b * 180 / .pi)) }
				}
				if last == nil || last! != k { keys.append(k); last = .some(k) }
				b += 0.002
			}
			_ = keys
		}
		func labelCheck(_ tag: String) {
			let rects = v.labelRects
			let list = Array(rects)
			for i in list.indices {
				let x = list[i].value
				if x.minX < 0 || x.maxX > v.bounds.width || x.minY < 0 || x.maxY > v.bounds.height {
					r.overlaps += 1
					if r.examples.count < 6 { r.examples.append("\(tag): label \(list[i].key) outside the view") }
				}
				let nx = max(x.minX, min(C.x, x.maxX)), ny = max(x.minY, min(C.y, x.maxY))
				if hypot(nx - C.x, ny - C.y) < outer * R + 2 {
					r.overlaps += 1
					if r.examples.count < 6 { r.examples.append("\(tag): label \(list[i].key) over the ring") }
				}
				for j in list.indices where j > i && x.insetBy(dx: 1, dy: 1).intersects(list[j].value.insetBy(dx: 1, dy: 1)) {
					r.overlaps += 1
					if r.examples.count < 6 { r.examples.append("\(tag): labels \(list[i].key) and \(list[j].key) overlap") }
				}
			}
		}
		v.settle(hover: nil)
		labelCheck("usual")
		r.labels = v.labelRects.count
		r.cut = v.labelNames.filter { $0.hasSuffix("…") }.count
		for p in content.pieces where p.ring == 1 || p.ring == 3 {
			v.settle(hover: p.key)
			labelCheck("hover \(p.name)")
		}
		v.settle(hover: nil)
		for (key, rect) in v.labelRects {
			v.settle(hover: nil)
			let p = v.probe(NSPoint(x: rect.midX, y: rect.midY))
			r.labelAll += 1
			if p.first != key || p.settled != key {
				r.labelBad += 1
				if r.examples.count < 6 { r.examples.append("label \(key): mouse on it lit \(p.first ?? "nothing"), then \(p.settled ?? "nothing")") }
			}
		}
		for p in content.pieces {
			v.setCenter(RingView.Center(title: p.name, bytes: p.bytes, sub: "65% of Group Containers", hint: p.detail))
			for rc in v.centerRects {
				let far = [CGPoint(x: rc.minX, y: rc.minY), CGPoint(x: rc.maxX, y: rc.minY), CGPoint(x: rc.minX, y: rc.maxY),
				           CGPoint(x: rc.maxX, y: rc.maxY)].map { hypot($0.x - C.x, $0.y - C.y) }.max() ?? 0
				if far > v.centerTextRadius + 2 {
					r.overlaps += 1
					if r.examples.count < 6 { r.examples.append(String(format: "centre text of %@ reaches %.0f of %.0f", p.name, far, v.centerTextRadius)) }
				}
			}
		}
		v.setCenter(RingView.Center())
		v.settle(hover: nil)
		var ms: [Double] = []
		for k in 0..<6 {
			if k == 3, let p = content.pieces.first(where: { $0.ring == 1 }) { v.settle(hover: p.key) }
			ms.append(v.timeDraw())
		}
		r.drawMs = ms.dropFirst().reduce(0, +) / Double(ms.count - 1)
		if ProcessInfo.processInfo.environment["BF_DRAW_PARTS"] != nil {
			var parts: [String] = []
			for part in ["arcs", "labels", "center"] {
				RingView.skip = Set(["arcs", "labels", "center"]).subtracting([part])
				let t = (0..<4).map { _ in v.timeDraw() }.dropFirst().reduce(0, +) / 3
				parts.append(String(format: "%@ %.1f", part, t))
			}
			RingView.skip = []
			r.examples.append("draw parts (ms): " + parts.joined(separator: ", "))
		}
		v.settle(hover: nil)
		return r
	}

	static func lopsided(_ s: Snapshot, from: Node?) -> Node? {
		guard let start = from else { return nil }
		var queue = [(start, 0)]
		var best: (Node, UInt64)?
		var visits = 0
		while !queue.isEmpty && visits < 4000 {
			let (n, depth) = queue.removeFirst()
			visits += 1
			let entries = s.tree.entries(n).filter { $0.bytes > 0 }
			let total = s.tree.size(n)
			if entries.count >= 10, total >= 1_000_000_000, let big = entries.map(\.bytes).max(), Double(big) > 0.6 * Double(total) {
				if best == nil || total > best!.1 { best = (n, total) }
			}
			if depth < 4 { for e in entries.prefix(12) { if let c = e.node { queue.append((c, depth + 1)) } } }
		}
		return best?.0
	}
}

enum TrashCheck {
	static func run(_ dir: String) -> Int32 {
		let fm = FileManager.default
		let trash = (dir as NSString).appendingPathComponent("fake-trash")
		try? fm.removeItem(atPath: trash)
		try? fm.createDirectory(atPath: trash + "/folder/inner", withIntermediateDirectories: true)
		fm.createFile(atPath: trash + "/folder/inner/a.bin", contents: Data(count: 100_000))
		fm.createFile(atPath: trash + "/.DS_Store", contents: Data(count: 10))
		fm.createFile(atPath: trash + "/locked.txt", contents: Data("x".utf8))
		fm.createFile(atPath: trash + "/folder/locked-inside.txt", contents: Data("y".utf8))
		_ = chflags(trash + "/locked.txt", UInt32(UF_IMMUTABLE))
		_ = chflags(trash + "/folder/locked-inside.txt", UInt32(UF_IMMUTABLE))
		let failed = Remover.empty(trash)
		let left = (try? fm.contentsOfDirectory(atPath: trash)) ?? ["?"]
		var bad = 0
		if failed != 0 || !left.isEmpty || !fm.fileExists(atPath: trash) { bad += 1 }
		print("\(bad == 0 ? "✓" : "✗") emptied a Trash-like folder with a locked file: \(failed) failed, \(left.count) left, folder kept: \(fm.fileExists(atPath: trash))")
		let missing = Remover.empty(trash + "/nope")
		print("\(missing == 0 ? "✓" : "✗") a missing folder counts as nothing to empty")
		if missing != 0 { bad += 1 }
		let list = [Freed(id: "a", date: Date(timeIntervalSince1970: 1_800_000_000), kind: .trash,
		                  items: [(path: "/Users/x/Library/Caches/one", bytes: 123, now: "/Users/x/.Trash/one"),
		                          (path: "/Users/x/With Space/two", bytes: 456, now: "/Users/x/.Trash/two 2")]),
		            Freed(id: "b", date: Date(timeIntervalSince1970: 1_800_000_100), kind: .empty,
		                  items: [(path: "Trash", bytes: 999, now: "")])]
		FreedLog.write(list)
		let back = FreedLog.read()
		let same = back.count == 2 && back[0].items.count == 2 && back[0].items[1].now == "/Users/x/.Trash/two 2"
			&& back[1].kind == .empty && back[1].total == 999 && back[0].total == 579
		print("\(same ? "✓" : "✗") freed log written and read back (\(back.count) operations)")
		if !same { bad += 1 }
		try? fm.removeItem(atPath: trash)
		return bad == 0 ? 0 : 1
	}
}
