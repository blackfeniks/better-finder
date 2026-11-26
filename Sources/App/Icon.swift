import AppKit

enum AppIcon {
	static func write(_ dir: String) -> Int32 {
		try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
			let px = size * scale
			guard let rep = render(px) else { return 1 }
			let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
			try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
		}
		return 0
	}

	static func render(_ px: Int) -> NSBitmapImageRep? {
		guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
		                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
		      let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.current = g
		let ctx = g.cgContext
		let s = CGFloat(px) / 1024
		ctx.scaleBy(x: s, y: s)
		let small = px <= 64
		let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
		let path = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
		ctx.saveGState()
		ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor(white: 0, alpha: 0.5).cgColor)
		ctx.addPath(path); ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.fillPath()
		ctx.restoreGState()
		ctx.saveGState()
		ctx.addPath(path); ctx.clip()
		let colors = [NSColor(white: 0.125, alpha: 1).cgColor, NSColor(white: 0.075, alpha: 1).cgColor, NSColor(white: 0.04, alpha: 1).cgColor]
		if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
			ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
		}
		ctx.addPath(path); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
		let rim = [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0.03).cgColor, NSColor(white: 1, alpha: 0).cgColor]
		if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: rim as CFArray, locations: [0, 0.35, 1]) {
			ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
		}
		ctx.restoreGState()

		let c = CGPoint(x: 512, y: 512)
		let R: CGFloat = 292
		let line: CGFloat = small ? 14 : 8
		func arc(_ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> CGMutablePath {
			let p = CGMutablePath()
			p.addArc(center: c, radius: r, startAngle: .pi / 2 - a0, endAngle: .pi / 2 - a1, clockwise: true)
			return p
		}
		func block(_ r0: CGFloat, _ r1: CGFloat, _ a0: CGFloat, _ a1: CGFloat, _ tone: CGFloat, lines: Int) {
			let gap = (small ? 30 : 16) / ((r0 + r1) / 2)
			let s = a0 + gap / 2, e = a1 - gap / 2
			if !small && lines > 0 {
				ctx.setStrokeColor(NSColor(white: 1, alpha: tone * 0.4).cgColor)
				ctx.setLineWidth(line * 0.65)
				for k in 1...lines {
					let r = r0 + (r1 - r0) * CGFloat(k) / CGFloat(lines + 1)
					let inset = 14 / r
					ctx.addPath(arc(r, s + inset, e - inset)); ctx.strokePath()
				}
			}
			let frame = CGMutablePath()
			frame.addArc(center: c, radius: r1, startAngle: .pi / 2 - s, endAngle: .pi / 2 - e, clockwise: true)
			frame.addArc(center: c, radius: r0, startAngle: .pi / 2 - e, endAngle: .pi / 2 - s, clockwise: false)
			frame.closeSubpath()
			ctx.setStrokeColor(NSColor(white: 1, alpha: tone).cgColor)
			ctx.setLineWidth(line)
			ctx.setLineJoin(.round)
			ctx.addPath(frame); ctx.strokePath()
		}
		let tau = CGFloat.pi * 2
		let inner: [(CGFloat, CGFloat, CGFloat)] = [(0, 0.36, 0.95), (0.36, 0.56, 0.62), (0.56, 0.70, 0.86)]
		for (a, b, t) in inner { block(R * 0.56, R * 0.80, a * tau, b * tau, t, lines: 2) }
		let outer: [(CGFloat, CGFloat, CGFloat)] = [(0, 0.22, 0.72), (0.22, 0.36, 0.46), (0.36, 0.48, 0.5), (0.48, 0.56, 0.34)]
		for (a, b, t) in outer { block(R * 0.86, R * 1.0, a * tau, b * tau, t, lines: 1) }
		ctx.setStrokeColor(NSColor(white: 1, alpha: 0.28).cgColor)
		ctx.setLineWidth(line * 0.7)
		ctx.setLineCap(.round)
		ctx.setLineDash(phase: 0, lengths: [0.1, small ? 34 : 22])
		for r in [R * 0.56, R * 0.80] { ctx.addPath(arc(r, 0.715 * tau, 0.985 * tau)); ctx.strokePath() }
		NSGraphicsContext.restoreGraphicsState()
		return rep
	}
}
