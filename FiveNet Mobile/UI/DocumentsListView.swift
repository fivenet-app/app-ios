import SwiftUI
import SwiftProtobuf

/// Documents module: searchable list of documents with category filters,
/// open/closed state, and page-based pagination.
struct DocumentsListView: View {
    @Environment(AppState.self) private var appState

    private static let pageSize: Int64 = 20

    @State private var searchText = ""
    @State private var documents: [Resources_Documents_DocumentShort] = []
    @State private var categories: [Resources_Documents_Category_Category] = []
    @State private var selectedCategoryID: Int64?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false
    @State private var categoriesLoaded = false
    @State private var showCreateSheet = false
    @State private var createdDocumentID: Int64?
    @State private var showCreatedDocument = false

    private var totalCountKnown: Bool { totalCount >= 0 }

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    private var canGoNext: Bool {
        if totalCountKnown {
            return currentPage + 1 < totalPages
        }
        return documents.count == Self.pageSize
    }

    private var canGoLast: Bool {
        totalCountKnown && totalPages > 1 && currentPage + 1 < totalPages
    }

    /// Page turner only makes sense with more than one page of results.
    /// When the total count is unknown, a full page hints at more content.
    private var hasMultiplePages: Bool {
        if totalCountKnown {
            return totalPages > 1
        }
        return documents.count == Self.pageSize
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

                if !categories.isEmpty {
                    Section("Kategorien") {
                        SectionCard {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Theme.Spacing.md) {
                                    categoryChip(id: nil, label: "Alle")
                                    ForEach(categories) { category in
                                        categoryChip(id: category.id, label: category.name)
                                    }
                                }
                                .padding(.vertical, Theme.Spacing.xs)
                            }
                        }
                        .cardRow()
                    }
                }

                if isLoading && documents.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if let errorMessage, documents.isEmpty {
                    EmptyStateView(
                        "exclamationmark.triangle",
                        color: Theme.Palette.danger,
                        title: "Laden fehlgeschlagen",
                        message: errorMessage,
                        actionTitle: "Erneut versuchen"
                    ) {
                        Task { await load(reset: true) }
                    }
                } else if documents.isEmpty {
                    EmptyStateView(
                        "doc.text",
                        color: Theme.Palette.accent,
                        title: "Keine Dokumente gefunden",
                        message: "Für diese Suche sind keine Dokumente vorhanden."
                    )
                } else {
                    Section(resultCountText) {
                        ForEach(documents) { document in
                            NavigationLink(value: DocumentRoute(documentID: document.id)) {
                                DocumentRow(document: document)
                            }
                            .buttonStyle(.plain)
                            .navigationLinkIndicatorVisibility(.hidden)
                            .cardRow()
                        }
                    }

                    if hasMultiplePages {
                        Section(pageHeaderText) {
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

                                    if canGoLast {
                                        Button {
                                            Task { await load(page: totalPages - 1) }
                                        } label: {
                                            Text("Letzte")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isLoading)
                                    }

                                    Button {
                                        Task { await load(page: currentPage + 1) }
                                    } label: {
                                        Label("Weiter", systemImage: "chevron.right")
                                            .labelStyle(.titleAndIcon)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(!canGoNext || isLoading)
                                }
                            }
                        }
                    }
                }
            }
            .cardListStyle()
            .searchable(text: $searchText, prompt: "Titel, Inhalt oder DOC-ID suchen")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onChange(of: searchText) {
                Task { await load(reset: true) }
            }
            .onChange(of: selectedCategoryID) {
                Task { await load(reset: true) }
            }
            .refreshable {
                await load(reset: true)
            }
            .pendingAlarmBell()
            .moduleNavTitle(.documents)
            .navConnectionDot()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Dokument erstellen", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                CreateDocumentSheet { id in
                    createdDocumentID = id
                    showCreatedDocument = true
                }
            }
            .onChange(of: showCreateSheet) {
                if !showCreateSheet {
                    Task { await load(reset: true) }
                }
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await loadCategories()
                await load(reset: true)
            }
        }
        .navigationDestination(for: DocumentRoute.self) { route in
            DocumentDetailView(documentID: route.documentID)
        }
        .navigationDestination(isPresented: $showCreatedDocument) {
            if let createdDocumentID {
                DocumentDetailView(documentID: createdDocumentID)
            }
        }
    }

    private var resultCountText: String {
        if totalCountKnown {
            return "\(totalCount) Dokumente gefunden"
        }
        return "\(documents.count) Dokumente"
    }

    private var pageHeaderText: String {
        if totalCountKnown {
            return "Seite \(currentPage + 1) von \(totalPages)"
        }
        return "Seite \(currentPage + 1)"
    }

    private func categoryChip(id: Int64?, label: String) -> some View {
        let isSelected = selectedCategoryID == id
        return Button {
            selectedCategoryID = id
        } label: {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.sm)
                .background(isSelected ? Theme.Palette.accent : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func loadCategories() async {
        guard !categoriesLoaded else { return }
        categoriesLoaded = true
        do {
            let response = try await appState.listCategories()
            categories = response.categories
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load(page: Int64 = 0, reset: Bool = false) async {
        if reset { currentPage = 0 }
        let target = reset ? 0 : page
        currentPage = target
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = target * Self.pageSize
        do {
            let parsed = Self.parseSearch(query)
            let categoryIDs: [Int64] = selectedCategoryID.map { [$0] } ?? []
            let response = try await appState.listDocuments(
                search: parsed.search,
                categoryIds: categoryIDs,
                documentIds: parsed.documentIDs,
                offset: offset,
                pageSize: Self.pageSize
            )
            documents = response.documents
            totalCount = response.pagination.totalCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Splits a search query into a DOC-ID filter and a text search.
    /// A query that starts with "DOC-" or consists only of digits is treated
    /// as a document id; otherwise the whole query is a text search.
    private static func parseSearch(_ query: String) -> (documentIDs: [Int64], search: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], "") }

        var documentIDs: [Int64] = []
        var search = trimmed

        if trimmed.lowercased().hasPrefix("doc-") {
            let numberPart = trimmed.dropFirst(4)
            if let id = Int64(numberPart) {
                documentIDs = [id]
                search = ""
            }
        } else if trimmed.allSatisfy(\.isNumber) {
            if let id = Int64(trimmed) {
                documentIDs = [id]
                search = ""
            }
        }
        return (documentIDs, search)
    }
}

/// Hashable navigation value for a document detail screen.
struct DocumentRoute: Hashable {
    let documentID: Int64
}

/// Navigation route to a citizen detail view (used from document relations).
struct CitizenRoute: Hashable {
    let userID: Int32
}

/// Navigation route to a unit detail view, available app-wide so dispatch
/// assignments can open unit info from any module.
struct UnitRoute: Hashable {
    let unitID: Int64
}

private struct DocumentRow: View {
    let document: Resources_Documents_DocumentShort

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            GradientIconTile("doc.text", gradient: FiveNetModule.documents.gradient, size: 44)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    if document.hasPin && document.pin.state {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                    Text(title)
                        .font(.headline)
                        .lineLimit(2)
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !badges.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(badges) { badge in
                            StatusBadge(badge.label, color: badge.color)
                        }
                    }
                }
            }

            Spacer()

            IDBadge(formatDocumentID(document.id))

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
        document.title.isEmpty ? "Unbenanntes Dokument" : document.title
    }

    private var subtitle: String {
        var parts: [String] = []
        if document.hasCategory, !document.category.name.isEmpty {
            parts.append(document.category.name)
        }
        let creatorName = [document.creator.firstname, document.creator.lastname]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !creatorName.isEmpty {
            parts.append(creatorName)
        }
        if document.hasUpdatedAt, document.updatedAt.timestamp.date.timeIntervalSince1970 > 0 {
            parts.append(formatRelative(document.updatedAt))
        } else if document.hasCreatedAt, document.createdAt.timestamp.date.timeIntervalSince1970 > 0 {
            parts.append(formatRelative(document.createdAt))
        }
        return parts.joined(separator: " · ")
    }

    private var badges: [DocumentBadge] {
        var result: [DocumentBadge] = []
        if document.meta.draft {
            result.append(DocumentBadge(label: "Entwurf", color: .gray))
        }
        if document.meta.closed {
            result.append(DocumentBadge(label: "Geschlossen", color: .orange))
        }
        let approval = DocumentApprovalStatus(meta: document.meta)
        if approval != .none {
            result.append(DocumentBadge(label: approval.label, color: approval.color))
        }
        if !document.meta.state.isEmpty {
            result.append(DocumentBadge(label: document.meta.state, color: .blue))
        }
        return result
    }
}

