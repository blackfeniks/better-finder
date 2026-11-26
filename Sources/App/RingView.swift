import AppKit
import QuartzCore

enum LabelPlacer {
	struct Cand {
		var key: String
		var mid: Double
		var priority: Int
		var weight: Double
		var side: Double = 1
		var want: Double = 0
		var y: Double = 0
	}

	static let tau = Double.pi * 2

	static func norm(_ a: Double) -> Double {
		let r = a.truncatingRemainder(dividingBy: tau)
		return r < 0 ? r + tau : r
	}

	static func split(_ list: [Cand]) -> [Cand] {
		var out = list
		var load = [0, 0]
		var flex: [Int] = []
		for i in out.indices {
			let s = sin(out[i].mid)
			if abs(s) < 0.12 { flex.append(i); continue }
			out[i].side = s >= 0 ? 1 : -1
			load[s >= 0 ? 0 : 1] += 1
		}
		for i in flex.sorted(by: { out[$0].priority < out[$1].priority }) {
			let right = load[0] <= load[1]
			out[i].side = right ? 1 : -1
			load[right ? 0 : 1] += 1
		}
		return out
	}

	static func bend(_ c: Cand, y: Double, cy: Double, rl: Double) -> Double {
		let cosv = max(-1, min(1, (cy - y) / rl))
		var e = acos(cosv)
		if c.side < 0 { e = tau - e }
		let d = abs(e - norm(c.mid))
		return min(d, tau - d)
	}

	static func place(_ input: [Cand], cy: Double, rl: Double, gap: Double, top: Double, bottom: Double,
	                  maxBend: Double, maxShift: Double = .infinity) -> [Cand] {
		guard bottom > top, !input.isEmpty else { return [] }
		var list = input
		for i in list.indices { list[i].want = cy - cos(list[i].mid) * rl }
		let room = Int((bottom - top) / gap) + 1
		if list.count > room {
			list.sort { ($0.priority, -$0.weight) < ($1.priority, -$1.weight) }
			list = Array(list.prefix(room))
		}
		while !list.isEmpty {
			list.sort { $0.want < $1.want }
			spread(&list, gap: gap, top: top, bottom: bottom)
			var worst: Int?
			var worstBend = 0.0
			for (i, l) in list.enumerated() {
				let shift = abs(l.y - l.want) / maxShift
				let b = max(bend(l, y: l.y, cy: cy, rl: rl) / maxBend, shift)
				guard b > 1 else { continue }
				if let w = worst, l.priority < list[w].priority || (l.priority == list[w].priority && b <= worstBend) { continue }
				worst = i
				worstBend = b
			}
			guard let w = worst else { break }
			list.remove(at: w)
		}
		return list
	}

	private static func spread(_ list: inout [Cand], gap: Double, top: Double, bottom: Double) {
		var groups: [(start: Int, count: Int, y0: Double)] = []
		func clamped(_ g: (start: Int, count: Int, y0: Double)) -> (start: Int, count: Int, y0: Double) {
			var g = g
			g.y0 = max(top, min(bottom - Double(g.count - 1) * gap, g.y0))
			return g
		}
		for i in list.indices {
			groups.append(clamped((i, 1, list[i].want)))
			while groups.count > 1 {
				let b = groups[groups.count - 1], a = groups[groups.count - 2]
				guard a.y0 + Double(a.count) * gap > b.y0 + 1e-9 else { break }
				let count = a.count + b.count
				let mean = list[a.start..<a.start + count].reduce(0) { $0 + $1.want } / Double(count)
				groups.removeLast(2)
				groups.append(clamped((a.start, count, mean - Double(count - 1) * gap / 2)))
			}
		}
		for g in groups { for k in 0..<g.count { list[g.start + k].y = g.y0 + Double(k) * gap } }
	}

	static func score(_ cands: [Cand]) -> Double {
		let s = split(cands)
		var total = 0.0
		for side in [1.0, -1.0] {
			let kept = place(s.filter { $0.side == side }, cy: 0, rl: 1, gap: 0.095, top: -1.04, bottom: 1.02, maxBend: 0.42, maxShift: 0.25)
			total += kept.reduce(0) { $0 + $1.weight }
		}
		return total
	}
}

final class RingView: NSView {
	enum Transition: Equatable { case none, zoomIn(String), zoomOut(String), fade, update, reveal }

	struct Center: Equatable {
		var title = ""
		var bytes: UInt64?
		var size = ""
		var sub = ""
		var hint = ""
		var progress: Double?
	}

	var onHover: ((String?) -> Void)?
	var onClick: ((Piece) -> Void)?
	var onCenterClick: (() -> Void)?
	var centerIsBack = false
	static var instant = false

	private var content = RingContent.empty
	private var arcs: [Arc] = []
	private var anim: Anim?
	private var hoverKey: String?
	private var reported: String??
	private var center = Center()
	private var loading = false
	private var loadStart = CACurrentMediaTime()
	private var link: CADisplayLink?
	private var lastTick: CFTimeInterval = 0
	private var pressed: Hit?

	private var labels: [String: LabelState] = [:]
	private var labelFocus: String?
	private var focusWanted: String?
	private var focusAt: CFTimeInterval = 0
	private var labelsHeld = false
	private var pinLabels = false
	private var hitLabel = false

	private var shown: Double = 0
	private var rollFrom: Double = 0
	private var rollTo: Double = 0
	private var rollStart: CFTimeInterval = 0

	private struct Arc {
		var piece: Piece
		var a0: CGFloat, a1: CGFloat, r0: CGFloat, r1: CGFloat
		var alpha: CGFloat = 1
		var lift: CGFloat = 0
		var focus: CGFloat = 1
		var leaving = false
	}

	private struct LabelState {
		var piece: Piece
		var side: CGFloat
		var y: CGFloat
		var yTarget: CGFloat
		var alpha: CGFloat
		var target: CGFloat
		var name: NSAttributedString
		var size: NSAttributedString
		var nameW: CGFloat
		var sizeW: CGFloat
	}

