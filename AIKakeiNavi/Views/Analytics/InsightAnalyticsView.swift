import SwiftUI
import SwiftData
import Charts

struct InsightAnalyticsView: View {
    @Query private var allReceipts: [SavedReceipt]
    @StateObject private var viewModel = AnalyticsViewModel()

    @State private var showIncome = false
    @State private var selectedPreset: AnalysisPreset = .breakdown
    @State private var selectedBreakdown: BreakdownMetric = .category
    @State private var selectedTrend: TrendMetric = .monthly
    @State private var selectedRange: AnalysisRange = .thisMonth
    @State private var selectedCategoryFilter = "すべて"
    @State private var selectedNecessityFilter = "すべて"
    @State private var selectedLabel: String?

    static var currentYear:  Int { Calendar.current.component(.year,  from: Date()) }
    static var currentMonth: Int { Calendar.current.component(.month, from: Date()) }
    @State private var startYear  = InsightAnalyticsView.currentYear
    @State private var startMonth = InsightAnalyticsView.currentMonth
    @State private var endYear    = InsightAnalyticsView.currentYear
    @State private var endMonth   = InsightAnalyticsView.currentMonth
    let years  = Array(2000...Calendar.current.component(.year, from: Date()))
    let months = Array(1...12)

    // MARK: - Enums

    enum AnalysisPreset: String, CaseIterable {
        case breakdown = "内訳"
        case trend     = "推移"

        var icon: String {
            switch self {
            case .breakdown: return "chart.pie.fill"
            case .trend:     return "chart.bar.fill"
            }
        }
        var description: String {
            switch self {
            case .breakdown: return "カテゴリ・必要度・曜日の内訳"
            case .trend:     return "日別・月別の時系列推移"
            }
        }
    }

    enum BreakdownMetric: String, CaseIterable {
        case category  = "カテゴリ別"
        case necessity = "必要度別"
        case payment   = "支払い方法別"
        case weekday   = "曜日別"
        var analysisMetric: AnalysisMetric {
            switch self {
            case .category:  return .category
            case .necessity: return .necessity
            case .payment:   return .payment
            case .weekday:   return .weekday
            }
        }
    }

    enum TrendMetric: String, CaseIterable {
        case daily   = "日別"
        case monthly = "月別"
        var analysisMetric: AnalysisMetric {
            self == .daily ? .daily : .monthly
        }
    }

    enum AnalysisRange: String, CaseIterable {
        case thisMonth = "今月"
        case lastMonth = "先月"
        case thisYear  = "今年"
        case lastYear  = "昨年"
        case all       = "全期間"
        case custom    = "期間指定"
    }

    enum AnalysisMetric: String, CaseIterable {
        case category  = "カテゴリ"
        case necessity = "必要度"
        case payment   = "支払い方法"
        case monthly   = "月別"
        case daily     = "日別"
        case weekday   = "曜日別"

        var isPieChart: Bool { self == .category || self == .necessity || self == .payment }
        var icon: String {
            switch self {
            case .category:  return "chart.pie.fill"
            case .necessity: return "gauge.with.needle.fill"
            case .payment:   return "creditcard.fill"
            case .monthly:   return "calendar"
            case .daily:     return "calendar.day.timeline.left"
            case .weekday:   return "calendar.badge.exclamationmark"
            }
        }
    }

    // MARK: - Derived

    private var currentMetric: AnalysisMetric {
        switch selectedPreset {
        case .breakdown: return selectedBreakdown.analysisMetric
        case .trend:     return selectedTrend.analysisMetric
        }
    }

    private var availableRanges: [AnalysisRange] {
        switch selectedPreset {
        case .breakdown:
            return [.thisMonth, .lastMonth, .thisYear, .lastYear, .all, .custom]
        case .trend:
            return selectedTrend == .daily ? [.thisMonth, .lastMonth, .custom]
                                           : [.thisYear, .lastYear, .all, .custom]
        }
    }

