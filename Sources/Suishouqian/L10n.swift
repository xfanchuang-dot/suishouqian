import Foundation
import SwiftUI

/// 界面文案。中文是开发语言；英文走 String Catalog。
/// 测试进程默认仍返回中文，避免既有断言被系统语言带偏。
enum L10n {
    nonisolated(unsafe) static var localeOverride: Locale?

    static var locale: Locale {
        if let localeOverride { return localeOverride }
        if isRunningTests { return Locale(identifier: "zh-Hans") }
        return .autoupdatingCurrent
    }

    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil {
            return true
        }
        // `swift test` 不一定导出上面的环境变量，但进程一定是 xctest。
        if ProcessInfo.processInfo.processName == "xctest" { return true }
        return Bundle.allBundles.contains { bundle in
            let path = bundle.bundlePath
            return path.hasSuffix(".xctest") || path.contains(".xctest/")
        }
    }
}

/// 按当前语言取文案。`key` 用中文原文（带 `%@` / `%lld` 占位）。
func l10n(_ key: String, _ args: CVarArg...) -> String {
    L10n.render(key, args, locale: L10n.locale)
}

extension L10n {
    /// String Catalog 在测试包里不一定按 `locale:` 选中英文，所以按语言目录直接取。
    static func string(_ key: String, locale: Locale) -> String {
        for code in candidateCodes(locale) {
            guard let path = Bundle.module.path(forResource: code, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
            if value != key || code.hasPrefix("zh") { return value }
        }
        return key
    }

    private static func candidateCodes(_ locale: Locale) -> [String] {
        var codes: [String] = []
        let id = locale.identifier.replacingOccurrences(of: "_", with: "-")
        codes.append(id)
        if let lang = locale.language.languageCode?.identifier {
            codes.append(lang)
            if lang == "zh" { codes.append("zh-Hans") }
        }
        codes.append("zh-Hans")
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    /// 取出转换符（`@`、`d`、`f`）。`%%` 不算占位。
    static func formatSpecifiers(_ format: String) -> [String] {
        var specs: [String] = []
        var index = format.startIndex
        while index < format.endIndex {
            guard format[index] == "%" else {
                index = format.index(after: index)
                continue
            }
            let next = format.index(after: index)
            if next < format.endIndex, format[next] == "%" {
                index = format.index(after: next)
                continue
            }
            var cursor = next
            while cursor < format.endIndex {
                let character = format[cursor]
                cursor = format.index(after: cursor)
                if "diouxXfFeEgGaAcsp@".contains(character) {
                    specs.append(String(character))
                    break
                }
            }
            index = cursor
        }
        return specs
    }

    /// `%@` 只接受对象。整数和浮点先变成十进制文本。
    static func argument(_ arg: CVarArg, for specifier: String) -> CVarArg {
        guard specifier == "@" else { return arg }
        switch arg {
        case let value as String: return value
        case let value as Int: return String(value)
        case let value as Int64: return String(value)
        case let value as Int32: return String(value)
        case let value as Int16: return String(value)
        case let value as UInt: return String(value)
        case let value as UInt64: return String(value)
        case let value as UInt32: return String(value)
        case let value as Double: return String(value)
        case let value as Float: return String(value)
        default: return arg
        }
    }

    /// 英文复数规则。只读 `en.lproj`，跟系统当前语言无关。
    private static let englishPluralRules: [String: [String: Any]] = {
        guard let dir = Bundle.module.path(forResource: "en", ofType: "lproj") else { return [:] }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("Localizable.stringsdict")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        var rules: [String: [String: Any]] = [:]
        for (key, value) in plist {
            if let entry = value as? [String: Any] {
                rules[key] = entry
            }
        }
        return rules
    }()

    static func render(_ key: String, _ args: [CVarArg], locale: Locale) -> String {
        let base = string(key, locale: locale)
        // 英文复数在 en.lproj/Localizable.stringsdict。这里自己展开，
        // 不走系统当前语言，中文目录没有这份文件就不会被改写。
        let format = pluralFormat(key: key, fallback: base, locale: locale, args: args)
        guard !args.isEmpty else { return format }
        // `%@` 配整数会在 String(format:) 里段错误。迁移动作已经做完才写成功日志，
        // 这里把数字收成字符串，避免成功路径把进程打死。
        let specs = formatSpecifiers(format)
        let safe = args.enumerated().map { index, arg in
            argument(arg, for: index < specs.count ? specs[index] : "")
        }
        return String(format: format, locale: locale, arguments: safe)
    }

    static func pluralFormat(key: String, fallback: String, locale: Locale, args: [CVarArg]) -> String {
        guard locale.language.languageCode?.identifier == "en",
              let entry = englishPluralRules[key],
              let template = entry["NSStringLocalizedFormatKey"] as? String else {
            return fallback
        }
        return expandPluralTemplate(template, entry: entry, args: args)
    }

    private static func expandPluralTemplate(_ template: String, entry: [String: Any], args: [CVarArg]) -> String {
        var output = ""
        var index = template.startIndex
        var argumentIndex = 0
        while index < template.endIndex {
            guard template[index] == "%" else {
                output.append(template[index])
                index = template.index(after: index)
                continue
            }
            let rest = template[index...]
            if rest.hasPrefix("%%") {
                output += "%%"
                index = template.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("%#@") {
                let nameStart = template.index(index, offsetBy: 3)
                guard let nameEnd = template[nameStart...].firstIndex(of: "@") else {
                    output.append("%")
                    index = template.index(after: index)
                    continue
                }
                let name = String(template[nameStart..<nameEnd])
                let value = argumentIndex < args.count ? integerArgument(args[argumentIndex]) : nil
                output += pluralVariant(entry[name], value: value)
                argumentIndex += 1
                index = template.index(after: nameEnd)
                continue
            }
            var cursor = template.index(after: index)
            var found = false
            while cursor < template.endIndex {
                let character = template[cursor]
                cursor = template.index(after: cursor)
                if "diouxXfFeEgGaAcsp@".contains(character) {
                    found = true
                    break
                }
            }
            guard found else {
                output.append("%")
                index = template.index(after: index)
                continue
            }
            output += template[index..<cursor]
            argumentIndex += 1
            index = cursor
        }
        return output
    }

    private static func pluralVariant(_ raw: Any?, value: Int64?) -> String {
        guard let dict = raw as? [String: Any] else { return "%lld" }
        let category = value == 1 ? "one" : "other"
        if let text = dict[category] as? String { return text }
        if let text = dict["other"] as? String { return text }
        return "%lld"
    }

    private static func integerArgument(_ arg: CVarArg) -> Int64? {
        switch arg {
        case let value as Int: return Int64(value)
        case let value as Int64: return value
        case let value as Int32: return Int64(value)
        case let value as Int16: return Int64(value)
        case let value as UInt: return Int64(value)
        case let value as UInt64: return Int64(exactly: value)
        case let value as UInt32: return Int64(value)
        case let value as Double: return Int64(value)
        case let value as Float: return Int64(value)
        default: return nil
        }
    }
}

extension Button where Label == Text {
    /// `Button` 的标题重载只吃本地化键字面量。运行时字符串走这里。
    init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(title) }
    }
}

extension View {
    /// 帮助气泡和辅助功能标签只吃字面量。已经本地化的字符串包成 Text。
    func help(_ text: String) -> some View {
        help(Text(text))
    }

    func accessibilityLabel(_ label: String) -> some View {
        accessibilityLabel(Text(label))
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: String, systemImage name: String) {
        self.init {
            Text(title)
        } icon: {
            Image(systemName: name)
        }
    }
}
