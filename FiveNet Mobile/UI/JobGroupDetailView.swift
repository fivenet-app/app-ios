import SwiftUI
import SwiftProtobuf

/// Gruppen-Detail: Header-Karte (Name, Badges, Statistik) + Tabs
/// Mitglieder / Regeln / Manuelle Mitglieder / Leiter / Ausschlüsse / Aktivität.
/// Spiegelt die Web-`DetailsSlideover.vue` inkl. Zugriffs-Gating.
struct JobGroupDetailView: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64

    @State private var group: Resources_Jobs_Groups_Group?
    @State private var access: Resources_Access_Access?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    @State private var selectedTab: Tab = .members
    @State private var showEditor = false
    @State private var ruleEditorRequest: GroupRuleEditorState?
    @State private var rulesReloadToken = 0
    @State private var confirmArchive = false
    @State private var confirmRestore = false
    @State private var archiveReason = ""
    @State private var pendingArchive = false
    @State private var activitySelectedTypes: Set<Resources_Jobs_Groups_GroupActivityType> = []
    @State private var activityReloadToken = 0
    @State private var activityLinkUserID: Int32?

    enum Tab: String, CaseIterable, Identifiable {
        case members = "Mitglieder"
        case rules = "Regeln"
        case manualMembers = "Manuell"
        case leaders = "Leiter"
        case exclusions = "Ausschlüsse"
        case activity = "Aktivität"

        var id: String { rawValue }
    }

    private var canViewGroup: Bool {
        guard let access else { return false }
        return checkGroupAccess(access, level: .view, character: appState.character, isSuperuser: appState.isSuperuser)
    }

    private var canMutateGroup: Bool {
        guard let group, group.state != .archived, let access else { return false }
        return checkGroupAccess(access, level: .edit, character: appState.character, isSuperuser: appState.isSuperuser)
    }

    private var canMutateLeaders: Bool {
        guard let group, group.state != .archived, let access else { return false }
        return checkGroupAccess(access, level: .manage, character: appState.character, isSuperuser: appState.isSuperuser)
    }

    private var canManageArchiveState: Bool {
        guard let access else { return false }
        return checkGroupAccess(access, level: .manage, character: appState.character, isSuperuser: appState.isSuperuser) && appState.can("jobs.GroupsService/ArchiveGroup")
    }

    var body: some View {
        List {
            if isLoading && group == nil {
                SkeletonDetailView()
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
            } else if let errorMessage, group == nil {
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
            } else if let group {
                if canViewGroup {
                    headerSection(group)
                } else {
                    EmptyStateView(
                        "lock",
                        color: Theme.Palette.neutral,
                        title: "Kein Zugriff",
                        message: "Du hast keine Berechtigung, diese Gruppe anzusehen."
                    )
                    .listRowInsets(EdgeInsets())
                }
            } else {
                EmptyStateView(
                    "person.3",
                    color: Theme.Palette.accent,
                    title: "Gruppe nicht gefunden",
                    message: "Die angeforderte Gruppe existiert nicht oder du hast keinen Zugriff."
                )
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(group?.name ?? "Gruppe")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $activityLinkUserID) { userID in
            ColleagueDetailView(userID: userID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if selectedTab == .activity {
                    Menu {
                        ForEach(activityTypes, id: \.rawValue) { type in
                            Button {
                                if activitySelectedTypes.contains(type) {
                                    activitySelectedTypes.remove(type)
                                } else {
                                    activitySelectedTypes.insert(type)
                                }
                                activityReloadToken += 1
                            } label: {
                                if activitySelectedTypes.contains(type) {
                                    Label(type.label, systemImage: "checkmark")
                                } else {
                                    Text(type.label)
                                }
                            }
                        }
                        Button(role: .destructive) {
                            activitySelectedTypes.removeAll()
                            activityReloadToken += 1
                        } label: {
                            Text("Alle anzeigen")
                        }
                    } label: {
                        Label(
                            activitySelectedTypes.isEmpty ? "Alle Typen" : "\(activitySelectedTypes.count) Typ(en)",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                    }
                }
            }
        }
        .refreshable { await load() }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            await load()
        }
        .sheet(isPresented: $showEditor) {
            if let group {
                JobGroupEditorSheet(group: group, access: access) { updated in
                    self.group = updated
                    Task { await load() }
                }
            }
        }
        .sheet(item: $ruleEditorRequest) { request in
            GroupRuleEditorSheet(groupID: request.groupID, rule: request.rule) { _ in
                rulesReloadToken += 1
            }
            .environment(appState)
        }
        .confirmationDialog(
            group?.state == .archived ? "Gruppe wiederherstellen" : "Gruppe archivieren",
            isPresented: $confirmArchive,
            titleVisibility: .visible
        ) {
            Button("Archivieren", role: .destructive) {
                Task { await archive() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            if let group {
                Text(group.state == .archived
                     ? "Möchtest du „\(group.name)“ wirklich wiederherstellen?"
                     : "Möchtest du „\(group.name)“ wirklich archivieren? Archivierte Gruppen bleiben in der Historie erhalten.")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func headerSection(_ group: Resources_Jobs_Groups_Group) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    Text(group.initials)
                        .font(Theme.Typography.title2)
                        .foregroundStyle(group.type.tint.readableText)
                        .frame(width: 56, height: 56)
                        .background(group.type.tint, in: Circle())
                        .lineLimit(1)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(group.name)
                                .font(Theme.Typography.title2)
                            if !group.shortName.isEmpty && group.shortName != group.name {
                                Text(group.shortName)
                                    .font(Theme.Typography.caption)
                                    .padding(.horizontal, Theme.Spacing.sm)
                                    .padding(.vertical, 2)
                                    .background(Theme.Palette.fill, in: Capsule())
                            }
                        }
                        Text(group.description.isEmpty ? "Keine Beschreibung" : group.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Label(group.type.label, systemImage: group.type.icon)
                        .labelStyle(CompactLabelStyle())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(group.type.tint)
                    Label(group.membershipMode.label, systemImage: group.membershipMode.icon)
                        .labelStyle(CompactLabelStyle())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(group.membershipMode.tint)
                    Text(group.state.label)
                        .font(Theme.Typography.caption2)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(group.state.tint.opacity(0.14), in: Capsule())
                    Spacer()
                }

                HStack(spacing: Theme.Spacing.md) {
                    GroupDetailStat(label: "Leiter", value: "\(group.leadersCount)")
                    GroupDetailStat(label: "Ausschlüsse", value: "\(group.exclusionsCount)")
                    GroupDetailStat(label: "Mitglieder", value: "\(group.membersCount)")
                    GroupDetailStat(label: "Regeln", value: "\(group.rulesCount)")
                }

                if group.isLegacyPolicyState {
                    Label(
                        "Diese Gruppe hat eine ungültige Kombination aus Typ und Mitgliedschaftsmodus. Bitte bearbeite sie, um sie zu korrigieren.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.warning)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                }

                if canMutateGroup || canManageArchiveState {
                    HStack(spacing: Theme.Spacing.md) {
                        if canMutateGroup {
                            Button {
                                showEditor = true
                            } label: {
                                Label("Bearbeiten", systemImage: "pencil")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        if canManageArchiveState {
                            Button {
                                confirmArchive = true
                            } label: {
                                Label(
                                    group.state == .archived ? "Wiederherstellen" : "Archivieren",
                                    systemImage: group.state == .archived ? "arrow.uturn.backward" : "archivebox"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(group.state == .archived ? Theme.Palette.accent : Theme.Palette.warning)
                        }
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }

        if canViewGroup {
            Section {
                PillTabBar(tabs: Tab.allCases, selection: $selectedTab) { $0.rawValue }
                    .listRowInsets(EdgeInsets())
            }
            .listRowBackground(Color.clear)

            switch selectedTab {
            case .members:
                GroupMembersPanel(groupID: groupID, canView: canViewGroup)
            case .rules:
                GroupRulesPanel(
                    groupID: groupID,
                    groupType: group.type,
                    access: access,
                    canView: canViewGroup,
                    canManage: canMutateGroup,
                    editorRequest: $ruleEditorRequest,
                    reloadToken: $rulesReloadToken
                )
            case .manualMembers:
                GroupManualMembersPanel(
                    groupID: groupID,
                    groupType: group.type,
                    access: access,
                    canView: canViewGroup,
                    canManage: canMutateGroup
                )
            case .leaders:
                GroupLeadersPanel(
                    groupID: groupID,
                    access: access,
                    canView: canViewGroup,
                    canManage: canMutateLeaders
                )
            case .exclusions:
                GroupExclusionsPanel(
                    groupID: groupID,
                    groupType: group.type,
                    access: access,
                    canView: canViewGroup,
                    canManage: canMutateGroup
                )
            case .activity:
                GroupActivityPanel(
                    groupID: groupID,
                    canView: canViewGroup,
                    selectedTypes: $activitySelectedTypes,
                    reloadToken: $activityReloadToken,
                    linkUserID: $activityLinkUserID
                )
            }
        }
    }

    // MARK: - Data

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.getGroup(
                id: groupID,
                includeArchived: true
            )
            group = response.group
            access = response.hasAccess ? response.access : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archive() async {
        guard let group else { return }
        pendingArchive = true
        defer { pendingArchive = false }
        do {
            if group.state == .archived {
                _ = try await appState.restoreGroup(id: group.id)
            } else {
                _ = try await appState.archiveGroup(id: group.id)
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Kleine Statistik-Zelle im Gruppen-Header.
private struct GroupDetailStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.Typography.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(Theme.Palette.elevated, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }
}

// MARK: - Zugriffs-Prüfung

/// Prüft, ob der aktive Charakter den Gruppen-Zugriff auf mindestens `level`
/// hat. Spiegelt die Web-`checkGroupAccess` (Superuser-Bypass, sonst gegen die
/// per-Gruppen-`Access`-Einträge). Die `AccessLevel`-Skala der Gruppen ist
/// VIEW=2 / EDIT=4 / MANAGE=5. Für Einträge ohne zugeordneten Job/Nutzer
/// („für alle“) zählt der bloße Level-Vergleich.
func checkGroupAccess(_ access: Resources_Access_Access, level: Resources_Jobs_Groups_Access_AccessLevel, character: Resources_Users_User? = nil, isSuperuser: Bool = false) -> Bool {
    if isSuperuser { return true }
    let required = Int32(level.rawValue)
    if let character {
        for user in access.users where user.userID == character.userID && required <= user.access {
            return true
        }
        for job in access.jobs where job.job == character.job && job.minimumGrade <= character.jobGrade && job.access >= required {
            return true
        }
    }
    for job in access.jobs where job.job.isEmpty && job.access >= required {
        return true
    }
    return false
}

#Preview {
    NavigationStack {
        JobGroupDetailView(groupID: 1)
            .environment(AppState())
    }
}