    private var isStackedByNecessity: Bool {
        !showIncome && !currentMetric.isPieChart
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 収支切り替えのみ固定表示
                Picker("収支", selection: $showIncome) {
                    Text("支出").tag(false)
                    Text("収入").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
                .onChange(of: showIncome) { _, _ in resetAndUpdate() }
                .background(Color(UIColor.secondarySystemGroupedBackground))

                // コントロール＋グラフを一体化したScrollView
                ScrollView {
                    VStack(spacing: 12) {

                        // ── コントロールパネル（スクロールで隠れる）──
                        VStack(spacing: 10) {
                            // プリセット選択
                            HStack(spacing: 8) {
                                ForEach(AnalysisPreset.allCases, id: \.self) { preset in
                                    PresetCard(preset: preset, isSelected: selectedPreset == preset) {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                            selectedPreset = preset
                                            resetFilters()
                                            fixRangeIfNeeded()
                                            update()
                                        }
                                    }
                                }
                            }

                            // サブ切り替え（内訳 / 推移のみ）
                            if selectedPreset == .breakdown {
                                subPickerRow(
                                    items: BreakdownMetric.allCases.map { ($0.rawValue, $0 == selectedBreakdown) },
                                    onSelect: { idx in
                                        withAnimation { selectedBreakdown = BreakdownMetric.allCases[idx]; resetFilters(); update() }
                                    }
                                )
                            } else if selectedPreset == .trend {
                                subPickerRow(
                                    items: TrendMetric.allCases.map { ($0.rawValue, $0 == selectedTrend) },
                                    onSelect: { idx in
                                        withAnimation { selectedTrend = TrendMetric.allCases[idx]; fixRangeIfNeeded(); resetFilters(); update() }
                                    }
                                )
                            }

                            // 期間ピル
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(availableRanges, id: \.self) { range in
                                        PillButton(title: range.rawValue, isSelected: selectedRange == range) {
                                            withAnimation { selectedRange = range; update() }
                                        }
                                    }
                                }
                                .padding(.horizontal, 2).padding(.vertical, 2)
                            }

                            // カスタム期間ピッカー
                            if selectedRange == .custom {
                                HStack {
                                    monthYearPicker(year: $startYear, month: $startMonth, showMonth: selectedPreset == .trend && selectedTrend == .daily || selectedPreset == .breakdown)
                                    Text("〜").font(.caption2).foregroundColor(.secondary)
                                    monthYearPicker(year: $endYear, month: $endMonth, showMonth: selectedPreset == .trend && selectedTrend == .daily || selectedPreset == .breakdown)
                                }
                                .background(Color.gray.opacity(0.05)).cornerRadius(8)
                            }

                            // 絞り込みフィルター
                            if !showIncome && currentMetric != .payment {
                                HStack(spacing: 8) {
                                    if currentMetric != .category {
                                        filterMenu(title: "カテゴリ", selected: $selectedCategoryFilter,
                                                   options: ["食費","服・美容費","日用品・雑貨費","交通・移動費","通信費","水道光熱費","住居費","医療・健康費","趣味・娯楽費","交際費","サブスク費","勉強費","その他"])
                                    }
                                    if currentMetric != .necessity {
                                        filterMenu(title: "必要度", selected: $selectedNecessityFilter,
                                                   options: ["必要","便利","贅沢"])
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(16)

                        // ── グラフエリア ──
                        ZStack {
                            if viewModel.summaries.isEmpty {
                                if viewModel.isCalculating {
                                    ProgressView("計算中...").padding(.top, 60)
                                } else {
                                    ContentUnavailableView("データがありません", systemImage: "tray.fill").padding(.top, 60)
                                }
                            } else {
                                chartCardView
                                    .opacity(viewModel.isCalculating ? 0.5 : 1.0)
                                    .overlay {
                                        if viewModel.isCalculating {
                                            ProgressView().scaleEffect(1.5)
                                        }
                                    }
                            }
                        }
                        .id("\(showIncome)-\(viewModel.currentMetric.rawValue)")
                        .animation(.easeInOut(duration: 0.2), value: viewModel.isCalculating)

                    }
                    .padding()
                }
            }
            .navigationTitle(showIncome ? "収入分析" : "支出分析")
            .background(Color(UIColor.systemGroupedBackground))
            .onAppear { update() }
            .onChange(of: allReceipts)           { update() }
            .onChange(of: startYear)             { update() }
            .onChange(of: startMonth)            { update() }
            .onChange(of: endYear)               { update() }
            .onChange(of: endMonth)              { update() }
            .onChange(of: selectedCategoryFilter){ update() }
            .onChange(of: selectedNecessityFilter){ update() }
        }
    }

    // MARK: - Chart Card

    private var chartCardView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ヘッダー
            HStack {
                Label(chartTitle, systemImage: currentMetric.icon)
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                let total = viewModel.summaries.reduce(0) { $0 + $1.total }
                Text("\(total.formatted())円").font(.caption.bold()).foregroundColor(.primary)
            }

