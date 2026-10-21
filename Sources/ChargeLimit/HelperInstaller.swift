import Foundation

enum HelperInstaller {
    enum Action {
        case install(limit: Int)
        case uninstall
    }

    static let label = "com.alessiocardelli.chargelimit.helper"
    static let plistPath = "/Library/LaunchDaemons/\(label).plist"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    private static func resource(_ name: String) -> String {
        Bundle.main.resourceURL?.appendingPathComponent(name).path ?? name
    }

    private static var bundledHelper: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/charge-limit-helper").path
    }

    static func perform(_ action: Action) -> String {
        switch action {
        case .install(let limit):
            return runPrivileged(script: resource("install.sh"), arguments: [bundledHelper, String(limit)])
        case .uninstall:
            return runPrivileged(script: resource("uninstall.sh"), arguments: [])
        }
    }

    static func status() -> String {
        run(bundledHelper, ["status"])
    }

    /// I percorsi passano come argv di osascript e vengono quotati da AppleScript,
    /// così spazi o caratteri strani nel percorso del bundle (es. App Translocation) non rompono il comando.
    private static func runPrivileged(script: String, arguments: [String]) -> String {
        let appleScript = """
        on run argv
            set cmd to "/bin/sh"
            repeat with arg in argv
                set cmd to cmd & " " & quoted form of (arg as text)
            end repeat
            do shell script cmd with administrator privileges
        end run
        """
        return run("/usr/bin/osascript", ["-e", appleScript, script] + arguments)
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "errore avvio \(executable): \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return process.terminationStatus == 0 ? output : "uscita \(process.terminationStatus): \(output)"
    }
}
