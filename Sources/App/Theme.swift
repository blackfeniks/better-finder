import AppKit
import SwiftUI

enum Theme {
	static let bgTop = Color(red: 0.060, green: 0.060, blue: 0.068)
	static let bgBottom = Color(red: 0.036, green: 0.036, blue: 0.042)
	static let card = Color(red: 0.075, green: 0.075, blue: 0.085)
	static let hair = Color.white.opacity(0.08)
	static let edge = Color.white.opacity(0.13)

	static let t1 = Color(red: 0.96, green: 0.96, blue: 0.97)
	static let t2 = Color.white.opacity(0.64)
	static let t3 = Color.white.opacity(0.43)
	static let t4 = Color.white.opacity(0.27)

	static let hover = Color.white.opacity(0.055)
	static let pick = Color.white.opacity(0.115)

	static let barHeight: CGFloat = 52
	static let corner: CGFloat = 9
	static let rowHeight: CGFloat = 50

	static let panelDefault: CGFloat = 410
	static let panelMin: CGFloat = 300
	static let panelMax: CGFloat = 680
	static let stageMin: CGFloat = 400
	static let windowMin = NSSize(width: Theme.stageMin + Theme.panelMin + 60, height: 560)

	static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
		.system(size: size, weight: weight).monospacedDigit()
	}
}

enum Fmt {
	static func size(_ b: UInt64) -> String {
		let v = Double(b)
		if v >= 1e12 { return String(format: "%.2f TB", v / 1e12) }
		if v >= 1e9 { return String(format: v >= 1e11 ? "%.0f GB" : "%.1f GB", v / 1e9) }
		if v >= 1e6 { return String(format: "%.0f MB", v / 1e6) }
		if v >= 1e3 { return String(format: "%.0f KB", v / 1e3) }
		return "\(b) B"
	}

	static func size(_ b: Int64) -> String { b < 0 ? "−" + size(UInt64(-b)) : size(UInt64(b)) }

	static func share(_ a: UInt64, of b: UInt64) -> String {
		guard b > 0, a > 0 else { return "0%" }
		let p = Double(a) / Double(b) * 100
		if p >= 10 { return "\(Int(p.rounded()))%" }
		if p >= 1 { return String(format: "%.1f%%", p) }
		return "<1%"
	}

	private static let counter: NumberFormatter = {
		let f = NumberFormatter()
		f.numberStyle = .decimal
		f.locale = Locale(identifier: "en_US")
		return f
	}()

	static func count(_ n: UInt64) -> String { counter.string(from: NSNumber(value: n)) ?? "\(n)" }

	static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
		"\(Fmt.count(UInt64(n))) " + (n == 1 ? one : many ?? one + "s")
	}

	private static func dates(_ format: String) -> DateFormatter {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_GB")
		f.dateFormat = format
		return f
	}
	private static let today = dates("'today,' HH:mm")
	private static let thisYear = dates("d MMM")
	private static let anyYear = dates("d MMM yyyy")
	private static let clock = dates("HH:mm")

	static func date(_ seconds: Int64) -> String {
		let d = Date(timeIntervalSince1970: TimeInterval(seconds))
		if Calendar.current.isDateInToday(d) { return today.string(from: d) }
		if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) { return thisYear.string(from: d) }
		return anyYear.string(from: d)
	}

	static func when(_ d: Date) -> String {
		let cal = Calendar.current
		if cal.isDateInToday(d) { return "today " + clock.string(from: d) }
		if cal.isDateInYesterday(d) { return "yesterday " + clock.string(from: d) }
		return thisYear.string(from: d) + " " + clock.string(from: d)
	}

	static func duration(_ seconds: Double) -> String {
		if seconds < 50 { return "under a minute" }
		if seconds < 3600 { return "about \(Int((seconds / 60).rounded())) min" }
		return String(format: "about %.1f h", seconds / 3600)
	}

	static func home(_ path: String) -> String {
		let h = NSHomeDirectory()
		return path == h ? "~" : path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
	}
}

