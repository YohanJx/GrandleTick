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
    /// 当系统已处于可交互状态但收到后续亮屏、解锁或遮罩关闭通知时触发，用于补偿窗口焦点恢复滞后。
    var recoveryEventDidFire: (() -> Void)?
    var isAvailable: Bool { pauseReasons.isEmpty }
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var lockObservers: [NSObjectProtocol] = []

    init() {
        // 1. 启动时先读取已有状态，防止应用在熄屏或锁屏期间重启后漏等一次通知。
        var reasons: Set<PauseReason> = []
        if Self.areAllDisplaysAsleep() {
            reasons.insert(.displaySleeping)
        }
        if Self.isSessionLocked() {
            reasons.insert(.screenLocked)
        }
        if !Self.isSessionOnConsole() {
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
                    self?.handleWorkspaceNotification(reason: reason, paused: paused)
                }
            })
        }

        // 3. 锁屏不一定熄屏，也不一定切换前台应用，单独接收系统锁定状态通知。
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleLockNotification(locked: locked)
                }
            })
        }

        // 4. 监听解锁遮罩窗口彻底关闭事件。loginwindow 在发出 screenIsUnlocked 后仍需数十至数百毫秒
        // 关闭锁屏遮罩并执行 CPSBringNextToFront 交还焦点，在遮罩关闭时再次触发恢复可及时拿到用户窗口。
        for name in ["com.apple.screenLockUIIsHidden", "com.apple.shieldWindowLowered"] {
            lockObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isAvailable else { return }
                    self.recoveryEventDidFire?()
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

    private func handleWorkspaceNotification(reason: PauseReason, paused: Bool) {
        // 1. 进入暂停状态时直接记录对应原因。
        guard !paused else {
            setPaused(true, reason: reason)
            return
        }

        // 2. 收到系统唤醒类通知时，清理当前已解除的暂停原因。
        // 若系统刚发出 willSleep 但数秒内被用户亮屏打断，powerd 可能延迟二十余秒才补发 didWake；
        // 此时显示器已经亮起（screensDidWake），整机必然未处于睡眠态，需同步清除残留的 systemSleeping。
        let wasAvailable = isAvailable
        pauseReasons.remove(reason)
        switch reason {
        case .displaySleeping:
            pauseReasons.remove(.systemSleeping)
        case .systemSleeping, .sessionInactive:
            if !Self.areAllDisplaysAsleep() {
                pauseReasons.remove(.displaySleeping)
                pauseReasons.remove(.systemSleeping)
            }
        case .screenLocked:
            break
        }

        // 3. 可用性首次恢复时走状态切换回调；若原本已可用但收到后续唤醒事件，则触发二次恢复补偿。
        if wasAvailable != isAvailable {
            availabilityDidChange?(isAvailable)
        } else if isAvailable {
            recoveryEventDidFire?()
        }
    }

    private func handleLockNotification(locked: Bool) {
        // 1. 收到锁屏通知时立即进入暂停。
        guard !locked else {
            setPaused(true, reason: .screenLocked)
            return
        }

        // 2. 用户完成解锁时，除了移除 screenLocked，若当前显示器已点亮，也一并清除可能因睡眠中断而残留的睡眠标记。
        let wasAvailable = isAvailable
        pauseReasons.remove(.screenLocked)
        if !Self.areAllDisplaysAsleep() {
            pauseReasons.remove(.displaySleeping)
            pauseReasons.remove(.systemSleeping)
        }

        // 3. 通知上层恢复识别窗口；若已处于可用态则触发焦点重采样。
        if wasAvailable != isAvailable {
            availabilityDidChange?(isAvailable)
        } else if isAvailable {
            recoveryEventDidFire?()
        }
    }

    static func areAllDisplaysAsleep() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
              count > 0 else {
            return false
        }
        return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
    }

    static func isSessionLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    static func isSessionOnConsole() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?[kCGSessionOnConsoleKey as String] as? Bool == true
    }
}
