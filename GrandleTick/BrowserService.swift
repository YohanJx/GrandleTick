import AppKit
import ApplicationServices

enum BrowserService {
    // 浏览器身份集中维护，避免名称本地化或预览版名称导致脚本发给另一个应用。
    private static let chromiumIDs: Set<String> = [
        "org.chromium.Chromium", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.dev", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.operasoftware.OperaGX",
        "company.thebrowser.Browser", "com.kagi.kagibrowser"
    ]
    private static let otherBrowserIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "app.zen-browser.zen",
        "com.duckduckgo.macos.browser"
    ]

    static func fetchActiveURL(processId: pid_t) -> String? {
        // 1. 仅访问仍在运行的目标进程，防止刷新任务意外启动已经退出的浏览器。
        guard let app = NSRunningApplication(processIdentifier: processId),
              let bundleID = app.bundleIdentifier else { return nil }
        if let url = accessiblePageURL(processId: processId) { return url }
        guard chromiumIDs.contains(bundleID) || bundleID.contains("Safari") else { return nil }
        let command = bundleID.contains("Safari")
            ? "URL of front document" : "URL of active tab of front window"
        let script = "tell application id \"\(bundleID)\" to return \(command)"

        // 2. 通过独立的 osascript 进程执行脚本。NSAppleScript 属于 AppKit，放到后台线程会触发主事件队列断言；
        // 独立进程既不会阻塞 GrandleTick 主线程，也不会让 AppKit 跨线程运行。
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        } catch {
            return nil
        }
    }

    static func isBrowserApp(bundleId: String) -> Bool {
        // 系统默认浏览器也进入通用采集流程，让未列出的浏览器有机会通过 AXURL 工作。
        if chromiumIDs.contains(bundleId) || otherBrowserIDs.contains(bundleId)
            || bundleId.contains("Safari") || bundleId.contains("Chrome") || bundleId.contains("Edge") {
            return true
        }
        guard let url = URL(string: "https://example.com"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return Bundle(url: appURL)?.bundleIdentifier == bundleId
    }

    private static func accessiblePageURL(processId: pid_t) -> String? {
        // 1. 沿用主窗口优先策略，避免把标签页悬浮卡片当成当前页面。
        let app = AXUIElementCreateApplication(processId)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var window: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window) != .success {
            AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)
        }
        guard let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var pending = [window as! AXUIElement]
        let deadline = Date().addingTimeInterval(1)
        var visited = 0

        // 2. 只取网页容器的 URL，不读取地址栏输入或页面链接，避免把未访问的地址记入历史。
        // 限制遍历数量和时间，防止复杂网页或无响应浏览器长期占用后台任务。
        while let element = pending.popLast(), visited < 300, Date() < deadline {
            visited += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXWebArea" {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value)
                let raw = (value as? URL)?.absoluteString ?? (value as? String)
                if let raw, let url = URL(string: raw),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                    return raw
                }
                // 不深入网页内容，避免误取嵌入网页的域名。
                continue
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if let children = children as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(300 - visited).reversed())
            }
        }
        return nil
    }
}
