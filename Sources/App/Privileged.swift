import Darwin
import Foundation
import Security
import Synchronization

enum Privileged {
	private static let service = "com.ilya.betterfinder.admin"
	private static let hello = Data("BFH1\n".utf8)

	static func savedPassword() -> String? {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName(), kSecReturnData as String: true,
		                        kSecMatchLimit as String: kSecMatchLimitOne]
		var out: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
		return String(data: d, encoding: .utf8)
	}

	static var hasPassword: Bool {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName()]
		return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
	}

	static func save(_ password: String) -> Bool {
		forget()
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName(), kSecValueData as String: Data(password.utf8),
		                        kSecAttrLabel as String: "Better Finder — reads closed system folders"]
		return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
	}

	static func forget() {
		let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
		                        kSecAttrAccount as String: NSUserName()]
		SecItemDelete(q as CFDictionary)
	}

	static func check(_ password: String) -> Bool {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
		p.arguments = ["-k", "-S", "-p", "", "/usr/bin/true"]
		let input = Pipe()
		p.standardInput = input
		p.standardOutput = FileHandle.nullDevice
		p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { return false }
		input.fileHandleForWriting.write(Data((password + "\n").utf8))
		try? input.fileHandleForWriting.close()
		p.waitUntilExit()
		return p.terminationStatus == 0
	}

	enum Outcome {
		case walks([String: VolumeScan])
		case wrongPassword
		case failed
	}

	static func walk(_ paths: [String], password: String?, asUser: Bool = false) -> Outcome {
		let paths = paths.filter { $0.hasPrefix("/") && !$0.contains("\n") }
		guard !paths.isEmpty else { return .walks([:]) }
		guard let me = Bundle.main.executablePath else { return .failed }
		if !asUser {
			guard let password else { return .failed }
			guard check(password) else { return .wrongPassword }
		}
		let p = Process()
		if asUser {
			p.executableURL = URL(fileURLWithPath: me)
			p.arguments = ["helper", "--as-user"]
		} else {
			p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
			p.arguments = ["-k", "-S", "-p", "", me, "helper"]
		}
		let input = Pipe(), output = Pipe()
		p.standardInput = input
		p.standardOutput = output
		p.standardError = FileHandle.nullDevice
		do { try p.run() } catch { return .failed }
		let w = input.fileHandleForWriting, r = output.fileHandleForReading
		let answered = Atomic<Bool>(false)
		DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
			if !answered.load(ordering: .relaxed) && p.isRunning { p.terminate() }
		}
		if !asUser, let password { w.write(Data((password + "\n").utf8)) }
		guard read(r, hello.count) == hello else {
			try? w.close()
			if p.isRunning { p.terminate() }
			p.waitUntilExit()
			return .failed
		}
		answered.store(true, ordering: .relaxed)
		let writer = Thread {
			w.write(Data(("\(marker)\n" + paths.joined(separator: "\n") + "\n").utf8))
			try? w.close()
		}
		writer.start()
		var out: [String: VolumeScan] = [:]
		var complete = true
		for _ in paths {
			guard let head = read(r, 8), head.count == 8 else { complete = false; break }
			let n = head.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
			guard n < 1 << 32, let body = read(r, Int(n)), body.count == Int(n) else { complete = false; break }
			if let root = Store.root(of: body), paths.contains(root),
			   let (scan, _) = Store.decode(body, root: root, dev: 0, views: []) {
				out[root] = scan
			}
		}
		if !complete && p.isRunning { p.terminate() }
		try? r.close()
		p.waitUntilExit()
		return .walks(out)
	}

	private static let marker = "BFPATHS"

	private static func read(_ h: FileHandle, _ n: Int) -> Data? {
		var d = Data()
		while d.count < n {
			guard let chunk = try? h.read(upToCount: n - d.count), !chunk.isEmpty else { return d.isEmpty ? nil : d }
			d.append(chunk)
		}
		return d
	}

	static func helper(asUser: Bool = false) -> Int32 {
		guard geteuid() == 0 || asUser else { return 1 }
		let out = FileHandle.standardOutput
		out.write(hello)
		while let line = readLine(strippingNewline: true), line != marker {}
		while let path = readLine(strippingNewline: true) {
			guard path.hasPrefix("/") else { continue }
			var frame = Data()
			if path.hasPrefix("/"), let scan = try? VolumeScan(root: path) {
				scan.run(threads: 8)
				frame = Store.encode(scan, Store.Header(root: path, eventsUUID: "", lastEvent: 0, stamp: "", date: Date()))
			} else {
				let empty = VolumeScan(root: path, dev: 0, views: [])
				frame = Store.encode(empty, Store.Header(root: path, eventsUUID: "", lastEvent: 0, stamp: "", date: Date()))
			}
			var n = UInt64(frame.count).littleEndian
			out.write(Data(bytes: &n, count: 8))
			out.write(frame)
		}
		return 0
	}
}
