import Foundation
import Network

enum OAuthCallbackListenerError: Error, Sendable, Equatable, LocalizedError {
    case failedToStart(String)
    case stoppedBeforeCallback
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .failedToStart(let detail):
            return "Could not start the local Spotify sign-in callback: \(detail)"
        case .stoppedBeforeCallback:
            return "The local Spotify sign-in callback was stopped."
        case .invalidRequest:
            return "The local Spotify sign-in callback was invalid."
        }
    }
}

final class OAuthCallbackReceiver: @unchecked Sendable {
    let redirectURI: URL
    private let waitOperation: @Sendable () async throws -> URL
    private let cancelOperation: @Sendable () -> Void

    init(
        redirectURI: URL,
        wait: @escaping @Sendable () async throws -> URL,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.redirectURI = redirectURI
        self.waitOperation = wait
        self.cancelOperation = cancel
    }

    func waitForCallback() async throws -> URL {
        try await waitOperation()
    }

    func cancel() {
        cancelOperation()
    }
}

protocol OAuthCallbackListening: Sendable {
    func start(callbackPath: String) async throws -> OAuthCallbackReceiver
}

struct LoopbackOAuthCallbackListener: OAuthCallbackListening {
    private let port: NWEndpoint.Port

    init(port: UInt16 = 43_821) {
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    func start(callbackPath: String) async throws -> OAuthCallbackReceiver {
        let normalizedPath = callbackPath.hasPrefix("/") ? callbackPath : "/\(callbackPath)"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw OAuthCallbackListenerError.failedToStart(error.localizedDescription)
        }

        let coordinator = LoopbackCallbackCoordinator(listener: listener, callbackPath: normalizedPath)
        listener.stateUpdateHandler = { state in
            coordinator.handleListenerState(state)
        }
        listener.newConnectionHandler = { connection in
            coordinator.handle(connection: connection)
        }
        listener.start(queue: coordinator.queue)

        let port = try await coordinator.waitUntilReady()
        guard let redirectURI = URL(string: "http://127.0.0.1:\(port)\(normalizedPath)") else {
            coordinator.cancel()
            throw OAuthCallbackListenerError.failedToStart("Could not create the redirect URL.")
        }

        return OAuthCallbackReceiver(
            redirectURI: redirectURI,
            wait: { try await coordinator.waitForCallback() },
            cancel: { coordinator.cancel() }
        )
    }
}

private final class LoopbackCallbackCoordinator: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.spotifylite.SpotifyLite.oauth-callback")

    private let listener: NWListener
    private let callbackPath: String
    private let lock = NSLock()
    private var readyResult: Result<UInt16, Error>?
    private var readyWaiters: [CheckedContinuation<UInt16, Error>] = []
    private var callbackResult: Result<URL, Error>?
    private var callbackWaiters: [CheckedContinuation<URL, Error>] = []
    private var hasFinished = false

    init(listener: NWListener, callbackPath: String) {
        self.listener = listener
        self.callbackPath = callbackPath
    }

    func waitUntilReady() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let readyResult {
                lock.unlock()
                continuation.resume(with: readyResult)
            } else {
                readyWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func waitForCallback() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let callbackResult {
                    lock.unlock()
                    continuation.resume(with: callbackResult)
                } else {
                    callbackWaiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let rawPort = listener.port?.rawValue else {
                fail(OAuthCallbackListenerError.failedToStart("No loopback port was assigned."))
                return
            }
            resolveReady(.success(rawPort))
        case .failed(let error):
            fail(OAuthCallbackListenerError.failedToStart(error.localizedDescription))
        case .cancelled:
            failIfNeeded(OAuthCallbackListenerError.stoppedBeforeCallback)
        default:
            break
        }
    }

    func handle(connection: NWConnection) {
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        HTTPCallbackConnection(
            connection: connection,
            queue: queue,
            expectedPath: callbackPath,
            completion: { [weak self] result in self?.handleRequest(result, connection: connection) }
        ).start()
    }

    func cancel() {
        failIfNeeded(OAuthCallbackListenerError.stoppedBeforeCallback)
        listener.cancel()
    }

    private func handleRequest(_ result: Result<URL, Error>, connection: NWConnection) {
        switch result {
        case .success(let url):
            let body = """
            <!doctype html><html><head><meta charset="utf-8"><title>Spotify Lite</title></head>
            <body><p>Authorization received. You can close this window and return to Spotify Lite.</p></body></html>
            """
            send(status: "200 OK", body: body, connection: connection) { [weak self] in
                self?.succeed(url)
            }
        case .failure:
            send(status: "400 Bad Request", body: "Invalid authorization callback.", connection: connection)
        }
    }

    private func send(
        status: String,
        body: String,
        connection: NWConnection,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    private func succeed(_ url: URL) {
        finishCallback(.success(url))
        listener.cancel()
    }

    private func fail(_ error: Error) {
        resolveReady(.failure(error))
        failIfNeeded(error)
        listener.cancel()
    }

    private func failIfNeeded(_ error: Error) {
        finishCallback(.failure(error))
    }

    private func resolveReady(_ result: Result<UInt16, Error>) {
        lock.lock()
        guard readyResult == nil else {
            lock.unlock()
            return
        }
        readyResult = result
        let waiters = readyWaiters
        readyWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        callbackResult = result
        let waiters = callbackWaiters
        callbackWaiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(with: result) }
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host)
        return value == "127.0.0.1" || value == "::1" || value == "[::1]"
    }
}

private final class HTTPCallbackConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let expectedPath: String
    private let completion: @Sendable (Result<URL, Error>) -> Void
    private var data = Data()
    private var completed = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        expectedPath: String,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.expectedPath = expectedPath
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(.failure(OAuthCallbackListenerError.invalidRequest)) }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] chunk, _, isComplete, error in
            guard !completed else { return }
            if let chunk { data.append(chunk) }
            if data.count > 65_536 {
                finish(.failure(OAuthCallbackListenerError.invalidRequest))
            } else if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                parseRequest()
            } else if error != nil || isComplete {
                finish(.failure(OAuthCallbackListenerError.invalidRequest))
            } else {
                receive()
            }
        }
    }

    private func parseRequest() {
        guard
            let request = String(data: data, encoding: .utf8),
            let firstLine = request.components(separatedBy: "\r\n").first
        else {
            finish(.failure(OAuthCallbackListenerError.invalidRequest))
            return
        }
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        let headers = request.components(separatedBy: "\r\n").dropFirst()
        let hostHeader = headers.first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst("host:".count)
            .trimmingCharacters(in: .whitespaces)
        guard
            parts.count == 3,
            parts[0] == "GET",
            let hostHeader,
            hostHeader == "127.0.0.1" || hostHeader.hasPrefix("127.0.0.1:"),
            let url = URL(string: "http://\(hostHeader)\(parts[1])"),
            url.path == expectedPath
        else {
            finish(.failure(OAuthCallbackListenerError.invalidRequest))
            return
        }
        finish(.success(url))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        completion(result)
    }
}
