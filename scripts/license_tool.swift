#!/usr/bin/env swift
//
// 随手迁 Pro 许可证工具（离线 Ed25519，零服务器成本）
//
// 用法:
//   swift scripts/license_tool.swift keygen [--out <私钥路径>]
//   swift scripts/license_tool.swift issue --email <邮箱> [--expiry YYYY-MM-DD] [--tier pro] [--key <私钥路径>]
//   swift scripts/license_tool.swift verify <许可证> [--pub <公钥base64>]
//
// 密钥去向（沿用 scripts/sparkle_keys.sh 的惯例）:
//   私钥  默认 ~/Library/Caches/suishouqian-license/private_key.txt（**绝密**，已被 .gitignore 覆盖）
//   公钥  license_public_key.txt（**不是秘密**）+ 内嵌在 LicenseManager.swift
//
// 许可证格式（必须与 LicenseManager.verify 完全一致）:
//   base64( payload ) + "." + base64( Ed25519 签名 )
//   payload = "email|expiry|tier"，例如 "user@example.com|2099-12-31|pro"
//
// 一个应用一辈子只用一把密钥：换公钥 = 已卖出的许可证全部作废，且老用户无法自助恢复。

import Foundation
import CryptoKit

// MARK: - 参数解析

struct Args {
    let command: String
    private var flags: [String: String] = [:]
    var positional: [String] = []

    init(_ argv: [String]) {
        var rest = argv
        command = rest.isEmpty ? "help" : rest.removeFirst()
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    flags[name] = rest[i + 1]
                    i += 2
                } else {
                    flags[name] = ""
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func flag(_ name: String) -> String? {
        guard let v = flags[name], !v.isEmpty else { return nil }
        return v
    }
}

// MARK: - 常量

let defaultKeyPath = ("~/Library/Caches/suishouqian-license/private_key.txt" as NSString)
    .expandingTildeInPath
let projectDir = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()   // scripts/
    .deletingLastPathComponent()   // 仓库根
let publicKeyFile = projectDir.appendingPathComponent("license_public_key.txt")

/// 买断制的默认到期日：远未来，配合 App 侧 "有效期含当日" 的判定
let defaultExpiry = "2099-12-31"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误: " + message + "\n").utf8))
    exit(1)
}

func note(_ message: String) {
    print(message)
}

// MARK: - payload 组装（与 LicenseManager 对齐）

/// 固定格式日期串，且**必须**锁定 en_US_POSIX：
/// 用 dateFormat 解析时若跟随用户区域（如佛历/民国历），同一张许可证在不同 Mac 上
/// 会算出不同日期。校验公钥同理——这里的一致性就是许可证的可移植性。
let payloadDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Shanghai")
    return f
}()

// MARK: - 子命令

func keygen(_ args: Args) {
    let outPath = args.flag("out") ?? defaultKeyPath
    let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)

    if FileManager.default.fileExists(atPath: outURL.path) {
        note("⚠️  私钥已存在: \(outURL.path)")
        note("    一个应用一辈子只用一把密钥。换掉它，已售出的许可证全部作废，")
        note("    且老用户无法自助恢复（只能重新人工签发）。如非必要请勿继续。")
        note("    确定要重新生成，请先手动移走该文件，再跑一次 keygen。")
        exit(2)
    }

    let key = Curve25519.Signing.PrivateKey()
    let privB64 = key.rawRepresentation.base64EncodedString()
    let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

    do {
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try (privB64 + "\n").write(to: outURL, atomically: true, encoding: .utf8)
        // 私钥文件权限收紧到 600：同机其他用户读不到
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: outURL.path)
        try (pubB64 + "\n").write(to: publicKeyFile, atomically: true, encoding: .utf8)
    } catch {
        fail("写文件失败: \(error.localizedDescription)")
    }

    note("")
    note("✅ 密钥对已生成")
    note("")
    note("  私钥（绝密，立即备份到密码管理器，不要进仓库/聊天/邮件）:")
    note("    \(outURL.path)")
    note("  公钥（公开，已写入 \(publicKeyFile.lastPathComponent)）:")
    note("    \(pubB64)")
    note("")
    note("  下一步：把上面的公钥填进 Sources/Suishouqian/Services/LicenseManager.swift")
    note("  的 publicKeyBase64（或直接重跑本工具的 keygen 后再复制一次）。")
    note("")
}

func loadPrivateKey(_ args: Args) -> Curve25519.Signing.PrivateKey {
    let path = args.flag("key") ?? defaultKeyPath
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
        fail("读不到私钥: \(url.path)\n      先跑: swift scripts/license_tool.swift keygen")
    }
    let b64 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: b64), data.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
        fail("私钥文件格式不对（应为 32 字节 seed 的 base64）: \(url.path)")
    }
    return key
}

