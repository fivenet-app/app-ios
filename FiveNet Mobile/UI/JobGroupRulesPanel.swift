import SwiftUI
import SwiftProtobuf

/// Regeln-Tab: smarte Mitgliedschafts-Regeln (Rang- und Qualifikations-Regeln)
/// mit Aktiv/Inaktiv-Toggle, Bearbeiten und Löschen (mit Grund).
/// Spiegelt die Web-`RulesPanel.vue` + `RuleForm.vue`.
struct GroupRulesPanel: View {
    @Environment(AppState.self) private var appState

    let groupID: Int64
    let groupType: Resources_Jobs_Groups_GroupType
    let access: Resources_Access_Access?
    let canView: Bool
    let canManage: Bool

    /// Das Regel-Editor-Sheet hängt NICHT am Panel-Inhalt, sondern am stabilen
    /// `List`-Level der `JobGroupDetailView` (Binding `editorRequest`). Solange
    /// das Panel nachlädt (`.task`-`load()`), würde ein direkt hier verankertes
    /// Sheet beim ersten Öffnen sofort wieder abgerissen (Auto-Close-Bug).
    @Binding var editorRequest: GroupRuleEditorState?
    /// Wird vom Detail-Parent nach dem Speichern erhöht → Panel lädt neu.
    @Binding var reloadToken: Int

    private static let pageSize: Int64 = 20

    @State private var rules: [Resources_Jobs_Groups_GroupRule] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var currentPage: Int64 = 0
    @State private var totalCount: Int64 = 0
    @State private var hasLoaded = false
    @State private var isMutating = false

    @State private var togglingRule: Resources_Jobs_Groups_GroupRule?
    @State private var confirmDelete: Resources_Jobs_Groups_GroupRule?

