import Foundation

func launchProcess(
    _ process: Process,
    onStarted: (() -> Void)? = nil
) throws {
    try process.run()
    onStarted?()
}
