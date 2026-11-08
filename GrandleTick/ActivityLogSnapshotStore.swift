import Foundation
import SQLite3

/// SQLite 只读快照读取器，绕开 SwiftData 对象图构建开销。
enum ActivityLogSnapshotStore {
    static func databaseURL() -> URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return applicationSupportDirectoryURL
            .appendingPathComponent("GrandleTick", isDirectory: true)
            .appendingPathComponent("ActivityData.sqlite")
    }

    static func fetchLogs(
        databaseURL: URL,
        interval: DateInterval?,
        includeOverlapping: Bool = false
    ) -> [ActivityLogSnapshot] {
        // 1. 在后台直接读取 SQLite 行，绕开 SwiftData 对象图构建带来的主线程成本。
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }

        defer { sqlite3_close(database) }

        let sql: String
        if interval == nil {
            sql = """
            SELECT ZAPPNAME, ZWINDOWTITLE, ZSTARTTIME, ZDURATION, ZDOMAIN, ZBILIBILIIDENTIFIER, ZFULLURL, ZPDFIDENTIFIER
            FROM ZACTIVITYLOG
            ORDER BY ZSTARTTIME DESC
            """
        } else if includeOverlapping {
            // 今日时间线需要包含昨晚开始、跨过零点后仍在继续的会话；原有统计调用保持按开始时间筛选。
            sql = """
            SELECT ZAPPNAME, ZWINDOWTITLE, ZSTARTTIME, ZDURATION, ZDOMAIN, ZBILIBILIIDENTIFIER, ZFULLURL, ZPDFIDENTIFIER
            FROM ZACTIVITYLOG
            WHERE ZSTARTTIME < ? AND (ZSTARTTIME + ZDURATION) > ?
            ORDER BY ZSTARTTIME DESC
            """
        } else {
            sql = """
            SELECT ZAPPNAME, ZWINDOWTITLE, ZSTARTTIME, ZDURATION, ZDOMAIN, ZBILIBILIIDENTIFIER, ZFULLURL, ZPDFIDENTIFIER
            FROM ZACTIVITYLOG
            WHERE ZSTARTTIME >= ? AND ZSTARTTIME < ?
            ORDER BY ZSTARTTIME DESC
            """
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }

        defer { sqlite3_finalize(statement) }

        if let interval {
            if includeOverlapping {
                sqlite3_bind_double(statement, 1, interval.end.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(statement, 2, interval.start.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_double(statement, 1, interval.start.timeIntervalSinceReferenceDate)
                sqlite3_bind_double(statement, 2, interval.end.timeIntervalSinceReferenceDate)
            }
        }

        var snapshots: [ActivityLogSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let appName = stringColumn(statement, index: 0) ?? ""
            let windowTitle = stringColumn(statement, index: 1) ?? ""
            let startTime = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            let duration = sqlite3_column_double(statement, 3)

            snapshots.append(
                ActivityLogSnapshot(
                    appName: appName,
                    windowTitle: windowTitle,
                    startTime: startTime,
                    duration: duration,
                    domain: stringColumn(statement, index: 4),
                    bilibiliIdentifier: stringColumn(statement, index: 5),
                    fullUrl: stringColumn(statement, index: 6),
                    pdfIdentifier: stringColumn(statement, index: 7)
                )
            )
        }

        return snapshots
    }

    private static func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }
}

private struct AggregateCacheDayFingerprint: Equatable {
    let count: Int
    let duration: TimeInterval
    let maxStartTime: Date?
}

private struct AggregateCacheKey: Hashable {
    let dayStart: Date
    let hour: Int
    let appName: String
    let windowTitle: String
    let domain: String?
    let bilibiliIdentifier: String?
    let pdfIdentifier: String?
}

private struct AggregateCacheValidationKey: Hashable {
    let cacheVersion: String
    let dayStart: Date
}

