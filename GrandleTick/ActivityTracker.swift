import AppKit
import SwiftData
import CryptoKit

struct BrowserTitleData {
    let displayTitle: String
    let groupedTitle: String
}

@MainActor
@Observable
final class ActivityTracker {
    var currentAppName: String = ""
    var currentWindowTitle: String = ""
    var currentGroupedTitle: String = ""

    var currentDomain: String? = nil
    var currentBilibiliId: String? = nil
    var currentBilibiliTidV2: Int? = nil
    var currentFullUrl: String? = nil
    var currentPdfIdentifier: String? = nil
    var activityDidChange: (() -> Void)?

    static var titleCache: [String: BrowserTitleData] = [:]
    static var bilibiliIdToMainTitleCache: [String: String] = [:]
    private static var bilibiliMetadataCache: [String: BilibiliVideoMetadata] = [:]

    private var lastBrowserURLRefreshAt: Date = .distantPast
    private var lastTrustCheckAt: Date = .distantPast
    private var cachedAccessibilityTrusted = false
    private var lastResolvedSnapshot: TrackedSnapshot?
    private var pendingBrowserURLRefreshKeys: Set<BrowserURLRefreshKey> = []
    private var prefetchedBrowserURLResults: [BrowserURLRefreshKey: BrowserURLRefreshResult] = [:]
    private var pendingBilibiliMetadataRequests: Set<String> = []
    nonisolated(unsafe) private var activationObserver: NSObjectProtocol?
    private var observedProcessId: pid_t?
    nonisolated(unsafe) private var activeAppObserver: AXObserver?
    nonisolated(unsafe) private var observedFocusedWindow: AXUIElement?
    private var lastPublishedActivity: PublishedActivityState?

