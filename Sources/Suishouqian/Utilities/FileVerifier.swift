import Foundation

struct FileVerifier {
    
    /// 逐文件比较两个目录（使用 diff -rq）
    static func verifyDirectories(source: String, target: String) async -> Bool {
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            process.arguments = ["-rq", source, target]
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            
            do {
                try process.run()
                process.waitUntilExit()
                // diff -rq 完全相同则 exit 0，不同则 exit 1
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
    
    /// 计算单个文件的 SHA256
    static func sha256(of filePath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", filePath]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(separator: " ").first.map(String.init)
        } catch {
            return nil
        }
    }
    
    /// 检查目录是否存在且非空
    static func isValidAppBundle(_ path: String) -> Bool {
        let infoPlist = "\(path)/Contents/Info.plist"
        return FileManager.default.fileExists(atPath: infoPlist)
    }
}
