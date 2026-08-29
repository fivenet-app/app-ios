import SwiftUI

/// Zentrale Design-Tokens für die App. Statt Ad-hoc-Werte (Spacing, Radien,
/// Farben) überall direkt zu verwenden, werden hier die gemeinsamen Maße und
/// Farben definiert, damit alle Screens visuell konsistent bleiben.
enum Theme {
    /// Spacing-Skala (Punkte). Überall für Abstände verwenden.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 24
    }

    /// Radius-Skala für gerundete Ecken.
    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Semantische Farben der App. Der Akzent ist eine feste Markenfarbe
    /// (konsistent in Hell-/Dunkelmodus); Flächen nutzen System-Surfaces.
    enum Palette {
        /// Markenfarbe der App (globaler Tint für Buttons, Links, aktive
        /// Elemente). Feste Behörden-Blau #2563EB, unabhängig vom Modus.
        static let accent: Color = Color(red: 0.145, green: 0.388, blue: 0.922)

        /// Erfolg (grün).
        static let success: Color = .green
        /// Warnung (orange).
        static let warning: Color = .orange
        /// Fehler/negativ (rot).
        static let danger: Color = .red
        /// Hinweis/Info (blau).
        static let info: Color = .blue
        /// Neutral (grau) für unkritische/ausgegraute Elemente.
        static let neutral: Color = .gray

        /// Standard-Fläche für Karten und Listen-Zeilen.
        static let surface = Color(.secondarySystemGroupedBackground)
        /// Erhöhte Fläche (z. B. Toolbars, Overlays).
        static let elevated = Color(.tertiarySystemGroupedBackground)
        /// Hintergrund der App.
        static let background = Color(.systemGroupedBackground)

        /// Getrennte/ausgegraute Fläche (z. B. Code-Blöcke).
        static let fill = Color(.secondarySystemFill)
        /// Neutraler Platzhalter-Ton für Skeleton/Shimmer-Elemente.
        static let placeholder = Color(.tertiarySystemFill)
    }

    /// Einheitliche Type-Skala: gerundete, fette Titel/Headlines für den
    /// modernen Look; Captions bleiben standard für Lesbarkeit.
    enum Typography {
        static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let title = Font.system(.title, design: .rounded, weight: .bold)
        static let title2 = Font.system(.title2, design: .rounded, weight: .bold)
        static let title3 = Font.system(.title3, design: .rounded, weight: .semibold)
        static let headline = Font.system(.headline, design: .rounded, weight: .semibold)
        static let subheadline = Font.system(.subheadline, design: .rounded, weight: .medium)
        static let caption = Font.caption.weight(.medium)
        static let caption2 = Font.caption2.weight(.medium)
    }
}

/// Getönttes Icon-Feld für Listen-Zeilen und Detail-Header (aktueller
/// iOS-Stil): farbiges SF-Symbol auf abgerundetem, transparent getönttem Grund.
struct IconTile: View {
    let systemName: String
    let color: Color
    var size: CGFloat
    var cornerRadius: CGFloat

    init(_ systemName: String, color: Color, size: CGFloat = 44, cornerRadius: CGFloat = Theme.Radius.md) {
        self.systemName = systemName
        self.color = color
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Einheitlicher Leer-/Fehler-Zustand: Icon in getönter Kreis-Fläche + Titel
/// + Beschreibung + optionaler Action-Button. Ersetzt nacktes `ContentUnavailableView`.
struct EmptyStateView: View {
    let systemName: String
    let color: Color
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    init(_ systemName: String, color: Color = Theme.Palette.accent, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemName = systemName
        self.color = color
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: systemName)
                .font(.system(size: 34))
                .foregroundStyle(color)
                .frame(width: 88, height: 88)
                .background(color.opacity(0.12), in: Circle())

            VStack(spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.headline)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
            }
        }
        .padding(.vertical, Theme.Spacing.xxl)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }
}

