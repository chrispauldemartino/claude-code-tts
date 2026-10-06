import Foundation

@main
struct BackfillImportHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("backfill import harness: FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func writeBatch(root: URL, id: String, generation: UInt64) throws {
        let batch = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try "\(generation)\n".write(to: batch.appendingPathComponent(".generation"), atomically: true, encoding: .utf8)
        let manifest = "{\"batch_id\":\"\(id)\",\"item_count\":1,\"source\":\"Claude Code\",\"session_id\":\"s1\"}\n"
        try manifest.write(to: batch.appendingPathComponent("batch.json"), atomically: true, encoding: .utf8)
        try "Speech text.".write(to: batch.appendingPathComponent("000.txt"), atomically: true, encoding: .utf8)
        try "Full answer.".write(to: batch.appendingPathComponent("000.full.txt"), atomically: true, encoding: .utf8)
        try "s1".write(to: batch.appendingPathComponent("000.session"), atomically: true, encoding: .utf8)
        try "Claude Code".write(to: batch.appendingPathComponent("000.source"), atomically: true, encoding: .utf8)
        try "main session".write(to: batch.appendingPathComponent("000.session_name"), atomically: true, encoding: .utf8)
        let meta = "{\"schema_version\":1,\"origin\":\"backfill\",\"autoplay\":false,\"batch_id\":\"\(id)\",\"batch_index\":0,\"turn_id\":\"t1\",\"answered_at\":1,\"imported_at\":100,\"content_hash\":\"abc\",\"normalization_version\":1}\n"
        try meta.write(to: batch.appendingPathComponent("000.meta.json"), atomically: true, encoding: .utf8)
    }

    static func main() throws {
        require(backfillOrderingTime(answeredAt: 10, legacyTimestamp: 500) == 10, "answered time controls ordering")
        require(backfillRetentionTime(importedAt: 500, legacyTimestamp: 10) == 500, "import time controls retention")
        require(backfillOrderingTime(answeredAt: nil, legacyTimestamp: 42) == 42, "legacy manifest ordering fallback")
        require(backfillRetentionTime(importedAt: nil, legacyTimestamp: 42) == 42, "legacy manifest retention fallback")
        require(backfillContentHash("Full answer.\r\n") == "3c684d54c904e0b9919edfec4471025f04a79c4d97d2c36299f64089a8753050", "compatible normalized SHA-256")
        var dedup = BackfillDedupIndex()
        dedup.insert(source: "Claude Code", sessionID: "s1", contentHash: "abc")
        require(dedup.contains(source: "Claude Code", sessionID: "s1", contentHash: "abc"), "repeat import is a duplicate")
        require(!dedup.contains(source: "Claude Code", sessionID: "s2", contentHash: "abc"), "dedup remains session-scoped")

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("backfill-import-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("inbox")
        let acks = root.appendingPathComponent("acks")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try writeBatch(root: inbox, id: "accepted", generation: 7)
        var committed = 0
        importBackfillBatches(inboxURL: inbox, acknowledgementURL: acks, isGenerationCurrent: { $0 == 7 }) { batch, generation in
            committed += 1
            require(generation == 7, "commit receives captured generation")
            require(batch.items.count == 1, "one item decoded")
            require(batch.items[0].autoplay == false, "backfill is never autoplay")
            require(batch.items[0].speechText == "Speech text.", "speech text decoded")
            return BackfillCommitResult(imported: 1, skipped: 0, dupes: 0)
        }
        require(committed == 1, "fresh batch committed once")
        require(FileManager.default.fileExists(atPath: acks.appendingPathComponent("accepted.imported").path), "durable ack emitted")
        require(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("accepted").path), "committed inbox removed")

        try writeBatch(root: inbox, id: "stale", generation: 6)
        importBackfillBatches(inboxURL: inbox, acknowledgementURL: acks, isGenerationCurrent: { $0 == 7 }) { _, _ in
            committed += 1
            return BackfillCommitResult(imported: 1, skipped: 0, dupes: 0)
        }
        require(committed == 1, "stale work never reaches commit or synthesis boundary")
        let staleAck = try String(contentsOf: acks.appendingPathComponent("stale.imported"), encoding: .utf8)
        require(staleAck.contains("\"status\":\"stale\""), "stale status acknowledged")
        print("backfill import harness: PASS")
    }
}
