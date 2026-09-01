import SwiftUI
import SwiftProtobuf

/// Qualifikations-Detail: Header (Titel, Beschreibung, Badges, Erstellt von/am,
/// Anforderungen), Tabs „Inhalt“ und „Tutor“. Spiegelt die Web-Seite
/// `qualifications/[id]/index.vue` (View.vue) inkl. Tutor-Ansicht
/// (`tutor/TutorView.vue`).
struct QualificationDetailView: View {
    @Environment(AppState.self) private var appState

    let qualificationID: Int64

    @State private var qualification: Resources_Qualifications_Qualification?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    @State private var selectedTab: Tab = .info

    // Tutor tab data + presentation state. Hoisted here so the sheets/dialogs can
    // be attached to the root view — attaching them inside the List (as the old
    // nested QualificationTutorView did) made them auto-dismiss on first present.
    @State private var requests: [Resources_Qualifications_QualificationRequest] = []
    @State private var requestPage: Int64 = 0
    @State private var requestTotal: Int64 = 0
    @State private var isLoadingRequests = false
    @State private var requestError: String?

    @State private var results: [Resources_Qualifications_QualificationResult] = []
    @State private var resultPage: Int64 = 0
    @State private var resultTotal: Int64 = 0
    @State private var isLoadingResults = false
    @State private var resultError: String?

    @State private var requestForDelete: Resources_Qualifications_QualificationRequest?
    @State private var resultForDelete: Resources_Qualifications_QualificationResult?
    @State private var requestForStatus: Resources_Qualifications_QualificationRequest?
    @State private var gradeUser: GradeUser?
    @State private var showCreateResult = false
    @State private var showEdit = false

    @State private var requestSearch = ""
    @State private var resultSearch = ""
    @State private var requestSearchTask: Task<Void, Never>?
    @State private var resultSearchTask: Task<Void, Never>?

    private static let tutorPageSize: Int64 = 10

    /// Größere Seiten für den clientseitigen Suchfallback (weniger Round-Trips).
    private static let fetchPageSize: Int64 = 100

    enum Tab: String, CaseIterable, Identifiable {
        case info = "Inhalt"
        case tutor = "Tutor"

        var id: String { rawValue }
    }

    /// Tutor-Tab wird immer angezeigt. Der Server gate-t `ListQualificationRequests`
    /// und `ListQualificationsResults` über das Zugriffs-Level der Qualifikation
    /// (`checkQualificationAccess(GRADE)`, nicht per `can()`-Permission — die
    /// `QualificationsService`-Permissions enthalten keine Listen-Permissions).
    /// Ohne Berechtigung zeigen die beiden Listen-Sections den Serverfehler an.
    private var canGrade: Bool {
        true
    }

    var body: some View {
        List {
            if let errorMessage, qualification == nil {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.danger)
                }
            }

