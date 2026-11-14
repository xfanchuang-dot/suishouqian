import XCTest
@testable import 随手迁

/// Pro 权益口径：Pro > 试用 > 免费，试用一次性、按自然日倒计时。
/// 这一组守的是「付了钱的人不能被判成免费，没付钱的人不能白嫖第二次」。
final class ProEntitlementTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ProEntitlementTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - 夹具

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeInfo(email: String = "buyer@example.com",
                          expiry: Date,
                          tier: String = "pro") -> LicenseManager.LicenseInfo {
        LicenseManager.LicenseInfo(email: email, expiry: expiry, tier: tier)
    }

    /// 注入"验签通过"的假许可证，避免测试依赖真实私钥
    private func verifier(_ info: LicenseManager.LicenseInfo?) -> (String) -> LicenseManager.LicenseInfo? {
        { _ in info }
    }

    private func storeLicense(_ raw: String = "fake.license") {
        defaults.set(raw, forKey: ProEntitlement.licenseStorageKey)
    }

    private func day(_ offset: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: now)!
    }

    // MARK: - 免费 / 试用

    func testNoLicenseNoTrialIsFree() {
        XCTAssertEqual(ProEntitlement.status(now: now, defaults: defaults), .free)
        XCTAssertFalse(ProEntitlement.isEntitled(.versionedBackup, now: now, defaults: defaults))
        XCTAssertFalse(ProEntitlement.isEntitled(.smartAdvice, now: now, defaults: defaults))
    }

    func testTrialStartsAtSevenDaysAndCountsDown() {
        XCTAssertTrue(ProEntitlement.startTrialIfAvailable(now: now, defaults: defaults))

        XCTAssertEqual(ProEntitlement.status(now: now, defaults: defaults), .trial(daysLeft: 7),
                       "刚开始试用应是完整 7 天")
        XCTAssertEqual(ProEntitlement.status(now: day(1), defaults: defaults), .trial(daysLeft: 6))
        XCTAssertEqual(ProEntitlement.status(now: day(6), defaults: defaults), .trial(daysLeft: 1))
        XCTAssertTrue(ProEntitlement.isEntitled(.versionedBackup, now: day(6), defaults: defaults))
    }

    func testTrialExpiresAtDaySeven() {
        XCTAssertTrue(ProEntitlement.startTrialIfAvailable(now: now, defaults: defaults))

        XCTAssertNil(ProEntitlement.trialDaysLeft(now: day(7), defaults: defaults),
                     "满 7 天即到期")
        XCTAssertEqual(ProEntitlement.status(now: day(7), defaults: defaults), .free)
        XCTAssertFalse(ProEntitlement.isEntitled(.smartAdvice, now: day(7), defaults: defaults))
        XCTAssertTrue(ProEntitlement.hasUsedTrial(defaults: defaults),
                      "到期后仍算用过了，不能重新开始")
    }

    func testTrialCanOnlyBeStartedOnce() {
        XCTAssertTrue(ProEntitlement.startTrialIfAvailable(now: now, defaults: defaults))
        XCTAssertFalse(ProEntitlement.startTrialIfAvailable(now: day(30), defaults: defaults),
                       "试用是一次性的")
        XCTAssertEqual(ProEntitlement.status(now: day(30), defaults: defaults), .free,
                       "重复点击不能续期")
    }

    // MARK: - Pro 优先级

    func testProWinsOverTrial() {
        XCTAssertTrue(ProEntitlement.startTrialIfAvailable(now: now, defaults: defaults))
        storeLicense()
        let info = makeInfo(expiry: day(3650))
        let status = ProEntitlement.status(now: now, defaults: defaults,
                                           licenseVerifier: verifier(info))
        guard case .pro(let email, _) = status else {
            return XCTFail("Pro 应优先于试用，实际 \(status)")
        }
        XCTAssertEqual(email, "buyer@example.com")
        XCTAssertTrue(ProEntitlement.isEntitled(.versionedBackup, now: now,
                                                defaults: defaults,
                                                licenseVerifier: verifier(info)))
    }

    func testExpiredLicenseFallsBackToActiveTrial() {
        XCTAssertTrue(ProEntitlement.startTrialIfAvailable(now: now, defaults: defaults))
        storeLicense()
        let expired = makeInfo(expiry: day(-1))
        XCTAssertEqual(
            ProEntitlement.status(now: now, defaults: defaults,
                                  licenseVerifier: verifier(expired)),
            .trial(daysLeft: 7),
            "许可证过期不应连仍在有效期内的试用一起吞掉")
    }

    func testExpiredLicenseWithoutTrialIsFree() {
        storeLicense()
        let expired = makeInfo(expiry: day(-1))
        XCTAssertEqual(
            ProEntitlement.status(now: now, defaults: defaults,
                                  licenseVerifier: verifier(expired)),
            .free)
    }

    func testLicenseExpiryIsInclusiveOfTheDay() {
        storeLicense()
        let info = makeInfo(expiry: day(0))
        XCTAssertEqual(
            ProEntitlement.status(now: now, defaults: defaults,
                                  licenseVerifier: verifier(info)),
            .pro(email: "buyer@example.com", expiry: day(0)),
            "到期日当天仍是 Pro")
        XCTAssertEqual(
            ProEntitlement.status(now: day(1), defaults: defaults,
                                  licenseVerifier: verifier(info)),
            .free,
            "次日失效")
    }

    func testNonProTierDoesNotUnlock() {
        storeLicense()
        let info = makeInfo(expiry: day(3650), tier: "basic")
        XCTAssertEqual(
            ProEntitlement.status(now: now, defaults: defaults,
                                  licenseVerifier: verifier(info)),
            .free,
            "验签通过但层级不是 pro 不能解锁")
    }

    func testInvalidStoredLicenseIsIgnored() {
        storeLicense("garbage")
        // 不注入 verifier：走真实验签，垃圾串必须失败
        XCTAssertEqual(ProEntitlement.status(now: now, defaults: defaults), .free)
    }
}
