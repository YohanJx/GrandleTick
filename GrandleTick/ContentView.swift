import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var usageManager: UsageManager
    var breakReminderManager: BreakReminderManager
    var onBreakTimerExpansionChanged: (Bool) -> Void

    @State private var contentVisible = false
    @State private var isBreakTimerExpanded = false
    
    private let requiredConfirmText = "我已知晓"
    
    private var isUntracked: Bool {
        usageManager.tracker.currentAppName.isEmpty
    }
    
    /// 区分当前正在活跃的窗口是属于“学习专注”还是“娱乐休闲”
    private var isStudyActive: Bool {
        guard !isUntracked else { return false }
        
        let appName = usageManager.tracker.currentAppName
        let windowTitle = usageManager.tracker.currentWindowTitle
        let domain = usageManager.tracker.currentDomain
        
        let lowercasedAppName = appName.lowercased()
        let isWebsite = BrowserService.isWebsiteActivity(appName: appName, domain: domain)
        
        // 1. 黑名单优先校验：命中黑名单的应用或域名直接判定为娱乐休闲状态。
        let isBlacklistedApp = WhitelistManager.shared.blacklistedApps.contains { app in
            let lower = app.lowercased()
            return lower == lowercasedAppName || lower.contains(lowercasedAppName) || lowercasedAppName.contains(lower)
        }
        if isBlacklistedApp {
            return false
        }
        if isWebsite, let domain {
            let isBlacklistedDomain = WhitelistManager.shared.blacklistedDomains.contains {
                $0.lowercased() == domain.lowercased()
            }
            if isBlacklistedDomain {
                return false
            }
        }

        // 2. 如果是浏览器，需要进一步校验域名是否在白名单内，并对 B 站做特殊处理。
        if isWebsite {
            guard let domain else { return false }
            let isWhitelistedDomain = WhitelistManager.shared.whitelistedDomains.contains { $0.lowercased() == domain.lowercased() }
            
            // B 站视频必须以 bilibiliIdentifier 非空为唯一判断依据：
            // - bilibiliIdentifier 只有在 API 确认为知识区（tidV2 在白名单中）时才会被赋值。
            // - 当 URL 获取失败走窗口标题兜底路径时，identifier 为 nil，
            //   此时 groupedTitle 可能是 "Bilibili" 而非 "娱乐"，不能用 groupedTitle 做判断，
            //   必须直接以 identifier 为准，否则所有 B 站内容都会被误归为学习。
            if domain == "bilibili.com" {
                return usageManager.tracker.currentBilibiliId != nil
            }
            
            return isWhitelistedDomain
        } 
        
        // 3. 如果是 macOS 预览 App，需要明确判断是否正在查看 PDF 文件以归为学习。
        if lowercasedAppName.contains("预览") || lowercasedAppName.contains("preview") {
            return windowTitle.lowercased().contains(".pdf")
        } 
        
        // 4. 其他常规应用直接根据应用名称是否在白名单中来判断是否属于专注学习。
        return WhitelistManager.shared.whitelistedApps.contains { app in
            let lowercasedApp = app.lowercased()
            return lowercasedApp == lowercasedAppName || lowercasedApp.contains(lowercasedAppName) || lowercasedAppName.contains(lowercasedApp)
        }
    }
    
    private var currentTitle: String {
        isUntracked ? "未统计的窗口" : usageManager.tracker.currentWindowTitle
    }
    
    private var currentSourceName: String {
        isUntracked ? "其他应用（不在白名单）" : usageManager.tracker.currentAppName
    }
    
    private var durationHeadline: String {
        if isUntracked {
            return "未在统计范围内"
        }
        return isStudyActive ? "今日学习总时长" : "今日休闲总时长"
    }
    
    private var durationSubtitle: String {
        if isUntracked {
            return "切换到白名单内的应用或网站后会继续累计"
        }
        return isStudyActive ? "今日学习累计" : "今日休闲累计"
    }

    private var activityTint: Color {
        isUntracked ? .gray : (isStudyActive ? AppDesign.primaryBlue : AppDesign.leisurePurple)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            if usageManager.tracker.currentWindowTitle == "需开启辅助功能权限" {
                Button(action: {
                    let accessibilitySettingsAddress = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                    NSWorkspace.shared.open(accessibilitySettingsAddress)
                }) {
                    HStack {
                        Image(systemName: "exclamationmark.shield.fill")
                        Text("前往开启辅助功能权限")
                            .font(.caption).bold()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            
            VStack(alignment: .center, spacing: 12) {
                StatusPill(
                    text: isUntracked ? "已暂停统计" : (isStudyActive ? "学习中" : "休闲中"),
                    tint: activityTint,
                    systemImage: isUntracked ? "pause.circle.fill" : (isStudyActive ? "book.closed.fill" : "gamecontroller.fill")
                )

                VStack(spacing: 6) {
                    Text(currentTitle)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(currentSourceName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.center)

                    if let durationLabel = usageManager.currentContentDurationLabel {
                        HStack(spacing: 8) {
                            Text(durationLabel)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Text(usageManager.formattedCurrentContentDuration)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundColor(.primary.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .padding(.top, 2)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(durationLabel)
                        .accessibilityValue(usageManager.formattedCurrentContentDuration)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppDesign.largeCornerRadius)
                    .fill(AppDesign.tintedSurface(activityTint, opacity: 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppDesign.largeCornerRadius)
                            .stroke(activityTint.opacity(0.12), lineWidth: 1)
                    )
            )
            
            VStack(alignment: .center, spacing: 8) {
                ZStack {
                    Text(durationHeadline)
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Spacer()

                        BreakTimerIconButton(
                            isScheduled: breakReminderManager.isScheduled,
                            action: toggleBreakTimerExpansion
                        )
                    }
                }

                Text(usageManager.formattedPopoverDuration)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(activityTint)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(durationSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: AppDesign.largeCornerRadius)
                    .fill(AppDesign.tintedSurface(activityTint, opacity: 0.12))
            )

            if isBreakTimerExpanded {
                BreakTimerControlView(
                    reminderManager: breakReminderManager,
                    onReminderScheduled: collapseBreakTimer
                )
            }
            
            VStack(spacing: 10) {
                ActionCapsuleButton(
                    title: "管理白名单与黑名单",
                    systemImage: "checklist",
                    tint: AppDesign.primaryBlue,
                    action: openWhitelistWindow
                )

                ActionCapsuleButton(
                    title: "查看统计数据",
                    systemImage: "chart.pie.fill",
                    tint: AppDesign.primaryBlue,
                    action: openStatisticsWindow
                )

                ActionCapsuleButton(
                    title: "今日总结",
                    systemImage: "clock.arrow.circlepath",
                    tint: AppDesign.primaryBlue,
                    action: openTodaySummaryWindow
                )

                ActionCapsuleButton(
                    title: "清空所有历史数据",
                    systemImage: "trash.fill",
                    tint: AppDesign.destructiveRed,
                    action: showResetConfirmation
                )
                
                Divider().padding(.horizontal, 40)
                
                ActionCapsuleButton(
                    title: "退出 GrandleTick",
                    systemImage: "power",
                    tint: AppDesign.secondaryText,
                    action: {
                        // 1. 退出前强制持久化当前活动 Session，确保退出时的数据能够写入 SQLite 数据库。
                        usageManager.flushPendingSession()
                        
                        // 2. 强行终止进程，防止任何打开的子窗口/Sheet（例如年度报告）拦截系统终止指令而导致退出受阻。
                        exit(0)
                    }
                )
            }
            .padding(.horizontal, 12)
        }
        .padding()
        .frame(width: 320)
        .opacity(contentVisible ? 1 : 0)
        .offset(y: reduceMotion || contentVisible ? 0 : 6)
        .animation(reduceMotion ? nil : AppDesign.animationCurve, value: isStudyActive)
        .onAppear {
            onBreakTimerExpansionChanged(isBreakTimerExpanded)
            withAnimation(reduceMotion ? nil : AppDesign.springAnimation) {
                contentVisible = true
            }
        }
        .onDisappear {
            // NSPopover 会复用同一个 HostingController；关闭时必须复位入场状态，
            // 否则下次打开会直接绘制缓存界面，随后才切换为刷新后的正确内容。
            contentVisible = false
        }
        .onChange(of: breakReminderManager.isScheduled) { _, isScheduled in
            // 计时可能由菜单预设、自定义输入或提醒“延后”触发；统一在开始后恢复紧凑布局。
            if isScheduled {
                collapseBreakTimer()
            }
        }
    }

    private func toggleBreakTimerExpansion() {
        let newValue = !isBreakTimerExpanded
        if !newValue {
            collapseBreakTimer()
            return
        }

        // 弹层高度变化本身会触发 AppKit 重新布局；这里保持同步切换，避免再叠加 SwiftUI
        // 弹簧位移后出现两套几何动画互相拉扯。
        isBreakTimerExpanded = newValue
        onBreakTimerExpansionChanged(newValue)
    }

    private func collapseBreakTimer() {
        guard isBreakTimerExpanded else { return }
        isBreakTimerExpanded = false
        onBreakTimerExpansionChanged(false)
    }
    
    func openWhitelistWindow() {
        FeatureWindowCoordinator.shared.openWhitelistWindow(modelContext: modelContext)
    }
    
    func openStatisticsWindow() {
        FeatureWindowCoordinator.shared.openStatisticsWindow(modelContext: modelContext)
    }

    func openTodaySummaryWindow() {
        // 打开总结前先把正在进行的会话写入数据库，让时间线能够包含用户此刻正在做的事情。
        usageManager.flushPendingSession()
        FeatureWindowCoordinator.shared.openTodaySummaryWindow(modelContext: modelContext)
    }
    
    private func showResetConfirmation() {
        // 1. 激活 App 并配置警告弹窗属性。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "危险操作：清空所有历史数据"
        alert.informativeText = "此操作将永久删除数据库中的所有活动日志。请在下方输入：“\(requiredConfirmText)”"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定清空")
        alert.addButton(withTitle: "取消")
        
        // 2. 插入文本输入框作为辅助视图。
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        inputField.placeholderString = requiredConfirmText
        alert.accessoryView = inputField
        
        // 3. 以模态方式运行弹窗并根据输入文字判断是否执行清空。
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if inputField.stringValue == requiredConfirmText {
                deleteAllData()
            } else {
                NSSound.beep()
            }
        }
    }
    
    private func deleteAllData() {
        do {
            let descriptor = FetchDescriptor<ActivityLog>()
            let allLogs = try modelContext.fetch(descriptor)
            for log in allLogs { modelContext.delete(log) }
            try modelContext.save()
            usageManager.restartTrackingAfterHistoryDeletion()
        } catch {
            print("❌ [Database] 清空失败: \(error.localizedDescription)")
        }
    }
}

private struct BreakTimerIconButton: View {
    let isScheduled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isScheduled ? AppDesign.successGreen : AppDesign.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                isScheduled
                                    ? AppDesign.successGreen.opacity(isHovered ? 0.18 : 0.12)
                                    : Color.primary.opacity(isHovered ? 0.10 : 0.055)
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                if isScheduled {
                    Circle()
                        .fill(AppDesign.successGreen)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(AppDesign.appBackground, lineWidth: 1.5))
                }
            }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(isScheduled ? "查看正在进行的休息计时" : "设置定时休息")
        .accessibilityLabel(isScheduled ? "查看正在进行的休息计时" : "设置定时休息")
        .animation(AppDesign.animationCurve, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct BreakTimerControlView: View {
    let reminderManager: BreakReminderManager
    let onReminderScheduled: () -> Void
    @State private var customMinutes = "45"

    private var parsedCustomMinutes: Int? {
        guard let minutes = Int(customMinutes), (1...720).contains(minutes) else {
            return nil
        }
        return minutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("定时休息", systemImage: "cup.and.saucer.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppDesign.primaryText)

                Spacer()

                if reminderManager.isScheduled {
                    Text("进行中")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppDesign.successGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppDesign.successGreen.opacity(0.12), in: Capsule())
                }
            }

            if reminderManager.isScheduled {
                HStack(spacing: 10) {
                    Text(reminderManager.formattedRemainingDuration)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundStyle(AppDesign.successGreen)
                        .contentTransition(.numericText())
                        .accessibilityLabel("距离休息")
                        .accessibilityValue(reminderManager.formattedRemainingDuration)

                    Spacer()

                    Button("取消") {
                        reminderManager.cancel()
                    }
                    .buttonStyle(AppCapsuleButtonStyle(role: .secondary, compact: true))
                }
            } else {
                HStack(spacing: 7) {
                    ForEach([25, 45, 60], id: \.self) { minutes in
                        Button("\(minutes) 分钟") {
                            reminderManager.schedule(minutes: minutes)
                            onReminderScheduled()
                        }
                        .buttonStyle(AppCapsuleButtonStyle(role: .secondary, compact: true))
                        .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 8) {
                    TextField("自定义分钟", text: $customMinutes)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit(startCustomReminder)

                    Text("分钟")
                        .font(.system(size: 11))
                        .foregroundStyle(AppDesign.secondaryText)

                    Button("开始", action: startCustomReminder)
                        .buttonStyle(AppCapsuleButtonStyle(role: .primary, compact: true))
                        .disabled(parsedCustomMinutes == nil)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppDesign.mediumCornerRadius, style: .continuous)
                .fill(AppDesign.tintedSurface(AppDesign.successGreen, opacity: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: AppDesign.mediumCornerRadius, style: .continuous)
                        .stroke(AppDesign.successGreen.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func startCustomReminder() {
        guard let parsedCustomMinutes else { return }
        reminderManager.schedule(minutes: parsedCustomMinutes)
        onReminderScheduled()
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color
    let systemImage: String
    
    var body: some View {
        HStack(spacing: 6) {
            Text(text)

            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(tint)
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
    }
}

private struct ActionCapsuleButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius)
                    .fill(tint.opacity(isHovered ? 0.14 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius))
            .scaleEffect(isHovered ? 1.01 : 1)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .animation(AppDesign.animationCurve, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
