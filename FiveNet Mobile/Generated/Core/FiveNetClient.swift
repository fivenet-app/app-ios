import Foundation
import SwiftProtobuf

/// Converts a Swift `Date` to the FiveNet timestamp proto.
func toTimestampProto(_ date: Date) -> Resources_Timestamp_Timestamp {
    Resources_Timestamp_Timestamp.with {
        $0.timestamp.seconds = Int64(date.timeIntervalSince1970)
    }
}

/// High-level client for the FiveNet gRPC backend.
///
/// Authentication (`Login`, `GetCharacters`, `ChooseCharacter`) is performed over
/// gRPC-Web over HTTP — mirroring the web client. All subsequent data calls run
/// over the multiplexed `grpcws` WebSocket channel.
final class FiveNetClient: @unchecked Sendable {
    let baseURL: URL
    private let grpcWeb: GrpcWebClient
    private let channel: FiveNetChannel

    private(set) var accountToken: String?
    private(set) var userToken: String?

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.grpcWeb = GrpcWebClient(baseURL: baseURL, session: Self.grpcWebSession)
        self.channel = FiveNetChannel(baseURL: baseURL, session: session)
    }

    /// Dedicated cookie-less session for the HTTP auth calls. FiveNet is
    /// authenticated via the `fivenet_acc` cookie / bearer token, and using a
    /// shared cookie jar would leak tokens between servers that share a hostname
    /// (HTTP cookies are scoped by host/path, not by port).
    private static let grpcWebSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    // MARK: - WebSocket channel access

    var isChannelConnected: Bool { channel.connectionState() }

    func setChannelStatusHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        channel.setStatusHandler(handler)
    }

    func setChannelAuthFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        channel.setAuthFailureHandler(handler)
    }

    /// Opens the WebSocket channel and authenticates it with the current user token.
    func connectChannel() async throws {
        try await channel.connect(userToken: userToken, accountToken: accountToken)
    }

    func disconnectChannel() {
        channel.disconnect()
    }

    /// Drops the in-memory auth tokens (kept around for re-login on the same server).
    func resetAuth() {
        accountToken = nil
        userToken = nil
    }

    /// Restores persisted tokens (used when a session is restored from storage
    /// instead of a fresh login).
    func setAuthTokens(accountToken: String?, userToken: String?) {
        self.accountToken = accountToken
        self.userToken = userToken
    }

    // MARK: - Auth (HTTP gRPC-Web)

    @discardableResult
    func login(username: String, password: String) async throws -> Services_Auth_LoginResponse {
        var request = Services_Auth_LoginRequest()
        request.username = username
        request.password = password

        let result = try await grpcWeb.unaryWithHeaders(
            service: "services.auth.AuthService",
            method: "Login",
            request: request,
            responseType: Services_Auth_LoginResponse.self,
            authToken: nil
        )

        guard let token = Self.extractAccountToken(from: result.headers) else {
            throw FiveNetError.accountTokenMissing
        }
        accountToken = token
        return result.message
    }

    func getCharacters() async throws -> [Resources_Accounts_Character] {
        let request = Services_Auth_GetCharactersRequest()
        let response: Services_Auth_GetCharactersResponse = try await grpcWeb.unary(
            service: "services.auth.AuthService",
            method: "GetCharacters",
            request: request,
            responseType: Services_Auth_GetCharactersResponse.self,
            authToken: accountToken
        )
        return response.chars
    }

    @discardableResult
    func chooseCharacter(id: Int32) async throws -> Services_Auth_ChooseCharacterResponse {
        var request = Services_Auth_ChooseCharacterRequest()
        request.charID = id

        let response: Services_Auth_ChooseCharacterResponse = try await grpcWeb.unary(
            service: "services.auth.AuthService",
            method: "ChooseCharacter",
            request: request,
            responseType: Services_Auth_ChooseCharacterResponse.self,
            authToken: accountToken,
            sendBearer: false
        )
        userToken = response.token
        return response
    }

    func logout() async throws {
        let request = Services_Auth_LogoutRequest()
        _ = try? await grpcWeb.unary(
            service: "services.auth.AuthService",
            method: "Logout",
            request: request,
            responseType: Services_Auth_LogoutResponse.self,
            authToken: accountToken
        )
    }

    // MARK: - gRPC-Web over WebSocket

    func call<O: SwiftProtobuf.Message>(service: String, method: String, requestData: Data?, responseType: O.Type) async throws -> O {
        let messages = try await channel.call(operation: "\(service)/\(method)", request: requestData)
        guard let first = messages.first else {
            throw FiveNetError.invalidResponse("Keine Antwort vom Server erhalten")
        }
        return try O(serializedBytes: first)
    }

    func serverStream(service: String, method: String, requestData: Data?) async throws -> AsyncThrowingStream<Data, Error> {
        try await channel.serverStream(operation: "\(service)/\(method)", request: requestData)
    }

    // MARK: - Citizens

    /// Lists citizens with an optional name search, ordered by last/first name.
    func listCitizens(search: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Citizens_ListCitizensResponse {
        var request = Services_Citizens_ListCitizensRequest()
        request.search = search
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "lastname" },
            Resources_Common_Database_SortByColumn.with { $0.id = "firstname" },
        ]
        return try await call(
            service: "services.citizens.CitizensService",
            method: "ListCitizens",
            requestData: try request.serializedData(),
            responseType: Services_Citizens_ListCitizensResponse.self
        )
    }

    /// Fetches a single citizen's full profile.
    func getCitizen(userID: Int32) async throws -> Resources_Users_User {
        var request = Services_Citizens_GetUserRequest()
        request.userID = userID
        let response: Services_Citizens_GetUserResponse = try await call(
            service: "services.citizens.CitizensService",
            method: "GetUser",
            requestData: try request.serializedData(),
            responseType: Services_Citizens_GetUserResponse.self
        )
        return response.user
    }

    /// Fetches the activity history (Aktivität) of a citizen.
    func listUserActivity(userID: Int32, offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Citizens_ListUserActivityResponse {
        var request = Services_Citizens_ListUserActivityRequest()
        request.userID = userID
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "createdAt"; $0.desc = true }
        ]
        return try await call(
            service: "services.citizens.CitizensService",
            method: "ListUserActivity",
            requestData: try request.serializedData(),
            responseType: Services_Citizens_ListUserActivityResponse.self
        )
    }

    // MARK: - Vehicles (Fahrzeuge)

    /// Resolves a name search to matching user ids (used for owner search).
    func completeCitizens(search: String, userIds: [Int32] = []) async throws -> Services_Completor_CompleteCitizensResponse {
        var request = Services_Completor_CompleteCitizensRequest()
        request.search = search
        request.userIds = userIds
        return try await call(
            service: "services.completor.CompletorService",
            method: "CompleteCitizens",
            requestData: try request.serializedData(),
            responseType: Services_Completor_CompleteCitizensResponse.self
        )
    }

    /// Lists vehicles with an optional license-plate / model search.
    func listVehicles(licensePlate: String = "", model: String = "", userIds: [Int32] = [], offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Vehicles_ListVehiclesResponse {
        var request = Services_Vehicles_ListVehiclesRequest()
        if !licensePlate.isEmpty { request.licensePlate = licensePlate }
        if !model.isEmpty { request.model = model }
        request.userIds = userIds
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "plate" }
        ]
        return try await call(
            service: "services.vehicles.VehiclesService",
            method: "ListVehicles",
            requestData: try request.serializedData(),
            responseType: Services_Vehicles_ListVehiclesResponse.self
        )
    }

    /// Fetches the activity history of a vehicle.
    func listVehicleActivity(plate: String, offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Vehicles_ListVehicleActivityResponse {
        var request = Services_Vehicles_ListVehicleActivityRequest()
        request.plate = plate
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "created_at" }
        ]
        return try await call(
            service: "services.vehicles.VehiclesService",
            method: "ListVehicleActivity",
            requestData: try request.serializedData(),
            responseType: Services_Vehicles_ListVehicleActivityResponse.self
        )
    }

    // MARK: - Centrum (Leitstelle)

    /// Lists dispatches, optionally filtered by status.
    func listDispatches(status: [Resources_Centrum_Dispatches_StatusDispatch] = [], notStatus: [Resources_Centrum_Dispatches_StatusDispatch] = [], offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Centrum_ListDispatchesResponse {
        var request = Services_Centrum_ListDispatchesRequest()
        request.status = status
        request.notStatus = notStatus
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.centrum.DispatchesService",
            method: "ListDispatches",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_ListDispatchesResponse.self
        )
    }

    /// Searches dispatches for the archive: by dispatch id, postal code and creator.
    func searchDispatches(ids: [Int64] = [], postal: String = "", creatorIds: [Int32] = [], status: [Resources_Centrum_Dispatches_StatusDispatch] = [], offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Centrum_ListDispatchesResponse {
        var request = Services_Centrum_ListDispatchesRequest()
        request.ids = ids
        if !postal.isEmpty { request.postal = postal }
        request.creatorIds = creatorIds
        request.status = status
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.centrum.DispatchesService",
            method: "ListDispatches",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_ListDispatchesResponse.self
        )
    }

    /// Fetches a single dispatch.
    func getDispatch(id: Int64) async throws -> Resources_Centrum_Dispatches_Dispatch {
        var request = Services_Centrum_GetDispatchRequest()
        request.id = id
        let response: Services_Centrum_GetDispatchResponse = try await call(
            service: "services.centrum.DispatchesService",
            method: "GetDispatch",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_GetDispatchResponse.self
        )
        return response.dispatch
    }

    /// Fetches the dispatch heatmap overlay (weighted dispatch hotspots).
    func getDispatchHeatmap() async throws -> Services_Centrum_GetDispatchHeatmapResponse {
        let request = Services_Centrum_GetDispatchHeatmapRequest()
        return try await call(
            service: "services.centrum.CentrumService",
            method: "GetDispatchHeatmap",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_GetDispatchHeatmapResponse.self
        )
    }

    /// Creates a new dispatch (einsatz) for the current character.
    func createDispatch(job: String, message: String, description: String = "", anon: Bool = false, x: Double = 0, y: Double = 0, postal: String = "") async throws -> Resources_Centrum_Dispatches_Dispatch {
        var request = Services_Centrum_CreateDispatchRequest()
        var dispatch = Resources_Centrum_Dispatches_Dispatch()
        dispatch.job = job
        dispatch.message = message
        if !description.isEmpty { dispatch.description_p = description }
        dispatch.anon = anon
        if x != 0 || y != 0 {
            dispatch.x = x
            dispatch.y = y
        }
        if !postal.isEmpty { dispatch.postal = postal }
        request.dispatch = dispatch
        let response: Services_Centrum_CreateDispatchResponse = try await call(
            service: "services.centrum.DispatchesService",
            method: "CreateDispatch",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_CreateDispatchResponse.self
        )
        return response.dispatch
    }

    /// Signs the current character on/off as a centrum dispatcher.
    func takeControl(signon: Bool) async throws {
        var request = Services_Centrum_TakeControlRequest()
        request.signon = signon
        _ = try await call(
            service: "services.centrum.CentrumService",
            method: "TakeControl",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_TakeControlResponse.self
        )
    }

    /// Updates the status of a dispatch.
    func updateDispatchStatus(dispatchID: Int64, status: Resources_Centrum_Dispatches_StatusDispatch, reason: String = "") async throws {
        var request = Services_Centrum_UpdateDispatchStatusRequest()
        request.dispatchID = dispatchID
        request.status = status
        if !reason.isEmpty { request.reason = reason }
        _ = try await call(
            service: "services.centrum.DispatchesService",
            method: "UpdateDispatchStatus",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_UpdateDispatchStatusResponse.self
        )
    }

    /// Responds to an assigned dispatch (accept/decline).
    func takeDispatch(dispatchIds: [Int64], resp: Resources_Centrum_Dispatches_TakeDispatchResp, reason: String = "") async throws {
        var request = Services_Centrum_TakeDispatchRequest()
        request.dispatchIds = dispatchIds
        request.resp = resp
        if !reason.isEmpty { request.reason = reason }
        _ = try await call(
            service: "services.centrum.DispatchesService",
            method: "TakeDispatch",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_TakeDispatchResponse.self
        )
    }

    /// Assigns or removes units from a dispatch.
    func assignDispatch(dispatchID: Int64, toAdd: [Int64], toRemove: [Int64]) async throws {
        var request = Services_Centrum_AssignDispatchRequest()
        request.dispatchID = dispatchID
        request.toAdd = toAdd
        request.toRemove = toRemove
        _ = try await call(
            service: "services.centrum.DispatchesService",
            method: "AssignDispatch",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_AssignDispatchResponse.self
        )
    }

    /// Lists units (Einheiten), optionally filtered by status.
    func listUnits(status: [Resources_Centrum_Units_StatusUnit] = []) async throws -> Services_Centrum_ListUnitsResponse {
        var request = Services_Centrum_ListUnitsRequest()
        request.status = status
        return try await call(
            service: "services.centrum.UnitsService",
            method: "ListUnits",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_ListUnitsResponse.self
        )
    }

    /// Updates the status of a unit.
    func updateUnitStatus(unitID: Int64, status: Resources_Centrum_Units_StatusUnit, reason: String = "") async throws {
        var request = Services_Centrum_UpdateUnitStatusRequest()
        request.unitID = unitID
        request.status = status
        if !reason.isEmpty { request.reason = reason }
        _ = try await call(
            service: "services.centrum.UnitsService",
            method: "UpdateUnitStatus",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_UpdateUnitStatusResponse.self
        )
    }

    /// Fetches the status history (activity feed) of a unit.
    func listUnitActivity(unitID: Int64, offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Centrum_ListUnitActivityResponse {
        var request = Services_Centrum_ListUnitActivityRequest()
        request.id = unitID
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.centrum.UnitsService",
            method: "ListUnitActivity",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_ListUnitActivityResponse.self
        )
    }

    /// Fetches the status history (activity feed) of a dispatch.
    func listDispatchActivity(dispatchID: Int64, offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Centrum_ListDispatchActivityResponse {
        var request = Services_Centrum_ListDispatchActivityRequest()
        request.id = dispatchID
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.centrum.DispatchesService",
            method: "ListDispatchActivity",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_ListDispatchActivityResponse.self
        )
    }

    /// Assigns or removes users from a unit.
    func assignUnit(unitID: Int64, toAdd: [Int32], toRemove: [Int32]) async throws {
        var request = Services_Centrum_AssignUnitRequest()
        request.unitID = unitID
        request.toAdd = toAdd
        request.toRemove = toRemove
        _ = try await call(
            service: "services.centrum.UnitsService",
            method: "AssignUnit",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_AssignUnitResponse.self
        )
    }

    /// Joins the authenticated character into a unit (server resolves the user from the token).
    func joinUnit(unitID: Int64) async throws -> Resources_Centrum_Units_Unit {
        var request = Services_Centrum_JoinUnitRequest()
        request.unitID = unitID
        let response: Services_Centrum_JoinUnitResponse = try await call(
            service: "services.centrum.UnitsService",
            method: "JoinUnit",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_JoinUnitResponse.self
        )
        return response.unit
    }

    /// Opens the server-streaming centrum live channel (dispatches + units).
    func centrumStream() async throws -> AsyncThrowingStream<Services_Centrum_StreamResponse, Error> {
        let dataStream = try await serverStream(
            service: "services.centrum.CentrumService",
            method: "Stream",
            requestData: try Services_Centrum_StreamRequest().serializedData()
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in dataStream {
                        let response = try Services_Centrum_StreamResponse(serializedBytes: data)
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Livemap

    /// Opens the server-streaming livemap channel yielding user positions.
    func livemapStream() async throws -> AsyncThrowingStream<Services_Livemap_StreamResponse, Error> {
        let dataStream = try await serverStream(
            service: "services.livemap.LivemapService",
            method: "Stream",
            requestData: try Services_Livemap_StreamRequest().serializedData()
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in dataStream {
                        let response = try Services_Livemap_StreamResponse(serializedBytes: data)
                        continuation.yield(response)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Creates or updates a marker marker (zone/shape) on the livemap.
    func createOrUpdateMarker(_ marker: Resources_Livemap_Markers_MarkerMarker) async throws -> Resources_Livemap_Markers_MarkerMarker {
        var request = Services_Livemap_CreateOrUpdateMarkerRequest()
        request.marker = marker
        let response: Services_Livemap_CreateOrUpdateMarkerResponse = try await call(
            service: "services.livemap.LivemapService",
            method: "CreateOrUpdateMarker",
            requestData: try request.serializedData(),
            responseType: Services_Livemap_CreateOrUpdateMarkerResponse.self
        )
        return response.marker
    }

    /// Deletes (or restores) a marker marker on the livemap.
    func deleteMarker(id: Int64) async throws {
        var request = Services_Livemap_DeleteMarkerRequest()
        request.id = id
        _ = try await call(
            service: "services.livemap.LivemapService",
            method: "DeleteMarker",
            requestData: try request.serializedData(),
            responseType: Services_Livemap_DeleteMarkerResponse.self
        )
    }

    // MARK: - Wiki

    /// Lists wiki pages, optionally filtered by job, root pages only, and/or a search term.
    func listWikiPages(job: String = "", rootOnly: Bool = false, search: String = "", offset: Int64 = 0, pageSize: Int64 = 100) async throws -> Services_Wiki_ListPagesResponse {
        var request = Services_Wiki_ListPagesRequest()
        if !job.isEmpty { request.job = job }
        request.rootOnly = rootOnly
        if !search.isEmpty { request.search = search }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.wiki.WikiService",
            method: "ListPages",
            requestData: try request.serializedData(),
            responseType: Services_Wiki_ListPagesResponse.self
        )
    }

    /// Fetches a single wiki page including its content.
    func getWikiPage(id: Int64) async throws -> Resources_Wiki_Page {
        var request = Services_Wiki_GetPageRequest()
        request.id = id
        let response: Services_Wiki_GetPageResponse = try await call(
            service: "services.wiki.WikiService",
            method: "GetPage",
            requestData: try request.serializedData(),
            responseType: Services_Wiki_GetPageResponse.self
        )
        return response.page
    }

    // MARK: - Documents (Dokumente)

    /// Lists document categories.
    func listCategories() async throws -> Services_Documents_ListCategoriesResponse {
        let request = Services_Documents_ListCategoriesRequest()
        return try await call(
            service: "services.documents.CategoriesService",
            method: "ListCategories",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListCategoriesResponse.self
        )
    }

    /// Lists documents with an optional search term, category filter, and closed state.
    func listDocuments(search: String = "", categoryIds: [Int64] = [], documentIds: [Int64] = [], closed: Bool? = nil, offset: Int64 = 0, pageSize: Int64 = 20) async throws -> Services_Documents_ListDocumentsResponse {
        var request = Services_Documents_ListDocumentsRequest()
        if !search.isEmpty { request.search = search }
        request.categoryIds = categoryIds
        request.documentIds = documentIds
        if let closed {
            request.closed = closed
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "createdAt"; $0.desc = true }
        ]
        return try await call(
            service: "services.documents.DocumentsService",
            method: "ListDocuments",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListDocumentsResponse.self
        )
    }

    /// Fetches a single document including its content.
    func getDocument(id: Int64) async throws -> Resources_Documents_Document {
        var request = Services_Documents_GetDocumentRequest()
        request.documentID = id
        let response: Services_Documents_GetDocumentResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "GetDocument",
            requestData: try request.serializedData(),
            responseType: Services_Documents_GetDocumentResponse.self
        )
        return response.document
    }

    /// Lists pinned documents (optionally personal pins only).
    func listDocumentPins(personal: Bool = false, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Documents_ListDocumentPinsResponse {
        var request = Services_Documents_ListDocumentPinsRequest()
        request.personal = personal
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.documents.DocumentsService",
            method: "ListDocumentPins",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListDocumentPinsResponse.self
        )
    }

    /// Pins or unpins a document for the current user / job.
    @discardableResult
    func toggleDocumentPin(documentID: Int64, state: Bool, personal: Bool = false) async throws -> Resources_Documents_Pins_DocumentPin? {
        var request = Services_Documents_ToggleDocumentPinRequest()
        request.documentID = documentID
        request.state = state
        request.personal = personal
        let response: Services_Documents_ToggleDocumentPinResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "ToggleDocumentPin",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ToggleDocumentPinResponse.self
        )
        return response.hasPin ? response.pin : nil
    }

    /// Opens or closes a document.
    func toggleDocument(documentID: Int64, closed: Bool) async throws {
        var request = Services_Documents_ToggleDocumentRequest()
        request.documentID = documentID
        request.closed = closed
        _ = try await call(
            service: "services.documents.DocumentsService",
            method: "ToggleDocument",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ToggleDocumentResponse.self
        )
    }

    /// Lists documents related to (or related from) the given document.
    func listDocumentRelations(documentID: Int64) async throws -> [Resources_Documents_Relations_DocumentRelation] {
        var request = Services_Documents_GetDocumentRelationsRequest()
        request.documentID = documentID
        let response: Services_Documents_GetDocumentRelationsResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "GetDocumentRelations",
            requestData: try request.serializedData(),
            responseType: Services_Documents_GetDocumentRelationsResponse.self
        )
        return response.relations
    }

    /// Lists documents referencing (or referenced by) the given document.
    func listDocumentReferences(documentID: Int64) async throws -> [Resources_Documents_References_DocumentReference] {
        var request = Services_Documents_GetDocumentReferencesRequest()
        request.documentID = documentID
        let response: Services_Documents_GetDocumentReferencesResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "GetDocumentReferences",
            requestData: try request.serializedData(),
            responseType: Services_Documents_GetDocumentReferencesResponse.self
        )
        return response.references
    }

    /// Fetches the access configuration (jobs/users) of a document.
    func getDocumentAccess(documentID: Int64) async throws -> Resources_Access_Access {
        var request = Services_Documents_GetDocumentAccessRequest()
        request.documentID = documentID
        let response: Services_Documents_GetDocumentAccessResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "GetDocumentAccess",
            requestData: try request.serializedData(),
            responseType: Services_Documents_GetDocumentAccessResponse.self
        )
        return response.access
    }

    /// Lists comments on a document.
    func listComments(documentID: Int64, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> [Resources_Documents_Comment_Comment] {
        var request = Services_Documents_GetCommentsRequest()
        request.documentID = documentID
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        let response: Services_Documents_GetCommentsResponse = try await call(
            service: "services.documents.CommentsService",
            method: "GetComments",
            requestData: try request.serializedData(),
            responseType: Services_Documents_GetCommentsResponse.self
        )
        return response.comments
    }

    /// Lists document templates available for creating new documents.
    func listTemplates() async throws -> [Resources_Documents_Templates_TemplateShort] {
        let request = Services_Documents_ListTemplatesRequest()
        let response: Services_Documents_ListTemplatesResponse = try await call(
            service: "services.documents.TemplatesService",
            method: "ListTemplates",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListTemplatesResponse.self
        )
        return response.templates
    }

    /// Fetches a template with rendered content (render=true). The server resolves
    /// the selection (citizens/documents/vehicles) itself and returns the raw
    /// template error (instead of a sanitized ErrFailedQuery) when the caller has
    /// CreateTemplate permission, which is useful for diagnostics.
    func getTemplate(templateID: Int64, templateSelection: Resources_Documents_Templates_TemplateSelection? = nil, render: Bool = false) async throws -> Resources_Documents_Templates_Template {
        var request = Services_Documents_GetTemplateRequest()
        request.templateID = templateID
        if let templateSelection {
            request.selection = templateSelection
        }
        request.render = render
        let response: Services_Documents_GetTemplateResponse = try await call(
            service: "services.documents.TemplatesService",
            method: "GetTemplate",
            requestData: try request.serializedData(),
            responseType: Services_Documents_GetTemplateResponse.self
        )
        return response.template
    }

    /// Creates a new document from a template and returns the new document id.
    /// When `templateID` is omitted, an empty document is created instead.
    func createDocument(templateID: Int64? = nil, templateSelection: Resources_Documents_Templates_TemplateSelection? = nil) async throws -> Int64 {
        var request = Services_Documents_CreateDocumentRequest()
        if let templateID {
            request.templateID = templateID
        }
        request.contentType = .html
        if let templateSelection {
            request.templateSelection = templateSelection
        }
        let response: Services_Documents_CreateDocumentResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "CreateDocument",
            requestData: try request.serializedData(),
            responseType: Services_Documents_CreateDocumentResponse.self
        )
        return response.id
    }

    /// Lists document relations for a given user (citizen "Dokumente" tab).
    func listUserDocuments(userID: Int32, closed: Bool? = nil, offset: Int64 = 0, pageSize: Int64 = 20) async throws -> [Resources_Documents_Relations_DocumentRelation] {
        var request = Services_Documents_ListUserDocumentsRequest()
        request.userID = userID
        if let closed {
            request.closed = closed
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "createdAt"; $0.desc = true }
        ]
        let response: Services_Documents_ListUserDocumentsResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "ListUserDocuments",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListUserDocumentsResponse.self
        )
        return response.relations
    }

    /// Updates a document (title, category, content, meta). Mirrors the web
    /// edit page save. The server requires a full `DocumentMeta`.
    func updateDocument(documentID: Int64, title: String, categoryID: Int64? = nil, content: Resources_Common_Content_Content, contentType: Resources_Common_Content_ContentType, data: Resources_Documents_Data_DocumentData? = nil, meta: Resources_Documents_DocumentMeta, access: Resources_Access_Access? = nil, files: [Resources_File_File] = []) async throws -> Resources_Documents_Document {
        var request = Services_Documents_UpdateDocumentRequest()
        request.documentID = documentID
        request.title = title
        if let categoryID {
            request.categoryID = categoryID
        }
        request.content = content
        request.contentType = contentType
        if let data {
            request.data = data
        }
        request.meta = meta
        if let access {
            request.access = access
        }
        request.files = files
        let response: Services_Documents_UpdateDocumentResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "UpdateDocument",
            requestData: try request.serializedData(),
            responseType: Services_Documents_UpdateDocumentResponse.self
        )
        return response.document
    }

    /// Soft-deletes a document. When called on an already-deleted document the
    /// server restores it instead (job admin only).
    func deleteDocument(documentID: Int64, reason: String? = nil) async throws {
        var request = Services_Documents_DeleteDocumentRequest()
        request.documentID = documentID
        if let reason {
            request.reason = reason
        }
        _ = try await call(
            service: "services.documents.DocumentsService",
            method: "DeleteDocument",
            requestData: try request.serializedData(),
            responseType: Services_Documents_DeleteDocumentResponse.self
        )
    }

    /// Takes ownership of a document (optionally assigning it to another user).
    func changeDocumentOwner(documentID: Int64, newUserID: Int32? = nil) async throws {
        var request = Services_Documents_ChangeDocumentOwnerRequest()
        request.documentID = documentID
        if let newUserID {
            request.newUserID = newUserID
        }
        _ = try await call(
            service: "services.documents.DocumentsService",
            method: "ChangeDocumentOwner",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ChangeDocumentOwnerResponse.self
        )
    }

    /// Sets or updates a personal reminder for a document.
    func setDocumentReminder(documentID: Int64, reminderTime: Resources_Timestamp_Timestamp? = nil, message: String? = nil, maxReminderCount: Int32 = 10) async throws {
        var request = Services_Documents_SetDocumentReminderRequest()
        request.documentID = documentID
        if let reminderTime {
            request.reminderTime = reminderTime
        }
        if let message {
            request.message = message
        }
        request.maxReminderCount = maxReminderCount
        _ = try await call(
            service: "services.documents.DocumentsService",
            method: "SetDocumentReminder",
            requestData: try request.serializedData(),
            responseType: Services_Documents_SetDocumentReminderResponse.self
        )
    }

    /// Lists document requests (Anfragen) for a document.
    func listDocumentReqs(documentID: Int64, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Documents_ListDocumentReqsResponse {
        var request = Services_Documents_ListDocumentReqsRequest()
        request.documentID = documentID
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.documents.DocumentsService",
            method: "ListDocumentReqs",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListDocumentReqsResponse.self
        )
    }

    /// Creates a document request (e.g. requestedAccess, requestedClosure, …).
    @discardableResult
    func createDocumentReq(documentID: Int64, requestType: Resources_Documents_Activity_DocActivityType, reason: String) async throws -> Resources_Documents_Requests_DocRequest {
        var request = Services_Documents_CreateDocumentReqRequest()
        request.documentID = documentID
        request.requestType = requestType
        request.reason = reason
        let response: Services_Documents_CreateDocumentReqResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "CreateDocumentReq",
            requestData: try request.serializedData(),
            responseType: Services_Documents_CreateDocumentReqResponse.self
        )
        return response.request
    }

    /// Approves or declines a document request.
    @discardableResult
    func updateDocumentReq(documentID: Int64, requestID: Int64, accepted: Bool) async throws -> Resources_Documents_Requests_DocRequest {
        var request = Services_Documents_UpdateDocumentReqRequest()
        request.documentID = documentID
        request.requestID = requestID
        request.accepted = accepted
        let response: Services_Documents_UpdateDocumentReqResponse = try await call(
            service: "services.documents.DocumentsService",
            method: "UpdateDocumentReq",
            requestData: try request.serializedData(),
            responseType: Services_Documents_UpdateDocumentReqResponse.self
        )
        return response.request
    }

    /// Deletes a document request.
    func deleteDocumentReq(requestID: Int64) async throws {
        var request = Services_Documents_DeleteDocumentReqRequest()
        request.requestID = requestID
        _ = try await call(
            service: "services.documents.DocumentsService",
            method: "DeleteDocumentReq",
            requestData: try request.serializedData(),
            responseType: Services_Documents_DeleteDocumentReqResponse.self
        )
    }

    // MARK: - Document approvals

    /// Lists approval tasks for a document (optionally filtered by status).
    func listApprovalTasks(documentID: Int64, statuses: [Resources_Documents_Approval_ApprovalTaskStatus] = []) async throws -> [Resources_Documents_Approval_ApprovalTask] {
        var request = Services_Documents_ListApprovalTasksRequest()
        request.documentID = documentID
        request.statuses = statuses
        let response: Services_Documents_ListApprovalTasksResponse = try await call(
            service: "services.documents.ApprovalService",
            method: "ListApprovalTasks",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListApprovalTasksResponse.self
        )
        return response.tasks
    }

    /// Decides an approval task (approve or decline).
    @discardableResult
    func decideApproval(documentID: Int64, taskID: Int64, newStatus: Resources_Documents_Approval_ApprovalTaskStatus, comment: String = "") async throws -> Services_Documents_DecideApprovalResponse {
        var request = Services_Documents_DecideApprovalRequest()
        request.documentID = documentID
        request.taskID = taskID
        request.newStatus = newStatus
        request.comment = comment
        return try await call(
            service: "services.documents.ApprovalService",
            method: "DecideApproval",
            requestData: try request.serializedData(),
            responseType: Services_Documents_DecideApprovalResponse.self
        )
    }

    /// Fetches the approval policy (and document meta) of a document.
    func listApprovalPolicies(documentID: Int64) async throws -> Services_Documents_ListApprovalPoliciesResponse {
        var request = Services_Documents_ListApprovalPoliciesRequest()
        request.documentID = documentID
        return try await call(
            service: "services.documents.ApprovalService",
            method: "ListApprovalPolicies",
            requestData: try request.serializedData(),
            responseType: Services_Documents_ListApprovalPoliciesResponse.self
        )
    }

    // MARK: - Jobs (Berufe)

    /// Fetches the job message of the day (MOTD).
    func getMOTD() async throws -> String {
        let request = Services_Jobs_GetMOTDRequest()
        let response: Services_Jobs_GetMOTDResponse = try await call(
            service: "services.jobs.JobsService",
            method: "GetMOTD",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetMOTDResponse.self
        )
        return response.motd
    }

    /// Sets the job message of the day (MOTD).
    func setMOTD(_ motd: String) async throws -> String {
        var request = Services_Jobs_SetMOTDRequest()
        request.motd = motd
        let response: Services_Jobs_SetMOTDResponse = try await call(
            service: "services.jobs.JobsService",
            method: "SetMOTD",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_SetMOTDResponse.self
        )
        return response.motd
    }

    /// Lists colleagues with optional search, absence and label filters.
    func listColleagues(search: String = "", userIds: [Int32] = [], absent: Bool? = nil, labelIds: [Int64] = [], offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListColleaguesResponse {
        var request = Services_Jobs_ListColleaguesRequest()
        request.search = search
        request.users.userIds = userIds
        if let absent {
            request.absent = absent
        }
        request.labelIds = labelIds
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "jobGrade" },
            Resources_Common_Database_SortByColumn.with { $0.id = "name" },
        ]
        return try await call(
            service: "services.jobs.ColleaguesService",
            method: "ListColleagues",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListColleaguesResponse.self
        )
    }

    /// Fetches the current character's own colleague profile.
    func getSelfColleague() async throws -> Resources_Jobs_Colleagues_Colleague {
        let request = Services_Jobs_GetSelfRequest()
        let response: Services_Jobs_GetSelfResponse = try await call(
            service: "services.jobs.ColleaguesService",
            method: "GetSelf",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetSelfResponse.self
        )
        return response.colleague
    }

    /// Fetches a single colleague's full profile.
    func getColleague(userID: Int32) async throws -> Resources_Jobs_Colleagues_Colleague {
        var request = Services_Jobs_GetColleagueRequest()
        request.userID = userID
        let response: Services_Jobs_GetColleagueResponse = try await call(
            service: "services.jobs.ColleaguesService",
            method: "GetColleague",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetColleagueResponse.self
        )
        return response.colleague
    }

    /// Lists colleague activity (Aktivität) filtered by user and activity types.
    ///
    /// The server returns an empty response when no `activityTypes` are sent
    /// (services/jobs/colleagues.go: `ListColleagueActivity`), so an empty list
    /// defaults to all types — mirroring the web client, which always sends the
    /// full list. The server filters these down to the caller's permissions.
    func listColleagueActivity(userIds: [Int32] = [], activityTypes: [Resources_Jobs_Colleagues_Activity_ColleagueActivityType] = [], offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListColleagueActivityResponse {
        var request = Services_Jobs_ListColleagueActivityRequest()
        request.users.userIds = userIds
        request.activityTypes = activityTypes.isEmpty ? Self.allActivityTypes : activityTypes
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "created_at"; $0.desc = true }
        ]
        return try await call(
            service: "services.jobs.ColleaguesService",
            method: "ListColleagueActivity",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListColleagueActivityResponse.self
        )
    }

    /// All non-unspecified colleague activity types, sent when the caller did
    /// not filter explicitly (the server then applies permission filtering).
    private static let allActivityTypes: [Resources_Jobs_Colleagues_Activity_ColleagueActivityType] = [
        .hired, .fired, .promoted, .demoted, .absenceDate, .note, .labels, .name,
    ]

    /// Sets colleague properties (absence, note, labels, name).
    func setColleagueProps(_ props: Resources_Jobs_Colleagues_ColleagueProps, reason: String = "") async throws -> Resources_Jobs_Colleagues_ColleagueProps {
        var request = Services_Jobs_SetColleaguePropsRequest()
        request.props = props
        request.reason = reason
        let response: Services_Jobs_SetColleaguePropsResponse = try await call(
            service: "services.jobs.ColleaguesService",
            method: "SetColleagueProps",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_SetColleaguePropsResponse.self
        )
        return response.props
    }

    /// Lists colleague labels, optionally filtered by search.
    func getColleagueLabels(search: String = "") async throws -> [Resources_Jobs_Labels_Label] {
        var request = Services_Jobs_GetColleagueLabelsRequest()
        if !search.isEmpty {
            request.search = search
        }
        let response: Services_Jobs_GetColleagueLabelsResponse = try await call(
            service: "services.jobs.ColleaguesService",
            method: "GetColleagueLabels",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetColleagueLabelsResponse.self
        )
        return response.labels
    }

    /// Creates or updates a single colleague label (v2026.8.1 replaced the
    /// bulk `ManageLabels` RPC with per-label CreateOrUpdate/Delete/Reorder).
    func createOrUpdateLabel(_ label: Resources_Jobs_Labels_Label) async throws -> Resources_Jobs_Labels_Label {
        var request = Services_Jobs_CreateOrUpdateLabelRequest()
        request.label = label
        let response: Services_Jobs_CreateOrUpdateLabelResponse = try await call(
            service: "services.jobs.ColleaguesService",
            method: "CreateOrUpdateLabel",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_CreateOrUpdateLabelResponse.self
        )
        return response.label
    }

    /// Deletes a colleague label by id.
    func deleteLabel(id: Int64) async throws {
        var request = Services_Jobs_DeleteLabelRequest()
        request.id = id
        _ = try await call(
            service: "services.jobs.ColleaguesService",
            method: "DeleteLabel",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_DeleteLabelResponse.self
        )
    }

    /// Reorders colleague labels by id (send the full ordered list of ids).
    func reorderLabels(_ labelIds: [Int64]) async throws {
        var request = Services_Jobs_ReorderLabelsRequest()
        request.labelIds = labelIds
        _ = try await call(
            service: "services.jobs.ColleaguesService",
            method: "ReorderLabels",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ReorderLabelsResponse.self
        )
    }

    /// Fetches label usage statistics (how many colleagues carry each label).
    func getColleagueLabelsStats(labelIds: [Int64] = []) async throws -> [Resources_Jobs_Labels_LabelCount] {
        var request = Services_Jobs_GetColleagueLabelsStatsRequest()
        request.labelIds = labelIds
        let response: Services_Jobs_GetColleagueLabelsStatsResponse = try await call(
            service: "services.jobs.ColleaguesService",
            method: "GetColleagueLabelsStats",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetColleagueLabelsStatsResponse.self
        )
        return response.count
    }

    /// Fetches job statistics (employee count over time, matching the web
    /// `jobs.StatsService/GetStats` page). Category/period mirror the web
    /// query; the server caps the range at 365 days and defaults to daily.
    func getStats(start: Date, end: Date, period: Resources_Stats_StatsPeriod = .unspecified, category: Resources_Stats_StatsCategory = .employeeCountOverTime) async throws -> Services_Jobs_GetStatsResponse {
        var request = Services_Jobs_GetStatsRequest()
        request.start = toTimestampProto(start)
        request.end = toTimestampProto(end)
        request.period = period
        request.category = category
        return try await call(
            service: "services.jobs.StatsService",
            method: "GetStats",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetStatsResponse.self
        )
    }

    /// Lists timeclock entries (daily view).
    func listTimeclock(userMode: Resources_Jobs_Timeclock_TimeclockViewMode = .unspecified, mode: Resources_Jobs_Timeclock_TimeclockMode = .daily, perDay: Bool = false, userIds: [Int32] = [], start: Date? = nil, end: Date? = nil, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListTimeclockResponse {
        var request = Services_Jobs_ListTimeclockRequest()
        request.userMode = userMode
        request.mode = mode
        request.perDay = perDay
        request.users.userIds = userIds
        if let start {
            request.date.start = toTimestampProto(start)
        }
        if let end {
            request.date.end = toTimestampProto(end)
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.jobs.TimeclockService",
            method: "ListTimeclock",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListTimeclockResponse.self
        )
    }

    /// Fetches timeclock statistics for the current character (or a given user).
    func getTimeclockStats(userID: Int32? = nil) async throws -> Services_Jobs_GetTimeclockStatsResponse {
        var request = Services_Jobs_GetTimeclockStatsRequest()
        if let userID {
            request.users.userIds = [userID]
        }
        return try await call(
            service: "services.jobs.TimeclockService",
            method: "GetTimeclockStats",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetTimeclockStatsResponse.self
        )
    }

    /// Lists inactive employees (no timeclock entry within the last `days` days).
    func listInactiveEmployees(days: Int32 = 30, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListInactiveEmployeesResponse {
        var request = Services_Jobs_ListInactiveEmployeesRequest()
        request.days = days
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.jobs.TimeclockService",
            method: "ListInactiveEmployees",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListInactiveEmployeesResponse.self
        )
    }

    /// Lists conduct register entries.
    func listConductEntries(types: [Resources_Jobs_Conduct_ConductType] = [], userIds: [Int32] = [], showExpired: Bool? = nil, showDrafts: Bool? = nil, showDeleted: Bool? = nil, ids: [Int64] = [], offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListConductEntriesResponse {
        var request = Services_Jobs_ListConductEntriesRequest()
        request.types = types
        request.users.userIds = userIds
        request.ids = ids
        if let showExpired {
            request.showExpired = showExpired
        }
        if let showDrafts {
            request.showDrafts = showDrafts
        }
        if let showDeleted {
            request.showDeleted = showDeleted
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "created_at"; $0.desc = true }
        ]
        return try await call(
            service: "services.jobs.ConductService",
            method: "ListConductEntries",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListConductEntriesResponse.self
        )
    }

    /// Fetches a single conduct register entry by id.
    func getConductEntry(id: Int64) async throws -> Services_Jobs_GetConductEntryResponse {
        var request = Services_Jobs_GetConductEntryRequest()
        request.id = id
        return try await call(
            service: "services.jobs.ConductService",
            method: "GetConductEntry",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetConductEntryResponse.self
        )
    }

    /// Creates a new conduct register entry. The server fills in `job` and
    /// `creator_id` from the session token.
    func createConductEntry(entry: Resources_Jobs_Conduct_ConductEntry) async throws -> Resources_Jobs_Conduct_ConductEntry {
        var request = Services_Jobs_CreateConductEntryRequest()
        request.entry = entry
        let response: Services_Jobs_CreateConductEntryResponse = try await call(
            service: "services.jobs.ConductService",
            method: "CreateConductEntry",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_CreateConductEntryResponse.self
        )
        return response.entry
    }

    /// Updates an existing conduct register entry.
    func updateConductEntry(entry: Resources_Jobs_Conduct_ConductEntry) async throws -> Resources_Jobs_Conduct_ConductEntry {
        var request = Services_Jobs_UpdateConductEntryRequest()
        request.entry = entry
        let response: Services_Jobs_UpdateConductEntryResponse = try await call(
            service: "services.jobs.ConductService",
            method: "UpdateConductEntry",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_UpdateConductEntryResponse.self
        )
        return response.entry
    }

    /// Fetches job props (logo, radio frequency, MOTD) for the current job.
    func getJobProps() async throws -> Resources_Jobs_Props_JobProps {
        let request = Services_Settings_GetJobPropsRequest()
        let response: Services_Settings_GetJobPropsResponse = try await call(
            service: "services.settings.SettingsService",
            method: "GetJobProps",
            requestData: try request.serializedData(),
            responseType: Services_Settings_GetJobPropsResponse.self
        )
        return response.jobProps
    }

    /// Updates the active job's properties (MOTD, radio frequency, job label,
    /// marker color). The server persists the fields and returns the stored props.
    func setJobProps(_ props: Resources_Jobs_Props_JobProps) async throws -> Resources_Jobs_Props_JobProps {
        var request = Services_Settings_SetJobPropsRequest()
        request.jobProps = props
        let response: Services_Settings_SetJobPropsResponse = try await call(
            service: "services.settings.SettingsService",
            method: "SetJobProps",
            requestData: try request.serializedData(),
            responseType: Services_Settings_SetJobPropsResponse.self
        )
        return response.jobProps
    }

    /// Lists all roles of the active job (GetRoles; lowestRank optional).
    func getRoles(lowestRank: Bool? = nil) async throws -> [Resources_Permissions_Permissions_Role] {
        var request = Services_Settings_GetRolesRequest()
        if let lowestRank {
            request.lowestRank = lowestRank
        }
        let response: Services_Settings_GetRolesResponse = try await call(
            service: "services.settings.SettingsService",
            method: "GetRoles",
            requestData: try request.serializedData(),
            responseType: Services_Settings_GetRolesResponse.self
        )
        return response.roles
    }

    /// Creates a new role for the given job at the given grade.
    func createRole(job: String, grade: Int32) async throws -> Resources_Permissions_Permissions_Role {
        var request = Services_Settings_CreateRoleRequest()
        request.job = job
        request.grade = grade
        let response: Services_Settings_CreateRoleResponse = try await call(
            service: "services.settings.SettingsService",
            method: "CreateRole",
            requestData: try request.serializedData(),
            responseType: Services_Settings_CreateRoleResponse.self
        )
        return response.role
    }

    /// Deletes a role by id.
    func deleteRole(id: Int64) async throws {
        var request = Services_Settings_DeleteRoleRequest()
        request.id = id
        _ = try await call(
            service: "services.settings.SettingsService",
            method: "DeleteRole",
            requestData: try request.serializedData(),
            responseType: Services_Settings_DeleteRoleResponse.self
        )
    }

    /// Fetches the effective (inherited) role, permissions and attributes.
    func getEffectivePermissions(roleId: Int64) async throws -> Services_Settings_GetEffectivePermissionsResponse {
        var request = Services_Settings_GetEffectivePermissionsRequest()
        request.roleID = roleId
        return try await call(
            service: "services.settings.SettingsService",
            method: "GetEffectivePermissions",
            requestData: try request.serializedData(),
            responseType: Services_Settings_GetEffectivePermissionsResponse.self
        )
    }

    /// Views the audit log with optional filters (search, actions, results) and
    /// offset/pageSize pagination.
    func viewAuditLog(search: String = "", actions: [Resources_Audit_EventAction] = [], results: [Resources_Audit_EventResult] = [], offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Settings_ViewAuditLogResponse {
        var request = Services_Settings_ViewAuditLogRequest()
        if !search.isEmpty {
            request.search = search
        }
        request.actions = actions
        request.results = results
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "created_at"; $0.desc = true }
        ]
        return try await call(
            service: "services.settings.SettingsService",
            method: "ViewAuditLog",
            requestData: try request.serializedData(),
            responseType: Services_Settings_ViewAuditLogResponse.self
        )
    }

    /// Lists the discord channels of the linked guild.
    func listDiscordChannels() async throws -> [Resources_Discord_Channel] {
        let request = Services_Settings_ListDiscordChannelsRequest()
        let response: Services_Settings_ListDiscordChannelsResponse = try await call(
            service: "services.settings.SettingsService",
            method: "ListDiscordChannels",
            requestData: try request.serializedData(),
            responseType: Services_Settings_ListDiscordChannelsResponse.self
        )
        return response.channels
    }

    /// Lists the discord guilds the authenticated user is in.
    func listUserGuilds() async throws -> [Resources_Discord_Guild] {
        let request = Services_Settings_ListUserGuildsRequest()
        let response: Services_Settings_ListUserGuildsResponse = try await call(
            service: "services.settings.SettingsService",
            method: "ListUserGuilds",
            requestData: try request.serializedData(),
            responseType: Services_Settings_ListUserGuildsResponse.self
        )
        return response.guilds
    }

    /// Deletes the active job's logo.
    func deleteJobLogo() async throws {
        let request = Services_Settings_DeleteJobLogoRequest()
        _ = try await call(
            service: "services.settings.SettingsService",
            method: "DeleteJobLogo",
            requestData: try request.serializedData(),
            responseType: Services_Settings_DeleteJobLogoResponse.self
        )
    }

    // MARK: - Jobs: Gruppen (GroupsService)

    /// Lists job groups, optionally filtered by states/kind/search. Mirrors the
    /// web `groups/List.vue` list request (default sort `sort_rank` asc).
    func listGroups(states: [Resources_Jobs_Groups_GroupState] = [], kind: Resources_Jobs_Groups_GroupType? = nil, search: String = "", includeCounts: Bool = true, includeInactive: Bool = false, includeArchived: Bool = false, groupIds: [Int32] = [], sortColumn: String = "sort_rank", desc: Bool = false, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListGroupsResponse {
        var request = Services_Jobs_ListGroupsRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        if let kind {
            request.kind = kind
        }
        if !search.isEmpty {
            request.search = search
        }
        request.states = states
        request.includeCounts = includeCounts
        request.includeInactive = includeInactive
        request.includeArchived = includeArchived
        request.groupIds = groupIds
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = sortColumn; $0.desc = desc }
        ]
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ListGroups",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListGroupsResponse.self
        )
    }

    /// Fetches a single job group. The detail view only needs `group` + `access`
    /// (the v2026.8.4 proto dropped the per-item include flags — panels load
    /// rules/leaders/members/exclusions via the dedicated list endpoints).
    func getGroup(id: Int64, includeArchived: Bool = true) async throws -> Services_Jobs_GetGroupResponse {
        var request = Services_Jobs_GetGroupRequest()
        request.id = id
        request.includeArchived = includeArchived
        return try await call(
            service: "services.jobs.GroupsService",
            method: "GetGroup",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_GetGroupResponse.self
        )
    }

    /// Creates a new job group. The server fills `job` from the session token.
    func createGroup(_ group: Services_Jobs_CreateGroupRequest) async throws -> Resources_Jobs_Groups_Group {
        let response: Services_Jobs_CreateGroupResponse = try await call(
            service: "services.jobs.GroupsService",
            method: "CreateGroup",
            requestData: try group.serializedData(),
            responseType: Services_Jobs_CreateGroupResponse.self
        )
        return response.group
    }

    /// Updates an existing job group.
    func updateGroup(_ request: Services_Jobs_UpdateGroupRequest) async throws -> Resources_Jobs_Groups_Group {
        let response: Services_Jobs_UpdateGroupResponse = try await call(
            service: "services.jobs.GroupsService",
            method: "UpdateGroup",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_UpdateGroupResponse.self
        )
        return response.group
    }

    /// Archives a job group (requires a reason, mirrors the web confirm modal).
    func archiveGroup(id: Int64, reason: String = "") async throws -> Resources_Jobs_Groups_Group {
        var request = Services_Jobs_ArchiveGroupRequest()
        request.id = id
        if !reason.isEmpty {
            request.reason = reason
        }
        let response: Services_Jobs_ArchiveGroupResponse = try await call(
            service: "services.jobs.GroupsService",
            method: "ArchiveGroup",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ArchiveGroupResponse.self
        )
        return response.group
    }

    /// Restores an archived job group.
    func restoreGroup(id: Int64) async throws -> Resources_Jobs_Groups_Group {
        var request = Services_Jobs_RestoreGroupRequest()
        request.id = id
        let response: Services_Jobs_RestoreGroupResponse = try await call(
            service: "services.jobs.GroupsService",
            method: "RestoreGroup",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_RestoreGroupResponse.self
        )
        return response.group
    }

    /// Deletes a job group logo.
    func deleteGroupLogo(id: Int64) async throws -> Resources_Jobs_Groups_Group {
        var request = Services_Jobs_DeleteGroupLogoRequest()
        request.id = id
        let response: Services_Jobs_DeleteGroupLogoResponse = try await call(
            service: "services.jobs.GroupsService",
            method: "DeleteGroupLogo",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_DeleteGroupLogoResponse.self
        )
        return response.group
    }

    /// Lists resolved group members (rules + manual + leaders − exclusions).
    func listGroupMembers(groupID: Int64, search: String = "", sources: [Resources_Jobs_Groups_GroupMemberSource] = [], includeExcluded: Bool = true, includeLeaders: Bool = true, includeReasons: Bool = true, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListGroupMembersResponse {
        var request = Services_Jobs_ListGroupMembersRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.groupID = groupID
        if !search.isEmpty {
            request.search = search
        }
        request.includeExcluded = includeExcluded
        request.includeLeaders = includeLeaders
        request.includeReasons = includeReasons
        request.sources = sources
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "user_id"; $0.desc = false }
        ]
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ListGroupMembers",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListGroupMembersResponse.self
        )
    }

    /// Lists explicitly added group members.
    func listGroupManualMembers(groupID: Int64, search: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListGroupManualMembersResponse {
        var request = Services_Jobs_ListGroupManualMembersRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.groupID = groupID
        if !search.isEmpty {
            request.search = search
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ListGroupManualMembers",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListGroupManualMembersResponse.self
        )
    }

    /// Lists group member exclusions.
    func listGroupMemberExclusions(groupID: Int64, search: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListGroupMemberExclusionsResponse {
        var request = Services_Jobs_ListGroupMemberExclusionsRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.groupID = groupID
        if !search.isEmpty {
            request.search = search
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ListGroupMemberExclusions",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListGroupMemberExclusionsResponse.self
        )
    }

    /// Lists group leaders.
    func listGroupLeaders(groupID: Int64, search: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListGroupLeadersResponse {
        var request = Services_Jobs_ListGroupLeadersRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.groupID = groupID
        if !search.isEmpty {
            request.search = search
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ListGroupLeaders",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListGroupLeadersResponse.self
        )
    }

    /// Adds (or updates via upsert semantics) a manual group member.
    func addGroupMember(groupID: Int64, userID: Int32, reason: String = "") async throws -> Services_Jobs_AddGroupMemberResponse {
        var request = Services_Jobs_AddGroupMemberRequest()
        request.groupID = groupID
        request.userID = userID
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "AddGroupMember",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_AddGroupMemberResponse.self
        )
    }

    /// Removes a manual group member.
    func removeGroupMember(groupID: Int64, userID: Int32, reason: String = "") async throws -> Services_Jobs_RemoveGroupMemberResponse {
        var request = Services_Jobs_RemoveGroupMemberRequest()
        request.groupID = groupID
        request.userID = userID
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "RemoveGroupMember",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_RemoveGroupMemberResponse.self
        )
    }

    /// Excludes a user from resolved group membership (upsert semantics for edits).
    func excludeGroupMember(groupID: Int64, userID: Int32, reasonType: Resources_Jobs_Groups_GroupExclusionReason, reason: String = "") async throws -> Services_Jobs_ExcludeGroupMemberResponse {
        var request = Services_Jobs_ExcludeGroupMemberRequest()
        request.groupID = groupID
        request.userID = userID
        request.reasonType = reasonType
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ExcludeGroupMember",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ExcludeGroupMemberResponse.self
        )
    }

    /// Removes a group member exclusion.
    func removeGroupMemberExclusion(groupID: Int64, userID: Int32, reason: String = "") async throws -> Services_Jobs_RemoveGroupMemberExclusionResponse {
        var request = Services_Jobs_RemoveGroupMemberExclusionRequest()
        request.groupID = groupID
        request.userID = userID
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "RemoveGroupMemberExclusion",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_RemoveGroupMemberExclusionResponse.self
        )
    }

    /// Adds a group leader.
    func addGroupLeader(groupID: Int64, userID: Int32, reason: String = "") async throws -> Services_Jobs_AddGroupLeaderResponse {
        var request = Services_Jobs_AddGroupLeaderRequest()
        request.groupID = groupID
        request.userID = userID
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "AddGroupLeader",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_AddGroupLeaderResponse.self
        )
    }

    /// Removes a group leader.
    func removeGroupLeader(groupID: Int64, userID: Int32, reason: String = "") async throws -> Services_Jobs_RemoveGroupLeaderResponse {
        var request = Services_Jobs_RemoveGroupLeaderRequest()
        request.groupID = groupID
        request.userID = userID
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "RemoveGroupLeader",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_RemoveGroupLeaderResponse.self
        )
    }

    /// Lists group membership rules.
    func listGroupRules(groupID: Int64, offset: Int64 = 0, pageSize: Int64 = 20) async throws -> Services_Jobs_ListGroupRulesResponse {
        var request = Services_Jobs_ListGroupRulesRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.groupID = groupID
        return try await call(
            service: "services.jobs.GroupsService",
            method: "ListGroupRules",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_ListGroupRulesResponse.self
        )
    }

    /// Creates a new group membership rule.
    func createGroupRule(groupID: Int64, rule: Services_Jobs_GroupRuleInput, reason: String = "") async throws -> Services_Jobs_CreateGroupRuleResponse {
        var request = Services_Jobs_CreateGroupRuleRequest()
        request.groupID = groupID
        request.rule = rule
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "CreateGroupRule",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_CreateGroupRuleResponse.self
        )
    }

    /// Updates an existing group membership rule.
    func updateGroupRule(groupID: Int64, ruleID: Int64, rule: Services_Jobs_GroupRuleInput, reason: String = "") async throws -> Services_Jobs_UpdateGroupRuleResponse {
        var request = Services_Jobs_UpdateGroupRuleRequest()
        request.groupID = groupID
        request.ruleID = ruleID
        request.rule = rule
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "UpdateGroupRule",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_UpdateGroupRuleResponse.self
        )
    }

    /// Deletes a group membership rule (requires a reason, mirrors the web).
    func deleteGroupRule(groupID: Int64, ruleID: Int64, reason: String = "") async throws -> Services_Jobs_DeleteGroupRuleResponse {
        var request = Services_Jobs_DeleteGroupRuleRequest()
        request.groupID = groupID
        request.ruleID = ruleID
        if !reason.isEmpty {
            request.reason = reason
        }
        return try await call(
            service: "services.jobs.GroupsService",
            method: "DeleteGroupRule",
            requestData: try request.serializedData(),
            responseType: Services_Jobs_DeleteGroupRuleResponse.self
        )
    }

    /// Lists group activity (Audit-like feed for a group).
    func listGroupActivity(groupID: Int64, types: [Resources_Jobs_Groups_GroupActivityType] = [], userID: Int32? = nil, from: Date? = nil, to: Date? = nil, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Jobs_ListGroupActivityResponse {
        var request = Services_Jobs_ListGroupActivityRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.groupID = groupID
        request.types = types
        if let userID {
            request.userID = userID
        }
        if let from {
            request.from = toTimestampProto(from)
        }
        if let to {
            request.to = toTimestampProto(to)
        }
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "created_at"; $0.desc = true }
        ]
        do {
            return try await call(
                service: "services.jobs.GroupsService",
                method: "ListGroupActivity",
                requestData: try request.serializedData(),
                responseType: Services_Jobs_ListGroupActivityResponse.self
            )
        } catch {
            // Server-side grpcws-transport bug (fivenet `pkg/grpc/grpcws/websocket_stream.go`
            // `GrpcStream.Write`): this RPC's response is buffered but never flushed. The exact
            // failure mode varies with response size — small responses end "Header + Complete"
            // with no body (`invalidResponse`), larger ones emit a teardown failure frame
            // (`grpcStatus(-1, "...cancel...")`). The identical call succeeds over the HTTP
            // gRPC-Web path, so fall back to it for those transport-level failures.
            guard shouldRetryListGroupActivityOverHTTP(error) else {
                print("[FiveNetClient] listGroupActivity: WS-Error wird NICHT retried: \(error)")
                throw error
            }
            print("[FiveNetClient] listGroupActivity: WS-Error \(error) -> HTTP-Fallback (task.isCancelled=\(Task.isCancelled))")
            do {
                let response = try await grpcWeb.unary(
                    service: "services.jobs.GroupsService",
                    method: "ListGroupActivity",
                    request: request,
                    responseType: Services_Jobs_ListGroupActivityResponse.self,
                    authToken: userToken,
                    cookie: accountToken
                )
                print("[FiveNetClient] listGroupActivity: HTTP-Fallback OK, activities=\(response.activity.count)")
                return response
            } catch {
                print("[FiveNetClient] listGroupActivity: HTTP-Fallback FEHLGESCHLAGEN: \(error)")
                throw error
            }
        }
    }

    /// True when a transport-level WS failure of `ListGroupActivity` should be
    /// retried over the HTTP gRPC-Web path (see comment above). Genuine business
    /// errors (Err*, i18n messages) are rethrown unchanged.
    private func shouldRetryListGroupActivityOverHTTP(_ error: Error) -> Bool {
        guard let error = error as? FiveNetError else { return false }
        switch error {
        case .invalidResponse:
            return true
        case .cancelled:
            return true
        case .grpcStatus(let code, let message):
            // WS `failure` frames carry the synthetic code -1; the grpcws teardown
            // of the unflushed stream surfaces as "cancelled"/"Canceled"/"context
            // canceled"/"rpc error: code = Canceled ..." — match on the keyword.
            return code == -1 && message.lowercased().contains("cancel")
        default:
            return false
        }
    }

    // MARK: - Settings: Leitstelle (Centrum)

    /// Fetches the centrum settings (mode, timings, status presets).
    func getCentrumSettings() async throws -> Services_Centrum_GetSettingsResponse {
        let request = Services_Centrum_GetSettingsRequest()
        return try await call(
            service: "services.centrum.CentrumService",
            method: "GetSettings",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_GetSettingsResponse.self
        )
    }

    /// Updates the centrum settings.
    func updateCentrumSettings(_ settings: Resources_Centrum_Settings_Settings) async throws -> Resources_Centrum_Settings_Settings {
        var request = Services_Centrum_UpdateSettingsRequest()
        request.settings = settings
        let response: Services_Centrum_UpdateSettingsResponse = try await call(
            service: "services.centrum.CentrumService",
            method: "UpdateSettings",
            requestData: try request.serializedData(),
            responseType: Services_Centrum_UpdateSettingsResponse.self
        )
        return response.settings
    }

    // MARK: - Settings: Gesetzbücher (Laws)

    /// Lists all law books including their laws.
    func listLawBooks() async throws -> [Resources_Laws_LawBook] {
        let request = Services_Settings_ListLawBooksRequest()
        let response: Services_Settings_ListLawBooksResponse = try await call(
            service: "services.settings.LawsService",
            method: "ListLawBooks",
            requestData: try request.serializedData(),
            responseType: Services_Settings_ListLawBooksResponse.self
        )
        return response.books
    }

    /// Creates or updates a law book.
    func createOrUpdateLawBook(_ lawBook: Resources_Laws_LawBook) async throws -> Resources_Laws_LawBook {
        var request = Services_Settings_CreateOrUpdateLawBookRequest()
        request.lawBook = lawBook
        let response: Services_Settings_CreateOrUpdateLawBookResponse = try await call(
            service: "services.settings.LawsService",
            method: "CreateOrUpdateLawBook",
            requestData: try request.serializedData(),
            responseType: Services_Settings_CreateOrUpdateLawBookResponse.self
        )
        return response.lawBook
    }

    /// Deletes a law book by id.
    func deleteLawBook(id: Int64) async throws {
        var request = Services_Settings_DeleteLawBookRequest()
        request.id = id
        _ = try await call(
            service: "services.settings.LawsService",
            method: "DeleteLawBook",
            requestData: try request.serializedData(),
            responseType: Services_Settings_DeleteLawBookResponse.self
        )
    }

    /// Creates or updates a law within a law book.
    func createOrUpdateLaw(_ law: Resources_Laws_Law) async throws -> Resources_Laws_Law {
        var request = Services_Settings_CreateOrUpdateLawRequest()
        request.law = law
        let response: Services_Settings_CreateOrUpdateLawResponse = try await call(
            service: "services.settings.LawsService",
            method: "CreateOrUpdateLaw",
            requestData: try request.serializedData(),
            responseType: Services_Settings_CreateOrUpdateLawResponse.self
        )
        return response.law
    }

    /// Deletes a law by id.
    func deleteLaw(id: Int64) async throws {
        var request = Services_Settings_DeleteLawRequest()
        request.id = id
        _ = try await call(
            service: "services.settings.LawsService",
            method: "DeleteLaw",
            requestData: try request.serializedData(),
            responseType: Services_Settings_DeleteLawResponse.self
        )
    }

    // MARK: - Settings: Datenspeicher (Filestore)

    /// Lists files stored in the filestore, optionally filtered by path.
    func listFiles(path: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Filestore_ListFilesResponse {
        var request = Services_Filestore_ListFilesRequest()
        if !path.isEmpty {
            request.path = path
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.filestore.FilestoreService",
            method: "ListFiles",
            requestData: try request.serializedData(),
            responseType: Services_Filestore_ListFilesResponse.self
        )
    }

    /// Deletes a file by its id (within the given parent directory).
    func deleteFile(parentID: Int64, fileID: Int64) async throws {
        var request = Resources_File_DeleteFileRequest()
        request.parentID = parentID
        request.fileID = fileID
        _ = try await call(
            service: "services.filestore.FilestoreService",
            method: "DeleteFile",
            requestData: try request.serializedData(),
            responseType: Resources_File_DeleteFileResponse.self
        )
    }

    /// Deletes a file by its path.
    func deleteFileByPath(path: String) async throws {
        var request = Services_Filestore_DeleteFileByPathRequest()
        request.path = path
        _ = try await call(
            service: "services.filestore.FilestoreService",
            method: "DeleteFileByPath",
            requestData: try request.serializedData(),
            responseType: Services_Filestore_DeleteFileByPathResponse.self
        )
    }

    // MARK: - Settings: Konten (Accounts)

    /// Lists user accounts (optionally filtered by username).
    func listAccounts(username: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Settings_ListAccountsResponse {
        var request = Services_Settings_ListAccountsRequest()
        if !username.isEmpty {
            request.username = username
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.settings.AccountsService",
            method: "ListAccounts",
            requestData: try request.serializedData(),
            responseType: Services_Settings_ListAccountsResponse.self
        )
    }

    /// Enables/disables an account.
    func updateAccount(id: Int64, enabled: Bool) async throws -> Resources_Accounts_Account {
        var request = Services_Settings_UpdateAccountRequest()
        request.id = id
        request.enabled = enabled
        let response: Services_Settings_UpdateAccountResponse = try await call(
            service: "services.settings.AccountsService",
            method: "UpdateAccount",
            requestData: try request.serializedData(),
            responseType: Services_Settings_UpdateAccountResponse.self
        )
        return response.account
    }

    /// Deletes an account by id.
    func deleteAccount(id: Int64) async throws {
        var request = Services_Settings_DeleteAccountRequest()
        request.id = id
        _ = try await call(
            service: "services.settings.AccountsService",
            method: "DeleteAccount",
            requestData: try request.serializedData(),
            responseType: Services_Settings_DeleteAccountResponse.self
        )
    }

    // MARK: - Settings: FiveNet-Einstellungen (Config)

    /// Fetches the server app config.
    func getAppConfig() async throws -> Resources_Settings_AppConfig {
        let request = Services_Settings_GetAppConfigRequest()
        let response: Services_Settings_GetAppConfigResponse = try await call(
            service: "services.settings.ConfigService",
            method: "GetAppConfig",
            requestData: try request.serializedData(),
            responseType: Services_Settings_GetAppConfigResponse.self
        )
        return response.config
    }

    // MARK: - Settings: Hintergrund-Aufgaben (Cron)

    /// Lists all background cron jobs.
    func listCronjobs() async throws -> [Resources_Cron_Cronjob] {
        let request = Services_Settings_ListCronjobsRequest()
        let response: Services_Settings_ListCronjobsResponse = try await call(
            service: "services.settings.CronService",
            method: "ListCronjobs",
            requestData: try request.serializedData(),
            responseType: Services_Settings_ListCronjobsResponse.self
        )
        return response.jobs
    }

    /// Manually runs a cron job.
    func runCronjob(name: String) async throws {
        var request = Services_Settings_RunCronjobRequest()
        request.name = name
        _ = try await call(
            service: "services.settings.CronService",
            method: "RunCronjob",
            requestData: try request.serializedData(),
            responseType: Services_Settings_RunCronjobResponse.self
        )
    }

    // MARK: - Qualifications (Qualifikationen)

    /// Lists qualifications, optionally filtered by search text.
    func listQualifications(search: String = "", offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Qualifications_ListQualificationsResponse {
        var request = Services_Qualifications_ListQualificationsRequest()
        if !search.isEmpty { request.search = search }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "abbreviation"; $0.desc = false }
        ]
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "ListQualifications",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_ListQualificationsResponse.self
        )
    }

    /// Fetches a single qualification.
    func getQualification(id: Int64) async throws -> Services_Qualifications_GetQualificationResponse {
        var request = Services_Qualifications_GetQualificationRequest()
        request.qualificationID = id
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "GetQualification",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_GetQualificationResponse.self
        )
    }

    /// Creates a new, empty qualification. Mirrors the web `useQualifications.createQualification`
    /// (sends `ContentType.HTML`; the web then navigates to the edit page).
    func createQualification(contentType: Resources_Common_Content_ContentType = .html) async throws -> Services_Qualifications_CreateQualificationResponse {
        var request = Services_Qualifications_CreateQualificationRequest()
        request.contentType = contentType
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "CreateQualification",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_CreateQualificationResponse.self
        )
    }

    /// Updates an existing qualification. Mirrors the web `Editor.vue.updateQualification`:
    /// the creator/creator_job are taken from the current character, the qualification
    /// carries job="", weight=0, exam_mode (default DISABLED) and the access list.
    func updateQualification(_ qualification: Resources_Qualifications_Qualification) async throws -> Services_Qualifications_UpdateQualificationResponse {
        var request = Services_Qualifications_UpdateQualificationRequest()
        request.qualification = qualification
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "UpdateQualification",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_UpdateQualificationResponse.self
        )
    }

    /// Lists qualification results (the caller's own results by default, or a
    /// specific user's via `userIds`). Mirrors the web `ResultList.vue`.
    func listQualificationsResults(qualificationID: Int64? = nil, statuses: [Resources_Qualifications_ResultStatus] = [], userIds: [Int32] = [], search: String? = nil, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Qualifications_ListQualificationsResultsResponse {
        var request = Services_Qualifications_ListQualificationsResultsRequest()
        if let qualificationID {
            request.qualificationID = qualificationID
        }
        request.status = statuses
        request.userIds = userIds
        if let search {
            request.search = search
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "abbreviation"; $0.desc = true }
        ]
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "ListQualificationsResults",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_ListQualificationsResultsResponse.self
        )
    }

    /// Lists qualification requests for a specific qualification (tutor view).
    /// Mirrors the web `RequestList.vue` in the tutor tab.
    func listQualificationRequests(qualificationID: Int64, statuses: [Resources_Qualifications_RequestStatus] = [], userIds: [Int32] = [], search: String? = nil, offset: Int64 = 0, pageSize: Int64 = 10) async throws -> Services_Qualifications_ListQualificationRequestsResponse {
        var request = Services_Qualifications_ListQualificationRequestsRequest()
        request.qualificationID = qualificationID
        request.status = statuses
        request.userIds = userIds
        if let search {
            request.search = search
        }
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.sort.columns = [
            Resources_Common_Database_SortByColumn.with { $0.id = "createdAt"; $0.desc = true }
        ]
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "ListQualificationRequests",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_ListQualificationRequestsResponse.self
        )
    }

    /// Creates or updates a qualification request (approve/deny/reopen from the
    /// tutor tab). Mirrors the web `RequestTutorModal` → `CreateOrUpdateQualificationRequest`.
    func createOrUpdateQualificationRequest(request: Resources_Qualifications_QualificationRequest) async throws -> Services_Qualifications_CreateOrUpdateQualificationRequestResponse {
        var req = Services_Qualifications_CreateOrUpdateQualificationRequestRequest()
        req.request = request
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "CreateOrUpdateQualificationRequest",
            requestData: try req.serializedData(),
            responseType: Services_Qualifications_CreateOrUpdateQualificationRequestResponse.self
        )
    }

    /// Deletes a qualification request (tutor tab trash action).
    func deleteQualificationRequest(qualificationID: Int64, userID: Int32) async throws -> Services_Qualifications_DeleteQualificationReqResponse {
        var request = Services_Qualifications_DeleteQualificationReqRequest()
        request.qualificationID = qualificationID
        request.userID = userID
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "DeleteQualificationReq",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_DeleteQualificationReqResponse.self
        )
    }

    /// Creates or updates a qualification result (grading from the tutor tab).
    /// Mirrors the web `ResultTutorForm` → `CreateOrUpdateQualificationResult`.
    func createOrUpdateQualificationResult(result: Resources_Qualifications_QualificationResult) async throws -> Services_Qualifications_CreateOrUpdateQualificationResultResponse {
        var request = Services_Qualifications_CreateOrUpdateQualificationResultRequest()
        request.result = result
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "CreateOrUpdateQualificationResult",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_CreateOrUpdateQualificationResultResponse.self
        )
    }

    /// Deletes a qualification result (tutor tab trash action).
    func deleteQualificationResult(resultID: Int64) async throws -> Services_Qualifications_DeleteQualificationResultResponse {
        var request = Services_Qualifications_DeleteQualificationResultRequest()
        request.resultID = resultID
        return try await call(
            service: "services.qualifications.QualificationsService",
            method: "DeleteQualificationResult",
            requestData: try request.serializedData(),
            responseType: Services_Qualifications_DeleteQualificationResultResponse.self
        )
    }

    // MARK: - Calendar

    /// Lists all calendars the active character can access (job calendars like
    /// HCTM, the system birthdays calendar, shared calendars, …).
    func listCalendars(offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Calendar_ListCalendarsResponse {
        var request = Services_Calendar_ListCalendarsRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        return try await call(
            service: "services.calendar.CalendarService",
            method: "ListCalendars",
            requestData: try request.serializedData(),
            responseType: Services_Calendar_ListCalendarsResponse.self
        )
    }

    /// Lists calendar entries for a specific month, optionally restricted to the
    /// given calendar ids. Birthdays and recurring entries are expanded by the
    /// server into per-occurrence entries for the requested month.
    func listCalendarEntries(year: Int32, month: Int32, calendarIds: [Int64] = []) async throws -> [Resources_Calendar_Entries_CalendarEntry] {
        var request = Services_Calendar_ListCalendarEntriesRequest()
        request.year = year
        request.month = month
        request.calendarIds = calendarIds
        let response: Services_Calendar_ListCalendarEntriesResponse = try await call(
            service: "services.calendar.EntriesService",
            method: "ListCalendarEntries",
            requestData: try request.serializedData(),
            responseType: Services_Calendar_ListCalendarEntriesResponse.self
        )
        return response.entries
    }

    /// Creates or updates a calendar entry in the given calendar.
    func createOrUpdateCalendarEntry(_ entry: Resources_Calendar_Entries_CalendarEntry, userIds: [Int32] = []) async throws -> Resources_Calendar_Entries_CalendarEntry {
        var request = Services_Calendar_CreateOrUpdateCalendarEntryRequest()
        request.entry = entry
        request.userIds = userIds
        let response: Services_Calendar_CreateOrUpdateCalendarEntryResponse = try await call(
            service: "services.calendar.EntriesService",
            method: "CreateOrUpdateCalendarEntry",
            requestData: try request.serializedData(),
            responseType: Services_Calendar_CreateOrUpdateCalendarEntryResponse.self
        )
        return response.entry
    }

    /// Deletes a calendar entry by id.
    func deleteCalendarEntry(id: Int64) async throws {
        var request = Services_Calendar_DeleteCalendarEntryRequest()
        request.entryID = id
        _ = try await call(
            service: "services.calendar.EntriesService",
            method: "DeleteCalendarEntry",
            requestData: try request.serializedData(),
            responseType: Services_Calendar_DeleteCalendarEntryResponse.self
        )
    }

    // MARK: - Mail (Mailer)

    /// Lists the email accounts the active character can access.
    func listEmails(offset: Int64 = 0, pageSize: Int64 = 50, all: Bool = false) async throws -> Services_Mailer_ListEmailsResponse {
        var request = Services_Mailer_ListEmailsRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        if all { request.all = true }
        return try await call(
            service: "services.mailer.MailerService",
            method: "ListEmails",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_ListEmailsResponse.self
        )
    }

    /// Fetches a single email account.
    func getEmail(id: Int64) async throws -> Resources_Mailer_Emails_Email {
        var request = Services_Mailer_GetEmailRequest()
        request.id = id
        let response: Services_Mailer_GetEmailResponse = try await call(
            service: "services.mailer.MailerService",
            method: "GetEmail",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_GetEmailResponse.self
        )
        return response.email
    }

    /// Email address/domain proposals for the composer (Web `GetEmailProposals`).
    func getEmailProposals(input: String) async throws -> Services_Mailer_GetEmailProposalsResponse {
        var request = Services_Mailer_GetEmailProposalsRequest()
        request.input = input
        return try await call(
            service: "services.mailer.MailerService",
            method: "GetEmailProposals",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_GetEmailProposalsResponse.self
        )
    }

    /// Lists threads for the given email accounts, optionally filtered by unread/archived.
    func listThreads(emailIds: [Int64], unread: Bool? = nil, archived: Bool? = nil, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Mailer_ListThreadsResponse {
        var request = Services_Mailer_ListThreadsRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.emailIds = emailIds
        if let unread { request.unread = unread }
        if let archived { request.archived = archived }
        return try await call(
            service: "services.mailer.ThreadService",
            method: "ListThreads",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_ListThreadsResponse.self
        )
    }

    /// Searches threads across all accessible emails, returning matching messages.
    func searchThreads(search: String, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> Services_Mailer_SearchThreadsResponse {
        var request = Services_Mailer_SearchThreadsRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.search = search
        return try await call(
            service: "services.mailer.ThreadService",
            method: "SearchThreads",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_SearchThreadsResponse.self
        )
    }

    /// Fetches a single thread (with its state for the given email account).
    func getThread(emailID: Int64, threadID: Int64) async throws -> Resources_Mailer_Threads_Thread {
        var request = Services_Mailer_GetThreadRequest()
        request.emailID = emailID
        request.threadID = threadID
        let response: Services_Mailer_GetThreadResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "GetThread",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_GetThreadResponse.self
        )
        return response.thread
    }

    /// Lists the messages of a thread, newest first (as delivered by the server).
    func listThreadMessages(emailID: Int64, threadID: Int64, offset: Int64 = 0, pageSize: Int64 = 50) async throws -> [Resources_Mailer_Messages_Message] {
        var request = Services_Mailer_ListThreadMessagesRequest()
        request.pagination.offset = offset
        request.pagination.pageSize = pageSize
        request.emailID = emailID
        request.threadID = threadID
        let response: Services_Mailer_ListThreadMessagesResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "ListThreadMessages",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_ListThreadMessagesResponse.self
        )
        return response.messages
    }

    /// Creates a new thread with an initial message. The server derives the
    /// sending email account from the authenticated character.
    func createThread(title: String, message: Resources_Mailer_Messages_Message, recipients: [String]) async throws -> Resources_Mailer_Threads_Thread {
        var request = Services_Mailer_CreateThreadRequest()
        request.thread.title = title
        request.message = message
        request.recipients = recipients
        let response: Services_Mailer_CreateThreadResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "CreateThread",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_CreateThreadResponse.self
        )
        return response.thread
    }

    /// Posts a reply message into an existing thread.
    func postMessage(message: Resources_Mailer_Messages_Message, recipients: [String] = []) async throws -> Resources_Mailer_Messages_Message {
        var request = Services_Mailer_PostMessageRequest()
        request.message = message
        request.recipients = recipients
        let response: Services_Mailer_PostMessageResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "PostMessage",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_PostMessageResponse.self
        )
        return response.message
    }

    /// Updates the per-email thread state (read/unread, archived, important,
    /// favorite, muted) and returns the persisted state.
    @discardableResult
    func setThreadState(_ state: Resources_Mailer_Threads_ThreadState) async throws -> Resources_Mailer_Threads_ThreadState {
        var request = Services_Mailer_SetThreadStateRequest()
        request.state = state
        let response: Services_Mailer_SetThreadStateResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "SetThreadState",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_SetThreadStateResponse.self
        )
        return response.state
    }

    /// Deletes a thread for the given email account.
    func deleteThread(emailID: Int64, threadID: Int64) async throws {
        var request = Services_Mailer_DeleteThreadRequest()
        request.emailID = emailID
        request.threadID = threadID
        let _: Services_Mailer_DeleteThreadResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "DeleteThread",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_DeleteThreadResponse.self
        )
    }

    /// Deletes a single message within a thread (JobAdmin).
    func deleteMessage(emailID: Int64, threadID: Int64, messageID: Int64) async throws {
        var request = Services_Mailer_DeleteMessageRequest()
        request.emailID = emailID
        request.threadID = threadID
        request.messageID = messageID
        let _: Services_Mailer_DeleteMessageResponse = try await call(
            service: "services.mailer.ThreadService",
            method: "DeleteMessage",
            requestData: try request.serializedData(),
            responseType: Services_Mailer_DeleteMessageResponse.self
        )
    }

    // MARK: - Token extraction

    /// Extracts the account JWT from the `fivenet_acc` cookie sent by the server.
    private static func extractAccountToken(from headers: [AnyHashable: Any]) -> String? {
        let value = headers["Set-Cookie"] as? String ?? headers["set-cookie"] as? String
        return cookieValue(value, name: "fivenet_acc")
    }

    private static func cookieValue(_ setCookie: String?, name: String) -> String? {
        guard let setCookie else { return nil }
        let prefix = name + "="
        for part in setCookie.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count)
            return value.split(separator: ";", maxSplits: 1).first.map(String.init)
        }
        return nil
    }
}

extension FiveNetClient {
    /// Fetches a document/media resource (e.g. `/api/filestore/<key>`) with the
    /// session's auth headers so protected media loads like in the web app.
    /// Returns `nil` when the request fails (non-2xx or network error).
    func authenticatedData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let userToken, !userToken.isEmpty {
            request.setValue("Bearer \(userToken)", forHTTPHeaderField: "Authorization")
        } else if let accountToken, !accountToken.isEmpty {
            request.setValue("fivenet_acc=\(accountToken)", forHTTPHeaderField: "Cookie")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}