/// Platzhalter-Karte (Skeleton) während des Ladens — z. B. für die
/// Modul-Grid auf der Übersicht, bevor der Charakter geladen ist.
struct SkeletonBlock: View {
    var height: CGFloat = 92

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Palette.placeholder.opacity(0.35))
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Palette.placeholder.opacity(0.35))
                    .frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Palette.placeholder.opacity(0.25))
                    .frame(width: 96, height: 10)
            }
            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .redacted(reason: .placeholder)
        .accessibilityLabel("Wird geladen")
    }
}

// MARK: - Komponenten

/// Einheitliche Kartenfläche für Listen-Zeilen, Abschnitte und Detail-Blöcke.
/// Gleiche Radius-/Flächenwerte über die gesamte App.
struct AppCard<Content: View>: View {
    let padding: CGFloat
    @ViewBuilder let content: Content

    init(padding: CGFloat = Theme.Spacing.xl, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
    }
}

/// Kompakter Capsule-Badge (Status, Kategorien, IDs) mit getöntem
/// Hintergrund. Gemeinsames Design für alle Badges in Listen und Details.
struct AppBadge: View {
    let title: String
    let color: Color
    var icon: String?

    init(_ title: String, color: Color, icon: String? = nil) {
        self.title = title
        self.color = color
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// Vollflächiger Status-Badge (weißer Text auf Farbe), z. B. für
/// Approval-Status und Zähler.
struct StatusBadge: View {
    let title: String
    let color: Color

    init(_ title: String, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .font(.caption2.bold())
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .foregroundStyle(.white)
            .background(color)
            .clipShape(Capsule())
    }
}

/// Einheitliche Abschnittsüberschrift innerhalb von Listen/Detailansichten.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.9)
            .foregroundStyle(.secondary)
    }
}

/// Skeleton-Zeile für Listen-Ladezustände (ersetzt die nackte ProgressView).
/// Als Karte gestaltet, passend zum `cardListStyle`-Look.
struct SkeletonListRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.placeholder.opacity(0.4))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Palette.placeholder.opacity(0.4))
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.Palette.placeholder.opacity(0.3))
                    .frame(width: 110, height: 10)
            }
            Spacer()
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(
            top: Theme.Spacing.xs,
            leading: Theme.Spacing.xl,
            bottom: Theme.Spacing.xs,
            trailing: Theme.Spacing.xl
        ))
        .redacted(reason: .placeholder)
        .accessibilityLabel("Wird geladen")
    }
}

/// Skeleton für Detail-Screens beim ersten Laden (Header-Kachel + einige
/// Zeilen), ersetzt den zentrierten Spinner.
struct SkeletonDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            HStack(spacing: Theme.Spacing.xl) {
                RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                    .fill(Theme.Palette.placeholder.opacity(0.4))
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.Palette.placeholder.opacity(0.4))
                        .frame(width: 180, height: 18)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.Palette.placeholder.opacity(0.3))
                        .frame(width: 120, height: 12)
                }
                Spacer()
            }
            .padding(Theme.Spacing.xl)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))

            ForEach(0..<4, id: \.self) { _ in
                SkeletonListRow()
            }
        }
        .padding(Theme.Spacing.xl)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Wird geladen")
    }
}

/// Modul-Branding für die Navigationsleiste: kleines Verlaufs-Icon-Tile +
/// Modultitel — sitzt im richtigen Header zwischen Zurück-Button und dem
/// Verbindungs-Symbol (statt eines platzraubenden Hero-Bereichs).
struct ModuleNavTitle: View {
    let module: FiveNetModule
    var title: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: module.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: module.gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .shadow(color: module.tint.opacity(0.3), radius: 4, y: 2)
            Text(title ?? module.title)
                .font(Theme.Typography.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}

/// Verbindungs-Symbol für die Navigationsleiste: grün wenn der Kanal verbunden
/// ist, orange während des Verbindungsaufbaus.
struct NavConnectionDot: View {
    @Environment(AppState.self) private var appState

    private var color: Color {
        appState.isChannelConnected ? Theme.Palette.success : Theme.Palette.warning
    }

