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
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }
}

/// 按当前语言取文案。`key` 用中文原文（带 `%@` / `%lld` 占位）。
func l10n(_ key: String, _ args: CVarArg...) -> String {
    let locale = L10n.locale
    let format = String(
        localized: String.LocalizationValue(stringLiteral: key),
        bundle: .module,
        locale: locale)
    guard !args.isEmpty else { return format }
    return String(format: format, locale: locale, arguments: args)
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
