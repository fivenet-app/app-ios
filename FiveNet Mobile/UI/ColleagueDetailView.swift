import SwiftUI
import SwiftProtobuf

/// Berufe "Kollegen" detail with tabs (Info, Aktivität, Stempeluhr,
/// Qualifikationen, Führungsregister). Mirrors the web colleague pages.
struct ColleagueDetailView: View {
    @Environment(AppState.self) private var appState

    let userID: Int32

    private enum Tab: String, CaseIterable, Identifiable {
        case info
        case activity
        case timeclock
        case qualifications
        case conduct

        var id: String { rawValue }

        var label: String {
            switch self {
            case .info: return "Info"
            case .activity: return "Aktivität"
            case .timeclock: return "Stempeluhr"
            case .qualifications: return "Qualifikationen"
            case .conduct: return "Führungsregister"
            }
        }
    }

    @State private var selectedTab: Tab = .info
    @State private var colleague: Resources_Jobs_Colleagues_Colleague?
    @State private var activity: [Resources_Jobs_Colleagues_Activity_ColleagueActivity] = []
    @State private var isLoading = true
    @State private var isActivityLoading = false
    @State private var errorMessage: String?
    @State private var showAbsenceSheet = false
    @State private var showToast = false
    @State private var toastMessage = ""

    var body: some View {
        Group {
            if let errorMessage {
                List {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
                .listStyle(.insetGrouped)
            } else if isLoading && colleague == nil {
                List {
                    SkeletonDetailView()
                }
                .listStyle(.insetGrouped)
                .scrollDisabled(true)
            } else if let colleague {
                // The timeclock/conduct sub-views are Lists themselves, so they
                // must NOT be nested inside another List (a List inside a List
                // row renders empty/broken). The picker sits above, the content
                // below.
                VStack(spacing: 0) {
                    PillTabBar(tabs: Tab.allCases, selection: $selectedTab) { $0.label }
                        .padding(.vertical, Theme.Spacing.md)

                    switch selectedTab {
                    case .info:
                        List {
                            infoTab(colleague)
                        }
                        .listStyle(.insetGrouped)
                    case .activity:
                        List {
                            activityTab
                        }
                        .listStyle(.insetGrouped)
                    case .timeclock:
                        JobTimeclockView(userID: userID)
                    case .qualifications:
                        ColleagueQualificationsView(userID: userID)
                    case .conduct:
                        JobConductListView(userID: userID)
                    }
                }
                .background(Theme.Palette.background.ignoresSafeArea())
            } else {
                List {
                    EmptyStateView(
                        "person.fill.questionmark",
                        color: Theme.Palette.accent,
                        title: "Kollege nicht gefunden",
                        message: "Der angeforderte Kollege existiert nicht oder du hast keinen Zugriff."
                    )
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(colleagueTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .onChange(of: selectedTab) {
            if selectedTab == .activity, activity.isEmpty {
                Task { await loadActivity() }
            }
        }
        .sheet(isPresented: $showAbsenceSheet) {
            if let colleague {
                AbsenceDateSheet(colleague: colleague)
                    .environment(appState)
                    .onAbsenceSaved { updated in
                        self.colleague = updated
                        toastMessage = "Abwesenheit gespeichert"
                        showToast = true
                    }
            }
        }
        .toast(isPresented: $showToast, message: toastMessage)
    }

    // MARK: - Info tab

    @ViewBuilder
    private func infoTab(_ colleague: Resources_Jobs_Colleagues_Colleague) -> some View {
        detailHeroSection(DetailHero(
            gradient: FiveNetModule.jobs.gradient,
            icon: "person.crop.circle.fill",
            title: colleagueName(colleague),
            subtitle: colleagueJobLine(colleague),
            badges: colleagueBadges(colleague)
        ))

        Section("Kontakt") {
            if colleague.hasPhoneNumber {
                LabeledContent("Telefon") {
                    Text(formatPhoneNumber(colleague.phoneNumber))
                }
            }
            if colleague.hasEmail {
                LabeledContent("E-Mail") {
                    Text(colleague.email)
                }
            }
            if !colleague.dateofbirth.isEmpty {
                LabeledContent("Geburtsdatum") {
                    Text(colleague.dateofbirth)
                }
            }
        }

        Section("Bürger") {
            NavigationLink(value: CitizenRoute(userID: colleague.userID)) {
                Label("Bürgeransicht öffnen", systemImage: "person.crop.circle")
            }
            Button {
                appState.copyUserToClipboard(userShort(from: colleague))
                toastMessage = "Bürger kopiert"
                showToast = true
            } label: {
                Label("Zum Bürger kopieren", systemImage: "doc.on.doc")
            }
        }

        Section("Abwesenheit") {
            if let summary = absenceSummary(for: colleague) {
                Label(summary, systemImage: "calendar.badge.plus")
                    .foregroundStyle(.secondary)
            } else {
                Text("Keine Abwesenheit eingetragen.")
                    .foregroundStyle(.secondary)
            }

            Button("Urlaub eintragen") {
                showAbsenceSheet = true
            }
        }

        if !colleague.props.labels.list.isEmpty {
            Section("Labels") {
                FlowLayout(spacing: Theme.Spacing.md) {
                    ForEach(colleague.props.labels.list) { label in
                        Text(label.name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(Color(hex: label.color) ?? .secondary, in: Capsule())
                            .foregroundStyle(textColor(for: label))
                    }
                }
            }
        }
    }

    private func colleagueBadges(_ colleague: Resources_Jobs_Colleagues_Colleague) -> [String] {
        var result: [String] = []
        if colleague.userID > 0 {
            result.append("CIT-\(colleague.userID)")
        }
        if !colleague.props.labels.list.isEmpty {
            result.append(colleague.props.labels.list.map(\.name).joined(separator: ", "))
        }
        return result
    }

    private func colleagueJobLine(_ colleague: Resources_Jobs_Colleagues_Colleague) -> String {
        var parts: [String] = []
        if !colleague.jobLabel.isEmpty { parts.append(colleague.jobLabel) }
        if !colleague.jobGradeLabel.isEmpty { parts.append(colleague.jobGradeLabel) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Activity tab

    @ViewBuilder
    private var activityTab: some View {
        if isActivityLoading && activity.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
        } else if activity.isEmpty {
            EmptyStateView(
                "list.bullet",
                color: Theme.Palette.accent,
                title: "Keine Aktivität",
                message: "Für diesen Kollegen ist noch keine Aktivität vorhanden."
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        } else {
            Section("Aktivität") {
                ForEach(activity) { entry in
                    ActivityRow(
                        icon: entry.activityType.icon,
                        title: entry.activityType.title,
                        subtitle: activitySubtitle(entry)
                    )
                }
            }
        }
    }

    /// Reconstructs the previous grade for each grade-change activity entry.
    /// `GradeChange` only carries the target grade, so the "old" grade is taken
    /// from the next older grade-change entry in the (newest-first) list.
    private var previousGradeLookup: [Int64: Int32] {
        var lookup: [Int64: Int32] = [:]
        var previousGrade: Int32?
        for entry in activity.reversed() {
            if case .gradeChange(let change)? = entry.data.data {
                if let previousGrade {
                    lookup[entry.id] = previousGrade
                }
                previousGrade = change.grade
            }
        }
        return lookup
    }

    private func activitySubtitle(_ entry: Resources_Jobs_Colleagues_Activity_ColleagueActivity) -> String {
        colleagueActivitySubtitle(entry, previousGrade: previousGradeLookup[entry.id])
    }

    // MARK: - Helpers

    private var colleagueTitle: String {
        guard let colleague else { return "Kollege" }
        return [colleague.firstname, colleague.lastname].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func userShort(from colleague: Resources_Jobs_Colleagues_Colleague) -> Resources_Users_Short_UserShort {
        var short = Resources_Users_Short_UserShort()
        short.userID = colleague.userID
        short.job = colleague.job
        if colleague.hasJobLabel { short.jobLabel = colleague.jobLabel }
        short.jobGrade = colleague.jobGrade
        if colleague.hasJobGradeLabel { short.jobGradeLabel = colleague.jobGradeLabel }
        short.firstname = colleague.firstname
        short.lastname = colleague.lastname
        short.dateofbirth = colleague.dateofbirth
        if colleague.hasPhoneNumber { short.phoneNumber = colleague.phoneNumber }
        if colleague.hasProfilePictureFileID { short.profilePictureFileID = colleague.profilePictureFileID }
        if colleague.hasProfilePicture { short.profilePicture = colleague.profilePicture }
        return short
    }

    private func absenceSummary(for colleague: Resources_Jobs_Colleagues_Colleague) -> String? {
        let props = colleague.props
        guard props.hasAbsenceBegin || props.hasAbsenceEnd else { return nil }
        let begin = props.hasAbsenceBegin ? props.absenceBegin.timestamp.date.formatted(date: .abbreviated, time: .omitted) : "–"
        let end = props.hasAbsenceEnd ? props.absenceEnd.timestamp.date.formatted(date: .abbreviated, time: .omitted) : "–"
        return "\(begin) – \(end)"
    }

    private func textColor(for label: Resources_Jobs_Labels_Label) -> Color {
        guard let color = Color(hex: label.color) else { return .primary }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        return luminance > 0.6 ? .black : .white
    }

    // MARK: - Loading

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            colleague = try await appState.getColleague(userID: userID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadActivity() async {
        guard colleague != nil, !isActivityLoading else { return }
        isActivityLoading = true
        defer { isActivityLoading = false }
        do {
            let response = try await appState.listColleagueActivity(userIds: [userID])
            activity = response.activity
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Resources_Jobs_Colleagues_Activity_ColleagueActivityType {
    /// SF Symbol shown for this activity type.
    var icon: String {
        switch self {
        case .hired: return "shippingbox"
        case .fired: return "figure.walk"
        case .promoted: return "chevron.up.circle"
        case .demoted: return "chevron.down.circle"
        case .absenceDate: return "calendar.badge.plus"
        case .note: return "note.text"
        case .labels: return "tag"
        case .name: return "person.crop.circle.badge.checkmark"
        case .unspecified, .UNRECOGNIZED: return "clock"
        }
    }

    /// German past-tense title for the activity row.
    var title: String {
        switch self {
        case .hired: return "Eingestellt"
        case .fired: return "Entlassen"
        case .promoted: return "Befördert"
        case .demoted: return "Degradiert"
        case .absenceDate: return "Abwesenheit geändert"
        case .note: return "Notiz geändert"
        case .labels: return "Labels geändert"
        case .name: return "Name geändert"
        case .unspecified, .UNRECOGNIZED: return "Aktivität"
        }
    }
}

/// Simple flow layout for wrapping label badges.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = computeRows(width: width, subviews: subviews)
        let heights = rows.map { row in
            row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
        }
        let totalHeight = heights.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(width: CGFloat, subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.isEmpty && currentWidth + size.width + spacing > width {
                rows.append(current)
                current = []
                currentWidth = 0
            }
            current.append(index)
            currentWidth += size.width + (current.count > 1 ? spacing : 0)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview {
    NavigationStack {
        ColleagueDetailView(userID: 1)
            .environment(AppState())
    }
}