    var body: some View {
        Circle()
            .fill(color.opacity(0.16))
            .frame(width: 22, height: 22)
            .overlay {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            .accessibilityLabel(appState.isChannelConnected ? "Verbunden" : "Verbindung …")
    }
}

extension View {
    /// Modul-Branding im echten Navigations-Header (Zurück · Modul · Verbunden):
    /// setzt Titel + Inline-Display und legt Icon+Name in die Kopfzeilen-Mitte.
    func moduleNavTitle(_ module: FiveNetModule, title: String? = nil) -> some View {
        navigationTitle(title ?? module.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ModuleNavTitle(module: module, title: title)
                }
            }
    }

    /// Verbindungs-Punkt als hinteres Navigationsleisten-Element.
    func navConnectionDot() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavConnectionDot()
            }
        }
    }
}

/// Moderne Karten-Zeile für Listen: gerundete Fläche mit Innenabstand, Chevron
/// rechts und Schatten — ersetzt die dünnen Trenner-Zeilen. Kombiniert mit
/// `.cardRow()` und `.cardListStyle()`.
struct ListCardRow<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            content
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.xl)
        .background(
            Theme.Palette.surface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Trailinger Chevron für Karten-Rows — sitzt INNERHALB der Karte (wie in
/// `ListCardRow`), damit der Navigations-Pfeil nicht außerhalb der Box klebt.
struct CardChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

extension View {
    /// Blinkt den View (opacity 1.0 ↔ 0.35) solange `enabled` wahr ist —
    /// z.B. für den „Verstärkung“-Status-Button, wenn die eigene Einheit
    /// Verstärkung angefordert hat (500 ms Takt).
    func blinking(enabled: Bool, interval: TimeInterval = 0.5) -> some View {
        modifier(BlinkingModifier(enabled: enabled, interval: interval))
    }
}

/// Treibt die Blink-Animation über `TimelineView(.animation)` an; läuft nur
/// solange `enabled` gesetzt ist.
private struct BlinkingModifier: ViewModifier {
    let enabled: Bool
    let interval: TimeInterval

    func body(content: Content) -> some View {
        if enabled {
            TimelineView(.animation(minimumInterval: interval, paused: false)) { timeline in
                let on = Int(timeline.date.timeIntervalSinceReferenceDate / interval) % 2 == 0
                content.opacity(on ? 1.0 : 0.35)
            }
            .animation(.linear(duration: interval * 0.8), value: enabled)
        } else {
            content.opacity(1.0)
        }
    }
}

extension View {
    /// Flache Liste auf App-Hintergrund — Basis für den Karten-Look.
    func cardListStyle() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background.ignoresSafeArea())
    }

    /// Zeilen-Metadaten für Karten-Rows: unsichtbare Trenner/Background,
    /// gleichmäßiger Außenabstand um die Karte.
    func cardRow() -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(
                top: Theme.Spacing.xs,
                leading: Theme.Spacing.xl,
                bottom: Theme.Spacing.xs,
                trailing: Theme.Spacing.xl
            ))
    }
}

/// Standard-Karte für nackte List-Zeilen (Fehler, Leerzustände, Buttons,
/// Toggles, Picker): Surface-Hintergrund + Innenabstand + Schatten.
struct SectionCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
            )
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Horizontale Pill-Auswahl statt Segmented-Control: größere Tap-Flächen,
/// passen auch längere Labels, aktives Element als Accent-Capsule.
struct PillTabBar<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let label: (Tab) -> String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(tabs) { tab in
                    Button {
                        selection = tab
                    } label: {
                        Text(label(tab))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, Theme.Spacing.xl)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                selection == tab ? Theme.Palette.accent : Theme.Palette.surface,
                                in: Capsule()
                            )
                            .foregroundStyle(selection == tab ? .white : .primary)
                            .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
        }
    }
}

/// Pagination-Fußzeile (Zurück/Weiter) als Karte — Muster ColleaguesListView.
struct PaginationFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        SectionCard {
            content
        }
        .cardRow()
    }
}

/// Nackter Fehler-/Hinweis-`Label`-Row als Karte.
struct StatusLabelRow: View {
    let title: String
    var systemImage: String?
    var tint: Color = Theme.Palette.danger

