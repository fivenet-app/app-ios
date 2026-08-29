import SwiftUI
import SwiftProtobuf

/// Sheet zum Erstellen/Bearbeiten einer Job-Gruppe: Stammdaten (Name,
/// Kurzname, Beschreibung, Farbe, Typ, Mitgliedschaftsmodus, Sortierung)
/// + Zugriff (Jobs/Nutzer) + bei Erstellung optionale Leiter/Regeln.
/// Spiegelt die Web-`GroupForm.vue` + `GroupAccessForm.vue`.
struct JobGroupEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let group: Resources_Jobs_Groups_Group?
    let access: Resources_Access_Access?
    let onSaved: (Resources_Jobs_Groups_Group) -> Void

    init(group: Resources_Jobs_Groups_Group? = nil, access: Resources_Access_Access? = nil, onSaved: @escaping (Resources_Jobs_Groups_Group) -> Void) {
        self.group = group
        self.access = access
        self.onSaved = onSaved
    }

    // Stammdaten
    @State private var name = ""
    @State private var shortName = ""
    @State private var descriptionText = ""
    @State private var colorText = ""
    @State private var color: Color = Color(hex: "2563EB") ?? .accentColor
    @State private var type: Resources_Jobs_Groups_GroupType = .mixed
    @State private var membershipMode: Resources_Jobs_Groups_GroupMembershipMode = .strict
    @State private var sortRank = ""

    // Zugriff
    @State private var jobAccess: [Resources_Access_JobAccess] = []
    @State private var userAccess: [Resources_Access_UserAccess] = []
    @State private var showAddUserAccess = false
    @State private var showAddJobAccess = false
    @State private var newUser: Resources_Users_Short_UserShort?
    @State private var newUserAccessLevel: Int32 = Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue)
    @State private var newJobCode = ""
    @State private var newJobLabel = ""
    @State private var newJobMinimumGrade: Int32 = 0
    @State private var newJobAccessLevel: Int32 = Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue)

    @State private var isSaving = false
    @State private var errorMessage: String?

    private static let accessLevels: [(Resources_Jobs_Groups_Access_AccessLevel, String)] = [
        (.blocked, "Blockiert"),
        (.view, "Ansehen"),
        (.edit, "Bearbeiten"),
        (.manage, "Verwalten"),
    ]

    /// Membership modes valid for the currently selected group type
    /// (STRICT is only allowed for MIXED, per server `jobspolicy`).
    private var validMembershipModes: [Resources_Jobs_Groups_GroupMembershipMode] {
        type.allowsStrictMembershipMode
            ? [.flexible, .strict]
            : [.flexible]
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && type != .unspecified && membershipMode != .unspecified
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

                Section("Allgemein") {
                    TextField("Name", text: $name)
                    TextField("Kurzname", text: $shortName)
                    TextField("Beschreibung", text: $descriptionText, axis: .vertical)
                        .lineLimit(1...4)
                    ColorPicker("Farbe", selection: $color, supportsOpacity: false)
                        .onChange(of: color) { _, newValue in
                            if let hex = newValue.hexString {
                                colorText = hex
                            }
                        }
                    TextField("Farbe (Hex, z. B. #2563EB)", text: $colorText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: colorText) { _, newValue in
                            if let parsed = Color(hex: newValue) {
                                color = parsed
                            }
                        }
                    TextField("Sortierung", text: $sortRank)
                        .keyboardType(.numbersAndPunctuation)
                }

                Section("Typ & Modus") {
                    Picker("Typ", selection: $type) {
                        ForEach([
                            Resources_Jobs_Groups_GroupType.manual,
                            .smart,
                            .mixed,
                        ], id: \.rawValue) { value in
                            Text(value.label).tag(value)
                        }
                    }
                    .onChange(of: type) { _, newValue in
                        if !newValue.isValidMembershipMode(membershipMode) {
                            membershipMode = newValue.normalizeMembershipMode(membershipMode)
                        }
                    }

                    Picker("Mitgliedschaft", selection: $membershipMode) {
                        ForEach(validMembershipModes, id: \.rawValue) { value in
                            Text(value.label).tag(value)
                        }
                    }

                    if type.allowsStrictMembershipMode {
                        Text("Streng = nur aufgelöste Mitglieder zählen als Mitglieder.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Strenger Modus ist nur bei Typ „Gemischt“ möglich.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                accessSection
            }
            .navigationTitle(group == nil ? "Gruppe erstellen" : "Gruppe bearbeiten")
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
        }
        .sheet(isPresented: $showAddJobAccess) {
            GroupAccessJobSheet(
                jobCode: $newJobCode,
                jobLabel: $newJobLabel,
                minimumGrade: $newJobMinimumGrade,
                accessLevel: $newJobAccessLevel,
                onAdd: {
                    var entry = Resources_Access_JobAccess()
                    entry.job = newJobCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry.jobLabel = newJobLabel
                    entry.minimumGrade = newJobMinimumGrade
                    entry.access = newJobAccessLevel
                    jobAccess.append(entry)
                    newJobCode = ""
                    newJobLabel = ""
                    newJobMinimumGrade = 0
                    showAddJobAccess = false
                }
            )
        }
        .sheet(isPresented: $showAddUserAccess) {
            GroupAccessUserSheet(
                accessLevel: $newUserAccessLevel,
                selectedUser: $newUser,
                onAdd: {
                    guard let currentUser = newUser else { return }
                    var entry = Resources_Access_UserAccess()
                    entry.userID = currentUser.userID
                    entry.user = currentUser
                    entry.access = newUserAccessLevel
                    userAccess.append(entry)
                    newUser = nil
                    showAddUserAccess = false
                }
            )
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        Section("Zugriff") {
            if jobAccess.isEmpty && userAccess.isEmpty {
                Text("Noch kein Zugriff konfiguriert. Ohne Zugriff kann niemand die Gruppe sehen.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(jobAccess.enumerated()), id: \.element.id) { index, entry in
                HStack {
                    VStack(alignment: .leading) {
                        if entry.job.isEmpty {
                            Text("Alle Jobs")
                                .font(.subheadline)
                        } else if entry.hasJobLabel && !entry.jobLabel.isEmpty {
                            Text("\(entry.jobLabel) (\(entry.job))")
                                .font(.subheadline)
                        } else {
                            Text(entry.job)
                                .font(.subheadline)
                        }
                        Text(subtitle(for: entry))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        jobAccess.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }

            ForEach(Array(userAccess.enumerated()), id: \.element.id) { index, entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(entry.user.firstname) \(entry.user.lastname)")
                            .font(.subheadline)
                        Text(accessLevelLabel(entry.access))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        userAccess.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }

            Button {
                newJobCode = ""
                newJobLabel = ""
                newJobMinimumGrade = 0
                newJobAccessLevel = Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue)
                showAddJobAccess = true
            } label: {
                Label("Job-Zugriff hinzufügen", systemImage: "person.badge.plus")
            }

            Button {
                newUser = nil
                newUserAccessLevel = Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue)
                showAddUserAccess = true
            } label: {
                Label("Nutzer-Zugriff hinzufügen", systemImage: "person.crop.circle.badge.plus")
            }
        }
    }

    private func seed() {
        guard let group else {
            type = .mixed
            membershipMode = .strict
            colorText = "#2563EB"
            color = Color(hex: "2563EB") ?? .accentColor
            sortRank = "0"
            return
        }
        name = group.name
        shortName = group.shortName
        descriptionText = group.description
        colorText = group.hasColor ? group.color : ""
        color = Color(hex: group.color) ?? .accentColor
        type = group.type
        membershipMode = group.membershipMode
        sortRank = group.sortRank
        seedAccess()
    }

    private func seedAccess() {
        if let access {
            jobAccess = access.jobs
            userAccess = access.users
        }
    }

    private func accessLevelLabel(_ level: Int32) -> String {
        switch level {
        case Int32(Resources_Jobs_Groups_Access_AccessLevel.blocked.rawValue): "Blockiert"
        case Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue): "Ansehen"
        case Int32(Resources_Jobs_Groups_Access_AccessLevel.edit.rawValue): "Bearbeiten"
        case Int32(Resources_Jobs_Groups_Access_AccessLevel.manage.rawValue): "Verwalten"
        default: "Stufe \(level)"
        }
    }

    private func subtitle(for entry: Resources_Access_JobAccess) -> String {
        var parts = [accessLevelLabel(entry.access)]
        if entry.minimumGrade > 0 {
            parts.append("Mindestrang \(entry.minimumGrade)")
        }
        return parts.joined(separator: " · ")
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        do {
            if let group {
                var request = Services_Jobs_UpdateGroupRequest()
                request.id = group.id
                request.name = name
                if !descriptionText.isEmpty { request.description_p = descriptionText }
                if !shortName.isEmpty { request.shortName = shortName }
                if !colorText.isEmpty { request.color = colorText }
                request.type = type
                request.membershipMode = membershipMode
                if !sortRank.isEmpty { request.sortRank = sortRank }

                var access = Resources_Access_Access()
                access.jobs = jobAccess
                access.users = userAccess
                request.access = access

                let updated = try await appState.updateGroup(request)
                onSaved(updated)
            } else {
                var request = Services_Jobs_CreateGroupRequest()
                request.job = appState.character?.job ?? ""
                request.name = name
                if !descriptionText.isEmpty { request.description_p = descriptionText }
                if !shortName.isEmpty { request.shortName = shortName }
                if !colorText.isEmpty { request.color = colorText }
                request.type = type
                request.membershipMode = membershipMode
                if !sortRank.isEmpty { request.sortRank = sortRank }

                var access = Resources_Access_Access()
                access.jobs = jobAccess
                access.users = userAccess
                request.access = access

                let created = try await appState.createGroup(request)
                onSaved(created)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sheet zum Hinzufügen eines Job-Zugriffs (Job-Code + Zugriffsstufe).
/// Alle Eingabefelder sind `@Binding` an den Parent gebunden, damit die
/// Werte beim Hinzufügen tatsächlich in den `JobAccess`-Eintrag fließen.
private struct GroupAccessJobSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var jobCode: String
    @Binding var jobLabel: String
    @Binding var minimumGrade: Int32
    @Binding var accessLevel: Int32
    let onAdd: () -> Void

    private var canAdd: Bool {
        !jobCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Job") {
                    TextField("Job-Code (z. B. police)", text: $jobCode)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Job-Name (optional)", text: $jobLabel)
                    Stepper(value: $minimumGrade, in: 0...30) {
                        Text("Mindestrang: \(minimumGrade)")
                    }
                }

                Section("Zugriff") {
                    Picker("Stufe", selection: $accessLevel) {
                        Text("Ansehen").tag(Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue))
                        Text("Bearbeiten").tag(Int32(Resources_Jobs_Groups_Access_AccessLevel.edit.rawValue))
                        Text("Verwalten").tag(Int32(Resources_Jobs_Groups_Access_AccessLevel.manage.rawValue))
                    }
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
                        onAdd()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }
}

/// Sheet zum Hinzufügen eines Nutzer-Zugriffs (Kollege + Zugriffsstufe).
private struct GroupAccessUserSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Binding var accessLevel: Int32
    @Binding var selectedUser: Resources_Users_Short_UserShort?
    let onAdd: () -> Void

    @State private var searchText = ""
    @State private var results: [Resources_Users_Short_UserShort] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isLoading = false

    private var canAdd: Bool {
        selectedUser != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Suche") {
                    TextField("Name oder CIT-ID", text: $searchText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: searchText) { _, newValue in
                            searchTask?.cancel()
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            searchTask = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                guard !Task.isCancelled else { return }
                                await search(trimmed)
                            }
                        }
                        .onAppear {
                            if results.isEmpty {
                                Task { await search("") }
                            }
                        }

                    ForEach(results, id: \.userID) { user in
                        Button {
                            selectedUser = user
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(user.firstname) \(user.lastname)")
                                    Text("CIT-\(user.userID) · \(user.jobLabel.isEmpty ? user.job : user.jobLabel)")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedUser?.userID == user.userID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Palette.accent)
                                }
                            }
                        }
                    }
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Suche …")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Zugriff") {
                    Picker("Stufe", selection: $accessLevel) {
                        Text("Ansehen").tag(Int32(Resources_Jobs_Groups_Access_AccessLevel.view.rawValue))
                        Text("Bearbeiten").tag(Int32(Resources_Jobs_Groups_Access_AccessLevel.edit.rawValue))
                        Text("Verwalten").tag(Int32(Resources_Jobs_Groups_Access_AccessLevel.manage.rawValue))
                    }
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
                        onAdd()
                    }
                    .disabled(!canAdd)
                }
            }
        }
    }

    func search(_ query: String) async {
        isLoading = true
        defer { isLoading = false }
        // CIT-ID als Int32? Nutze die Kollegen-Suche (mappt auf UserShort).
        guard let response = try? await appState.listColleagues(search: query, pageSize: 20) else { return }
        results = response.colleagues.map { colleague in
            var user = Resources_Users_Short_UserShort()
            user.userID = colleague.userID
            user.job = colleague.job
            user.jobLabel = colleague.jobLabel
            user.jobGrade = colleague.jobGrade
            user.jobGradeLabel = colleague.jobGradeLabel
            user.firstname = colleague.firstname
            user.lastname = colleague.lastname
            return user
        }
    }
}
