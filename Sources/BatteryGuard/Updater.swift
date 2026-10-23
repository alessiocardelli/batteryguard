import AppKit
import os

/// Aggiornamenti dentro l'app: controllo su GitHub al massimo una volta al giorno, download dello zip della release,
/// verifiche (SHA256, identità del bundle, firma) e sostituzione del bundle dopo l'uscita, con riapertura.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case available(AvailableUpdate)
        case updating(AvailableUpdate)
        case failed(AvailableUpdate, message: String)
    }

    @Published private(set) var state: State = .idle

    private static let feedURL = URL(string: "https://api.github.com/repos/alessiocardelli/batteryguard/releases/latest")!
    private static let lastCheckKey = "updateLastCheck"
    private static let lastReleaseKey = "updateLastRelease"
    private nonisolated static let log = Logger(subsystem: "com.alessiocardelli.batteryguard", category: "update")

    /// Solo per provare l'aggiornamento senza pubblicare: URL di un JSON nel formato di GitHub (anche http locale).
    /// Con il feed di prova si controlla a ogni avvio, gli asset possono stare su qualunque host e non si tocca la cache.
    private static let debugFeedURL = ProcessInfo.processInfo.environment["BATTERYGUARD_DEBUG_UPDATE_FEED"].flatMap(URL.init(string:))

    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let defaults = UserDefaults.standard
    private var isChecking = false
    private var timer: Timer?

    /// Effimera: niente cookie né cache su disco, la richiesta porta solo gli header standard e lo User-Agent.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "BatteryGuard/\(currentVersion)"]
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    func start() {
        // Una release trovata da un controllo recente resta proposta anche dopo un riavvio dell'app
        if Self.debugFeedURL == nil, let data = defaults.data(forKey: Self.lastReleaseKey) {
            show(GitHubRelease.decode(data))
        }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            guard let updater = self else { return }
            Task { @MainActor in updater.checkIfDue() }
        }
    }

    /// Chiamato anche all'apertura del pannello: parte solo se l'ultimo controllo ha più di 24 ore.
    func checkIfDue() {
        let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date
        guard Self.debugFeedURL != nil || UpdatePolicy.shouldCheck(lastCheck: lastCheck, now: Date()) else { return }
        check()
    }

    private func check() {
        guard !isChecking else { return }
        if case .updating = state { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            var request = URLRequest(url: Self.debugFeedURL ?? Self.feedURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            // Errori di rete silenziosi: si riprova al prossimo controllo dovuto
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { return }
            if Self.debugFeedURL == nil {
                defaults.set(Date(), forKey: Self.lastCheckKey)
            }
            guard http.statusCode == 200, let release = GitHubRelease.decode(data) else { return }
            if Self.debugFeedURL == nil {
                defaults.set(data, forKey: Self.lastReleaseKey)
            }
            show(release)
        }
    }

    private func show(_ release: GitHubRelease?) {
        if case .updating = state { return }
        guard let release, let update = UpdatePolicy.availableUpdate(from: release, currentVersion: currentVersion) else {
            state = .idle
            return
        }
        if case .failed(let previous, _) = state, previous == update { return }
        Self.log.info("aggiornamento disponibile: \(update.version, privacy: .public)")
        state = .available(update)
    }

    /// Da un percorso traslocato (app aperta dove è stata scaricata) la sostituzione finirebbe in una copia temporanea.
    var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    func install() {
        let update: AvailableUpdate
        switch state {
        case .available(let value), .failed(let value, _): update = value
        case .idle, .updating: return
        }
        let bundleURL = Bundle.main.bundleURL
        if isTranslocated {
            state = .failed(update, message: String(localized: "To update from here, move BatteryGuard to Applications and open it again."))
            return
        }
        // Per spostare il bundle servono permessi sulla cartella che lo contiene e sul bundle stesso.
        // Niente sudo: se l'utente non può scrivere lì, si rimanda al sito
        let files = FileManager.default
        guard files.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path),
              files.isWritableFile(atPath: bundleURL.path) else {
            state = .failed(update, message: String(localized: "BatteryGuard can’t replace itself in this folder. Download the new version from batteryguard.alessiocardelli.com."))
            return
        }
        state = .updating(update)
        Task {
            do {
                let newApp = try await prepare(update)
                try relaunch(replacing: bundleURL, with: newApp)
            } catch let error as UpdateError {
                Self.log.error("aggiornamento non riuscito: \(error.logDescription, privacy: .public)")
                state = .failed(update, message: error.message)
            } catch {
                Self.log.error("aggiornamento non riuscito: \(error.localizedDescription, privacy: .public)")
                state = .failed(update, message: UpdateError.download.message)
            }
        }
    }

    // MARK: Download e verifiche

    private enum UpdateError: Error {
        case download
        case checksum
        case invalidApp(String)
        case replace(String)

        var message: String {
            switch self {
            case .download: return String(localized: "The download didn’t complete. Try again later.")
            case .checksum: return String(localized: "The downloaded file doesn’t match its checksum.")
            case .invalidApp: return String(localized: "The downloaded app didn’t pass the checks.")
            case .replace: return String(localized: "Couldn’t start the update.")
            }
        }

        var logDescription: String {
            switch self {
            case .download: return "download"
            case .checksum: return "checksum"
            case .invalidApp(let detail): return "app non valida: \(detail)"
            case .replace(let detail): return "sostituzione: \(detail)"
            }
        }
    }

    /// Ritorna il bundle nuovo, estratto e verificato, dentro una cartella temporanea.
    private func prepare(_ update: AvailableUpdate) async throws -> URL {
        if Self.debugFeedURL == nil {
            guard UpdatePolicy.isTrustedDownloadURL(update.zipURL),
                  UpdatePolicy.isTrustedDownloadURL(update.checksumsURL) else { throw UpdateError.download }
        }
        let files = FileManager.default
        let work = files.temporaryDirectory.appendingPathComponent("BatteryGuard-update-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            let zip = try await download(update.zipURL, to: work.appendingPathComponent(update.zipName))
            let sums = try await download(update.checksumsURL, to: work.appendingPathComponent(UpdatePolicy.checksumsName))

            let bundleID = Bundle.main.bundleIdentifier
            // ditto, codesign e l'hash sono lavoro sincrono: fuori dal main thread
            return try await Task.detached {
                try Self.unpackAndVerify(zip: zip, sums: sums, update: update, work: work, bundleID: bundleID)
            }.value
        } catch {
            try? files.removeItem(at: work)
            throw error
        }
    }

    private nonisolated static func unpackAndVerify(zip: URL, sums: URL, update: AvailableUpdate, work: URL, bundleID: String?) throws -> URL {
        // L'app non dichiara LSFileQuarantineEnabled: URLSession non dovrebbe mettere la quarantena. Si registra cosa succede davvero
        log.info("quarantena sullo zip scaricato: \(hasQuarantine(zip) ? "sì" : "no", privacy: .public)")

        guard let sumsText = try? String(contentsOf: sums, encoding: .utf8),
              let expected = Checksum.expectedSHA256(in: sumsText, for: update.zipName),
              let zipData = try? Data(contentsOf: zip),
              Checksum.matches(zipData, expected: expected) else { throw UpdateError.checksum }

        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        let ditto = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
        guard ditto.status == 0 else { throw UpdateError.invalidApp("ditto: \(ditto.output)") }
        let newApp = extracted.appendingPathComponent("\(UpdatePolicy.appName).app", isDirectory: true)
        try verify(newApp, expectedVersion: update.version, bundleID: bundleID)

        // Solo sul bundle già verificato, e solo se la quarantena c'è
        if hasQuarantine(newApp) {
            let xattr = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            log.info("quarantena rimossa dal bundle nuovo: \(xattr.status == 0 ? "sì" : xattr.output, privacy: .public)")
        } else {
            log.info("bundle nuovo senza quarantena")
        }
        return newApp
    }

    private func download(_ url: URL, to destination: URL) async throws -> URL {
        let (temporary, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.download
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private nonisolated static func verify(_ app: URL, expectedVersion: String, bundleID: String?) throws {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = plist as? [String: Any] else { throw UpdateError.invalidApp("Info.plist illeggibile") }
        let identifier = info["CFBundleIdentifier"] as? String
        let version = info["CFBundleShortVersionString"] as? String
        guard let bundleID, identifier == bundleID else {
            throw UpdateError.invalidApp("identificativo \(identifier ?? "-")")
        }
        guard version == expectedVersion else { throw UpdateError.invalidApp("versione \(version ?? "-")") }
        let codesign = Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard codesign.status == 0 else { throw UpdateError.invalidApp("codesign: \(codesign.output)") }
    }

    /// Cerca l'attributo anche dentro il bundle: basta un file in quarantena per far intervenire Gatekeeper.
    private nonisolated static func hasQuarantine(_ url: URL) -> Bool {
        let name = "com.apple.quarantine"
        if getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
        guard let enumerator = FileManager.default.enumerator(atPath: url.path) else { return false }
        for case let relative as String in enumerator {
            let path = url.appendingPathComponent(relative).path
            if getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 { return true }
        }
        return false
    }

    // MARK: Sostituzione

    /// Lo script aspetta l'uscita di questo processo, scambia i bundle e riapre l'app. Si lancia staccato:
    /// i processi figli sopravvivono all'uscita dell'app (vengono adottati da launchd).
    private func relaunch(replacing bundleURL: URL, with newApp: URL) throws {
        guard let script = Bundle.main.url(forResource: "update", withExtension: "sh") else {
            throw UpdateError.replace("update.sh assente")
        }
        let work = newApp.deletingLastPathComponent().deletingLastPathComponent()
        // Copia nella cartella temporanea: l'originale sta nel bundle che lo script sposta
        let scriptCopy = work.appendingPathComponent("update.sh")
        do {
            try FileManager.default.copyItem(at: script, to: scriptCopy)
        } catch {
            throw UpdateError.replace(error.localizedDescription)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptCopy.path, String(getpid()), bundleURL.path, newApp.path, work.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.replace(error.localizedDescription)
        }
        Self.log.info("sostituzione avviata: \(bundleURL.path, privacy: .public)")
        NSApp.terminate(nil)
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
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
