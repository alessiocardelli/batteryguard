// Ciclo vero del servizio (ChargeLoop) sul finto SMC, un profilo per tipo di firmware.
// Si compila insieme a tutto SMCKit con scripts/test.sh; argomento: cartella dei profili.

import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, _ line: UInt = #line) {
    if !condition {
        failures += 1
        print("FALLITO riga \(line): \(message)")
    }
}

let profilesDir = CommandLine.arguments.dropFirst().first ?? "Tests/fixtures/smc-profiles"

func fake(_ name: String) -> FakeSMC {
    do { return try FakeSMC(profileAt: "\(profilesDir)/\(name).json") } catch {
        print("profilo \(name) non leggibile: \(error)")
        exit(1)
    }
}

/// Servizio simulato: come il demone, un ciclo ogni 5 secondi con la carica che avanza nel frattempo
final class Harness {
    let smc: FakeSMC
    let loop: ChargeLoop
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var limit = 80

    init(_ smc: FakeSMC, forceAdapter: Bool = false) throws {
        self.smc = smc
        loop = ChargeLoop(control: try ChargingControl(smc: smc, forceAdapter: forceAdapter)) { _ in }
    }

    /// Fa girare il servizio per `minutes` minuti e restituisce la carica minima e massima viste
    @discardableResult
    func run(minutes: Double) -> (min: Double, max: Double) {
        var low = smc.percent, high = smc.percent
        for _ in 0..<Int(minutes * 12) {
            loop.tick(battery: smc.battery, limit: limit, now: now)
            smc.advance(by: 5)
            now = now.addingTimeInterval(5)
            low = min(low, smc.percent)
            high = max(high, smc.percent)
        }
        return (low, high)
    }
}

// MARK: Profili con uno schema che funziona: attiva, si ferma alla soglia, riprende sotto, disattivazione

for (name, scheme) in [("chte", ChargingScheme.chte), ("ch0b-ch0c", .ch0bc), ("firmware-27", .firmware)] {
    let smc = fake(name)
    guard let harness = try? Harness(smc) else {
        check(false, "\(name): schema non rilevato")
        continue
    }
    check(harness.loop.control.scheme == scheme, "\(name): schema \(harness.loop.control.scheme)")

    // Attivazione con la carica al 70% e soglia 80: carica fino a 80 e si ferma lì
    let charging = harness.run(minutes: 5)
    check(charging.max >= 79, "\(name): la carica sale fino alla soglia (max \(charging.max))")
    check(charging.max <= 81, "\(name): la carica non supera la soglia (max \(charging.max))")
    let held = harness.run(minutes: 60)
    check(held.max <= 81 && held.min >= 77.5, "\(name): un'ora collegato resta alla soglia (\(held.min)-\(held.max))")
    check(!smc.isCharging, "\(name): ferma alla soglia")
    check(harness.loop.state == .running && harness.loop.lastError == nil, "\(name): nessun errore")

    // Sotto la soglia meno l'isteresi la ricarica riprende
    smc.pluggedIn = false
    harness.run(minutes: 2)
    check(smc.percent < 78, "\(name): scollegato scende (\(smc.percent))")
    smc.pluggedIn = true
    harness.run(minutes: 0.5)
    check(smc.isCharging, "\(name): ricollegato sotto la soglia ricarica")
    let again = harness.run(minutes: 10)
    check(again.max <= 81 && smc.percent >= 77.5, "\(name): si riferma alla soglia (\(again.max))")

    // Soglia cambiata dall'app: 60
    harness.limit = 60
    smc.pluggedIn = false
    harness.run(minutes: 8)
    smc.pluggedIn = true
    let lower = harness.run(minutes: 30)
    check(lower.max <= 81 && smc.percent <= 61 && smc.percent >= 57.5, "\(name): nuova soglia 60 rispettata (\(smc.percent))")

    if scheme == .firmware {
        check(smc.bytes("bfF0") == [0x02], "firmware: bfF0 attivo")
        check(smc.bytes("bfD0") == [0x3c, 0, 0, 0] && smc.bytes("bfE0") == [0x3a, 0, 0, 0], "firmware: soglie 60/58 little-endian")
    }

    // Disattivazione (quello che fanno il segnale di uscita e uninstall.sh): ricarica normale fino al 100%
    do { try harness.loop.control.restoreNormalCharging() } catch { check(false, "\(name): ripristino \(error)") }
    smc.advance(by: 60 * 60)
    check(smc.percent >= 100, "\(name): dopo la disattivazione carica al 100% (\(smc.percent))")
    switch scheme {
    case .chte: check(smc.bytes("CHTE") == [0, 0, 0, 0], "chte: CHTE a zero")
    case .ch0bc: check(smc.bytes("CH0B") == [0] && smc.bytes("CH0C") == [0], "ch0b-ch0c: chiavi a zero")
    case .firmware: check(smc.bytes("bfF0") == [0x00], "firmware: bfF0 spento")
    case .adapter: break
    }
}