	private struct Frame { var a0, a1, r0, r1, alpha: CGFloat }
	private enum Fade { case none, fadeIn, fadeOut }
	private struct AnimItem { var index: Int; var from: Frame; var to: Frame; var fade: Fade }
	private struct Anim { var items: [AnimItem]; var t0: CFTimeInterval; var duration: Double; var labelsAfter: Bool }
	private enum Hit: Equatable { case none, center, piece(String) }

	private static let band: [Int: (CGFloat, CGFloat)] = [1: (0.60, 0.82), 2: (0.85, 1.0), 3: (0.60, 1.0)]
	private static let hole: CGFloat = 0.56
	private static let liftInner: CGFloat = 0.04
	private static let liftOuter: CGFloat = 0.03
	private static let tau = CGFloat.pi * 2

	override var isFlipped: Bool { true }
	override var acceptsFirstResponder: Bool { false }

	override init(frame: NSRect) {
		super.init(frame: frame)
		wantsLayer = true
		layerContentsRedrawPolicy = .duringViewResize
		layer?.drawsAsynchronously = true
	}

	required init?(coder: NSCoder) { fatalError() }

	private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

	private var blocking: Bool { anim?.labelsAfter ?? false }

	func show(_ next: RingContent, _ transition: Transition) {
		frozen = false
		let old = arcs.filter { !$0.leaving }
		let oldRot = CGFloat(content.rotation)
		let newRot = CGFloat(next.rotation)
		let transition: Transition = old.isEmpty && transition == .update ? .reveal : transition
		let target = next.pieces
		content = next
		var keep: [String: Arc] = [:]
		for a in old { keep[a.piece.key] = a }
		func home(_ p: Piece) -> Arc {
			let b = Self.band[p.ring]!
			var a = Arc(piece: p, a0: p.a0, a1: p.a1, r0: b.0, r1: b.1)
			if let o = keep[p.key] { a.lift = o.lift; a.focus = o.focus }
			return a
		}
		if transition != .update {
			reported = nil
			labels.removeAll()
		}

		if Self.instant || transition == .none || reduceMotion || old.isEmpty && transition != .reveal {
			arcs = target.map(home)
			anim = nil
			labelsHeld = false
			rebuildLayers()
			layoutLabels(snap: true)
			kick()
			retrack()
			return
		}
		if transition == .update && anim == nil && old.count == target.count
			&& target.allSatisfy({ p in keep[p.key].map { abs($0.a0 - p.a0) < 0.002 && abs($0.a1 - p.a1) < 0.002 } ?? false }) {
			let same = arcs.count == target.count
			arcs = target.map(home)
			if same { syncLayers(force: true) } else { rebuildLayers() }
			layoutLabels(snap: false)
			needsDisplay = true
			return
		}

		var items: [AnimItem] = []
		var next: [Arc] = []
		func add(_ p: Piece, from: Frame, to: Frame, fade: Fade, leaving: Bool = false) {
			var from = from
			let k = (((to.a0 + to.a1) - (from.a0 + from.a1)) / 2 / Self.tau).rounded()
			from.a0 += k * Self.tau; from.a1 += k * Self.tau
			var a = Arc(piece: p, a0: from.a0, a1: from.a1, r0: from.r0, r1: from.r1, alpha: from.alpha)
			if let o = keep[p.key] { a.lift = o.lift; a.focus = o.focus }
			a.leaving = leaving
			next.append(a)
			items.append(AnimItem(index: next.count - 1, from: from, to: to, fade: fade))
		}
		func homeFrame(_ p: Piece) -> Frame {
			let b = Self.band[p.ring]!
			return Frame(a0: p.a0, a1: p.a1, r0: b.0, r1: b.1, alpha: 1)
		}
		func frame(_ a: Arc) -> Frame { Frame(a0: a.a0, a1: a.a1, r0: a.r0, r1: a.r1, alpha: a.alpha) }
		let targetKeys = Set(target.map(\.key))
		var duration = 0.72

		switch transition {
		case .zoomIn(let focus), .zoomOut(let focus):
			let deeper = { if case .zoomIn = transition { return true } else { return false } }()
			var f0 = deeper ? oldRot : newRot, f1 = f0 + Self.tau
			if deeper, let f = keep[focus] { f0 = f.a0; f1 = f.a1 }
			if !deeper, let f = target.first(where: { $0.key == focus }) { f0 = f.a0; f1 = f.a1 }
			let span = max(1e-6, f1 - f0)
			let fullRot = deeper ? newRot : oldRot
			func into(_ a0: CGFloat, _ a1: CGFloat) -> (CGFloat, CGFloat) {
				let r0 = CGFloat(LabelPlacer.norm(Double(a0 - fullRot)))
				return (f0 + r0 / Self.tau * span, f0 + (r0 + a1 - a0) / Self.tau * span)
			}
			func outOf(_ a0: CGFloat, _ a1: CGFloat) -> (CGFloat, CGFloat) {
				let mid = (a0 + a1) / 2
				let rm = CGFloat(LabelPlacer.norm(Double(mid - f0)))
				if rm <= span {
					let r0 = max(0, min(span, rm - (mid - a0))), r1 = max(0, min(span, rm + (a1 - mid)))
					return (fullRot + r0 / span * Self.tau, fullRot + r1 / span * Self.tau)
				}
				let end = rm - span < Self.tau - rm ? fullRot + Self.tau : fullRot
				return (end, end)
			}
			for p in target {
				let to = homeFrame(p)
				if let o = keep[p.key] {
					add(p, from: frame(o), to: to, fade: .none)
				} else if deeper {
					let (a0, a1) = into(p.a0, p.a1)
					add(p, from: Frame(a0: a0, a1: a1, r0: 1.03, r1: 1.13, alpha: 0), to: to, fade: .fadeIn)
				} else {
					let (a0, a1) = outOf(p.a0, p.a1)
					let b: (CGFloat, CGFloat) = p.ring == 2 ? (0.82, 0.85) : (0.50, 0.58)
					add(p, from: Frame(a0: a0, a1: a1, r0: b.0, r1: b.1, alpha: 0), to: to, fade: .fadeIn)
				}
			}
			for o in old where !targetKeys.contains(o.piece.key) {
				let (a0, a1) = deeper ? outOf(o.a0, o.a1) : into(o.a0, o.a1)
				let dr: CGFloat = deeper ? -0.1 : 0.12
				add(o.piece, from: frame(o), to: Frame(a0: a0, a1: a1, r0: o.r0 + dr, r1: o.r1 + dr, alpha: 0), fade: .fadeOut, leaving: true)
			}
		case .update, .fade:
			duration = transition == .fade ? 0.34 : 0.5
			for p in target {
				let to = homeFrame(p)
				if transition == .update, let o = keep[p.key] {
					add(p, from: frame(o), to: to, fade: .none)
				} else {
					var from = to; from.alpha = 0
					add(p, from: from, to: to, fade: .fadeIn)
				}
			}
			for o in old where transition == .fade || !targetKeys.contains(o.piece.key) {
				var to = frame(o); to.alpha = 0
				add(o.piece, from: frame(o), to: to, fade: .fadeOut, leaving: true)
			}
		case .reveal:
			duration = 1.0
			for p in target {
				let to = homeFrame(p)
				add(p, from: Frame(a0: newRot, a1: newRot, r0: to.r0, r1: to.r1, alpha: 1), to: to, fade: .none)
			}
		case .none:
			break
		}
		arcs = next
		rebuildLayers()
		let heldBefore = anim?.labelsAfter ?? false
		let holds = transition != .update || heldBefore
		anim = Anim(items: items, t0: CACurrentMediaTime(), duration: duration, labelsAfter: holds)
		if holds {
			labelsHeld = true
			labels.removeAll()
		} else {
			layoutLabels(snap: false)
		}
		kick()
	}

