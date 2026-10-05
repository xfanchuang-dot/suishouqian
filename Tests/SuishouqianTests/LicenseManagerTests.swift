import XCTest
import CryptoKit
@testable import 随手迁

/// Pro 许可证：离线 Ed25519 验签。
///
/// 这一组用例守的是**生意账**，不是代码风格：
/// - 验签必须真验（篡改一位就拒）
/// - 别人拿自己的密钥不能伪造（换一对密钥签的许可证必须不过）
/// - 到期日不能算错（早一天/晚一天都是在坑付费用户）
/// - 发布前公钥必须已注入（占位符上架 = 用户付了钱却永远激活不了）
@MainActor
final class LicenseManagerTests: XCTestCase {

    // MARK: - 夹具

    /// 每个用例用独立密钥对，互不干扰；生产公钥不参与测试免得把真实私钥写进测试。
    private func freshKey() -> Curve25519.Signing.PrivateKey {
        Curve25519.Signing.PrivateKey()
    }

    private func publicKeyBase64(_ key: Curve25519.Signing.PrivateKey) -> String {
        key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// 按仓库约定的格式签发一张许可证（与 scripts/license_tool.swift 同格式）。
    private func makeLicense(payload: String, key: Curve25519.Signing.PrivateKey) -> String {
        let data = Data(payload.utf8)
        let sig = try! key.signature(for: data)
        return data.base64EncodedString() + "." + sig.base64EncodedString()
    }

    private func makeLicense(email: String, expiry: String, tier: String = "pro",
                             key: Curve25519.Signing.PrivateKey) -> String {
        makeLicense(payload: "\(email)|\(expiry)|\(tier)", key: key)
    }

    private static let payloadFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    private func dateString(daysFromNow: Int) -> String {
        let d = Calendar(identifier: .gregorian).date(byAdding: .day, value: daysFromNow, to: Date())!
        return Self.payloadFormatter.string(from: d)
    }

    // MARK: - 正向

    func testValidLicenseParsesAllFields() {
        let key = freshKey()
        let license = makeLicense(email: "buyer@example.com", expiry: "2099-12-31", key: key)

        let info = LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(key))

        XCTAssertNotNil(info, "正常签发的许可证必须验签通过")
        XCTAssertEqual(info?.email, "buyer@example.com")
        XCTAssertEqual(info?.tier, "pro")
        XCTAssertFalse(info?.isExpired ?? true, "2099 年到期不应判为过期")
    }

    func testPastedLicenseWithWhitespaceStillVerifies() {
        let key = freshKey()
        let license = makeLicense(email: "buyer@example.com", expiry: "2099-12-31", key: key)
        // 邮件/聊天窗口粘贴常带换行与缩进——不该因此判用户"许可证无效"
        let messy = "  " + license.prefix(20) + "\n\t" + license.dropFirst(20) + "  \n"

        XCTAssertNotNil(LicenseManager.verify(messy, publicKeyBase64: publicKeyBase64(key)),
                        "带空白/换行的粘贴必须仍能验签")
    }

    // MARK: - 攻击面