// MARK: Nessuno schema: il servizio non parte e l'app mostra "non disponibile"

for name in ["nessuna-chiave", "firmware-27-gated-senza-chie"] {
    let smc = fake(name)
    do {
        _ = try ChargingControl(smc: smc)
        check(false, "\(name): non deve trovare uno schema")
    } catch ChargingControlError.noChargeKeys(let found) {
        check(!found.isEmpty, "\(name): elenco chiavi per la diagnosi")
    } catch {
        check(false, "\(name): errore inatteso \(error)")
    }
    // Lo stesso battito che scrive runDaemon quando ChargingControl fallisce
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let status = ServiceStatus(updated: now, state: .failed, error: ServiceError(.noChargeKeys))
    let parsed = ServiceStatus.parse(status.serialize())
    check(ServiceHealth.evaluate(filesPresent: true, status: parsed, launchdRunning: true, now: now) == .failed,
          "\(name): l'app vede il servizio come non disponibile")
    check(smc.writes.isEmpty, "\(name): nessuna scrittura")
}

// Il probe in sola lettura sul firmware bloccato riporta gli errori e nessuno schema
let gatedProbe = SMCProbe.lines(fake("firmware-27-gated"))
check(gatedProbe.contains { $0.hasPrefix("bfF0") && $0.contains("0xe00002c1") }, "probe: bfF0 bloccata")
check(gatedProbe.contains { $0.hasPrefix("CHTE") && $0.contains("byte=0") }, "probe: CHTE a dimensione zero")
check(gatedProbe.contains { $0.hasPrefix("CHIE") && $0.contains("byte=1") }, "probe: CHIE leggibile")
check(gatedProbe.last == "schema rilevato: adapter (CHIE)", "probe: modalità alimentatore, \(gatedProbe.last ?? "")")
check(SMCProbe.lines(fake("firmware-27-gated-senza-chie")).last == "schema rilevato: nessuno (non supportato)", "probe: nessuno schema senza CHIE")
check(SMCProbe.lines(fake("chte")).last == "schema rilevato: CHTE", "probe chte")

// MARK: Firmware che rifiuta i valori: un nuovo tentativo dopo 60 s, poi non disponibile e ricarica normale

do {
    let smc = fake("firmware-27")
    smc.rejectsFirmwareLimit = true
    let harness = try Harness(smc)
    harness.run(minutes: 0.1)
    check(harness.loop.state == .running && harness.loop.lastError?.knownCode == .firmwareRejected, "rifiuto: primo tentativo, ancora in prova")
    let writesAfterFirst = smc.writes.count
    harness.run(minutes: 0.5)
    check(smc.writes.count == writesAfterFirst, "rifiuto: niente scritture prima dei 60 s")
    harness.run(minutes: 1)
    check(harness.loop.state == .failed && harness.loop.isUnavailable, "rifiuto: al secondo tentativo non disponibile")
    check(smc.bytes("bfF0") == [0x00], "rifiuto: limite firmware spento")
    let writesAtGiveUp = smc.writes.count
    harness.run(minutes: 5)
    check(smc.writes.count == writesAtGiveUp, "rifiuto: dopo la resa non scrive più")
} catch {
    check(false, "rifiuto: \(error)")
}

