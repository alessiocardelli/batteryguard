// Battito del servizio e stato visto dall'app: decide se mostrare "attivo", "non disponibile" o lo stato 1.
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
let full = ServiceStatus.parse("updated=1800000000\nstate=failed\nscheme=firmware\nerror=no_charge_keys\ndetail=bfF0 absent, CHTE absent\n")
check(full == ServiceStatus(updated: now, state: .failed, scheme: "firmware", error: ServiceError(.noChargeKeys, detail: "bfF0 absent, CHTE absent")), "file completo: \(String(describing: full))")
check(full?.error?.knownCode == .noChargeKeys, "codice riconosciuto")
// Battito di un servizio 1.0.3: frase al posto del codice, niente dettaglio
let legacy = ServiceStatus.parse("updated=1800000000\nstate=failed\nerror=avvio non riuscito: chiave CHTE / CH0B / CH0C assente\n")
check(legacy?.error == ServiceError(code: "avvio non riuscito: chiave CHTE / CH0B / CH0C assente"), "battito 1.0.3")
check(legacy?.error?.knownCode == nil, "frase 1.0.3 = codice sconosciuto")
check(ServiceStatus.parse("updated=1800000000\nstate=failed\ndetail=solo dettaglio\n")?.error == nil, "dettaglio senza codice = nessun errore")
check(ServiceStatus.parse("updated=1800000000\nstate=failed\n")?.error == nil, "senza errore")
check(ServiceStatus.parse("updated=1800000000\nstate=running\nerror=\n")?.error == nil, "errore vuoto = nessun errore")
// Modalità adapter: il campo adapter dice se il servizio ha staccato l'alimentatore
let cutStatus = ServiceStatus(updated: now, state: .running, scheme: "adapter", adapterCut: true)
check(cutStatus.serialize().contains("adapter=cut\n"), "adapter=cut scritto")
check(ServiceStatus.parse(cutStatus.serialize()) == cutStatus, "andata e ritorno adapter=cut")
check(ServiceStatus.parse("updated=1800000000\nstate=running\nscheme=adapter\nadapter=attached\n")?.adapterCut == false, "adapter=attached")
check(ServiceStatus.parse("updated=1800000000\nstate=running\nscheme=adapter\nadapter=boh\n")?.adapterCut == nil, "valore sconosciuto = nessuna informazione")
check(!ServiceStatus(updated: now, state: .running, scheme: "CHTE").serialize().contains("adapter="), "altri schemi: niente campo adapter")
check(cutStatus.isOnBatteryByAdapterCut(at: now), "pannello: A batteria")
check(!cutStatus.isOnBatteryByAdapterCut(at: now.addingTimeInterval(60)), "battito vecchio: niente A batteria")
check(!ServiceStatus(updated: now, state: .running, scheme: "adapter", adapterCut: false).isOnBatteryByAdapterCut(at: now), "alimentatore collegato")
check(!ServiceStatus(updated: now, state: .failed, scheme: "adapter", adapterCut: true).isOnBatteryByAdapterCut(at: now), "servizio non disponibile")
check(!ServiceStatus(updated: now, state: .running, scheme: "CHTE", adapterCut: true).isOnBatteryByAdapterCut(at: now), "solo con lo schema adapter")
check(ServiceStatus.parse("") == nil, "file vuoto")
check(ServiceStatus.parse("updated=1800000000\n") == nil, "senza stato")
check(ServiceStatus.parse("state=running\n") == nil, "senza ora")
check(ServiceStatus.parse("updated=ieri\nstate=running\n") == nil, "ora illeggibile")
check(ServiceStatus.parse("updated=nan\nstate=running\n") == nil, "ora non finita")
check(ServiceStatus.parse("updated=1800000000\nstate=boh\n") == nil, "stato sconosciuto")
check(ServiceStatus.parse("updated=18000") == nil, "scrittura a metà")

// Andata e ritorno, con un errore su più righe che non deve rompere il formato
let multiline = ServiceStatus(updated: now, state: .failed, scheme: nil, error: ServiceError(.smcFailed, detail: "riga uno\nriga due"))
check(ServiceStatus.parse(multiline.serialize()) == ServiceStatus(updated: now, state: .failed, error: ServiceError(.smcFailed, detail: "riga uno riga due")), "dettaglio su più righe: \(multiline.serialize().debugDescription)")
check(multiline.serialize().contains("error=smc_failed\n"), "codice stabile nel file")
let noDetail = ServiceStatus(updated: now, state: .failed, error: ServiceError(.noChargeKeys))
check(ServiceStatus.parse(noDetail.serialize()) == noDetail, "codice senza dettaglio")

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
let stale = ServiceStatus(updated: now.addingTimeInterval(-120), state: .running, error: ServiceError(.smcFailed, detail: "x"))
let failed = ServiceStatus(updated: now, state: .failed, error: ServiceError(.noChargeKeys, detail: "CHTE absent"))
let stopped = ServiceStatus(updated: now, state: .stopped)

check(health(false, running, true) == .notInstalled, "file mancanti = non installato anche con battito")
check(health(true, running, false) == .running, "launchctl illeggibile ma battito recente = attivo")
check(health(true, nil, true) == .running, "servizio di una versione precedente (niente battito) = attivo")
check(health(true, stale, true) == .running, "battito vecchio ma launchd running = attivo")
check(health(true, stale, false) == .notResponding, "battito vecchio = non risponde")
check(health(true, nil, false) == .notResponding, "niente battito e launchctl muto = non risponde")
check(health(true, failed, true) == .failed, "servizio che si dichiara non disponibile vince su launchd")
check(health(true, failed, true, at: now.addingTimeInterval(120)) == .running, "battito failed vecchio con launchd running = attivo")
check(health(true, stopped, false) == .notResponding, "fermato e non rilanciato = non risponde")

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("ServiceStatus: tutti i test passati")
