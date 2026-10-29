import SwiftUI
import AppKit
import CryptoKit
import Security

// Updates from the GitHub releases of the project: Kestrel ▸ Check for Updates…, and once a day at launch (Settings).
// Installing downloads the release's DMG, checks it against the SHA-256 in the release notes, checks that the app
// inside is signed with the same certificate as this one, puts it in this app's place and relaunches.

@MainActor
final class Updater: ObservableObject {
    static let repo = "Yohoa/Kestrel"

    struct Release: Equatable {
        let version: String          // "1.4"
        let notes: String
        let dmg: URL
        let size: Int
        let page: URL
        var sha256: String? {        // "SHA-256 of `Kestrel-1.4.dmg`: `…`" in the notes
            guard let r = notes.range(of: "SHA-256[^`]*`[^`]+`: `([0-9a-f]{64})`", options: .regularExpression) else { return nil }
            return String(notes[r]).components(separatedBy: "`").dropLast().last
        }
    }

    enum Phase: Equatable {
        case idle, checking, available(Release), upToDate, downloading(Double), installing, failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var autoCheck = UserDefaults.standard.object(forKey: "updatesAutoCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updatesAutoCheck") }
    }
    @Published private(set) var lastCheck = UserDefaults.standard.object(forKey: "updatesLastCheck") as? Date

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// "1.10" is newer than "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// At launch: at most once a day, and quietly (only a newer version is shown).
    func checkAtLaunch() {
        guard autoCheck else { return }
        if let l = lastCheck, Date().timeIntervalSince(l) < 20 * 3600 { return }
        check(userAsked: false)
    }

    func check(userAsked: Bool) {
        if case .downloading = phase { return }
        phase = .checking
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let found = data.flatMap { Self.parse($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.lastCheck = Date()
                    UserDefaults.standard.set(self.lastCheck, forKey: "updatesLastCheck")
                    guard let r = found else {
                        let why = error?.localizedDescription ?? (code == 404 ? "no release found" : "GitHub answered \(code)")
                        self.phase = userAsked ? .failed("Couldn't check for updates: \(why)") : .idle
                        return
                    }
                    let skipped = UserDefaults.standard.string(forKey: "updatesSkipped")
                    if Self.isNewer(r.version, than: Self.currentVersion), userAsked || skipped != r.version {
                        self.phase = .available(r)
                    } else {
                        self.phase = userAsked ? .upToDate : .idle
                    }
                }
            }
        }.resume()
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = j["assets"] as? [[String: Any]],
              let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let url = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: v, notes: j["body"] as? String ?? "", dmg: url, size: dmg["size"] as? Int ?? 0, page: page)
    }

    func skip(_ r: Release) { UserDefaults.standard.set(r.version, forKey: "updatesSkipped"); phase = .idle }

    // MARK: installing

    private var task: URLSessionDownloadTask?
    private var progressWatch: NSKeyValueObservation?

    func install(_ r: Release) {
        phase = .downloading(0)
        let t = URLSession.shared.downloadTask(with: r.dmg) { file, _, error in
            // the file is gone once this returns: move it first
            var kept: URL?
            if let file {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("Kestrel-\(r.version)-\(UUID().uuidString).dmg")
                if (try? FileManager.default.moveItem(at: file, to: dest)) != nil { kept = dest }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.progressWatch = nil
                    guard let dmg = kept else { self.phase = .failed("Download failed: \(error?.localizedDescription ?? "no file")"); return }
                    self.phase = .installing
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Self.installFromDMG(dmg, expectedSHA: r.sha256)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                switch result {
                                case .success(let script): Self.relaunch(with: script)
                                case .failure(let e): self.phase = .failed(e.message)
                                }
                            }
                        }
                    }
                }
            }
        }
        progressWatch = t.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { MainActor.assumeIsolated { if case .downloading = self.phase { self.phase = .downloading(f) } } }
        }
        task = t
        t.resume()
    }

    func cancel() { task?.cancel(); task = nil; phase = .idle }

    struct UpdateError: Error { let message: String }

    /// Checks the DMG, copies the app out of it next to this one and returns the script that swaps them once this
    /// app has quit. Nothing here touches the running app.
    nonisolated static func installFromDMG(_ dmg: URL, expectedSHA: String?) -> Result<URL, UpdateError> {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: dmg, options: .mappedIfSafe) else { return .failure(.init(message: "Couldn't read the download")) }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let e = expectedSHA, e != sha { return .failure(.init(message: "The download doesn't match the release's SHA-256; not installed")) }

        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.open(dmg)                    // can't replace it here: let the person drag it over
            return .failure(.init(message: "Kestrel's folder isn't writable, so the new version's disk image was opened: drag Kestrel to Applications"))
        }
        let mount = fm.temporaryDirectory.appendingPathComponent("kestrel-update-\(UUID().uuidString)")
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path]) else {
            return .failure(.init(message: "Couldn't open the disk image"))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let newApp = mount.appendingPathComponent("Kestrel.app")
        guard fm.fileExists(atPath: newApp.path) else { return .failure(.init(message: "No Kestrel.app in the disk image")) }
        guard sameSigner(newApp, current) else {
            return .failure(.init(message: "The new version isn't signed like this one; not installed"))
        }
        let staged = parent.appendingPathComponent(".Kestrel-update-\(UUID().uuidString).app")
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) else { return .failure(.init(message: "Couldn't copy the new version")) }

        // waits for this process to quit, swaps the apps (the old one to the Trash), opens the new one
        let script = fm.temporaryDirectory.appendingPathComponent("kestrel-update-\(UUID().uuidString).sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let sh = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        old="\(current.path)"; new="\(staged.path)"
        trash="$HOME/.Trash/Kestrel $(date +%Y%m%d-%H%M%S).app"
        mv "$old" "$trash" && mv "$new" "$old" || { [ -d "$old" ] || mv "$trash" "$old"; rm -rf "$new"; }
        open "$old"
        rm -f "$0"
        """
        guard (try? sh.write(to: script, atomically: true, encoding: .utf8)) != nil else { return .failure(.init(message: "Couldn't prepare the update")) }
        _ = run("/bin/chmod", ["+x", script.path])
        return .success(script)
    }

    /// Both apps signed, validly, with the same leaf certificate (a self-signed one is compared as is).
    nonisolated static func sameSigner(_ a: URL, _ b: URL) -> Bool {
        func leaf(_ u: URL) -> Data? {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(u as CFURL, [], &code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess else { return nil }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let d = info as? [String: Any], let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate],
                  let first = certs.first else { return nil }
            return SecCertificateCopyData(first) as Data
        }
        guard let x = leaf(a), let y = leaf(b) else { return false }
        return x == y
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static func relaunch(with script: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try? p.run()                                         // keeps running after this app quits
        AppDelegate.model?.flushForQuit()                    // pending sidecar saves are written first
        NSLog("Kestrel update: quitting to install")
        NSApp.terminate(nil)
        // a sheet or a background launch can leave terminate unanswered; the swap waits for this process to end
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    }
}

/// The update sheet: what's new, Install and Relaunch / Later / Skip This Version; progress while it installs.
struct UpdateView: View {
    @ObservedObject var updater: Updater
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text("You have \(Updater.currentVersion).").font(.caption).foregroundStyle(.secondary)
                }
            }
            switch updater.phase {
            case .available(let r):
                ScrollView { Text(Self.whatsNew(r.notes)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: 220)
                HStack {                                 // labels never shortened: the sheet is wide enough for all four
                    Button("Skip This Version") { updater.skip(r); close() }.help("Don't offer this version again; a later one will still be offered").fixedSize()
                    Button("Release Page") { NSWorkspace.shared.open(r.page) }.help("Open the release on GitHub in the browser").fixedSize()
                    Spacer()
                    Button("Later") { updater.phase = .idle; close() }.help("Ask again at the next check").fixedSize()
                    Button("Install and Relaunch") { updater.install(r) }.help("Download, check its checksum and signature, replace this copy (the old one goes to the Trash) and restart").keyboardShortcut(.defaultAction).fixedSize()
                }
            case .downloading(let f):
                ProgressView(value: f) { Text("Downloading…").font(.caption) }
                HStack { Spacer(); Button("Cancel") { updater.cancel(); close() } }
            case .installing:
                ProgressView { Text("Checking and installing…").font(.caption) }
            case .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                Text("Kestrel \(Updater.currentVersion) is the newest version.").font(.callout)
                HStack { Spacer(); Button("OK") { updater.phase = .idle; close() }.keyboardShortcut(.defaultAction) }
            case .failed(let why):
                Text(why).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("OK") { updater.phase = .idle; close() }.keyboardShortcut(.defaultAction) }
            case .idle:
                HStack { Spacer(); Button("Close") { close() } }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var title: String {
        switch updater.phase {
        case .available(let r): "Kestrel \(r.version) is available"
        case .downloading, .installing: "Updating Kestrel"
        case .checking: "Checking for updates…"
        case .upToDate: "You're up to date"
        case .failed: "Update"
        case .idle: "Updates"
        }
    }

    /// The release notes without the install paragraph and the checksum line, Markdown markers stripped.
    static func whatsNew(_ notes: String) -> String {
        notes.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("**Install:**") && !$0.hasPrefix("SHA-256") }
            .map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "## ", with: "") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
