import AppKit
import Darwin

setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
if args.isEmpty {
	MainActor.assumeIsolated { AppDelegate.run() }
} else if args[0] == "window-check" {
	exit(MainActor.assumeIsolated { WindowCheck.run(args.count > 1 ? args[1] : "shots") })
} else if args[0] == "ring-check" {
	exit(MainActor.assumeIsolated { RingCheck.run(args.count > 1 ? args[1] : "shots") })
} else if args[0] == "shots" {
	exit(MainActor.assumeIsolated { Shots.run(args.count > 1 ? args[1] : "shots") })
} else {
	exit(CLI.run(args))
}
