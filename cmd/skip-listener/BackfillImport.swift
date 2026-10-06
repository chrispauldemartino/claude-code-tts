import Foundation
import CryptoKit

func backfillOrderingTime(answeredAt: TimeInterval?, legacyTimestamp: TimeInterval) -> TimeInterval {
    answeredAt ?? legacyTimestamp
}

func backfillRetentionTime(importedAt: TimeInterval?, legacyTimestamp: TimeInterval) -> TimeInterval {
    importedAt ?? legacyTimestamp
}

func normalizedBackfillHashText(_ text: String) -> String {
    let normalized = text.precomposedStringWithCanonicalMapping
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    return normalized
        .components(separatedBy: "\n")
        .map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func backfillContentHash(_ text: String) -> String {
    SHA256.hash(data: Data(normalizedBackfillHashText(text).utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

struct BackfillDedupIndex {
    private var keys = Set<String>()

    mutating func insert(source: String, sessionID: String, contentHash: String) {
        keys.insert(source + "\u{0}" + sessionID + "\u{0}" + contentHash)
    }

    func contains(source: String, sessionID: String, contentHash: String) -> Bool {
        keys.contains(source + "\u{0}" + sessionID + "\u{0}" + contentHash)
    }
}

struct BackfillBatchManifest: Decodable {
    let batchID: String
    let itemCount: Int
    let source: String
    let sessionID: String
    let skipped: Int?

    enum CodingKeys: String, CodingKey {
        case batchID = "batch_id"
        case itemCount = "item_count"
        case source
        case sessionID = "session_id"
        case skipped
    }
}

struct BackfillItemMetadata: Decodable {
    let schemaVersion: Int?
    let origin: String
    let autoplay: Bool
    let batchID: String
    let batchIndex: Int
    let turnID: String?
    let answeredAt: TimeInterval?
    let importedAt: TimeInterval?
    let contentHash: String?
    let normalizationVersion: Int?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case origin, autoplay
        case batchID = "batch_id"
        case batchIndex = "batch_index"
        case turnID = "turn_id"
        case answeredAt = "answered_at"
        case importedAt = "imported_at"
        case contentHash = "content_hash"
        case normalizationVersion = "normalization_version"
    }
}

struct BackfillImportItem {
    let speechText: String
    let fullText: String
    let source: String
    let sessionID: String
    let sessionName: String?
    let metadata: BackfillItemMetadata

    var autoplay: Bool { metadata.autoplay }
}

struct BackfillImportBatch {
    let id: String
    let directory: URL
    let manifest: BackfillBatchManifest
    let items: [BackfillImportItem]
}

struct BackfillCommitResult {
    let imported: Int
    let skipped: Int
    let dupes: Int
}

private func backfillRead(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeBackfillBatch(at directory: URL) -> BackfillImportBatch? {
    let decoder = JSONDecoder()
    guard let manifestData = try? Data(contentsOf: directory.appendingPathComponent("batch.json")),
          let manifest = try? decoder.decode(BackfillBatchManifest.self, from: manifestData),
          manifest.batchID == directory.lastPathComponent,
          manifest.itemCount >= 0 else { return nil }

    var items: [BackfillImportItem] = []
    for index in 0..<manifest.itemCount {
        let prefix = String(format: "%03d", index)
        guard let speech = backfillRead(directory.appendingPathComponent("\(prefix).txt")), !speech.isEmpty,
              let full = backfillRead(directory.appendingPathComponent("\(prefix).full.txt")), !full.isEmpty,
              let source = backfillRead(directory.appendingPathComponent("\(prefix).source")),
              let sessionID = backfillRead(directory.appendingPathComponent("\(prefix).session")),
              let metadataData = try? Data(contentsOf: directory.appendingPathComponent("\(prefix).meta.json")),
              let metadata = try? decoder.decode(BackfillItemMetadata.self, from: metadataData),
              metadata.origin == "backfill", metadata.autoplay == false,
              metadata.batchID == manifest.batchID, metadata.batchIndex == index else { return nil }
        items.append(BackfillImportItem(
            speechText: speech,
            fullText: full,
            source: source,
            sessionID: sessionID,
            sessionName: backfillRead(directory.appendingPathComponent("\(prefix).session_name")),
            metadata: metadata
        ))
    }
    return BackfillImportBatch(id: manifest.batchID, directory: directory, manifest: manifest, items: items)
}

private func writeBackfillAcknowledgement(
    batchID: String,
    at acknowledgementURL: URL,
    status: String,
    result: BackfillCommitResult
) {
    try? FileManager.default.createDirectory(at: acknowledgementURL, withIntermediateDirectories: true)
    let value: [String: Any] = [
        "batch_id": batchID, "status": status, "imported": result.imported,
        "skipped": result.skipped, "dupes": result.dupes,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    try? data.write(to: acknowledgementURL.appendingPathComponent("\(batchID).imported"), options: .atomic)
}

func importBackfillBatches(
    inboxURL: URL,
    acknowledgementURL: URL,
    isGenerationCurrent: (UInt64) -> Bool,
    commit: (BackfillImportBatch, UInt64) -> BackfillCommitResult?
) {
    let fm = FileManager.default
    try? fm.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    let directories = ((try? fm.contentsOfDirectory(
        at: inboxURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }

    for directory in directories {
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        let batchID = directory.lastPathComponent
        let generation = UInt64(backfillRead(directory.appendingPathComponent(".generation")) ?? "") ?? 0
        guard isGenerationCurrent(generation) else {
            writeBackfillAcknowledgement(
                batchID: batchID, at: acknowledgementURL, status: "stale",
                result: BackfillCommitResult(imported: 0, skipped: 0, dupes: 0)
            )
            try? fm.removeItem(at: directory)
            continue
        }
        guard let batch = decodeBackfillBatch(at: directory) else {
            writeBackfillAcknowledgement(
                batchID: batchID, at: acknowledgementURL, status: "invalid",
                result: BackfillCommitResult(imported: 0, skipped: 1, dupes: 0)
            )
            try? fm.removeItem(at: directory)
            continue
        }
        guard let result = commit(batch, generation), isGenerationCurrent(generation) else {
            writeBackfillAcknowledgement(
                batchID: batchID, at: acknowledgementURL, status: "stale",
                result: BackfillCommitResult(imported: 0, skipped: batch.items.count, dupes: 0)
            )
            try? fm.removeItem(at: directory)
            continue
        }
        writeBackfillAcknowledgement(batchID: batch.id, at: acknowledgementURL, status: "imported", result: result)
        try? fm.removeItem(at: directory)
    }
}
