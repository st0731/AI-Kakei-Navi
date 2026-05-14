import Foundation
import SwiftUI
import SwiftData
import Combine

@MainActor
class AnalyticsViewModel: ObservableObject {
    struct SummaryItem: Identifiable {
        let id = UUID()
        let label: String
        let total: Int
        var necessity: String? = nil
    }

    @Published var summaries: [SummaryItem] = []
    @Published var upperScale: Int = 1
    @Published var averageValue: Int = 0   // 推移グラフの平均ライン用
    @Published var isCalculating: Bool = false
    @Published var currentPreset: InsightAnalyticsView.AnalysisPreset = .breakdown
    @Published var currentMetric: InsightAnalyticsView.AnalysisMetric = .category

    private var allReceipts: [SavedReceipt] = []

    func updateData(
        allReceipts: [SavedReceipt],
        showIncome: Bool,
        preset: InsightAnalyticsView.AnalysisPreset,
        metric: InsightAnalyticsView.AnalysisMetric,
        range: InsightAnalyticsView.AnalysisRange,
        startYear: Int, startMonth: Int,
        endYear: Int, endMonth: Int,
        categoryFilter: String,
        necessityFilter: String
    ) {
        self.allReceipts = allReceipts
        // メトリクスが変わる場合は古いデータをクリア（レースコンディション防止）
        if metric != self.currentMetric {
            self.summaries = []
        }
        calculate(showIncome: showIncome, preset: preset, metric: metric, range: range,
                  startYear: startYear, startMonth: startMonth,
                  endYear: endYear, endMonth: endMonth,
                  categoryFilter: categoryFilter, necessityFilter: necessityFilter)
    }

