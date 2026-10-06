import Foundation

func pluginBinDirectory(executablePath: String = CommandLine.arguments[0]) -> String {
    let executableURL = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
    let appExecutableMarker = ".app/Contents/MacOS/"
    if let markerRange = executableURL.path.range(of: appExecutableMarker, options: .backwards) {
        let appPath = String(executableURL.path[..<markerRange.lowerBound]) + ".app"
        return URL(fileURLWithPath: appPath).deletingLastPathComponent().path
    }
    return executableURL.deletingLastPathComponent().path
}

func pluginToolPath(
    _ toolName: String,
    executablePath: String = CommandLine.arguments[0]
) -> String {
    URL(fileURLWithPath: pluginBinDirectory(executablePath: executablePath))
        .appendingPathComponent(toolName)
        .path
}

private struct StopAllQueueCandidate {
    let url: URL
    let modificationDate: Date
}

@discardableResult
func archiveQueueEntryThenRemove(
    _ entryURL: URL,
    archive: (URL) -> String?
) -> String? {
    guard let itemID = archive(entryURL) else { return nil }
    try? FileManager.default.removeItem(at: entryURL)
    return itemID
}

@discardableResult
func archiveStopAllQueueEntries(
    in directories: [URL],
    discardStaging: Bool = false,
    archive: (URL) -> String?
) -> [String] {
    let fm = FileManager.default
    var candidates: [StopAllQueueCandidate] = []

    for directory in directories {
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { continue }

        for entry in entries where entry.lastPathComponent.hasPrefix("entry-") {
            guard let values = try? entry.resourceValues(
                forKeys: [.isDirectoryKey, .contentModificationDateKey]
            ), values.isDirectory == true else { continue }
            candidates.append(
                StopAllQueueCandidate(
                    url: entry,
                    modificationDate: values.contentModificationDate ?? .distantPast
                )
            )
        }
    }

    candidates.sort {
        if $0.modificationDate != $1.modificationDate {
            return $0.modificationDate < $1.modificationDate
        }
        return $0.url.path < $1.url.path
    }

    var archivedIDs: [String] = []
    for candidate in candidates {
        guard let itemID = archiveQueueEntryThenRemove(candidate.url, archive: archive) else { continue }
        archivedIDs.append(itemID)
    }

    if discardStaging {
        for directory in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasPrefix(".entry-") && name.hasSuffix(".tmp") {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }

    return archivedIDs
}

func playbackLogTargetIndex(
    itemCount: Int,
    currentIndex: Int,
    direction: String?
) -> Int? {
    guard itemCount > 0 else { return nil }
    let current = min(max(currentIndex, 0), itemCount - 1)
    switch direction {
    case "next":
        return current < itemCount - 1 ? current + 1 : nil
    case "prev":
        return current > 0 ? current - 1 : nil
    default:
        return current
    }
}

func stopAllCursorItemID(
    archivedIDs: [String],
    manifestLatestID: String?
) -> String? {
    archivedIDs.last ?? manifestLatestID
}
