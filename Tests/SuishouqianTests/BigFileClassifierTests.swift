import XCTest
@testable import 随手迁

/// v2.5.2 大文件分类器：让体检条目"说人话"，系统数据绝不建议清理
final class BigFileClassifierTests: XCTestCase {

    func testAppleContainerDataIsSystemManaged() {
        let r = BigFileClassifier.classify(
            path: "/Users/fan/Library/Containers/com.apple.Safari/Data/Library/Caches/big")
        XCTAssertTrue(r.systemManaged, "com.apple 容器数据必须标记为系统管理")
        XCTAssertTrue(r.label.contains("系统数据"))
    }

    func testPrivateVarIsSystemManaged() {
        let r = BigFileClassifier.classify(path: "/private/var/db/some/huge.file")
        XCTAssertTrue(r.systemManaged)
    }

    func testIPhoneBackupLabeled() {
        let r = BigFileClassifier.classify(
            path: "/Users/fan/Library/Application Support/MobileSync/Backup/xxx/3d0d.bin")
        // v3.0.1：残留扫描一直把 MobileSync 当保护名单，大文件面板却给了可点的
        // 「清理」按钮（与项目自己的风险分级矛盾）。现在统一为"工具不提供清理"。
        XCTAssertFalse(r.systemManaged, "iPhone 备份不是系统管理的数据")
        XCTAssertTrue(r.protected, "iPhone 备份不可再生，必须禁止一键清理")
        XCTAssertTrue(r.cleanupDisabled, "清理按钮必须禁用")
        XCTAssertTrue(r.label.contains("iPhone 备份"))
    }

    func testDevCacheLabeledRegenerable() {
        for path in [
            "/Users/fan/Library/Developer/Xcode/DerivedData/App-x/index",
            "/Users/fan/Library/Developer/CoreSimulator/Devices/x/data",
            "/Users/fan/Projects/web/node_modules/electron/dist/x",
        ] {
            let r = BigFileClassifier.classify(path: path)
            XCTAssertFalse(r.systemManaged)
            XCTAssertTrue(r.label.contains("开发缓存"), path)
        }
    }

    func testAppDataWarnsAboutLoss() {
        let r = BigFileClassifier.classify(
            path: "/Users/fan/Library/Application Support/Google/Chrome/x.dat")
        XCTAssertTrue(r.label.contains("可能丢失"), "应用数据必须警告会丢设置/记录")
    }

    func testInstallerAndMediaExtensions() {
        XCTAssertEqual(BigFileClassifier.classify(path: "/a/b/x.dmg").label, "安装镜像/安装包（装完即可删）")
        XCTAssertEqual(BigFileClassifier.classify(path: "/a/b/movie.mp4").label, "音视频文件")
        XCTAssertEqual(BigFileClassifier.classify(path: "/a/b/backup.zip").label, "压缩包")
        XCTAssertEqual(BigFileClassifier.classify(path: "/a/b/disk.raw").label, "虚拟磁盘镜像")
        XCTAssertEqual(BigFileClassifier.classify(path: "/a/b/unknown.xyz").label, "其他大文件")
    }
}