// MARK: SMC che smette di rispondere: dopo 5 cicli di errori non disponibile; un errore isolato no

do {
    let smc = fake("chte")
    let harness = try Harness(smc)
    harness.run(minutes: 5)
    check(!smc.isCharging, "smc: ferma alla soglia prima del guasto")
    harness.loop.tick(battery: nil, limit: 80, now: harness.now)
    check(harness.loop.state == .running && harness.loop.lastError?.knownCode == .batteryUnreadable, "batteria illeggibile una volta: ancora attivo")
    harness.run(minutes: 0.1)
    check(harness.loop.lastError == nil, "dopo un ciclo buono l'errore sparisce")

    smc.failKey("CHTE")
    for _ in 0..<(ChargeLoop.maxConsecutiveFailures - 1) { harness.loop.tick(battery: smc.battery, limit: 80, now: harness.now) }
    check(harness.loop.state == .running, "smc: 4 errori di fila, ancora attivo")
    harness.loop.tick(battery: smc.battery, limit: 80, now: harness.now)
    check(harness.loop.state == .failed && harness.loop.lastError?.knownCode == .smcFailed, "smc: al quinto non disponibile")
} catch {
    check(false, "smc: \(error)")
}


// MARK: Modalità alimentatore (firmware-27-gated): ciclo completo e regole di sicurezza

/// Simula un Mac col firmware bloccato, collegato, carica al 70%, soglia 80
func gatedHarness(percent: Double = 70, forceOn profile: String = "firmware-27-gated", force: Bool = false) throws -> Harness {
    let smc = fake(profile)
    smc.percent = percent
    return try Harness(smc, forceAdapter: force)
}

do {
    let harness = try gatedHarness()
    let smc = harness.smc
    check(harness.loop.control.scheme == .adapter && harness.loop.control.adapter?.key == "CHIE", "gated: schema adapter su CHIE")

    // Sale fino a 80, lì stacca: il Mac va a batteria col cavo inserito e la carica scende
    harness.run(minutes: 2)
    check(smc.bytes("CHIE") == [0x08], "gated: a 80% CHIE = 08 (\(smc.percent))")
    check(smc.pluggedIn && !smc.isOnWallPower && !smc.battery.externalConnected, "gated: cavo inserito ma a batteria")
    check(harness.loop.isAdapterCut == true, "gated: battito adapter=cut")
    let cycle = harness.run(minutes: 60)
    check(cycle.max <= 81 && cycle.min >= 77.5, "gated: un'ora tra 78 e 80 (\(cycle.min)-\(cycle.max))")
    check(smc.writes.allSatisfy { $0.key == "CHIE" }, "gated: scrive solo CHIE")
    let toggles = smc.writes.count
    check(toggles >= 4, "gated: stacca e riattacca più volte in un'ora (\(toggles) scritture)")
    check(harness.loop.state == .running && harness.loop.lastError == nil, "gated: nessun errore")

    // Sotto 78 riattacca e ricarica
    while smc.bytes("CHIE") != [0x08] { harness.run(minutes: 1.0 / 12) }
    var steps = 0
    while smc.bytes("CHIE") != [0x00] && steps < 200 {
        harness.loop.tick(battery: smc.battery, limit: harness.limit, now: harness.now)
        if smc.bytes("CHIE") == [0x00] { break }
        smc.advance(by: 5)
        steps += 1
    }
    check(smc.bytes("CHIE") == [0x00] && smc.battery.percent == 78, "gated: riattaccato a 78% (\(smc.percent))")

    // Uscita pulita (SIGTERM, bootout, disinstallazione): alimentatore riattaccato
    while smc.bytes("CHIE") != [0x08] { harness.run(minutes: 1.0 / 12) }
    do { check(try harness.loop.control.restoreNormalCharging(), "uscita: c'era da riattaccare") } catch { check(false, "uscita: \(error)") }
    check(smc.bytes("CHIE") == [0x00] && smc.isOnWallPower, "uscita: alimentatore riattaccato")
    smc.advance(by: 60 * 60)
    check(smc.percent >= 100, "uscita: poi carica al 100% (\(smc.percent))")
} catch {
    check(false, "gated: \(error)")
}

