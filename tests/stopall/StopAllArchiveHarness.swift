import Foundation

@main
struct StopAllArchiveHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("stop archive harness: FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-tts-stop-archive-test-\(UUID().uuidString)")
        let queue = root.appendingPathComponent("queue")
        let deferred = root.appendingPathComponent("deferred")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deferred, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        require(
            pluginBinDirectory(
                executablePath: "/plugins/claude-code-tts/bin/SkipListener.app/Contents/MacOS/skip-listener"
            ) == "/plugins/claude-code-tts/bin",
            "app-bundle tools must resolve from the plugin bin directory"
        )
        require(
            pluginToolPath(
                "stopall-drain.sh",
                executablePath: "/plugins/claude-code-tts/bin/SkipListener.app/Contents/MacOS/skip-listener"
            ) == "/plugins/claude-code-tts/bin/stopall-drain.sh",
            "stop-all drain must resolve beside speak-text in bin"
        )

        let fixtures: [(URL, String, TimeInterval)] = [
            (queue.appendingPathComponent("entry-new"), "new", 300),
            (deferred.appendingPathComponent("entry-old"), "old", 100),
            (queue.appendingPathComponent("entry-middle"), "middle", 200),
        ]
        for (url, text, timestamp) in fixtures {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try text.write(to: url.appendingPathComponent("text"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: timestamp)],
                ofItemAtPath: url.path
            )
        }
        let staging = queue.appendingPathComponent(".entry-incomplete.tmp")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var log: [(id: String, text: String, state: String)] = []
        let archivedIDs = archiveStopAllQueueEntries(
            in: [queue, deferred],
            discardStaging: true
        ) { entry in
            let text = try? String(contentsOf: entry.appendingPathComponent("text"), encoding: .utf8)
            guard let text else { return nil }
            let id = "item-\(log.count + 1)"
            log.append((id: id, text: text, state: "skipped"))
            return id
        }

        require(log.map(\.text) == ["old", "middle", "new"], "entries must archive in arrival order")
        require(log.allSatisfy { $0.state == "skipped" }, "archived entries must be marked skipped")
        require(archivedIDs == ["item-1", "item-2", "item-3"], "archive IDs should preserve order")
        require(
            stopAllCursorItemID(archivedIDs: archivedIDs, manifestLatestID: "item-active") == "item-3",
            "the newest archived entry must win over a later-timestamped active manifest item"
        )
        require(fixtures.allSatisfy { !FileManager.default.fileExists(atPath: $0.0.path) }, "archived queue entries should be drained")
        require(!FileManager.default.fileExists(atPath: staging.path), "incomplete staging should be discarded")

        let skippedEntry = queue.appendingPathComponent("entry-ordinary-skip")
        try FileManager.default.createDirectory(at: skippedEntry, withIntermediateDirectories: true)
        try "ordinary skip".write(
            to: skippedEntry.appendingPathComponent("text"),
            atomically: true,
            encoding: .utf8
        )
        var ordinarySkipState: String?
        let ordinarySkipID = archiveQueueEntryThenRemove(skippedEntry) { entry in
            ordinarySkipState = "skipped"
            return FileManager.default.fileExists(atPath: entry.path) ? "item-skip" : nil
        }
        require(ordinarySkipID == "item-skip", "ordinary skip should return its playback-log item")
        require(ordinarySkipState == "skipped", "ordinary skip should archive with skipped state")
        require(
            !FileManager.default.fileExists(atPath: skippedEntry.path),
            "ordinary skip should remove an entry only after archival"
        )

        let failedArchiveEntry = queue.appendingPathComponent("entry-failed-archive")
        try FileManager.default.createDirectory(at: failedArchiveEntry, withIntermediateDirectories: true)
        let failedArchiveID = archiveQueueEntryThenRemove(failedArchiveEntry) { _ in nil }
        require(failedArchiveID == nil, "failed archival should report no playback-log item")
        require(
            FileManager.default.fileExists(atPath: failedArchiveEntry.path),
            "an entry must remain queued when archival fails"
        )

        var cursor = log.count - 1
        require(cursor == 2, "stop should position the cursor at the newest archived item")
        cursor = playbackLogTargetIndex(itemCount: log.count, currentIndex: cursor, direction: "prev")!
        require(log[cursor].text == "middle", "previous should reach the next older unplayed item")
        cursor = playbackLogTargetIndex(itemCount: log.count, currentIndex: cursor, direction: "prev")!
        require(log[cursor].text == "old", "previous should reach the oldest unplayed item")
        cursor = playbackLogTargetIndex(itemCount: log.count, currentIndex: cursor, direction: "next")!
        require(log[cursor].text == "middle", "next should navigate forward through archived items")

        print("stop archive harness: PASS")
    }
}
