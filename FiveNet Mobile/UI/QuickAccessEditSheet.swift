import SwiftUI

/// Sheet zum Bearbeiten des Schnellzugriffs der Startseite: Module und direkte
/// Tab-Ziele auswählen, anordnen und entfernen. Wird pro Server gespeichert.
struct QuickAccessEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [QuickAccessItem] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if items.isEmpty {
                        Text("Noch keine Schnellzugriffe konfiguriert. Füge unten Module oder Tabs hinzu.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, Theme.Spacing.sm)
                    } else {
                        ForEach(items) { item in
                            row(item)
                        }
                        .onMove { indices, newOffset in
                            items.move(fromOffsets: indices, toOffset: newOffset)
                        }
                        .onDelete { indices in
                            items.remove(atOffsets: indices)
                        }
                    }
                } header: {
                    Text("Schnellzugriff")
                } footer: {
                    Text("Wischen zum Entfernen, Ziehen zum Sortieren. Ein Tab öffnet das Modul direkt auf der ausgewählten Ansicht.")
                }

                if !addableSections.isEmpty {
                    Section("Hinzufügen") {
                        ForEach(addableSections) { section in
                            addRow(for: section)
                        }
                    }
                }
            }
            .navigationTitle("Schnellzugriff")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") {
                        appState.setQuickAccessItems(items)
                        dismiss()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .onAppear {
                items = appState.effectiveQuickAccess
            }
        }
    }

    /// Aktuelle Zeile mit Drag-Handle (Reihenfolge) und direktem Entfernen.
    private func row(_ item: QuickAccessItem) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: item.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.module.tint)
                .frame(width: 28, height: 28)
                .background(item.module.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(item.title)
                    .foregroundStyle(.primary)
                Text(item.module.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// Hinzufügen-Zeile für ein Modul: ein Dropdown (`Menu`) mit der Option das
/// gesamte Modul zu heften („Gesamtes Modul“) sowie allen noch nicht
/// angehefteten Tabs des Moduls — statt einer flachen, langen Tab-Liste.
private struct AddSection: Identifiable {
    let module: FiveNetModule
    let addableTabs: [QuickAccessTab]
    var id: String { module.rawValue }
}

/// Angeheftete Module und Tab-Ziele der Startseite (in „Hinzufügen“) —
/// pro Modul gebündelt via Dropdown.
private extension QuickAccessEditSheet {
    private var addableSections: [AddSection] {
        appState.accessibleModules.compactMap { module in
            let hasModule = moduleIsAddable(module)
            let tabs = addableTabs(for: module)
            guard hasModule || !tabs.isEmpty else { return nil }
            return AddSection(module: module, addableTabs: tabs)
        }
    }

    /// Ob das Modul noch nicht als ganzes Modul im Schnellzugriff ist.
    private func moduleIsAddable(_ module: FiveNetModule) -> Bool {
        !items.contains { if case .module(let m) = $0 { return m == module }; return false }
    }

    /// Tab-Ziele eines Moduls, die noch nicht als Tab im Schnellzugriff sind.
    /// Ein als ganzes Modul angeheftetes Modul schließt seine Tabs NICHT aus —
    /// so kann man gezielt einzelne Ansichten anheften, auch wenn das Modul
    /// selbst bereits im Schnellzugriff ist.
    private func addableTabs(for module: FiveNetModule) -> [QuickAccessTab] {
        QuickAccessTab.allCases.filter { tab in
            tab.module == module
                && !items.contains { if case .tab(let existing) = $0 { return existing == tab }; return false }
        }
    }

    @ViewBuilder
    private func addRow(for section: AddSection) -> some View {
        if section.addableTabs.isEmpty {
            Button {
                withAnimation {
                    items.append(.module(section.module))
                }
            } label: {
                HStack {
                    addRowIcon(section.module)
                    Text(section.module.title)
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        } else {
            Menu {
                if moduleIsAddable(section.module) {
                    Button {
                        withAnimation {
                            items.append(.module(section.module))
                        }
                    } label: {
                        Label("Gesamtes Modul", systemImage: section.module.icon)
                    }
                    if !section.addableTabs.isEmpty {
                        Divider()
                    }
                }
                ForEach(section.addableTabs) { tab in
                    Button {
                        withAnimation {
                            items.append(.tab(tab))
                        }
                    } label: {
                        Label(tab.label, systemImage: tab.icon)
                    }
                }
            } label: {
                HStack {
                    addRowIcon(section.module)
                    Text(section.module.title)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Identisches Start-Icon in beiden "Hinzufügen"-Zeilen-Varianten (Button /
    /// Dropdown), damit die Titel auf derselben x-Position beginnen.
    private func addRowIcon(_ module: FiveNetModule) -> some View {
        Image(systemName: module.icon)
            .font(.subheadline.weight(.semibold))
            .frame(width: 20, alignment: .center)
            .foregroundStyle(module.tint)
    }
}