    var body: some View {
        Group {
            Section {
            if !groupType.allowsRules {
                StatusLabelRow(
                    "Dieser Gruppentyp unterstützt keine automatischen Regeln.",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: Theme.Palette.warning
                )
                .cardRow()
            }

            if let errorMessage {
                StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .cardRow()
            }

            if groupType.allowsRules {
                if canManage {
                    Button {
                        editorRequest = GroupRuleEditorState(groupID: groupID, rule: nil)
                    } label: {
                        HStack {
                            Label("Regel hinzufügen", systemImage: "plus.square.on.square")
                            Spacer()
                            CardChevron()
                        }
                    }
                    .cardRow()
                }

                if isLoading && rules.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if rules.isEmpty {
                    EmptyStateView(
                        "wand.and.stars",
                        color: Theme.Palette.accent,
                        title: "Keine Regeln",
                        message: "Für diese Gruppe wurden noch keine automatischen Regeln definiert."
                    )
                    .cardRow()
                } else {
                    ForEach(rules, id: \.id) { rule in
                        GroupRuleRow(
                            rule: rule,
                            isMutating: isMutating,
                            onToggle: {
                                Task { await toggle(rule) }
                            },
                        onEdit: {
                            editorRequest = GroupRuleEditorState(groupID: groupID, rule: rule)
                        },
                        onDelete: {
                            confirmDelete = rule
                        }
                    )
                    .cardRow()
                }
            }
            }
        }
        .task {
            guard !hasLoaded else { return }
            hasLoaded = true
            guard groupType.allowsRules else { return }
            await load()
        }
        .onChange(of: reloadToken) { _, _ in
            Task { await load(reset: true) }
        }
        .confirmationDialog(
            "Regel löschen",
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                if let confirmDelete {
                    Task { await delete(confirmDelete) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Möchtest du diese Regel wirklich löschen?")
        }
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
            let response = try await appState.listGroupRules(
                groupID: groupID,
                offset: target * Self.pageSize,
                pageSize: Self.pageSize
            )
            rules = response.rules
            totalCount = response.pagination.totalCount
            currentPage = target
        } catch {
            errorMessage = error.localizedDescription
            currentPage = previous
        }
    }

    func toggle(_ rule: Resources_Jobs_Groups_GroupRule) async {
        togglingRule = rule
        isMutating = true
        defer { isMutating = false; togglingRule = nil }
        do {
            var input = Services_Jobs_GroupRuleInput()
            input.enabled = !rule.enabled
            switch rule.rule {
            case .grade(let grade):
                input.grade = grade
            case .qualification(let qualification):
                input.qualification = qualification
            case nil:
                break
            }
            _ = try await appState.updateGroupRule(groupID: groupID, ruleID: rule.id, rule: input)
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ rule: Resources_Jobs_Groups_GroupRule) async {
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await appState.deleteGroupRule(groupID: groupID, ruleID: rule.id)
            confirmDelete = nil
            await load(reset: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Beschreibung des (hochgezogenen) Regel-Editor-Sheets. Das Sheet wird von der
/// `JobGroupDetailView` am stabilen `List`-Level präsentiert (`.sheet(item:)`),
/// damit es beim Nachladen des Regeln-Panels nicht abgerissen wird.
struct GroupRuleEditorState: Identifiable {
    let id = UUID()
    let groupID: Int64
    let rule: Resources_Jobs_Groups_GroupRule?
}

/// Zeile einer Gruppen-Regel: Label, Aktiv-Toggle, Bearbeiten/Löschen.
private struct GroupRuleRow: View {
    let rule: Resources_Jobs_Groups_GroupRule
    let isMutating: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            Image(systemName: "square.3.layers.3d")
                .font(.subheadline)
                .foregroundStyle(rule.enabled ? Theme.Palette.success : Theme.Palette.neutral)
                .frame(width: 32, height: 32)
                .background((rule.enabled ? Theme.Palette.success : Theme.Palette.neutral).opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(rule.label)
                    .font(Theme.Typography.headline)
                    .lineLimit(2)

                HStack(spacing: Theme.Spacing.xs) {
                    Text(rule.enabled ? "Aktiv" : "Inaktiv")
                        .font(Theme.Typography.caption2)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background((rule.enabled ? Theme.Palette.success : Theme.Palette.neutral).opacity(0.14), in: Capsule())
                    if rule.hasCreatedAt {
                        Text(formatTimestamp(rule.createdAt))
                            .font(Theme.Typography.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(isMutating)

            Menu {
                Button {
                    onEdit()
                } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Löschen", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// Sheet zum Erstellen/Bearbeiten einer Gruppen-Regel (Rang oder Qualifikation).
/// Spiegelt die Web-`RuleForm.vue` + `GroupGradeRuleForm.vue`/`GroupQualificationRuleForm.vue`.
struct GroupRuleEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let groupID: Int64
    let rule: Resources_Jobs_Groups_GroupRule?
    let onSaved: (Resources_Jobs_Groups_GroupRule?) -> Void

    @State private var ruleKind: RuleKind = .grade
    @State private var enabled = true

    // Rang-Regel
    @State private var gradeType: Resources_Jobs_Groups_GroupGradeRuleType = .minimum
    @State private var grade: Int32 = 1
    @State private var minGrade: Int32 = 1
    @State private var maxGrade: Int32 = 30
    @State private var gradeLabel = ""

    // Qualifikations-Regel
    @State private var qualificationType: Resources_Jobs_Groups_GroupQualificationRuleType = .any
    @State private var selectedQualificationIDs: Set<Int64> = []
    @State private var requireCompleted = true
    @State private var qualifications: [Resources_Qualifications_Qualification] = []
    @State private var isLoadingQualifications = false

    @State private var reason = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private enum RuleKind: String, CaseIterable, Identifiable {
        case grade = "Rang-Regel"
        case qualification = "Qualifikations-Regel"

        var id: String { rawValue }
    }

    private var canSave: Bool {
        switch ruleKind {
        case .grade:
            return gradeType != .unspecified
        case .qualification:
            return !selectedQualificationIDs.isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .cardRow()
                    }
                }

                Section("Regel-Typ") {
                    Picker("Typ", selection: $ruleKind) {
                        ForEach(RuleKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: ruleKind) { _, _ in
                        // Selection in die richtige Struktur übernehmen
                    }
                    Toggle("Aktiv", isOn: $enabled)
                }

                switch ruleKind {
                case .grade:
                    gradeSection
                case .qualification:
                    qualificationSection
                }

                Section {
                    TextField("Grund (optional)", text: $reason, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle(rule == nil ? "Regel erstellen" : "Regel bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving)
            }
            }
            }
        .task {
            seed()
            if ruleKind == .qualification || rule?.rule != nil {
                await loadQualifications()
            }
        }
    }

    @ViewBuilder
    private var gradeSection: some View {
        Section("Rang-Regel") {
            Picker("Bedingung", selection: $gradeType) {
                Text("Mindestens").tag(Resources_Jobs_Groups_GroupGradeRuleType.minimum)
                Text("Exakt").tag(Resources_Jobs_Groups_GroupGradeRuleType.exact)
                Text("Bereich").tag(Resources_Jobs_Groups_GroupGradeRuleType.range)
            }

            switch gradeType {
            case .minimum, .exact:
                Stepper(value: $grade, in: 0...30) {
                    HStack {
                        Text("Rang")
                        Spacer()
                        Text(gradeLabelText(grade))
                            .foregroundStyle(.secondary)
                    }
                }
            case .range:
                Stepper(value: $minGrade, in: 0...30) {
                    HStack {
                        Text("Von")
                        Spacer()
                        Text(gradeLabelText(minGrade))
                            .foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $maxGrade, in: minGrade...30) {
                    HStack {
                        Text("Bis")
                        Spacer()
                        Text(gradeLabelText(maxGrade))
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var qualificationSection: some View {
        Section {
            Picker("Bedingung", selection: $qualificationType) {
                Text("Alle ausgewählten").tag(Resources_Jobs_Groups_GroupQualificationRuleType.all)
                Text("Mindestens eine").tag(Resources_Jobs_Groups_GroupQualificationRuleType.any)
            }
            Toggle("Nur bestandene Qualifikationen zählen", isOn: $requireCompleted)
        }

        Section("Qualifikationen") {
            if isLoadingQualifications {
                HStack {
                    ProgressView()
                    Text("Lade Qualifikationen …")
                        .foregroundStyle(.secondary)
                }
            } else if qualifications.isEmpty {
                Text("Keine Qualifikationen verfügbar.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(qualifications) { qualification in
                    Button {
                        if selectedQualificationIDs.contains(qualification.id) {
                            selectedQualificationIDs.remove(qualification.id)
                        } else {
                            selectedQualificationIDs.insert(qualification.id)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("\(qualification.abbreviation): \(qualification.title)")
                                    .font(.subheadline)
                                Text("QUAL-\(qualification.id)")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedQualificationIDs.contains(qualification.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private func seed() {
        guard let rule else {
            ruleKind = .grade
            enabled = true
            return
        }
        enabled = rule.enabled
        switch rule.rule {
        case .grade(let gradeRule):
            ruleKind = .grade
            gradeType = gradeRule.type
            grade = gradeRule.grade
            minGrade = gradeRule.minGrade
            maxGrade = gradeRule.maxGrade
            gradeLabel = gradeRule.gradeLabel
        case .qualification(let qualificationRule):
            ruleKind = .qualification
            qualificationType = qualificationRule.type
            selectedQualificationIDs = Set(qualificationRule.qualificationIds)
            requireCompleted = qualificationRule.requireCompleted
        case nil:
            break
        }
    }

    private func gradeLabelText(_ value: Int32) -> String {
        guard value != 0 else { return "Rang 0" }
        return "Rang \(value)"
    }

    func loadQualifications() async {
        isLoadingQualifications = true
        defer { isLoadingQualifications = false }
        do {
            let response = try await appState.listQualifications(search: "", pageSize: 100)
            qualifications = response.qualifications
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }

        var input = Services_Jobs_GroupRuleInput()
        input.enabled = enabled
        switch ruleKind {
        case .grade:
            var gradeRule = Resources_Jobs_Groups_GroupGradeRule()
            gradeRule.type = gradeType
            switch gradeType {
            case .minimum, .exact:
                gradeRule.grade = grade
                if !gradeLabel.isEmpty {
                    gradeRule.gradeLabel = gradeLabel
                }
            case .range:
                gradeRule.minGrade = minGrade
                gradeRule.maxGrade = maxGrade
            default:
                break
            }
            input.grade = gradeRule
        case .qualification:
            var qualificationRule = Resources_Jobs_Groups_GroupQualificationRule()
            qualificationRule.type = qualificationType
            qualificationRule.qualificationIds = Array(selectedQualificationIDs).sorted()
            qualificationRule.requireCompleted = requireCompleted
            input.qualification = qualificationRule
        }

        do {
            if let rule {
                let response = try await appState.updateGroupRule(groupID: groupID, ruleID: rule.id, rule: input, reason: reason)
                onSaved(response.hasRule ? response.rule : nil)
            } else {
                let response = try await appState.createGroupRule(groupID: groupID, rule: input, reason: reason)
                onSaved(response.hasRule ? response.rule : nil)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
