import SwiftUI

// MARK: - Gemeinsame Bausteine

/// Inline-Suchleiste (Muster Kollegen/Archiv) für die Gruppen-Panels: wird als
/// eigene `SectionCard` unterhalb des Tab-Selectors gerendert.
struct GroupPanelSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        SectionCard {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $text)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .cardRow()
    }
}

/// Avatar + Name für Mitglieds-Zeilen.
struct MemberIdentityView: View {
    let name: String
    let initials: String
    let tint: Color

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text(initials)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(tint.readableText)
                .frame(width: 40, height: 40)
                .background(tint, in: Circle())
                .lineLimit(1)
            Text(name)
                .font(Theme.Typography.headline)
                .lineLimit(1)
        }
    }
}

/// Sheet zum Hinzufügen/Bearbeiten eines Mitglieds (Kollege + optionaler Grund).
struct GroupMemberAddSheet: View {
    let title: String
    @Binding var selectedUser: Resources_Jobs_Colleagues_Colleague?
    @Binding var reasonText: String
    @Binding var colleagueSearch: String
    @Binding var colleagueResults: [Resources_Jobs_Colleagues_Colleague]
    @Binding var colleagueSearchTask: Task<Void, Never>?
    var onSearch: (String) async -> Void
    var onSubmit: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name oder CIT-ID", text: $colleagueSearch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: colleagueSearch) { _, newValue in
                            colleagueSearchTask?.cancel()
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            colleagueSearchTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                guard !Task.isCancelled else { return }
                                await onSearch(trimmed)
                            }
                        }
                        .onAppear {
                            if colleagueResults.isEmpty {
                                Task { await onSearch("") }
                            }
                        }

                    ForEach(colleagueResults, id: \.userID) { colleague in
                        Button {
                            selectedUser = colleague
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(colleagueName(colleague))
                                    Text("CIT-\(colleague.userID) · \(colleagueJobLine(colleague))")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedUser?.userID == colleague.userID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Palette.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    TextField("Grund (optional)", text: $reasonText, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        selectedUser = nil
                        colleagueSearch = ""
                        colleagueSearchTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task { await onSubmit() }
                    }
                    .disabled(selectedUser == nil)
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

/// Helper to build a job line for a colleague (used by the add sheets).
private func colleagueJobLine(_ colleague: Resources_Jobs_Colleagues_Colleague) -> String {
    let job = colleague.jobLabel.isEmpty ? colleague.job : colleague.jobLabel
    let grade = colleague.jobGradeLabel.isEmpty ? "Rang \(colleague.jobGrade)" : colleague.jobGradeLabel
    return [job, grade].filter { !$0.isEmpty }.joined(separator: " · ")
}

// MARK: - Mitglieder (aufgelöst)
struct GroupMembersPanel: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64
    let canView: Bool

    private static let pageSize: Int64 = 20

    @State private var members: [Resources_Jobs_Groups_GroupResolvedMember] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingSearch = ""
    @State private var selectedSources: Set<Resources_Jobs_Groups_GroupMemberSource> = []

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Section {
            GroupPanelSearchField(text: $searchText, prompt: "Mitglieder durchsuchen")

            if let errorMessage {
                StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .cardRow()
            }

            if isLoading && members.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonListRow()
                }
            } else if members.isEmpty {
                EmptyStateView(
                    "person.2",
                    color: Theme.Palette.accent,
                    title: "Keine Mitglieder",
                    message: "Für diese Gruppe sind noch keine Mitglieder aufgelöst."
                )
                .cardRow()
            } else {
                ForEach(members, id: \.id) { member in
                    MemberRow(member: member)
                        .cardRow()
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
                                if isLoading { ProgressView() }
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
        }
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                pendingSearch = trimmed
                await load(reset: true)
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
    }

    func load(page: Int64? = nil, reset: Bool = false) async {
        if reset { currentPage = 0 }
        let target = page ?? currentPage
        let previous = currentPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.listGroupMembers(
                groupID: groupID,
                search: pendingSearch,
                sources: Array(selectedSources),
                includeExcluded: true,
                includeLeaders: true,
                includeReasons: true,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            members = response.members
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }
}

/// Zeile eines aufgelösten Gruppenmitglieds (Tone-Badge + Gründe).
struct MemberRow: View {
    let member: Resources_Jobs_Groups_GroupResolvedMember

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            if member.hasColleague {
                Text(member.colleague.initials)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(member.memberTone.readableText)
                    .frame(width: 40, height: 40)
                    .background(member.memberTone, in: Circle())
                    .lineLimit(1)
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(member.memberTone)
                    .frame(width: 40, height: 40)
                    .background(member.memberTone.opacity(0.14), in: Circle())
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(member.hasColleague ? colleagueName(member.colleague) : "Benutzer #\(member.userID)")
                        .font(Theme.Typography.headline)
                        .lineLimit(1)
                    Text(member.memberToneLabel)
                        .font(Theme.Typography.caption2)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(member.memberTone.opacity(0.14), in: Capsule())
                    if member.hasManualReason {
                        Text("Manuell")
                            .font(Theme.Typography.caption2)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 2)
                            .background(Theme.Palette.neutral.opacity(0.14), in: Capsule())
                    }
                }

                if !member.reasons.isEmpty {
                    Text(reasonsText(member.reasons))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func reasonsText(_ reasons: [Resources_Jobs_Groups_GroupMembershipReason]) -> String {
        reasons.map { reason in
            var text = reason.type.label
            if reason.hasRuleID {
                text += " #\(reason.ruleID)"
            }
            if reason.hasDetail && !reason.detail.isEmpty {
                text += " – \(reason.detail)"
            }
            return text
        }.joined(separator: ", ")
    }
}

// MARK: - Manuelle Mitglieder

/// Manuelle-Mitglieder-Tab: explizit hinzugefügte Mitglieder mit Grund,
/// Hinzufügen/Bearbeiten (Upsert via `AddGroupMember`) + Entfernen.
/// Spiegelt die Web-`ManualMembersPanel.vue`.
struct GroupManualMembersPanel: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64
    let groupType: Resources_Jobs_Groups_GroupType
    let access: Resources_Access_Access?
    let canView: Bool
    let canManage: Bool

    private static let pageSize: Int64 = 20

    @State private var members: [Resources_Jobs_Groups_GroupManualMember] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingSearch = ""

    @State private var showAdd = false
    @State private var selectedUser: Resources_Jobs_Colleagues_Colleague?
    @State private var reasonText = ""
    @State private var editingMember: Resources_Jobs_Groups_GroupManualMember?
    @State private var isSubmitting = false
    @State private var confirmRemove: Resources_Jobs_Groups_GroupManualMember?
    @State private var colleagueSearch = ""
    @State private var colleagueResults: [Resources_Jobs_Colleagues_Colleague] = []
    @State private var colleagueSearchTask: Task<Void, Never>?

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Section {
            if !groupType.allowsManualMembers {
                StatusLabelRow(
                    "Dieser Gruppentyp unterstützt keine manuellen Mitglieder.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Theme.Palette.warning
                )
                .cardRow()
            }

            if let errorMessage {
                StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .cardRow()
            }

            if groupType.allowsManualMembers {
                if canManage {
                    Button {
                        showAdd = true
                        editingMember = nil
                        selectedUser = nil
                        reasonText = ""
                    } label: {
                        HStack {
                            Label("Mitglied hinzufügen", systemImage: "person.badge.plus")
                            Spacer()
                            CardChevron()
                        }
                    }
                    .cardRow()
                }

                if isLoading && members.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if members.isEmpty {
                    EmptyStateView(
                        "person.badge.plus",
                        color: Theme.Palette.accent,
                        title: "Keine manuellen Mitglieder",
                        message: "Es wurden noch keine Kollegen manuell hinzugefügt."
                    )
                    .cardRow()
                } else {
                    ForEach(members, id: \.id) { member in
                        HStack(spacing: Theme.Spacing.lg) {
                            MemberIdentityView(
                                name: member.hasColleague ? colleagueName(member.colleague) : "Benutzer #\(member.userID)",
                                initials: member.hasColleague ? member.colleague.initials : "?",
                                tint: Theme.Palette.success
                            )

                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                if member.hasReason && !member.reason.isEmpty {
                                    Text(member.reason)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text("Hinzugefügt: \(formatTimestamp(member.createdAt))")
                                    .font(Theme.Typography.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                        .cardRow()
                        .swipeActions(edge: .trailing) {
                            if canManage {
                                Button(role: .destructive) {
                                    confirmRemove = member
                                } label: {
                                    Label("Entfernen", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Manuelle Mitglieder durchsuchen")
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                pendingSearch = trimmed
                await load(reset: true)
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            guard groupType.allowsManualMembers else { return }
            await load()
        }
        .sheet(isPresented: $showAdd) {
            GroupMemberAddSheet(
                title: editingMember == nil ? "Mitglied hinzufügen" : "Mitglied bearbeiten",
                selectedUser: $selectedUser,
                reasonText: $reasonText,
                colleagueSearch: $colleagueSearch,
                colleagueResults: $colleagueResults,
                colleagueSearchTask: $colleagueSearchTask,
                onSearch: { query in
                    guard let results = try? await appState.listColleagues(search: query, pageSize: 20).colleagues else { return }
                    colleagueResults = results
                }
            ) {
                Task { await submit() }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            "Mitglied entfernen",
            isPresented: Binding(
                get: { confirmRemove != nil },
                set: { if !$0 { confirmRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Entfernen", role: .destructive) {
                if let confirmRemove {
                    Task { await remove(confirmRemove) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Möchtest du dieses Mitglied wirklich aus der Gruppe entfernen?")
        }
    }

    func load(page: Int64? = nil, reset: Bool = false) async {
        if reset { currentPage = 0 }
        let target = page ?? currentPage
        let previous = currentPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.listGroupManualMembers(
                groupID: groupID,
                search: pendingSearch,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            members = response.manualMembers
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }

    func submit() async {
        guard let user = selectedUser else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await appState.addGroupMember(groupID: groupID, userID: user.userID, reason: reasonText)
            showAdd = false
            editingMember = nil
            selectedUser = nil
            reasonText = ""
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ member: Resources_Jobs_Groups_GroupManualMember) async {
        do {
            _ = try await appState.removeGroupMember(groupID: groupID, userID: member.userID)
            confirmRemove = nil
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Leiter

/// Leiter-Tab: Gruppen-Leiter (MANAGE-Level), hinzufügen/entfernen.
/// Spiegelt die Web-`LeadersPanel.vue`.
struct GroupLeadersPanel: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64
    let access: Resources_Access_Access?
    let canView: Bool
    let canManage: Bool

    private static let pageSize: Int64 = 20

    @State private var leaders: [Resources_Jobs_Groups_GroupLeader] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingSearch = ""

    @State private var showAdd = false
    @State private var selectedUser: Resources_Jobs_Colleagues_Colleague?
    @State private var isSubmitting = false
    @State private var confirmRemove: Resources_Jobs_Groups_GroupLeader?
    @State private var colleagueSearch = ""
    @State private var colleagueResults: [Resources_Jobs_Colleagues_Colleague] = []
    @State private var colleagueSearchTask: Task<Void, Never>?

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Section {
            if let errorMessage {
                StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .cardRow()
            }

            if canManage {
                Button {
                    showAdd = true
                    selectedUser = nil
                } label: {
                    HStack {
                        Label("Leiter hinzufügen", systemImage: "person.badge.plus")
                        Spacer()
                        CardChevron()
                    }
                }
                .cardRow()
            }

            if isLoading && leaders.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonListRow()
                }
            } else if leaders.isEmpty {
                EmptyStateView(
                    "person.badge.plus",
                    color: Theme.Palette.accent,
                    title: "Keine Leiter",
                    message: "Dieser Gruppe sind noch keine Leiter zugewiesen."
                )
                .cardRow()
            } else {
                ForEach(leaders, id: \.id) { leader in
                    NavigationLink(value: ColleagueRoute(userID: leader.userID)) {
                        HStack(spacing: Theme.Spacing.lg) {
                            MemberIdentityView(
                                name: leader.hasColleague ? colleagueName(leader.colleague) : "Benutzer #\(leader.userID)",
                                initials: leader.hasColleague ? leader.colleague.initials : "?",
                                tint: Theme.Palette.warning
                            )
                            Spacer(minLength: 0)
                            Text("Leiter")
                                .font(Theme.Typography.caption2)
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, 2)
                                .background(Theme.Palette.warning.opacity(0.14), in: Capsule())
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    }
                    .buttonStyle(.plain)
                    .cardRow()
                    .swipeActions(edge: .trailing) {
                        if canManage {
                            Button(role: .destructive) {
                                confirmRemove = leader
                            } label: {
                                Label("Entfernen", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Leiter durchsuchen")
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                pendingSearch = trimmed
                await load(reset: true)
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .sheet(isPresented: $showAdd) {
            GroupMemberAddSheet(
                title: "Leiter hinzufügen",
                selectedUser: $selectedUser,
                reasonText: .constant(""),
                colleagueSearch: $colleagueSearch,
                colleagueResults: $colleagueResults,
                colleagueSearchTask: $colleagueSearchTask,
                onSearch: { query in
                    guard let results = try? await appState.listColleagues(search: query, pageSize: 20).colleagues else { return }
                    colleagueResults = results
                }
            ) {
                Task { await submit() }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            "Leiter entfernen",
            isPresented: Binding(
                get: { confirmRemove != nil },
                set: { if !$0 { confirmRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Entfernen", role: .destructive) {
                if let confirmRemove {
                    Task { await remove(confirmRemove) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Möchtest du diesen Leiter wirklich aus der Gruppe entfernen?")
        }
    }

    func load(page: Int64? = nil, reset: Bool = false) async {
        if reset { currentPage = 0 }
        let target = page ?? currentPage
        let previous = currentPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.listGroupLeaders(
                groupID: groupID,
                search: pendingSearch,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            leaders = response.leaders
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }

    func submit() async {
        guard let user = selectedUser else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await appState.addGroupLeader(groupID: groupID, userID: user.userID)
            showAdd = false
            selectedUser = nil
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ leader: Resources_Jobs_Groups_GroupLeader) async {
        do {
            _ = try await appState.removeGroupLeader(groupID: groupID, userID: leader.userID)
            confirmRemove = nil
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Ausschlüsse

/// Ausschlüsse-Tab: ausgeschlossene Kollegen (nur MIXED-Gruppen), mit
/// Grund-Typ und optionalem Grund; Hinzufügen/Bearbeiten (Upsert via
/// `ExcludeGroupMember`) + Entfernen. Spiegelt die Web-`ExclusionsPanel.vue`.
struct GroupExclusionsPanel: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64
    let groupType: Resources_Jobs_Groups_GroupType
    let access: Resources_Access_Access?
    let canView: Bool
    let canManage: Bool

    private static let pageSize: Int64 = 20

    @State private var exclusions: [Resources_Jobs_Groups_GroupMemberExclusion] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    @State private var searchText = ""
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingSearch = ""

    @State private var showAdd = false
    @State private var selectedUser: Resources_Jobs_Colleagues_Colleague?
    @State private var reasonType: Resources_Jobs_Groups_GroupExclusionReason = .manual
    @State private var reasonText = ""
    @State private var editingExclusion: Resources_Jobs_Groups_GroupMemberExclusion?
    @State private var isSubmitting = false
    @State private var confirmRemove: Resources_Jobs_Groups_GroupMemberExclusion?
    @State private var colleagueSearch = ""
    @State private var colleagueResults: [Resources_Jobs_Colleagues_Colleague] = []
    @State private var colleagueSearchTask: Task<Void, Never>?

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Section {
            if !groupType.allowsExclusions {
                StatusLabelRow(
                    "Dieser Gruppentyp unterstützt keine Ausschlüsse.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Theme.Palette.warning
                )
                .cardRow()
            }

            if let errorMessage {
                StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .cardRow()
            }

            if groupType.allowsExclusions {
                if canManage {
                    Button {
                        showAdd = true
                        editingExclusion = nil
                        selectedUser = nil
                        reasonType = .manual
                        reasonText = ""
                    } label: {
                        HStack {
                            Label("Kollegen ausschließen", systemImage: "person.crop.circle.badge.xmark")
                            Spacer()
                            CardChevron()
                        }
                    }
                    .cardRow()
                }

                if isLoading && exclusions.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if exclusions.isEmpty {
                    EmptyStateView(
                        "person.crop.circle.badge.xmark",
                        color: Theme.Palette.accent,
                        title: "Keine Ausschlüsse",
                        message: "Es wurden noch keine Kollegen ausgeschlossen."
                    )
                    .cardRow()
                } else {
                    ForEach(exclusions, id: \.id) { exclusion in
                        HStack(spacing: Theme.Spacing.lg) {
                            MemberIdentityView(
                                name: exclusion.hasColleague ? colleagueName(exclusion.colleague) : "Benutzer #\(exclusion.userID)",
                                initials: exclusion.hasColleague ? exclusion.colleague.initials : "?",
                                tint: Theme.Palette.danger
                            )

                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Text(exclusion.reasonType.label)
                                        .font(Theme.Typography.caption2)
                                        .padding(.horizontal, Theme.Spacing.sm)
                                        .padding(.vertical, 2)
                                        .background(Theme.Palette.danger.opacity(0.14), in: Capsule())
                                }
                                if exclusion.hasReason && !exclusion.reason.isEmpty {
                                    Text(exclusion.reason)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Text("Ausgeschlossen: \(formatTimestamp(exclusion.createdAt))")
                                    .font(Theme.Typography.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                        .cardRow()
                        .swipeActions(edge: .trailing) {
                            if canManage {
                                Button(role: .destructive) {
                                    confirmRemove = exclusion
                                } label: {
                                    Label("Entfernen", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Ausschlüsse durchsuchen")
        .onChange(of: searchText) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                pendingSearch = trimmed
                await load(reset: true)
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            guard groupType.allowsExclusions else { return }
            await load()
        }
        .sheet(isPresented: $showAdd) {
            GroupExclusionAddSheet(
                title: editingExclusion == nil ? "Kollegen ausschließen" : "Ausschluss bearbeiten",
                selectedUser: $selectedUser,
                reasonType: $reasonType,
                reasonText: $reasonText,
                colleagueSearch: $colleagueSearch,
                colleagueResults: $colleagueResults,
                colleagueSearchTask: $colleagueSearchTask,
                onSearch: { query in
                    guard let results = try? await appState.listColleagues(search: query, pageSize: 20).colleagues else { return }
                    colleagueResults = results
                }
            ) {
                Task { await submit() }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog(
            "Ausschluss entfernen",
            isPresented: Binding(
                get: { confirmRemove != nil },
                set: { if !$0 { confirmRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Entfernen", role: .destructive) {
                if let confirmRemove {
                    Task { await remove(confirmRemove) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Möchtest du diesen Ausschluss wirklich aufheben?")
        }
    }

    func load(page: Int64? = nil, reset: Bool = false) async {
        if reset { currentPage = 0 }
        let target = page ?? currentPage
        let previous = currentPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.listGroupMemberExclusions(
                groupID: groupID,
                search: pendingSearch,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            exclusions = response.exclusions
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }

    func submit() async {
        guard let user = selectedUser else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            _ = try await appState.excludeGroupMember(
                groupID: groupID,
                userID: user.userID,
                reasonType: reasonType,
                reason: reasonText
            )
            showAdd = false
            editingExclusion = nil
            selectedUser = nil
            reasonText = ""
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ exclusion: Resources_Jobs_Groups_GroupMemberExclusion) async {
        do {
            _ = try await appState.removeGroupMemberExclusion(groupID: groupID, userID: exclusion.userID)
            confirmRemove = nil
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet zum Ausschließen eines Kollegen (Grund-Typ + optionaler Grund).
private struct GroupExclusionAddSheet: View {
    let title: String
    @Binding var selectedUser: Resources_Jobs_Colleagues_Colleague?
    @Binding var reasonType: Resources_Jobs_Groups_GroupExclusionReason
    @Binding var reasonText: String
    @Binding var colleagueSearch: String
    @Binding var colleagueResults: [Resources_Jobs_Colleagues_Colleague]
    @Binding var colleagueSearchTask: Task<Void, Never>?
    var onSearch: (String) async -> Void
    var onSubmit: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name oder CIT-ID", text: $colleagueSearch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: colleagueSearch) { _, newValue in
                            colleagueSearchTask?.cancel()
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            colleagueSearchTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                guard !Task.isCancelled else { return }
                                await onSearch(trimmed)
                            }
                        }
                        .onAppear {
                            if colleagueResults.isEmpty {
                                Task { await onSearch("") }
                            }
                        }

                    ForEach(colleagueResults, id: \.userID) { colleague in
                        Button {
                            selectedUser = colleague
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(colleagueName(colleague))
                                    Text("CIT-\(colleague.userID) · \(colleagueJobLine(colleague))")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedUser?.userID == colleague.userID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Palette.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    Picker("Grund-Typ", selection: $reasonType) {
                        ForEach([
                            Resources_Jobs_Groups_GroupExclusionReason.manual,
                            .temporary,
                            .notEligible,
                            .other
                        ], id: \.rawValue) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    TextField("Grund (optional)", text: $reasonText, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        selectedUser = nil
                        colleagueSearch = ""
                        colleagueSearchTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task { await onSubmit() }
                    }
                    .disabled(selectedUser == nil)
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - Aktivität

/// Aktivität-Tab: Audit-Feed der Gruppe (Erstellung, Mitglieder-, Leiter-,
/// Regel- und Logo-Ereignisse) mit Typ-Filter und Pagination.
/// Spiegelt die Web-`ActivityPanel.vue`.
struct GroupActivityPanel: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64
    let canView: Bool
    @Binding var selectedTypes: Set<Resources_Jobs_Groups_GroupActivityType>
    @Binding var reloadToken: Int
    @Binding var linkUserID: Int32?

    private static let pageSize: Int64 = 20

    @State private var activity: [Resources_Jobs_Groups_GroupActivity] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    var body: some View {
        Section {
            if let errorMessage {
                StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .cardRow()
            }

            if isLoading && activity.isEmpty {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonListRow()
                }
            } else if activity.isEmpty {
                EmptyStateView(
                    "clock.arrow.circlepath",
                    color: Theme.Palette.accent,
                    title: "Keine Aktivität",
                    message: "Für diese Gruppe gibt es noch keine Aktivität."
                )
                .cardRow()
            } else {
                ForEach(activity, id: \.id) { entry in
                    GroupActivityRow(entry: entry, linkUserID: $linkUserID)
                        .cardRow()
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
                                if isLoading { ProgressView() }
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
        }
        .onChange(of: reloadToken) {
            Task { await load(reset: true) }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
    }

    func load(page: Int64? = nil, reset: Bool = false) async {
        if reset { currentPage = 0 }
        let target = page ?? currentPage
        let previous = currentPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.listGroupActivity(
                groupID: groupID,
                types: Array(selectedTypes),
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            activity = response.activity
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }
}

/// Zeile im Gruppen-Aktivitäts-Feed.
struct GroupActivityRow: View {
    let entry: Resources_Jobs_Groups_GroupActivity
    let linkUserID: Binding<Int32?>

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            Image(systemName: entry.type.icon)
                .font(.subheadline)
                .foregroundStyle(entry.type.tint)
                .frame(width: 32, height: 32)
                .background(entry.type.tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(entry.type.label)
                    .font(Theme.Typography.headline)
                if entry.hasReason, !entry.reason.isEmpty {
                    Text(entry.reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                targetName
                if entry.hasRuleID {
                    Text("Regel #\(entry.ruleID)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 2) {
                    Text(formatTimestamp(entry.createdAt))
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(.tertiary)
                    actorName
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(Theme.Spacing.md)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    /// Ziel-User: Name (bzw. Fallback) mit Link zum Kollegen-Detail.
    @ViewBuilder
    private var targetName: some View {
        if entry.hasTargetUserID {
            Button {
                linkUserID.wrappedValue = entry.targetUserID
            } label: {
                Text(entry.targetName ?? "Benutzer #\(entry.targetUserID)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.borderless)
        } else if let name = entry.targetName {
            Text(name)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.accent)
        }
    }

    /// Ausführender User: Name (bzw. Fallback) mit Link zum Kollegen-Detail.
    @ViewBuilder
    private var actorName: some View {
        if entry.hasActorUserID {
            Text("·")
                .font(Theme.Typography.caption2)
                .foregroundStyle(.tertiary)
            Button {
                linkUserID.wrappedValue = entry.actorUserID
            } label: {
                Text(entry.actorName ?? "Benutzer #\(entry.actorUserID)")
                    .font(Theme.Typography.caption2)
                    .foregroundStyle(Theme.Palette.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
        } else if let name = entry.actorName {
            Text("· \(name)")
                .font(Theme.Typography.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// Alle Gruppen-Aktivitätstypen außer `.unspecified` (für das Filter-Menu).
var activityTypes: [Resources_Jobs_Groups_GroupActivityType] {
    Resources_Jobs_Groups_GroupActivityType.allCases.filter { $0 != .unspecified }
}
