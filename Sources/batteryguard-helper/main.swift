import Foundation
import SMCKit

// Ciclo breve: la soglia cambiata dall'app viene applicata entro pochi secondi
let pollInterval: TimeInterval = 5

setvbuf(stdout, nil, _IOLBF, 0)

let environment = ProcessInfo.processInfo.environment
/// Solo per le prove: percorso di un profilo JSON (Tests/fixtures/smc-profiles) da usare al posto dell'SMC vero.
/// Serve dove non c'è batteria (macchine virtuali). Con il finto SMC non serve root e nessuna chiave vera viene toccata.
let fakeProfilePath = environment["BATTERYGUARD_FAKE_SMC"]
/// Il battito si può spostare solo in modalità di prova, per girare senza root
let statusPath = fakeProfilePath == nil ? ServiceStatus.path : environment["BATTERYGUARD_DEBUG_STATUS_FILE"] ?? ServiceStatus.path

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("errore: \(message)\n".utf8))
    exit(1)
}

let fakeSMC: FakeSMC? = fakeProfilePath.map { path in
    do { return try FakeSMC(profileAt: path) } catch { fail("profilo finto non leggibile (\(path)): \(error)") }
}

func requireRoot() {
    if fakeSMC == nil && geteuid() != 0 { fail("serve root (sudo)") }
}

func makeSMC() throws -> SMCAccess {
    if let fakeSMC { return fakeSMC }
    return try SMC()
}

func makeControl() -> ChargingControl {
    do { return try ChargingControl(smc: makeSMC()) } catch { fail("\(error)") }
}

/// Con il finto SMC la carica simulata avanza con il tempo vero e l'app la legge da un file accanto al battito
var lastFakeAdvance = Date()
func readBattery() -> BatteryStatus? {
    guard let fakeSMC else { return Battery.read() }
    let now = Date()
    fakeSMC.advance(by: now.timeIntervalSince(lastFakeAdvance))
    lastFakeAdvance = now
    try? FakeBatterySnapshot.serialize(fakeSMC.battery)
        .write(toFile: FakeBatterySnapshot.path(nextTo: statusPath), atomically: true, encoding: .utf8)
    return fakeSMC.battery
}

/// Il file è scrivibile dall'utente: un valore illeggibile o fuori range (anche una scrittura
/// a metà letta nel momento sbagliato) non deve mai cambiare la soglia, si tiene l'ultima valida.
var lastValidLimit = LimitConfig.defaultLimit

func readLimit() -> Int {
    if let value = LimitConfig.read() {
        if value != lastValidLimit { log("soglia aggiornata: \(value)%") }
        lastValidLimit = value
    }
    return lastValidLimit
}

var statusWriteFailed = false

/// Scrittura atomica (file temporaneo + rename) nella cartella di root: l'app non legge mai un file a metà.
func writeStatus(_ state: ServiceStatus.State, scheme: String?, error: ServiceError?) {
    let status = ServiceStatus(updated: Date(), state: state, scheme: scheme, error: error)
    do {
        try Data(status.serialize().utf8).write(to: URL(fileURLWithPath: statusPath), options: .atomic)
        chmod(statusPath, 0o644)
        if statusWriteFailed { log("battito di nuovo scritto") }
        statusWriteFailed = false
    } catch {
        // Una riga sola, non una ogni 5 secondi
        if !statusWriteFailed { log("battito non scritto: \(error.localizedDescription)") }
        statusWriteFailed = true
    }
}

/// Sola lettura: è il comando da far lanciare a chi segnala un Mac non supportato
func probe() {
    let smc: SMCAccess
    do { smc = try makeSMC() } catch { fail("\(error)") }
    SMCProbe.lines(smc).forEach { print($0) }
}

func status() {
    let control = makeControl()
    let limit = LimitConfig.read() ?? LimitConfig.defaultLimit
    print("schema SMC:        \(control.scheme.rawValue)")
    if control.scheme == .firmware {
        print("limite firmware:   \(ChargingControl.describe(try? control.readFirmwareLimit()))")
    } else if let enabled = try? control.isChargingEnabled() {
        print("ricarica SMC:      \(enabled ? "abilitata" : "bloccata")")
    }
    print("soglia:            \(limit)% (riprende a \(limit - ChargeLoop.hysteresis)%)")
    if let battery = readBattery() {
        print("batteria:          \(battery.percent)%")
        print("alimentatore:      \(battery.externalConnected ? "collegato" : "scollegato")")
        print("in carica:         \(battery.isCharging ? "sì" : "no")")
    }
}

/// enable-charging lo usa anche uninstall.sh: con lo schema firmware spegne il limite del firmware
func enableCharging() {
    requireRoot()
    let control = makeControl()
    do { try control.restoreNormalCharging() } catch { fail("\(error)") }
    print("ricarica normale ripristinata (\(control.scheme.rawValue))")
}

func disableCharging() {
    requireRoot()
    let control = makeControl()
    do { try control.setChargingEnabled(false) } catch { fail("\(error)") }
    print("ricarica bloccata (\(control.scheme.rawValue))")
}

func runDaemon() -> Never {
    requireRoot()
    if let fakeProfilePath { log("modalità di prova: finto SMC dal profilo \(fakeProfilePath)") }
    let control: ChargingControl
    do {
        control = try ChargingControl(smc: makeSMC())
    } catch {
        // launchd lo rilancia: il motivo resta nel log e nel battito, l'app mostra "non disponibile"
        let code: ServiceErrorCode = error is ChargingControlError ? .noChargeKeys : .smcUnavailable
        log("errore \(code.rawValue): \(error)")
        writeStatus(.failed, scheme: nil, error: ServiceError(code, detail: "\(error)"))
        exit(1)
    }
    let loop = ChargeLoop(control: control, log: log)
    let scheme = control.scheme.rawValue
    lastValidLimit = LimitConfig.read() ?? LimitConfig.defaultLimit
    log("avvio, schema \(scheme), soglia \(lastValidLimit)%")

    // Sicurezza: qualunque uscita pulita (launchctl bootout, kill) torna alla ricarica normale,
    // anche con lo schema firmware: il limite resterebbe attivo pure a servizio disinstallato
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            _ = try? control.restoreNormalCharging()
            log("segnale \(sig): ricarica normale ripristinata, uscita")
            writeStatus(.stopped, scheme: scheme, error: loop.lastError)
            exit(0)
        }
        source.resume()
        sources.append(source)
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: pollInterval)
    timer.setEventHandler {
        loop.tick(battery: readBattery(), limit: readLimit(), now: Date())
        writeStatus(loop.state, scheme: scheme, error: loop.lastError)
    }
    timer.resume()

    withExtendedLifetime((sources, timer)) { dispatchMain() }
}

let usage = """
uso: batteryguard-helper <comando>
  probe              legge le chiavi SMC di ricarica (non serve root)
  status             stato batteria, ricarica e soglia
  daemon             ciclo di controllo (root, lanciato da launchd)
  enable-charging    ricarica normale; schema firmware: spegne il limite (root)
  disable-charging   blocca la ricarica (root, solo schemi legacy, per test)

solo prove: BATTERYGUARD_FAKE_SMC=<profilo.json> usa un finto SMC (niente root);
BATTERYGUARD_DEBUG_STATUS_FILE=<file> sposta il battito (solo con il finto SMC)
"""

switch CommandLine.arguments.dropFirst().first {
case "probe": probe()
case "status": status()
case "daemon": runDaemon()
case "enable-charging": enableCharging()
case "disable-charging": disableCharging()
default:
    print(usage)
    exit(2)
}
