import SwiftUI

// MARK: - Navigation

/// Navigation route for a job group detail (registered in the root stack).
struct GroupRoute: Hashable {
    let groupID: Int64
}

// MARK: - Gruppen-Policy (spiegelt die Web-`groups/policy.ts`)

extension Resources_Jobs_Groups_GroupType {
    /// Manual members are allowed for MANUAL and MIXED groups.
    var allowsManualMembers: Bool {
        self == .manual || self == .mixed
    }

    /// Smart membership rules are allowed for SMART and MIXED groups.
    var allowsRules: Bool {
        self == .smart || self == .mixed
    }

    /// Exclusions are allowed for MIXED groups only.
    var allowsExclusions: Bool {
        self == .mixed
    }

    /// Strict membership mode is only valid for MIXED groups.
    var allowsStrictMembershipMode: Bool {
        self == .mixed
    }

    /// Validates a type/membership-mode combination.
    func isValidMembershipMode(_ mode: Resources_Jobs_Groups_GroupMembershipMode) -> Bool {
        if self == .unspecified || mode == .unspecified { return false }
        if mode == .strict && !allowsStrictMembershipMode { return false }
        return true
    }

    /// Normalizes the membership mode: MIXED → STRICT, otherwise always FLEXIBLE.
    func normalizeMembershipMode(_ mode: Resources_Jobs_Groups_GroupMembershipMode) -> Resources_Jobs_Groups_GroupMembershipMode {
        self == .mixed ? .strict : .flexible
    }

    var label: String {
        switch self {
        case .manual: "Manuell"
        case .smart: "Automatisch"
        case .mixed: "Gemischt"
        default: "Unbekannt"
        }
    }

    var icon: String {
        switch self {
        case .manual: "person.fill.badge.plus"
        case .smart: "wand.and.stars"
        case .mixed: "person.3.fill"
        default: "person.3"
        }
    }

    var tint: Color {
        switch self {
        case .manual: Theme.Palette.neutral
        case .smart: Theme.Palette.info
        case .mixed: Theme.Palette.success
        default: Theme.Palette.neutral
        }
    }
}

extension Resources_Jobs_Groups_GroupMembershipMode {
    var label: String {
        switch self {
        case .flexible: "Flexibel"
        case .strict: "Streng"
        default: "Unbekannt"
        }
    }

    var icon: String {
        switch self {
        case .flexible: "tornado"
        case .strict: "lock.shield"
        default: "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .flexible: Theme.Palette.info
        case .strict: Theme.Palette.warning
        default: Theme.Palette.neutral
        }
    }
}

extension Resources_Jobs_Groups_GroupState {
    var label: String {
        switch self {
        case .active: "Aktiv"
        case .inactive: "Inaktiv"
        case .archived: "Archiviert"
        default: "Unbekannt"
        }
    }

    var tint: Color {
        switch self {
        case .active: Theme.Palette.success
        case .inactive: Theme.Palette.warning
        case .archived: Theme.Palette.neutral
        default: Theme.Palette.neutral
        }
    }
}

extension Resources_Jobs_Groups_GroupExclusionReason {
    var label: String {
        switch self {
        case .manual: "Manuell"
        case .temporary: "Temporär"
        case .notEligible: "Nicht berechtigt"
        case .other: "Sonstiges"
        default: "Unbekannt"
        }
    }
}

extension Resources_Jobs_Groups_GroupMemberSource {
    var label: String {
        switch self {
        case .manual: "Manuell"
        case .rule: "Regel"
        case .leader: "Leiter"
        default: "Info"
        }
    }
}

extension Resources_Jobs_Groups_GroupMembershipReasonType {
    var label: String {
        switch self {
        case .manual: "Manuell hinzugefügt"
        case .rule: "Per Regel"
        case .exclusion: "Ausgeschlossen"
        case .leader: "Gruppenleiter"
        default: "Info"
        }
    }
}

extension Resources_Jobs_Groups_GroupActivityType {
    var label: String {
        switch self {
        case .created: "Gruppe erstellt"
        case .updated: "Gruppe aktualisiert"
        case .archived: "Gruppe archiviert"
        case .restored: "Gruppe wiederhergestellt"
        case .memberAdded: "Mitglied hinzugefügt"
        case .memberRemoved: "Mitglied entfernt"
        case .memberExcluded: "Mitglied ausgeschlossen"
        case .memberExclusionRemoved: "Ausschluss entfernt"
        case .leaderAdded: "Leiter hinzugefügt"
        case .leaderRemoved: "Leiter entfernt"
        case .ruleAdded: "Regel hinzugefügt"
        case .ruleUpdated: "Regel aktualisiert"
        case .ruleRemoved: "Regel entfernt"
        case .logoUpdated: "Logo aktualisiert"
        default: "Unbekannt"
        }
    }

