import SwiftUI
import SwiftProtobuf

/// Vollwertiger Qualifikations-Editor für Erstellen und Bearbeiten (4 Tabs:
/// Inhalt, Zugriff, Details, Prüfung). Spiegelt die Web-`Editor.vue` (Create + Update).
struct QualificationEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Die zu bearbeitende Qualifikation. `nil` = Erstellen (neue Qualifikation
    /// wird im `.task` angelegt und dann befüllt).
    let qualification: Resources_Qualifications_Qualification?
    var onSaved: (Int64) -> Void

    // MARK: - Tabs

    private enum Tab: String, CaseIterable, Identifiable {
        case content = "Inhalt"
        case access = "Zugriff"
        case details = "Details"
        case exam = "Prüfung"

        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .content

    // MARK: - Lade-/Speicherzustand

    @State private var qualificationID: Int64 = 0
    @State private var loaded: Resources_Qualifications_Qualification?
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSeedOrCreate = false

    // MARK: - Inhalt (Tab 1)

    @State private var abbreviation = ""
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var draft = false
    @State private var closed = false
    @State private var isPublic = false
    @State private var contentText = ""

    // MARK: - Zugriff (Tab 2)

    @State private var jobAccess: [Resources_Access_JobAccess] = []
    @State private var userAccess: [Resources_Access_UserAccess] = []
    @State private var showJobAccessSheet = false
    @State private var showUserAccessSheet = false

    // MARK: - Details (Tab 3)

    @State private var requirements: [Resources_Qualifications_QualificationRequirement] = []
    @State private var showRequirementPicker = false

    @State private var discordSyncEnabled = false
    @State private var discordRoleName = ""
    @State private var discordRoleFormat = "%abbr%: %name%"

    @State private var labelSyncEnabled = false
    @State private var labelSyncFormat = "%abbr%: %name%"

    // MARK: - Prüfung (Tab 4)

    @State private var examMode: Resources_Qualifications_Exam_QualificationExamMode = .unspecified
    @State private var autoGrade = false
    @State private var autoGradeMode: Resources_Qualifications_Exam_AutoGradeMode = .unspecified
    @State private var minimumPoints: Int = 0
    @State private var questions: [ExamQuestionDraft] = []

    // MARK: - Derived

    private var canEditPublic: Bool {
        appState.attr("qualifications.QualificationsService/UpdateQualification", key: "Fields", value: "Public")
    }

    private var canSave: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
    }

    private var examVisible: Bool {
        examMode != .unspecified && examMode != .disabled
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && loaded == nil {
                    List {
                        ForEach(0..<5, id: \.self) { _ in
                            SkeletonListRow()
                        }
                    }
                    .cardListStyle()
                } else if let errorMessage, loaded == nil {
                    List {
                        EmptyStateView(
                            "exclamationmark.triangle",
                            color: Theme.Palette.danger,
                            title: "Fehler",
                            message: errorMessage,
                            actionTitle: "Erneut versuchen"
                        ) {
                            Task { await start() }
                        }
                    }
                    .cardListStyle()
                } else {
                    content
                }
            }
            .navigationTitle(qualification == nil ? "Qualifikation erstellen" : "Qualifikation bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        dismiss()
                    }
                    .disabled(isSaving || isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        Task { await save() }
                    }
                    .disabled(!canSave || isSaving || isLoading || loaded == nil)
                }
            }
            .task {
                guard !didSeedOrCreate else { return }
                didSeedOrCreate = true
                await start()
            }
            .sheet(isPresented: $showJobAccessSheet) {
                QualAccessJobSheet { entry in
                    jobAccess.append(entry)
                }
                .environment(appState)
            }
            .sheet(isPresented: $showUserAccessSheet) {
                QualAccessUserSheet { entry in
                    userAccess.append(entry)
                }
                .environment(appState)
            }
            .sheet(isPresented: $showRequirementPicker) {
                QualRequirementPickerSheet { picked in
                    var req = Resources_Qualifications_QualificationRequirement()
                    req.targetQualificationID = picked.id
                    req.targetQualification = picked
                    requirements.append(req)
                }
                .environment(appState)
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                PillTabBar(tabs: Tab.allCases, selection: $selectedTab) { $0.rawValue }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if let errorMessage {
                Section {
                    StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .cardRow()
                }
            }

            switch selectedTab {
            case .content:
                contentTab
            case .access:
                accessTab
            case .details:
                detailsTab
            case .exam:
                examTab
            }
        }
        .cardListStyle()
    }

    // MARK: - Tab 1: Inhalt

    private var contentTab: some View {
        Group {
            Section("Abkürzung") {
                TextField("z. B. HCTM", text: $abbreviation)
                    .onChange(of: abbreviation) { _, newValue in
                        if newValue.count > 20 { abbreviation = String(newValue.prefix(20)) }
                    }
                Text("\(abbreviation.count)/20")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Titel") {
                TextField("Titel (Pflicht)", text: $title, axis: .vertical)
                    .lineLimit(1...3)
                    .onChange(of: title) { _, newValue in
                        if newValue.count > 255 { title = String(newValue.prefix(255)) }
                    }
                Text("\(title.count)/255")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Beschreibung") {
                TextField("Beschreibung (optional)", text: $descriptionText, axis: .vertical)
                    .lineLimit(1...4)
                    .onChange(of: descriptionText) { _, newValue in
                        if newValue.count > 512 { descriptionText = String(newValue.prefix(512)) }
                    }
                Text("\(descriptionText.count)/512")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Status") {
                Toggle("Entwurf", isOn: $draft)
                Toggle("Geschlossen", isOn: $closed)
                if canEditPublic {
                    Toggle("Öffentlich", isOn: $isPublic)
                }
            }
            Section("Inhalt") {
                TextEditor(text: $contentText)
                    .font(.system(size: 14))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                Text("Der Inhalt wird als normaler Text gespeichert.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tab 2: Zugriff

    private var accessTab: some View {
        Group {
            Section {
                Button {
                    showJobAccessSheet = true
                } label: {
                    Label("Job-Zugriff hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .cardRow()
            }
            .listRowSeparator(.hidden)

            Section("Berufs-Zugriffe") {
                if jobAccess.isEmpty {
                    Label("Keine Berufs-Zugriffe", systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .cardRow()
                } else {
                    ForEach(jobAccess, id: \.id) { job in
                        accessJobRow(job)
                            .cardRow()
                    }
                }
            }

            Section {
                Button {
                    showUserAccessSheet = true
                } label: {
                    Label("Nutzer-Zugriff hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .cardRow()
            }
            .listRowSeparator(.hidden)

            Section("Nutzer-Zugriffe") {
                if userAccess.isEmpty {
                    Label("Keine Nutzer-Zugriffe", systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .cardRow()
                } else {
                    ForEach(userAccess, id: \.id) { user in
                        accessUserRow(user)
                            .cardRow()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accessJobRow(_ job: Resources_Access_JobAccess) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(jobDisplayName(job))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(accessLevelLabel(job.access))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if job.minimumGrade > 0 {
                    Text("Mindestrang: \(job.minimumGrade)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if job.required {
                Text("erforderlich")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Button {
                jobAccess.removeAll { $0.job == job.job }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.Palette.danger)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Entfernen")
        }
    }

    @ViewBuilder
    private func accessUserRow(_ user: Resources_Access_UserAccess) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(userHasName(user) ? userShortName(user.user) : "CIT-\(user.userID)")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Text(accessLevelLabel(user.access))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if user.required {
                Text("erforderlich")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Button {
                userAccess.removeAll { $0.userID == user.userID }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.Palette.danger)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Entfernen")
        }
    }

    // MARK: - Tab 3: Details

    private var detailsTab: some View {
        Group {
            Section("Anforderungen") {
                if requirements.isEmpty {
                    Label("Keine Anforderungen", systemImage: "list.number")
                        .foregroundStyle(.secondary)
                        .cardRow()
                } else {
                    ForEach(requirements, id: \.id) { requirement in
                        HStack(spacing: Theme.Spacing.lg) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(requirementTitle(requirement))
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            Button {
                                requirements.removeAll { $0.targetQualificationID == requirement.targetQualificationID }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(Theme.Palette.danger)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Entfernen")
                        }
                        .cardRow()
                    }
                }

                Button {
                    showRequirementPicker = true
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .cardRow()
            }

            Section("Discord-Sync") {
                Toggle("Aktiviert", isOn: $discordSyncEnabled)
                if discordSyncEnabled {
                    TextField("Rollenname", text: $discordRoleName)
                        .onChange(of: discordRoleName) { _, newValue in
                            if newValue.count > 64 { discordRoleName = String(newValue.prefix(64)) }
                        }
                    TextField("Rollenformat", text: $discordRoleFormat)
                        .onChange(of: discordRoleFormat) { _, newValue in
                            if newValue.count > 64 { discordRoleFormat = String(newValue.prefix(64)) }
                        }
                    Text("%abbr% und %name% werden durch Abkürzung und Titel ersetzt.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Label-Sync") {
                Toggle("Aktiviert", isOn: $labelSyncEnabled)
                if labelSyncEnabled {
                    TextField("Format", text: $labelSyncFormat)
                        .onChange(of: labelSyncFormat) { _, newValue in
                            if newValue.count > 128 { labelSyncFormat = String(newValue.prefix(128)) }
                        }
                    Text("%abbr% und %name% werden durch Abkürzung und Titel ersetzt.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Tab 4: Prüfung

    private var examTab: some View {
        Group {
            Section("Prüfungsmodus") {
                Picker("Modus", selection: $examMode) {
                    ForEach([Resources_Qualifications_Exam_QualificationExamMode.unspecified,
                             .disabled, .requestNeeded, .enabled], id: \.rawValue) { mode in
                        Text(examModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            if examVisible {
                Section("Prüfungseinstellungen") {
                    Toggle("Automatisch bewerten", isOn: $autoGrade)
                    if autoGrade {
                        Picker("Modus", selection: $autoGradeMode) {
                            ForEach([Resources_Qualifications_Exam_AutoGradeMode.unspecified,
                                     .strict, .partialCredit], id: \.rawValue) { mode in
                                Text(autoGradeModeLabel(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Stepper("Mindestpunkte: \(minimumPoints)", value: $minimumPoints, in: 0...100)
                }

                Section("Fragen") {
                    if questions.isEmpty {
                        Label("Keine Fragen", systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                            .cardRow()
                    } else {
                        ForEach(questions) { question in
                            questionRow(question)
                                .cardRow()
                        }
                    }

                    Menu {
                        Button {
                            addQuestion(.separator)
                        } label: {
                            Label("Trennlinie", systemImage: "minus")
                        }
                        Button {
                            addQuestion(.freeText)
                        } label: {
                            Label("Text (Freitext)", systemImage: "text.alignleft")
                        }
                        Button {
                            addQuestion(.yesno)
                        } label: {
                            Label("Ja/Nein", systemImage: "checkmark.circle")
                        }
                        Button {
                            addQuestion(.singleChoice)
                        } label: {
                            Label("Einfachwahl", systemImage: "circle.circle")
                        }
                        Button {
                            addQuestion(.multipleChoice)
                        } label: {
                            Label("Mehrfachwahl", systemImage: "checklist")
                        }
                    } label: {
                        Label("Frage hinzufügen", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.Palette.accent)
                    .cardRow()
                }
            }
        }
    }

    @ViewBuilder
    private func questionRow(_ draft: ExamQuestionDraft) -> some View {
        let index = index(of: draft)
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("#\(index + 1)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        moveQuestion(draft, up: true)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel("Aufwärts")
                    Button {
                        moveQuestion(draft, up: false)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == questions.count - 1)
                    .accessibilityLabel("Abwärts")
                    Button {
                        removeQuestion(draft)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Entfernen")
                }
            }
            questionBinding(draft)
        }
    }

    @ViewBuilder
    private func questionBinding(_ draft: ExamQuestionDraft) -> some View {
        if let idx = indexOptional(of: draft) {
            TextField("Frage", text: $questions[idx].title)
                .onChange(of: questions[idx].title) { _, newValue in
                    if newValue.count > 512 { questions[idx].title = String(newValue.prefix(512)) }
                }
            TextField("Beschreibung (optional)", text: $questions[idx].descriptionText)
                .onChange(of: questions[idx].descriptionText) { _, newValue in
                    if newValue.count > 1024 { questions[idx].descriptionText = String(newValue.prefix(1024)) }
                }
            Stepper("Punkte: \(questions[idx].points)", value: $questions[idx].points, in: 0...100)

            switch questions[idx].type {
            case .separator, .yesno:
                EmptyView()
            case .freeText:
                Stepper("Min. Länge: \(questions[idx].minLength)", value: $questions[idx].minLength, in: 0...5000)
                Stepper("Max. Länge: \(questions[idx].maxLength)", value: $questions[idx].maxLength, in: 0...5000)
            case .singleChoice:
                choiceList(for: idx)
            case .multipleChoice:
                Stepper("Limit: \(questions[idx].limit)", value: $questions[idx].limit, in: 0...10)
                choiceList(for: idx)
            }
        }
    }

    @ViewBuilder
    private func choiceList(for idx: Int) -> some View {
        ForEach(questions[idx].choices.indices, id: \.self) { choiceIndex in
            HStack {
                Image(systemName: questions[idx].type == .singleChoice ? "circle" : "square")
                    .foregroundStyle(.secondary)
                TextField("Antwort \(choiceIndex + 1)", text: $questions[idx].choices[choiceIndex])
                    .onChange(of: questions[idx].choices[choiceIndex]) { _, newValue in
                        if newValue.count > 512 { questions[idx].choices[choiceIndex] = String(newValue.prefix(512)) }
                    }
                Button {
                    questions[idx].choices.remove(at: choiceIndex)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Antwort entfernen")
            }
        }
        Button {
            if questions[idx].choices.count < 10 {
                questions[idx].choices.append("")
            }
        } label: {
            Label("Antwort hinzufügen", systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .disabled(questions[idx].choices.count >= 10)
    }

    // MARK: - Questions helpers

    private func index(of draft: ExamQuestionDraft) -> Int {
        questions.firstIndex { $0.id == draft.id } ?? questions.count - 1
    }

    private func indexOptional(of draft: ExamQuestionDraft) -> Int? {
        questions.firstIndex { $0.id == draft.id }
    }

    private func addQuestion(_ type: ExamQuestionKind) {
        questions.append(ExamQuestionDraft(type: type))
    }

    private func removeQuestion(_ draft: ExamQuestionDraft) {
        questions.removeAll { $0.id == draft.id }
    }

    private func moveQuestion(_ draft: ExamQuestionDraft, up: Bool) {
        guard let from = indexOptional(of: draft) else { return }
        let to = up ? from - 1 : from + 1
        guard to >= 0 && to < questions.count else { return }
        questions.swapAt(from, to)
    }

    // MARK: - Create / Seed

    private func start() async {
        if let qualification {
            seed(from: qualification)
        } else {
            await create()
        }
    }

    private func create() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let created = try await appState.createQualification(contentType: .html)
            let id = created.qualificationID
            let response = try await appState.getQualification(id: id)
            let loadedQual = response.qualification
            qualificationID = id
            loaded = loadedQual
            seed(from: loadedQual, isNew: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func seed(from qual: Resources_Qualifications_Qualification, isNew: Bool = false) {
        qualificationID = qual.id
        loaded = qual
        abbreviation = qual.abbreviation
        title = qual.title
        descriptionText = qual.hasDescription_p ? qual.description_p : ""
        draft = qual.draft
        isPublic = qual.`public`
        closed = qual.closed

        if isNew {
            contentText = ""
        } else if qual.hasContent {
            contentText = WikiContent.plainText(for: qual.content)
        } else {
            contentText = ""
        }

        if qual.hasAccess {
            jobAccess = qual.access.jobs
            userAccess = qual.access.users
        }
        requirements = qual.requirements

        discordSyncEnabled = qual.discordSyncEnabled
        if qual.hasDiscordSettings {
            discordRoleName = qual.discordSettings.hasRoleName ? qual.discordSettings.roleName : ""
            discordRoleFormat = qual.discordSettings.hasRoleFormat ? qual.discordSettings.roleFormat : "%abbr%: %name%"
        } else {
            discordRoleName = ""
            discordRoleFormat = "%abbr%: %name%"
        }

        labelSyncEnabled = qual.labelSyncEnabled
        labelSyncFormat = qual.hasLabelSyncFormat ? qual.labelSyncFormat : "%abbr%: %name%"

        examMode = qual.examMode
        if qual.hasExamSettings {
            autoGrade = qual.examSettings.autoGrade
            autoGradeMode = qual.examSettings.autoGradeMode
            minimumPoints = Int(qual.examSettings.minimumPoints)
        } else {
            autoGrade = false
            autoGradeMode = .unspecified
            minimumPoints = 0
        }

        questions.removeAll()
        if qual.hasExam {
            questions = qual.exam.questions.map { draftFromProto($0) }
        }
    }

    // MARK: - Save

    private func save() async {
        guard let base = loaded else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var updated = base
            updated.job = ""
            updated.weight = 0
            updated.closed = closed
            updated.draft = draft
            updated.`public` = canEditPublic ? isPublic : base.`public`
            updated.abbreviation = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDescription.isEmpty {
                updated.clearDescription_p()
            } else {
                updated.description_p = trimmedDescription
            }

            // Web `Editor.vue` sendet creatorId/creatorJob aus dem aktiven Char.
            if let creatorID = appState.activeCharacterUserID {
                updated.creatorID = creatorID
            }
            updated.creatorJob = appState.character?.job ?? base.creatorJob

            if updated.examMode == .unspecified {
                updated.examMode = .disabled
            }

            // Inhalt als Tiptap-Dokument.
            var content = Resources_Common_Content_Content()
            content.contentType = .tiptapJson
            content.tiptapJson = tiptapDoc(text: contentText)
            updated.content = content

            // Zugriff.
            var access = Resources_Access_Access()
            access.jobs = jobAccess
            access.users = userAccess
            updated.access = access

            // Anforderungen. Bei neuen Einträgen ist die id 0 und der Server
            // legt sie (über qualificationID) selbst an.
            updated.requirements = requirements

            // Discord-Sync.
            updated.discordSyncEnabled = discordSyncEnabled
            if discordSyncEnabled {
                var settings = Resources_Qualifications_QualificationDiscordSettings()
                let roleName = discordRoleName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !roleName.isEmpty {
                    settings.roleName = roleName
                }
                let roleFormat = discordRoleFormat.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.roleFormat = roleFormat.isEmpty ? "%abbr%: %name%" : roleFormat
                updated.discordSettings = settings
            } else {
                updated.clearDiscordSettings()
            }

            // Label-Sync.
            updated.labelSyncEnabled = labelSyncEnabled
            if labelSyncEnabled {
                let format = labelSyncFormat.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.labelSyncFormat = format.isEmpty ? "%abbr%: %name%" : format
            } else {
                updated.clearLabelSyncFormat()
            }

            // Prüfung.
            updated.examMode = examMode
            if examVisible {
                var settings = Resources_Qualifications_Exam_QualificationExamSettings()
                settings.autoGrade = autoGrade
                settings.autoGradeMode = autoGradeMode
                settings.minimumPoints = Int32(minimumPoints)
                updated.examSettings = settings

                var exam = Resources_Qualifications_Exam_ExamQuestions()
                for (i, q) in questions.enumerated() {
                    var proto = protoFromDraft(q)
                    proto.qualificationID = qualificationID
                    proto.order = Int32(i)
                    exam.questions.append(proto)
                }
                updated.exam = exam
            } else {
                updated.clearExamSettings()
                updated.clearExam()
            }

            let response = try await appState.updateQualification(updated)
            onSaved(response.qualificationID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Proto <-> Draft conversion for questions

    private func draftFromProto(_ q: Resources_Qualifications_Exam_ExamQuestion) -> ExamQuestionDraft {
        var draft = ExamQuestionDraft()
        draft.id = q.id
        draft.isExisting = true

        switch q.data.data {
        case .separator:
            draft.type = .separator
        case .yesno:
            draft.type = .yesno
        case .freeText(let text):
            draft.type = .freeText
            draft.minLength = Int(text.minLength)
            draft.maxLength = Int(text.maxLength)
        case .singleChoice(let choice):
            draft.type = .singleChoice
            draft.choices = choice.choices
            draft.limit = 1
        case .multipleChoice(let choice):
            draft.type = .multipleChoice
            draft.choices = choice.choices
            draft.limit = Int(choice.hasLimit ? choice.limit : 0)
        case .image, .none:
            // Bilder werden im Editor nicht unterstützt — als Freitext-Fallback.
            draft.type = .freeText
        }
        draft.title = q.title
        draft.descriptionText = q.hasDescription_p ? q.description_p : ""
        draft.points = Int(q.hasPoints ? q.points : 0)
        return draft
    }

    private func protoFromDraft(_ draft: ExamQuestionDraft) -> Resources_Qualifications_Exam_ExamQuestion {
        var q = Resources_Qualifications_Exam_ExamQuestion()
        q.id = draft.id
        q.title = draft.title
        if !draft.descriptionText.isEmpty {
            q.description_p = draft.descriptionText
        }
        q.points = Int32(draft.points)

        switch draft.type {
        case .separator:
            q.data.separator = Resources_Qualifications_Exam_ExamQuestionSeparator()
        case .yesno:
            q.data.yesno = Resources_Qualifications_Exam_ExamQuestionYesNo()
        case .freeText:
            var text = Resources_Qualifications_Exam_ExamQuestionText()
            text.minLength = Int32(draft.minLength)
            text.maxLength = Int32(draft.maxLength)
            q.data.freeText = text
        case .singleChoice:
            var choice = Resources_Qualifications_Exam_ExamQuestionSingleChoice()
            choice.choices = draft.choices
            q.data.singleChoice = choice
        case .multipleChoice:
            var choice = Resources_Qualifications_Exam_ExamQuestionMultipleChoice()
            choice.choices = draft.choices
            choice.limit = Int32(draft.limit)
            q.data.multipleChoice = choice
        }
        return q
    }

    // MARK: - Helpers

    private func jobDisplayName(_ job: Resources_Access_JobAccess) -> String {
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

    private func userHasName(_ user: Resources_Access_UserAccess) -> Bool {
        user.hasUser
    }

    private func requirementTitle(_ requirement: Resources_Qualifications_QualificationRequirement) -> String {
        if requirement.hasTargetQualification {
            let qual = requirement.targetQualification
            let abbreviation = qual.abbreviation
            let name = qual.title
            if !abbreviation.isEmpty {
                return name.isEmpty ? abbreviation : "\(abbreviation): \(name)"
            }
            return name.isEmpty ? formatQualificationID(requirement.targetQualificationID) : name
        }
        return formatQualificationID(requirement.targetQualificationID)
    }

    private func accessLevelLabel(_ level: Int32) -> String {
        switch level {
        case 0: return "Nicht festgelegt"
        case 1: return "Blockiert"
        case 2: return "Ansehen"
        case 3: return "Anfrage"
        case 4: return "Abnehmen"
        case 5: return "Bewerten"
        case 6: return "Bearbeiten"
        default: return "Stufe \(level)"
        }
    }

    private func examModeLabel(_ mode: Resources_Qualifications_Exam_QualificationExamMode) -> String {
        switch mode {
        case .unspecified: return "Nicht spezifiziert"
        case .disabled: return "Deaktiviert"
        case .requestNeeded: return "Auf Anfrage"
        case .enabled: return "Aktiviert"
        case .UNRECOGNIZED: return "Nicht spezifiziert"
        }
    }

    private func autoGradeModeLabel(_ mode: Resources_Qualifications_Exam_AutoGradeMode) -> String {
        switch mode {
        case .unspecified: return "Nicht spezifiziert"
        case .strict: return "Streng"
        case .partialCredit: return "Teilpunkte"
        case .UNRECOGNIZED: return "Nicht spezifiziert"
        }
    }

    private func tiptapDoc(text: String) -> Google_Protobuf_Struct {
        var doc = Google_Protobuf_Struct()
        doc.fields["type"] = .with { $0.stringValue = "doc" }
        var paragraph = Google_Protobuf_Struct()
        paragraph.fields["type"] = .with { $0.stringValue = "paragraph" }
        var textNode = Google_Protobuf_Struct()
        textNode.fields["type"] = .with { $0.stringValue = "text" }
        textNode.fields["text"] = .with { $0.stringValue = text }
        paragraph.fields["content"] = .with { $0.listValue = .with {
            $0.values = [Google_Protobuf_Value.with { $0.structValue = textNode }]
        } }
        doc.fields["content"] = .with { $0.listValue = .with {
            $0.values = [Google_Protobuf_Value.with { $0.structValue = paragraph }]
        } }
        return doc
    }
}

// MARK: - Question draft model

/// Frage-Typ im Editor. Bilder werden bewusst nicht unterstützt (Web erlaubt
/// sie, die App rendert Freitext-Fallbacks für bestehende Bild-Fragen).
private enum ExamQuestionKind {
    case separator
    case yesno
    case freeText
    case singleChoice
    case multipleChoice
}

/// Editierbarer Zwischenzustand einer Prüfungsfrage.
private struct ExamQuestionDraft: Identifiable {
    var id: Int64 = Int64.random(in: 1...Int64.max)
    var isExisting = false
    var type: ExamQuestionKind = .freeText
    var title = ""
    var descriptionText = ""
    var points = 0
    var minLength = 0
    var maxLength = 0
    var choices: [String] = []
    var limit = 1
}

// MARK: - Access add sheets

/// Sheet zum Hinzufügen eines Job-Zugriffs: Beruf wird per Freitext eingegeben
/// (Job-Code), Zugriffs-Level und optionales "erforderlich"-Flag werden gewählt.
private struct QualAccessJobSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onAdd: (Resources_Access_JobAccess) -> Void

    private static let levels: [Int32] = [2, 3, 4, 5, 6]

    @State private var jobCode = ""
    @State private var selectedLevel: Int32 = 2
    @State private var required = false

    private var canAdd: Bool {
        let trimmed = jobCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 20
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Beruf") {
                    TextField("Job-Code (z. B. police)", text: $jobCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Zugriff") {
                    Picker("Level", selection: $selectedLevel) {
                        ForEach(Self.levels, id: \.self) { level in
                            Text(accessLevelLabel(level)).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Toggle("Erforderlich", isOn: $required)
                }
            }
            .navigationTitle("Job-Zugriff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        var entry = Resources_Access_JobAccess()
                        entry.id = Int64.random(in: 1...Int64.max)
                        entry.job = jobCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        entry.access = selectedLevel
                        entry.required = required
                        onAdd(entry)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func accessLevelLabel(_ level: Int32) -> String {
        switch level {
        case 2: return "Ansehen"
        case 3: return "Anfrage"
        case 4: return "Abnehmen"
        case 5: return "Bewerten"
        case 6: return "Bearbeiten"
        default: return "Stufe \(level)"
        }
    }
}

/// Sheet zum Hinzufügen eines Nutzer-Zugriffs: Bürger-Suche über
/// `completeCitizens`, Zugriffs-Level und optionales "erforderlich"-Flag.
private struct QualAccessUserSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onAdd: (Resources_Access_UserAccess) -> Void

    private static let levels: [Int32] = [2, 3, 4, 5, 6]

    @State private var searchText = ""
    @State private var results: [Resources_Users_Short_UserShort] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedUser: Resources_Users_Short_UserShort?
    @State private var selectedLevel: Int32 = 2
    @State private var required = false

    private var canAdd: Bool {
        selectedUser != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bürger") {
                    if let selectedUser {
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(userShortName(selectedUser))
                                    .font(.subheadline.weight(.medium))
                                Text("CIT-\(selectedUser.userID)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                self.selectedUser = nil
                                searchText = ""
                                results = []
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        TextField("Bürger suchen …", text: $searchText)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                        }
                        if !results.isEmpty {
                            ForEach(results, id: \.userID) { user in
                                Button {
                                    selectedUser = user
                                    results = []
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
                Section("Zugriff") {
                    Picker("Level", selection: $selectedLevel) {
                        ForEach(Self.levels, id: \.self) { level in
                            Text(accessLevelLabel(level)).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section {
                    Toggle("Erforderlich", isOn: $required)
                }
            }
            .navigationTitle("Nutzer-Zugriff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hinzufügen") {
                        guard let selectedUser else { return }
                        var entry = Resources_Access_UserAccess()
                        entry.id = Int64.random(in: 1...Int64.max)
                        entry.userID = selectedUser.userID
                        entry.user = selectedUser
                        entry.access = selectedLevel
                        entry.required = required
                        onAdd(entry)
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
            .onChange(of: searchText) {
                searchTask?.cancel()
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    results = []
                    isSearching = false
                    return
                }
                let task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    isSearching = true
                    defer { isSearching = false }
                    let found = (try? await appState.completeCitizens(search: query)) ?? []
                    guard !Task.isCancelled else { return }
                    results = found
                }
                searchTask = task
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func accessLevelLabel(_ level: Int32) -> String {
        switch level {
        case 2: return "Ansehen"
        case 3: return "Anfrage"
        case 4: return "Abnehmen"
        case 5: return "Bewerten"
        case 6: return "Bearbeiten"
        default: return "Stufe \(level)"
        }
    }
}

// MARK: - Requirement picker sheet

/// Sheet zum Auswählen einer Ziel-Qualifikation als Anforderung. Listet
/// Qualifikationen mit Suche (`listQualifications`) und ruft `onPick` mit der
/// gewählten `QualificationShort` auf.
private struct QualRequirementPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var onPick: (Resources_Qualifications_QualificationShort) -> Void

    private static let pageSize: Int64 = 20

    @State private var searchText = ""
    @State private var items: [Resources_Qualifications_Qualification] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Group {
                List {
                    if let errorMessage {
                        Section {
                            StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .cardRow()
                        }
                    }
                    if isLoading && items.isEmpty {
                        ForEach(0..<5, id: \.self) { _ in
                            SkeletonListRow()
                        }
                    } else if items.isEmpty, errorMessage == nil {
                        Section {
                            EmptyStateView(
                                "graduationcap",
                                color: Theme.Palette.accent,
                                title: "Keine Qualifikationen",
                                message: "Für diese Suche sind keine Qualifikationen vorhanden."
                            )
                        }
                    } else {
                        Section {
                            ForEach(items, id: \.id) { item in
                                Button {
                                    onPick(short(from: item))
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                            Text(displayTitle(item))
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                            if !item.description_p.isEmpty {
                                                Text(item.description_p)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                        Text(verbatim: formatQualificationID(item.id))
                                            .font(.caption2.monospaced().weight(.semibold))
                                            .padding(.horizontal, Theme.Spacing.md)
                                            .padding(.vertical, Theme.Spacing.xxs)
                                            .background(.secondary.opacity(0.15), in: Capsule())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .cardRow()
                            }
                        }
                    }
                }
                .cardListStyle()
            }
            .navigationTitle("Anforderung wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
            .onChange(of: searchText) {
                searchTask?.cancel()
                let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let task = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await load(query: query)
                }
                searchTask = task
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                await load(query: "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func load(query: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await appState.listQualifications(search: query, offset: 0, pageSize: Self.pageSize)
            items = response.qualifications
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func displayTitle(_ item: Resources_Qualifications_Qualification) -> String {
        let abbreviation = item.abbreviation
        let name = item.title
        if !abbreviation.isEmpty {
            return name.isEmpty ? abbreviation : "\(abbreviation): \(name)"
        }
        return name.isEmpty ? "Ohne Titel" : name
    }

    private func short(from item: Resources_Qualifications_Qualification) -> Resources_Qualifications_QualificationShort {
        var short = Resources_Qualifications_QualificationShort()
        short.id = item.id
        short.job = item.job
        short.weight = item.weight
        short.closed = item.closed
        short.draft = item.draft
        short.`public` = item.`public`
        short.abbreviation = item.abbreviation
        short.title = item.title
        if item.hasDescription_p {
            short.description_p = item.description_p
        }
        return short
    }
}
