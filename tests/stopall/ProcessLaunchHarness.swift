import Foundation

@main
struct ProcessLaunchHarness {
    static func main() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["1"]

        var observedRunningProcess = false
        try launchProcess(process) {
            observedRunningProcess = process.isRunning
        }

        guard observedRunningProcess else {
            fputs("playback-start callback must run after launch and before completion\n", stderr)
            exit(1)
        }

        process.terminate()
        process.waitUntilExit()
        print("process launch harness: PASS")
    }
}