    private func calculate(
        showIncome: Bool,
        preset: InsightAnalyticsView.AnalysisPreset,
        metric: InsightAnalyticsView.AnalysisMetric,
        range: InsightAnalyticsView.AnalysisRange,
        startYear: Int, startMonth: Int,
        endYear: Int, endMonth: Int,
        categoryFilter: String,
        necessityFilter: String
    ) {
        isCalculating = true
        let baseData = self.allReceipts

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let filtered = self.filterReceipts(
                base: baseData, showIncome: showIncome, range: range,
                startYear: startYear, startMonth: startMonth,
                endYear: endYear, endMonth: endMonth,
                categoryFilter: categoryFilter, necessityFilter: necessityFilter
            )
            let result = self.generateSummaries(filtered: filtered, metric: metric, showIncome: showIncome)
            let isStacked = !showIncome && (metric == .monthly || metric == .daily || metric == .weekday)
            let scale = self.calculateUpperScale(items: result, isStacked: isStacked)
            let avg = self.calculateAverage(items: result, metric: metric)

            await MainActor.run {
                self.summaries = result
                self.upperScale = scale
                self.averageValue = avg
                self.currentPreset = preset
                self.currentMetric = metric
                self.isCalculating = false
            }
        }
    }

    // MARK: - Filtering

    nonisolated private func filterReceipts(
        base: [SavedReceipt], showIncome: Bool,
        range: InsightAnalyticsView.AnalysisRange,
        startYear: Int, startMonth: Int, endYear: Int, endMonth: Int,
        categoryFilter: String, necessityFilter: String
    ) -> [SavedReceipt] {
        var result = base.filter { $0.isIncome == showIncome }
        if categoryFilter != "すべて" { result = result.filter { $0.category == categoryFilter } }
        if necessityFilter != "すべて" { result = result.filter { $0.necessity == necessityFilter } }

        let calendar = Calendar.current
        let now = Date()
        switch range {
        case .all: break
        case .thisMonth:
            result = result.filter { calendar.isDate($0.receiptDate, equalTo: now, toGranularity: .month) }
        case .lastMonth:
            if let last = calendar.date(byAdding: .month, value: -1, to: now) {
                result = result.filter { calendar.isDate($0.receiptDate, equalTo: last, toGranularity: .month) }
            }
        case .thisYear:
            result = result.filter { calendar.isDate($0.receiptDate, equalTo: now, toGranularity: .year) }
        case .lastYear:
            if let last = calendar.date(byAdding: .year, value: -1, to: now) {
                result = result.filter { calendar.isDate($0.receiptDate, equalTo: last, toGranularity: .year) }
            }
        case .custom:
            let start = calendar.startOfDay(for: calendar.date(from: DateComponents(year: startYear, month: startMonth, day: 1)) ?? now)
            let endBase = calendar.date(from: DateComponents(year: endYear, month: endMonth + 1, day: 0)) ?? now
            let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endBase) ?? endBase
            result = result.filter { $0.receiptDate >= start && $0.receiptDate <= end }
        }
        return result
    }

    // MARK: - Summary Generation

    nonisolated private func generateSummaries(
        filtered: [SavedReceipt],
        metric: InsightAnalyticsView.AnalysisMetric,
        showIncome: Bool
    ) -> [SummaryItem] {
        switch metric {
        case .category:
            return Dictionary(grouping: filtered) { $0.category }
                .compactMap { key, items -> SummaryItem? in
                    let total = items.reduce(0) { $0 + $1.total }
                    return total > 0 ? SummaryItem(label: key, total: total) : nil
                }
                .sorted { $0.total > $1.total }

        case .necessity:
            let grouped = Dictionary(grouping: filtered) { $0.necessity }
            return ["必要", "便利", "贅沢"].compactMap { nec -> SummaryItem? in
                let total = grouped[nec]?.reduce(0) { $0 + $1.total } ?? 0
                return total > 0 ? SummaryItem(label: nec, total: total) : nil
            }

        case .monthly:
            let fmt = DateFormatter(); fmt.dateFormat = "yyyy/MM"
            if showIncome {
                return Dictionary(grouping: filtered) { fmt.string(from: $0.receiptDate) }
                    .map { SummaryItem(label: $0.key, total: $0.value.reduce(0) { $0 + $1.total }) }
                    .sorted { $0.label < $1.label }
            }
            return necessityStacked(filtered: filtered,
                                    groupKey: { fmt.string(from: $0.receiptDate) },
                                    sortBy: { $0.key < $1.key })

        case .daily:
            let grouped = Dictionary(grouping: filtered) { Calendar.current.component(.day, from: $0.receiptDate) }
            if showIncome {
                return (1...31).compactMap { day -> SummaryItem? in
                    let total = grouped[day]?.reduce(0) { $0 + $1.total } ?? 0
                    return total > 0 ? SummaryItem(label: "\(day)日", total: total) : nil
                }
            }
            var results: [SummaryItem] = []
            for day in 1...31 {
                let items = grouped[day] ?? []
                let necGrouped = Dictionary(grouping: items) { $0.necessity }
                for nec in ["必要", "便利", "贅沢"] {
                    let total = necGrouped[nec]?.reduce(0) { $0 + $1.total } ?? 0
                    if total > 0 { results.append(SummaryItem(label: "\(day)日", total: total, necessity: nec)) }
                }
            }
            return results

        case .weekday:
            let names = ["月", "火", "水", "木", "金", "土", "日"]
            let toIdx = { (wd: Int) -> Int in (wd + 5) % 7 }
            let grouped = Dictionary(grouping: filtered) { toIdx(Calendar.current.component(.weekday, from: $0.receiptDate)) }
            if showIncome {
                return (0..<7).map { idx in
                    SummaryItem(label: names[idx], total: grouped[idx]?.reduce(0) { $0 + $1.total } ?? 0)
                }
            }
            var results: [SummaryItem] = []
            for idx in 0..<7 {
                let label = names[idx]
                let items = grouped[idx] ?? []
                if items.isEmpty {
                    results.append(SummaryItem(label: label, total: 0, necessity: "必要"))
                } else {
                    let necGrouped = Dictionary(grouping: items) { $0.necessity }
                    var hasData = false
                    for nec in ["必要", "便利", "贅沢"] {
                        let total = necGrouped[nec]?.reduce(0) { $0 + $1.total } ?? 0
                        if total > 0 { results.append(SummaryItem(label: label, total: total, necessity: nec)); hasData = true }
                    }
                    if !hasData { results.append(SummaryItem(label: label, total: 0, necessity: "必要")) }
                }
            }
            return results
        }
    }

    // MARK: - Helpers

    nonisolated private func necessityStacked(
        filtered: [SavedReceipt],
        groupKey: (SavedReceipt) -> String,
        sortBy: ((key: String, value: [SavedReceipt]), (key: String, value: [SavedReceipt])) -> Bool
    ) -> [SummaryItem] {
        var results: [SummaryItem] = []
        let grouped = Dictionary(grouping: filtered, by: groupKey)
        for (label, items) in grouped.sorted(by: sortBy) {
            let necGrouped = Dictionary(grouping: items) { $0.necessity }
            for nec in ["必要", "便利", "贅沢"] {
                let total = necGrouped[nec]?.reduce(0) { $0 + $1.total } ?? 0
                if total > 0 { results.append(SummaryItem(label: label, total: total, necessity: nec)) }
            }
        }
        return results
    }

    nonisolated private func calculateUpperScale(items: [SummaryItem], isStacked: Bool) -> Int {
        if isStacked {
            let maxTotal = Dictionary(grouping: items) { $0.label }
                .values.map { $0.reduce(0) { $0 + $1.total } }.max() ?? 0
            return max(1, Int(Double(maxTotal) * 1.5))
        }
        return max(1, Int(Double(items.map { $0.total }.max() ?? 0) * 1.4))
    }

    /// 推移グラフ（月別・日別）の平均値を計算
    nonisolated private func calculateAverage(items: [SummaryItem], metric: InsightAnalyticsView.AnalysisMetric) -> Int {
        guard metric == .monthly || metric == .daily else { return 0 }
        let labels = Set(items.map { $0.label })
        guard !labels.isEmpty else { return 0 }
        let totals = labels.map { label in items.filter { $0.label == label }.reduce(0) { $0 + $1.total } }
        return totals.reduce(0, +) / totals.count
    }
}
