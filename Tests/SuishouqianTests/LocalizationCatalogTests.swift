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
        XCTAssertEqual(l10n("已选 %lld 个（%@）", 1, "12 MB"), "1 selected (12 MB)")
    }
}
