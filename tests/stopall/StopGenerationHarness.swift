import Foundation

@main
struct StopGenerationHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("stop generation harness: FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-tts-stop-generation-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let stateURL = testRoot.appendingPathComponent("state")
        let store = StopGenerationStore(stateURL: stateURL)
        let initial = store.snapshot()
        require(initial.generation == 0, "new store should start at generation zero")
        require(store.isCurrent(initial), "initial snapshot should be current")

        let stopped = store.advance(timestamp: 1_234.5)
        require(stopped.generation == 1, "first stop should advance generation")
        require(stopped.timestamp == 1_234.5, "stop timestamp should be recorded")
        let persistedState = try String(contentsOf: stateURL, encoding: .utf8)
        require(
            persistedState.contains("timestamp_ns=1234500000000"),
            "stop state should include an epoch-nanosecond bridge boundary"
        )
        require(!store.isCurrent(initial), "a stop should invalidate older workers")
        require(store.isCurrent(stopped), "new stop snapshot should be current")
        require(store.isAutoplayHeld(), "stop should enable autoplay hold")
        require(
            store.queueDisposition(modificationTime: 1_234.4, archiveOnly: false) == .archive,
            "pre-stop entries should archive without autoplay"
        )
        require(store.isAutoplayHeld(), "archiving old work should keep the hold")
        require(
            store.queueDisposition(modificationTime: 1_234.6, archiveOnly: true) == .archive,
            "bridge-invalidated imports should archive even when published later"
        )
        require(
            store.queueDisposition(modificationTime: 1_234.6, archiveOnly: false) == .play,
            "a genuinely new entry should clear the hold and autoplay"
        )
        require(!store.isAutoplayHeld(), "new entry should persistently clear the hold")

        _ = store.advance(timestamp: 1_500)
        store.clearAutoplayHold()
        require(
            store.queueDisposition(modificationTime: 1_400, archiveOnly: false) == .play,
            "an explicit operator action should clear the hold"
        )

        let operatorResumed = store.snapshot()
        let reloaded = StopGenerationStore(stateURL: stateURL)
        require(reloaded.snapshot() == operatorResumed, "generation, timestamp, and hold should survive restart")
        require(!reloaded.isAutoplayHeld(), "cleared hold should survive restart")

        let unwritableStateURL = testRoot.appendingPathComponent("state-is-a-directory")
        try FileManager.default.createDirectory(at: unwritableStateURL, withIntermediateDirectories: true)
        let failedStore = StopGenerationStore(stateURL: unwritableStateURL)
        _ = failedStore.advance(timestamp: 1_750)
        require(!failedStore.isPersistenceHealthy(), "failed persistence must be observable")
        require(failedStore.isAutoplayHeld(), "failed persistence must retain a fail-closed hold")
        require(
            failedStore.queueDisposition(modificationTime: 1_800, archiveOnly: false) == .archive,
            "failed persistence must never release a new entry to autoplay"
        )
        require(
            FileManager.default.fileExists(atPath: unwritableStateURL.path + ".failed"),
            "failed persistence must create a bridge-visible fail-closed marker"
        )

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stop-generation-test", attributes: .concurrent)
        for offset in 1...50 {
            group.enter()
            queue.async {
                _ = store.advance(timestamp: 2_000 + Double(offset))
                group.leave()
            }
        }
        group.wait()
        require(store.snapshot().generation == 52, "concurrent stops must not lose increments")

        print("stop generation harness: PASS")
    }
}
