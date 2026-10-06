import Foundation

struct StopGenerationSnapshot: Equatable {
    let generation: UInt64
    let timestamp: TimeInterval
    let autoplayHold: Bool
}

enum QueueAutoplayDisposition: Equatable {
    case archive
    case play
}

final class StopGenerationStore {
    private let lock = NSLock()
    private let stateURL: URL
    private let failureURL: URL
    private var state: StopGenerationSnapshot
    private var persistenceFailed: Bool

    init(stateURL: URL) {
        self.stateURL = stateURL
        self.failureURL = URL(fileURLWithPath: stateURL.path + ".failed")
        let loadedState = Self.readState(from: stateURL)
        if FileManager.default.fileExists(atPath: failureURL.path) {
            let failureDate = (try? failureURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? loadedState.timestamp
            self.state = StopGenerationSnapshot(
                generation: loadedState.generation + 1,
                timestamp: failureDate,
                autoplayHold: true
            )
            self.persistenceFailed = true
        } else {
            self.state = loadedState
            self.persistenceFailed = false
        }
    }

    func snapshot() -> StopGenerationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func advance(timestamp: TimeInterval = Date().timeIntervalSince1970) -> StopGenerationSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let next = StopGenerationSnapshot(
            generation: state.generation + 1,
            timestamp: timestamp,
            autoplayHold: true
        )
        if persist(next) {
            persistenceFailed = false
            try? FileManager.default.removeItem(at: failureURL)
        } else {
            persistenceFailed = true
            markPersistenceFailure(snapshot: next)
        }
        state = next
        return state
    }

    func isCurrent(_ snapshot: StopGenerationSnapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.generation == state.generation
    }

    func performIfCurrent(
        _ snapshot: StopGenerationSnapshot,
        _ operation: () throws -> Void
    ) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.generation == state.generation else { return false }
        try operation()
        return true
    }

    func valueIfCurrent<T>(
        _ snapshot: StopGenerationSnapshot,
        _ operation: () -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.generation == state.generation else { return nil }
        return operation()
    }

    func hasRecordedStop() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.generation > 0
    }

    func isAutoplayHeld() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.autoplayHold
    }

    func isPersistenceHealthy() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !persistenceFailed
    }

    func clearAutoplayHold() {
        lock.lock()
        defer { lock.unlock() }
        guard state.autoplayHold else { return }
        let resumed = StopGenerationSnapshot(
            generation: state.generation,
            timestamp: state.timestamp,
            autoplayHold: false
        )
        guard persist(resumed) else {
            persistenceFailed = true
            markPersistenceFailure(snapshot: state)
            return
        }
        state = resumed
        persistenceFailed = false
        try? FileManager.default.removeItem(at: failureURL)
    }

    func queueDisposition(
        modificationTime: TimeInterval,
        archiveOnly: Bool
    ) -> QueueAutoplayDisposition {
        lock.lock()
        defer { lock.unlock() }

        if archiveOnly {
            return .archive
        }
        if persistenceFailed {
            return .archive
        }
        guard state.autoplayHold else {
            return .play
        }
        guard modificationTime > state.timestamp else {
            return .archive
        }

        // The first eligible post-stop entry automatically ends the hold. It is
        // persisted here so subsequent queue entries can autoplay normally.
        let resumed = StopGenerationSnapshot(
            generation: state.generation,
            timestamp: state.timestamp,
            autoplayHold: false
        )
        guard persist(resumed) else {
            persistenceFailed = true
            markPersistenceFailure(snapshot: state)
            return .archive
        }
        state = resumed
        persistenceFailed = false
        try? FileManager.default.removeItem(at: failureURL)
        return .play
    }

    private func persist(_ snapshot: StopGenerationSnapshot) -> Bool {
        let timestampNanoseconds = UInt64(max(0, snapshot.timestamp) * 1_000_000_000)
        let contents = "generation=\(snapshot.generation)\ntimestamp=\(snapshot.timestamp)\ntimestamp_ns=\(timestampNanoseconds)\nautoplay_hold=\(snapshot.autoplayHold ? 1 : 0)\n"
        do {
            try contents.write(to: stateURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            fputs("stop generation persistence failed: \(error)\n", stderr)
            return false
        }
    }

    private func markPersistenceFailure(snapshot: StopGenerationSnapshot) {
        let contents = "timestamp=\(snapshot.timestamp)\n"
        try? contents.write(to: failureURL, atomically: true, encoding: .utf8)
    }

    private static func readState(from url: URL) -> StopGenerationSnapshot {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return StopGenerationSnapshot(generation: 0, timestamp: 0, autoplayHold: false)
        }

        var generation: UInt64 = 0
        var timestamp: TimeInterval = 0
        var autoplayHold = false
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            if fields[0] == "generation" {
                generation = UInt64(fields[1]) ?? 0
            } else if fields[0] == "timestamp" {
                timestamp = TimeInterval(fields[1]) ?? 0
            } else if fields[0] == "autoplay_hold" {
                autoplayHold = fields[1] == "1"
            }
        }
        return StopGenerationSnapshot(
            generation: generation,
            timestamp: timestamp,
            autoplayHold: autoplayHold
        )
    }
}
