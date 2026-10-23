import Foundation
import SMCKit

let hysteresis = 2
// Ciclo breve: la soglia cambiata dall'app viene applicata entro pochi secondi
let pollInterval: TimeInterval = 5
let probeKeys = FirmwareLimit.keys + ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "BUIC", "B0RM"]
/// Se il firmware rifiuta le soglie non si riprova a ogni ciclo: bfF0 verrebbe spento e riacceso ogni 5 secondi
let firmwareRetryDelay: TimeInterval = 60

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("errore: \(message)\n".utf8))
    exit(1)
}

func requireRoot() {
    if geteuid() != 0 { fail("serve root (sudo)") }
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

// Battito per l'app: stato, schema e ultimo errore, riscritto a ogni ciclo
var currentScheme: String?
var lastError: ServiceError?
var statusWriteFailed = false

/// Lo stesso errore a ogni ciclo va nel log una volta sola
func recordError(_ code: ServiceErrorCode, _ detail: String) {
    let error = ServiceError(code, detail: detail)
    if error != lastError { log("errore \(code.rawValue): \(detail)") }
    lastError = error
}

/// Scrittura atomica (file temporaneo + rename) nella cartella di root: l'app non legge mai un file a metà.
func writeStatus(_ state: ServiceStatus.State) {
    let status = ServiceStatus(updated: Date(), state: state, scheme: currentScheme, error: lastError)
    do {
        try Data(status.serialize().utf8).write(to: URL(fileURLWithPath: ServiceStatus.path), options: .atomic)
        chmod(ServiceStatus.path, 0o644)
        if statusWriteFailed { log("battito di nuovo scritto") }
        statusWriteFailed = false
    } catch {
        // Una riga sola, non una ogni 5 secondi
        if !statusWriteFailed { log("battito non scritto: \(error.localizedDescription)") }
        statusWriteFailed = true
    }
}

func makeControl() -> ChargingControl {
    do { return try ChargingControl() } catch { fail("\(error)") }
}

/// Sola lettura: è il comando da far lanciare a chi segnala un Mac non supportato
func probe() {
    let smc: SMC
    do { smc = try SMC() } catch { fail("\(error)") }
    for key in probeKeys {
        do {
            let value = try smc.read(key)
            var line = "\(key)  tipo=\(value.type)  byte=\(value.bytes.count)  valore=\(value.hex)"
            if key == FirmwareLimit.upperKey || key == FirmwareLimit.lowerKey,
               let percent = FirmwareLimit.decodePercent(value.bytes) {
                line += "  (\(percent)%)"
            }
            print(line)
        } catch {
            print("\(key)  \(error)")
        }
    }
    let scheme = ChargingScheme.detect(keySize: smc.dataSize)
    print("schema rilevato: \(scheme?.rawValue ?? "nessuno (non supportato)")")
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
    print("soglia:            \(limit)% (riprende a \(limit - hysteresis)%)")
    if let battery = Battery.read() {
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

func tick(_ control: ChargingControl) {
    defer { writeStatus(.running) }
    if control.scheme == .firmware { return firmwareTick(control) }
    guard let battery = Battery.read() else { return recordError(.batteryUnreadable, "IOPowerSources returned no battery") }
    let limit = readLimit()
    do {
        let enabled = try control.isChargingEnabled()
        if limit >= 100 {
            if !enabled {
                try control.setChargingEnabled(true)
                log("soglia 100%: ricarica riabilitata")
            }
        } else if enabled && battery.percent >= limit {
            try control.setChargingEnabled(false)
            log("batteria \(battery.percent)% >= \(limit)%: ricarica bloccata")
        } else if !enabled && battery.percent <= limit - hysteresis {
            try control.setChargingEnabled(true)
            log("batteria \(battery.percent)% <= \(limit - hysteresis)%: ricarica ripresa")
        }
    } catch {
        recordError(.smcFailed, "\(error)")
    }
}

var firmwareRetryAfter: Date?
/// Ultimo limite firmware scritto da noi: se lo ritroviamo diverso l'ha cambiato qualcun altro (anche macOS)
var appliedFirmwareLimit: (upper: Int, lower: Int)?

/// Il firmware tiene la carica tra lower e upper anche quando il servizio non gira (sonno compreso):
/// qui si controlla soltanto che le soglie siano ancora quelle giuste.
func firmwareTick(_ control: ChargingControl) {
    if let retry = firmwareRetryAfter, Date() < retry { return }
    firmwareRetryAfter = nil
    let limit = readLimit()
    do {
        if limit >= 100 {
            if try control.restoreNormalCharging() { log("soglia 100%: limite firmware disattivato") }
            appliedFirmwareLimit = nil
            return
        }
        let target = (upper: limit, lower: limit - hysteresis)
        let result = try control.ensureFirmwareLimit(upper: target.upper, lower: target.lower)
        guard result.changed else { return }
        let previous = ChargingControl.describe(result.previous)
        if let applied = appliedFirmwareLimit, applied == target {
            log("limite firmware cambiato da fuori (\(previous)): ripristinato \(target.lower)-\(target.upper)%")
        } else {
            log("limite firmware impostato: \(target.lower)-\(target.upper)% (prima: \(previous))")
        }
        appliedFirmwareLimit = target
    } catch let error as ChargingControlError {
        if case .firmwareRejected = error {
            firmwareRetryAfter = Date().addingTimeInterval(firmwareRetryDelay)
            recordError(.firmwareRejected, "\(error)")
        } else {
            recordError(.smcFailed, "\(error)")
        }
    } catch {
        recordError(.smcFailed, "\(error)")
    }
}

func runDaemon() -> Never {
    requireRoot()
    let control: ChargingControl
    do {
        control = try ChargingControl()
    } catch {
        // launchd lo rilancia: il motivo resta nel log e nel battito, così l'app lo può mostrare
        let code: ServiceErrorCode = error is ChargingControlError ? .noChargeKeys : .smcUnavailable
        recordError(code, "\(error)")
        writeStatus(.failed)
        exit(1)
    }
    currentScheme = control.scheme.rawValue
    lastValidLimit = LimitConfig.read() ?? LimitConfig.defaultLimit
    log("avvio, schema \(control.scheme.rawValue), soglia \(lastValidLimit)%")

    // Sicurezza: qualunque uscita pulita (launchctl bootout, kill) torna alla ricarica normale,
    // anche con lo schema firmware: il limite resterebbe attivo pure a servizio disinstallato
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            _ = try? control.restoreNormalCharging()
            log("segnale \(sig): ricarica normale ripristinata, uscita")
            writeStatus(.stopped)
            exit(0)
        }
        source.resume()
        sources.append(source)
    }

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: pollInterval)
    timer.setEventHandler { tick(control) }
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
