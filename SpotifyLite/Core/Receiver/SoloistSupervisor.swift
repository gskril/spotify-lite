import Foundation

enum SoloistSupervisorError: LocalizedError, Sendable, Equatable {
    case notInstalled
    case invalidExecutable(String)
    case busy
    case apiKeyRequired
    case authenticationRequired
    case buildExpired
    case configuration(String)
    case launch(String)
    case authenticationFailed(status: Int32)
    case pairingTimedOut

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Spotify Soloist was not found. Download it from Spotify, place it where Settings shows, then choose Recheck."
        case .invalidExecutable(let path):
            "The Soloist executable is not runnable: \(path)"
        case .busy:
            "Soloist is already running or pairing."
        case .apiKeyRequired:
            "Add your Spotify Soloist API key in Settings before playing music."
        case .authenticationRequired:
            "Pair the local receiver in Settings before playing music."
        case .buildExpired:
            "This Soloist build has expired. Download the current build from Spotify and replace the old one."
        case .configuration(let message):
            "Could not prepare Soloist: \(message)"
        case .launch(let message):
            "Could not launch Soloist: \(message)"
        case .authenticationFailed(let status):
            "Soloist pairing exited with status \(status)."
        case .pairingTimedOut:
            "Pairing timed out. Open Spotify on this network, choose this Mac's Spotify Lite device, and try again."
        }
    }
}

