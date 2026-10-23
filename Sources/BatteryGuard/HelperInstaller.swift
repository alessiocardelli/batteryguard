import Foundation
import SMCKit

enum HelperInstaller {
    enum Outcome {
        case success
        case cancelled
        case failed(String)
    }

    static let label = "com.alessiocardelli.batteryguard.helper"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"

    private static let environment = ProcessInfo.processInfo.environment

    /// Solo per provare l'interfaccia senza installare nulla: finge il servizio attivo e non scrive la soglia.
    static let isDebugInstalled = environment["BATTERYGUARD_DEBUG_INSTALLED"] == "1"

    /// Solo per provare il primo avvio su un Mac dove il servizio c'è già: lo finge assente.
    static let isDebugNotInstalled = environment["BATTERYGUARD_DEBUG_NOT_INSTALLED"] == "1"

    /// Solo per provare il rilevamento: launchctl trattato come illeggibile e battito letto da un file a scelta.
    static let isDebugLaunchctlUnreadable = environment["BATTERYGUARD_DEBUG_LAUNCHCTL_UNREADABLE"] == "1"
    static let statusPath = environment["BATTERYGUARD_DEBUG_STATUS_FILE"] ?? ServiceStatus.path

    /// Installato = plist e binario presenti. Attivo = battito recente o launchd che lo dà in esecuzione.
    /// launchctl da solo non basta: il suo output non è un'interfaccia stabile e può cambiare tra versioni di macOS.
    static func checkHealth() -> ServiceHealth {
        if isDebugInstalled { return .running }
        if isDebugNotInstalled { return .notInstalled }
        let files = FileManager.default
        let filesPresent = files.fileExists(atPath: plistPath) && files.fileExists(atPath: helperPath)
        guard filesPresent else { return .notInstalled }
        return ServiceHealth.evaluate(
            filesPresent: true,
            status: ServiceStatus.read(from: statusPath),
            launchdRunning: launchdSaysRunning,
            now: Date()
        )
    }

    /// Il dominio system si legge senza root (man launchctl, macOS 26.5: "Anyone may read or query the system domain").
    private static var launchdSaysRunning: Bool {
        if isDebugLaunchctlUnreadable { return false }
        let result = run("/bin/launchctl", ["print", "system/\(label)"])
        return result.status == 0 && result.output.contains("state = running")
    }

    private static func resource(_ name: String) -> String {
        Bundle.main.resourceURL?.appendingPathComponent(name).path ?? name
    }

    private static var bundledHelper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/batteryguard-helper").path
    }

    /// Dopo un aggiornamento dell'app il servizio installato può essere quello vecchio: si confrontano i binari.
    static func serviceNeedsUpdate() -> Bool {
        if isDebugInstalled || isDebugNotInstalled { return false }
        return ServiceUpdate.isNeeded(
            installedHash: Checksum.sha256(ofFile: URL(fileURLWithPath: helperPath)),
            bundledHash: Checksum.sha256(ofFile: URL(fileURLWithPath: bundledHelper))
        )
    }

    static func install(limit: Int) -> Outcome {
        runPrivileged(script: resource("install.sh"), arguments: [bundledHelper, String(limit), String(getuid())])
    }

    static func uninstall() -> Outcome {
        runPrivileged(script: resource("uninstall.sh"), arguments: [])
    }

    /// Riscrive il file sul posto: la cartella è di root, quindi una scrittura atomica (file temporaneo + rename) non è permessa.
    static func writeLimit(_ limit: Int) throws {
        if isDebugInstalled { return }
        try LimitConfig.serialize(limit).write(toFile: LimitConfig.path, atomically: false, encoding: .utf8)
    }

    /// I percorsi passano come argv di osascript e vengono quotati da AppleScript,
    /// così spazi o caratteri strani nel percorso del bundle (es. App Translocation) non rompono il comando.
    private static func runPrivileged(script: String, arguments: [String]) -> Outcome {
        let appleScript = """
        on run argv
            set cmd to "/bin/sh"
            repeat with arg in argv
                set cmd to cmd & " " & quoted form of (arg as text)
            end repeat
            do shell script cmd with administrator privileges
        end run
        """
        let result = run("/usr/bin/osascript", ["-e", appleScript, script] + arguments)
        if result.status == 0 { return .success }
        // -128 è il codice AppleScript di "Annulla" nel dialogo della password
        if result.output.contains("(-128)") { return .cancelled }
        return .failed(result.output)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}
