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
        print("PASS: 交错暂停原因、同步结算、暂停期间不累计、恢复不补算、候选会话取消")
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
