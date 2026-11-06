import XCTest
@testable import 随手迁

/// 字符串目录：每个界面 key 都有简体中文和英文，占位符一致，源码里的 l10n 没有漏网。
final class LocalizationCatalogTests: XCTestCase {

    private func catalog() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Suishouqian/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }

    private func sourceKeys() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Suishouqian")
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            var i = src.startIndex
            while let found = src.range(of: "l10n(", range: i..<src.endIndex) {
                var k = found.upperBound
                while k < src.endIndex, src[k].isWhitespace { k = src.index(after: k) }
                guard k < src.endIndex, src[k] == "\"" else {
                    i = found.upperBound
                    continue
                }
                k = src.index(after: k)
                var raw = ""
                while k < src.endIndex {
                    if src[k] == "\\" {
                        let next = src.index(after: k)
                        guard next < src.endIndex else { break }
                        let map: [Character: String] = ["n": "\n", "r": "\r", "t": "\t", "\"": "\"", "\\": "\\"]
                        raw += map[src[next]] ?? String(src[next])
                        k = src.index(after: next)
                        continue
                    }
                    if src[k] == "\"" { break }
                    raw.append(src[k])
                    k = src.index(after: k)
                }
                keys.insert(raw)
                i = k < src.endIndex ? src.index(after: k) : src.endIndex
            }
        }
        return keys
    }

    private func specifiers(_ s: String) -> [String] {
        var out: [String] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "%", let next = s.index(i, offsetBy: 1, limitedBy: s.index(before: s.endIndex)) {
                if s[next] == "@" || s[next] == "%" {
                    out.append("%" + String(s[next]))
                    i = s.index(after: next)
                    continue
                }
                if s[i...].hasPrefix("%lld") {
                    out.append("%lld")
                    i = s.index(i, offsetBy: 4)
                    continue
                }
                if s[i...].hasPrefix("%.0f") {
                    out.append("%.0f")
                    i = s.index(i, offsetBy: 4)
                    continue
                }
            }
            i = s.index(after: i)
        }
        return out
    }

    func testEveryKeyHasChineseAndEnglish() throws {
        let strings = try catalog()
        XCTAssertGreaterThan(strings.count, 500)
        for (key, value) in strings {
            let entry = value as? [String: Any]
            let locs = entry?["localizations"] as? [String: Any]
            let zh = locs?["zh-Hans"] as? [String: Any]
            let en = locs?["en"] as? [String: Any]
            let zhText = (zh?["stringUnit"] as? [String: Any])?["value"] as? String
            let enText = (en?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertEqual(zhText, key, "简体中文必须保留原文：\(key.prefix(40))")
            XCTAssertNotNil(enText, "缺少英文：\(key.prefix(40))")
            XCTAssertFalse(enText?.isEmpty ?? true)
            if let enText {
                XCTAssertEqual(specifiers(key), specifiers(enText), "占位符不一致：\(key.prefix(40))")
            }
        }
    }

    func testSourceKeysAreAllInTheCatalog() throws {
        let strings = try catalog()
        let keys = try sourceKeys()
        XCTAssertFalse(keys.isEmpty)
        let missing = keys.subtracting(strings.keys)
        XCTAssertEqual(missing, [], "源码里的 l10n key 没有进目录：\(missing.prefix(8))")
    }

    func testEnglishLookupFollowsLocaleOverride() {
        L10n.localeOverride = Locale(identifier: "en")
        defer { L10n.localeOverride = nil }
        XCTAssertEqual(l10n("取消"), "Cancel")
        XCTAssertEqual(l10n("设置"), "Settings")
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 0, "12 MB"), "0 items selected (12 MB)")
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 1, "12 MB"), "1 item selected (12 MB)")
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 2, "12 MB"), "2 items selected (12 MB)")
    }

    func testEnglishQuantitiesUseSingularAndPlural() {
        L10n.localeOverride = Locale(identifier: "en")
        defer { L10n.localeOverride = nil }

        XCTAssertEqual(
            l10n("近 %lld 天启动 %lld 次 · %@", 0, 2, "X"),
            "In the last 0 days, launched 2 times · X")
        XCTAssertEqual(
            l10n("近 %lld 天启动 %lld 次 · %@", 1, 1, "X"),
            "In the last 1 day, launched 1 time · X")
        XCTAssertEqual(
            l10n("近 %lld 天启动 %lld 次 · %@", 2, 1, "X"),
            "In the last 2 days, launched 1 time · X")
        XCTAssertEqual(l10n("%lld 个高频应用住在外置盘", 0),
                       "0 apps you use often live on an external drive")
        XCTAssertEqual(l10n("%lld 个高频应用住在外置盘", 1),
                       "1 app you use often lives on an external drive")
        XCTAssertEqual(l10n("%lld 个高频应用住在外置盘", 2),
                       "2 apps you use often live on an external drive")
        XCTAssertEqual(l10n("已用 %lld%%", 0), "0% used")
        XCTAssertEqual(l10n("已用 %lld%%", 1), "1% used")
        XCTAssertEqual(l10n("已用 %lld%%", 2), "2% used")
        XCTAssertEqual(l10n("先处理：%@，可回 %lld 分", "links", 1),
                       "Start with links. That can restore 1 point")
        XCTAssertEqual(l10n("先处理：%@，可回 %lld 分", "links", 2),
                       "Start with links. That can restore 2 points")
    }

    func testChineseCountsStayInTheOriginalSentence() {
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 0, "12 MB"), "已选 0 个（12 MB）")
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 1, "12 MB"), "已选 1 个（12 MB）")
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 2, "12 MB"), "已选 2 个（12 MB）")
        XCTAssertEqual(l10n("近 %lld 天启动 %lld 次 · %@", 1, 2, "X"), "近 1 天启动 2 次 · X")
        XCTAssertEqual(l10n("已用 %lld%%", 12), "已用 12%")
    }

    func testEveryCountedEnglishStringHasPluralRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Suishouqian/en.lproj")
        let plistData = try Data(contentsOf: root.appendingPathComponent("Localizable.stringsdict"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        let rules = try XCTUnwrap(plist)
        let counted = try countedStringKeys(in: root.appendingPathComponent("Localizable.strings"))
        XCTAssertEqual(Set(rules.keys), counted)

        L10n.localeOverride = Locale(identifier: "en")
        defer { L10n.localeOverride = nil }
        for (key, value) in rules {
            let entry = try XCTUnwrap(value as? [String: Any])
            XCTAssertNotNil(entry["NSStringLocalizedFormatKey"], key)
            var singularDiffers = false
            for (name, raw) in entry where name != "NSStringLocalizedFormatKey" {
                let rule = try XCTUnwrap(raw as? [String: Any], name)
                let one = try XCTUnwrap(rule["one"] as? String, key)
                let other = try XCTUnwrap(rule["other"] as? String, key)
                if one != other { singularDiffers = true }
            }
            let zero = L10n.render(key, countArguments(key, number: 0), locale: Locale(identifier: "en"))
            let one = L10n.render(key, countArguments(key, number: 1), locale: Locale(identifier: "en"))
            let two = L10n.render(key, countArguments(key, number: 2), locale: Locale(identifier: "en"))
            XCTAssertNotEqual(zero, one, key)
            XCTAssertNotEqual(zero, two, key)
            if singularDiffers {
                XCTAssertNotEqual(one, two, key)
            }
        }
    }

    private func countedStringKeys(in url: URL) throws -> Set<String> {
        let text = try String(contentsOf: url, encoding: .utf8)
        var keys = Set<String>()
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "\"" else {
                index = text.index(after: index)
                continue
            }
            let parsed = try parseStringsLiteral(text, from: text.index(after: index))
            let key = parsed.value
            var cursor = parsed.end
            while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
            if cursor < text.endIndex, text[cursor] == "=", key.contains("%lld") {
                keys.insert(key)
            }
            index = parsed.end
        }
        return keys
    }

    private func parseStringsLiteral(_ text: String, from start: String.Index) throws -> (value: String, end: String.Index) {
        var value = ""
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                let next = text.index(after: index)
                guard next < text.endIndex else { break }
                let map: [Character: String] = ["n": "\n", "r": "\r", "t": "\t", "\"": "\"", "\\": "\\"]
                value += map[text[next]] ?? String(text[next])
                index = text.index(after: next)
                continue
            }
            if text[index] == "\"" {
                return (value, text.index(after: index))
            }
            value.append(text[index])
            index = text.index(after: index)
        }
        throw NSError(domain: "strings", code: 1)
    }

    private func countArguments(_ key: String, number: Int) -> [CVarArg] {
        var args: [CVarArg] = []
        var index = key.startIndex
        while index < key.endIndex {
            guard key[index] == "%" else {
                index = key.index(after: index)
                continue
            }
            if key[index...].hasPrefix("%%") {
                index = key.index(index, offsetBy: 2)
                continue
            }
            if key[index...].hasPrefix("%lld") {
                args.append(number)
                index = key.index(index, offsetBy: 4)
                continue
            }
            if key[index...].hasPrefix("%.0f") {
                args.append(1.0)
                index = key.index(index, offsetBy: 4)
                continue
            }
            if key[index...].hasPrefix("%@") {
                args.append("X")
                index = key.index(index, offsetBy: 2)
                continue
            }
            index = key.index(after: index)
        }
        return args
    }

    func testObjectPlaceholderAcceptsInteger() {
        XCTAssertEqual(
            l10n("迁移成功 %@：%@ 字节 → %@", "X.app", Int64(12), "/tmp/X.app"),
            "迁移成功 X.app：12 字节 → /tmp/X.app")
    }
}