    var icon: String {
        switch self {
        case .created: "plus.circle.fill"
        case .updated: "pencil.circle.fill"
        case .archived: "archivebox.fill"
        case .restored: "arrow.uturn.backward.circle.fill"
        case .memberAdded: "person.badge.plus"
        case .memberRemoved: "person.badge.minus"
        case .memberExcluded: "person.crop.circle.badge.xmark"
        case .memberExclusionRemoved: "person.crop.circle.badge.checkmark"
        case .leaderAdded: "star.fill"
        case .leaderRemoved: "star"
        case .ruleAdded: "plus.square.on.square"
        case .ruleUpdated: "gearshape.2.fill"
        case .ruleRemoved: "minus.square.fill"
        case .logoUpdated: "photo.fill"
        default: "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .created, .memberAdded, .leaderAdded, .memberExclusionRemoved: Theme.Palette.success
        case .updated, .ruleUpdated: Theme.Palette.info
        case .archived: Theme.Palette.neutral
        case .restored: .teal
        case .memberRemoved, .leaderRemoved, .ruleRemoved: Theme.Palette.danger
        case .memberExcluded: Theme.Palette.warning
        case .ruleAdded: .cyan
        case .logoUpdated: .purple
        default: Theme.Palette.neutral
        }
    }
}

// MARK: - Group helpers

extension Resources_Jobs_Groups_Group {
    /// Display initials: first two characters of shortName ?? name.
    var initials: String {
        let base = shortName.isEmpty ? name : shortName
        return String(base.prefix(2)).uppercased()
    }
    /// Description (SwiftProtobuf mangles the field to `description_p`).
    var description: String { description_p }
    /// "Legacy policy state": persisted type/membership-mode combo is now invalid
    /// (e.g. MANUAL+STRICT). Mirrors the web `isLegacyGroupPolicyState`.
    var isLegacyPolicyState: Bool {
        !type.isValidMembershipMode(membershipMode)
    }
}

extension Resources_Jobs_Colleagues_Colleague {
    /// Display initials for the colleague (used in group member avatars).
    var initials: String {
        let name = [firstname, lastname].filter { !$0.isEmpty }
        let letters = name.compactMap { $0.first }.map { String($0) }
        let joined = letters.joined(separator: "").uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }
}

extension Resources_Jobs_Groups_GroupRule {
    /// Formatted rule label, mirrors the web `groupRuleLabel`.
    var label: String {
        switch rule {
        case .grade(let grade):
            switch grade.type {
            case .minimum:
                let value = grade.hasGradeLabel && !grade.gradeLabel.isEmpty ? grade.gradeLabel : "\(grade.grade)"
                return "Mindestrang: \(value)"
            case .exact:
                let value = grade.hasGradeLabel && !grade.gradeLabel.isEmpty ? grade.gradeLabel : "\(grade.grade)"
                return "Rang: \(value)"
            case .range:
                return "Rang \(grade.minGrade) bis \(grade.maxGrade)"
            default:
                return "Rang-Regel"
            }
        case .qualification(let qualification):
            let mode = qualification.type == .any ? "Eine von" : "Alle von"
            return "\(mode) \(qualification.qualificationIds.count) Qualifikationen"
        default:
            return "Regel"
        }
    }
}

extension Resources_Jobs_Groups_GroupResolvedMember {
    /// Primary badge tone for the member list (excluded → red, leader → orange,
    /// member → green, else neutral).
    var memberTone: Color {
        if isExcluded { return Theme.Palette.danger }
        if isLeader { return Theme.Palette.warning }
        if isMember { return Theme.Palette.success }
        return Theme.Palette.neutral
    }

    var memberToneLabel: String {
        if isExcluded { return "Ausgeschlossen" }
        if isLeader { return "Leiter" }
        if isMember { return "Mitglied" }
        return "Info"
    }

    /// True if any membership reason is a manual one (shows a "manual" badge).
    var hasManualReason: Bool {
        reasons.contains { $0.type == .manual }
    }
}

extension Resources_Jobs_Groups_GroupActivity {
    /// Target user name (targetUser ?? fallback) for activity rows.
    var targetName: String? {
        guard hasTargetUser else { return nil }
        return colleagueName(targetUser)
    }

    /// Actor name for activity rows.
    var actorName: String? {
        guard hasActorUser else { return nil }
        return colleagueName(actorUser)
    }
}