    init() {
        // 启动阶段只静默读取授权状态，避免签名变化或系统权限状态异常时反复弹出授权窗口。
        // 首次授权仍由界面的“前往开启辅助功能权限”按钮承接，确保提示来自用户主动操作。
        cachedAccessibilityTrusted = checkAccessibilityPermissions(prompt: false)
        track(forceRefresh: true)

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 用户可能刚在系统设置里授予或撤销权限；应用切换是可靠且低频的刷新时机，
                // 这里绕过 60 秒缓存，但不影响标题变化等高频事件的性能。
                self?.refreshAccessibilityTrust()
            }
        }
    }

    deinit {
        // 1. 移除系统前台应用切换通知观察者。
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        
        // 2. 释放 AXObserver 观察者，并从运行循环中移除关联的源，防止观察回调访问已被销毁的实例（野指针崩溃）。
        if let observer = activeAppObserver {
            if let window = observedFocusedWindow {
                AXObserverRemoveNotification(observer, window, kAXTitleChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    func checkAccessibilityPermissions(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func refreshAccessibilityTrust() {
        // 1. 用户主动回到菜单或切换应用时立即读取系统状态，避免授权成功后仍显示旧缓存。
        cachedAccessibilityTrusted = checkAccessibilityPermissions(prompt: false)
        lastTrustCheckAt = Date()

        // 2. 使用刚更新的权限状态重新识别前台窗口；track 内的低频兜底检查会因时间戳更新而跳过。
        track(forceRefresh: true)
    }

    func track(forceRefresh: Bool = false) {
        // 1. 每次调用都来自应用切换、焦点窗口变化或标题变化事件，必须立即读取新状态。
        // 这里不能做时间节流，否则用户快速切窗时事件会被丢弃，导致旧会话被多记数秒。
        let now = Date()

        // 2. 低频检查作为权限变化的兜底；用户可见的应用切换和菜单打开路径会主动绕过缓存。
        if now.timeIntervalSince(lastTrustCheckAt) >= AppConfig.trustRefreshInterval {
            cachedAccessibilityTrusted = checkAccessibilityPermissions(prompt: false)
            lastTrustCheckAt = now
        }

        // 3. 获取前台最上层应用，若获取不到则清理状态；若为 GrandleTick 自身（弹出菜单栏弹层场景）则保留上次状态不变。
        guard let activeApp = NSWorkspace.shared.frontmostApplication else {
            removeActiveAppObserver()
            clearTrackedState()
            return
        }
        if activeApp.bundleIdentifier == Bundle.main.bundleIdentifier {
            // NSPopover（菜单栏弹层）弹出时系统会短暂把 GrandleTick 设为前台应用，
            // 但这不代表用户真正切换了应用，应保留上次的追踪状态不变，
            // 否则会导致学习会话被短暂中断并错误计入娱乐时间。
            return
        }

        // 4. 辅助功能权限受阻时，向界面更新状态，提示开启辅助功能权限。
        if !cachedAccessibilityTrusted {
            removeActiveAppObserver()
            resetBrowserMetadata()
            currentAppName = "权限受阻"
            currentWindowTitle = "需开启辅助功能权限"
            currentGroupedTitle = "需开启辅助功能权限"
            publishActivityChangeIfNeeded()
            return
        }

        let appName = activeApp.localizedName ?? "未知应用"
        let bundleId = activeApp.bundleIdentifier ?? ""
        let processId = activeApp.processIdentifier

        // 5. 过滤掉不属于用户前台交互的应用（如系统服务、守护进程、屏保等）。
        guard isUserFacingApp(activeApp) else {
            removeActiveAppObserver()
            clearTrackedState()
            return
        }

        // 6. 对当前前台 App 安装 AXObserver，补齐 NSWorkspace 只通知“应用切换”、不通知“同一应用内切窗口/标题变化”的空白。
        installActiveAppObserverIfNeeded(processId: processId)

        let isBrowserApp = BrowserService.isBrowserApp(bundleId: bundleId)
        let isPreviewApp = bundleId == "com.apple.Preview" || appName == "预览"

        // 7. 获取真正承载用户内容的窗口及其标题。
        // 浏览器的标签页悬浮卡片会被辅助功能接口短暂报告为“焦点窗口”，其中可能包含
        // “内存用量高 · 843 MB”等 Chrome 自己的提示。浏览器优先读取主窗口，避免把浮层文案当成网页标题。
        let appRef = AXUIElementCreateApplication(processId)
        guard let windowElement = trackedWindowElement(for: appRef, prefersMainWindow: isBrowserApp) else {
            observedFocusedWindow = nil
            clearTrackedState()
            return
        }
        observeTitleChangesIfNeeded(for: windowElement)

        var titleRef: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
        guard titleResult == .success, let rawTitle = titleRef as? String else {
            clearTrackedState()
            return
        }

        if isPreviewApp {
            // 8. 针对预览 App：如果识别为 PDF 文档，则以 PDF 特殊路径进行匹配和上报；否则（如打开的是图片或处于空窗状态），则不拦截并落入后面的常规应用处理，记为娱乐/休闲时长。
            if let normalizedTitle = normalizedPreviewPDFTitle(from: rawTitle) {
                // (1) 复制焦点窗口的 AXDocument 属性获取真实的 file:// 协议路径
                var docRef: CFTypeRef?
                let docResult = AXUIElementCopyAttributeValue(windowElement, "AXDocument" as CFString, &docRef)
                let docUrl: URL? = {
                    if docResult == .success, let docUrlString = docRef as? String {
                        return URL(string: docUrlString)
                    }
                    return nil
                }()
                
                // (2) 使用系统 Inode 与快速文件哈希特征指纹唯一识别该 PDF
                let pdfId = generatePDFIdentifier(for: docUrl)

                applySnapshot(
                    TrackedSnapshot(
                        processId: processId,
                        appName: appName,
                        bundleId: bundleId,
                        rawTitle: rawTitle,
                        displayTitle: normalizedTitle,
                        groupedTitle: normalizedTitle,
                        domain: nil,
                        bilibiliIdentifier: nil,
                        bilibiliTidV2: nil,
                        fullUrl: nil,
                        pdfIdentifier: pdfId
                    )
                )
                return
            }
        }

        if isBrowserApp {
            resolveBrowserSnapshot(
                appName: appName,
                bundleId: bundleId,
                processId: processId,
                rawTitle: rawTitle,
                forceRefresh: forceRefresh,
                now: now
            )
            return
        }

        applySnapshot(
            TrackedSnapshot(
                processId: processId,
                appName: appName,
                bundleId: bundleId,
                rawTitle: rawTitle,
                displayTitle: rawTitle,
                groupedTitle: appName,
                domain: nil,
                bilibiliIdentifier: nil,
                bilibiliTidV2: nil,
                fullUrl: nil,
                pdfIdentifier: nil
            )
        )
    }

    private func trackedWindowElement(
        for appElement: AXUIElement,
        prefersMainWindow: Bool
    ) -> AXUIElement? {
        // 1. 浏览器优先取主窗口，隔离标签页悬浮卡片、菜单和提示气泡等临时焦点元素。
        if prefersMainWindow {
            var mainWindowRef: CFTypeRef?
            let mainWindowResult = AXUIElementCopyAttributeValue(
                appElement,
                kAXMainWindowAttribute as CFString,
                &mainWindowRef
            )
            if mainWindowResult == .success, let mainWindow = mainWindowRef as! AXUIElement? {
                return mainWindow
            }
        }

        // 2. 非浏览器优先用焦点窗口；浏览器取不到主窗口时也用它兜底，避免全屏切换期间停止统计。
        var focusedWindowRef: CFTypeRef?
        let focusedWindowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        )
        if focusedWindowResult == .success, let focusedWindow = focusedWindowRef as! AXUIElement? {
            return focusedWindow
        }

        // 3. 菜单栏 NSPopover 弹出时会抢走前台应用的窗口焦点，导致 kAXFocusedWindowAttribute
        // 短暂失效。此时尝试用主窗口兜底，避免把瞬时焦点丢失误判为用户切走应用而清空会话。
        var mainWindowRef: CFTypeRef?
        let mainWindowResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXMainWindowAttribute as CFString,
            &mainWindowRef
        )
        if mainWindowResult == .success, let mainWindow = mainWindowRef as! AXUIElement? {
            return mainWindow
        }

        return nil
    }

    private func resolveBrowserSnapshot(
        appName: String,
        bundleId: String,
        processId: pid_t,
        rawTitle: String,
        forceRefresh: Bool,
        now: Date
    ) {
        // 1. 用进程和原始标题标识本次读取，避免把旧标签页结果用于新页面。
        let refreshKey = BrowserURLRefreshKey(
            processId: processId,
            appName: appName,
            rawTitle: rawTitle
        )

        if let prefetchedResult = prefetchedBrowserURLResults.removeValue(forKey: refreshKey) {
            lastBrowserURLRefreshAt = now
            // 网址读取可能因浏览器忙碌或临时失去焦点而失败；同一页面已有可靠快照时，
            // 保留其分类和统计身份，避免退回标题兜底后累计值反复跳到另一组记录。
            // 新标题或新进程不能沿用旧快照，否则会把新视频错误归到原视频。
            if prefetchedResult.url == nil,
               let lastResolvedSnapshot,
               lastResolvedSnapshot.processId == processId,
               lastResolvedSnapshot.rawTitle == rawTitle {
                applySnapshot(lastResolvedSnapshot)
                return
            }
            applyResolvedBrowserSnapshot(
                appName: appName,
                bundleId: bundleId,
                processId: processId,
                rawTitle: rawTitle,
                browserUrl: prefetchedResult.url
            )
            return
        }

        // 2. 同一浏览器窗口/标签页（processId + rawTitle 均未变）的缓存快照始终可复用，
        // 因为标题不变意味着用户没有切标签页或导航到新页面。
        // forceRefresh 只决定是否在后台重新获取 URL，不应丢弃已解析的有效快照——
        // 否则会短暂发布 browserUrl=nil 的兜底状态，导致白名单域名识别失败，
        // 把正在进行的学习会话瞬间误判为娱乐。
        if let lastResolvedSnapshot,
           lastResolvedSnapshot.processId == processId,
           lastResolvedSnapshot.rawTitle == rawTitle {
            let needsRefresh = forceRefresh
                || now.timeIntervalSince(lastBrowserURLRefreshAt) >= AppConfig.browserURLRefreshInterval
            if needsRefresh {
                scheduleBrowserURLRefresh(for: refreshKey)
            }
            applySnapshot(lastResolvedSnapshot)
            return
        }

        // 3. 新标签页和标题变化以前会在主线程同步执行 AppleScript，最慢时会冻结整个 SwiftUI 界面。
        // 先根据窗口标题发布轻量兜底状态，再由 utility 任务读取 URL 并回到主线程修正结果。
        scheduleBrowserURLRefresh(for: refreshKey)
        applyResolvedBrowserSnapshot(
            appName: appName,
            bundleId: bundleId,
            processId: processId,
            rawTitle: rawTitle,
            browserUrl: nil
        )
    }

    private func applyResolvedBrowserSnapshot(
        appName: String,
        bundleId: String,
        processId: pid_t,
        rawTitle: String,
        browserUrl: String?
    ) {
        // 1. 从浏览器 URL 中提取域名，并进行白名单域名匹配。
        let matchedDomain: String? = {
            guard let browserUrl,
                  let url = URL(string: browserUrl),
                  let host = url.host?.lowercased() else {
                return nil
            }
            return matchedWhitelistedDomainFromHost(host) ?? host
        }()

        // 2. 如果是 Bilibili 网站，则分流到 Bilibili 的解析逻辑中。
        if matchedDomain == "bilibili.com",
           let browserUrl {
            resolveBilibiliSnapshot(
                appName: appName,
                bundleId: bundleId,
                processId: processId,
                rawTitle: rawTitle,
                browserUrl: browserUrl
            )
            return
        }

        // 3. 检查本地标题缓存以避免重复的字符串解析。
        if let cachedBrowserTitleData = ActivityTracker.titleCache[browserTitleCacheKey(originalTitle: rawTitle, domain: matchedDomain)] {
            let snapshot = TrackedSnapshot(
                processId: processId,
                appName: appName,
                bundleId: bundleId,
                rawTitle: rawTitle,
                displayTitle: cachedBrowserTitleData.displayTitle,
                groupedTitle: cachedBrowserTitleData.groupedTitle,
                domain: matchedDomain,
                bilibiliIdentifier: matchedDomain == "bilibili.com" ? browserUrl.flatMap(BilibiliService.extractIdentifier) : nil,
                bilibiliTidV2: nil,
                fullUrl: browserUrl,
                pdfIdentifier: nil
            )
            applySnapshot(snapshot)
            return
        }

        var displayTitle = rawTitle
        var groupedTitle = rawTitle
        var hasMatchedDomain = false
        var targetMatchedDomain: String? = matchedDomain
        var bilibiliIdentifier: String?

        if let currentBrowserUrl = browserUrl,
           let url = URL(string: currentBrowserUrl),
           let host = url.host?.lowercased() {
            hasMatchedDomain = true
            let resolvedDomain = matchedWhitelistedDomainFromHost(host) ?? host
            targetMatchedDomain = resolvedDomain

            if resolvedDomain == "bilibili.com" {
                bilibiliIdentifier = BilibiliService.extractIdentifier(from: currentBrowserUrl)
                if rawTitle.isEmpty || rawTitle.contains("无标题") || rawTitle.lowercased().contains("untitled") {
                    displayTitle = "网页加载中..."
                    groupedTitle = "网页加载中..."
                } else {
                    var cleanedTitle = rawTitle
                    let bilibiliTitleParts = rawTitle.components(separatedBy: "_")
                    if bilibiliTitleParts.count > 1 {
                        cleanedTitle = bilibiliTitleParts[0] + " (Bilibili)"
                    } else if let firstTitlePart = rawTitle.components(separatedBy: " - ").first {
                        cleanedTitle = firstTitlePart + " (Bilibili)"
                    }
                    displayTitle = cleanedTitle
                    if let bilibiliIdentifier,
                       let mainTitle = ActivityTracker.bilibiliIdToMainTitleCache[bilibiliIdentifier] {
                        groupedTitle = mainTitle
                    } else if let bilibiliIdentifier {
                        ActivityTracker.bilibiliIdToMainTitleCache[bilibiliIdentifier] = cleanedTitle
                        ActivityTracker.trimCache(&ActivityTracker.bilibiliIdToMainTitleCache, limit: 128)
                        groupedTitle = cleanedTitle
                    } else {
                        groupedTitle = cleanedTitle
                    }
                }
            } else {
                let domainLabel = resolvedDomain.components(separatedBy: ".").first?.capitalized ?? resolvedDomain
                displayTitle = rawTitle.isEmpty ? "网页加载中..." : rawTitle
                groupedTitle = domainLabel
            }
        } else {
            let lowercasedRawTitle = rawTitle.lowercased()
            if lowercasedRawTitle.contains("无标题") || lowercasedRawTitle.contains("untitled") {
                displayTitle = "网页加载中..."
                groupedTitle = "网页加载中..."
                hasMatchedDomain = true
            } else {
                var found = false
                let allDomains = WhitelistManager.shared.whitelistedDomains + WhitelistManager.shared.blacklistedDomains
                for domain in allDomains {
                    let keyword = domain.components(separatedBy: ".").first ?? domain
                    if lowercasedRawTitle.contains(keyword) || (keyword == "bilibili" && lowercasedRawTitle.contains("哔哩哔哩")) {
                        displayTitle = rawTitle
                        groupedTitle = keyword.capitalized
                        targetMatchedDomain = domain
                        hasMatchedDomain = true
                        found = true
                        break
                    }
                }
                if !found {
                    displayTitle = rawTitle
                    groupedTitle = appName
                    targetMatchedDomain = nil
                    hasMatchedDomain = true
                }
            }
        }

        guard hasMatchedDomain else {
            clearTrackedState()
            return
        }

        ActivityTracker.titleCache[browserTitleCacheKey(originalTitle: rawTitle, domain: targetMatchedDomain)] = BrowserTitleData(
            displayTitle: displayTitle,
            groupedTitle: groupedTitle
        )
        ActivityTracker.trimCache(&ActivityTracker.titleCache, limit: 256)

        applySnapshot(
            TrackedSnapshot(
                processId: processId,
                appName: appName,
                bundleId: bundleId,
                rawTitle: rawTitle,
                displayTitle: displayTitle,
                groupedTitle: groupedTitle,
                domain: targetMatchedDomain,
                bilibiliIdentifier: bilibiliIdentifier,
                bilibiliTidV2: nil,
                fullUrl: browserUrl,
                pdfIdentifier: nil
            )
        )
    }

    private func scheduleBrowserURLRefresh(for refreshKey: BrowserURLRefreshKey) {
        guard !pendingBrowserURLRefreshKeys.contains(refreshKey) else { return }
        pendingBrowserURLRefreshKeys.insert(refreshKey)

        Task.detached(priority: .utility) {
            let browserUrl = BrowserService.fetchActiveURL(for: refreshKey.appName)

            await MainActor.run { [weak self] in
                guard let self else { return }

                self.pendingBrowserURLRefreshKeys.remove(refreshKey)
                guard let lastResolvedSnapshot = self.lastResolvedSnapshot,
                      lastResolvedSnapshot.processId == refreshKey.processId,
                      lastResolvedSnapshot.rawTitle == refreshKey.rawTitle else { return }

                // 用户已切走的旧标签页结果直接丢弃，避免异步结果字典在长期运行中不断增长。
                self.prefetchedBrowserURLResults[refreshKey] = BrowserURLRefreshResult(url: browserUrl)
                self.track(forceRefresh: true)
            }
        }
    }

    private func installActiveAppObserverIfNeeded(processId: pid_t) {
        guard observedProcessId != processId else { return }
        removeActiveAppObserver()

        var observer: AXObserver?
        let result = AXObserverCreate(processId, activityTrackerAXObserverCallback, &observer)
        guard result == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(processId)
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // 只监听会影响“当前统计对象”的通知：
        // - 焦点窗口变化用于同一 App 内切文档/窗口；
        // - 主窗口变化覆盖部分 App 不触发 focusedWindowChanged 的情况。
        AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification as CFString, context)
        AXObserverAddNotification(observer, appElement, kAXMainWindowChangedNotification as CFString, context)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observedProcessId = processId
        activeAppObserver = observer
    }

    private func observeTitleChangesIfNeeded(for windowElement: AXUIElement) {
        guard let activeAppObserver else { return }
        if let observedFocusedWindow,
           CFEqual(observedFocusedWindow, windowElement) {
            return
        }

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        if let observedFocusedWindow {
            AXObserverRemoveNotification(activeAppObserver, observedFocusedWindow, kAXTitleChangedNotification as CFString)
        }

        // 窗口标题经常在页面加载、PDF 翻页或编辑器切文档后才稳定，
        // 监听标题变化可以把轮询延迟压到系统通知触发时。
        AXObserverAddNotification(activeAppObserver, windowElement, kAXTitleChangedNotification as CFString, context)
        observedFocusedWindow = windowElement
    }

    private func removeActiveAppObserver() {
        if let activeAppObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(activeAppObserver), .commonModes)
        }
        observedProcessId = nil
        activeAppObserver = nil
        observedFocusedWindow = nil
    }

    fileprivate func handleAccessibilityEvent() {
        track(forceRefresh: true)
    }

    private func resolveBilibiliSnapshot(
        appName: String,
        bundleId: String,
        processId: pid_t,
        rawTitle: String,
        browserUrl: String
    ) {
        guard let bilibiliIdentifier = BilibiliService.extractIdentifier(from: browserUrl),
              bilibiliIdentifier.hasPrefix("BV") else {
            clearTrackedState()
            return
        }

        if let metadata = ActivityTracker.bilibiliMetadataCache[bilibiliIdentifier] {
            applySnapshot(
                TrackedSnapshot(
                    processId: processId,
                    appName: appName,
                    bundleId: bundleId,
                    rawTitle: rawTitle,
                    displayTitle: metadata.title,
                    // 知识类视频保留具体标题并按 BV 号累计；
                    // 娱乐类统一折叠成“娱乐”，后续统计页默认不把它算进学习向指标。
                    groupedTitle: metadata.isKnowledge ? metadata.title : AppConfig.bilibiliEntertainmentTitle,
                    domain: "bilibili.com",
                    bilibiliIdentifier: metadata.isKnowledge ? bilibiliIdentifier : nil,
                    bilibiliTidV2: metadata.tidV2,
                    fullUrl: nil,
                    pdfIdentifier: nil
                )
            )
            return
        }

        fetchBilibiliMetadataIfNeeded(for: bilibiliIdentifier)
        clearTrackedState()
    }

    private func fetchBilibiliMetadataIfNeeded(for bilibiliIdentifier: String) {
        guard !pendingBilibiliMetadataRequests.contains(bilibiliIdentifier) else { return }
        pendingBilibiliMetadataRequests.insert(bilibiliIdentifier)

        Task { [weak self] in
            let metadata = await BilibiliService.fetchMetadata(for: bilibiliIdentifier)
            await MainActor.run {
                guard let self else { return }
                self.pendingBilibiliMetadataRequests.remove(bilibiliIdentifier)
                if let metadata {
                    ActivityTracker.bilibiliMetadataCache[bilibiliIdentifier] = metadata
                    ActivityTracker.trimCache(&ActivityTracker.bilibiliMetadataCache, limit: 128)
                }
                self.track(forceRefresh: true)
            }
        }
    }

    private func normalizedPreviewPDFTitle(from title: String) -> String? {
        var cleanedTitle = title
        let components = cleanedTitle.components(separatedBy: " - ")
        if components.count > 1, let last = components.last, last.contains("页") || last.contains("Page") {
            cleanedTitle = Array(components.dropLast()).joined(separator: " - ")
        }
        guard let range = cleanedTitle.range(of: ".pdf", options: [.backwards, .caseInsensitive]) else {
            return nil
        }

        // 预览只在明确识别出 PDF 文件名时才参与统计，
        // 避免欢迎页、图片或其它非 PDF 文档被误算进学习时长。
        return String(cleanedTitle[..<range.upperBound])
    }

    /// 常驻菜单栏应用生命周期很长，浏览过的标题和视频数量理论上没有上限；限制缓存可防止内存缓慢增长。
    private static func trimCache<Key: Hashable, Value>(_ cache: inout [Key: Value], limit: Int) {
        guard cache.count > limit else { return }
        let overflow = cache.count - limit
        for key in cache.keys.prefix(overflow) {
            cache.removeValue(forKey: key)
        }
    }

    private func matchedWhitelistedDomainFromHost(_ host: String) -> String? {
        let allDomains = WhitelistManager.shared.whitelistedDomains + WhitelistManager.shared.blacklistedDomains
        return allDomains.first { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    /// 1. 判断是否属于正常的用户前台应用，过滤掉状态栏图标、后台常驻服务和系统级底层 UI。
    private func isUserFacingApp(_ activeApp: NSRunningApplication) -> Bool {
        // 1. 检查应用的激活策略：仅允许 regular（拥有常规 Dock 图标和主窗口）应用通过，
        // 从而直接把 accessory（仅状态栏图标的辅助软件）和 prohibited（后台服务）排除，防止系统后台进程干扰。
        guard activeApp.activationPolicy == .regular else {
            return false
        }

        // 2. 排除部分虽属于常规激活策略，但实为系统功能底座的内置 Bundle 标识。
        guard let bundleId = activeApp.bundleIdentifier else {
            return false
        }

        let excludedBundleIds: Set<String> = [
            "com.apple.finder",           // 访达（文件管理器）作为纯操作底座，不算做具体娱乐或学习时长
            "com.apple.dock",             // Dock 快捷栏
            "com.apple.loginwindow",      // 锁屏或登录窗口
            "com.apple.ScreenSaver.Engine", // 屏保程序
            "com.apple.controlcenter",    // 控制中心
            "com.apple.notificationcenterui", // 通知面板
            "com.apple.SystemUIServer",   // 系统菜单栏
            "com.apple.Siri",             // 语音助手界面
            "com.apple.accessibility.AccessibilityVisualsAgent", // 辅助功能弹窗
            "com.apple.Spotlight"         // Spotlight 聚焦搜索面板
        ]

        if excludedBundleIds.contains(bundleId) {
            return false
        }

        // 3. 根据 Bundle 所在的绝对路径剔除位于系统库文件、核心组件或守护进程目录下的进程。
        if let bundleURL = activeApp.bundleURL {
            let path = bundleURL.path
            let excludedPaths = [
                "/System/Library/CoreServices",
                "/System/Library/Frameworks",
                "/System/Library/PrivateFrameworks",
                "/usr/libexec"
            ]
            for excludedPath in excludedPaths {
                if path.hasPrefix(excludedPath) {
                    return false
                }
            }
        }

        return true
    }

    private func browserTitleCacheKey(originalTitle: String, domain: String?) -> String {
        "\(domain ?? "_no_domain_")|\(originalTitle)"
    }

    private func resetBrowserMetadata() {
        currentDomain = nil
        currentBilibiliId = nil
        currentBilibiliTidV2 = nil
        currentFullUrl = nil
        currentPdfIdentifier = nil
    }

    /// 3. 根据 PDF 文件 URL 计算一个唯一的 Inode 和快速内容哈希值特征指纹，确保文件重命名后依然能够合并统计
    private func generatePDFIdentifier(for url: URL?) -> String? {
        guard let url else { return nil }
        
        // 1. 获取文件 Inode 唯一标识符（同磁盘分区重命名时此标识符不变）
        var inodeString = ""
        if let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
           let fileID = values.fileResourceIdentifier {
            inodeString = "\(fileID)"
        }
        
        // 2. 计算快速内容指纹 (文件大小 + 头部 64KB 哈希 + 尾部 64KB 哈希，确保文件复制/跨设备传输后能正确辨识)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? UInt64,
              let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return inodeString.isEmpty ? nil : inodeString
        }
        
        defer { try? fileHandle.close() }
        
        let chunkSize = min(Int(fileSize), 64 * 1024)
        guard let firstChunk = try? fileHandle.read(upToCount: chunkSize) else {
            return inodeString.isEmpty ? nil : inodeString
        }
        let firstHash = SHA256.hash(data: firstChunk).description.prefix(12)
        
        if fileSize > UInt64(chunkSize) {
            try? fileHandle.seek(toOffset: fileSize - UInt64(chunkSize))
        } else {
            try? fileHandle.seek(toOffset: 0)
        }
        guard let lastChunk = try? fileHandle.read(upToCount: chunkSize) else {
            return inodeString.isEmpty ? nil : inodeString
        }
        let lastHash = SHA256.hash(data: lastChunk).description.prefix(12)
        
        return "pdf_\(fileSize)_\(firstHash)_\(lastHash)"
    }

    private func clearTrackedState() {
        currentAppName = ""
        currentWindowTitle = ""
        currentGroupedTitle = ""
        resetBrowserMetadata()
        lastResolvedSnapshot = nil
        publishActivityChangeIfNeeded()
    }

    private func applySnapshot(_ snapshot: TrackedSnapshot) {
        currentAppName = snapshot.appName
        currentWindowTitle = snapshot.displayTitle
        currentGroupedTitle = snapshot.groupedTitle
        currentDomain = snapshot.domain
        currentBilibiliId = snapshot.bilibiliIdentifier
        currentBilibiliTidV2 = snapshot.bilibiliTidV2
        currentFullUrl = snapshot.fullUrl
        currentPdfIdentifier = snapshot.pdfIdentifier
        lastResolvedSnapshot = snapshot
        publishActivityChangeIfNeeded()
    }

    private func publishActivityChangeIfNeeded() {
        let currentActivity = PublishedActivityState(
            appName: currentAppName,
            groupedTitle: currentGroupedTitle,
            domain: currentDomain,
            bilibiliIdentifier: currentBilibiliId,
            fullUrl: currentFullUrl,
            pdfIdentifier: currentPdfIdentifier
        )
        guard currentActivity != lastPublishedActivity else { return }
        lastPublishedActivity = currentActivity
        activityDidChange?()
    }
}

private let activityTrackerAXObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<ActivityTracker>.fromOpaque(refcon).takeUnretainedValue()
    Task { @MainActor in
        tracker.handleAccessibilityEvent()
    }
}

private struct TrackedSnapshot {
    let processId: pid_t
    let appName: String
    let bundleId: String
    let rawTitle: String
    let displayTitle: String
    let groupedTitle: String
    let domain: String?
    let bilibiliIdentifier: String?
    let bilibiliTidV2: Int?
    let fullUrl: String?
    let pdfIdentifier: String?
}

private struct BrowserURLRefreshKey: Hashable, Sendable {
    let processId: pid_t
    let appName: String
    let rawTitle: String
}

private struct BrowserURLRefreshResult: Sendable {
    let url: String?
}

private struct PublishedActivityState: Equatable {
    let appName: String
    let groupedTitle: String
    let domain: String?
    let bilibiliIdentifier: String?
    let fullUrl: String?
    let pdfIdentifier: String?
}