enum Explain {
	static func known(_ name: String) -> String? {
		if name.hasPrefix("._") && name.count > 2 { return "Finder’s extra data for “\(name.dropFirst(2))” on a non-Mac disk" }
		switch name {
		case ".DS_Store": return "Finder’s view settings for this folder (icon places, sorting) — a few KB, made again if removed"
		case ".localized": return "Tells Finder to show this folder’s name in your language"
		case "Icon\r": return "This folder’s custom icon"
		case ".Spotlight-V100": return "Spotlight’s search index of this disk"
		case ".fseventsd": return "macOS’s log of file changes on this disk (Time Machine and apps use it)"
		case ".Trashes": return "The Trash of this disk"
		case ".Trash": return "Your Trash"
		case ".DocumentRevisions-V100": return "Older versions of documents (File › Revert To)"
		case ".TemporaryItems": return "Temporary files apps keep while saving"
		case ".apdisk": return "Network-disk settings (AirPort, Time Capsule)"
		case ".VolumeIcon.icns": return "This disk’s icon"
		case ".com.apple.timemachine.donotpresent": return "Marks a disk Time Machine should not offer"
		case ".PKInstallSandboxManager", ".PKInstallSandboxManager-SystemSoftware": return "Leftovers of macOS installers"
		case ".MobileBackups": return "Time Machine’s local copies"
		case ".vol": return "A macOS system link"
		case ".file": return "A macOS system placeholder"
		case ".hotfiles.btree": return "macOS’s list of often-used files (old disks)"
		case ".journal", ".journal_info_block": return "The file system’s journal"
		default: return nil
		}
	}
}

enum Fit {
	typealias Attrs = [NSAttributedString.Key: Any]

	static func width(_ s: String, _ a: Attrs) -> CGFloat { NSAttributedString(string: s, attributes: a).size().width }

	static func middle(_ s: String, _ a: Attrs, _ room: CGFloat) -> NSAttributedString {
		let whole = NSAttributedString(string: s, attributes: a)
		guard whole.size().width > room, s.count > 2 else { return whole }
		let chars = Array(s)
		var lo = 1, hi = chars.count - 1
		var best = NSAttributedString(string: "…", attributes: a)
		while lo <= hi {
			let k = (lo + hi) / 2
			let head = Int((Double(k) * 0.45).rounded(.up))
			let tail = k - head
			let str = String(chars[0..<head]).trimmingCharacters(in: .whitespaces) + "…"
				+ String(chars[(chars.count - tail)...]).trimmingCharacters(in: .whitespaces)
			let t = NSAttributedString(string: str, attributes: a)
			if t.size().width <= room { best = t; lo = k + 1 } else { hi = k - 1 }
		}
		return best
	}

	static func tail(_ s: String, _ a: Attrs, _ room: CGFloat) -> NSAttributedString {
		let whole = NSAttributedString(string: s, attributes: a)
		guard whole.size().width > room, s.count > 1 else { return whole }
		let chars = Array(s)
		var lo = 1, hi = chars.count - 1
		var best = NSAttributedString(string: "…", attributes: a)
		while lo <= hi {
			let k = (lo + hi) / 2
			let t = NSAttributedString(string: String(chars[0..<k]).trimmingCharacters(in: .whitespaces) + "…", attributes: a)
			if t.size().width <= room { best = t; lo = k + 1 } else { hi = k - 1 }
		}
		return best
	}

	static func lines(_ s: String, _ a: Attrs, rooms: [CGFloat]) -> [NSAttributedString] {
		let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !s.isEmpty, let first = rooms.first else { return [] }
		if width(s, a) <= first { return [NSAttributedString(string: s, attributes: a)] }
		let words = s.split(separator: " ").map(String.init)
		let isPath = s.hasPrefix("/") || s.hasPrefix("~")
		guard rooms.count > 1, words.count > 1, !isPath, width(words[0], a) <= first else { return [middle(s, a, first)] }
		var out: [NSAttributedString] = []
		var rest = words[...]
		for (k, room) in rooms.enumerated() {
			guard !rest.isEmpty else { break }
			if k == rooms.count - 1 {
				out.append(tail(rest.joined(separator: " "), a, room))
				rest = []
				break
			}
			var line = rest.first!
			rest = rest.dropFirst()
			if width(line, a) > room {
				out.append(middle(([line] + rest).joined(separator: " "), a, room))
				rest = []
				break
			}
			while let w = rest.first, width(line + " " + w, a) <= room {
				line += " " + w
				rest = rest.dropFirst()
			}
			out.append(NSAttributedString(string: line, attributes: a))
		}
		return out
	}
}
