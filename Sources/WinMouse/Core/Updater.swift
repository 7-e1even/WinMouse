import Foundation
import AppKit

/// 自动更新：检查 GitHub Releases → 下载 zip → 解包校验 → 原地替换 .app → 重启。
/// 仓库为私有时匿名 API 返回 404，回退本机 gh CLI（需 `gh auth login`）；
/// 公开仓库直接走 URLSession 下载，私有仓库用 `gh release download`。
final class Updater {
    static let shared = Updater()

    private let repo = "7-e1even/WinMouse"
    private let assetName = "WinMouse-macOS-universal.zip"
    private let d = UserDefaults.standard
    private enum Key {
        static let lastAutoCheck = "winmouse.update.lastautocheck"
    }

    struct Release {
        let tag: String          // 如 "v1.2"
        let notes: String
        /// 公开仓库的资产直链；经 gh 获取（私有仓库）时为 nil，下载走 gh
        let assetURL: URL?
        var version: [Int] { Updater.parseVersion(tag) }
    }

    enum UpdateError: LocalizedError {
        case network(String)
        case ghMissing
        case noReleaseAsset(String)
        case badPackage
        case cannotReplace(String)

        var errorDescription: String? {
            switch self {
            case .network(let msg): return msg
            case .ghMissing:
                return "仓库为私有，无法匿名检查更新：未找到 gh 命令。\n请安装并登录（brew install gh && gh auth login），或将仓库设为公开。"
            case .noReleaseAsset(let name): return "最新 Release 中没有 \(name)。"
            case .badPackage: return "下载的压缩包里没有有效的 WinMouse.app，已取消更新。"
            case .cannotReplace(let path): return "无法替换当前应用（可能没有写入权限）：\(path)\n请手动下载 Release 压缩包替换。"
            }
        }
    }

