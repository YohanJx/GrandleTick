import Foundation

// MARK: - Supporting Enums and Models

/// 统计排行维度：应用、域名或具体窗口项
enum RankingDimension: String, CaseIterable, Identifiable, Sendable {
    case app, domain, item
    var id: String { rawValue }
}

/// 内容类型过滤器
enum ContentFilter: String, CaseIterable, Identifiable, Sendable {
    case all, website, pdf
    var id: String { rawValue }
}

/// 详细列表分类类型
enum DetailCategory: String, Sendable {
    case app, domain, pdf
}

/// 单项使用趋势的查询维度。
enum UsageQueryDimension: String, CaseIterable, Identifiable, Sendable {
    case app, domain, pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .app: return "App"
        case .domain: return "域名"
        case .pdf: return "PDF"
        }
    }
}

/// 单项使用趋势支持的时间范围。全部选项都按自然月展示，避免横轴粒度混乱。
enum UsageQueryRange: String, CaseIterable, Identifiable, Sendable {
    case recentSixMonths
    case recentTwelveMonths
    case currentYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentSixMonths: return "近 6 个月"
        case .recentTwelveMonths: return "近 12 个月"
        case .currentYear: return "今年"
        }
    }

    func interval(containing date: Date, calendar: Calendar) -> DateInterval? {
        // 1. 先取当前自然月或自然年的稳定边界，保证图表始终从完整月份开始。
        switch self {
        case .recentSixMonths, .recentTwelveMonths:
            guard let currentMonth = calendar.dateInterval(of: .month, for: date) else { return nil }
            let monthOffset = self == .recentSixMonths ? -5 : -11
            guard let start = calendar.date(byAdding: .month, value: monthOffset, to: currentMonth.start) else {
                return nil
            }

            // 2. 末月只统计到当前时刻，避免把尚未发生的月份尾部误解为缺失数据。
            return DateInterval(start: start, end: date)

        case .currentYear:
            guard let year = calendar.dateInterval(of: .year, for: date) else { return nil }
            return DateInterval(start: year.start, end: date)
        }
    }
}

/// 每日总计时长
struct DaySummary: Identifiable, Sendable {
    let date: Date
    let totalTime: TimeInterval
    var id: Date { date }
}

/// 某个 App、域名或 PDF 在一个自然月中的累计使用时长。
struct MonthlyUsageSummary: Identifiable, Sendable {
    let monthStart: Date
    let totalTime: TimeInterval
    var id: Date { monthStart }
}

/// 某个自然月内固定四个日期段的累计使用时长。
struct MonthlyWeekUsageSummary: Identifiable, Sendable {
    let monthStart: Date
    let weekIndex: Int
    let totalTime: TimeInterval
    var id: String { "\(monthStart.timeIntervalSinceReferenceDate)|\(weekIndex)" }
}

/// 排行榜单项
struct RankingEntry: Identifiable, Sendable {
    let name: String
    let totalTime: TimeInterval
    var id: String { name }
}

/// 过滤选项（供下拉菜单展示）
struct FilterOption: Identifiable, Sendable {
    let name: String
    let totalTime: TimeInterval
    let queryKey: String

    init(name: String, totalTime: TimeInterval, queryKey: String? = nil) {
        self.name = name
        self.totalTime = totalTime
        // 显示名与查询键默认一致；PDF 使用文件指纹作为查询键，避免重命名后月度记录被拆散。
        self.queryKey = queryKey ?? name
    }

    var id: String { queryKey }
}

/// 按维度分组的明细数据
struct GroupedSummary: Identifiable, Sendable {
    let name: String
    let totalTime: TimeInterval
    let details: [SummaryDetail]
    var id: String { name }
}

/// 分组下的具体明细子项
struct SummaryDetail: Identifiable, Sendable {
    let name: String
    let subtitle: String?
    let totalTime: TimeInterval
    var id: String { "\(name)|\(subtitle ?? "")" }
}

/// 最高耗时应用概览
struct AppDurationSummary: Sendable {
    let displayName: String
    let totalTime: TimeInterval
}

/// 过滤器输入条件结构体
struct FilterCriteria: Sendable {
    let normalizedSearchText: String
    let selectedContentFilter: ContentFilter
    let selectedAppFilter: String?
    let selectedDomainFilter: String?
}

/// 处理且规范化后的用户活动日志
struct PreparedLog: Identifiable, Sendable {
    let identity: PreparedLogIdentity
    let appName: String
    let windowTitle: String
    let startTime: Date
    let dayStart: Date
    let duration: TimeInterval
    let resolvedDomain: String?
    let bilibiliIdentifier: String?
    let fullUrl: String?
    let searchableText: String
    let isPDF: Bool
    let isWebsite: Bool
    let isStudy: Bool
    let pdfIdentifier: String?
    var id: PreparedLogIdentity { identity }

    var endTime: Date {
        startTime.addingTimeInterval(duration)
    }

    init?(log: ActivityLog, whitelist: WhitelistSnapshot, calendar: Calendar) {
        self.init(
            snapshot: ActivityLogSnapshot(
                appName: log.appName,
                windowTitle: log.windowTitle,
                startTime: log.startTime,
                duration: log.duration,
                domain: log.domain,
                bilibiliIdentifier: log.bilibiliIdentifier,
                fullUrl: log.fullUrl,
                pdfIdentifier: log.pdfIdentifier
            ),
            whitelist: whitelist,
            calendar: calendar
        )
    }

