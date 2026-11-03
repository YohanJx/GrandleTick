import Foundation

enum BrowserService {
    // 1. 获取浏览器当前的活动标签页 URL。
    // 使用 AppleScript 是目前 macOS 上获取沙盒外浏览器 URL 的最可靠方式。
    static func fetchActiveURL(for appName: String) -> String? {
        // 1. 根据浏览器名称生成对应的 AppleScript 脚本代码。
        let script: String
        if appName.contains("Safari") {
            script = "tell application \"Safari\" to return URL of front document"
        } else if appName == "Chromium" {
            // Chromium 使用独立的应用身份，不能向 Google Chrome 请求它的标签页。
            script = "tell application \"Chromium\" to return URL of active tab of front window"
        } else if appName.contains("Chrome") {
            script = "tell application \"Google Chrome\" to return URL of active tab of front window"
        } else if appName.contains("Edge") {
            script = "tell application \"Microsoft Edge\" to return URL of active tab of front window"
        } else {
            return nil
        }

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

    // 2. 检查应用是否属于受支持的浏览器。
    static func isBrowserApp(bundleId: String) -> Bool {
        // Chromium 的标识不包含 Chrome，必须显式识别才能进入域名采集流程。
        bundleId == "org.chromium.Chromium" || bundleId.contains("Safari") || bundleId.contains("Chrome") || bundleId.contains("Edge")
    }
}