actor SoloistSupervisor: ReceiverManaging {
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

    private let eventBus = BroadcastStream<ReceiverEvent>(bufferSize: 256)
    private var configuration: SoloistSupervisorConfiguration
    private var discoveredExecutableURL: URL?
    private var child: RunningChild?
    private var outputBuffers: [OutputSource: Data] = [:]
    private var logTail: [String] = []
    private var stopWasRequested = false
    private var keepAliveRequested = false
    private var keepAliveRestartTask: Task<Void, Never>?
    private var audioOutputObservationTask: Task<Void, Never>?
    private var pairingAdvertisement: Process?
    private let apiKey: @Sendable () async -> String?
    private let defaultAudioOutputChanges: @Sendable () -> AsyncStream<Void>

    nonisolated var events: AsyncStream<ReceiverEvent> { eventBus.stream() }

    init(
        configuration: SoloistSupervisorConfiguration = .init(),
        apiKey: @escaping @Sendable () async -> String? = { SoloistAPIKeyStore.load() },
        defaultAudioOutputChanges: @escaping @Sendable () -> AsyncStream<Void> = {
            ReceiverAudioOutput.defaultDeviceChanges()
        }
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.defaultAudioOutputChanges = defaultAudioOutputChanges
    }

    func recentLogLines() -> [String] { logTail }

    func inspectInstallation() async -> ReceiverInstallation {
        let candidates = [
            configuration.userSelectedExecutableURL,
            configuration.installDirectory.appendingPathComponent("soloist"),
            URL(fileURLWithPath: "/opt/homebrew/bin/soloist"),
            URL(fileURLWithPath: "/usr/local/bin/soloist")
        ].compactMap { $0 }

        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            do {
                let result = try runShortCommand(executable: candidate, arguments: ["--version"])
                guard result.status == 0 else { continue }
                let version = firstNonemptyLine(in: result.output)
                discoveredExecutableURL = candidate
                if child?.process.isRunning != true {
                    let state: ReceiverState = sessionLikelyExists() ? .stopped : .needsAuthentication
                    eventBus.send(.stateChanged(state))
                }
                return ReceiverInstallation(
                    executableURL: candidate,
                    version: version,
                    buildExpiry: version.flatMap(Self.buildExpiry(fromVersionLine:))
                )
            } catch {
                continue
            }
        }

        discoveredExecutableURL = nil
        eventBus.send(.stateChanged(.notInstalled))
        return ReceiverInstallation(executableURL: nil, version: nil)
    }

    /// Pairs through Spotify Connect: Soloist waits until the user picks this device in a
    /// Spotify app on the local network, stores the session, and exits.
    func authenticate() async throws {
        if child?.process.isRunning == true {
            guard child?.isAuthentication != true else { throw SoloistSupervisorError.busy }
            await stop()
        }
        let executable = try await requireExecutable()
        try prepareApplicationSupport()
        let key = try await requireAPIKey()

        appendLog("Starting Soloist pairing")
        // Verbose output is the only place Soloist reports its pairing port. It also names
        // the account, so pairing output is scanned for that port and never stored.
        let launched = try launch(
            executable: executable,
            arguments: baseArguments(apiKey: key) + ["--pair", "--verbose"],
            isAuthentication: true
        )
        child = launched
        stopWasRequested = false
        defer { stopPairingAdvertisement() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: configuration.pairingTimeout)
        var timedOut = false
        while launched.process.isRunning {
            if Task.isCancelled || clock.now >= deadline {
                timedOut = !Task.isCancelled
                launched.process.terminate()
                await waitForExit(of: launched.process, for: configuration.gracefulStopDelay)
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let status = launched.process.terminationStatus
        clearHandlers(on: launched)
        outputBuffers.removeAll()
        if child?.identifier == launched.identifier { child = nil }

        if timedOut {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SoloistSupervisorError.pairingTimedOut
        }
        try Task.checkCancellation()
        if status == SoloistSupervisorConfiguration.expiredBuildExitStatus {
            eventBus.send(.stateChanged(.crashed(status: status)))
            throw SoloistSupervisorError.buildExpired
        }
        guard status == 0, sessionLikelyExists() else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SoloistSupervisorError.authenticationFailed(status: status)
        }
        appendLog("Soloist pairing completed")
        eventBus.send(.stateChanged(.stopped))
    }

    func start() async throws {
        if let child, child.process.isRunning {
            if child.isAuthentication { throw SoloistSupervisorError.busy }
            return
        }

        let executable = try await requireExecutable()
        do {
            try prepareApplicationSupport()
        } catch {
            eventBus.send(.stateChanged(.crashed(status: -1)))
            throw error
        }
        guard let key = await apiKey() else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SoloistSupervisorError.apiKeyRequired
        }
        guard sessionLikelyExists() else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SoloistSupervisorError.authenticationRequired
        }
        // Another caller may have launched the receiver while the key was being read.
        if let child, child.process.isRunning {
            if child.isAuthentication { throw SoloistSupervisorError.busy }
            return
        }
        stopWasRequested = false
        eventBus.send(.stateChanged(.starting))

        do {
            let launched = try launch(
                executable: executable,
                arguments: baseArguments(apiKey: key),
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

    func startKeepingAlive() async throws {
        keepAliveRequested = true
        try await start()
    }

    func stopKeepingAlive() async {
        keepAliveRequested = false
        keepAliveRestartTask?.cancel()
        keepAliveRestartTask = nil
        await stop()
    }

    func stop() async {
        stopPairingAdvertisement()
        stopObservingDefaultAudioOutput()
        guard let running = child else {
            eventBus.send(.stateChanged(.stopped))
            return
        }

        DiagnosticLog.shared.record("receiver.stop_requested")
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
            throw SoloistSupervisorError.notInstalled
        }
        return executable
    }

    private func requireAPIKey() async throws -> String {
        guard let key = await apiKey() else {
            eventBus.send(.stateChanged(.needsAuthentication))
            throw SoloistSupervisorError.apiKeyRequired
        }
        return key
    }

    /// Soloist accepts the API key only as an argument, so it is visible to other processes
    /// of this user while the receiver runs. It is never logged.
    private func baseArguments(apiKey: String) -> [String] {
        [
            "--device-name", configuration.deviceName,
            "--api-key", apiKey,
            "--data-dir", configuration.dataDirectory.path,
            "--cache-dir", configuration.cacheDirectory.path,
            "--cache-size", String(configuration.maxCacheSizeMB),
            "--initial-volume", String(SoloistSupervisorConfiguration.rememberedVolume)
        ]
    }

    private func prepareApplicationSupport() throws {
        do {
            try createPrivateDirectory(configuration.applicationSupportDirectory)
            try createPrivateDirectory(configuration.cacheDirectory)
            try createPrivateDirectory(configuration.logDirectory)
            try createPrivateDirectory(configuration.dataDirectory)
        } catch {
            throw SoloistSupervisorError.configuration(safeDescription(of: error))
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
            throw SoloistSupervisorError.invalidExecutable(executable.path)
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
            DiagnosticLog.shared.record("receiver.started", ["pid": String(process.processIdentifier)])
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw SoloistSupervisorError.launch(safeDescription(of: error))
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
            handleOutputLine(String(decoding: lineData, as: UTF8.self), from: source)
        }
        if buffer.count > 16_384 {
            handleOutputLine(String(decoding: buffer.prefix(16_384), as: UTF8.self), from: source)
            buffer.removeAll(keepingCapacity: true)
        }
        outputBuffers[source] = buffer
    }

    private func flushBuffer(_ source: OutputSource) {
        let data = outputBuffers.removeValue(forKey: source) ?? Data()
        guard !data.isEmpty else { return }
        handleOutputLine(String(decoding: data, as: UTF8.self), from: source)
    }

    private func handleOutputLine(_ line: String, from source: OutputSource) {
        guard child?.isAuthentication == true else {
            appendLog("[\(source.rawValue)] \(line)")
            return
        }
        if pairingAdvertisement == nil, let endpoint = Self.pairingEndpoint(in: line) {
            startPairingAdvertisement(port: endpoint.port, path: endpoint.path)
        }
    }

    /// Soloist's verbose log line announcing its Spotify Connect pairing endpoint.
    nonisolated static func pairingEndpoint(in line: String) -> (port: Int, path: String)? {
        guard let match = line.firstMatch(of: /Started ZeroConf service on port (\d+) path (\/[A-Za-z0-9_\/-]*)/),
              let port = Int(match.1), (1...65_535).contains(port) else { return nil }
        return (port, String(match.2))
    }

    /// Soloist reports its build date as `(yyyyMMdd)` in `--version`; builds stop working
    /// `buildLifetimeDays` later.
    nonisolated static func buildExpiry(fromVersionLine line: String) -> Date? {
        guard let match = line.firstMatch(of: /\((\d{4})(\d{2})(\d{2})\)/) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = DateComponents(year: Int(match.1), month: Int(match.2), day: Int(match.3))
        guard let built = calendar.date(from: components) else { return nil }
        return calendar.date(byAdding: .day, value: SoloistSupervisorConfiguration.buildLifetimeDays, to: built)
    }

    /// Advertises the pairing endpoint through the system Bonjour service. Soloist's own
    /// multicast announcement does not reliably reach the network from a child process.
    private func startPairingAdvertisement(port: Int, path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        process.arguments = [
            "-R", configuration.deviceName, "_spotify-connect._tcp", "local.", String(port),
            "CPath=\(path)", "VERSION=1.0", "Stack=SP"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            pairingAdvertisement = process
            appendLog("Advertising Soloist pairing on the local network")
        } catch {
            appendLog("Could not advertise Soloist pairing: \(safeDescription(of: error))")
        }
    }

    private func stopPairingAdvertisement() {
        if pairingAdvertisement?.isRunning == true { pairingAdvertisement?.terminate() }
        pairingAdvertisement = nil
    }

    private func flushOutputBuffers(for identifier: UUID) {
        guard child?.identifier == identifier || child == nil else { return }
        flushBuffer(.standardOutput)
        flushBuffer(.standardError)
    }

    private func appendLog(_ unsafeLine: String) {
        // Strip terminal color codes; they are noise in files and the UI.
        let line = Redaction.redact(unsafeLine)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        DiagnosticLog.shared.record("receiver.log", ["message": line])
        logTail.append(line)
        if logTail.count > configuration.logTailLineLimit {
            logTail.removeFirst(logTail.count - configuration.logTailLineLimit)
        }
        eventBus.send(.log(line))
        if !stopWasRequested, child?.isAuthentication == false, line.contains("waiting for login") {
            // The stored session is gone or was rejected; only pairing again can fix that.
            Task { [weak self] in await self?.storedSessionWasRejected() }
        }
        appendToRotatingLog(line)
    }

    private func storedSessionWasRejected() async {
        guard child?.isAuthentication == false else { return }
        keepAliveRestartTask?.cancel()
        keepAliveRestartTask = nil
        await stop()
        eventBus.send(.stateChanged(.needsAuthentication))
    }

    private func appendToRotatingLog(_ line: String) {
        let logURL = configuration.logDirectory.appendingPathComponent("soloist.log")
        let oldURL = configuration.logDirectory.appendingPathComponent("soloist.log.1")
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
        DiagnosticLog.shared.record("receiver.exited", ["status": String(status), "requested": String(stopWasRequested)])
        stopObservingDefaultAudioOutput()
        flushOutputBuffers(for: identifier)
        clearHandlers(on: running)
        child = nil
        let expired = status == SoloistSupervisorConfiguration.expiredBuildExitStatus
        if expired { appendLog("Soloist build has expired; a newer build must be installed") }
        if !stopWasRequested, !running.isAuthentication, !expired {
            eventBus.send(.connectionInterrupted(restartReceiver: false))
            scheduleKeepAliveRestart()
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

    private func scheduleKeepAliveRestart() {
        guard keepAliveRequested, keepAliveRestartTask == nil else { return }
        let delay = configuration.keepAliveRestartDelay
        keepAliveRestartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.performKeepAliveRestart()
        }
    }

    private func performKeepAliveRestart() async {
        keepAliveRestartTask = nil
        guard keepAliveRequested else { return }
        do {
            try await start()
        } catch {
            appendLog("Could not keep receiver running: \(safeDescription(of: error))")
        }
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

    /// Soloist writes per-user settings once a Connect session has been stored.
    private func sessionLikelyExists() -> Bool {
        let users = configuration.dataDirectory.appendingPathComponent("settings/Users", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        return !entries.isEmpty
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
            return (process.terminationStatus, Redaction.redact(String(decoding: data.prefix(64_000), as: UTF8.self)))
        } catch {
            throw SoloistSupervisorError.launch(safeDescription(of: error))
        }
    }

    private func firstNonemptyLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private func safeDescription(of error: Error) -> String {
        Redaction.redact((error as NSError).localizedDescription)
    }
}