private struct AggregateCacheAccumulator {
    let key: AggregateCacheKey
    var duration: TimeInterval
    var latestStartTime: Date
    var fullUrl: String?

    mutating func merge(_ log: PreparedLog) {
        duration += log.duration
        if log.startTime >= latestStartTime {
            latestStartTime = log.startTime
            fullUrl = log.fullUrl
        }
    }
}

/// 已结束整天的物化统计缓存。原始 ActivityLog 仍是事实源，缓存只用于统计页快速读取。
enum ActivityAggregateCacheStore {
    private static let algorithmVersion = "aggregate-cache-v1"
    private static let validationLock = NSLock()
    private static var validatedDays: Set<AggregateCacheValidationKey> = []

    static func cacheVersion(for whitelist: WhitelistSnapshot) -> String {
        // 白名单与黑名单直接影响 isStudy 分类，因此缓存版本必须绑定当前规则输入，避免修改名单后复用旧统计。
        let apps = whitelist.lowercasedApps.sorted().joined(separator: ",")
        let domains = whitelist.domains.map { $0.lowercased() }.sorted().joined(separator: ",")
        let blackApps = whitelist.lowercasedBlacklistedApps.sorted().joined(separator: ",")
        let blackDomains = whitelist.blacklistedDomains.map { $0.lowercased() }.sorted().joined(separator: ",")
        return "\(algorithmVersion)|apps=\(apps)|domains=\(domains)|blackApps=\(blackApps)|blackDomains=\(blackDomains)"
    }

    static func fetchPreparedLogs(
        databaseURL: URL,
        interval: DateInterval?,
        whitelist: WhitelistSnapshot,
        calendar: Calendar
    ) -> [PreparedLog] {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            let sourceLogs = ActivityLogSnapshotStore.fetchLogs(databaseURL: databaseURL, interval: interval)
            return sourceLogs.compactMap { PreparedLog(snapshot: $0, whitelist: whitelist, calendar: calendar) }
        }

        defer { sqlite3_close(database) }
        guard let database else { return [] }

        ensureSchema(database)

        // 1. 将请求区间拆成“可缓存的完整历史日”和“必须实时读取的边界片段”。
        let plan = buildFetchPlan(database: database, interval: interval, calendar: calendar)
        let cacheVersion = cacheVersion(for: whitelist)

        // 2. 对已结束整天建立或刷新缓存。通过源数据指纹判断历史删除、迁移或压缩是否让缓存失效。
        for dayStart in plan.cacheableDays {
            guard !Task.isCancelled else { return [] }

            // 已结束日期在同一次 App 运行中只核验一次。删除记录会主动撤销标记，避免 60 秒刷新反复扫描全年历史。
            guard needsValidation(cacheVersion: cacheVersion, dayStart: dayStart) else { continue }
            let fingerprint = sourceFingerprint(database: database, dayStart: dayStart, calendar: calendar)
            if cachedFingerprint(database: database, cacheVersion: cacheVersion, dayStart: dayStart) != fingerprint {
                rebuildCache(
                    database: database,
                    databaseURL: databaseURL,
                    cacheVersion: cacheVersion,
                    dayStart: dayStart,
                    fingerprint: fingerprint,
                    whitelist: whitelist,
                    calendar: calendar
                )
            }
            markValidated(cacheVersion: cacheVersion, dayStart: dayStart)
        }

        // 3. 从缓存读取完整历史日，并补上今天或半截边界区间的原始日志。
        var preparedLogs = readCachedLogs(
            database: database,
            cacheVersion: cacheVersion,
            dayStarts: plan.cacheableDays,
            calendar: calendar,
            whitelist: whitelist
        )

        for rawInterval in plan.rawIntervals {
            guard !Task.isCancelled else { return [] }
            let rawLogs = ActivityLogSnapshotStore.fetchLogs(databaseURL: databaseURL, interval: rawInterval)
            preparedLogs.append(contentsOf: rawLogs.compactMap { PreparedLog(snapshot: $0, whitelist: whitelist, calendar: calendar) })
        }

