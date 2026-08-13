import Foundation

enum SpotifydSupervisorError: LocalizedError, Sendable, Equatable {
    case notInstalled
    case invalidExecutable(String)
    case busy
    case authenticationRequired
    case configuration(String)
    case launch(String)
    case authenticationFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "spotifyd was not found. Install it with `brew install spotifyd` or choose the executable in Settings."
        case .invalidExecutable(let path):
            "The selected spotifyd executable is not runnable: \(path)"
        case .busy:
            "spotifyd is already running or authenticating."
        case .authenticationRequired:
            "Authenticate the local receiver in Settings before playing music."
        case .configuration(let message):
            "Could not prepare spotifyd: \(message)"
        case .launch(let message):
            "Could not launch spotifyd: \(message)"
        case .authenticationFailed(let status):
            "spotifyd authentication exited with status \(status)."
        }
    }
}

actor SpotifydSupervisor: SpotifydManaging {
    private enum OutputSource: String {
        case standardOutput = "stdout"
        case standardError = "stderr"
    }

    private struct RunningChild {
        let identifier: UUID
        let process: Process
        let standardOutput: Pipe
        let standardError: Pipe
        let isAuthentication: Bool
    }

    private let eventBus = SpotifydEventBus()
    private var configuration: SpotifydSupervisorConfiguration
    private var discoveredExecutableURL: URL?
    private var child: RunningChild?
    private var outputBuffers: [OutputSource: Data] = [:]
    private var logTail: [String] = []
    private var stopWasRequested = false
    private var audioOutputObservationTask: Task<Void, Never>?
    private let defaultAudioOutputChanges: @Sendable () -> AsyncStream<Void>

    nonisolated var events: AsyncStream<SpotifydEvent> { eventBus.stream() }

    init(
        configuration: SpotifydSupervisorConfiguration = .init(),
        defaultAudioOutputChanges: @escaping @Sendable () -> AsyncStream<Void> = {
            SpotifydAudioOutput.defaultDeviceChanges()
        }
    ) {
        self.configuration = configuration
        self.defaultAudioOutputChanges = defaultAudioOutputChanges
    }

    func setUserSelectedExecutableURL(_ url: URL?) {
        configuration.userSelectedExecutableURL = url
        discoveredExecutableURL = nil
    }

    func configuredDeviceName() -> String { configuration.deviceName }

    func recentLogLines() -> [String] { logTail }

    func inspectInstallation() async -> SpotifydInstallation {
        let candidates = [
            configuration.userSelectedExecutableURL,
            URL(fileURLWithPath: "/opt/homebrew/bin/spotifyd"),
            URL(fileURLWithPath: "/usr/local/bin/spotifyd")
        ].compactMap { $0 }

        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            do {
                let result = try runShortCommand(executable: candidate, arguments: ["--version"])
                guard result.status == 0 else { continue }
                let version = firstNonemptyLine(in: result.output)
                discoveredExecutableURL = candidate
                if child?.process.isRunning != true {
                    let state: SpotifydState = credentialsLikelyExist() ? .stopped : .needsAuthentication
                    eventBus.send(.stateChanged(state))
                }
                return SpotifydInstallation(executableURL: candidate, version: version)
            } catch {
                continue
            }
        }

        discoveredExecutableURL = nil
        eventBus.send(.stateChanged(.notInstalled))
        return SpotifydInstallation(executableURL: nil, version: nil)
    }

    func authenticate() async throws {
        if child?.process.isRunning == true {
            guard child?.isAuthentication != true else { throw SpotifydSupervisorError.busy }
            await stop()
        }
        let executable = try await requireExecutable()
        try prepareApplicationSupport()

        let help = (try? runShortCommand(executable: executable, arguments: ["--help"]).output) ?? ""
        let subcommand = authenticationSubcommand(from: help)
        appendLog("Starting spotifyd \(subcommand) flow")
        let launched = try launch(
            executable: executable,
            arguments: [subcommand, "--config-path", configuration.configFile.path],
            isAuthentication: true
        )
        child = launched
        stopWasRequested = false

        while launched.process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        flushOutputBuffers(for: launched.identifier)
        let status = launched.process.terminationStatus
        clearHandlers(on: launched)
        if child?.identifier == launched.identifier { child = nil }

        guard status == 0 else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SpotifydSupervisorError.authenticationFailed(status: status)
        }
        guard credentialsLikelyExist() else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SpotifydSupervisorError.authenticationFailed(status: status)
        }
        eventBus.send(.stateChanged(.stopped))
    }

    func start() async throws {
        if let child, child.process.isRunning {
            if child.isAuthentication { throw SpotifydSupervisorError.busy }
            return
        }

        let executable = try await requireExecutable()
        try prepareApplicationSupport()
        guard credentialsLikelyExist() else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SpotifydSupervisorError.authenticationRequired
        }
        stopWasRequested = false
        eventBus.send(.stateChanged(.starting))

        do {
            let launched = try launch(
                executable: executable,
                arguments: ["--no-daemon", "--config-path", configuration.configFile.path],
                isAuthentication: false
            )
            child = launched
            observeDefaultAudioOutput()
            eventBus.send(.stateChanged(.running(processID: launched.process.processIdentifier)))
        } catch {
            eventBus.send(.stateChanged(.crashed(status: -1)))
            throw error
        }
    }

    func stop() async {
        stopObservingDefaultAudioOutput()
        guard let running = child else {
            eventBus.send(.stateChanged(.stopped))
            return
        }

        stopWasRequested = true
        if running.process.isRunning {
            running.process.terminate()
            await waitForExit(of: running.process, for: configuration.gracefulStopDelay)
        }
        if running.process.isRunning {
            // Process.interrupt targets this Process object's PID; never signal by daemon name.
            running.process.interrupt()
            await waitForExit(of: running.process, for: .seconds(1))
        }

        flushOutputBuffers(for: running.identifier)
        clearHandlers(on: running)
        if child?.identifier == running.identifier { child = nil }
        eventBus.send(.stateChanged(.stopped))
    }

    private func requireExecutable() async throws -> URL {
        if let discoveredExecutableURL,
           FileManager.default.isExecutableFile(atPath: discoveredExecutableURL.path) {
            return discoveredExecutableURL
        }
        let installation = await inspectInstallation()
        guard let executable = installation.executableURL else {
            throw SpotifydSupervisorError.notInstalled
        }
        return executable
    }

    private func prepareApplicationSupport() throws {
        do {
            try createPrivateDirectory(configuration.applicationSupportDirectory)
            try createPrivateDirectory(configuration.cacheDirectory)
            try createPrivateDirectory(configuration.logDirectory)
            let contents = SpotifydConfigurationFile.render(
                deviceName: configuration.deviceName,
                cacheDirectory: configuration.cacheDirectory,
                maxCacheSizeBytes: configuration.maxCacheSizeBytes
            )
            try Data(contents.utf8).write(to: configuration.configFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.configFile.path)
        } catch {
            throw SpotifydSupervisorError.configuration(safeDescription(of: error))
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func launch(executable: URL, arguments: [String], isAuthentication: Bool) throws -> RunningChild {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SpotifydSupervisorError.invalidExecutable(executable.path)
        }

        let identifier = UUID()
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.currentDirectoryURL = configuration.applicationSupportDirectory

        installReadHandler(on: standardOutput, source: .standardOutput, childIdentifier: identifier)
        installReadHandler(on: standardError, source: .standardError, childIdentifier: identifier)
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { await self?.childDidExit(identifier: identifier, status: status) }
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw SpotifydSupervisorError.launch(safeDescription(of: error))
        }

        return RunningChild(
            identifier: identifier,
            process: process,
            standardOutput: standardOutput,
            standardError: standardError,
            isAuthentication: isAuthentication
        )
    }

    private func installReadHandler(on pipe: Pipe, source: OutputSource, childIdentifier: UUID) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data, from: source, childIdentifier: childIdentifier) }
        }
    }

    private func receive(_ data: Data, from source: OutputSource, childIdentifier: UUID) {
        guard child?.identifier == childIdentifier || child == nil else { return }
        if data.isEmpty {
            flushBuffer(source)
            return
        }
        outputBuffers[source, default: Data()].append(data)
        drainCompleteLines(source)
    }

    private func drainCompleteLines(_ source: OutputSource) {
        var buffer = outputBuffers[source, default: Data()]
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            appendLog("[\(source.rawValue)] \(String(decoding: lineData, as: UTF8.self))")
        }
        if buffer.count > 16_384 {
            appendLog("[\(source.rawValue)] \(String(decoding: buffer.prefix(16_384), as: UTF8.self))")
            buffer.removeAll(keepingCapacity: true)
        }
        outputBuffers[source] = buffer
    }

    private func flushBuffer(_ source: OutputSource) {
        let data = outputBuffers.removeValue(forKey: source) ?? Data()
        guard !data.isEmpty else { return }
        appendLog("[\(source.rawValue)] \(String(decoding: data, as: UTF8.self))")
    }

    private func flushOutputBuffers(for identifier: UUID) {
        guard child?.identifier == identifier || child == nil else { return }
        flushBuffer(.standardOutput)
        flushBuffer(.standardError)
    }

    private func appendLog(_ unsafeLine: String) {
        let line = Self.redact(unsafeLine)
        logTail.append(line)
        if logTail.count > configuration.logTailLineLimit {
            logTail.removeFirst(logTail.count - configuration.logTailLineLimit)
        }
        eventBus.send(.log(line))
        if !stopWasRequested,
           child?.isAuthentication != true,
           Self.isConnectionInterruption(line) {
            eventBus.send(.connectionInterrupted(restartReceiver: true))
        }
        appendToRotatingLog(line)
    }

    static func isConnectionInterruption(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("unexpected shutdown")
            || line.localizedCaseInsensitiveContains("connection to server closed")
    }

    private func appendToRotatingLog(_ line: String) {
        let logURL = configuration.logDirectory.appendingPathComponent("spotifyd.log")
        let oldURL = configuration.logDirectory.appendingPathComponent("spotifyd.log.1")
        let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? NSNumber)?.intValue ?? 0
        if size >= configuration.logFileMaxBytes {
            try? FileManager.default.removeItem(at: oldURL)
            try? FileManager.default.moveItem(at: logURL, to: oldURL)
        }

        let timestampedLine = "[\(Date().ISO8601Format())] \(line)"
        let data = Data((timestampedLine + "\n").utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never destabilize playback.
        }
    }

    private func childDidExit(identifier: UUID, status: Int32) {
        guard let running = child, running.identifier == identifier else { return }
        stopObservingDefaultAudioOutput()
        flushOutputBuffers(for: identifier)
        clearHandlers(on: running)
        child = nil
        if !stopWasRequested, !running.isAuthentication {
            eventBus.send(.connectionInterrupted(restartReceiver: false))
        }
        eventBus.send(.exited(status: status))
        if stopWasRequested {
            eventBus.send(.stateChanged(.stopped))
        } else if running.isAuthentication {
            eventBus.send(.stateChanged(status == 0 ? .stopped : .needsAuthentication))
        } else {
            eventBus.send(.stateChanged(.crashed(status: status)))
        }
    }

    private func clearHandlers(on child: RunningChild) {
        child.standardOutput.fileHandleForReading.readabilityHandler = nil
        child.standardError.fileHandleForReading.readabilityHandler = nil
        child.process.terminationHandler = nil
    }

    private func observeDefaultAudioOutput() {
        guard audioOutputObservationTask == nil else { return }
        let changes = defaultAudioOutputChanges()
        audioOutputObservationTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.defaultAudioOutputDidChange()
            }
        }
    }

    private func stopObservingDefaultAudioOutput() {
        audioOutputObservationTask?.cancel()
        audioOutputObservationTask = nil
    }

    private func defaultAudioOutputDidChange() async {
        guard let running = child,
              running.process.isRunning,
              !running.isAuthentication else { return }

        // This method runs on the observation task. Detach it before stopping so stop() does
        // not cancel the task while it is waiting for the receiver process to exit.
        let previousObservationTask = audioOutputObservationTask
        audioOutputObservationTask = nil
        defer { previousObservationTask?.cancel() }

        appendLog("macOS default audio output changed; restarting receiver")
        await stop()
        do {
            try await start()
            eventBus.send(.connectionInterrupted(restartReceiver: false))
        } catch {
            appendLog("Could not restart receiver after audio output change: \(safeDescription(of: error))")
        }
    }

    private func waitForExit(of process: Process, for duration: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while process.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func credentialsLikelyExist() -> Bool {
        let candidates = [
            configuration.cacheDirectory.appendingPathComponent("credentials.json"),
            configuration.cacheDirectory.appendingPathComponent("oauth/credentials.json")
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func authenticationSubcommand(from help: String) -> String {
        let lowered = help.lowercased()
        if lowered.range(of: #"(?m)^\s*authenticate(?:\s|$)"#, options: .regularExpression) != nil {
            return "authenticate"
        }
        return "auth"
    }

    private func runShortCommand(executable: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, Self.redact(String(decoding: data.prefix(64_000), as: UTF8.self)))
        } catch {
            throw SpotifydSupervisorError.launch(safeDescription(of: error))
        }
    }

    private func firstNonemptyLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func safeDescription(of error: Error) -> String {
        Self.redact((error as NSError).localizedDescription)
    }

    static func redact(_ value: String) -> String {
        var redacted = String(value.prefix(4_096))
        let querySecret = #"(?i)(access_token|refresh_token|code|state|password|username)=([^&\s]+)"#
        redacted = redacted.replacingOccurrences(
            of: querySecret,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*"#,
            with: "Bearer <redacted>",
            options: .regularExpression
        )
        return redacted
    }
}