            if isLoading && qualification == nil {
                SkeletonDetailView()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            } else if let errorMessage, qualification == nil {
                EmptyStateView(
                    "exclamationmark.triangle",
                    color: Theme.Palette.danger,
                    title: "Laden fehlgeschlagen",
                    message: errorMessage,
                    actionTitle: "Erneut versuchen"
                ) {
                    Task { await load() }
                }
                .listRowInsets(EdgeInsets())
            } else if let qualification {
                headerSection(qualification)

                Section {
                    PillTabBar(tabs: tabs, selection: $selectedTab) { $0.rawValue }
                        .listRowInsets(EdgeInsets())
                }
                .listRowBackground(Color.clear)

                switch selectedTab {
                case .info:
                    infoSections(qualification)
                case .tutor:
                    tutorSections(qualification)
                }
            } else {
                EmptyStateView(
                    "graduationcap",
                    color: Theme.Palette.accent,
                    title: "Qualifikation nicht gefunden",
                    message: "Die angeforderte Qualifikation existiert nicht oder du hast keinen Zugriff."
                )
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(qualificationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await load()
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .task(id: selectedTab) {
            guard selectedTab == .tutor, qualification != nil else { return }
            await loadRequests(page: 0)
            await loadResults(page: 0)
        }
        .sheet(item: $requestForStatus) { request in
            QualificationRequestStatusSheet(request: request) {
                await loadRequests(page: requestPage)
            }
            .environment(appState)
        }
        .sheet(item: $gradeUser) { gradeUser in
            QualificationGradeSheet(
                qualificationID: qualificationID,
                result: nil,
                presetUserID: gradeUser.userID
            ) {
                await loadRequests(page: requestPage)
                await loadResults(page: resultPage)
            }
            .environment(appState)
        }
        .sheet(isPresented: $showCreateResult) {
            QualificationGradeSheet(
                qualificationID: qualificationID,
                result: nil,
                presetUserID: nil
            ) {
                await loadResults(page: resultPage)
            }
            .environment(appState)
        }
        .sheet(isPresented: $showEdit) {
            if let qualification {
                QualificationEditorSheet(qualification: qualification) { _ in
                    showEdit = false
                    Task { await load() }
                }
                .environment(appState)
            }
        }
        .toolbar {
            if let qualification, canEdit(qualification) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showEdit = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.body.weight(.semibold))
                    }
                }
            }
        }
        .confirmationDialog("Anfrage löschen?", isPresented: Binding(
            get: { requestForDelete != nil },
            set: { if !$0 { requestForDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                let request = requestForDelete
                requestForDelete = nil
                if let request {
                    Task { await deleteRequest(request) }
                }
            }
            Button("Abbrechen", role: .cancel) {
                requestForDelete = nil
            }
        }
        .confirmationDialog("Ergebnis löschen?", isPresented: Binding(
            get: { resultForDelete != nil },
            set: { if !$0 { resultForDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                let result = resultForDelete
                resultForDelete = nil
                if let result {
                    Task { await deleteResult(result) }
                }
            }
            Button("Abbrechen", role: .cancel) {
                resultForDelete = nil
            }
        }
    }

    private var tabs: [Tab] {
        canGrade ? Tab.allCases : [.info]
    }

    private var qualificationTitle: String {
        guard let qualification else { return "Qualifikation" }
        let abbreviation = qualification.abbreviation
        let title = qualification.title
        if !abbreviation.isEmpty {
            return title.isEmpty ? abbreviation : "\(abbreviation): \(title)"
        }
        return title.isEmpty ? "Qualifikation" : title
    }

    private func heroBadges(_ qualification: Resources_Qualifications_Qualification) -> [String] {
        var result: [String] = []
        result.append("QUAL-\(qualification.id)")
        result.append(qualification.closed ? "Geschlossen" : "Offen")
        if qualification.draft {
            result.append("Entwurf")
        }
        if qualification.public {
            result.append("Öffentlich")
        }
        result.append("Prüfung: \(examModeLabel(qualification.examMode))")
        if qualification.hasResult, qualification.result.status != .unspecified {
            result.append(resultStatusLabel(qualification.result.status))
        } else if qualification.hasRequest, qualification.request.status != .unspecified {
            result.append(requestStatusLabel(qualification.request.status))
        }
        return result
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await appState.getQualification(id: qualificationID)
            qualification = response.qualification
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection(_ qualification: Resources_Qualifications_Qualification) -> some View {
        detailHeroSection(DetailHero(
            gradient: FiveNetModule.qualifications.gradient,
            icon: FiveNetModule.qualifications.icon,
            title: qualificationTitle,
            subtitle: qualification.description_p.isEmpty ? nil : qualification.description_p,
            badges: heroBadges(qualification)
        ))

        // Anforderungen
        if !qualification.requirements.isEmpty {
            Section("Anforderungen") {
                ForEach(qualification.requirements) { requirement in
                    if requirement.hasTargetQualification {
                        NavigationLink(value: QualificationRoute(qualificationID: requirement.targetQualificationID)) {
                            HStack {
                                Image(systemName: "checkmark.seal")
                                    .foregroundStyle(
                                        requirement.targetQualification.result.status == .successful
                                            ? Theme.Palette.success : Theme.Palette.danger
                                    )
                                Text(requirementTitle(requirement))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if requirement.targetQualification.hasResult {
                                    Text(resultShortLabel(requirement.targetQualification.result.status))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(resultShortColor(requirement.targetQualification.result.status))
                                }
                            }
                        }
                    } else {
                        Label(requirementTitle(requirement), systemImage: "checkmark.seal")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
        }
    }

    private func requirementTitle(_ requirement: Resources_Qualifications_QualificationRequirement) -> String {
        let abbreviation = requirement.targetQualification.abbreviation
        let title = requirement.targetQualification.title
        if !abbreviation.isEmpty {
            return title.isEmpty ? abbreviation : "\(abbreviation): \(title)"
        }
        return title.isEmpty ? "Qualifikation \(requirement.targetQualificationID)" : title
    }

    // MARK: - Inhalt

    @ViewBuilder
    private func infoSections(_ qualification: Resources_Qualifications_Qualification) -> some View {
        // Bewertung läuft noch (Web RequestStatus.EXAM_GRADING)
        if qualification.request.status == .examGrading {
            Section {
                Label("Bewertung läuft noch …", systemImage: "clock")
                    .foregroundStyle(Theme.Palette.info)
            }
        }

        Section("Inhalt") {
            if qualification.hasContent {
                WikiContentView(content: qualification.content)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } else {
                Label("Kein Inhalt verfügbar", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }

        if qualification.hasResult {
            Section("Ergebnis") {
                qualificationResultInfo(qualification.result)
            }
        }

        if qualification.hasRequest {
            Section("Anfrage") {
                qualificationRequestInfo(qualification.request)
            }
        }

        Section("Zugriff") {
            if qualification.hasAccess {
                if qualification.access.jobs.isEmpty && qualification.access.users.isEmpty {
                    Label("Keine Zugriffe festgelegt", systemImage: "lock")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(qualification.access.jobs, id: \.id) { job in
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(jobLabel(job))
                                    .font(.subheadline)
                                Text(accessLevelLabel(job.access))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if job.required {
                                QualificationBadge("erforderlich")
                            }
                        }
                    }
                    ForEach(qualification.access.users, id: \.id) { userAccess in
                        if userAccess.hasUser {
                            NavigationLink(value: ColleagueRoute(userID: userAccess.user.userID)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                        Text(userShortName(userAccess.user))
                                            .font(.subheadline)
                                        Text(accessLevelLabel(userAccess.access))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if userAccess.required {
                                        QualificationBadge("erforderlich")
                                    }
                                }
                            }
                        } else {
                            HStack {
                                Spacer()
                                if userAccess.required {
                                    QualificationBadge("erforderlich")
                                }
                            }
                        }
                    }
                }
            } else {
                Label("Keine Zugriffe festgelegt", systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func qualificationResultInfo(_ result: Resources_Qualifications_QualificationResult) -> some View {
        infoRow("Ergebnis", resultStatusLabel(result.status), color: resultStatusColor(result.status))
        if result.hasScore {
            infoRow("Punktzahl", formatScore(result.score))
        }
        if !result.summary.isEmpty {
            infoRow("Zusammenfassung", result.summary)
        }
        if result.hasCreator {
            NavigationLink(value: ColleagueRoute(userID: result.creator.userID)) {
                HStack(alignment: .top) {
                    Text("Erstellt von")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(creatorTitle(result.creator))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        if result.hasCreator {
            HStack(alignment: .top) {
                Text("Erhalten von")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(creatorTitle(result.creator))
                    .multilineTextAlignment(.trailing)
            }
        }
        if result.hasCreatedAt {
            infoRow("Erhalten am", formatTimestamp(result.createdAt))
        }
    }

    @ViewBuilder
    private func qualificationRequestInfo(_ request: Resources_Qualifications_QualificationRequest) -> some View {
        infoRow("Status", requestStatusLabel(request.status), color: requestStatusColor(request.status))
        if request.hasUserComment, !request.userComment.isEmpty {
            infoRow("Nachricht", request.userComment)
        }
        if request.hasApproverComment, !request.approverComment.isEmpty {
            infoRow("Kommentar", request.approverComment)
        }
        if request.hasApprovedAt {
            infoRow("Genehmigt am", formatTimestamp(request.approvedAt))
        }
        if request.hasApprover {
            NavigationLink(value: ColleagueRoute(userID: request.approver.userID)) {
                HStack {
                    Text("Genehmigt von")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(userShortName(request.approver))
                }
            }
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(color ?? Color.primary)
        }
    }

    // MARK: - Label helpers

    /// "Name" inkl. Rang (Berufs-Rang-Label) und Job, falls vorhanden.
    private func creatorTitle(_ user: Resources_Users_Short_UserShort) -> String {
        var parts = [userShortName(user)]
        if user.hasJobGradeLabel, !user.jobGradeLabel.isEmpty {
            parts.append(user.jobGradeLabel)
        } else if user.hasJobLabel, !user.jobLabel.isEmpty {
            parts.append(user.jobLabel)
        }
        return parts.joined(separator: " · ")
    }

    private func jobLabel(_ job: Resources_Access_JobAccess) -> String {
        var parts: [String] = []
        if job.hasJobLabel, !job.jobLabel.isEmpty {
            parts.append(job.jobLabel)
        } else if !job.job.isEmpty {
            parts.append(job.job)
        }
        if job.hasJobGradeLabel, !job.jobGradeLabel.isEmpty {
            parts.append(job.jobGradeLabel)
        }
        return parts.isEmpty ? "Beruf \(job.job)" : parts.joined(separator: " - ")
    }

    private func accessLevelLabel(_ level: Int32) -> String {
        switch level {
        case 0: return "Nicht festgelegt"
        case 1: return "Blockiert"
        case 2: return "Ansehen"
        case 3: return "Anfragen"
        case 4: return "Prüfung ablegen"
        case 5: return "Benoten"
        case 6: return "Bearbeiten"
        default: return "Stufe \(level)"
        }
    }

    // MARK: - Tutor tab

    /// Tutor-Ansicht der Qualifikation: zwei Sektionen „Anfragen“ und „Ergebnisse“
    /// mit Schnellaktionen (Web `tutor/TutorView.vue`).
    @ViewBuilder
    private func tutorSections(_ qualification: Resources_Qualifications_Qualification) -> some View {
        Section("Anfragen") {
            tutorSearchField($requestSearch, prompt: "Nach Kollegen suchen")
                .onChange(of: requestSearch) { _, _ in
                    debounceRequestSearch()
                }

            if let requestError {
                Label(requestError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.danger)
            }

            if isLoadingRequests && requests.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if requests.isEmpty, requestError == nil {
                Label("Keine Anfragen vorhanden", systemImage: "mail")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(requests) { request in
                    TutorRequestRow(
                        request: request,
                        canEdit: canEditTutor(qualification),
                        onDeny: { requestForStatus = request },
                        onGrade: { gradeUser = GradeUser(userID: request.userID) },
                        onDelete: { requestForDelete = request }
                    )
                }
            }

            if requestTotal > 0, requestTotal > Self.tutorPageSize {
                HStack {
                    Button {
                        Task { await loadRequests(page: requestPage - 1) }
                    } label: {
                        Label("Zurück", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(requestPage == 0 || isLoadingRequests)

                    Spacer()

                    if isLoadingRequests {
                        ProgressView()
                    }

                    Spacer()

                    Button {
                        Task { await loadRequests(page: requestPage + 1) }
                    } label: {
                        Label("Weiter", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .disabled((requestPage + 1) * Self.tutorPageSize >= requestTotal || isLoadingRequests)
                }
            }
        }

        Section {
            HStack {
                Text("Ergebnisse")
                    .font(.headline)
                Spacer()
                Button {
                    showCreateResult = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Ergebnis hinzufügen")
            }
            .listRowSeparator(.hidden)

            tutorSearchField($resultSearch, prompt: "Nach Kollegen suchen")
                .onChange(of: resultSearch) { _, _ in
                    debounceResultSearch()
                }
        }
        Section {
            if let resultError {
                Label(resultError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.danger)
            }

            if isLoadingResults && results.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if results.isEmpty, resultError == nil {
                Label("Keine Ergebnisse vorhanden", systemImage: "list.status")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { result in
                    TutorResultRow(
                        result: result,
                        canEdit: canEditTutor(qualification),
                        onDelete: { resultForDelete = result }
                    )
                }
            }

            if resultTotal > 0, resultTotal > Self.tutorPageSize {
                HStack {
                    Button {
                        Task { await loadResults(page: resultPage - 1) }
                    } label: {
                        Label("Zurück", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .disabled(resultPage == 0 || isLoadingResults)

                    Spacer()

                    if isLoadingResults {
                        ProgressView()
                    }

                    Spacer()

                    Button {
                        Task { await loadResults(page: resultPage + 1) }
                    } label: {
                        Label("Weiter", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderless)
                    .disabled((resultPage + 1) * Self.tutorPageSize >= resultTotal || isLoadingResults)
                }
            }
        }
    }

    private func loadRequests(page: Int64) async {
        guard qualification != nil else { return }
        requestPage = page
        isLoadingRequests = true
        requestError = nil
        defer { isLoadingRequests = false }
        do {
            let trimmed = requestSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let (rows, total) = try await fetchRequests(term: trimmed, page: page)
            requests = rows
            requestTotal = total
        } catch {
            requestError = error.localizedDescription
        }
    }

    /// Fetcht eine Seite der Anfragen. Ohne Suchbegriff wird die echte
    /// Server-Pagination genutzt; bei aktivem Suchbegriff liest ein Fallback die
    /// gesamte (unaufgeteilte) Menge aus, weil Server < v2026.8.5 den `search`-Filter
    /// ignorieren — und filtert clientseitig (Web `RequestList.vue` sucht über Name).
    private func fetchRequests(term: String, page: Int64) async throws -> ([Resources_Qualifications_QualificationRequest], Int64) {
        guard let qualification else { return ([], 0) }
        let lowered = term.lowercased()
        let response = try await appState.listQualificationRequests(
            qualificationID: qualification.id,
            search: lowered.isEmpty ? nil : lowered,
            offset: page * Self.tutorPageSize,
            pageSize: Self.tutorPageSize
        )
        guard !lowered.isEmpty else {
            return (response.requests, response.pagination.totalCount)
        }
        // Clientseitiger Suchfallback über alle Seiten.
        var matching: [Resources_Qualifications_QualificationRequest] = []
        var offset: Int64 = 0
        var iterations = 0
        let cap: Int64 = 5000
        while offset < cap && iterations < 100 {
            let batch = try await appState.listQualificationRequests(
                qualificationID: qualification.id,
                search: nil,
                offset: offset,
                pageSize: Self.fetchPageSize
            )
            matching += batch.requests.filter { requestMatchesSearch($0, term: lowered) }
            if batch.requests.count < Self.fetchPageSize { break }
            offset += Int64(batch.requests.count)
            iterations += 1
        }
        let start = Int(page * Self.tutorPageSize)
        let window = Array(matching.dropFirst(start).prefix(Int(Self.tutorPageSize)))
        return (window, Int64(matching.count))
    }

    private func loadResults(page: Int64) async {
        guard qualification != nil else { return }
        resultPage = page
        isLoadingResults = true
        resultError = nil
        defer { isLoadingResults = false }
        do {
            let trimmed = resultSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            let (rows, total) = try await fetchResults(term: trimmed, page: page)
            results = rows
            resultTotal = total
        } catch {
            resultError = error.localizedDescription
        }
    }

    /// Wie `fetchRequests(term:page:)`, nur für Ergebnisse.
    private func fetchResults(term: String, page: Int64) async throws -> ([Resources_Qualifications_QualificationResult], Int64) {
        guard let qualification else { return ([], 0) }
        let lowered = term.lowercased()
        let response = try await appState.listQualificationsResults(
            qualificationID: qualification.id,
            search: lowered.isEmpty ? nil : lowered,
            offset: page * Self.tutorPageSize,
            pageSize: Self.tutorPageSize
        )
        guard !lowered.isEmpty else {
            return (response.results, response.pagination.totalCount)
        }
        var matching: [Resources_Qualifications_QualificationResult] = []
        var offset: Int64 = 0
        var iterations = 0
        let cap: Int64 = 5000
        while offset < cap && iterations < 100 {
            let batch = try await appState.listQualificationsResults(
                qualificationID: qualification.id,
                search: nil,
                offset: offset,
                pageSize: Self.fetchPageSize
            )
            matching += batch.results.filter { resultMatchesSearch($0, term: lowered) }
            if batch.results.count < Self.fetchPageSize { break }
            offset += Int64(batch.results.count)
            iterations += 1
        }
        let start = Int(page * Self.tutorPageSize)
        let window = Array(matching.dropFirst(start).prefix(Int(Self.tutorPageSize)))
        return (window, Int64(matching.count))
    }

    private func requestMatchesSearch(_ request: Resources_Qualifications_QualificationRequest, term: String) -> Bool {
        if request.hasUser, matches(term: term, user: request.user) { return true }
        return String(request.userID).contains(term) || request.userComment.lowercased().contains(term)
    }

    private func resultMatchesSearch(_ result: Resources_Qualifications_QualificationResult, term: String) -> Bool {
        if result.hasUser, matches(term: term, user: result.user) { return true }
        return String(result.userID).contains(term) || result.summary.lowercased().contains(term)
    }

    private func matches(term: String, user: Resources_Users_Short_UserShort) -> Bool {
        userShortName(user).lowercased().contains(term)
            || user.firstname.lowercased().contains(term)
            || user.lastname.lowercased().contains(term)
            || String(user.userID).contains(term)
    }

    private func tutorSearchField(_ text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func debounceRequestSearch() {
        requestSearchTask?.cancel()
        requestSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await loadRequests(page: 0)
        }
    }

    private func debounceResultSearch() {
        resultSearchTask?.cancel()
        resultSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await loadResults(page: 0)
        }
    }

    private func deleteRequest(_ request: Resources_Qualifications_QualificationRequest) async {
        do {
            _ = try await appState.deleteQualificationRequest(
                qualificationID: request.qualificationID,
                userID: request.userID
            )
            await loadRequests(page: requestPage)
        } catch {
            requestError = error.localizedDescription
        }
    }

    private func deleteResult(_ result: Resources_Qualifications_QualificationResult) async {
        do {
            _ = try await appState.deleteQualificationResult(resultID: result.id)
            await loadResults(page: resultPage)
        } catch {
            resultError = error.localizedDescription
        }
    }

    /// Ob eine Anfrage/Ergebnis-Zeile im Tutor-Tab gelöscht werden darf. Der
    /// Server gate-t Delete-Aktionen über das Zugriffs-Level EDIT (Web
    /// `checkQualificationAccess(..., AccessLevel.EDIT)` ohne Permission — die
    /// `QualificationsService`-Permissions enthalten keine Request-/Result-
    /// Listen-Permissions).
    private func canEditTutor(_ qualification: Resources_Qualifications_Qualification) -> Bool {
        Self.checkQualificationAccess(
            access: qualification.hasAccess ? qualification.access : nil,
            creator: qualification.creator,
            level: 6,
            creatorJob: qualification.creatorJob,
            character: appState.character
        )
    }

    /// Ob die Qualifikation bearbeitet werden darf (Edit-Button). Web-`View.vue`
    /// (`Z. 125–133`): `can('qualifications.QualificationsService/UpdateQualification')`
    /// && `checkQualificationAccess(access, creator, AccessLevel.EDIT, creatorJob)`.
    private func canEdit(_ qualification: Resources_Qualifications_Qualification) -> Bool {
        guard appState.can("qualifications.QualificationsService/UpdateQualification") else { return false }
        return Self.checkQualificationAccess(
            access: qualification.hasAccess ? qualification.access : nil,
            creator: qualification.creator,
            level: 6,
            creatorJob: qualification.creatorJob,
            character: appState.character
        )
    }

    /// Replikat der Web-`checkAccess` (app/utils/acl.ts) für Qualifikationen:
    /// Ersteller-Bypass (gleicher User + Job), dann Zugriffsliste (users/jobs).
    /// Die Zugriffs-`qualifications`-Sektion wird auf iOS nicht ausgewertet
    /// (das generierte Proto enthält kein verschachteltes QualificationShort).
    private static func checkQualificationAccess(
        access: Resources_Access_Access?,
        creator: Resources_Users_Short_UserShort?,
        level: Int32,
        creatorJob: String?,
        character: Resources_Users_User?
    ) -> Bool {
        guard let character else { return false }
        guard let creator else { return false }
        if character.userID == creator.userID, character.job == (creatorJob ?? creator.job) {
            return true
        }
        guard let access else { return false }
        for userAccess in access.users where userAccess.userID == character.userID && level <= userAccess.access {
            return true
        }
        var lowestAccess: Int32?
        for job in access.jobs where job.job == character.job && job.minimumGrade <= character.jobGrade && job.access >= level {
            lowestAccess = min(lowestAccess ?? Int32.max, job.access)
        }
        if let lowestAccess, level <= lowestAccess {
            return true
        }
        return false
    }
}

/// Identifiable-Wrapper für die Bürger-Suche im Benoten-Sheet (`Int32`-userID).
private struct GradeUser: Identifiable {
    let userID: Int32
    var id: Int32 { userID }
}

// MARK: - Tutor

// MARK: - Tutor rows

/// Anfragen-Zeile: Kopfzeile mit Bürger + Aktions-Buttons rechts (Ablehnen,
/// Benoten), dann Kommentar, Status, Angefragt/Genehmigt am, Genehmiger.
/// Löschen ist eine Swipe-Action nach links (wie Wiki-Pin nach rechts).
/// Spiegelt die Web-`RequestList.vue`-Spalten in vertikaler Reihenfolge.
private struct TutorRequestRow: View {
    let request: Resources_Qualifications_QualificationRequest
    let canEdit: Bool
    var onDeny: () -> Void
    var onGrade: () -> Void
    var onDelete: () -> Void

    var body: some View {
        NavigationLink(value: ColleagueRoute(userID: request.user.userID)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(userShortName(request.user))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if request.hasUserComment, !request.userComment.isEmpty {
                            Text(request.userComment)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Spacer()

                    HStack(spacing: Theme.Spacing.md) {
                        if request.status != .denied {
                            Button {
                                onDeny()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(Theme.Palette.warning)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Ablehnen")
                        }
                        if request.status == .accepted || request.status == .examGrading {
                            Button {
                                onGrade()
                            } label: {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 13))
                                    .frame(width: 28, height: 28)
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Benoten")
                        }
                    }
                }

                HStack(spacing: Theme.Spacing.sm) {
                    QualificationRequestStatusBadge(status: request.status)
                }

                if request.hasCreatedAt {
                    Text("Angefragt am \(formatTimestamp(request.createdAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if request.hasApprovedAt {
                    Text("Genehmigt am \(formatTimestamp(request.approvedAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if request.hasApprover {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Genehmiger:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(userShortName(request.approver))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
    }
}

/// Ergebnisse-Zeile: Kopfzeile mit Bürger (qualifizierter Kollege), dann Status,
/// Punktzahl, Zusammenfassung, Erhalten am, Ersteller.
/// Löschen ist eine Swipe-Action nach links.
/// Spiegelt die Web-`ResultList.vue`-Spalten in vertikaler Reihenfolge.
private struct TutorResultRow: View {
    let result: Resources_Qualifications_QualificationResult
    let canEdit: Bool
    var onDelete: () -> Void

    var body: some View {
        NavigationLink(value: ColleagueRoute(userID: result.user.userID)) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(userShortName(result.user))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                QualificationResultStatusBadge(status: result.status)

                if result.hasScore {
                    Text("Ergebnis: \(formatScore(result.score)) Punkte")
                        .font(.subheadline)
                }

                if !result.summary.isEmpty {
                    Text(result.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if result.hasCreatedAt {
                    Text("Erhalten am \(formatTimestamp(result.createdAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if result.hasCreator {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("Ersteller:")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(userShortName(result.creator))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
        .swipeActions(edge: .trailing) {
            if canEdit {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            }
        }
    }
}

// MARK: - Sheets

/// Sheet zum Statuswechsel einer Anfrage (Ablehnen/Akzeptieren) mit optionalem
/// Genehmiger-Kommentar. Spiegelt die Web-`RequestTutorModal.vue`.
private struct QualificationRequestStatusSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let request: Resources_Qualifications_QualificationRequest
    var onSaved: () async -> Void

    @State private var status: Resources_Qualifications_RequestStatus = .denied
    @State private var approverComment = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let availableStatuses: [Resources_Qualifications_RequestStatus] = [
        .accepted, .denied, .pending,
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(availableStatuses, id: \.rawValue) { status in
                            Text(requestStatusLabel(status)).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Nachricht") {
                    TextField("Kommentar des Genehmigers …", text: $approverComment, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            .navigationTitle("Anfrage bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var updated = request
            updated.status = status
            updated.approverComment = approverComment
            _ = try await appState.createOrUpdateQualificationRequest(request: updated)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet zum Benoten/Anlegen eines Ergebnisses (Bürger, Status, Punktzahl,
/// Zusammenfassung). Spiegelt die Web-`ResultTutorForm.vue`: ohne `presetUserID`
/// muss ein Bürger gewählt werden, Status/Score/Summary sind Pflicht.
private struct QualificationGradeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let qualificationID: Int64
    let result: Resources_Qualifications_QualificationResult?
    var presetUserID: Int32?
    var onSaved: () async -> Void

    @State private var status: Resources_Qualifications_ResultStatus = .successful
    @State private var score: Double = 0
    @State private var summary = ""
    @State private var targetUser: Resources_Users_Short_UserShort?
    @State private var targetSearch = ""
    @State private var targetResults: [Resources_Users_Short_UserShort] = []
    @State private var isSearchingTarget = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let availableStatuses: [Resources_Qualifications_ResultStatus] = [
        .successful, .failed, .pending,
    ]

    /// True, wenn kein Ziel-Bürger vorgegeben ist (manuelles Anlegen ohne Anfrage).
    private var needsUserSelection: Bool {
        result == nil && presetUserID == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if needsUserSelection {
                    Section("Bürger") {
                        if let targetUser {
                            HStack {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(userShortName(targetUser))
                                        .font(.subheadline.weight(.medium))
                                    Text("CIT-\(targetUser.userID)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    self.targetUser = nil
                                    targetSearch = ""
                                    targetResults = []
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                            }
                        } else {
                            TextField("Bürger suchen …", text: $targetSearch)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            if isSearchingTarget {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                    Spacer()
                                }
                            }

                            if !targetResults.isEmpty {
                                ForEach(targetResults) { user in
                                    Button {
                                        targetUser = user
                                        targetResults = []
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                                Text(userShortName(user))
                                                    .font(.subheadline)
                                                    .foregroundStyle(.primary)
                                                if !user.jobLabel.isEmpty {
                                                    Text(user.jobLabel)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Text("CIT-\(user.userID)")
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }

                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(availableStatuses, id: \.rawValue) { status in
                            Text(resultStatusLabel(status)).tag(status)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Punktzahl") {
                    HStack {
                        TextField("Punktzahl", value: $score, format: .number)
                            .keyboardType(.decimalPad)
                        Text("/ 1000")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Zusammenfassung") {
                    TextField("Zusammenfassung …", text: $summary, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            .navigationTitle(result == nil ? "Ergebnis erstellen" : "Ergebnis benoten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Absenden") {
                        Task { await save() }
                    }
                    .disabled(isSaving || !canSubmit)
                }
            }
            .onChange(of: targetSearch) {
                searchTask?.cancel()
                let query = targetSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    targetResults = []
                    isSearchingTarget = false
                    return
                }
                let task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    isSearchingTarget = true
                    defer { isSearchingTarget = false }
                    let results = (try? await appState.completeCitizens(search: query)) ?? []
                    guard !Task.isCancelled else { return }
                    targetResults = results
                }
                searchTask = task
            }
            .task {
                if let presetUserID {
                    targetSearch = String(presetUserID)
                    let results = (try? await appState.completeCitizens(search: "", userIds: [presetUserID])) ?? []
                    targetUser = results.first
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var canSubmit: Bool {
        guard !needsUserSelection || targetUser != nil else { return false }
        return true
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var updated = result ?? Resources_Qualifications_QualificationResult()
            updated.qualificationID = qualificationID
            updated.status = status
            updated.score = Float(score)
            updated.summary = summary
            if let result {
                updated.id = result.id
                updated.userID = result.userID
            } else if let presetUserID {
                updated.userID = presetUserID
            } else if let targetUser {
                updated.userID = targetUser.userID
            }
            // The server validates `result.creator_id > 0` on creation (Web
            // `ResultTutorForm.vue` sends `creatorId: activeChar.userId`).
            if result == nil, let creatorID = appState.activeCharacterUserID {
                updated.creatorID = creatorID
            }
            _ = try await appState.createOrUpdateQualificationResult(result: updated)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Badges

/// QUAL-ID-Badge (Web `IDCopyBadge` mit Prefix "QUAL").
private struct QUALIDBadge: View {
    let id: Int64

    var body: some View {
        Text(verbatim: formatQualificationID(id))
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// Geschlossen-Badge.
private struct OpenClosedBadgeView: View {
    let closed: Bool

    var body: some View {
        if closed {
            QualificationBadge("Geschlossen", systemImage: "lock.fill")
        }
    }
}

/// Entwurf-Badge.
private struct QualificationDraftBadge: View {
    var body: some View {
        QualificationBadge("Entwurf", systemImage: "pencil")
    }
}

/// Kompaktes Capsule-Badge mit optionalem Symbol.
private struct QualificationBadge: View {
    let text: String
    var systemImage: String? = nil

    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(.secondary.opacity(0.15), in: Capsule())
        .foregroundStyle(.secondary)
    }
}

/// Anfrage-Status-Badge mit Web-Farbmapping (`requestStatusToBadgeColor`):
/// accepted/completed→grün, denied→rot, sonst blau.
private struct QualificationRequestStatusBadge: View {
    let status: Resources_Qualifications_RequestStatus

    var body: some View {
        Text(requestStatusLabel(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .accepted, .completed: return .green
        case .denied: return .red
        case .pending, .examStarted, .examGrading, .unspecified, .UNRECOGNIZED: return .blue
        }
    }
}

/// Ergebnis-Badge mit Web-Farbmapping (`resultStatusToBadgeColor`):
/// successful→grün, failed→rot, sonst blau.
private struct QualificationResultStatusBadge: View {
    let status: Resources_Qualifications_ResultStatus

    var body: some View {
        Text(resultStatusLabel(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .successful: return .green
        case .failed: return .red
        case .pending, .unspecified, .UNRECOGNIZED: return .blue
        }
    }
}

// MARK: - Global label helpers

func requestStatusLabel(_ status: Resources_Qualifications_RequestStatus) -> String {
    switch status {
    case .unspecified: return "Unbekannt"
    case .pending: return "Ausstehend"
    case .denied: return "Abgelehnt"
    case .accepted: return "Akzeptiert"
    case .examStarted: return "Prüfung gestartet"
    case .examGrading: return "Bewertung läuft"
    case .completed: return "Abgeschlossen"
    case .UNRECOGNIZED: return "Unbekannt"
    }
}

func requestStatusColor(_ status: Resources_Qualifications_RequestStatus) -> Color {
    switch status {
    case .accepted, .completed: return .green
    case .denied: return .red
    case .pending, .examStarted, .examGrading, .unspecified, .UNRECOGNIZED: return .blue
    }
}

func resultStatusLabel(_ status: Resources_Qualifications_ResultStatus) -> String {
    switch status {
    case .unspecified: return "Unbekannt"
    case .pending: return "Ausstehend"
    case .failed: return "Fehlgeschlagen"
    case .successful: return "Erfolgreich"
    case .UNRECOGNIZED: return "Unbekannt"
    }
}

func resultStatusColor(_ status: Resources_Qualifications_ResultStatus) -> Color {
    switch status {
    case .successful: return .green
    case .failed: return .red
    case .pending, .unspecified, .UNRECOGNIZED: return .blue
    }
}

private func resultShortLabel(_ status: Resources_Qualifications_ResultStatus) -> String {
    switch status {
    case .successful: return "Bestanden"
    case .failed: return "Nicht bestanden"
    default: return "Ausstehend"
    }
}

private func resultShortColor(_ status: Resources_Qualifications_ResultStatus) -> Color {
    switch status {
    case .successful: return .green
    case .failed: return .red
    default: return .blue
    }
}

private func examModeLabel(_ mode: Resources_Qualifications_Exam_QualificationExamMode) -> String {
    switch mode {
    case .unspecified: return "Unbekannt"
    case .disabled: return "Deaktiviert"
    case .requestNeeded: return "Anfrage nötig"
    case .enabled: return "Aktiviert"
    case .UNRECOGNIZED: return "Unbekannt"
    }
}

private func formatScore(_ score: Float) -> String {
    score.formatted()
}
