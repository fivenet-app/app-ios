import Foundation
import SwiftProtobuf

/// gRPC-over-WebSocket channel ("grpcws") used by the FiveNet web client.
///
/// Replicates `app/composables/grpcws` from the FiveNet repository:
/// - Single binary WebSocket connection to `<base>/api/grpcws` with the
///   `grpc-websocket-channel` subprotocol.
/// - Control stream (id 0) for the `auth`/`reauth` handshake.
/// - Data streams multiplexed over the connection (max 7 concurrent), each
///   identified by a `Header` frame whose `operation` is `Service/Method`.
/// - gRPC length-prefixed message framing inside `Body` frames.
actor FiveNetChannel {
    private let baseURL: URL
    private let session: URLSession
    private let maxStreams = 7

    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectInFlight: Task<Void, Error>?

    private var streams: [UInt32: StreamBox] = [:]
    private var availableStreamIDs: Set<UInt32> = Set(1...7)

    private var authToken: String?
    private var accountToken: String?
    private var isAuthenticated = false
    private var pendingAuth: AuthHandshake?
    private var isConnected = false

    /// Whether the channel should automatically re-establish the websocket when
    /// it drops. Disabled by an explicit `disconnect()`.
    private var shouldAutoReconnect = false

    /// Lock-protected state readable/writable from nonisolated contexts.
    private let state = ConnectionStateBox()

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Connection lifecycle

    nonisolated func setStatusHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        state.lock.lock()
        state.statusHandler = handler
        state.lock.unlock()
    }

    /// Registers a handler invoked when the server rejects the session as
    /// unauthenticated/invalid (auth handshake failure or an Unauthenticated
    /// status on an RPC). The app uses this to auto-logout an expired session.
    nonisolated func setAuthFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        state.lock.lock()
        state.authFailureHandler = handler
        state.lock.unlock()
    }

    nonisolated func connectionState() -> Bool {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.isConnected
    }

    /// Schedules a disconnect on the channel.
    nonisolated func disconnect() {
        Task { await self.disconnectInternal() }
    }

    private func disconnectInternal() {
        shouldAutoReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        forceDisconnect()
    }

    private func updateStatus(_ connected: Bool) {
        isConnected = connected
        state.lock.lock()
        state.isConnected = connected
        let handler = state.statusHandler
        state.lock.unlock()
        handler?(connected)
    }

    /// Invokes the auth-failure handler (if any) without blocking the actor.
    private func notifyAuthFailure() {
        state.lock.lock()
        let handler = state.authFailureHandler
        state.lock.unlock()
        handler?()
    }

    private func isUnauthorizedError(_ error: Error) -> Bool {
        if case FiveNetError.unauthorized = error { return true }
        return false
    }

    /// Connects to the server and performs the control-plane authentication
    /// handshake using the given bearer token.
    ///
    /// - Parameters:
    ///   - userToken: the character user token sent as `Authorization: Bearer`.
    ///   - accountToken: the `fivenet_acc` cookie value required for the upgrade.
    func connect(userToken: String?, accountToken: String?) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        shouldAutoReconnect = true
        authToken = userToken
        self.accountToken = accountToken
        // A concurrent connect may already be mid-handshake (e.g. `ensureChannel`
        // from a view while `restore` is still connecting). Calling
        // `forceDisconnect()` here would kill that in-flight handshake, strand its
        // `authenticate` send-retry loop for 15s, and make `performConnect` below
        // block on `connectInFlight` until it times out — the 14-20s stall. Let the
        // in-flight task finish and reuse it instead.
        if connectInFlight == nil {
            forceDisconnect()
        }
        try await performConnect()
    }

    private func forceDisconnect() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveTask?.cancel(); receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil

        isAuthenticated = false
        pendingAuth?.fail(FiveNetError.cancelled)
        pendingAuth = nil

        let active = Array(streams.values)
        streams.removeAll()
        availableStreamIDs = Set((1...maxStreams).map(UInt32.init))
        for box in active {
            box.fail(FiveNetError.cancelled)
        }
        updateStatus(false)
    }

    /// Re-establishes the websocket connection without tearing down stream state
    /// first. Serialized via `connectInFlight` so a manual reconnect and the
    /// auto-reconnect loop never race.
    private func performConnect() async throws {
        if let inFlight = connectInFlight {
            try? await inFlight.value
            if isConnected, isAuthenticated { return }
        }
        let task = Task { [weak self] in
            guard let self else { throw FiveNetError.notConnected }
            try await self.establishConnection()
        }
        connectInFlight = task
        defer { connectInFlight = nil }
        try await task.value
    }

    private func establishConnection() async throws {
        guard let userToken = authToken else {
            throw FiveNetError.notConnected
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FiveNetError.invalidServerURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "api/grpcws"
        guard let wsURL = components.url else {
            throw FiveNetError.invalidServerURL
        }

        var request = URLRequest(url: wsURL)
        request.setValue(originHeaderValue, forHTTPHeaderField: "Origin")
        request.setValue("grpc-websocket-channel", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let accountToken, !accountToken.isEmpty {
            request.setValue("fivenet_acc=\(accountToken)", forHTTPHeaderField: "Cookie")
        }

        let wsTask = session.webSocketTask(with: request)
        task = wsTask
        wsTask.resume()

        receiveTask = Task { await self.receiveLoop(wsTask) }
        heartbeatTask = Task { await self.heartbeatLoop() }

        do {
            try await authenticate(token: userToken)
            updateStatus(true)
        } catch {
            forceDisconnect()
            throw error
        }
    }

    // MARK: - RPC calls

    /// Performs a unary (or server-streaming-response) call and collects all
    /// response messages.
    func call(operation: String, request: Data?) async throws -> [Data] {
        let box = try makeStream()
        do {
            try await sendStart(box.id, operation: operation, request: request)
        } catch {
            cancelStream(box.id)
            throw error
        }

        var messages: [Data] = []
        do {
            for try await chunk in box.stream {
                messages.append(chunk)
            }
        } catch {
            cancelStream(box.id)
            throw error
        }
        cancelStream(box.id)
        return messages
    }

    /// Opens a server-streaming call. The returned stream yields each message
    /// until the call completes or fails.
    func serverStream(operation: String, request: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        let box = try makeStream()
        do {
            try await sendStart(box.id, operation: operation, request: request)
        } catch {
            cancelStream(box.id)
            throw error
        }
        return box.stream
    }

    // MARK: - Stream management

    private func makeStream() throws -> StreamBox {
        guard isConnected, isAuthenticated else {
            throw FiveNetError.notConnected
        }
        guard let id = availableStreamIDs.min() else {
            throw FiveNetError.maxStreamsReached
        }
        availableStreamIDs.remove(id)

        let box = StreamBox(id: id) { [weak self] in
            Task { await self?.cancelStream(id) }
        }
        streams[id] = box
        return box
    }

    private func cancelStream(_ id: UInt32) {
        guard streams[id] != nil else { return }
        streams.removeValue(forKey: id)
        availableStreamIDs.insert(id)
        Task {
            try? await sendFrame(Resources_Grpcws_GrpcFrame.with {
                $0.streamID = id
                $0.payload = .cancel(Resources_Grpcws_Cancel())
            })
        }
    }

    private func sendStart(_ id: UInt32, operation: String, request: Data?) async throws {
        var header = Resources_Grpcws_Header()
        header.operation = operation
        if let accountToken, !accountToken.isEmpty {
            var cookie = Resources_Grpcws_HeaderValue()
            cookie.value = ["fivenet_acc=\(accountToken)"]
            header.headers["Cookie"] = cookie
        }
        try await sendFrame(Resources_Grpcws_GrpcFrame.with {
            $0.streamID = id
            $0.payload = .header(header)
        })

        var body = Resources_Grpcws_Body()
        if let request {
            body.data = GrpcFramer.frame(request)
        }
        body.complete = true
        try await sendFrame(Resources_Grpcws_GrpcFrame.with {
            $0.streamID = id
            $0.payload = .body(body)
        })
    }

    // MARK: - Auth

    private func authenticate(token: String?) async throws {
        let handshake = AuthHandshake()
        pendingAuth = handshake

        var sent = false
        let deadline = Date().addingTimeInterval(15)
        while !sent && !Task.isCancelled && Date() < deadline {
            do {
                try await sendFrame(makeControlAuthFrame(operation: "auth", token: token))
                sent = true
            } catch {
                if Task.isCancelled {
                    pendingAuth = nil
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        guard sent else {
            pendingAuth = nil
            throw FiveNetError.timeout
        }

        // Wait for the server's auth confirmation, but fail fast instead of
        // hanging forever if the server never answers the handshake.
        do {
            try await authHandshake(withTimeout: 15, handshake: handshake)
        } catch {
            pendingAuth = nil
            throw error
        }
        isAuthenticated = true
    }

    /// Awaits the handshake result, cancelling via a timeout so a silent server
    /// (or a lost websocket without a disconnect frame) cannot block the connect.
    private func authHandshake(withTimeout seconds: TimeInterval, handshake: AuthHandshake) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await handshake.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                throw FiveNetError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw FiveNetError.timeout
            }
            return first
        }
    }

    private func makeControlAuthFrame(operation: String, token: String?) -> Resources_Grpcws_GrpcFrame {
        var header = Resources_Grpcws_Header()
        header.operation = operation
        if let token, !token.isEmpty {
            var value = Resources_Grpcws_HeaderValue()
            value.value = ["Bearer \(token)"]
            header.headers["Authorization"] = value
        }
        return Resources_Grpcws_GrpcFrame.with {
            $0.streamID = 0
            $0.payload = .header(header)
        }
    }

    // MARK: - Receive loop

    private func receiveLoop(_ wsTask: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await wsTask.receive()
                switch message {
                case .data(let data):
                    handleFrame(data)
                case .string(let string):
                    if let data = Data(base64Encoded: string) {
                        handleFrame(data)
                    }
                @unknown default:
                    break
                }
            } catch {
                break
            }
        }
        handleDisconnect()
    }

    private func handleFrame(_ data: Data) {
        guard let frame = try? Resources_Grpcws_GrpcFrame(serializedBytes: data) else { return }
        let id = frame.streamID

        if id == 0 {
            handleControl(frame)
            return
        }

        guard let box = streams[id] else { return }
        switch frame.payload {
        case .header:
            break
        case .body(let body):
            box.yield(body.data)
            if body.complete {
                box.finish()
                streams.removeValue(forKey: id)
                availableStreamIDs.insert(id)
            }
        case .complete:
            box.finish()
            streams.removeValue(forKey: id)
            availableStreamIDs.insert(id)
        case .failure(let failure):
            let error = error(from: failure)
            if isUnauthorizedError(error) {
                notifyAuthFailure()
            }
            box.fail(error)
            streams.removeValue(forKey: id)
            availableStreamIDs.insert(id)
        case .cancel:
            box.fail(FiveNetError.cancelled)
            streams.removeValue(forKey: id)
            availableStreamIDs.insert(id)
        case .ping, nil:
            break
        }
    }

    private func handleControl(_ frame: Resources_Grpcws_GrpcFrame) {
        switch frame.payload {
        case .header(let header):
            if header.operation == "auth_ok" {
                pendingAuth?.succeed()
            } else {
                notifyAuthFailure()
                pendingAuth?.fail(FiveNetError.unauthorized)
            }
            pendingAuth = nil
        case .failure(let failure):
            notifyAuthFailure()
            pendingAuth?.fail(FiveNetError.loginFailed(failure.errorMessage))
            pendingAuth = nil
        case .ping(let ping):
            if !ping.pong {
                Task { try? await self.sendFrame(self.pongFrame) }
            }
        default:
            break
        }
    }

    private func handleDisconnect() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveTask = nil
        task = nil
        isAuthenticated = false
        pendingAuth?.fail(FiveNetError.connectionClosed)
        pendingAuth = nil

        let active = Array(streams.values)
        streams.removeAll()
        availableStreamIDs = Set((1...maxStreams).map(UInt32.init))
        for box in active {
            box.fail(FiveNetError.connectionClosed)
        }
        updateStatus(false)

        scheduleReconnectIfNeeded()
    }

    /// Reconnects with exponential backoff after an unexpected websocket drop.
    /// The auth tokens are kept across drops so the same character session can
    /// be re-established without a user action.
    private func scheduleReconnectIfNeeded() {
        guard shouldAutoReconnect, authToken != nil else { return }
        reconnectTask?.cancel()
            reconnectTask = Task { [weak self] in
                var attempt = 0
                while !Task.isCancelled {
                    let delay = min(0.5 * pow(2, Double(attempt)), 15)
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled, await self.shouldAutoReconnect else { return }
                    do {
                        try await self.performConnect()
                        return
                    } catch {
                        // Don't retry authentication failures forever — the session
                        // is invalid and needs a fresh login.
                        if case FiveNetError.unauthorized = error { return }
                        if case FiveNetError.loginFailed = error { return }
                        attempt += 1
                    }
                }
            }
    }

    // MARK: - Heartbeat

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard isConnected else { continue }
            try? await sendFrame(pingFrame)
        }
    }

    // MARK: - Sending

    private func sendFrame(_ frame: Resources_Grpcws_GrpcFrame) async throws {
        guard let task else { throw FiveNetError.notConnected }
        let data = try frame.serializedData()
        try await task.send(.data(data))
    }

    private var pingFrame: Resources_Grpcws_GrpcFrame {
        Resources_Grpcws_GrpcFrame.with {
            $0.streamID = 0
            $0.payload = .ping(Resources_Grpcws_Ping.with { $0.pong = false })
        }
    }

    private var pongFrame: Resources_Grpcws_GrpcFrame {
        Resources_Grpcws_GrpcFrame.with {
            $0.streamID = 0
            $0.payload = .ping(Resources_Grpcws_Ping.with { $0.pong = true })
        }
    }

    /// The server rejects websocket upgrades whose `Origin` host does not match
    /// the request host.
    private var originHeaderValue: String {
        var origin = baseURL.scheme ?? "https"
        origin += "://"
        origin += baseURL.host ?? ""
        if let port = baseURL.port {
            origin += ":\(port)"
        }
        return origin
    }

    private func error(from failure: Resources_Grpcws_Failure) -> Error {
        if failure.errorStatus == "Unauthenticated" || failure.errorStatus == "Unauthorized" {
            return FiveNetError.unauthorized
        }
        let message = failure.errorMessage.isEmpty ? "Unknown gRPC error" : failure.errorMessage
        return FiveNetError.grpcStatus(code: -1, message: message)
    }
}

