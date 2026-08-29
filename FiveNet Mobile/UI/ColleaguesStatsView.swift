import SwiftUI
import SwiftProtobuf

/// Berufe "Kollegen": Statistik-Tab, spiegelt die Web-Ansicht
/// `pages/jobs/colleagues/stats.vue` + `Chart.client.vue`: Employee-Count over
/// Time als Balken-Diagramm (amount) mit Urlaub-Overlay (vacation) plus
/// Gesamt-/Durchschnitts-Kopfzeile. Daten via `jobs.StatsService/GetStats`.
struct ColleaguesStatsView: View {
    @Environment(AppState.self) private var appState

    private static let presetRanges: [Int] = [7, 14, 30, 90, 180, 365]

    @State private var rangeDays: Int = 14
    @State private var stats: Services_Jobs_GetStatsResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var startDate: Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -rangeDays, to: today) ?? today
    }

    private var endDate: Date {
        Date()
    }

    /// Ableitung der Aggregations-Periode aus dem Datumsbereich (Web
    /// `getSelectedPeriod`): >365 Tage → monatlich, >60 → wöchentlich, sonst täglich.
    private var selectedPeriod: Resources_Stats_StatsPeriod {
        Self.getSelectedPeriod(.unspecified, start: startDate, end: endDate)
    }

    private var chartData: [StatsDataPoint] {
        guard let stats else { return [] }
        return Self.buildChartData(stats: stats, period: selectedPeriod, start: startDate, end: endDate)
    }

    private var total: Double {
        guard let stats else { return 0 }
        if stats.totalValue > 0 { return Double(stats.totalValue) }
        return chartData.reduce(0) { $0 + $1.amount }
    }

    private var averageVacation: Double {
        let points = chartData
        guard !points.isEmpty else { return 0 }
        return points.reduce(0) { $0 + $1.vacation } / Double(points.count)
    }

    var body: some View {
        Group {
            List {
                Section {
                    SectionCard {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text((stats?.averageValue ?? 0) > 0 ? "Ø: Kollegen (abwesend)" : "Anzahl: Kollegen (abwesend)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("\(Self.formatTotal((stats?.averageValue ?? 0) > 0 ? stats?.averageValue ?? 0 : total)) (Ø \(averageVacation, specifier: "%.1f"))")
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                    .cardRow()
                }

                if let errorMessage {
                    Section {
                        StatusLabelRow(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .cardRow()
                    }
                }

                if isLoading && stats == nil {
                    ForEach(0..<4, id: \.self) { _ in
                        SkeletonListRow()
                    }
                } else if let errorMessage, stats == nil {
                    EmptyStateView(
                        "chart.bar",
                        color: Theme.Palette.danger,
                        title: "Statistik laden fehlgeschlagen",
                        message: errorMessage,
                        actionTitle: "Erneut versuchen"
                    ) {
                        Task { await load() }
                    }
                } else if stats == nil {
                    EmptyStateView(
                        "chart.bar",
                        color: Theme.Palette.accent,
                        title: "Keine Statistik verfügbar",
                        message: "Für diesen Zeitraum sind keine Kollegen-Statistiken vorhanden."
                    )
                } else {
                    Section {
                        SectionCard {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                HStack {
                                    Spacer()
                                    Menu {
                                        ForEach(Self.presetRanges, id: \.self) { days in
                                            Button("Letzte \(days) Tage") {
                                                rangeDays = days
                                            }
                                        }
                                    } label: {
                                        Label("Letzte \(rangeDays) Tage", systemImage: "calendar")
                                            .font(.subheadline)
                                    }
                                }

                                StatsBarChart(data: chartData)
                                    .frame(height: 180)
                            }
                        }
                    }
                    .cardRow()
                }
            }
            .cardListStyle()
            .contentMargins(.top, Theme.Spacing.sm, for: .scrollContent)
        }
        .refreshable {
            await load()
        }
        .task {
            await load()
        }
        .onChange(of: rangeDays) { _, _ in
            Task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            stats = try await appState.getStats(
                start: startDate,
                end: endDate,
                period: selectedPeriod,
                category: .employeeCountOverTime
            )
        } catch {
            errorMessage = error.localizedDescription
            stats = nil
        }
    }

    // MARK: - Chart-Datenaufbereitung (Web `helpers.ts` `buildChartData`)

    private static func getSelectedPeriod(_ period: Resources_Stats_StatsPeriod, start: Date, end: Date) -> Resources_Stats_StatsPeriod {
        if period != .unspecified { return period }
        let days = max(Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0, 1)
        if days > 365 { return .monthly }
        return days > 60 ? .weekly : .daily
    }

    private static func bucketStart(_ date: Date, period: Resources_Stats_StatsPeriod) -> Date {
        let cal = Calendar.current
        switch period {
        case .monthly:
            return cal.dateInterval(of: .month, for: date)?.start ?? cal.startOfDay(for: date)
        case .weekly:
            // Wochenstart Montag (Web `startOfWeek(..., { weekStartsOn: 1 })`)
            let startOfDay = cal.startOfDay(for: date)
            let weekday = cal.component(.weekday, from: startOfDay) // 1 = Sonntag
            let offset = (weekday - 2 + 7) % 7
            return cal.date(byAdding: .day, value: -offset, to: startOfDay) ?? startOfDay
        default:
            return cal.startOfDay(for: date)
        }
    }

    private static func nextBucket(_ date: Date, period: Resources_Stats_StatsPeriod) -> Date {
        let cal = Calendar.current
        switch period {
        case .monthly:
            return cal.date(byAdding: .month, value: 1, to: date) ?? date
        case .weekly:
            return cal.date(byAdding: .day, value: 7, to: date) ?? date
        default:
            return cal.date(byAdding: .day, value: 1, to: date) ?? date
        }
    }

    private static func buildChartData(stats: Services_Jobs_GetStatsResponse, period: Resources_Stats_StatsPeriod, start: Date, end: Date) -> [StatsDataPoint] {
        let effectivePeriod = getSelectedPeriod(period, start: start, end: end)
        var byBucket: [Date: StatsDataPoint] = [:]

        for item in stats.periodSeriesValues {
            guard item.hasDay else { continue }
            let bucket = bucketStart(item.day.timestamp.date, period: effectivePeriod)
            var point = byBucket[bucket] ?? StatsDataPoint(date: bucket, amount: 0, vacation: 0, absent: 0)
            switch item.key {
            case "on_vacation_count", "vacation_count":
                point.vacation += Double(item.value)
            case "absence_count", "absent_count", "on_absence_count":
                point.absent += Double(item.value)
            default:
                break
            }
            byBucket[bucket] = point
        }

        for item in stats.periodValues {
            guard item.hasDay else { continue }
            let bucket = bucketStart(item.day.timestamp.date, period: effectivePeriod)
            var point = byBucket[bucket] ?? StatsDataPoint(date: bucket, amount: 0, vacation: 0, absent: 0)
            point.amount += Double(item.value)
            byBucket[bucket] = point
        }

        var data: [StatsDataPoint] = []
        var cursor = bucketStart(start, period: effectivePeriod)
        let endBucket = bucketStart(end, period: effectivePeriod)
        while cursor <= endBucket {
            data.append(byBucket[cursor] ?? StatsDataPoint(date: cursor, amount: 0, vacation: 0, absent: 0))
            cursor = nextBucket(cursor, period: effectivePeriod)
        }
        return data
    }

    private static func formatTotal(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private static func formatTotal(_ value: Int64) -> String {
        formatTotal(Double(value))
    }
}

/// Ein Datenpunkt des Statistik-Diagramms.
private struct StatsDataPoint {
    let date: Date
    var amount: Double
    var vacation: Double
    var absent: Double
}

/// Balken-Diagramm wie im Web (`Chart.client.vue`, Unovis `VisGroupedBar`):
/// amount-Balken (primary, volle Opazität) mit darüberliegendem vacation-Overlay
/// (warning, 10 %) je Aggregations-Bucket. Balkenbreite auf `min(barWidth,
/// Containerbreite)` gedeckelt und je Spalte zentriert (`bandPaddingInner`),
/// nur x-Achse mit einem Datums-Label pro Bucket im de-Locale. Keine y-Achse,
/// Gridlines, Wert-Marker oder Legende (Web-treu).
private struct StatsBarChart: View {
    let data: [StatsDataPoint]

    /// Gemeinsame Skala über alle Reihen (amount + vacation), wie Unovis es für
    /// die im selben Container liegenden Bar-Serien berechnet.
    private var plotMax: Double {
        max(
            data.map(\.amount).max() ?? 0,
            data.map(\.vacation).max() ?? 0,
            1
        )
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: Self.axisStackSpacing) {
                ZStack(alignment: .bottom) {
                    HStack(alignment: .bottom, spacing: Self.barSpacing) {
                        ForEach(data.indices, id: \.self) { index in
                            barColumn(point: data[index], width: min(Self.barWidth, proxy.size.width))
                        }
                    }

                    Rectangle()
                        .fill(Color(.separator).opacity(0.35))
                        .frame(maxWidth: .infinity)
                        .frame(height: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: Self.plotHeight, alignment: .bottom)

                xAxisLabels
            }
        }
        .frame(height: Self.plotHeight + Self.axisStackSpacing)
    }

    private static let plotHeight: CGFloat = 170
    private static let barWidth: CGFloat = 30
    private static let barSpacing: CGFloat = 4
    private static let axisStackSpacing: CGFloat = Theme.Spacing.sm

    /// Balken klebt von unten, vacation-Wash darüber (warning, 10 % — Web `:opacity="0.1"`).
    private func barColumn(point: StatsDataPoint, width: CGFloat) -> some View {
        let height = Self.plotHeight * CGFloat(point.amount / plotMax)
        let vacationHeight = Self.plotHeight * CGFloat(point.vacation / plotMax)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.Palette.warning.opacity(0.1))
                .frame(width: width, height: vacationHeight)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.Palette.accent)
                .frame(width: width, height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: Self.plotHeight, alignment: .bottom)
    }

    private var xAxisLabels: some View {
        let stride = Self.xLabelStride(count: data.count)
        return HStack(spacing: 0) {
            ForEach(data.indices, id: \.self) { index in
                Text(index.isMultiple(of: stride) || index == data.count - 1 ? Self.xLabel(data[index].date) : " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Label-Abstand, damit die vollen `dd.MM.yyyy`-Labels nicht überlappen
    /// (Web zeigt pro Bucket ein Label, Unovis überspringt kollidierende automatisch).
    private static func xLabelStride(count: Int) -> Int {
        guard count > 1 else { return 1 }
        return max(1, Int(ceil(Double(count) / 6.0)))
    }

    /// Web `d(date, 'date')` → de-Locale `dd.MM.yyyy`.
    private static func xLabel(_ date: Date) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year())
    }
}

#Preview {
    ColleaguesStatsView()
        .environment(AppState())
}