// Battito del servizio e stato visto dall'app: decide se mostrare "attivo", "non risponde" o lo stato 1.
// Si compila insieme a ServiceStatus.swift con scripts/test.sh: XCTest non c'è nei Command Line Tools.

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, _ line: UInt = #line) {
    if !condition {
        failures += 1
        print("FALLITO riga \(line): \(message)")
    }
}

let now = Date(timeIntervalSince1970: 1_800_000_000)

// Lettura del file
let full = ServiceStatus.parse("updated=1800000000\nstate=running\nscheme=CHTE\nerror=errore SMC: chiave CHTE assente\n")
check(full == ServiceStatus(updated: now, state: .running, scheme: "CHTE", error: "errore SMC: chiave CHTE assente"), "file completo: \(String(describing: full))")
check(ServiceStatus.parse("updated=1800000000\nstate=failed\n")?.error == nil, "senza errore")
check(ServiceStatus.parse("updated=1800000000\nstate=running\nerror=\n")?.error == nil, "errore vuoto = nessun errore")
check(ServiceStatus.parse("") == nil, "file vuoto")
check(ServiceStatus.parse("updated=1800000000\n") == nil, "senza stato")
check(ServiceStatus.parse("state=running\n") == nil, "senza ora")
check(ServiceStatus.parse("updated=ieri\nstate=running\n") == nil, "ora illeggibile")
check(ServiceStatus.parse("updated=nan\nstate=running\n") == nil, "ora non finita")
check(ServiceStatus.parse("updated=1800000000\nstate=boh\n") == nil, "stato sconosciuto")
check(ServiceStatus.parse("updated=18000") == nil, "scrittura a metà")

// Andata e ritorno, con un errore su più righe che non deve rompere il formato
let multiline = ServiceStatus(updated: now, state: .failed, scheme: nil, error: "riga uno\nriga due")
check(ServiceStatus.parse(multiline.serialize()) == ServiceStatus(updated: now, state: .failed, error: "riga uno riga due"), "errore su più righe: \(multiline.serialize().debugDescription)")

// Freschezza: sotto i 30 secondi, in entrambe le direzioni (orologio spostato)
let running = ServiceStatus(updated: now, state: .running)
check(running.isFresh(at: now.addingTimeInterval(29)), "29 s fa")
check(!running.isFresh(at: now.addingTimeInterval(30)), "30 s fa")
check(!running.isFresh(at: now.addingTimeInterval(3600)), "un'ora fa")
check(running.isFresh(at: now.addingTimeInterval(-10)), "orologio indietro di 10 s")

// Stato visto dall'app
func health(_ files: Bool, _ status: ServiceStatus?, _ launchd: Bool, at time: Date = now) -> ServiceHealth {
    ServiceHealth.evaluate(filesPresent: files, status: status, launchdRunning: launchd, now: time)
}
let stale = ServiceStatus(updated: now.addingTimeInterval(-120), state: .running, error: "errore SMC: x")
let failed = ServiceStatus(updated: now, state: .failed, error: "avvio non riuscito: chiave CHTE / CH0B / CH0C assente")
let stopped = ServiceStatus(updated: now, state: .stopped)

check(health(false, running, true) == .notInstalled, "file mancanti = non installato anche con battito")
check(health(true, running, false) == .running, "launchctl illeggibile ma battito recente = attivo")
check(health(true, nil, true) == .running, "servizio di una versione precedente (niente battito) = attivo")
check(health(true, stale, true) == .running, "battito vecchio ma launchd running = attivo")
check(health(true, stale, false) == .notResponding(lastError: "errore SMC: x"), "battito vecchio = non risponde, con l'ultimo errore")
check(health(true, nil, false) == .notResponding(lastError: nil), "niente battito e launchctl muto = non risponde")
check(health(true, failed, true) == .notResponding(lastError: failed.error), "avvio fallito recente vince su launchd")
check(health(true, stopped, false) == .notResponding(lastError: nil), "fermato e non rilanciato = non risponde")

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("ServiceStatus: tutti i test passati")
