import SwiftUI

/// Berufe → Gruppen: Liste aller Job-Gruppen mit Suche, Status-/Typ-Filter,
/// Statistik-Kacheln und Erstellen-Button. Spiegelt die Web-Seite
/// `pages/jobs/groups/index.vue` → `components/jobs/groups/List.vue`.
struct JobGroupsListView: View {
    @Environment(AppState.self) private var appState

    /// Externer Trigger für das Erstellen-Sheet. Der "Neue Gruppe"-Button sitzt
    /// auf dem TabView-Container (JobsView) — Toolbar-Items auf Tab-Inhalten
    /// werden in einem gepushten TabView nicht zuverlässig gerendert (gleiches
    /// Muster wie die Leitstellen-"+"). Deshalb steuert der Container das Sheet.
    @Binding var isPresentingCreateSheet: Bool

    init(isPresentingCreateSheet: Binding<Bool> = .constant(false)) {
        _isPresentingCreateSheet = isPresentingCreateSheet
    }

    private static let pageSize: Int64 = 20

    @State private var groups: [Resources_Jobs_Groups_Group] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false

    // Filter
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .active
    @State private var kindFilter: KindFilter = .all
    @State private var sortColumn: String = "sort_rank"
    @State private var sortDesc = false
    @State private var appliedFilters = false
    @State private var searchTask: Task<Void, Never>?
    @State private var pendingSearchText = ""

    private var totalPages: Int64 {
        max(1, Int64(ceil(Double(totalCount) / Double(Self.pageSize))))
    }

    enum StatusFilter: String, CaseIterable, Identifiable {
        case active = "Aktiv"
        case inactive = "Inaktiv"
        case archived = "Archiviert"
        case all = "Alle"

        var id: String { rawValue }

        var states: [Resources_Jobs_Groups_GroupState] {
            switch self {
            case .active: [.active]
            case .inactive: [.inactive]
            case .archived: [.archived]
            case .all: []
            }
        }

        var includeInactive: Bool { self == .all || self == .inactive }
        var includeArchived: Bool { self == .all || self == .archived }
    }

    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "Alle"
        case manual = "Manuell"
        case smart = "Automatisch"
        case mixed = "Gemischt"

        var id: String { rawValue }

        var kind: Resources_Jobs_Groups_GroupType? {
            switch self {
            case .all: nil
            case .manual: .manual
            case .smart: .smart
            case .mixed: .mixed
            }
        }
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

                statCardsSection

                if isLoading && groups.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if groups.isEmpty {
                    EmptyStateView(
                        "person.3",
                        color: Theme.Palette.accent,
                        title: "Keine Gruppen",
                        message: "Für diesen Filter sind noch keine Gruppen vorhanden.",
                        actionTitle: "Neu laden"
                    ) {
                        Task { await load(reset: true) }
                    }
                    .cardRow()
                } else {
                    Section {
                        ForEach(groups) { group in
                            NavigationLink(value: GroupRoute(groupID: group.id)) {
                                GroupRow(group: group)
                            }
                            .navigationLinkIndicatorVisibility(.hidden)
                            .cardRow()
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
            }
            .cardListStyle()
            .navigationTitle("Gruppen")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Gruppen durchsuchen")
            .onChange(of: searchText) { _, newValue in
                searchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                searchTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    pendingSearchText = trimmed
                    appliedFilters = true
                    await load(reset: true)
                }
            }
            .refreshable { await load(reset: true) }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await load()
            }
            .onAppear {
                if hasLoaded {
                    Task { await load() }
                }
            }
            .sheet(isPresented: $isPresentingCreateSheet) {
                JobGroupEditorSheet { _ in
                    Task { await load(reset: true) }
                }
            }
        }
    }

    private var statCardsSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.md) {
                GroupStatCard(
                    title: "Sichtbare Gruppen",
                    value: "\(groups.count)",
                    systemImage: "person.3"
                )
                GroupStatCard(
                    title: "Mitglieder (ca.)",
                    value: "\(groups.reduce(0) { $0 + $1.membersCount })",
                    systemImage: "person.2"
                )
                GroupStatCard(
                    title: "Leiter",
                    value: "\(groups.reduce(0) { $0 + $1.leadersCount })",
                    systemImage: "star"
                )
                GroupStatCard(
                    title: "Ausschlüsse",
                    value: "\(groups.reduce(0) { $0 + $1.exclusionsCount })",
                    systemImage: "person.crop.circle.badge.xmark"
                )
            }
            .cardRow()
        }
    }

    func load(page: Int64? = nil, reset: Bool = false) async {
        if reset {
            currentPage = 0
        }
        let target = page ?? currentPage
        let previous = currentPage
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await appState.listGroups(
                states: statusFilter.states,
                kind: kindFilter.kind,
                search: pendingSearchText,
                includeCounts: true,
                includeInactive: statusFilter.includeInactive,
                includeArchived: statusFilter.includeArchived,
                sortColumn: sortColumn,
                desc: sortDesc,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            groups = response.groups
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }
}

/// Statistik-Kachel (Web-Stat-Cards) für die Gruppen-Liste.
private struct GroupStatCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(Theme.Typography.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.md)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Zeile in der Gruppen-Liste: Avatar-Initialen, Name, Kurzname-Badge,
/// Beschreibung, Typ-/Status-Badges und Zähler.
struct GroupRow: View {
    let group: Resources_Jobs_Groups_Group

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text(group.initials)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(group.type.tint.readableText)
                .frame(width: 40, height: 40)
                .background(group.type.tint, in: Circle())
                .lineLimit(1)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(group.name)
                        .font(Theme.Typography.headline)
                        .lineLimit(1)
                    if !group.shortName.isEmpty && group.shortName != group.name {
                        Text(group.shortName)
                            .font(Theme.Typography.caption2)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 2)
                            .background(Theme.Palette.fill, in: Capsule())
                    }
                }
                Text(group.description.isEmpty ? "Keine Beschreibung" : group.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: Theme.Spacing.md) {
                    Label(group.type.label, systemImage: group.type.icon)
                        .labelStyle(CompactLabelStyle())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(group.type.tint)
                    Label(group.membershipMode.label, systemImage: group.membershipMode.icon)
                        .labelStyle(CompactLabelStyle())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(group.membershipMode.tint)
                    Spacer()
                    Text(group.state.label)
                        .font(Theme.Typography.caption2)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(group.state.tint.opacity(0.14), in: Capsule())
                }
                Text("\(group.membersCount) Mitglieder · \(group.leadersCount) Leiter · \(group.rulesCount) Regeln · \(group.exclusionsCount) Ausschlüsse")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            CardChevron()
        }
        .padding(.vertical, Theme.Spacing.xs)
        .padding(Theme.Spacing.md)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

#Preview {
    NavigationStack {
        JobGroupsListView()
            .environment(AppState())
    }
}
