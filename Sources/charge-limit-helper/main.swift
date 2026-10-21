import Foundation
import SMCKit

let configPath = "/Library/Application Support/ChargeLimit/config"
let defaultLimit = 80
let hysteresis = 2
let pollInterval: TimeInterval = 30
let probeKeys = ["CHTE", "CH0B", "CH0C", "CHIE", "CH0I", "CH0J", "BUIC", "B0RM"]

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

/// Config minimale: una riga `limit=NN`. Valori fuori range vengono riportati nei limiti.
func readLimit() -> Int {
    guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return defaultLimit }
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, parts[0] == "limit", let value = Int(parts[1]) {
            return min(max(value, 20), 100)
        }
    }
    return defaultLimit
}

func makeControl() -> ChargingControl {
    do { return try ChargingControl() } catch { fail("\(error)") }
}

func probe() {
    let smc: SMC
    do { smc = try SMC() } catch { fail("\(error)") }
    for key in probeKeys {
        do {
            let value = try smc.read(key)
            print("\(key)  tipo=\(value.type)  byte=\(value.bytes.count)  valore=\(value.hex)")
        } catch {
            print("\(key)  \(error)")
        }
    }
}

func status() {
    let control = makeControl()
    let limit = readLimit()
    print("schema SMC:        \(control.scheme.rawValue)")
    if let enabled = try? control.isChargingEnabled() {
        print("ricarica SMC:      \(enabled ? "abilitata" : "bloccata")")
    }
    print("soglia:            \(limit)% (riprende a \(limit - hysteresis)%)")
    if let battery = Battery.read() {
        print("batteria:          \(battery.percent)%")
        print("alimentatore:      \(battery.externalConnected ? "collegato" : "scollegato")")
        print("in carica:         \(battery.isCharging ? "sì" : "no")")
    }
}

func setCharging(_ enabled: Bool) {
    requireRoot()
    let control = makeControl()
    do { try control.setChargingEnabled(enabled) } catch { fail("\(error)") }
    print("ricarica \(enabled ? "abilitata" : "bloccata") (\(control.scheme.rawValue))")
}

func tick(_ control: ChargingControl) {
    guard let battery = Battery.read() else { return log("batteria non leggibile") }
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
        log("errore SMC: \(error)")
    }
}

func runDaemon() -> Never {
    requireRoot()
    let control = makeControl()
    log("avvio, schema \(control.scheme.rawValue), soglia \(readLimit())%")

    // Sicurezza: qualunque uscita pulita (launchctl bootout, kill) riabilita la ricarica
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            try? control.setChargingEnabled(true)
            log("segnale \(sig): ricarica riabilitata, uscita")
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
uso: charge-limit-helper <comando>
  probe              legge le chiavi SMC di ricarica (non serve root)
  status             stato batteria, ricarica e soglia
  daemon             ciclo di controllo (root, lanciato da launchd)
  enable-charging    riabilita la ricarica (root)
  disable-charging   blocca la ricarica (root, solo per test)
"""

switch CommandLine.arguments.dropFirst().first {
case "probe": probe()
case "status": status()
case "daemon": runDaemon()
case "enable-charging": setCharging(true)
case "disable-charging": setCharging(false)
default:
    print(usage)
    exit(2)
}