        return preparedLogs.sorted { $0.startTime > $1.startTime }
    }

    static func invalidateDay(databaseURL: URL, dayStart: Date) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return
        }

        defer { sqlite3_close(database) }
        guard let database else { return }

        ensureSchema(database)

        // 删除操作会改变历史日的事实源，直接清除该日所有规则版本的缓存，下一次统计时按需重建。
        execute(database, sql: "DELETE FROM ZGT_ACTIVITY_AGGREGATE_CACHE WHERE ZDAYSTART = ?", bindings: [.double(dayStart.timeIntervalSinceReferenceDate)])
        execute(database, sql: "DELETE FROM ZGT_ACTIVITY_AGGREGATE_META WHERE ZDAYSTART = ?", bindings: [.double(dayStart.timeIntervalSinceReferenceDate)])
        invalidateValidation(for: dayStart)
    }

    static func prewarmClosedDays(databaseURL: URL, whitelist: WhitelistSnapshot, calendar: Calendar) {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX

        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return
        }

        defer { sqlite3_close(database) }
        guard let database else { return }

        ensureSchema(database)
        let plan = buildFetchPlan(database: database, interval: nil, calendar: calendar)
        let cacheVersion = cacheVersion(for: whitelist)

        // 启动后只预热已经结束的完整自然日；今天仍保持实时读取，避免前台活动持续写入时缓存频繁失效。
        for dayStart in plan.cacheableDays {
            guard !Task.isCancelled else { return }
            let fingerprint = sourceFingerprint(database: database, dayStart: dayStart, calendar: calendar)
            if cachedFingerprint(database: database, cacheVersion: cacheVersion, dayStart: dayStart) != fingerprint {
                rebuildCache(
                    database: database,
                    databaseURL: databaseURL,
                    cacheVersion: cacheVersion,
                    dayStart: dayStart,
                    fingerprint: fingerprint,
                    whitelist: whitelist,
                    calendar: calendar
                )
            }
        }
    }

    private static func ensureSchema(_ database: OpaquePointer) {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS ZGT_ACTIVITY_AGGREGATE_CACHE (
                ZCACHEVERSION TEXT NOT NULL,
                ZDAYSTART REAL NOT NULL,
                ZHOUR INTEGER NOT NULL,
                ZAPPNAME TEXT NOT NULL,
                ZWINDOWTITLE TEXT NOT NULL,
                ZDOMAIN TEXT,
                ZBILIBILIIDENTIFIER TEXT,
                ZFULLURL TEXT,
                ZPDFIDENTIFIER TEXT,
                ZDURATION REAL NOT NULL,
                ZLATESTSTARTTIME REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS ZGT_ACTIVITY_AGGREGATE_META (
                ZCACHEVERSION TEXT NOT NULL,
                ZDAYSTART REAL NOT NULL,
                ZSOURCECOUNT INTEGER NOT NULL,
                ZSOURCEDURATION REAL NOT NULL,
                ZSOURCEMAXSTARTTIME REAL,
                PRIMARY KEY (ZCACHEVERSION, ZDAYSTART)
            )
            """,
            "CREATE INDEX IF NOT EXISTS ZGT_ACTIVITY_AGGREGATE_CACHE_DAY_IDX ON ZGT_ACTIVITY_AGGREGATE_CACHE (ZCACHEVERSION, ZDAYSTART)",
            "CREATE INDEX IF NOT EXISTS ZGT_ACTIVITY_AGGREGATE_META_DAY_IDX ON ZGT_ACTIVITY_AGGREGATE_META (ZDAYSTART)"
        ]

        for statement in statements {
            sqlite3_exec(database, statement, nil, nil, nil)
        }
    }

    private static func needsValidation(cacheVersion: String, dayStart: Date) -> Bool {
        validationLock.lock()
        defer { validationLock.unlock() }
        return !validatedDays.contains(AggregateCacheValidationKey(cacheVersion: cacheVersion, dayStart: dayStart))
    }

    private static func markValidated(cacheVersion: String, dayStart: Date) {
        validationLock.lock()
        validatedDays.insert(AggregateCacheValidationKey(cacheVersion: cacheVersion, dayStart: dayStart))
        validationLock.unlock()
    }

    private static func invalidateValidation(for dayStart: Date) {
        validationLock.lock()
        validatedDays = Set(validatedDays.filter { $0.dayStart != dayStart })
        validationLock.unlock()
    }

    private static func buildFetchPlan(
        database: OpaquePointer,
        interval: DateInterval?,
        calendar: Calendar
    ) -> (cacheableDays: [Date], rawIntervals: [DateInterval]) {
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let resolvedInterval: DateInterval

        if let interval {
            resolvedInterval = interval
        } else if let bounds = sourceBounds(database: database) {
            resolvedInterval = DateInterval(start: bounds.start, end: max(bounds.end, bounds.start))
        } else {
            return ([], [])
        }

        guard resolvedInterval.end > resolvedInterval.start else { return ([], []) }

        var cacheableDays: [Date] = []
        var rawIntervals: [DateInterval] = []
        var cursor = calendar.startOfDay(for: resolvedInterval.start)

        while cursor < resolvedInterval.end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            let segmentStart = max(cursor, resolvedInterval.start)
            let segmentEnd = min(nextDay, resolvedInterval.end)

            if segmentEnd > segmentStart {
                // 只有“完整且已经结束”的自然日才能固化缓存；今天和区间边界半天仍读原始日志，避免多算。
                if segmentStart == cursor, segmentEnd == nextDay, nextDay <= todayStart {
                    cacheableDays.append(cursor)
                } else {
                    rawIntervals.append(DateInterval(start: segmentStart, end: segmentEnd))
                }
            }

            cursor = nextDay
        }

        return (cacheableDays, rawIntervals)
    }

    private static func sourceBounds(database: OpaquePointer) -> DateInterval? {
        let sql = "SELECT MIN(ZSTARTTIME), MAX(ZSTARTTIME) FROM ZACTIVITYLOG"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }

        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL,
              sqlite3_column_type(statement, 1) != SQLITE_NULL else {
            return nil
        }

        let minDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 0))
        let maxDate = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
        return DateInterval(start: minDate, end: maxDate.addingTimeInterval(0.001))
    }

    private static func sourceFingerprint(database: OpaquePointer, dayStart: Date, calendar: Calendar) -> AggregateCacheDayFingerprint {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return AggregateCacheDayFingerprint(count: 0, duration: 0, maxStartTime: nil)
        }

        let sql = """
        SELECT COUNT(*), COALESCE(SUM(ZDURATION), 0), MAX(ZSTARTTIME)
        FROM ZACTIVITYLOG
        WHERE ZSTARTTIME >= ? AND ZSTARTTIME < ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return AggregateCacheDayFingerprint(count: 0, duration: 0, maxStartTime: nil)
        }

        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, dayStart.timeIntervalSinceReferenceDate)
        sqlite3_bind_double(statement, 2, dayEnd.timeIntervalSinceReferenceDate)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return AggregateCacheDayFingerprint(count: 0, duration: 0, maxStartTime: nil)
        }

        let count = Int(sqlite3_column_int64(statement, 0))
        let duration = sqlite3_column_double(statement, 1)
        let maxStartTime: Date? = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))

        return AggregateCacheDayFingerprint(count: count, duration: duration, maxStartTime: maxStartTime)
    }

    private static func cachedFingerprint(database: OpaquePointer, cacheVersion: String, dayStart: Date) -> AggregateCacheDayFingerprint? {
        let sql = """
        SELECT ZSOURCECOUNT, ZSOURCEDURATION, ZSOURCEMAXSTARTTIME
        FROM ZGT_ACTIVITY_AGGREGATE_META
        WHERE ZCACHEVERSION = ? AND ZDAYSTART = ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }

        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: cacheVersion)
        sqlite3_bind_double(statement, 2, dayStart.timeIntervalSinceReferenceDate)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let maxStartTime: Date? = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
        return AggregateCacheDayFingerprint(
            count: Int(sqlite3_column_int64(statement, 0)),
            duration: sqlite3_column_double(statement, 1),
            maxStartTime: maxStartTime
        )
    }

    private static func rebuildCache(
        database: OpaquePointer,
        databaseURL: URL,
        cacheVersion: String,
        dayStart: Date,
        fingerprint: AggregateCacheDayFingerprint,
        whitelist: WhitelistSnapshot,
        calendar: Calendar
    ) {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let dayInterval = DateInterval(start: dayStart, end: dayEnd)
        let sourceLogs = ActivityLogSnapshotStore.fetchLogs(databaseURL: databaseURL, interval: dayInterval)
        let preparedLogs = sourceLogs.compactMap { PreparedLog(snapshot: $0, whitelist: whitelist, calendar: calendar) }

        var grouped: [AggregateCacheKey: AggregateCacheAccumulator] = [:]
        for log in preparedLogs {
            let key = AggregateCacheKey(
                dayStart: log.dayStart,
                hour: calendar.component(.hour, from: log.startTime),
                appName: log.appName,
                windowTitle: log.windowTitle,
                domain: log.resolvedDomain,
                bilibiliIdentifier: log.bilibiliIdentifier,
                pdfIdentifier: log.pdfIdentifier
            )

            if var accumulator = grouped[key] {
                accumulator.merge(log)
                grouped[key] = accumulator
            } else {
                grouped[key] = AggregateCacheAccumulator(
                    key: key,
                    duration: log.duration,
                    latestStartTime: log.startTime,
                    fullUrl: log.fullUrl
                )
            }
        }

        execute(database, sql: "BEGIN IMMEDIATE", bindings: [])
        execute(database, sql: "DELETE FROM ZGT_ACTIVITY_AGGREGATE_CACHE WHERE ZCACHEVERSION = ? AND ZDAYSTART = ?", bindings: [.text(cacheVersion), .double(dayStart.timeIntervalSinceReferenceDate)])
        execute(database, sql: "DELETE FROM ZGT_ACTIVITY_AGGREGATE_META WHERE ZCACHEVERSION = ? AND ZDAYSTART = ?", bindings: [.text(cacheVersion), .double(dayStart.timeIntervalSinceReferenceDate)])

        for accumulator in grouped.values {
            insertCacheRow(database: database, cacheVersion: cacheVersion, accumulator: accumulator)
        }

        insertMetaRow(database: database, cacheVersion: cacheVersion, dayStart: dayStart, fingerprint: fingerprint)
        execute(database, sql: "COMMIT", bindings: [])
    }

    private static func insertCacheRow(database: OpaquePointer, cacheVersion: String, accumulator: AggregateCacheAccumulator) {
        let sql = """
        INSERT INTO ZGT_ACTIVITY_AGGREGATE_CACHE (
            ZCACHEVERSION, ZDAYSTART, ZHOUR, ZAPPNAME, ZWINDOWTITLE, ZDOMAIN,
            ZBILIBILIIDENTIFIER, ZFULLURL, ZPDFIDENTIFIER, ZDURATION, ZLATESTSTARTTIME
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        execute(
            database,
            sql: sql,
            bindings: [
                .text(cacheVersion),
                .double(accumulator.key.dayStart.timeIntervalSinceReferenceDate),
                .int(accumulator.key.hour),
                .text(accumulator.key.appName),
                .text(accumulator.key.windowTitle),
                .nullableText(accumulator.key.domain),
                .nullableText(accumulator.key.bilibiliIdentifier),
                .nullableText(accumulator.fullUrl),
                .nullableText(accumulator.key.pdfIdentifier),
                .double(accumulator.duration),
                .double(accumulator.latestStartTime.timeIntervalSinceReferenceDate)
            ]
        )
    }

    private static func insertMetaRow(
        database: OpaquePointer,
        cacheVersion: String,
        dayStart: Date,
        fingerprint: AggregateCacheDayFingerprint
    ) {
        let sql = """
        INSERT INTO ZGT_ACTIVITY_AGGREGATE_META (
            ZCACHEVERSION, ZDAYSTART, ZSOURCECOUNT, ZSOURCEDURATION, ZSOURCEMAXSTARTTIME
        ) VALUES (?, ?, ?, ?, ?)
        """
        execute(
            database,
            sql: sql,
            bindings: [
                .text(cacheVersion),
                .double(dayStart.timeIntervalSinceReferenceDate),
                .int(fingerprint.count),
                .double(fingerprint.duration),
                .nullableDouble(fingerprint.maxStartTime?.timeIntervalSinceReferenceDate)
            ]
        )
    }

    private static func readCachedLogs(
        database: OpaquePointer,
        cacheVersion: String,
        dayStarts: [Date],
        calendar: Calendar,
        whitelist: WhitelistSnapshot
    ) -> [PreparedLog] {
        guard !dayStarts.isEmpty else { return [] }
        let dayValues = Set(dayStarts.map { $0.timeIntervalSinceReferenceDate })
        let minDay = dayValues.min() ?? 0
        let maxDay = dayValues.max() ?? 0

        let sql = """
        SELECT ZAPPNAME, ZWINDOWTITLE, ZLATESTSTARTTIME, ZDURATION, ZDOMAIN,
               ZBILIBILIIDENTIFIER, ZFULLURL, ZPDFIDENTIFIER, ZDAYSTART
        FROM ZGT_ACTIVITY_AGGREGATE_CACHE
        WHERE ZCACHEVERSION = ? AND ZDAYSTART >= ? AND ZDAYSTART <= ?
        ORDER BY ZLATESTSTARTTIME DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }

        defer { sqlite3_finalize(statement) }

        bindText(statement, index: 1, value: cacheVersion)
        sqlite3_bind_double(statement, 2, minDay)
        sqlite3_bind_double(statement, 3, maxDay)

        var logs: [PreparedLog] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dayStartValue = sqlite3_column_double(statement, 8)
            guard dayValues.contains(dayStartValue) else { continue }

            let snapshot = ActivityLogSnapshot(
                appName: stringColumn(statement, index: 0) ?? "",
                windowTitle: stringColumn(statement, index: 1) ?? "",
                startTime: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                duration: sqlite3_column_double(statement, 3),
                domain: stringColumn(statement, index: 4),
                bilibiliIdentifier: stringColumn(statement, index: 5),
                fullUrl: stringColumn(statement, index: 6),
                pdfIdentifier: stringColumn(statement, index: 7)
            )

            if let preparedLog = PreparedLog(snapshot: snapshot, whitelist: whitelist, calendar: calendar) {
                logs.append(preparedLog)
            }
        }

        return logs
    }

    private enum SQLiteBinding {
        case text(String)
        case nullableText(String?)
        case double(Double)
        case nullableDouble(Double?)
        case int(Int)
    }

    private static func execute(_ database: OpaquePointer, sql: String, bindings: [SQLiteBinding]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }

        defer { sqlite3_finalize(statement) }

        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case let .text(value):
                bindText(statement, index: index, value: value)
            case let .nullableText(value):
                if let value {
                    bindText(statement, index: index, value: value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .double(value):
                sqlite3_bind_double(statement, index, value)
            case let .nullableDouble(value):
                if let value {
                    sqlite3_bind_double(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .int(value):
                sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            }
        }

        sqlite3_step(statement)
    }

    private static func bindText(_ statement: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func stringColumn(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        let value = String(cString: text)
        return value.isEmpty ? nil : value
    }
}