    init(_ title: String, systemImage: String? = nil, tint: Color = Theme.Palette.danger) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
            }
            Text(title)
                .foregroundStyle(tint)
            Spacer()
        }
    }
}

/// Icon-Feld mit Verlaufs-Hintergrund (wie die Modul-Kacheln der Overview) —
/// bringt Farbe in Listen-Zeilen und Detail-Köpfe.
struct GradientIconTile: View {
    let systemName: String
    let gradient: [Color]
    var size: CGFloat
    var cornerRadius: CGFloat

    init(_ systemName: String, gradient: [Color], size: CGFloat = 44, cornerRadius: CGFloat = Theme.Radius.md) {
        self.systemName = systemName
        self.gradient = gradient
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: systemName)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: (gradient.first ?? Theme.Palette.accent).opacity(0.3), radius: 6, y: 3)
    }
}

/// Weiße Badge-Pill für den Detail-Hero (z. B. CIT-ID, Status, WANTED).
struct HeroBadge: View {
    let title: String
    var icon: String?

    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.Spacing.xs)
        .foregroundStyle(.white)
        .background(.white.opacity(0.22), in: Capsule())
    }
}

/// Hero-Kopf für Detail-Screens im Overview-Stil: Verlaufs-Hintergrund in der
/// Modulfarbe, dekorative Circles, optionales Icon-Tile, Titel + Untertitel und
/// Badge-Pills auf dem Verlauf. Über `actions` kann rechts eine vertikale
/// Spalte mit Schnellaktionen (z. B. Status-Buttons) eingebettet werden.
struct DetailHero<Actions: View>: View {
    let gradient: [Color]
    var icon: String?
    var title: String
    var subtitle: String?
    var badges: [String] = []
    let actions: Actions

    init(gradient: [Color], icon: String? = nil, title: String, subtitle: String? = nil, badges: [String] = [], @ViewBuilder actions: () -> Actions) {
        self.gradient = gradient
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.badges = badges
        self.actions = actions()
    }

    init(gradient: [Color], icon: String? = nil, title: String, subtitle: String? = nil, badges: [String] = []) where Actions == EmptyView {
        self.init(gradient: gradient, icon: icon, title: title, subtitle: subtitle, badges: badges) { EmptyView() }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let icon {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                            .fill(.white.opacity(0.18))
                        Image(systemName: icon)
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 72, height: 72)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Typography.title)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(2)
                    }
                }

                if !badges.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(badges, id: \.self) { badge in
                            HeroBadge(badge)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            if !(actions is EmptyView) {
                actions
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 130, height: 130)
                .offset(x: 36, y: -55)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(.white.opacity(0.06))
                .frame(width: 90, height: 90)
                .offset(x: -25, y: 45)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .shadow(color: (gradient.first ?? Theme.Palette.accent).opacity(0.25), radius: 14, y: 6)
    }
}

/// Vertikale Status-Schnellaktionen für Detail-Heroes: je Status ein Button
/// (aktiv = ausgefüllt mit Statusfarbe, inaktiv = heller weißer Hintergrund).
struct HeroStatusButtons<Status: Hashable>: View {
    struct Item: Identifiable {
        let status: Status
        let label: String
        let icon: String
        let color: Color

        var id: Status { status }
    }

    let items: [Item]
    let isActive: (Status) -> Bool
    let action: (Status) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ForEach(items) { item in
                Button {
                    action(item.status)
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: item.icon)
                        Text(item.label)
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(
                        isActive(item.status) ? item.color : Color.white.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 120)
    }
}

extension View {
    /// Fügt den Detail-Hero als erste List-Section ein (ohne List-Insets).
    func detailHeroSection<Actions: View>(_ hero: DetailHero<Actions>) -> some View {
        Section {
            hero
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

/// Label-Stil mit engem Icon-Text-Abstand.
///
/// Der Standard-`LabelStyle` legt in Listen-Kontexten zu viel Abstand zwischen
/// Icon und Titel; dieser Stil presst beide eng zusammen (`spacing`).
struct CompactLabelStyle: LabelStyle {
    var spacing: CGFloat = Theme.Spacing.xxs

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
            configuration.title
        }
    }
}