    /// "v1.2.3-beta+sha" → [1,2,3]：忽略 v 前缀、+ 构建后缀与非数字段
    static func parseVersion(_ v: String) -> [Int] {
        var s = v
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        return s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    static func isVersion(_ a: [Int], newerThan b: [Int]) -> Bool {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    var currentVersion: [Int] {
        parseVersion(currentVersionDisplay)
    }

    var currentVersionDisplay: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    // MARK: - 检查

    /// 获取最新 Release；返回 nil 表示尚未发布任何版本
    func fetchLatest() async throws -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                return parseRelease(data, viaGH: false)
            }
        } catch {
            throw UpdateError.network("网络错误：\(error.localizedDescription)")
        }
        // 404/401：私有仓库或确无 Release → gh 兜底
        guard let gh = await Self.locateGH() else { throw UpdateError.ghMissing }
        let (code, out, err) = try await Self.run(gh, ["api", "repos/\(repo)/releases/latest"])
        guard code == 0 else {
            if String(data: err, encoding: .utf8)?.contains("Not Found") == true { return nil }
            throw UpdateError.network("gh api 失败：\(String(data: err, encoding: .utf8) ?? "未知错误")")
        }
        return parseRelease(out, viaGH: true)
    }

    private func parseRelease(_ data: Data, viaGH: Bool) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else { return nil }
        var assetURL: URL?
        if let assets = obj["assets"] as? [[String: Any]] {
            for a in assets where (a["name"] as? String) == assetName {
                assetURL = (a["browser_download_url"] as? String).flatMap { URL(string: $0) }
            }
        }
        let notes = ((obj["body"] as? String) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        return Release(tag: tag, notes: String(notes.prefix(600)), assetURL: viaGH ? nil : assetURL)
    }

    // MARK: - 自动检查节奏（启动 + 每 24h 一次，静默）

    func dueForAutoCheck() -> Bool {
        let last = d.object(forKey: Key.lastAutoCheck) as? Date ?? .distantPast
        return Date().timeIntervalSince(last) >= 24 * 3600
    }

    func markAutoChecked() {
        d.set(Date(), forKey: Key.lastAutoCheck)
    }

    // MARK: - 下载

    func download(_ release: Release) async throws -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WinMouse-Update", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(assetName)
        try? fm.removeItem(at: zip)

        if let url = release.assetURL {
            var req = URLRequest(url: url)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError.network("下载失败：HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            try data.write(to: zip)
        } else {
            guard let gh = await Self.locateGH() else { throw UpdateError.ghMissing }
            let (code, _, err) = try await Self.run(gh, [
                "release", "download", release.tag, "--repo", repo,
                "--pattern", assetName, "--output", zip.path,
            ])
            guard code == 0 else {
                throw UpdateError.network("gh release download 失败：\(String(data: err, encoding: .utf8) ?? "未知错误")")
            }
        }
        return zip
    }

    // MARK: - 安装（替换 .app 并重启）

    func install(from zip: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("WinMouseUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let (dittoCode, _, dittoErr) = try await Self.run(
            "/usr/bin/ditto", ["-x", "-k", "--sequesterRsrc", zip.path, work.path])
        guard dittoCode == 0 else {
            throw UpdateError.badPackage
        }
        let newApp = work.appendingPathComponent("WinMouse.app", isDirectory: true)
        guard fm.fileExists(atPath: newApp.appendingPathComponent("Contents/Info.plist").path) else {
            throw UpdateError.badPackage
        }
        // 清掉可能存在的隔离属性，避免重启后 Gatekeeper 拦截
        _ = try? await Self.run("/usr/bin/xattr", ["-cr", newApp.path])

        let cur = Bundle.main.bundleURL
        let old = cur.deletingLastPathComponent()
            .appendingPathComponent("WinMouse-old-\(UUID().uuidString).app")
        do {
            // 运行中的二进制已加载进内存，移动包不影响当前进程
            try fm.moveItem(at: cur, to: old)
        } catch {
            throw UpdateError.cannotReplace(cur.path)
        }
        do {
            try fm.moveItem(at: newApp, to: cur)
        } catch {
            try? fm.moveItem(at: old, to: cur)
            throw UpdateError.cannotReplace(cur.path)
        }
        relaunch(at: cur, cleanup: old)
    }

    private func relaunch(at appURL: URL, cleanup oldURL: URL) {
        // 独立 shell 稍后清理旧包：本进程即将退出，不能由自己删
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.environment = ["OLD_APP": oldURL.path]
        sh.arguments = ["-c", "sleep 3; rm -rf \"$OLD_APP\""]
        try? sh.run()

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if error != nil {
                    let a = NSAlert()
                    a.messageText = "更新已安装，但自动重启失败"
                    a.informativeText = "请手动打开：\(appURL.path)"
                    a.runModal()
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 进程工具

    /// GUI 应用 PATH 受限（Finder 启动时只有 /usr/bin 等），先扫常见安装位置，
    /// 再用登录 shell 找一次（覆盖非标准路径的 Homebrew）
    private static func locateGH() async -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh", "/usr/local/bin/gh",
            "/opt/homebrew/sbin/gh", "/usr/local/sbin/gh", "/usr/bin/gh",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        guard let (code, out, _) = try? await run("/bin/zsh", ["-lc", "command -v gh"]),
              code == 0,
              let path = String(data: out, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    /// 同步 Process 包成 async：跑在全局队列，避免阻塞协作线程。
    /// 输出很小（JSON / 错误文本），先 wait 再读管道不会撑爆缓冲。
    private static func run(_ path: String, _ args: [String]) async throws
        -> (code: Int32, out: Data, err: Data)
    {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                p.standardInput = FileHandle.nullDevice
                let outPipe = Pipe()
                let errPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                do {
                    try p.run()
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                p.waitUntilExit()
                cont.resume(returning: (
                    p.terminationStatus,
                    outPipe.fileHandleForReading.readDataToEndOfFile(),
                    errPipe.fileHandleForReading.readDataToEndOfFile()
                ))
            }
        }
    }
}