func issue(_ args: Args) {
    guard let email = args.flag("email") else {
        fail("缺少 --email。用法: issue --email <邮箱> [--expiry YYYY-MM-DD]")
    }
    let emailClean = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard emailClean.contains("@"), !emailClean.contains("|") else {
        fail("邮箱不合法（必须含 @，且不能含 |，因为 | 是 payload 分隔符）")
    }
    let expiry = args.flag("expiry") ?? defaultExpiry
    guard payloadDateFormatter.date(from: expiry) != nil else {
        fail("到期日必须是 YYYY-MM-DD，收到: \(expiry)")
    }
    let tier = args.flag("tier") ?? "pro"

    let payload = "\(emailClean)|\(expiry)|\(tier)"
    let payloadData = Data(payload.utf8)
    let key = loadPrivateKey(args)

    guard let signature = try? key.signature(for: payloadData) else {
        fail("签名失败")
    }
    let license = payloadData.base64EncodedString() + "." + signature.base64EncodedString()

    // 自检：签完立刻用自己的公钥验一遍，杜绝"发出去的许可证验不过"
    let pub = key.publicKey
    let ok = pub.isValidSignature(signature, for: payloadData)
    guard ok else { fail("自检失败：刚签出的许可证验签不通过") }

    print(license)
    FileHandle.standardError.write(Data("""
    ✅ 已签发（自检通过）
       邮箱: \(emailClean)
       到期: \(expiry)（含当日）
       层级: \(tier)
    把上面那一行完整发给用户（设置 → 关于 → 支持开发者 → 输入许可证）。
    注意：许可证含用户邮箱，属于个人信息，只发给本人。

    """.utf8))
}

func verify(_ args: Args) {
    guard let license = args.positional.first else {
        fail("用法: verify <许可证字符串> [--pub <公钥base64>]")
    }
    let pubB64: String
    if let p = args.flag("pub") {
        pubB64 = p
    } else if let fromFile = try? String(contentsOf: publicKeyFile, encoding: .utf8) {
        pubB64 = fromFile.trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        fail("找不到 \(publicKeyFile.path)，可用 --pub 直接给公钥")
    }

    // 与本工具 issue / App 侧一致的宽松处理：去掉粘贴带进来的空白
    let clean = license.components(separatedBy: .whitespacesAndNewlines).joined()
    let parts = clean.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2,
          let payloadData = Data(base64Encoded: parts[0]),
          let sigData = Data(base64Encoded: parts[1]),
          let payload = String(data: payloadData, encoding: .utf8) else {
        fail("格式错误：许可证应为 base64(payload).base64(signature)")
    }
    guard let pubData = Data(base64Encoded: pubB64),
          let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else {
        fail("公钥 base64 解析失败")
    }
    guard pubKey.isValidSignature(sigData, for: payloadData) else {
        fail("签名不匹配（许可证被篡改，或公钥与签发时不是一对）")
    }

    let fields = payload.split(separator: "|").map(String.init)
    guard fields.count == 3 else { fail("payload 字段数不是 3: \(payload)") }
    guard let expiry = payloadDateFormatter.date(from: fields[1]) else {
        fail("payload 里的到期日无法解析: \(fields[1])")
    }
    let expired = Date() >= Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: expiry)!
    print("""
    ✅ 签名有效
       邮箱: \(fields[0])
       到期: \(fields[1])（含当日）
       层级: \(fields[2])
       状态: \(expired ? "已过期" : "有效期内")
    """)
    exit(expired ? 3 : 0)
}

func usage() {
    print("""
    随手迁 Pro 许可证工具（离线 Ed25519）

      swift scripts/license_tool.swift keygen [--out <私钥路径>]
      swift scripts/license_tool.swift issue --email <邮箱> [--expiry YYYY-MM-DD] [--tier pro] [--key <私钥路径>]
      swift scripts/license_tool.swift verify <许可证> [--pub <公钥base64>]

    私钥默认: \(defaultKeyPath)
    公钥文件: \(publicKeyFile.path)
    """)
}

// MARK: - 入口

let args = Args(Array(CommandLine.arguments.dropFirst()))
switch args.command {
case "keygen":  keygen(args)
case "issue":   issue(args)
case "verify":  verify(args)
case "help", "--help", "-h": usage()
default:
    note("未知子命令: \(args.command)\n")
    usage()
    exit(1)
}
