import SwiftUI
import SwiftData
import Foundation
import AppKit

@main
struct GrandleTickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let container: ModelContainer
    @State private var usageManager: UsageManager

    init() {
        // 1. 准备应用支持目录，用于存放 SQLite 数据库。
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let applicationDirectoryURL = applicationSupportDirectoryURL.appendingPathComponent("GrandleTick", isDirectory: true)

        if !FileManager.default.fileExists(atPath: applicationDirectoryURL.path) {
            try? FileManager.default.createDirectory(at: applicationDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // 2. 初始化 SwiftData 容器并执行必要的数据库维护（索引安装、迁移、压缩）。
        let databaseFileURL = applicationDirectoryURL.appendingPathComponent("ActivityData.sqlite")
        let configuration = ModelConfiguration(url: databaseFileURL)

        do {
            container = try ModelContainer(for: ActivityLog.self, configurations: configuration)
            ActivityLogIndexInstaller.installIfNeeded(databaseURL: databaseFileURL)

            let context = container.mainContext
            LegacyStoreMigrator.migrateIfNeeded(context: context, appDirectoryURL: applicationDirectoryURL)
            ActivityLogCompactor.compactIfNeeded(context: context, appDirectoryURL: applicationDirectoryURL)
            
            // 3. 初始化核心管理器并将上下文注入到 AppDelegate。
            let manager = UsageManager(modelContext: context)
            _usageManager = State(initialValue: manager)
            appDelegate.configure(usageManager: manager, modelContext: context)

            // 4. 历史统计缓存改为打开数据中心时按需建立。常驻菜单栏阶段不扫描全部历史数据库，
            // 让没有查看报表的绝大多数时间保持接近零后台开销。
        } catch {
            fatalError("无法初始化数据库容器: \(error)")
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .modelContainer(container)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var usageManager: UsageManager?
    private var modelContext: ModelContext?
    private var statusBarController: StatusBarController?
    private var breakReminderManager: BreakReminderManager?
    private var breakReminderPanelCoordinator: BreakReminderPanelCoordinator?

    func configure(usageManager: UsageManager, modelContext: ModelContext) {
        self.usageManager = usageManager
        self.modelContext = modelContext
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let usageManager, let modelContext else { return }
        // 1. 显式加载编译后的 icns，避免菜单栏应用动态切换到 Dock 时沿用系统占位图。
        if let iconURL = Bundle.main.url(forResource: "DockIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // 2. 启动时保持菜单栏模式；打开独立功能窗口后再临时显示 Dock 图标。
        NSApp.setActivationPolicy(.accessory)
        let breakReminderManager = BreakReminderManager()
        let breakReminderPanelCoordinator = BreakReminderPanelCoordinator(
            reminderManager: breakReminderManager
        )
        self.breakReminderManager = breakReminderManager
        self.breakReminderPanelCoordinator = breakReminderPanelCoordinator

        statusBarController = StatusBarController(
            usageManager: usageManager,
            modelContext: modelContext,
            breakReminderManager: breakReminderManager
        )

        // 3. 界面和提醒回调全部就绪后再恢复计时，防止过期提醒在协调器创建前被丢失。
        breakReminderManager.restorePersistedReminder()

        // 4. 自动化性能检查可通过启动参数直接打开数据中心，避免测试依赖菜单栏坐标；正常启动路径不受影响。
        if CommandLine.arguments.contains("--open-statistics") {
            DispatchQueue.main.async {
                FeatureWindowCoordinator.shared.openStatisticsWindow(modelContext: modelContext)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        usageManager?.flushPendingSession()
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let usageManager: UsageManager
    private let modelContext: ModelContext
    private let breakReminderManager: BreakReminderManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var pendingPopoverPresentation: DispatchWorkItem?

    init(
        usageManager: UsageManager,
        modelContext: ModelContext,
        breakReminderManager: BreakReminderManager
    ) {
        self.usageManager = usageManager
        self.modelContext = modelContext
        self.breakReminderManager = breakReminderManager
        super.init()
        configureStatusItem()
        configurePopover()
        installPopoverCloseHandlers()
        bindUsageManager()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.image = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: "GrandleTick")
        button.imagePosition = .imageLeft
        button.lineBreakMode = .byTruncatingTail
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: AppConfig.popoverWidth, height: AppConfig.popoverHeight)
        popover.contentViewController = NSHostingController(
            rootView: ContentView(
                usageManager: usageManager,
                breakReminderManager: breakReminderManager,
                onBreakTimerExpansionChanged: { [weak self] isExpanded in
                    self?.updatePopoverHeight(isBreakTimerExpanded: isExpanded)
                }
            )
                .modelContext(modelContext)
        )
    }

    private func updatePopoverHeight(isBreakTimerExpanded: Bool) {
        // 休息功能默认不占菜单主体空间；仅在用户主动展开时临时增高弹层。
        let height = isBreakTimerExpanded
            ? AppConfig.expandedPopoverHeight
            : AppConfig.popoverHeight
        popover.contentSize = NSSize(width: AppConfig.popoverWidth, height: height)
    }

    private func installPopoverCloseHandlers() {
        // 1. 监听应用失去焦点，自动关闭弹出框。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        // 2. 独立功能窗口打开前主动收起菜单栏弹层，避免弹层覆盖新窗口内容。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFeatureWindowWillOpen),
            name: .featureWindowWillOpen,
            object: nil
        )

        // 3. 到点提醒显示前收起菜单弹层，避免两个右上角窗口互相遮挡。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBreakReminderWillPresent),
            name: .breakReminderWillPresent,
            object: nil
        )

        // 4. 安装本地事件监听，处理弹出框外的点击。
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.closePopoverIfNeeded(for: event)
            return event
        }

        // 5. 安装全局事件监听，确保在其它应用点击时也能关闭。
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func bindUsageManager() {
        usageManager.menuBarTitleDidChange = { [weak self] title in
            self?.applyStatusItemTitle(title)
        }
        applyStatusItemTitle(usageManager.formattedMenuDuration)
    }

    private func applyStatusItemTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.title = title
    }

    @objc
    private func handleApplicationDidResignActive() {
        closePopover()
    }

    @objc
    private func handleFeatureWindowWillOpen() {
        closePopover()
    }

    @objc
    private func handleBreakReminderWillPresent() {
        closePopover()
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        // 1. 如果弹层仍在等待下一轮主线程展示，再次点击应取消本次打开，保持菜单栏按钮的开关语义。
        if let pendingPopoverPresentation {
            pendingPopoverPresentation.cancel()
            self.pendingPopoverPresentation = nil
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            // 2. 保留打开菜单时立即刷新权限与前台窗口的行为，避免系统设置授权后继续显示旧状态。
            // 用户通常会在系统设置授权后立即点击菜单栏图标返回；
            // 展示弹层前强制刷新权限，避免界面继续使用最长 60 秒的旧缓存。
            usageManager.tracker.refreshAccessibilityTrust()

            // 3. Observation 的状态写入是同步的，但 SwiftUI 视图重算发生在下一轮主线程。
            // 延后到下一轮再展示，可避免弹层先绘制上一次的学习/休闲界面，再跳到刷新后的正确界面。
            let presentation = DispatchWorkItem { [weak self, weak button] in
                guard let self, let button else { return }
                self.pendingPopoverPresentation = nil
                guard !self.popover.isShown else { return }

                self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                self.popover.contentViewController?.view.window?.animationBehavior = .none
            }
            pendingPopoverPresentation = presentation
            DispatchQueue.main.async(execute: presentation)
        }
    }

    private func closePopoverIfNeeded(for event: NSEvent) {
        guard popover.isShown else { return }
        guard let popoverWindow = popover.contentViewController?.view.window else { return }

        if event.window !== popoverWindow {
            popover.performClose(nil)
        }
    }

    private func closePopover() {
        pendingPopoverPresentation?.cancel()
        pendingPopoverPresentation = nil
        guard popover.isShown else { return }
        popover.performClose(nil)
    }
}