// kill -9 con l'alimentatore staccato: al riavvio (launchd KeepAlive) il primo gesto riattacca
do {
    let harness = try gatedHarness(percent: 79)
    harness.run(minutes: 0.5)
    check(harness.smc.bytes("CHIE") == [0x08], "kill: staccato prima della morte")
    // Il servizio muore senza ripristino; quello nuovo parte con lo stesso SMC
    let reattached = try ChargingControl.reattachAdapter(smc: harness.smc)
    check(reattached == ["CHIE"] && harness.smc.bytes("CHIE") == [0x00], "kill: riattaccato all'avvio (\(reattached))")
    check(try ChargingControl.reattachAdapter(smc: harness.smc).isEmpty, "kill: avvio normale, niente da riattaccare")
    // Anche dove lo schema non è adapter (enable-charging di uninstall.sh sul Mac della prova forzata)
    let chte = fake("chte")
    try chte.write("CHIE", bytes: [0x08])
    check(try ChargingControl.reattachAdapter(smc: chte) == ["CHIE"] && chte.bytes("CHIE") == [0x00], "kill: riattacca anche con CHTE")
    check(try ChargingControl.reattachAdapter(smc: fake("nessuna-chiave")).isEmpty, "kill: nessuna chiave, nessuna scrittura")
} catch {
    check(false, "kill: \(error)")
}

// Batteria sotto il 20% con l'alimentatore staccato (per qualunque motivo): riattacca anche con la soglia più bassa
do {
    let harness = try gatedHarness(percent: 81)
    harness.run(minutes: 1.0 / 12)
    check(harness.smc.bytes("CHIE") == [0x08], "20%: staccato")
    // Soglia 15 fuori dal range dell'app: così a riattaccare è solo la regola del 20%, non l'isteresi
    harness.smc.percent = 21
    harness.loop.tick(battery: harness.smc.battery, limit: 15, now: harness.now)
    check(harness.smc.bytes("CHIE") == [0x08], "20%: a 21% resta staccato")
    harness.smc.percent = 19
    harness.loop.tick(battery: harness.smc.battery, limit: 15, now: harness.now)
    check(harness.smc.bytes("CHIE") == [0x00], "20%: a 19% riattaccato")
    check(ChargeLoop.adapterSafetyFloor == 20, "20%: soglia di sicurezza")
} catch {
    check(false, "20%: \(error)")
}

// Watchdog: batteria illeggibile per 3 cicli = riattacca e non disponibile
do {
    let harness = try gatedHarness(percent: 81)
    harness.run(minutes: 1.0 / 12)
    check(harness.smc.bytes("CHIE") == [0x08], "watchdog: staccato")
    harness.loop.tick(battery: nil, limit: 80, now: harness.now)
    harness.loop.tick(battery: nil, limit: 80, now: harness.now)
    check(harness.loop.state == .running && harness.smc.bytes("CHIE") == [0x08], "watchdog: 2 cicli, ancora attivo")
    harness.loop.tick(battery: nil, limit: 80, now: harness.now)
    check(harness.loop.state == .failed && harness.loop.lastError?.knownCode == .batteryUnreadable, "watchdog: al terzo non disponibile")
    check(harness.smc.bytes("CHIE") == [0x00] && harness.loop.isAdapterCut == false, "watchdog: alimentatore riattaccato")
    harness.run(minutes: 5)
    check(harness.smc.bytes("CHIE") == [0x00], "watchdog: dopo la resa non stacca più")
    // Un ciclo buono in mezzo azzera il conteggio
    let other = try gatedHarness(percent: 81)
    other.loop.tick(battery: nil, limit: 80, now: other.now)
    other.loop.tick(battery: nil, limit: 80, now: other.now)
    other.run(minutes: 1.0 / 12)
    other.loop.tick(battery: nil, limit: 80, now: other.now)
    other.loop.tick(battery: nil, limit: 80, now: other.now)
    check(other.loop.state == .running, "watchdog: conteggio azzerato da un ciclo buono")
} catch {
    check(false, "watchdog: \(error)")
}