    func testTamperedEmailIsRejected() {
        let key = freshKey()
        // 用合法许可证的签名，配一个被改过的 payload
        let original = Data("buyer@example.com|2099-12-31|pro".utf8)
        let forged = Data("attacker@example.com|2099-12-31|pro".utf8)
        let sig = try! key.signature(for: original)
        let license = forged.base64EncodedString() + "." + sig.base64EncodedString()

        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(key)),
                     "改了 email 但签名没换，必须拒绝")
    }

    func testTamperedExpiryIsRejected() {
        let key = freshKey()
        let original = Data("buyer@example.com|2020-01-01|pro".utf8)
        let forged = Data("buyer@example.com|2099-12-31|pro".utf8)
        let sig = try! key.signature(for: original)
        let license = forged.base64EncodedString() + "." + sig.base64EncodedString()

        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(key)),
                     "自己把过期日改到未来，必须拒绝")
    }

    func testLicenseSignedByAnotherKeyIsRejected() {
        let issuer = freshKey()
        let attacker = freshKey()
        let license = makeLicense(email: "buyer@example.com", expiry: "2099-12-31", key: attacker)

        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(issuer)),
                     "用别人的密钥签的许可证不能通过（否则人人都能自己发证）")
    }

    func testGarbageAndMalformedInputIsRejected() {
        let key = freshKey()
        let pub = publicKeyBase64(key)
        let cases: [String] = [
            "",
            "not-a-license",
            "onlyonepart",
            "..",
            "a.b",
            "!!!.???",
            Data("no signature".utf8).base64EncodedString(),   // 缺签名段
            "\(Data("x".utf8).base64EncodedString()).\(Data(repeating: 0, count: 64).base64EncodedString())",
        ]
        for c in cases {
            XCTAssertNil(LicenseManager.verify(c, publicKeyBase64: pub),
                         "畸形输入必须返回 nil，收到: \(c.prefix(30))")
        }
    }

    func testValidSignatureButWrongFieldCountIsRejected() {
        let key = freshKey()
        // 签名有效，但 payload 只有 2 段——不能因为签得对就照单全收
        let license = makeLicense(payload: "buyer@example.com|2099-12-31", key: key)

        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(key)),
                     "payload 字段数不符（缺 tier）必须拒绝")
    }

    func testValidSignatureButUnparseableDateIsRejected() {
        let key = freshKey()
        let license = makeLicense(payload: "buyer@example.com|下辈子|pro", key: key)

        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(key)),
                     "到期日无法解析必须拒绝，不能退化成永久授权")
    }

    func testBadPublicKeyIsRejectedNotCrashed() {
        let key = freshKey()
        let license = makeLicense(email: "buyer@example.com", expiry: "2099-12-31", key: key)

        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: ""))
        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: "not-base64!!!"))
        XCTAssertNil(LicenseManager.verify(license, publicKeyBase64: "YWJj"))  // 长度不对的公钥
    }

    // MARK: - 到期语义（含当日）

    func testExpiryIsInclusiveOfTheDay() {
        let key = freshKey()
        let pub = publicKeyBase64(key)

        let today = LicenseManager.verify(
            makeLicense(email: "a@b.com", expiry: dateString(daysFromNow: 0), key: key),
            publicKeyBase64: pub)
        XCTAssertEqual(today?.isExpired, false, "到期日当天必须仍可用（少一天就是在坑付费用户）")

        let yesterday = LicenseManager.verify(
            makeLicense(email: "a@b.com", expiry: dateString(daysFromNow: -1), key: key),
            publicKeyBase64: pub)
        XCTAssertEqual(yesterday?.isExpired, true, "到期日次日必须失效")

        let tomorrow = LicenseManager.verify(
            makeLicense(email: "a@b.com", expiry: dateString(daysFromNow: 1), key: key),
            publicKeyBase64: pub)
        XCTAssertEqual(tomorrow?.isExpired, false)

        let longExpired = LicenseManager.verify(
            makeLicense(email: "a@b.com", expiry: "2020-01-01", key: key),
            publicKeyBase64: pub)
        XCTAssertEqual(longExpired?.isExpired, true)
    }

    // MARK: - 发布闸门：公钥必须已注入

    func testEmbeddedPublicKeyIsInjectedAndWellFormed() {
        let embedded = LicenseManager.publicKeyBase64
        XCTAssertNotEqual(embedded, LicenseManager.placeholderPublicKey,
                          "公钥仍是占位符：这样的包发出去，用户付了钱也永远激活不了")
        guard let data = Data(base64Encoded: embedded) else {
            return XCTFail("内嵌公钥不是合法 base64: \(embedded)")
        }
        XCTAssertEqual(data.count, 32, "Ed25519 公钥必须是 32 字节，实际 \(data.count)")
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: data),
                         "内嵌公钥必须能被 CryptoKit 接受")
    }

    func testCommittedPublicKeyFileMatchesEmbeddedKey() throws {
        // 仓库根 license_public_key.txt 与源码内嵌公钥必须同源，否则"哪把是真的"就会漂移。
        // 测试运行时的工作目录是包根目录。
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("license_public_key.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("仓库根没有 license_public_key.txt（工具尚未跑过 keygen）")
        }
        XCTAssertEqual(raw.trimmingCharacters(in: .whitespacesAndNewlines),
                       LicenseManager.publicKeyBase64,
                       "license_public_key.txt 与 LicenseManager 内嵌公钥不一致")
    }

    // MARK: - 激活 / 退出（真实用户路径）

    func testActivateThenDeactivateRoundTrip() {
        let key = freshKey()
        let license = makeLicense(email: "buyer@example.com", expiry: "2099-12-31", key: key)
        // 别让上一次跑留下的 Pro 状态污染断言
        UserDefaults.standard.removeObject(forKey: "proLicense.v1")
        let manager = LicenseManager.shared
        manager.deactivate()

        // 内嵌公钥与测试密钥不是一对，所以走底层验证；这里专测存储与状态迁移
        XCTAssertNotNil(LicenseManager.verify(license, publicKeyBase64: publicKeyBase64(key)))

        // 用真许可证激活（存在嵌入公钥，因此断言"失败"是预期行为）
        let bad = manager.activate(license: license)
        XCTAssertFalse(bad.ok, "拿别人的密钥签的许可证不能激活")
        XCTAssertFalse(manager.isPro)

        let junk = manager.activate(license: "garbage")
        XCTAssertFalse(junk.ok)
        XCTAssertFalse(manager.isPro, "激活失败后不能残留 Pro 状态")

        manager.deactivate()
        XCTAssertFalse(manager.isPro)
        XCTAssertNil(manager.licensedEmail)
    }

    func testNormalizedStripsAllWhitespace() {
        XCTAssertEqual(LicenseManager.normalized(" a b\n\tc \r\n"), "abc")
        XCTAssertEqual(LicenseManager.normalized(""), "")
    }
}
