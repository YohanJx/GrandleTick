import Foundation

/// 白名单与黑名单规则的内存快照，用于线程安全的后台日志过滤与实时分类判定。
struct WhitelistSnapshot: Sendable {
    let lowercasedApps: [String]
    let domains: [String]
    let lowercasedDomainSet: Set<String>
    let domainKeywords: [(domain: String, keyword: String)]
    let lowercasedBlacklistedApps: [String]
    let blacklistedDomains: [String]
    let lowercasedBlacklistedDomainSet: Set<String>
    let blacklistedDomainKeywords: [(domain: String, keyword: String)]

    init(whitelist: WhitelistManager) {
        // 1. 预处理白名单应用与域名，构建小写集合与标题匹配关键词。
        self.lowercasedApps = whitelist.whitelistedApps.map { $0.lowercased() }
        self.domains = whitelist.whitelistedDomains
        self.lowercasedDomainSet = Set(whitelist.whitelistedDomains.map { $0.lowercased() })
        self.domainKeywords = whitelist.whitelistedDomains.map { domain in
            let keyword = domain.components(separatedBy: ".").first?.lowercased() ?? domain.lowercased()
            return (domain: domain, keyword: keyword)
        }

        // 2. 预处理黑名单应用与域名，供分类时优先拦截娱乐项。
        self.lowercasedBlacklistedApps = whitelist.blacklistedApps.map { $0.lowercased() }
        self.blacklistedDomains = whitelist.blacklistedDomains
        self.lowercasedBlacklistedDomainSet = Set(whitelist.blacklistedDomains.map { $0.lowercased() })
        self.blacklistedDomainKeywords = whitelist.blacklistedDomains.map { domain in
            let keyword = domain.components(separatedBy: ".").first?.lowercased() ?? domain.lowercased()
            return (domain: domain, keyword: keyword)
        }
    }
}

/// 名单规则缓存键，同时覆盖白名单与黑名单，避免任一名单变更后今日分类累计缓存未失效。
struct WhitelistCacheKey: Equatable, Sendable {
    let apps: [String]
    let domains: [String]
    let blacklistedApps: [String]
    let blacklistedDomains: [String]

    init(whitelist: WhitelistManager) {
        apps = whitelist.whitelistedApps.map { $0.lowercased() }.sorted()
        domains = whitelist.whitelistedDomains.map { $0.lowercased() }.sorted()
        blacklistedApps = whitelist.blacklistedApps.map { $0.lowercased() }.sorted()
        blacklistedDomains = whitelist.blacklistedDomains.map { $0.lowercased() }.sorted()
    }
}

/// 统一承载“学习专注 vs 娱乐休闲”分类规则，消除实时弹窗、会话管理与统计引擎之间的重复判断。
enum ActivityClassifier {
    /// 判断日志是否属于无意义的系统权限提示或未知空记录。
    static func isInvalidLog(appName: String, windowTitle: String) -> Bool {
        windowTitle.contains("权限") || windowTitle.contains("未知") || appName.isEmpty
    }

    /// 判断当前活动是否为预览 App 打开的 PDF 文档。
    static func isPDFActivity(appName: String, windowTitle: String) -> Bool {
        let lowercasedAppName = appName.lowercased()
        let isPreview = lowercasedAppName.contains("预览") || lowercasedAppName.contains("preview")
        return isPreview && windowTitle.lowercased().contains(".pdf")
    }

    /// 解析网页活动的真实域名；当持久化记录缺少显式 domain 时，尝试从窗口标题关键词兜底还原。
    static func resolveDomain(
        domain: String?,
        windowTitle: String,
        whitelist: WhitelistSnapshot
    ) -> String? {
        // 1. 若已有采集到的非空域名，直接返回以保留一般网站的域名数据。
        if let domain, !domain.isEmpty {
            return domain
        }

        // 2. 兜底从窗口标题中提取白名单或黑名单域名关键词（兼容 B 站中文标题“哔哩哔哩”）。
        let lowercasedWindowTitle = windowTitle.lowercased()
        let allKeywords = whitelist.domainKeywords + whitelist.blacklistedDomainKeywords
        return allKeywords.first { entry in
            lowercasedWindowTitle.contains(entry.keyword)
                || (entry.keyword == "bilibili" && lowercasedWindowTitle.contains("哔哩哔哩"))
        }?.domain
    }

    /// 使用名单快照统一判定某项活动是否属于“学习专注”分类。
    static func isStudy(
        appName: String,
        windowTitle: String,
        domain: String?,
        bilibiliIdentifier: String?,
        whitelist: WhitelistSnapshot,
        resolveDomainFromTitle: Bool = true
    ) -> Bool {
        let lowercasedAppName = appName.lowercased()
        let isWebsite = BrowserService.isWebsiteActivity(appName: appName, domain: domain)

        // 1. 黑名单优先校验：命中黑名单的应用直接归入娱乐/休闲，不参与学习统计。
        let isBlacklistedApp = whitelist.lowercasedBlacklistedApps.contains { app in
            app == lowercasedAppName || app.contains(lowercasedAppName) || lowercasedAppName.contains(app)
        }
        if isBlacklistedApp {
            return false
        }

        // 2. 网页活动进一步校验域名黑白名单，并对 B 站视频执行专属知识区标识校验。
        if isWebsite {
            let effectiveDomain = resolveDomainFromTitle
                ? resolveDomain(domain: domain, windowTitle: windowTitle, whitelist: whitelist)
                : domain

            guard let effectiveDomain, !effectiveDomain.isEmpty else {
                return false
            }

            let lowercasedDomain = effectiveDomain.lowercased()
            if whitelist.lowercasedBlacklistedDomainSet.contains(lowercasedDomain) {
                return false
            }

            // B 站视频只有 bilibiliIdentifier 非空（API 确认知识区）才算学习；
            // 不能用窗口标题判断，避免 URL 获取失败退回标题兜底时把所有 B 站内容误归为学习。
            if lowercasedDomain == "bilibili.com" {
                return bilibiliIdentifier != nil
            }

            return whitelist.lowercasedDomainSet.contains(lowercasedDomain)
        }

        // 3. 预览 App 仅在查看 PDF 文档时计为学习，查看图片或欢迎页归入休闲。
        if lowercasedAppName.contains("预览") || lowercasedAppName.contains("preview") {
            return windowTitle.lowercased().contains(".pdf")
        }

        // 4. 其余本地应用按名称是否命中白名单（相等或互相包含）判定。
        return whitelist.lowercasedApps.contains { app in
            app == lowercasedAppName || app.contains(lowercasedAppName) || lowercasedAppName.contains(app)
        }
    }

    /// 供主线程实时状态直接调用的便捷入口。
    static func isStudy(
        appName: String,
        windowTitle: String,
        domain: String?,
        bilibiliIdentifier: String?,
        whitelist: WhitelistManager = .shared,
        resolveDomainFromTitle: Bool = false
    ) -> Bool {
        isStudy(
            appName: appName,
            windowTitle: windowTitle,
            domain: domain,
            bilibiliIdentifier: bilibiliIdentifier,
            whitelist: WhitelistSnapshot(whitelist: whitelist),
            resolveDomainFromTitle: resolveDomainFromTitle
        )
    }
}