            if viewModel.currentMetric.isPieChart {
                pieChartView
            } else {
                barChartView
            }
        }
        .modifier(CardStyle())
    }

    private var chartTitle: String {
        switch selectedPreset {
        case .breakdown: return selectedBreakdown.rawValue + "の内訳"
        case .trend:     return selectedTrend.rawValue + "の推移"
        }
    }

    // MARK: - Pie Chart

    private var pieChartView: some View {
        VStack(spacing: 12) {
            let totalAll = viewModel.summaries.reduce(0) { $0 + $1.total }

            Chart(viewModel.summaries) { item in
                SectorMark(
                    angle: .value("金額", item.total),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .foregroundStyle(chartColor(for: item))
                .annotation(position: .overlay) {
                    if totalAll > 0 {
                        let pct = Int(Double(item.total) / Double(totalAll) * 100)
                        if pct > 5 {
                            VStack(spacing: 2) {
                                Text(item.label).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                Text("\(pct)%").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            }
                            .shadow(color: .black.opacity(0.3), radius: 2)
                        }
                    }
                }
                .accessibilityLabel(item.label)
                .accessibilityValue("\(item.total)円")
            }
            .frame(height: 240)
            .chartLegend(.hidden)
            .chartBackground { proxy in
                GeometryReader { geo in
                    if let frame = proxy.plotFrame.map({ geo[$0] }) {
                        VStack(spacing: 4) {
                            Text("合計").font(.system(size: 11)).foregroundColor(.secondary)
                            Text("\(totalAll.formatted())円").font(.system(size: 15, weight: .bold))
                        }
                        .position(x: frame.midX, y: frame.midY)
                    }
                }
            }

            // カスタム凡例
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(viewModel.summaries) { item in
                    HStack(spacing: 6) {
                        Circle().fill(chartColor(for: item)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.system(size: 11)).lineLimit(1)
                            let pct = totalAll > 0 ? Int(Double(item.total) / Double(totalAll) * 100) : 0
                            Text("\(item.total.formatted())円 (\(pct)%)").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Bar Chart

    private var barChartView: some View {
        let showAvg = (selectedPreset == .trend) && (viewModel.averageValue > 0)

        return Group {
            if isStackedByNecessity {
                Chart {
                    barMarks
                    if showAvg {
                        RuleMark(y: .value("平均", viewModel.averageValue))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .annotation(position: .top, alignment: .leading) {
                                Text("平均 \(viewModel.averageValue.formatted())円")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                            }
                    }
                    selectionOverlay
                }
                .frame(height: 300)
                .chartYScale(domain: 0...viewModel.upperScale)
                .chartXSelection(value: $selectedLabel)
                .chartForegroundStyleScale(["必要": Color.indigo, "便利": Color.orange, "贅沢": Color.pink])
                .chartLegend(showIncome ? .hidden : .visible)
            } else {
                Chart {
                    barMarks
                    if showAvg {
                        RuleMark(y: .value("平均", viewModel.averageValue))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .annotation(position: .top, alignment: .leading) {
                                Text("平均 \(viewModel.averageValue.formatted())円")
                                    .font(.system(size: 9)).foregroundColor(.secondary)
                            }
                    }
                    selectionOverlay
                }
                .frame(height: 300)
                .chartYScale(domain: 0...viewModel.upperScale)
                .chartXSelection(value: $selectedLabel)
                .chartLegend(showIncome ? .hidden : .visible)
            }
        }
    }

    @ChartContentBuilder
    private var barMarks: some ChartContent {
        ForEach(viewModel.summaries) { item in
            if isStackedByNecessity, let nec = item.necessity {
                BarMark(x: .value("項目", item.label), y: .value("金額", item.total))
                    .foregroundStyle(by: .value("必要度", nec))
                    .opacity(selectedLabel == nil || selectedLabel == item.label ? 1.0 : 0.4)
                    .accessibilityLabel(item.label)
                    .accessibilityValue("\(item.total)円")
            } else {
                BarMark(x: .value("項目", item.label), y: .value("金額", item.total))
                    .foregroundStyle((showIncome ? Color.green : Color.blue).gradient)
                    .opacity(selectedLabel == nil || selectedLabel == item.label ? 1.0 : 0.4)
                    .accessibilityLabel(item.label)
                    .accessibilityValue("\(item.total)円")
            }
        }
    }

    @ChartContentBuilder
    private var selectionOverlay: some ChartContent {
        if let lbl = selectedLabel, viewModel.summaries.contains(where: { $0.label == lbl }) {
            let grp = viewModel.summaries.filter { $0.label == lbl }
            let tot = grp.reduce(0) { $0 + $1.total }
            RuleMark(x: .value("選択", lbl)).foregroundStyle(Color.gray.opacity(0.15))
            PointMark(x: .value("項目", lbl), y: .value("金額", tot))
                .opacity(0)
                .annotation(position: .top, spacing: 5) {
                    selectionAnnotation(label: lbl, total: tot, group: grp)
                }
        }
    }

    @ViewBuilder
    private func selectionAnnotation(label: String, total: Int, group: [AnalyticsViewModel.SummaryItem]) -> some View {
        VStack(spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
            Text("\(total.formatted())円").font(.system(size: 14, weight: .bold))
            if isStackedByNecessity {
                HStack(spacing: 8) {
                    ForEach(["必要", "便利", "贅沢"], id: \.self) { nec in
                        let v = group.first(where: { $0.necessity == nec })?.total ?? 0
                        if v > 0 {
                            VStack(spacing: 0) {
                                Text(nec).font(.system(size: 8)).foregroundColor(.secondary)
                                Text("\(v.formatted())").font(.system(size: 10, weight: .bold)).foregroundColor(necessityColor(nec))
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
    }

    // MARK: - Colors

    private func chartColor(for item: AnalyticsViewModel.SummaryItem) -> Color {
        if viewModel.currentMetric == .necessity { return necessityColor(item.label) }
        let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .indigo, .mint, .cyan, .brown]
        if let idx = viewModel.summaries.firstIndex(where: { $0.id == item.id }) {
            return palette[idx % palette.count]
        }
        return .gray
    }

    private func necessityColor(_ label: String) -> Color {
        switch label {
        case "必要": return .indigo
        case "便利": return .orange
        case "贅沢": return .pink
        default: return .blue
        }
    }

    // MARK: - Sub Components

    @ViewBuilder
    private func subPickerRow(items: [(String, Bool)], onSelect: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.0) { idx, item in
                Button { onSelect(idx) } label: {
                    Text(item.0)
                        .font(.system(size: 13, weight: item.1 ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(item.1 ? Color.blue.opacity(0.15) : Color.clear)
                        .foregroundColor(item.1 ? .blue : .secondary)
                }
            }
        }
        .background(Color.gray.opacity(0.08))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func filterMenu(title: String, selected: Binding<String>, options: [String]) -> some View {
        Menu {
            Button("すべて") { selected.wrappedValue = "すべて"; update() }
            Divider()
            ForEach(options, id: \.self) { opt in
                Button(opt) { selected.wrappedValue = opt; update() }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected.wrappedValue == "すべて" ? "\(title): すべて" : selected.wrappedValue)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
            }
            .font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.blue.opacity(0.08)).cornerRadius(8)
        }
    }

    @ViewBuilder
    func monthYearPicker(year: Binding<Int>, month: Binding<Int>, showMonth: Bool) -> some View {
        HStack(spacing: 0) {
            Picker("", selection: year) {
                ForEach(years, id: \.self) { Text("\($0)年").tag($0).fixedSize() }
            }
            .pickerStyle(.wheel).frame(width: 100, height: 80).clipped()
            if showMonth {
                Picker("", selection: month) {
                    ForEach(months, id: \.self) { Text("\($0)月").tag($0).fixedSize() }
                }
                .pickerStyle(.wheel).frame(width: 70, height: 80).clipped()
            }
        }
    }

    // MARK: - State Helpers

    private func resetFilters() {
        selectedCategoryFilter = "すべて"
        selectedNecessityFilter = "すべて"
    }

    private func fixRangeIfNeeded() {
        // 現在の期間が新しいプリセット/トレンドで使えない場合はデフォルトに戻す
        if !availableRanges.contains(selectedRange) {
            selectedRange = availableRanges.first ?? .thisMonth
        }
    }

    private func resetAndUpdate() {
        selectedPreset = showIncome ? .trend : .breakdown
        selectedBreakdown = .category
        selectedTrend = .monthly
        selectedRange = showIncome ? .thisYear : .thisMonth
        resetFilters()
        selectedLabel = nil
        update()
    }

    private func update() {
        selectedLabel = nil
        viewModel.updateData(
            allReceipts: allReceipts,
            showIncome: showIncome,
            preset: selectedPreset,
            metric: currentMetric,
            range: selectedRange,
            startYear: startYear, startMonth: startMonth,
            endYear: endYear, endMonth: endMonth,
            categoryFilter: selectedCategoryFilter,
            necessityFilter: selectedNecessityFilter
        )
    }
}

// MARK: - PresetCard

struct PresetCard: View {
    let preset: InsightAnalyticsView.AnalysisPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: preset.icon)
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .white : .blue)
                Text(preset.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .primary)
                Text(preset.description)
                    .font(.system(size: 9))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue : Color(UIColor.tertiarySystemGroupedBackground))
            )
            .shadow(color: isSelected ? Color.blue.opacity(0.3) : Color.clear, radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - PillButton

struct PillButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(isSelected ? Color.blue : Color(UIColor.tertiarySystemGroupedBackground))
                .foregroundColor(isSelected ? .white : .secondary)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - ProminentFilterChip (後方互換)

struct ProminentFilterChip: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(isSelected ? Color.blue : Color.gray.opacity(0.1))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(20)
            .shadow(color: isSelected ? Color.blue.opacity(0.3) : Color.clear, radius: 4, x: 0, y: 2)
        }
    }
}
