import SwiftUI
import Charts

/// 数据中心“使用查询”页面的月度/周度分组趋势视图。
struct UsageQuerySection: View {
    @Binding var selectedDimension: UsageQueryDimension
    @Binding var selectedRange: UsageQueryRange
    @Binding var selectedItem: String?
    @Binding var selectedMonth: Date?
    let appOptions: [FilterOption]
    let domainOptions: [FilterOption]
    let pdfOptions: [FilterOption]
    let monthlySummaries: [MonthlyUsageSummary]
    let monthlyWeekSummaries: [MonthlyWeekUsageSummary]
    let totalDuration: TimeInterval
    let isLoading: Bool
    let formatDuration: (TimeInterval) -> String

    @State private var optionSearchText = ""
    @State private var isShowingOptionPicker = false

    private var options: [FilterOption] {
        switch selectedDimension {
        case .app: return appOptions
        case .domain: return domainOptions
        case .pdf: return pdfOptions
        }
    }

    private var matchingOptions: [FilterOption] {
        let keyword = optionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return options }
        return options.filter { $0.name.localizedStandardContains(keyword) }
    }

    private var selectedOption: FilterOption? {
        guard let selectedItem else { return nil }
        return options.first { $0.queryKey == selectedItem }
    }

    private var displayedMonthlySummaries: [MonthlyUsageSummary] {
        // 1. 裁掉首尾连续的零值月份，避免少量近期数据全部挤在图表右侧。
        guard let firstActiveIndex = monthlySummaries.firstIndex(where: { $0.totalTime > 0 }),
              let lastActiveIndex = monthlySummaries.lastIndex(where: { $0.totalTime > 0 }) else {
            return monthlySummaries
        }

        // 2. 保留首尾活跃月之间的零值月份，它们代表真实中断，不能为了居中而抹掉。
        return Array(monthlySummaries[firstActiveIndex...lastActiveIndex])
    }

    private var selectedSummary: MonthlyUsageSummary? {
        guard let selectedMonth else { return displayedMonthlySummaries.last }
        return displayedMonthlySummaries.first { summary in
            Calendar.current.isDate(summary.monthStart, equalTo: selectedMonth, toGranularity: .month)
        } ?? displayedMonthlySummaries.last
    }

    private var displayedMonthlyWeekSummaries: [MonthlyWeekUsageSummary] {
        guard let firstMonth = displayedMonthlySummaries.first?.monthStart,
              let lastMonth = displayedMonthlySummaries.last?.monthStart else {
            return monthlyWeekSummaries
        }
        return monthlyWeekSummaries.filter {
            $0.monthStart >= firstMonth && $0.monthStart <= lastMonth
        }
    }

    private var maximumHours: Double {
        max(1, (displayedMonthlyWeekSummaries.map(\.totalTime).max() ?? 0) / 3600 * 1.15)
    }

    /// 基于月份数量估算每根柱的理想宽度，用于计算绘图区总宽度；柱体本身使用自动宽度避免重叠。
    private var dynamicBarWidth: CGFloat {
        let monthCount = displayedMonthlySummaries.count
        switch monthCount {
        case ...2:  return 28
        case 3:     return 24
        case 4...5: return 20
        case 6...8: return 16
        default:    return 12
        }
    }

    /// 根据月份数量计算绘图区宽度。每个月份占据固定槽位宽度，少月时图表自动收窄，
    /// 多月时允许占满容器，避免柱组在大片空白中迷失。
    private var chartPlotWidth: CGFloat? {
        let monthCount = displayedMonthlySummaries.count
        // 每个月份 4 根柱 + 间隙，按柱宽的倍率估算合理的槽位宽度。
        let slotWidth = dynamicBarWidth * 6.5
        let computedWidth = CGFloat(monthCount) * slotWidth
        // 月份较多时不设固定宽度，让 Chart 自行铺满可用空间。
        return monthCount <= 7 ? max(computedWidth, 180) : nil
    }

    private var selectedMonthKey: Binding<String?> {
        Binding(
            get: {
                selectedMonth.map { monthChartKey($0) }
            },
            set: { key in
                // 分类横轴返回的是稳定的月份键，这里映射回日期以保留原有的月份点击查询能力。
                selectedMonth = displayedMonthlySummaries.first {
                    monthChartKey($0.monthStart) == key
                }?.monthStart
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("查询对象")
                            .font(.headline)
                        Text(queryDescription)
                            .font(.caption)
                            .foregroundStyle(AppDesign.secondaryText)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        ForEach(UsageQueryDimension.allCases) { dimension in
                            Button(dimension.title) {
                                selectedDimension = dimension
                            }
                            .buttonStyle(AppCapsuleButtonStyle(
                                role: selectedDimension == dimension ? .primary : .secondary,
                                compact: true
                            ))
                        }
                    }
                }

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AppDesign.tertiaryText)

                        TextField("搜索\(selectedDimension.title)名称", text: $optionSearchText)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                // 回车直接选择首个匹配项，键盘查询不必再展开选择框。
                                if let firstMatch = matchingOptions.first {
                                    selectedItem = firstMatch.queryKey
                                    optionSearchText = ""
                                    isShowingOptionPicker = false
                                }
                            }

                        if !optionSearchText.isEmpty {
                            Button {
                                optionSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppDesign.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清空搜索")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: AppDesign.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                            .fill(AppDesign.elevatedPanelBackground)
                    )

                    Button {
                        isShowingOptionPicker.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("选择\(selectedDimension.title)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppDesign.secondaryText)
                                Text(selectedOption?.name ?? "请选择查询对象")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppDesign.primaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppDesign.tertiaryText)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 250, height: AppDesign.controlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                                .fill(AppDesign.elevatedPanelBackground)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(options.isEmpty)
                    .popover(isPresented: $isShowingOptionPicker, arrowEdge: .top) {
                        optionPickerPopover
                    }
                }

                HStack(spacing: 8) {
                    ForEach(UsageQueryRange.allCases) { range in
                        Button(range.title) {
                            selectedRange = range
                        }
                        .buttonStyle(AppCapsuleButtonStyle(
                            role: selectedRange == range ? .primary : .secondary,
                            compact: true
                        ))
                    }

                    Spacer()

                    if !optionSearchText.isEmpty {
                        Text("匹配 \(matchingOptions.count) 项")
                            .font(.caption)
                            .foregroundStyle(AppDesign.secondaryText)
                    } else if !options.isEmpty {
                        Text("共 \(options.count) 项，可输入名称搜索")
                            .font(.caption)
                            .foregroundStyle(AppDesign.secondaryText)
                    }
                }
            }
            .padding(16)
            .statisticsPanel(isSecondary: true)

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在汇总月度使用时间…")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 290)
                .statisticsPanel()
            } else if options.isEmpty || selectedItem == nil {
                VStack(spacing: 12) {
                    Image(systemName: emptyStateIcon)
                        .font(.system(size: 34))
                        .foregroundStyle(AppDesign.tertiaryText)
                    Text("这个时间范围没有\(selectedDimension.title)记录")
                        .font(.headline)
                    Text("可以切换查询类型或扩大月份范围。")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 290)
                .statisticsPanel()
            } else {
                monthlyChart
            }
        }
        .onChange(of: selectedDimension) { _, _ in
            optionSearchText = ""
            isShowingOptionPicker = false
        }
        .onChange(of: selectedRange) { _, _ in
            optionSearchText = ""
            isShowingOptionPicker = false
        }
    }

    private var optionPickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择\(selectedDimension.title)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(matchingOptions.count) 项")
                    .font(.caption)
                    .foregroundStyle(AppDesign.secondaryText)
            }

            Divider()

            if matchingOptions.isEmpty {
                Text("没有匹配的\(selectedDimension.title)")
                    .font(.caption)
                    .foregroundStyle(AppDesign.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 固定浮层尺寸并在内部滚动，避免长文件名或大量选项把系统菜单撑满整个窗口。
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(matchingOptions) { option in
                            Button {
                                selectedItem = option.queryKey
                                optionSearchText = ""
                                isShowingOptionPicker = false
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(AppDesign.primaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(formatDuration(option.totalTime))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(AppDesign.secondaryText)
                                    }

                                    Spacer(minLength: 8)

                                    if selectedItem == option.queryKey {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppDesign.primaryBlue)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selectedItem == option.queryKey ? AppDesign.primaryBlueMuted : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 380, height: optionPickerHeight)
    }

    private var optionPickerHeight: CGFloat {
        // 最多直接露出 6 行，其余内容通过滚动查看；少量结果时浮层自动收紧。
        let visibleRowCount = min(max(matchingOptions.count, 1), 6)
        return 70 + CGFloat(visibleRowCount * 46)
    }

    private var monthlyChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedOption?.name ?? "") 使用趋势")
                        .font(.headline)
                        .lineLimit(1)
                    Text(formatMonthRange())
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("区间总计")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                    Text(formatDuration(totalDuration))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AppDesign.primaryBlue)
                }
            }

            Chart(displayedMonthlyWeekSummaries) { summary in
                // 使用比例宽度而非固定像素，让 Charts 在 span 内自动分配每根柱的空间，避免柱间重叠。
                BarMark(
                    x: .value("月份", monthChartKey(summary.monthStart)),
                    y: .value("小时", summary.totalTime / 3600)
                )
                .position(
                    by: .value("周次", summary.weekIndex),
                    // 同月四柱紧凑排列，两侧留白拉开月份间距。
                    span: .ratio(0.62)
                )
                .foregroundStyle(weekColor(summary.weekIndex))
                .cornerRadius(3)

                if summary.totalTime == 0 {
                    // 零值柱本身没有高度，用基线圆点保留周位置，避免误以为该月缺少某一周。
                    PointMark(
                        x: .value("月份", monthChartKey(summary.monthStart)),
                        y: .value("小时", 0)
                    )
                    .position(
                        by: .value("周次", summary.weekIndex),
                        span: .ratio(0.62)
                    )
                    .symbolSize(14)
                    .foregroundStyle(weekColor(summary.weekIndex).opacity(0.7))
                }
            }
            .frame(height: 260)
            .chartYScale(domain: 0...maximumHours)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(hours == 0 ? "0h" : "\(Int(hours.rounded()))h")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    // 月份之间用虚线分隔，帮助辨认柱组归属。
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisTick()
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(formatAxisMonth(key))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            // 月份少时收窄绘图区域，让柱组自然聚拢而非铺满整个宽度。
            .chartPlotStyle { plotArea in
                plotArea.frame(width: chartPlotWidth)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .chartXSelection(value: selectedMonthKey)
            .id("\(selectedDimension.rawValue)|\(selectedRange.rawValue)|\(selectedItem ?? "")")

            HStack {
                HStack(spacing: 12) {
                    ForEach(1...4, id: \.self) { weekIndex in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(weekColor(weekIndex))
                                .frame(width: 7, height: 7)
                            Text("第\(weekIndex)周")
                                .font(.caption)
                                .foregroundStyle(AppDesign.secondaryText)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("第 4 周包含 22 日至月底")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                    if let selectedSummary {
                        Text("\(formatMonthYear(selectedSummary.monthStart)) · \(formatDuration(selectedSummary.totalTime))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
            }
        }
        .padding(18)
        .statisticsPanel()
    }

    private var emptyStateIcon: String {
        switch selectedDimension {
        case .app: return "app.dashed"
        case .domain: return "network.slash"
        case .pdf: return "doc.text.magnifyingglass"
        }
    }

    private var queryDescription: String {
        switch selectedDimension {
        case .app:
            return "学习 App 优先展示，其余应用合并为娱乐与杂项"
        case .domain:
            return "仅显示白名单和已识别的学习网站"
        case .pdf:
            return "搜索 PDF，再按自然月查看使用时长"
        }
    }

    private func formatMonthRange() -> String {
        guard let first = displayedMonthlySummaries.first?.monthStart,
              let last = displayedMonthlySummaries.last?.monthStart else {
            return selectedRange.title
        }
        return "\(formatMonthYear(first))—\(formatMonthYear(last)) · 仅展示有记录区间"
    }

    private func monthChartKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private func formatAxisMonth(_ key: String) -> String {
        guard let month = Int(key.suffix(2)) else { return key }
        return "\(month)月"
    }

    private func weekColor(_ weekIndex: Int) -> Color {
        switch weekIndex {
        case 1: return AppDesign.primaryBlue.opacity(0.34)
        case 2: return AppDesign.primaryBlue.opacity(0.52)
        case 3: return AppDesign.primaryBlue.opacity(0.72)
        default: return AppDesign.primaryBlue
        }
    }

    private func formatMonthYear(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }
}
