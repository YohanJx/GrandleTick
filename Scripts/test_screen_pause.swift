import AppKit
import SwiftData

// 与 GrandleTick 中除应用入口外的 Swift 源文件一起编译，使用内存数据库，避免改动真实历史。
@main
struct ScreenPauseRegressionTests {
    @MainActor
    static func main() throws {
        // 1. 验证交错和重复通知：系统唤醒、亮屏均不能覆盖尚未解除的锁屏原因。
        let monitor = SystemActivityMonitor()
        for reason in monitor.pauseReasons {
            monitor.setPaused(false, reason: reason)
        }
        var transitions: [Bool] = []
        monitor.availabilityDidChange = { transitions.append($0) }
        monitor.setPaused(true, reason: .displaySleeping)
        monitor.setPaused(true, reason: .displaySleeping)
        monitor.setPaused(true, reason: .screenLocked)
        monitor.setPaused(true, reason: .systemSleeping)
        monitor.setPaused(false, reason: .systemSleeping)
        monitor.setPaused(false, reason: .displaySleeping)
        precondition(!monitor.isAvailable && transitions == [false])
        monitor.setPaused(false, reason: .screenLocked)
        precondition(monitor.isAvailable && transitions == [false, true])

        // 2. 在内存中启动真实会话，熄屏通知必须同步保存旧会话并立即清空展示。
        let container = try ModelContainer(
            for: ActivityLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let manager = UsageManager(modelContext: container.mainContext)
        publishTestActivity(manager)
        pumpRunLoop(for: AppConfig.activityTransitionDebounceInterval + 0.3)
        precondition(manager.currentWindowTodayDuration > 0)
        let sleepAt = Date()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        precondition(manager.tracker.currentAppName.isEmpty)
        precondition(manager.currentWindowTodayDuration == 0)
        let logsAtSleep = try testLogs(container.mainContext)
        precondition(logsAtSleep.count == 1)
        precondition(logsAtSleep[0].startTime.addingTimeInterval(logsAtSleep[0].duration) <= sleepAt.addingTimeInterval(0.1))
        let savedDuration = logsAtSleep[0].duration

        // 3. 暂停中强制刷新和显示心跳不能重启计时；恢复后必须另开会话，不能补算暂停时间。
        manager.tracker.track(forceRefresh: true)
        publishTestActivity(manager)
        precondition(manager.tracker.currentAppName.isEmpty)
        pumpRunLoop(for: 1.2)
        manager.flushPendingSession()
        precondition(manager.currentWindowTodayDuration == 0)
        let pausedLogs = try testLogs(container.mainContext)
        precondition(pausedLogs[0].duration == savedDuration)
        let wakeAt = Date()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        publishTestActivity(manager)
        pumpRunLoop(for: AppConfig.activityTransitionDebounceInterval + 0.3)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        let resumedLogs = try testLogs(container.mainContext)
        precondition(resumedLogs.count == 2)
        precondition(resumedLogs[1].startTime >= wakeAt)
        precondition(resumedLogs[0].duration == savedDuration)

        // 4. 还在等待防抖确认的候选活动也必须取消，避免熄屏后延迟启动一个新会话。
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        publishTestActivity(manager)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        pumpRunLoop(for: AppConfig.activityTransitionDebounceInterval + 0.3)
        manager.flushPendingSession()
        let finalLogs = try testLogs(container.mainContext)
        precondition(finalLogs.count == 2)

        // 5. 验证统一分类器 ActivityClassifier 与 WhitelistCacheKey 黑白名单缓存键失效行为。
        verifyActivityClassifierAndCacheKey()

        // 6. 验证 UsageManager 今日分类时长在黑名单变更后自动失效重算，以及拆分后的统计存储与引擎聚合正常。
        try verifyUsageCategoryCacheAndStatisticsModules()

        // 7. 验证睡眠被亮屏打断（willSleep 后直接收到 screensDidWake）以及解锁后焦点延迟归还时的自动重试恢复计时。
        try verifyDelayedWakeRecoveryAndAbortedSleep(manager: manager, context: container.mainContext)
        print("PASS: 交错暂停原因、同步结算、暂停期间不累计、恢复不补算、候选会话取消、延迟焦点恢复、统一分类器、名单缓存失效与统计引擎聚合")
    }

    @MainActor
    private static func verifyDelayedWakeRecoveryAndAbortedSleep(
        manager: UsageManager,
        context: ModelContext
    ) throws {
        // 1. 模拟系统进入睡眠准备（willSleep）与熄屏（screensDidSleep），随后用户直接唤醒屏幕（screensDidWake），
        // 且 powerd 尚未补发 didWake。此时亮屏通知必须同步清除残留的 systemSleeping。
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        var probeAttempts = 0
        manager.tracker.testWakeRecoveryHandler = {
            probeAttempts += 1
            // 第 1 次为 T+0ms 同步检测（模拟 loginwindow 尚未完成 CPSBringNextToFront 焦点归还，窗口未就绪）；
            // 第 2 次为 150ms 后的自动恢复重采样（模拟焦点已归还但系统未发 didActivateApplicationNotification）。
            if probeAttempts >= 2 {
                publishTestActivity(manager)
            }
        }
        defer {
            manager.tracker.testWakeRecoveryHandler = nil
        }

        // 2. 触发亮屏通知：T+0ms 时窗口尚未就绪，等待自动恢复任务在 150ms 后重采样并启动会话。
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        pumpRunLoop(for: 0.25)
        precondition(probeAttempts == 2)
        precondition(manager.tracker.currentAppName == "ScreenPauseRegressionTest")

        // 3. 继续等待防抖确认完成并产生计时，验证无需人工点击即可自动恢复会话且不会重复触发多余探针。
        pumpRunLoop(for: AppConfig.activityTransitionDebounceInterval + 0.35)
        precondition( probeAttempts == 2 )
        precondition(manager.currentWindowTodayDuration > 0)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        let logsAfterDelayedWake = try testLogs(context)
        precondition(logsAfterDelayedWake.count == 3)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    @MainActor
    private static func verifyActivityClassifierAndCacheKey() {
        let whitelist = WhitelistManager.shared
        let savedWhiteApps = whitelist.whitelistedApps
        let savedWhiteDomains = whitelist.whitelistedDomains
        let savedBlackApps = whitelist.blacklistedApps
        let savedBlackDomains = whitelist.blacklistedDomains
        defer {
            whitelist.whitelistedApps = savedWhiteApps
            whitelist.whitelistedDomains = savedWhiteDomains
            whitelist.blacklistedApps = savedBlackApps
            whitelist.blacklistedDomains = savedBlackDomains
        }

        // 1. 黑名单变更必须使 WhitelistCacheKey 变化，防止今日学习/休闲汇总沿用旧缓存。
        let initialKey = WhitelistCacheKey(whitelist: whitelist)
        whitelist.blacklistedApps.append("__test_blacklist_app__")
        let keyAfterBlackApp = WhitelistCacheKey(whitelist: whitelist)
        precondition(initialKey != keyAfterBlackApp)
        whitelist.blacklistedDomains.append("example-entertainment.com")
        let keyAfterBlackDomain = WhitelistCacheKey(whitelist: whitelist)
        precondition(keyAfterBlackApp != keyAfterBlackDomain)

        // 2. 验证 B 站仅在存在 bilibiliIdentifier 时判定为学习，预览仅在查看 .pdf 时判定为学习。
        let snapshot = WhitelistSnapshot(whitelist: whitelist)
        precondition(
            ActivityClassifier.isStudy(
                appName: "Safari",
                windowTitle: "线性代数",
                domain: "bilibili.com",
                bilibiliIdentifier: "BV1xx411c7mD",
                whitelist: snapshot
            )
        )
        precondition(
            !ActivityClassifier.isStudy(
                appName: "Safari",
                windowTitle: "Bilibili",
                domain: "bilibili.com",
                bilibiliIdentifier: nil,
                whitelist: snapshot
            )
        )
        precondition(
            ActivityClassifier.isStudy(
                appName: "预览",
                windowTitle: "量子力学.pdf",
                domain: nil,
                bilibiliIdentifier: nil,
                whitelist: snapshot
            )
        )
        precondition(
            !ActivityClassifier.isStudy(
                appName: "预览",
                windowTitle: "截图.png",
                domain: nil,
                bilibiliIdentifier: nil,
                whitelist: snapshot
            )
        )
        precondition(
            !ActivityClassifier.isStudy(
                appName: "__test_blacklist_app__",
                windowTitle: "测试窗口",
                domain: nil,
                bilibiliIdentifier: nil,
                whitelist: snapshot
            )
        )
    }

    @MainActor
    private static func verifyUsageCategoryCacheAndStatisticsModules() throws {
        let whitelist = WhitelistManager.shared
        let savedWhiteApps = whitelist.whitelistedApps
        let savedWhiteDomains = whitelist.whitelistedDomains
        let savedBlackApps = whitelist.blacklistedApps
        let savedBlackDomains = whitelist.blacklistedDomains
        defer {
            whitelist.whitelistedApps = savedWhiteApps
            whitelist.whitelistedDomains = savedWhiteDomains
            whitelist.blacklistedApps = savedBlackApps
            whitelist.blacklistedDomains = savedBlackDomains
        }

        // 1. 验证 UsageManager 在应用从白名单移入黑名单后，今日分类累计时长能立即失效重算而不沿用旧缓存。
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("GrandleTickVerify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sqliteURL = tempDir.appendingPathComponent("VerifyActivityData.sqlite")
        let container = try ModelContainer(
            for: ActivityLog.self,
            configurations: ModelConfiguration(url: sqliteURL)
        )
        ActivityLogIndexInstaller.installIfNeeded(databaseURL: sqliteURL)
        let context = container.mainContext

        let now = Date()
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!

        // 插入一条今日已落库日志与一条昨日已结束自然日日志。
        context.insert(ActivityLog(
            appName: "TestStudyApp",
            windowTitle: "章节一",
            startTime: todayStart.addingTimeInterval(60),
            duration: 300
        ))
        context.insert(ActivityLog(
            appName: "预览",
            windowTitle: "高等数学.pdf",
            startTime: yesterdayStart.addingTimeInterval(3600),
            duration: 600,
            pdfIdentifier: "pdf_1024_abc_def"
        ))
        try context.save()

        whitelist.whitelistedApps = ["TestStudyApp", "预览"]
        whitelist.blacklistedApps = []

        let manager = UsageManager(modelContext: context)
        manager.tracker.applySnapshot(TrackedSnapshot(
            processId: 0,
            appName: "TestStudyApp",
            bundleId: "test.study",
            rawTitle: "章节二",
            displayTitle: "章节二",
            groupedTitle: "TestStudyApp",
            domain: nil,
            bilibiliIdentifier: nil,
            bilibiliTidV2: nil,
            fullUrl: nil,
            pdfIdentifier: nil
        ))
        precondition(manager.isCurrentSessionStudy)
        // 切入学习应用时，弹窗分类累计基准应包含今天已落库的 300 秒学习时长。
        precondition(manager.currentCategoryTodayDuration >= 300)

        // 将 TestStudyApp 加入黑名单后再次切入，缓存必须失效并转为休闲分类（不再把 300 秒计入学习）。
        whitelist.addBlacklistApp("TestStudyApp")
        manager.tracker.applySnapshot(TrackedSnapshot(
            processId: 0,
            appName: "OtherApp",
            bundleId: "test.other",
            rawTitle: "其他",
            displayTitle: "其他",
            groupedTitle: "OtherApp",
            domain: nil,
            bilibiliIdentifier: nil,
            bilibiliTidV2: nil,
            fullUrl: nil,
            pdfIdentifier: nil
        ))
        precondition(!manager.isCurrentSessionStudy)
        precondition(manager.currentCategoryTodayDuration >= 300)

        // 2. 验证拆分后的 ActivityLogSnapshotStore、ActivityAggregateCacheStore 与 StatisticsEngine 聚合计算。
        let snapshotWhitelist = WhitelistSnapshot(whitelist: whitelist)
        let preparedLogs = ActivityAggregateCacheStore.fetchPreparedLogs(
            databaseURL: sqliteURL,
            interval: DateInterval(start: yesterdayStart, end: now.addingTimeInterval(10)),
            whitelist: snapshotWhitelist,
            calendar: calendar
        ).filter { $0.appName == "TestStudyApp" || $0.appName == "预览" }
        precondition(preparedLogs.count == 2)
        precondition(preparedLogs.contains { $0.isPDF && $0.isStudy && $0.duration == 600 })
        precondition(preparedLogs.contains { $0.appName == "TestStudyApp" && !$0.isStudy && $0.duration == 300 })

        let engine = StatisticsEngine()
        engine.baseRangeLogs = preparedLogs
        engine.applyFilters(
            searchText: "",
            contentFilter: .all,
            appFilter: nil,
            domainFilter: nil,
            dimension: .app,
            range: .all
        )
        pumpRunLoop(for: 0.25)
        precondition(engine.studyDuration == 600)
        precondition(engine.entertainmentDuration == 300)
        precondition(engine.pdfDuration == 600)
        precondition(engine.activeDays == 1)
    }

    @MainActor
    private static func publishTestActivity(_ manager: UsageManager) {
        manager.tracker.applySnapshot(TrackedSnapshot(
            processId: 0, appName: "ScreenPauseRegressionTest", bundleId: "test.screen-pause",
            rawTitle: "test", displayTitle: "test", groupedTitle: "test", domain: nil,
            bilibiliIdentifier: nil, bilibiliTidV2: nil, fullUrl: nil, pdfIdentifier: nil
        ))
    }

    @MainActor
    private static func testLogs(_ context: ModelContext) throws -> [ActivityLog] {
        let name = "ScreenPauseRegressionTest"
        return try context.fetch(FetchDescriptor<ActivityLog>(
            predicate: #Predicate { $0.appName == name },
            sortBy: [SortDescriptor(\.startTime)]
        ))
    }

    private static func pumpRunLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
}
