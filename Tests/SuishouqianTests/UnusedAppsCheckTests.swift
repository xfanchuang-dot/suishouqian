import XCTest
@testable import 随手迁

/// 长期未用检查（v2.12.0）：mdls 输出解析 + 阈值过滤
final class UnusedAppsCheckTests: XCTestCase {

    private let now = Date()

    private func app(name: String, external: Bool, externalOnly: Bool = false) -> AppItem {
        var item = AppItem(
            name: name, bundleName: "\(name).app",
            path: external ? "/Volumes/Ext/\(name).app" : "/Applications/\(name).app",
            version: nil, size: 100, isSymlink: external && !externalOnly,
            symlinkTarget: external && !externalOnly ? "/Volumes/Ext/\(name).app" : nil,
            icon: nil)
        if externalOnly { item.status = .externalOnly }
        return item
    }

    private func date(_ raw: String) -> Date? {
        UnusedAppsCheck.parseLastUsed(raw)
    }

    func testParseLastUsedAcceptsSystemFormat() throws {
        let d = try XCTUnwrap(date("2026-09-11 04:03:27 +0000"))
        // 只校验能解析且日期部分正确，不跨时区比对钟点
        XCTAssertEqual(Calendar.current.component(.year, from: d), 2026)
        XCTAssertEqual(Calendar.current.component(.day, from: d), 11)
    }

    func testParseLastUsedRejectsNullAndGarbage() {
        XCTAssertNil(date("(null)"))
        XCTAssertNil(date(""))
        XCTAssertNil(date("   \n"))
        XCTAssertNil(date("yesterday"))
        XCTAssertNil(date("2026-13-99 99:99:99 +0000"))
    }

    func testFilterPicksOnlyStaleExternalApps() {
        let staleNative = app(name: "Stale", external: true, externalOnly: true)
        let freshExternal = app(name: "Fresh", external: true)
        let internalApp = app(name: "Local", external: false)
        let noData = app(name: "NoData", external: true, externalOnly: true)

        let candidates: [(app: AppItem, lastUsed: Date?)] = [
            (staleNative, Calendar.current.date(byAdding: .day, value: -45, to: now)),
            (freshExternal, Calendar.current.date(byAdding: .day, value: -3, to: now)),
            (internalApp, Calendar.current.date(byAdding: .day, value: -90, to: now)),  // 内置盘再旧也不报
            (noData, nil),                                                              // 拿不到数据宁缺毋滥
        ]
        let result = UnusedAppsCheck.filter(candidates, days: 30, now: now)
        XCTAssertEqual(result.map(\.app.name), ["Stale"])
    }

    func testFilterBoundaryExactly30DaysCounts() {
        let edge = app(name: "Edge", external: true, externalOnly: true)
        let candidates = [(edge, Calendar.current.date(byAdding: .day, value: -30, to: now))]
        XCTAssertEqual(UnusedAppsCheck.filter(candidates, days: 30, now: now).count, 1)
    }

    func testFilterSortsStalestFirst() {
        let a = app(name: "A", external: true, externalOnly: true)
        let b = app(name: "B", external: true, externalOnly: true)
        let candidates: [(app: AppItem, lastUsed: Date?)] = [
            (a, Calendar.current.date(byAdding: .day, value: -40, to: now)),
            (b, Calendar.current.date(byAdding: .day, value: -80, to: now)),
        ]
        XCTAssertEqual(UnusedAppsCheck.filter(candidates, now: now).map(\.app.name), ["B", "A"])
    }
}