	func setHover(_ key: String?) {
		guard key != hoverKey else { return }
		hoverKey = key
		focusWanted = key
		focusAt = CACurrentMediaTime() + 0.08
		if Self.instant {
			settleHover()
			if !pinLabels {
				labelFocus = key
				layoutLabels(snap: true)
			}
		}
		kick()
	}

	func setCenter(_ c: Center) {
		guard c != center else { return }
		let old = center
		center = c
		if let b = c.bytes {
			let to = Double(b)
			if old.bytes == nil || Self.instant || reduceMotion {
				shown = to; rollTo = to; rollStart = 0
			} else if to != rollTo {
				rollFrom = shown; rollTo = to; rollStart = CACurrentMediaTime()
				kick()
			}
		}
		needsDisplay = true
	}

	func setLoading(_ on: Bool) {
		guard on != loading else { return }
		loading = on
		loadStart = CACurrentMediaTime()
		kick()
	}

	private var W: CGFloat { bounds.width }
	private var H: CGFloat { bounds.height }
	private var labelRoom: CGFloat { W >= 560 && H >= 340 ? min(210, max(130, W * 0.17)) : 0 }
	private var showLabels: Bool { labelRoom > 0 }
	private var R: CGFloat {
		let byWidth = W / 2 - (showLabels ? labelRoom + 30 : 18)
		return max(40, min(byWidth, H / 2 - 30))
	}
	private var C: CGPoint { CGPoint(x: W / 2, y: H / 2) }
	private var restOuter: CGFloat { content.pieces.contains { $0.ring != 1 } ? 1.0 : Self.band[1]!.1 }
	private var outerLift: CGFloat { content.pieces.contains { $0.ring == 2 } ? Self.liftOuter : 0 }

	private func radii(_ a: Arc) -> (CGFloat, CGFloat) {
		if a.piece.ring != 2 {
			let l = a.lift * Self.liftInner
			return (max(0, a.r0 - l) * R, a.r1 * R)
		}
		let l = a.lift * Self.liftOuter
		return ((a.r0 + l) * R, (a.r1 + l) * R)
	}

	private func point(_ r: CGFloat, _ angle: CGFloat) -> CGPoint {
		CGPoint(x: C.x + sin(angle) * r, y: C.y - cos(angle) * r)
	}

