import Foundation

/// Runs `herdr-core events --json` and hands each line it prints to `onLine`, on the main
/// thread. Herdbar only ever reads from Herdr; this is the one command it runs.
@MainActor
final class HerdrProcess {
    nonisolated static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/herdr-core").path

    var onLine: ((String) -> Void)?
    /// Called when the command ends or cannot start, with a reason to show.
    var onStop: ((String) -> Void)?

    private var process: Process?
    private var buffer = Data()
    /// Counts launches, so output from a stopped run is ignored.
    private var generation = 0

    func start(path: String = HerdrProcess.defaultPath) {
        stop()
        generation += 1
        let run = generation
        guard FileManager.default.isExecutableFile(atPath: path) else {
            onStop?("Herdr's command-line tool was not found at \(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["events", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data, run: run) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == run else { return }
                    self.process = nil
                    self.onStop?("Herdr is not running, or its connection closed.")
                }
            }
        }
        do {
            try process.run()
            self.process = process
            buffer = Data()
        } catch {
            onStop?("Could not start Herdr's command-line tool: \(error.localizedDescription)")
        }
    }

    func stop() {
        generation += 1
        if let process, process.isRunning {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            process.terminate()
        }
        process = nil
        buffer = Data()
    }

    private func receive(_ data: Data, run: Int) {
        guard run == generation else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                onLine?(text)
            }
        }
    }
}