/// Lock-protected connection state shared between actor-isolated and
/// nonisolated contexts.
private final class ConnectionStateBox: @unchecked Sendable {
    let lock = NSLock()
    var isConnected = false
    var statusHandler: (@Sendable (Bool) -> Void)?
    var authFailureHandler: (@Sendable () -> Void)?
}

/// Per-stream message channel backed by an `AsyncThrowingStream`.
private final class StreamBox: @unchecked Sendable {
    let id: UInt32
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    let stream: AsyncThrowingStream<Data, Error>

    init(id: UInt32, onCancel: @escaping @Sendable () -> Void) {
        self.id = id
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { c in
            cont = c
            c.onTermination = { _ in onCancel() }
        }
        self.continuation = cont
    }

    func yield(_ data: Data) {
        continuation.yield(data)
    }

    func finish() {
        continuation.finish()
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }
}

/// Resolvable handshake result for the control-plane auth round-trip.
private final class AuthHandshake: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?
    private let lock = NSLock()

    var value: Void {
        get async throws {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let result {
                    lock.unlock()
                    c.resume(with: result)
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        }
    }

    func succeed() {
        settle(.success(()))
    }

    func fail(_ error: Error) {
        settle(.failure(error))
    }

    private func settle(_ result: Result<Void, Error>) {
        lock.lock()
        if self.result == nil {
            self.result = result
        }
        let c = continuation
        continuation = nil
        lock.unlock()
        if let c {
            c.resume(with: self.result!)
        }
    }
}
