import SwiftUI
import SwiftProtobuf

/// Navigation value for a qualification detail screen (qualification module).
struct QualificationRoute: Hashable {
    let qualificationID: Int64
}

/// Formats a qualification id as `QUAL-<id>`.
func formatQualificationID(_ id: Int64) -> String {
    "QUAL-\(id)"
}

/// Qualifikationen-Modul: zwei Tabs, die die Web-Seiten
/// `qualifications/index.vue` (ResultList) und `qualifications/all.vue` (List)
/// nachbilden.
struct QualificationsView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedTab: Tab = .results

    enum Tab: String, CaseIterable, Identifiable {
        case results = "Ihre Qualifizierungen"
        case all = "Alle Qualifizierungen"

        var id: String { rawValue }
    }

    init(initialTab: QuickAccessTab? = nil) {
        if initialTab == .qualificationsAll {
            _selectedTab = State(initialValue: .all)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Ansicht", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, Theme.Spacing.md)

            switch selectedTab {
            case .results:
                QualificationResultsView()
            case .all:
                QualificationsListView()
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .pendingAlarmBell()
        .moduleNavTitle(.qualifications)
        .navConnectionDot()
    }
}

/// "Ihre Qualifizierungen": eigene erfolgreiche Qualifizierungen mit Score,
/// Ergebnis und Erstellungsdatum (Web `ResultList.vue`).
private struct QualificationResultsView: View {
    @Environment(AppState.self) private var appState

    private static let pageSize: Int64 = 10

    @State private var results: [Resources_Qualifications_QualificationResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Group {
            List {
                if let errorMessage {
                    Section {
                        StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .cardRow()
                    }
                }

                if isLoading && results.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if let errorMessage, results.isEmpty {
                    EmptyStateView(
                        "exclamationmark.triangle",
                        color: Theme.Palette.danger,
                        title: "Laden fehlgeschlagen",
                        message: errorMessage,
                        actionTitle: "Erneut versuchen"
                    ) {
                        Task { await load(reset: true) }
                    }
                } else if results.isEmpty {
                    EmptyStateView(
                        "checkmark.seal",
                        color: Theme.Palette.accent,
                        title: "Keine Qualifizierungen",
                        message: "Für dich sind noch keine erfolgreichen Qualifizierungen vorhanden."
                    )
                } else {
                Section("\(totalCount) Qualifizierungen") {
                    ForEach(results) { result in
                        NavigationLink(value: QualificationRoute(qualificationID: result.qualificationID)) {
                            QualificationResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .navigationLinkIndicatorVisibility(.hidden)
                        .cardRow()
                    }
                }
                }

                if totalPages > 1 {
                    Section("Seite \(currentPage + 1) von \(totalPages)") {
                        PaginationFooter {
                            paginationButtons
                        }
                    }
                }
            }
            .cardListStyle()
            .refreshable {
                await load(reset: true)
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await load(reset: true)
            }
        }
    }

    private var paginationButtons: some View {
        HStack {
            Button {
                Task { await load(page: currentPage - 1) }
            } label: {
                Label("Zurück", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(currentPage == 0 || isLoading)

            Spacer()

            if isLoading {
                ProgressView()
            }

            Spacer()

            Button {
                Task { await load(page: currentPage + 1) }
            } label: {
                Label("Weiter", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .disabled(currentPage + 1 >= totalPages || isLoading)
        }
    }

    private func load(page: Int64 = 0, reset: Bool = false) async {
        let target = reset ? 0 : page
        if reset { currentPage = 0 }
        let previous = currentPage
        currentPage = target
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await appState.listQualificationsResults(
                statuses: [.successful],
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            results = response.results
            totalCount = response.pagination.totalCount
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }
}

/// Eine Zeile der eigenen Qualifizierungen: Abkürzung: Titel, Punktzahl,
/// Ergebnis-Badge und Erstellungsdatum (Web `ResultListEntry.vue`).
private struct QualificationResultRow: View {
    let result: Resources_Qualifications_QualificationResult

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            GradientIconTile("checkmark.seal", gradient: FiveNetModule.qualifications.gradient, size: 44)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)

                if hasScore || !result.summary.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    ResultStatusBadge(status: result.status)
                    if result.hasCreatedAt {
                        Text("Erhalten am \(formatTimestamp(result.createdAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            QUALIDBadge(id: result.qualificationID)

            CardChevron()
                .padding(.leading, Theme.Spacing.md)
        }
        .padding(Theme.Spacing.xl)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private var title: String {
        let abbreviation = result.qualification.abbreviation
        let name = result.qualification.title
        if !abbreviation.isEmpty {
            return name.isEmpty ? abbreviation : "\(abbreviation): \(name)"
        }
        return name.isEmpty ? "Ohne Titel" : name
    }

    private var hasScore: Bool {
        result.hasScore
    }

    private var subtitle: String {
        var parts: [String] = []
        if hasScore {
            parts.append("Punktzahl: \(formatScore(result.score))")
        }
        if !result.summary.isEmpty {
            parts.append("Zusammenfassung: \(result.summary)")
        }
        return parts.joined(separator: " · ")
    }
}

/// "Qualifikationen"-Tab in der Kollegen-Ansicht: die erfolgreichen
/// Qualifizierungen des jeweiligen Kollegen (Web `ResultList.vue` mit
/// `userIds`-Filter).
struct ColleagueQualificationsView: View {
    @Environment(AppState.self) private var appState

    let userID: Int32

    private static let pageSize: Int64 = 10

    @State private var results: [Resources_Qualifications_QualificationResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Group {
            List {
                if let errorMessage {
                    Section {
                        StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .cardRow()
                    }
                }

                if isLoading && results.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if let errorMessage, results.isEmpty {
                    EmptyStateView(
                        "exclamationmark.triangle",
                        color: Theme.Palette.danger,
                        title: "Laden fehlgeschlagen",
                        message: errorMessage,
                        actionTitle: "Erneut versuchen"
                    ) {
                        Task { await load(reset: true) }
                    }
                } else if results.isEmpty {
                    EmptyStateView(
                        "checkmark.seal",
                        color: Theme.Palette.accent,
                        title: "Keine Qualifizierungen",
                        message: "Für diesen Kollegen sind keine erfolgreichen Qualifizierungen vorhanden."
                    )
                } else {
                    Section("\(totalCount) Qualifizierungen") {
                        ForEach(results) { result in
                            NavigationLink(value: QualificationRoute(qualificationID: result.qualificationID)) {
                                QualificationResultRow(result: result)
                            }
                            .buttonStyle(.plain)
                            .navigationLinkIndicatorVisibility(.hidden)
                            .cardRow()
                        }
                    }
                }

                if totalPages > 1 {
                    Section("Seite \(currentPage + 1) von \(totalPages)") {
                        PaginationFooter {
                            HStack {
                                Button {
                                    Task { await load(page: currentPage - 1) }
                                } label: {
                                    Label("Zurück", systemImage: "chevron.left")
                                }
                                .buttonStyle(.borderless)
                                .disabled(currentPage == 0 || isLoading)

                                Spacer()

                                if isLoading {
                                    ProgressView()
                                }

                                Spacer()

                                Button {
                                    Task { await load(page: currentPage + 1) }
                                } label: {
                                    Label("Weiter", systemImage: "chevron.right")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.borderless)
                                .disabled(currentPage + 1 >= totalPages || isLoading)
                            }
                        }
                    }
                }
            }
            .cardListStyle()
            .refreshable {
                await load(reset: true)
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await load(reset: true)
            }
        }
    }

    private func load(page: Int64 = 0, reset: Bool = false) async {
        let target = reset ? 0 : page
        if reset { currentPage = 0 }
        let previous = currentPage
        currentPage = target
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await appState.listQualificationsResults(
                statuses: [.successful],
                userIds: [userID],
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            results = response.results
            totalCount = response.pagination.totalCount
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }
}

/// "Alle Qualifizierungen": suchbare, paginierte Liste aller Qualifikationen
/// (Web `List.vue`).
private struct QualificationsListView: View {
    @Environment(AppState.self) private var appState

    private static let pageSize: Int64 = 10

    @State private var searchText = ""
    @State private var qualifications: [Resources_Qualifications_Qualification] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false
    @State private var searchTask: Task<Void, Never>?
    @State private var showCreate = false

    private var canCreate: Bool {
        appState.can("qualifications.QualificationsService/UpdateQualification")
    }

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Group {
            List {
                Section {
                    SectionCard {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack(spacing: Theme.Spacing.sm) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                TextField("Qualifikation suchen", text: $searchText)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                if !searchText.isEmpty {
                                    Button {
                                        searchText = ""
                                        Task { await load(reset: true) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .cardRow()
                }

                if let errorMessage {
                    Section {
                        StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .cardRow()
                    }
                }

                if isLoading && qualifications.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if let errorMessage, qualifications.isEmpty {
                    EmptyStateView(
                        "exclamationmark.triangle",
                        color: Theme.Palette.danger,
                        title: "Laden fehlgeschlagen",
                        message: errorMessage,
                        actionTitle: "Erneut versuchen"
                    ) {
                        Task { await load(reset: true) }
                    }
                } else if qualifications.isEmpty {
                    EmptyStateView(
                        "graduationcap",
                        color: Theme.Palette.accent,
                        title: "Keine Qualifikationen gefunden",
                        message: "Für diese Suche sind keine Qualifikationen vorhanden."
                    )
                } else {
                Section("\(totalCount) Qualifikationen") {
                    ForEach(qualifications) { qualification in
                        NavigationLink(value: QualificationRoute(qualificationID: qualification.id)) {
                            QualificationRow(qualification: qualification, characterJob: appState.character?.job)
                        }
                        .buttonStyle(.plain)
                        .navigationLinkIndicatorVisibility(.hidden)
                        .cardRow()
                    }
                }
                }

                if totalPages > 1 {
                    Section("Seite \(currentPage + 1) von \(totalPages)") {
                        PaginationFooter {
                            HStack {
                                Button {
                                    Task { await load(page: currentPage - 1) }
                                } label: {
                                    Label("Zurück", systemImage: "chevron.left")
                                }
                                .buttonStyle(.borderless)
                                .disabled(currentPage == 0 || isLoading)

                                Spacer()

                                if isLoading {
                                    ProgressView()
                                }

                                Spacer()

                                Button {
                                    Task { await load(page: currentPage + 1) }
                                } label: {
                                    Label("Weiter", systemImage: "chevron.right")
                                        .labelStyle(.titleAndIcon)
                                }
                                .buttonStyle(.borderless)
                                .disabled(currentPage + 1 >= totalPages || isLoading)
                            }
                        }
                    }
                }
            }
            .cardListStyle()
            .onChange(of: searchText) {
                searchTask?.cancel()
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                if query.isEmpty {
                    searchTask = Task { @MainActor in
                        await load(reset: true)
                    }
                    return
                }
                let task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await load(reset: true)
                }
                searchTask = task
            }
            .refreshable {
                await load(reset: true)
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await load(reset: true)
            }
            .toolbar {
                if canCreate {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCreate = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.title2)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                QualificationEditorSheet(qualification: nil) { _ in
                    showCreate = false
                    Task { await load(reset: true) }
                }
            }
        }
    }

    private func load(page: Int64 = 0, reset: Bool = false) async {
        let target = reset ? 0 : page
        if reset { currentPage = 0 }
        let previous = currentPage
        currentPage = target
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try await appState.listQualifications(
                search: query,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            qualifications = response.qualifications
            totalCount = response.pagination.totalCount
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }
}

/// Eine Zeile der Qualifikationsliste: Abkürzung: Titel, Beschreibung,
/// Entwurf/Öffentlich/Ergebnis-Badges (Web `ListEntry.vue`).
private struct QualificationRow: View {
    let qualification: Resources_Qualifications_Qualification
    var characterJob: String?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            GradientIconTile("graduationcap", gradient: FiveNetModule.qualifications.gradient, size: 44)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)

                    if qualification.draft {
                        DraftBadge()
                    }
                    if qualification.public {
                        Badge("Öffentlich", systemImage: "globe")
                    }
                }

                if !qualification.description_p.isEmpty {
                    Text("Beschreibung: \(qualification.description_p)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    if qualification.hasResult, qualification.result.status != .unspecified {
                        ResultStatusBadge(status: qualification.result.status)
                    }
                    if let access = ownAccessLevel {
                        Badge(access, systemImage: "lock")
                    }
                    if qualification.hasCreatedAt {
                        Text("Erstellt am \(formatTimestamp(qualification.createdAt))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            QUALIDBadge(id: qualification.id)

            CardChevron()
                .padding(.leading, Theme.Spacing.md)
        }
        .padding(Theme.Spacing.xl)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    /// Zugriffs-Level des eigenen Charakters (über dessen Beruf) auf diese
    /// Qualifikation — "Prüfung ablegen", "Benoten" etc. — als kleines Badge.
    private var ownAccessLevel: String? {
        guard let characterJob, !characterJob.isEmpty else { return nil }
        let job = qualification.access.jobs.first { $0.job == characterJob }
        guard let job else { return nil }
        return "Zugriff: \(accessLevel(job.access))"
    }

    private func accessLevel(_ level: Int32) -> String {
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

    private var title: String {
        let abbreviation = qualification.abbreviation
        if !abbreviation.isEmpty {
            return qualification.title.isEmpty ? abbreviation : "\(abbreviation): \(qualification.title)"
        }
        return qualification.title.isEmpty ? "Ohne Titel" : qualification.title
    }
}

/// Ergebnis-Badge mit Web-Farbmapping (`resultStatusToBadgeColor`):
/// successful→grün, failed→rot, sonst blau.
private struct ResultStatusBadge: View {
    let status: Resources_Qualifications_ResultStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .successful: return "Ergebnis: Erfolgreich"
        case .failed: return "Ergebnis: Fehlgeschlagen"
        case .pending: return "Ergebnis: Ausstehend"
        case .unspecified, .UNRECOGNIZED: return "Ergebnis: Unbekannt"
        }
    }

    private var color: Color {
        switch status {
        case .successful: return .green
        case .failed: return .red
        case .pending, .unspecified, .UNRECOGNIZED: return .blue
        }
    }
}

/// Kompaktes Capsule-Badge mit optionalem Symbol.
private struct Badge: View {
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

/// Entwurf-Badge (entspricht dem Web `DraftBadge`).
private struct DraftBadge: View {
    var body: some View {
        Badge("Entwurf", systemImage: "pencil")
    }
}

/// Kompaktes QUAL-ID-Badge (Web `IDCopyBadge` mit Prefix "QUAL").
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

/// Formats a score the way the web does (locale decimal separator).
private func formatScore(_ score: Float) -> String {
    score.formatted()
}


#Preview {
    NavigationStack {
        QualificationsView()
            .environment(AppState())
    }
}
