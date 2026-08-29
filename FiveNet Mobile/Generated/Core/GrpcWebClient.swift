import Foundation
import SwiftProtobuf

/// Minimal gRPC-Web (text format) HTTP client used for the unauthenticated/unary
/// auth calls (`Login`, `GetCharacters`, `ChooseCharacter`, `Logout`) which the
/// server expects to be performed over HTTP so cookies/tokens can be exchanged.
struct GrpcWebClient: Sendable {
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// The HTTP base path the FiveNet backend exposes for gRPC-Web requests.
    var grpcEndpoint: URL {
        baseURL.appendingPathComponent("api/grpc")
    }

    /// Performs a unary gRPC-Web call and decodes the protobuf response message.
    func unary<I: SwiftProtobuf.Message, O: SwiftProtobuf.Message>(
        service: String,
        method: String,
        request: I,
        responseType: O.Type,
        authToken: String?,
        sendBearer: Bool = true,
        cookie: String? = nil
    ) async throws -> O {
        try await unaryWithHeaders(
            service: service,
            method: method,
            request: request,
            responseType: responseType,
            authToken: authToken,
            sendBearer: sendBearer,
            cookie: cookie
        ).message
    }

    /// Performs a unary gRPC-Web call, returning the decoded message together with
    /// the actual HTTP response headers (which carry server-set cookies like
    /// `fivenet_acc`).
    func unaryWithHeaders<I: SwiftProtobuf.Message, O: SwiftProtobuf.Message>(
        service: String,
        method: String,
        request: I,
        responseType: O.Type,
        authToken: String?,
        sendBearer: Bool = true,
        cookie: String? = nil
    ) async throws -> (message: O, headers: [AnyHashable: Any]) {
        let url = grpcEndpoint.appendingPathComponent("\(service)/\(method)")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/grpc-web-text", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/grpc-web-text", forHTTPHeaderField: "Accept")
        urlRequest.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        urlRequest.setValue("grpc-web-javascript/0.1", forHTTPHeaderField: "X-User-Agent")
        if let authToken, !authToken.isEmpty {
            // Mirror the web client: the account token travels as the
            // `fivenet_acc` cookie. Some deployments (e.g. the demo server)
            // reject `ChooseCharacter` when the token is ALSO sent as a Bearer
            // Authorization header, so that header is opt-in (`sendBearer`).
            if sendBearer {
                urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            urlRequest.setValue("fivenet_acc=\(cookie ?? authToken)", forHTTPHeaderField: "Cookie")
        } else if let cookie, !cookie.isEmpty {
            // Authenticated API calls send the distinct user token as the Bearer
            // header while the session cookie stays the account token.
            urlRequest.setValue("fivenet_acc=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        urlRequest.httpBody = GrpcFramer.frame(try request.serializedData()).base64EncodedData()
        urlRequest.timeoutInterval = 20

        let (data, response) = try await Self.perform(session: session, request: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FiveNetError.invalidResponse("Keine HTTP-URLResponse erhalten")
        }

        let headers = httpResponse.allHeaderFields
        // gRPC-Web trailers (grpc-status / grpc-message) are delivered as real
        // HTTP response headers by the FiveNet wrapper.
        let headerStatus = Self.value(for: "grpc-status", in: headers).flatMap(Int.init)
        let headerMessage = Self.value(for: "grpc-message", in: headers).map { decodeGRPCMessage($0) }

        guard httpResponse.statusCode == 200 else {
            throw FiveNetError.grpcStatus(code: httpResponse.statusCode, message: headerMessage ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))
        }

        // The FiveNet wrapper delivers gRPC errors as real HTTP response headers
        // (grpc-status / grpc-message) with an empty body. Report those first so
        // a failed login surfaces a meaningful error even if the body is odd.
        if let headerStatus, headerStatus != 0 {
            throw FiveNetError.grpcStatus(code: headerStatus, message: headerMessage ?? "Unknown gRPC error")
        }

        guard let base64Data = GrpcFramer.lenientBase64Decode(String(decoding: data, as: UTF8.self)) else {
            // Some deployments respond with raw (binary) gRPC-Web frames instead
            // of base64 — try that before giving up.
            if let rawMessages = try? GrpcFramer.decodeFrames(from: data), !rawMessages.isEmpty {
                return (try O(serializedBytes: rawMessages[0]), headers)
            }
            let preview = String(decoding: data.prefix(256), as: UTF8.self)
            throw FiveNetError.invalidResponse(
                "Body war kein gültiges Base64 (Content-Type: \(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "-"), Content-Encoding: \(httpResponse.value(forHTTPHeaderField: "Content-Encoding") ?? "-"), Preview: \(preview)"
            )
        }

        let parsed: (messages: [Data], status: Int?, message: String?)
        do {
            parsed = try GrpcFramer.parseGRPCWebResponse(base64Data)
        } catch {
            // Surface the raw decoded bytes (base64, lossless to copy) so the
            // actual wire format can be identified when a deployment deviates
            // from the gRPC-Web spec.
            let b64 = base64Data.base64EncodedString()
            throw FiveNetError.invalidResponse(
                "\(errorText(of: error)) | decodedBytes=\(base64Data.count) decodedB64=\(b64)"
            )
        }
        let status = parsed.status ?? headerStatus
        if let status, status != 0 {
            let grpcMessage = headerMessage ?? parsed.message.map { decodeGRPCMessage($0) } ?? "Unknown gRPC error"
            throw FiveNetError.grpcStatus(code: status, message: grpcMessage)
        }
        guard let payload = parsed.messages.first else {
            throw FiveNetError.invalidResponse("Antwort enthielt keine Nachricht (grpc-status: \(status.map(String.init) ?? "-"), grpc-message: \(headerMessage ?? "-"))")
        }

        return (try O(serializedBytes: payload), headers)
    }

    /// Case-insensitive lookup of an HTTP response header value.
    private static func value(for name: String, in headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers {
            if let key = key as? String, key.lowercased() == name {
                return value as? String
            }
        }
        return nil
    }

    /// Performs the URLSession request WITHOUT cooperative task cancellation.
    ///
    /// `session.data(for:)` throws `URLError.cancelled` (-999) whenever the
    /// surrounding SwiftUI task is torn down mid-flight (a `List`/`Section`
    /// re-identifying its content, a tab switch, `.refreshable` re-entry, …).
    /// That would silently kill the authenticated HTTP fallback for
    /// `ListGroupActivity` — the request itself never completes, so no data is
    /// delivered and the panel reports a bogus "cancelled" error. The
    /// completion-handler data task only stops via session invalidation or the
    /// request timeout (bounded above), never via child-task cancellation.
    private static func perform(session: URLSession, request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            session.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: FiveNetError.invalidResponse("Keine HTTP-Antwort erhalten"))
                }
            }
            .resume()
        }
    }

    /// Extracts a human-readable reason from an error thrown while parsing.
    private func errorText(of error: Error) -> String {
        if let fiveNetError = error as? FiveNetError {
            switch fiveNetError {
            case .invalidResponse(let detail): return detail
            case .grpcStatus(let code, let message): return "gRPC-Status \(code): \(message)"
            case .invalidServerURL: return "Ungültige Server-URL"
            case .notConnected: return "Nicht verbunden"
            case .connectionClosed: return "Verbindung geschlossen"
            case .timeout: return "Zeitüberschreitung"
            case .loginFailed(let detail): return "Login fehlgeschlagen: \(detail)"
            case .unauthorized: return "Nicht autorisiert"
            case .missingCharacter: return "Kein Charakter ausgewählt"
            case .streamAlreadyExists: return "Stream existiert bereits"
            case .maxStreamsReached: return "Maximale Streams erreicht"
            case .cancelled: return "Abgebrochen"
            case .accountTokenMissing: return "Account-Token fehlt"
            }
        }
        return error.localizedDescription
    }

    /// Decodes a percent-encoded gRPC error message.
    private func decodeGRPCMessage(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