	private static func within(_ a: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> Bool {
		let x = a0 + CGFloat(LabelPlacer.norm(Double(a - a0)))
		return x < a1
	}

	private var lit: Arc? { hoverKey.flatMap { k in arcs.first { $0.piece.key == k && !$0.leaving } } }

	private func related(_ a: Arc, _ h: Arc?) -> Bool {
		guard let h else { return true }
		if a.piece.key == h.piece.key { return true }
		if h.piece.ring != 2 && a.piece.parent == h.piece.key { return true }
		if a.piece.ring != 2 && h.piece.parent == a.piece.key { return true }
		return false
	}

	private func lifted(_ a: Arc, _ h: Arc?) -> Bool {
		guard let h else { return false }
		return a.piece.key == h.piece.key || (h.piece.ring != 2 && a.piece.parent == h.piece.key)
	}

	private func kick() {
		needsDisplay = true
		guard !Self.instant, !frozen, link == nil, window != nil else { return }
		let l = displayLink(target: self, selector: #selector(tick(_:)))
		l.add(to: .main, forMode: .common)
		link = l
		lastTick = 0
	}

	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if window == nil { link?.invalidate(); link = nil } else { rebuildLayers(); kick() }
	}

	override func setFrameSize(_ newSize: NSSize) {
		let changed = newSize != frame.size
		super.setFrameSize(newSize)
		guard changed else { return }
		needsDisplay = true
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		ringLayer.frame = bounds
		CATransaction.commit()
		syncLayers(force: true)
		if !labelsHeld { layoutLabels(snap: true) }
	}

	private static func ease(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
	private static func easeOut(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

	@objc private func tick(_ l: CADisplayLink) {
		guard !frozen else { return }
		if !step(CACurrentMediaTime()) { link?.invalidate(); link = nil }
	}

	private var frozen = false
	func freeze(at t: Double) {
		guard var an = anim else { return }
		frozen = true
		let now = CACurrentMediaTime()
		an.t0 = now - t * an.duration
		anim = an
		lastTick = 0
		_ = step(now)
		needsDisplay = true
	}

	private static func approach(_ v: inout CGFloat, _ to: CGFloat, _ dt: Double, _ tc: Double) -> Bool {
		let d = to - v
		if abs(d) < 0.003 { v = to; return false }
		v += d * CGFloat(min(1, dt / tc))
		return true
	}

	private func step(_ now: CFTimeInterval) -> Bool {
		let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, now - lastTick)
		lastTick = now
		var busy = false
		if let an = anim {
			let t = CGFloat(min(1, (now - an.t0) / an.duration))
			let e = Self.ease(t)
			for it in an.items where it.index < arcs.count {
				var a = arcs[it.index]
				a.a0 = it.from.a0 + (it.to.a0 - it.from.a0) * e
				a.a1 = it.from.a1 + (it.to.a1 - it.from.a1) * e
				a.r0 = it.from.r0 + (it.to.r0 - it.from.r0) * e
				a.r1 = it.from.r1 + (it.to.r1 - it.from.r1) * e
				switch it.fade {
				case .fadeOut: a.alpha = it.from.alpha * (1 - Self.easeOut(min(1, t / 0.45)))
				case .fadeIn: a.alpha = Self.easeOut(max(0, (t - 0.4) / 0.6))
				case .none: a.alpha = it.from.alpha + (it.to.alpha - it.from.alpha) * e
				}
				arcs[it.index] = a
			}
			busy = true
			if t >= 1 && !frozen {
				let before = arcs.count
				arcs.removeAll { $0.leaving }
				if arcs.count != before { rebuildLayers() }
				anim = nil
				if labelsHeld {
					labelsHeld = false
					labelFocus = focusWanted
					layoutLabels(snap: true)
				}
				retrack()
			}
		}
		let h = blocking ? nil : lit
		for i in arcs.indices {
			if Self.approach(&arcs[i].lift, lifted(arcs[i], h) ? 1 : 0, dt, 0.07) { busy = true }
			if Self.approach(&arcs[i].focus, related(arcs[i], h) ? 1 : 0, dt, 0.09) { busy = true }
		}
		if focusWanted != labelFocus && !labelsHeld && !pinLabels {
			if now >= focusAt {
				labelFocus = focusWanted
				layoutLabels(snap: false)
			}
			busy = true
		}
		for (k, var l) in labels {
			var moving = false
			let d = l.target - l.alpha
			if abs(d) > 0.004 {
				l.alpha += max(-1, min(1, d)) * CGFloat(min(1, dt / 0.12))
				moving = true
			} else {
				l.alpha = l.target
			}
			if Self.approach(&l.y, l.yTarget, dt, 0.09) { moving = true }
			if l.alpha <= 0.004 && l.target == 0 {
				labels[k] = nil
				continue
			}
			labels[k] = l
			if moving { busy = true }
		}
		if rollStart > 0 {
			let t = min(1, (now - rollStart) / 0.34)
			shown = rollFrom + (rollTo - rollFrom) * Double(Self.easeOut(CGFloat(t)))
			if t >= 1 { rollStart = 0; shown = rollTo } else { busy = true }
		}
		if loading && content.pieces.isEmpty { busy = true }
		syncLayers()
		if !useLayers || !labels.isEmpty || rollStart > 0 || (loading && content.pieces.isEmpty) || anim != nil { needsDisplay = true }
		return busy
	}

	private func settleHover() {
		let h = lit
		for i in arcs.indices {
			arcs[i].lift = lifted(arcs[i], h) ? 1 : 0
			arcs[i].focus = related(arcs[i], h) ? 1 : 0
		}
		syncLayers()
	}

	static var skip: Set<String> = []

	override func draw(_ dirty: NSRect) {
		guard let ctx = NSGraphicsContext.current?.cgContext, R > 0 else { return }
		ctx.setLineCap(.butt)
		if content.pieces.isEmpty && loading { drawLoading(ctx) }
		if !Self.skip.contains("arcs") && !useLayers {
			for a in arcs where a.piece.ring != 2 { drawArc(ctx, a) }
			for a in arcs where a.piece.ring == 2 { drawArc(ctx, a) }
		}
		if showLabels && !Self.skip.contains("labels") { drawLabels(ctx) }
		if !Self.skip.contains("center") { drawCenter() }
	}

	private struct Shape {
		var frame: CGPath?
		var lines: CGPath?
		var frameDash: [CGFloat] = []
		var linesDash: [CGFloat] = []
		var frameWidth: CGFloat = 1.2
	}

	private func shape(_ a: Arc) -> Shape {
		var sh = Shape()
		let (r0, r1raw) = radii(a)
		let r1 = max(r0 + 1, r1raw)
		let mid = (r0 + r1) / 2
		let gap = 3.6 / max(40, mid)
		var s = a.a0 + gap / 2, e = a.a1 - gap / 2
		if e - s < 1.2 / max(40, r1) {
			guard (a.a1 - a.a0) * r1 >= 0.8 else { return sh }
			s = (a.a0 + a.a1) / 2; e = s
		}
		let φ0 = s - .pi / 2, φ1 = e - .pi / 2
		if a.piece.kind == .free {
			let p = CGMutablePath()
			for r in [r0, r1] {
				p.move(to: point(r, s))
				p.addArc(center: C, radius: r, startAngle: φ0, endAngle: φ1, clockwise: false)
			}
			sh.frame = p; sh.frameDash = [1.5, 5]; sh.frameWidth = 1
			return sh
		}
		if e - s <= 0 {
			let p = CGMutablePath()
			p.move(to: point(r0, s)); p.addLine(to: point(r1, s))
			sh.frame = p; sh.frameWidth = 1
			return sh
		}
		if a.piece.kind != .view {
			let step: CGFloat = a.piece.ring == 2 ? 6.6 : 7.6
			let p = CGMutablePath()
			var r = r0 + step
			while r < r1 - step * 0.55 {
				let inset = 2.2 / r
				if e - s > inset * 2 {
					p.move(to: point(r, s + inset))
					p.addArc(center: C, radius: r, startAngle: φ0 + inset, endAngle: φ1 - inset, clockwise: false)
				}
				r += step
			}
			sh.lines = p
			switch a.piece.kind {
			case .hidden: sh.linesDash = [2, 3]
			case .more: sh.linesDash = [1, 3.5]
			case .files: sh.linesDash = [4, 2.5]
			default: break
			}
		}
		let f = CGMutablePath()
		f.addArc(center: C, radius: r1, startAngle: φ0, endAngle: φ1, clockwise: false)
		f.addLine(to: point(r0, e))
		f.addArc(center: C, radius: r0, startAngle: φ1, endAngle: φ0, clockwise: true)
		f.closeSubpath()
		sh.frame = f
		sh.frameDash = a.piece.kind == .view ? [3, 3] : []
		sh.frameWidth = 1.2 + 0.4 * a.lift
		return sh
	}

	private func alphas(_ a: Arc) -> (frame: CGFloat, lines: CGFloat) {
		if a.piece.kind == .free { return ((0.08 + 0.12 * a.focus) * a.alpha, 0) }
		let k = (0.22 + 0.78 * a.focus) * (1 + 0.32 * a.lift)
		let level = min(1, CGFloat(a.piece.tone) * k)
		return (level * a.alpha, level * 0.42 * a.alpha)
	}

	private func drawArc(_ ctx: CGContext, _ a: Arc) {
		guard a.alpha > 0.01 else { return }
		let sh = shape(a)
		let (fa, la) = alphas(a)
		if let l = sh.lines {
			ctx.setLineDash(phase: 0, lengths: sh.linesDash)
			ctx.setStrokeColor(NSColor(white: 1, alpha: la).cgColor)
			ctx.setLineWidth(1)
			ctx.addPath(l); ctx.strokePath()
		}
		if let f = sh.frame {
			ctx.setLineDash(phase: 0, lengths: sh.frameDash)
			ctx.setStrokeColor(NSColor(white: 1, alpha: fa).cgColor)
			ctx.setLineWidth(sh.frameWidth)
			ctx.addPath(f); ctx.strokePath()
		}
		ctx.setLineDash(phase: 0, lengths: [])
	}

	private final class ArcLayer {
		let lines = CAShapeLayer()
		let frame = CAShapeLayer()
		var made: [CGFloat] = []
		init(scale: CGFloat) {
			for l in [lines, frame] {
				l.fillColor = nil
				l.strokeColor = NSColor.white.cgColor
				l.lineCap = .butt
				l.lineJoin = .miter
				l.contentsScale = scale
			}
			lines.lineWidth = 1
		}
	}

	private var useLayers: Bool { !Self.instant && !drawsPieces }
	var drawsPieces = false
	private let ringLayer = CALayer()
	private var arcLayers: [ArcLayer] = []

	private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

	private func rebuildLayers() {
		guard useLayers, let host = layer else { arcLayers = []; return }
		if ringLayer.superlayer !== host {
			host.addSublayer(ringLayer)
			ringLayer.frame = bounds
		}
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		ringLayer.sublayers = nil
		arcLayers = arcs.map { _ in ArcLayer(scale: scale) }
		for pass in [false, true] {
			for (i, a) in arcs.enumerated() where (a.piece.ring == 2) == pass {
				ringLayer.addSublayer(arcLayers[i].lines)
				ringLayer.addSublayer(arcLayers[i].frame)
			}
		}
		CATransaction.commit()
		syncLayers()
	}

	private func syncLayers(force: Bool = false) {
		guard useLayers else { return }
		guard arcLayers.count == arcs.count else { return rebuildLayers() }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let size = [R, C.x, C.y]
		for (i, a) in arcs.enumerated() {
			let L = arcLayers[i]
			let made = [a.a0, a.a1, a.r0, a.r1, (a.lift * 400).rounded() / 400] + size
			if force || made != L.made {
				L.made = made
				let sh = shape(a)
				L.frame.path = sh.frame
				L.frame.lineWidth = sh.frameWidth
				L.frame.lineDashPattern = sh.frameDash.isEmpty ? nil : sh.frameDash.map { NSNumber(value: Double($0)) }
				L.lines.path = sh.lines
				L.lines.lineDashPattern = sh.linesDash.isEmpty ? nil : sh.linesDash.map { NSNumber(value: Double($0)) }
			}
			let (fa, la) = alphas(a)
			L.frame.opacity = Float(fa)
			L.lines.opacity = Float(la)
		}
		CATransaction.commit()
	}

	override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		for L in arcLayers { L.lines.contentsScale = scale; L.frame.contentsScale = scale }
		syncLayers(force: true)
	}

	private func drawLoading(_ ctx: CGContext) {
		let t = CGFloat(CACurrentMediaTime() - loadStart)
		let head = (t * 0.9).truncatingRemainder(dividingBy: 1) * Self.tau
		for (ring, step) in [(1, CGFloat(7.6)), (2, CGFloat(6.6))] {
			let b = Self.band[ring]!
			var r = b.0 * R + step / 2
			while r < b.1 * R {
				ctx.setStrokeColor(NSColor(white: 1, alpha: 0.05).cgColor)
				ctx.setLineWidth(1)
				ctx.beginPath(); ctx.addArc(center: C, radius: r, startAngle: 0, endAngle: Self.tau, clockwise: false); ctx.strokePath()
				for k in 0..<12 {
					let a1 = head - CGFloat(k) * 0.07
					let a0 = a1 - 0.07
					let alpha = 0.55 * pow(0.78, CGFloat(k)) * (ring == 1 ? 1 : 0.7)
					ctx.setStrokeColor(NSColor(white: 1, alpha: alpha).cgColor)
					ctx.beginPath()
					ctx.addArc(center: C, radius: r, startAngle: a0 - .pi / 2, endAngle: a1 - .pi / 2, clockwise: false)
					ctx.strokePath()
				}
				r += step
			}
		}
	}

	private func labelGeometry(y: CGFloat, side: CGFloat, mid: CGFloat) -> (anchor: CGPoint, stub: CGPoint, elbow: CGPoint, textX: CGFloat) {
		let base = (restOuter + outerLift) * R
		let rl = base + 18
		let anchor = point(base + 4, mid)
		let stub = point(base + 11, mid)
		let dy = y - C.y
		var ex = C.x + side * sqrt(max(0, rl * rl - dy * dy))
		ex = side > 0 ? max(ex, stub.x) : min(ex, stub.x)
		let lo = dy - 17, hi = dy + 15
		let closest: CGFloat = lo <= 0 && hi >= 0 ? 0 : min(abs(lo), abs(hi))
		let ringX = sqrt(max(0, (base + 8) * (base + 8) - closest * closest))
		let x = max(abs(ex - C.x) + 14, ringX + 10)
		return (anchor, stub, CGPoint(x: ex, y: y), C.x + side * x)
	}

	private func layoutLabels(snap: Bool) {
		guard showLabels, !labelsHeld else {
			labels.removeAll()
			return
		}
		let pieces = content.pieces
		let base = (restOuter + outerLift) * R
		let rl = base + 18
		func mid(_ p: Piece) -> Double { (p.a0 + p.a1) / 2 }
		func px(_ p: Piece) -> CGFloat { CGFloat(p.a1 - p.a0) * base }
		let ring = content.labelRing
		let usual = pieces.filter { ($0.ring == ring || ($0.kind == .free && ring == 1)) && px($0) >= 16 }
		var cands: [LabelPlacer.Cand] = []
		var alpha: [String: CGFloat] = [:]
		if let f = labelFocus.flatMap({ k in pieces.first { $0.key == k } }) {
			let inside = f.ring == 2 ? [] : Array(pieces.filter { $0.ring == 2 && $0.parent == f.key && px($0) >= 9 }
				.sorted { $0.bytes > $1.bytes }.prefix(5))
			if inside.isEmpty {
				cands.append(.init(key: f.key, mid: mid(f), priority: 0, weight: 1e15))
				alpha[f.key] = 1
			} else {
				alpha[f.key] = 0
			}
			if f.ring != 2 {
				for p in inside {
					cands.append(.init(key: p.key, mid: mid(p), priority: 1, weight: Double(p.bytes)))
					alpha[p.key] = 0.95
				}
			} else if let parent = f.parent.flatMap({ k in pieces.first { $0.key == k } }) {
				cands.append(.init(key: parent.key, mid: mid(parent), priority: 1, weight: Double(parent.bytes)))
				alpha[parent.key] = 0.9
			}
			for p in usual where alpha[p.key] == nil && p.key != f.key {
				cands.append(.init(key: p.key, mid: mid(p), priority: 2, weight: Double(p.bytes)))
				alpha[p.key] = 0.34
			}
		} else {
			for p in usual {
				cands.append(.init(key: p.key, mid: mid(p), priority: 0, weight: Double(p.bytes)))
				alpha[p.key] = 1
			}
		}
		let sided = LabelPlacer.split(cands)
		var placed: [LabelPlacer.Cand] = []
		for side in [1.0, -1.0] {
			placed += LabelPlacer.place(sided.filter { $0.side == side }, cy: Double(C.y), rl: Double(rl), gap: 36,
			                            top: 24, bottom: Double(H) - 22, maxBend: 0.42, maxShift: Double(rl) * 0.25)
		}
		var now = Set<String>()
		for c in placed {
			guard let p = pieces.first(where: { $0.key == c.key }) else { continue }
			now.insert(c.key)
			let side = CGFloat(c.side)
			let y = CGFloat(c.y)
			let g = labelGeometry(y: y, side: side, mid: CGFloat(c.mid))
			let room = (side > 0 ? W - g.textX : g.textX) - 14
			let name = Self.text(p.name, size: 13, weight: .medium, alpha: 1, room: room)
			let size = Self.text(Fmt.size(p.bytes), size: 12, weight: .regular, alpha: 0.55, room: room)
			let target = alpha[c.key] ?? 1
			if var l = labels[c.key], l.side == side {
				l.piece = p; l.yTarget = y; l.target = target; l.name = name; l.size = size
				l.nameW = name.size().width; l.sizeW = size.size().width
				if snap && l.alpha > 0 { l.y = y }
				labels[c.key] = l
			} else {
				let start: CGFloat = Self.instant ? target : 0
				labels[c.key] = LabelState(piece: p, side: side, y: y, yTarget: y, alpha: start, target: target, name: name, size: size,
				                           nameW: name.size().width, sizeW: size.size().width)
			}
		}
		var next = labels
		for (k, var l) in labels {
			if !now.contains(k) { l.target = 0 }
			if Self.instant { l.alpha = l.target; l.y = l.yTarget }
			next[k] = l.target > 0 || l.alpha > 0.004 ? l : nil
		}
		labels = next
		needsDisplay = true
		kick()
	}

	private func labelRect(_ l: LabelState) -> CGRect {
		let g = labelGeometry(y: l.y, side: l.side, mid: CGFloat((l.piece.a0 + l.piece.a1) / 2))
		let w = max(l.nameW, l.sizeW)
		return CGRect(x: l.side > 0 ? g.textX : g.textX - w, y: l.y - 17, width: w, height: 33)
	}

	private func drawLabels(_ ctx: CGContext) {
		for k in labels.keys.sorted() {
			guard let l = labels[k], l.alpha > 0.01 else { continue }
			let mid = CGFloat((l.piece.a0 + l.piece.a1) / 2)
			let g = labelGeometry(y: l.y, side: l.side, mid: mid)
			ctx.saveGState()
			ctx.setAlpha(l.alpha)
			ctx.setStrokeColor(NSColor(white: 1, alpha: 0.4).cgColor)
			ctx.setLineWidth(1)
			ctx.beginPath()
			ctx.move(to: g.anchor)
			ctx.addLine(to: g.stub)
			ctx.addLine(to: g.elbow)
			ctx.addLine(to: CGPoint(x: g.textX - l.side * 6, y: l.y))
			ctx.strokePath()
			ctx.setFillColor(NSColor(white: 1, alpha: 0.6).cgColor)
			ctx.fillEllipse(in: CGRect(x: g.anchor.x - 1.6, y: g.anchor.y - 1.6, width: 3.2, height: 3.2))
			let nw = l.nameW, sw = l.sizeW
			let nx = l.side > 0 ? g.textX : g.textX - nw
			let sx = l.side > 0 ? g.textX : g.textX - sw
			l.name.draw(at: CGPoint(x: nx, y: l.y - 17))
			l.size.draw(at: CGPoint(x: sx, y: l.y + 1))
			ctx.restoreGState()
		}
	}

	private static func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, room: CGFloat) -> NSAttributedString {
		let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
		return Fit.middle(s, [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha)], max(room, 12))
	}

	private struct CenterLine { let text: NSAttributedString; let rect: CGRect }
	private var centerLines: (key: String, lines: [CenterLine], numberTop: CGFloat, progressY: CGFloat)?

	private var textRadius: CGFloat { Self.hole * R - 10 }

	private func roomAcross(_ top: CGFloat, _ bottom: CGFloat) -> CGFloat {
		let far = max(abs(top - C.y), abs(bottom - C.y))
		let r = textRadius
		return far >= r ? 0 : 2 * sqrt(r * r - far * far) - 6
	}

	private func centerLayout() -> (lines: [CenterLine], numberTop: CGFloat, progressY: CGFloat, big: NSFont) {
		let c = center
		let roomy = R > 130
		let big = NSFont.monospacedDigitSystemFont(ofSize: R > 210 ? 40 : roomy ? 30 : 22, weight: .light)
		let key = "\(c.title)|\(c.sub)|\(c.hint)|\(c.progress != nil)|\(R)|\(C.x)|\(C.y)"
		if let cl = centerLines, cl.key == key { return (cl.lines, cl.numberTop, cl.progressY, big) }
		let nameFont = NSFont.systemFont(ofSize: roomy ? 14 : 12, weight: .medium)
		let small = NSFont.systemFont(ofSize: roomy ? 13 : 11)
		let hintFont = NSFont.systemFont(ofSize: roomy ? 12 : 11)
		func attrs(_ f: NSFont, _ a: CGFloat) -> [NSAttributedString.Key: Any] { [.font: f, .foregroundColor: NSColor(white: 1, alpha: a)] }
		func lh(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) + 1 }
		var lines: [CenterLine] = []
		func put(_ t: NSAttributedString, _ top: CGFloat, _ h: CGFloat) {
			let w = t.size().width
			lines.append(CenterLine(text: t, rect: CGRect(x: C.x - w / 2, y: top, width: w, height: h)))
		}
		let bigH = lh(big)
		let numberTop = C.y - bigH / 2 - 4
		let th = lh(nameFont)
		let near = roomAcross(numberTop + 2 - th, numberTop + 2), far = roomAcross(numberTop + 2 - 2 * th, numberTop + 2 - th)
		let ta = attrs(nameFont, 0.64)
		let title = Fit.width(c.title, ta) <= near ? Fit.lines(c.title, ta, rooms: [near]) : Fit.lines(c.title, ta, rooms: [far, near])
		for (k, t) in title.enumerated() {
			put(t, numberTop + 2 - CGFloat(title.count - k) * th, th)
		}
		var y = numberTop + bigH + 1
		let sh = lh(small)
		if !c.sub.isEmpty {
			put(Fit.lines(c.sub, attrs(small, 0.43), rooms: [roomAcross(y, y + sh)]).first ?? NSAttributedString(), y, sh)
			y += sh
		}
		let progressY = y + 9
		if c.progress != nil { y += 14 }
		y += 7
		let hh = lh(hintFont)
		let hint = Fit.lines(c.hint, attrs(hintFont, 0.3), rooms: [roomAcross(y, y + hh), roomAcross(y + hh, y + 2 * hh)])
		for (k, t) in hint.enumerated() { put(t, y + CGFloat(k) * hh, hh) }
		centerLines = (key, lines, numberTop, progressY)
		return (lines, numberTop, progressY, big)
	}

	private func drawCenter() {
		guard textRadius > 24 else { return }
		let (lines, numberTop, progressY, big) = centerLayout()
		for l in lines { l.text.draw(at: l.rect.origin) }
		let number = center.bytes != nil ? Fmt.size(UInt64(max(0, shown.rounded()))) : center.size
		let n = Fit.middle(number, [.font: big, .foregroundColor: NSColor(white: 1, alpha: 0.96)],
		                   roomAcross(numberTop, numberTop + big.ascender - big.descender))
		let nw = n.size().width
		n.draw(at: CGPoint(x: C.x - nw / 2, y: numberTop))
		if let p = center.progress {
			let w = min(roomAcross(progressY, progressY + 2) * 0.7, 160)
			let r = CGRect(x: C.x - w / 2, y: progressY, width: w, height: 2)
			NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
			NSColor(white: 1, alpha: 0.75).setFill()
			NSBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY, width: w * CGFloat(max(0, min(1, p))), height: 2), xRadius: 1, yRadius: 1).fill()
		}
	}

	var centerRects: [CGRect] { centerLayout().lines.map(\.rect) }
	var centerTextRadius: CGFloat { textRadius }

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for t in trackingAreas { removeTrackingArea(t) }
		addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
		                               owner: self, userInfo: nil))
	}

	private func hit(_ p: NSPoint) -> Hit {
		hitLabel = false
		for (k, l) in labels where l.alpha > 0.5 && l.target > 0 && labelRect(l).insetBy(dx: -4, dy: -3).contains(p) {
			if arcs.contains(where: { $0.piece.key == k && !$0.leaving }) { hitLabel = true; return .piece(k) }
		}
		let dx = p.x - C.x, dy = p.y - C.y
		let d = hypot(dx, dy) / R
		let angle = atan2(dx, -dy)
		if let a = lit {
			let (r0, r1) = radii(a)
			if d * R >= r0 - 3 && d * R <= r1 + 3 && Self.within(angle, a.piece.a0, a.piece.a1) { return .piece(a.piece.key) }
		}
		if d < Self.hole { return .center }
		guard d <= restOuter + outerLift + 0.05 else { return .none }
		func at(_ ring: Int) -> Arc? {
			arcs.first { $0.piece.ring == ring && !$0.leaving && $0.alpha > 0.5 && Self.within(angle, $0.piece.a0, $0.piece.a1) }
		}
		if let a = at(3) { return .piece(a.piece.key) }
		let split = (Self.band[1]!.1 + Self.band[2]!.0) / 2
		if d >= split, let a = at(2) { return .piece(a.piece.key) }
		if let a = at(1) { return .piece(a.piece.key) }
		return .none
	}

	private func piece(_ key: String) -> Piece? { arcs.first { $0.piece.key == key && !$0.leaving }?.piece }

	private func track(_ p: NSPoint) {
		let h = hit(p)
		if pinLabels != hitLabel {
			pinLabels = hitLabel
			focusAt = CACurrentMediaTime() + 0.08
			kick()
		}
		let clickable: Bool
		switch h {
		case .center: clickable = centerIsBack
		case .piece(let k): clickable = piece(k).map { $0.open != nil || $0.otherDisk != nil } ?? false
		case .none: clickable = false
		}
		(clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
		guard !blocking else { return }
		let key: String? = if case .piece(let k) = h { k } else { nil }
		if let r = reported, r == key { return }
		reported = .some(key)
		onHover?(key)
	}

	private func retrack() {
		guard !Self.instant, let w = window, w.isKeyWindow else { return }
		let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
		guard bounds.contains(p) else { return }
		track(p)
	}

	override func mouseMoved(with event: NSEvent) { track(convert(event.locationInWindow, from: nil)) }
	override func mouseEntered(with event: NSEvent) { track(convert(event.locationInWindow, from: nil)) }

	override func mouseExited(with event: NSEvent) {
		NSCursor.arrow.set()
		if pinLabels { pinLabels = false; kick() }
		if let r = reported, r == nil { return }
		reported = .some(nil)
		onHover?(nil)
	}

	override func mouseDown(with event: NSEvent) {
		pressed = hit(convert(event.locationInWindow, from: nil))
	}

	override func mouseUp(with event: NSEvent) {
		let h = hit(convert(event.locationInWindow, from: nil))
		defer { pressed = nil }
		guard !blocking, let was = pressed, was == h else { return }
		switch h {
		case .piece(let key): if let p = piece(key) { onClick?(p) }
		case .center: if centerIsBack { onCenterClick?() }
		case .none: break
		}
	}

	func probe(_ p: NSPoint) -> (first: String?, settled: String?) {
		func key(_ h: Hit) -> String? { if case .piece(let k) = h { return k } else { return nil } }
		let first = key(hit(p))
		pinLabels = hitLabel
		setHover(first)
		settleHover()
		let settled = key(hit(p))
		return (first, settled)
	}

	func probeRing(_ p: NSPoint) -> (first: String?, settled: String?) {
		func key(_ h: Hit) -> String? { if case .piece(let k) = h { return k } else { return nil } }
		let first = key(hit(p))
		hoverKey = first
		settleHover()
		return (first, key(hit(p)))
	}

	func resetHover() {
		hoverKey = nil
		settleHover()
	}

	func lift(_ key: String) -> CGFloat? { arcs.first { $0.piece.key == key }?.lift }

	var labelNames: [String] { labels.values.filter { $0.target > 0 }.map { $0.name.string } }

	var labelRects: [String: CGRect] {
		labels.filter { $0.value.target > 0 }.mapValues { l in
			let g = labelGeometry(y: l.yTarget, side: l.side, mid: CGFloat((l.piece.a0 + l.piece.a1) / 2))
			let w = max(l.nameW, l.sizeW)
			return CGRect(x: l.side > 0 ? g.textX : g.textX - w, y: l.yTarget - 17, width: w, height: 33)
		}
	}

	var ringRadius: CGFloat { R }
	var ringCenter: CGPoint { C }
	func timeDraw(scale: CGFloat = 2) -> Double {
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
		                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
		                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
		      let g = NSGraphicsContext(bitmapImageRep: rep) else { return -1 }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = g
		g.cgContext.scaleBy(x: scale, y: scale)
		g.cgContext.translateBy(x: 0, y: H)
		g.cgContext.scaleBy(x: 1, y: -1)
		NSGraphicsContext.current = NSGraphicsContext(cgContext: g.cgContext, flipped: true)
		let t0 = CACurrentMediaTime()
		draw(bounds)
		g.flushGraphics()
		let ms = (CACurrentMediaTime() - t0) * 1000
		NSGraphicsContext.restoreGraphicsState()
		return ms
	}
	func picture(scale: CGFloat = 2) -> Data? {
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
		                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
		                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
		      let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = g
		let ctx = g.cgContext
		ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.057, alpha: 1).cgColor)
		ctx.fill(CGRect(x: 0, y: 0, width: W * scale, height: H * scale))
		ctx.scaleBy(x: scale, y: scale)
		ctx.translateBy(x: 0, y: H)
		ctx.scaleBy(x: 1, y: -1)
		NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
		draw(bounds)
		g.flushGraphics()
		NSGraphicsContext.restoreGraphicsState()
		return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
	}

	func layerPixels(scale: CGFloat = 1) -> (Data, Int, Int)? {
		guard let root = layer else { return nil }
		display()
		let w = Int(W * scale), h = Int(H * scale)
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
		                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
		ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.057, alpha: 1).cgColor)
		ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
		ctx.scaleBy(x: scale, y: scale)
		ctx.translateBy(x: 0, y: H)
		ctx.scaleBy(x: 1, y: -1)
		root.render(in: ctx)
		guard let data = ctx.data else { return nil }
		return (Data(bytes: data, count: w * h * 4), w, h)
	}

	func drawnPixels(scale: CGFloat = 1) -> (Data, Int, Int)? {
		let w = Int(W * scale), h = Int(H * scale)
		guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
		                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
		ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.057, alpha: 1).cgColor)
		ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
		ctx.scaleBy(x: scale, y: scale)
		ctx.translateBy(x: 0, y: H)
		ctx.scaleBy(x: 1, y: -1)
		let was = drawsPieces
		drawsPieces = true
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
		draw(bounds)
		NSGraphicsContext.restoreGraphicsState()
		drawsPieces = was
		guard let data = ctx.data else { return nil }
		return (Data(bytes: data, count: w * h * 4), w, h)
	}

	func settle(hover key: String?) {
		setHover(key)
		var t = CACurrentMediaTime()
		for _ in 0..<400 { t += 1.0 / 60; if !step(t) { break } }
	}
}
