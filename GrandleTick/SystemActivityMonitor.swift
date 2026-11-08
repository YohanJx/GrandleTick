import AppKit
import CoreGraphics

/// 独立保存各类暂停原因，避免亮屏先于解锁、后台唤醒等事件顺序提前恢复统计。
@MainActor
final class SystemActivityMonitor {
    enum PauseReason: Hashable {
        case displaySleeping, systemSleeping, screenLocked, sessionInactive
    }

    private(set) var pauseReasons: Set<PauseReason>
    var availabilityDidChange: ((Bool) -> Void)?
    var isAvailable: Bool { pauseReasons.isEmpty }
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var lockObservers: [NSObjectProtocol] = []

    init() {
        // 1. 启动时先读取已有状态，防止应用在熄屏或锁屏期间重启后漏等一次通知。
        var reasons: Set<PauseReason> = []
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
           count > 0,
           displays.prefix(Int(count)).allSatisfy({ CGDisplayIsAsleep($0) != 0 }) {
            reasons.insert(.displaySleeping)
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true {
            reasons.insert(.screenLocked)
        }
        if session?[kCGSessionOnConsoleKey as String] as? Bool != true {
            reasons.insert(.sessionInactive)
        }
        pauseReasons = reasons

        // 2. 显示器熄灭与整机睡眠分别监听；插电时往往只发生前者。
        let workspaceEvents: [(Notification.Name, PauseReason, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .displaySleeping, true),
            (NSWorkspace.screensDidWakeNotification, .displaySleeping, false),
            (NSWorkspace.willSleepNotification, .systemSleeping, true),
            (NSWorkspace.didWakeNotification, .systemSleeping, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false)
        ]
        for (name, reason, paused) in workspaceEvents {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                // willSleep 必须在通知返回前同步落库，不能另开 Task 等待主线程再次调度。
                MainActor.assumeIsolated {
                    self?.setPaused(paused, reason: reason)
                }
            })
        }

        // 3. 锁屏不一定熄屏，也不一定切换前台应用，单独接收系统锁定状态通知。
        for (name, paused) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.setPaused(paused, reason: .screenLocked)
                }
            })
        }
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in lockObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func setPaused(_ paused: Bool, reason: PauseReason) {
        // 1. 只增删当前原因，重复通知不重复结算，单个恢复通知也不能清除其它暂停原因。
        let wasAvailable = isAvailable
        if paused {
            pauseReasons.insert(reason)
        } else {
            pauseReasons.remove(reason)
        }

        // 2. 所有原因解除后才重新识别窗口，恢复时从新事件时刻计时，不补算暂停区间。
        if wasAvailable != isAvailable {
            availabilityDidChange?(isAvailable)
        }
    }
}