// Sonno simulato: prima del sonno riattacca, durante il sonno non stacca, al risveglio riprende
do {
    let harness = try gatedHarness(percent: 81)
    harness.run(minutes: 1.0 / 12)
    check(harness.smc.bytes("CHIE") == [0x08], "sonno: staccato prima")
    harness.loop.systemWillSleep()
    check(harness.smc.bytes("CHIE") == [0x00] && harness.loop.isAdapterCut == false, "sonno: riattaccato alla notifica")
    // Un ciclo tra la notifica e il sonno vero (o in un risveglio parziale) non deve staccare
    harness.run(minutes: 1)
    check(harness.smc.bytes("CHIE") == [0x00], "sonno: nessun distacco finché dorme")
    harness.loop.systemDidWake()
    harness.run(minutes: 1.0 / 12)
    check(harness.smc.bytes("CHIE") == [0x08], "sonno: al risveglio sopra soglia stacca di nuovo")
    // Se l'SMC rifiuta il riattacco alla notifica, il ciclo successivo durante il sonno riprova
    harness.loop.systemWillSleep()
    try harness.smc.write("CHIE", bytes: [0x08])
    harness.run(minutes: 1.0 / 12)
    check(harness.smc.bytes("CHIE") == [0x00], "sonno: ciclo durante il sonno riattacca")
} catch {
    check(false, "sonno: \(error)")
}

// Senza notifiche di sonno la modalità non è sicura: non disponibile e alimentatore riattaccato
do {
    let harness = try gatedHarness(percent: 81)
    harness.run(minutes: 1.0 / 12)
    harness.loop.giveUpWithoutSleepNotifications()
    check(harness.loop.state == .failed && harness.smc.bytes("CHIE") == [0x00], "senza notifiche: non disponibile e riattaccato")
} catch {
    check(false, "senza notifiche: \(error)")
}

// Cavo tolto davvero: non stacca (non serve) e a cavo tolto riattacca comunque sotto soglia
do {
    let harness = try gatedHarness(percent: 85)
    harness.smc.pluggedIn = false
    harness.run(minutes: 0.5)
    check(harness.smc.writes.isEmpty, "cavo tolto: nessuna scrittura sopra soglia")
} catch {
    check(false, "cavo tolto: \(error)")
}

// SMC che non tiene il valore: dopo 5 cicli non disponibile, mai a batteria per sempre
do {
    let harness = try gatedHarness(percent: 81)
    harness.smc.failKey("CHIE")
    harness.run(minutes: 0.5)
    check(harness.loop.state == .failed && harness.loop.lastError?.knownCode == .smcFailed, "CHIE illeggibile: non disponibile")
} catch {
    check(false, "CHIE illeggibile: \(error)")
}

// Prova forzata sul Mac di Alessio (profilo chte): adapter anche con CHTE, CHTE non viene toccata
do {
    let harness = try gatedHarness(percent: 79, forceOn: "chte", force: true)
    check(harness.loop.control.scheme == .adapter && harness.loop.control.adapter?.key == "CHIE", "forzato: adapter su CHIE")
    let cycle = harness.run(minutes: 30)
    check(cycle.max <= 81 && cycle.min >= 77.5, "forzato: tra 78 e 80 (\(cycle.min)-\(cycle.max))")
    check(harness.smc.writes.allSatisfy { $0.key == "CHIE" }, "forzato: CHTE mai scritta")
    try harness.loop.control.restoreNormalCharging()
    check(harness.smc.bytes("CHIE") == [0x00], "forzato: ripristino, alla fine collegato")
} catch {
    check(false, "forzato: \(error)")
}

if failures > 0 {
    print("\(failures) test falliti")
    exit(1)
}
print("ChargeLoop: tutti i test passati")
