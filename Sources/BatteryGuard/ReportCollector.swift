import Foundation
import SMCKit

/// Raccoglie i dati della segnalazione senza privilegi: l'SMC si legge da utente, battito e log sono leggibili da tutti.
enum ReportCollector {
    static let logPath = "/Library/Logs/BatteryGuard/helper.log"
    static let logLines = 20

    static func collect() -> String {
        let info = ReportInfo(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            osVersion: osVersion,
            osBuild: sysctl("kern.osversion"),
            model: sysctl("hw.model"),
            chip: sysctl("machdep.cpu.brand_string"),
            probe: probe(),
            heartbeat: try? String(contentsOfFile: HelperInstaller.statusPath, encoding: .utf8),
            logTail: tail(of: logPath, lines: logLines)
        )
        return Report.anonymize(
            Report.text(info),
            home: NSHomeDirectory(),
            userName: NSUserName(),
            fullName: NSFullUserName(),
            computerNames: [Host.current().localizedName, ProcessInfo.processInfo.hostName].compactMap { $0 }
        )
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private static func probe() -> [String] {
        do {
            let smc: SMCAccess
            if let profile = HelperInstaller.fakeProfilePath {
                smc = try FakeSMC(profileAt: profile)
            } else {
                smc = try SMC()
            }
            return SMCProbe.lines(smc)
        } catch {
            return ["SMC not readable: \(error)"]
        }
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    /// Solo la coda del file: in mesi di uso il log del servizio può crescere parecchio
    private static func tail(of path: String, lines count: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return Array(lines.suffix(count))
    }
}