private struct DocumentBadge: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
}

/// Sheet to create a new document from a template.
/// Templates with a schema require a selection of citizens/documents/vehicles
/// copied into the app clipboard first. The selection is sent as a `TemplateSelection`
/// (IDs/plates); the server resolves the referenced objects itself (v2026.8.5).
struct CreateDocumentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onCreated: (Int64) -> Void

    @State private var templates: [Resources_Documents_Templates_TemplateShort] = []
    @State private var selectedTemplate: Resources_Documents_Templates_TemplateShort?
    @State private var selectedUserIDs: Set<Int32> = []
    @State private var selectedDocumentIDs: Set<Int64> = []
    @State private var selectedVehiclePlates: Set<String> = []
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var requirements: Resources_Documents_Templates_TemplateRequirements? {
        selectedTemplate?.schema.requirements
    }

    private var canCreate: Bool {
        guard selectedTemplate != nil, isCreating == false else { return false }
        guard let reqs = requirements else { return true }
        if reqs.hasUsers, reqs.users.required {
            let min = Int(reqs.users.min)
            if selectedUserIDs.count < min { return false }
        }
        if reqs.hasDocuments, reqs.documents.required {
            let min = Int(reqs.documents.min)
            if selectedDocumentIDs.count < min { return false }
        }
        if reqs.hasVehicles, reqs.vehicles.required {
            let min = Int(reqs.vehicles.min)
            if selectedVehiclePlates.count < min { return false }
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && templates.isEmpty {
                    ProgressView("Vorlagen werden geladen …")
                } else if selectedTemplate != nil {
                    if let reqs = requirements, reqs.hasUsers || reqs.hasDocuments || reqs.hasVehicles {
                        selectionStep(reqs)
                    } else {
                        List {
                            Section {
                                Text(selectedTemplate?.title ?? "Vorlage")
                                    .font(.headline)
                            } footer: {
                                Text("Das Dokument wird ohne Auswahl aus der Zwischenablage erstellt.")
                            }
                        }
                        .listStyle(.insetGrouped)
                    }
                } else if templates.isEmpty {
                    emptyTemplates
                } else {
                    templateList
                }
            }
            .navigationTitle(selectedTemplate == nil ? "Dokument erstellen" : selectedTemplate?.title ?? "Dokument erstellen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        if selectedTemplate == nil {
                            dismiss()
                        } else {
                            selectedTemplate = nil
                            errorMessage = nil
                        }
                    }
                    .disabled(isCreating)
                }
                if selectedTemplate != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isCreating ? "Erstellt …" : "Erstellen") {
                            Task { await create() }
                        }
                        .disabled(!canCreate)
                    }
                }
            }
            .task {
                await loadTemplates()
            }
            .overlay {
                if let errorMessage {
                    VStack {
                        Spacer()
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.danger)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                            .padding()
                    }
                }
            }
        }
    }

    private var emptyTemplates: some View {
        List {
            Section {
                blankDocumentRow
            } footer: {
                Text("Es sind keine Vorlagen zum Erstellen verfügbar. Ein leeres Dokument kannst du jederzeit anlegen.")
            }
        }
        .listStyle(.insetGrouped)
    }

    private var templateList: some View {
        List {
            Section {
                blankDocumentRow
            } header: {
                Text("Neu ohne Vorlage")
            }
            Section("Vorlagen") {
                ForEach(templates) { template in
                    Button {
                        selectedTemplate = template
                        errorMessage = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(template.title.isEmpty ? "Unbenannte Vorlage" : template.title)
                                    .font(.headline)
                                if !template.description_p.isEmpty {
                                    Text(template.description_p)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if template.hasSchema {
                                    Label("Erfordert Auswahl", systemImage: "list.bullet.rectangle")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Palette.warning)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var blankDocumentRow: some View {
        Button {
            Task { await createBlank() }
        } label: {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Leeres Dokument")
                        .font(.headline)
                    Text("Erstellt ein neues Dokument ohne Vorlage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .disabled(isCreating)
    }

    private func selectionStep(_ reqs: Resources_Documents_Templates_TemplateRequirements) -> some View {
        List {
            Section {
                Text(selectedTemplate?.title ?? "Vorlage")
                    .font(.headline)
            } footer: {
                Text("Wähle aus der Zwischenablage. Kopiere zuerst Bürger, Dokumente oder Fahrzeuge in die Zwischenablage (Button in der jeweiligen Detailansicht).")
            }

            if reqs.hasUsers, reqs.users.required {
                clipboardSection(
                    title: "Bürger",
                    requirementText: requirementText(min: reqs.users.min, max: reqs.users.max),
                    count: selectedUserIDs.count
                ) {
                    if appState.clipboardUsers.isEmpty {
                        Text("Keine Bürger in der Zwischenablage.").foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.clipboardUsers, id: \.userID) { user in
                            Button {
                                toggleUser(user)
                            } label: {
                                row(label: userShortName(user), selected: selectedUserIDs.contains(user.userID))
                            }
                        }
                    }
                }
            }

            if reqs.hasDocuments, reqs.documents.required {
                clipboardSection(
                    title: "Dokumente",
                    requirementText: requirementText(min: reqs.documents.min, max: reqs.documents.max),
                    count: selectedDocumentIDs.count
                ) {
                    if appState.clipboardDocuments.isEmpty {
                        Text("Keine Dokumente in der Zwischenablage.").foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.clipboardDocuments) { document in
                            Button {
                                toggleDocument(document)
                            } label: {
                                row(label: "\(formatDocumentID(document.id)) · \(document.title)", selected: selectedDocumentIDs.contains(document.id))
                            }
                        }
                    }
                }
            }

            if reqs.hasVehicles, reqs.vehicles.required {
                clipboardSection(
                    title: "Fahrzeuge",
                    requirementText: requirementText(min: reqs.vehicles.min, max: reqs.vehicles.max),
                    count: selectedVehiclePlates.count
                ) {
                    if appState.clipboardVehicles.isEmpty {
                        Text("Keine Fahrzeuge in der Zwischenablage.").foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.clipboardVehicles, id: \.plate) { vehicle in
                            Button {
                                toggleVehicle(vehicle)
                            } label: {
                                row(label: vehicleLabel(vehicle), selected: selectedVehiclePlates.contains(vehicle.plate))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func clipboardSection(title: String, requirementText: String, count: Int, @ViewBuilder content: () -> some View) -> some View {
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            Text("\(requirementText) · \(count) ausgewählt")
        }
    }

    private func row(label: String, selected: Bool) -> some View {
        HStack {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Text(label)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func requirementText(min: Int32, max: Int32) -> String {
        if max > min {
            return "\(min)–\(max) erforderlich"
        }
        return "\(min) erforderlich"
    }

    private func vehicleLabel(_ vehicle: Resources_Vehicles_Vehicle) -> String {
        [vehicle.plate, vehicle.model].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func toggleUser(_ user: Resources_Users_Short_UserShort) {
        if selectedUserIDs.contains(user.userID) {
            selectedUserIDs.remove(user.userID)
        } else {
            selectedUserIDs.insert(user.userID)
        }
    }

    private func toggleDocument(_ document: Resources_Documents_Document) {
        if selectedDocumentIDs.contains(document.id) {
            selectedDocumentIDs.remove(document.id)
        } else {
            selectedDocumentIDs.insert(document.id)
        }
    }

    private func toggleVehicle(_ vehicle: Resources_Vehicles_Vehicle) {
        if selectedVehiclePlates.contains(vehicle.plate) {
            selectedVehiclePlates.remove(vehicle.plate)
        } else {
            selectedVehiclePlates.insert(vehicle.plate)
        }
    }

    private func loadTemplates() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            templates = try await appState.listTemplates()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func create() async {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        let selection = selectionFromClipboard()
        do {
            let id = try await appState.createDocument(templateID: selectedTemplate!.id, templateSelection: selection)
            onCreated(id)
            dismiss()
        } catch {
            errorMessage = await Self.diagnose(error, templateID: selectedTemplate?.id ?? 0, selection: selection, appState: appState)
        }
    }

    /// Buildings a `TemplateSelection` from the clipboard items selected in the UI.
    /// The server resolves the referenced objects itself (per-request permissions,
    /// job enrichment) and derives the active character from the auth token.
    private func selectionFromClipboard() -> Resources_Documents_Templates_TemplateSelection? {
        guard selectedUserIDs.isEmpty == false || selectedDocumentIDs.isEmpty == false || selectedVehiclePlates.isEmpty == false else { return nil }
        var selection = Resources_Documents_Templates_TemplateSelection()
        selection.userIds = appState.clipboardUsers
            .filter { selectedUserIDs.contains($0.userID) }
            .map(\.userID)
        selection.documentIds = appState.clipboardDocuments
            .filter { selectedDocumentIDs.contains($0.id) }
            .map(\.id)
        selection.plates = appState.clipboardVehicles
            .filter { selectedVehiclePlates.contains($0.plate) }
            .map(\.plate)
        return selection
    }

    private func createBlank() async {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        await appState.ensureCharacterLoaded()
        do {
            let id = try await appState.createDocument()
            onCreated(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// When the server answers with the sanitized `ErrFailedQuery`/template errors,
    /// the real cause is swallowed by `errswrap`. Retry with `GetTemplate(render:true)`
    /// which returns the raw template error when the caller has CreateTemplate
    /// permission; otherwise the server still reports a generic template error.
    private static func diagnose(_ error: Error, templateID: Int64, selection: Resources_Documents_Templates_TemplateSelection?, appState: AppState) async -> String {
        let message = error.localizedDescription
        let templateErrorTokens = [
            "ErrFailedQuery", "FailedQuery",
            "ErrTemplateInvalid", "TemplateInvalid",
            "ErrTemplateRequirementsNotMet", "ErrTemplateRequirementsExceeded",
            "ErrTemplateOutputInvalid", "ErrTemplateRenderFailed", "ErrTemplateActiveChar",
            "ErrTemplateFailed", "TemplateFailed",
        ]
        guard templateErrorTokens.contains(where: { message.contains($0) }) else {
            return message
        }
        do {
            _ = try await appState.getTemplate(templateID: templateID, templateSelection: selection, render: true)
            return "\(message)\n\n(GetTemplate-Render lieferte keine Fehlermeldung.)"
        } catch {
            let detail = error.localizedDescription
            let hint = (detail.contains("TemplateInvalid") || detail.contains("TemplateFailed"))
                ? "Die Vorlage wird serverseitig gerendert; die genaue Ursache steht nur im Server-Log (der Fehler wird über gRPC gekürzt zurückgegeben)."
                : ""
            if hint.isEmpty {
                return "\(message)\n\nDetail: \(detail)"
            }
            return "\(message)\n\n\(hint)"
        }
    }
}

#Preview {
    NavigationStack {
        DocumentsListView()
            .environment(AppState())
    }
}