    init?(snapshot log: ActivityLogSnapshot, whitelist: WhitelistSnapshot, calendar: Calendar) {
        // 1. 过滤掉无意义的系统权限提示或未知/无效空日志。
        if ActivityClassifier.isInvalidLog(appName: log.appName, windowTitle: log.windowTitle) { return nil }
        
        let isWebsite = BrowserService.isWebsiteActivity(appName: log.appName, domain: log.domain)
        
        // 2. 解析域名。如果有域名，无论是否在白名单，均保留以支持网站统计与分类。
        let resolvedDomain = ActivityClassifier.resolveDomain(
            domain: log.domain,
            windowTitle: log.windowTitle,
            whitelist: whitelist
        )
        
        self.identity = PreparedLogIdentity(
            appName: log.appName,
            windowTitle: log.windowTitle,
            startTime: log.startTime,
            duration: log.duration,
            domain: log.domain,
            bilibiliIdentifier: log.bilibiliIdentifier,
            fullUrl: log.fullUrl,
            pdfIdentifier: log.pdfIdentifier
        )
        self.appName = log.appName
        self.windowTitle = log.windowTitle
        self.startTime = log.startTime
        self.dayStart = calendar.startOfDay(for: log.startTime)
        self.duration = log.duration
        self.resolvedDomain = resolvedDomain
        self.bilibiliIdentifier = log.bilibiliIdentifier
        self.fullUrl = log.fullUrl
        self.pdfIdentifier = log.pdfIdentifier
        
        // 3. 构建搜索文本，以便后续过滤与检索。
        self.searchableText = [log.appName, log.windowTitle, resolvedDomain ?? "", log.fullUrl ?? ""].joined(separator: "\n").lowercased()
        
        // 4. PDF 判断：必须是预览 App 且文件名以 .pdf 结尾。
        self.isPDF = ActivityClassifier.isPDFActivity(appName: log.appName, windowTitle: log.windowTitle)
        self.isWebsite = isWebsite
        
        // 5. 复用 ActivityClassifier 统一分类学习 vs 娱乐/休闲（黑名单优先归入娱乐，白名单命中归入学习）。
        self.isStudy = ActivityClassifier.isStudy(
            appName: log.appName,
            windowTitle: log.windowTitle,
            domain: resolvedDomain,
            bilibiliIdentifier: log.bilibiliIdentifier,
            whitelist: whitelist,
            resolveDomainFromTitle: false
        )
    }
}

/// 统计页只读快照，避免切换时间范围时在主线程批量实例化 SwiftData 模型对象
struct ActivityLogSnapshot: Sendable {
    let appName: String
    let windowTitle: String
    let startTime: Date
    let duration: TimeInterval
    let domain: String?
    let bilibiliIdentifier: String?
    let fullUrl: String?
    let pdfIdentifier: String?
}

/// 用于唯一标识一条日志的结构体
struct PreparedLogIdentity: Hashable, Sendable {
    let appName: String
    let windowTitle: String
    let startTime: Date
    let duration: TimeInterval
    let domain: String?
    let bilibiliIdentifier: String?
    let fullUrl: String?
    let pdfIdentifier: String?
}

/// 周期对比数据模型
struct ReportComparison: Sendable {
    let totalDurationDelta: TimeInterval
    let totalDurationChangeRate: Double?
    let activeDaysDelta: Int
}

/// 学习活跃时段分类
enum ReportTimeSlot: String, Sendable {
    case morning, afternoon, evening, lateNight
    var title: String {
        switch self {
        case .morning: return "上午"
        case .afternoon: return "下午"
        case .evening: return "晚上"
        case .lateNight: return "深夜"
        }
    }
}

/// 统一时间周期与范围分类
enum StatisticsRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month, year, all
    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .today: return "今天"
        case .week: return "本周"
        case .month: return "本月"
        case .year: return "今年"
        case .all: return "全部"
        }
    }

    var title: String {
        switch self {
        case .today: return "今天"
        case .week: return "本周统计"
        case .month: return "本月统计"
        case .year: return "今年统计"
        case .all: return "全部记录"
        }
    }

    var previousTitle: String {
        switch self {
        case .today: return "昨天"
        case .week: return "上周"
        case .month: return "上月"
        case .year: return "去年"
        case .all: return "前一期"
        }
    }
}

/// 后台计算结果的封装包，用于批量更新主线程状态
struct FilterComputationResult: Sendable {
    let filteredLogs: [PreparedLog]
    let previousFilteredLogs: [PreparedLog]
    let daySummaries: [DaySummary]
    let rangeTotalDuration: TimeInterval
    let topAppSummary: AppDurationSummary?
    let rankingEntries: [RankingEntry]
    let resolvedSelectedDay: Date?
    let todayDuration: TimeInterval

    // 选中日期的详情聚合数据
    let selectedDayAppSummaries: [GroupedSummary]
    let selectedDayDomainSummaries: [GroupedSummary]
    let selectedDayPdfSummaries: [GroupedSummary]

    // 常用项目排行
    let topWebsites: [RankingEntry]
    let topPDFs: [RankingEntry]
    let topStudyApps: [RankingEntry]

    // 合并自报告的数据指标
    let studyDuration: TimeInterval
    let entertainmentDuration: TimeInterval
    let activeDays: Int
    let averageDailyDuration: TimeInterval
    let strongestDay: DaySummary?
    let shortestActiveDay: DaySummary?
    let longestStreak: Int
    let websiteDuration: TimeInterval
    let pdfDuration: TimeInterval
    let primaryTimeSlot: ReportTimeSlot?
    let earliestStudyStart: Date?
    let latestStudyEnd: Date?
    let comparison: ReportComparison?
    let hourlyDurations: [Double]
}
