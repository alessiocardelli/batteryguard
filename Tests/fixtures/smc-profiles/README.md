# Profili del finto SMC

Ogni file descrive le chiavi SMC di un tipo di firmware, più una batteria simulata. Li usano i test (`scripts/test.sh`) e il servizio in modalità di prova (`BATTERYGUARD_FAKE_SMC=<profilo.json>`).

Formato: `keys` mappa la chiave su `type` (4 caratteri, come li riporta l'SMC), `bytes` (esadecimali separati da spazi; stringa vuota = segnaposto a dimensione zero) oppure `error` (codice IOKit restituito da ogni operazione). Una chiave assente non esiste. `battery` dà la carica iniziale, l'alimentatore e la velocità in punti percentuali al minuto. `rejectsFirmwareLimit: true` fa accettare le scritture su `bfD0`/`bfE0` senza tenerle. `lidClosed` simula il coperchio (AppleClamshellState): assente = Mac senza coperchio, e il servizio legge quello vero. `externalDisplay` simula un monitor esterno (DCPAVServiceProxy con `Location` = `External`): assente = il servizio legge quello vero.

Il finto SMC simula il comportamento che conta: `CHTE` diverso da zero o `CH0B`/`CH0C` diversi da zero bloccano la ricarica; con `bfF0 = 02` il firmware ferma la carica a `bfD0` e la fa ripartire a `bfE0`; `CHIE`, `CH0I` o `CH0J` diversi da `00` staccano l'alimentazione (il Mac va a batteria col cavo inserito e la batteria simulata dice "scollegato"); la carica sale con l'alimentatore e la ricarica libera, scende senza alimentatore. `BUIC` segue la carica.

## Da dove viene ogni profilo

| Profilo | Firmware | Fonti |
|---|---|---|
| `chte` | macOS 26 (Tahoe) | Mac di Alessio (MacBook Air M2, `Mac14,2`, macOS 26.5.1 build 25F80): `batteryguard-helper probe` in sola lettura il 23/10/2026, valori copiati tali e quali (CHTE ui32, CHIE hex_ 1 byte, bfD0 hex_ 2 byte, CH0J che risponde 0xe00002c1, B0RM). Semantica di CHTE (`01000000` blocca, `00000000` riabilita): [Battery-Toolkit #117](https://github.com/mhaeuser/Battery-Toolkit/issues/117), [batt #34](https://github.com/charlie0129/batt/issues/34). Dump completi con CHTE ui32 e CHIE hex_: batt #34, [Battery-Toolkit #150](https://github.com/mhaeuser/Battery-Toolkit/issues/150) |
| `ch0b-ch0c` | macOS 14-15 (Sonoma, Sequoia) | Chiavi e byte dal codice di batt (`pkg/smc/consts_arm64.go`, `pkg/smc/charging.go`: CH0B e CH0C 1 byte, `00` abilita, `02` blocca) e di Battery Toolkit (`Libraries/SMCComm+Power.swift`: CH0C hex_ 1 byte, CH0J ui8 1 byte). Che su Tahoe spariscano CH0B, CH0C e CH0I: batt #34, Battery-Toolkit #117. Il tipo di CH0B e CH0I e l'assenza di CHTE su questi firmware sono dedotti, non letti da un dump |
| `firmware-27` | macOS 27 fino alla beta 3 | [batt #140](https://github.com/charlie0129/batt/issues/140) (sequenza `bfF0 <- 00`, `bfD0`, `bfE0`, `bfF0 <- 02`; soglie ui32 little-endian, `32 00 00 00` = 50%; `bfF0` 1 byte, `00` spento, `02` attivo; il limite resta col Mac in stop), [batt #142](https://github.com/charlie0129/batt/pull/142) e il codice di batt (`pkg/smc/charging.go`, `ChargeControlMode`: le chiavi firmware hanno la precedenza). Il tipo di `bfF0` e i valori iniziali delle soglie sono dedotti |
| `firmware-27-gated` | macOS 27 dalla beta 4, e lo stesso firmware in macOS 15.8 / 26.7 | [batt #152](https://github.com/charlie0129/batt/issues/152) (firmware 20457.1.29: `bfF0`/`bfD0`/`bfE0` danno `0xe00002c1` anche da root su KeyInfo, lettura e scrittura; CHTE, CH0B, CH0C segnaposto a dimensione zero; CH0I e CH0J bloccati; CHIE leggibile e non bloccato), [batt #154](https://github.com/charlie0129/batt/pull/154) (modalità alimentatore, unita in batt il 24/9/2026, provata su MacBook Air M5 firmware 20457.1.29). Valori di CHIE dal codice di batt (`pkg/smc/adapter.go`): `00` collegato, `08` staccato. Qui BatteryGuard usa lo schema `adapter` |
| `firmware-27-gated-coperchio` | Come sopra, MacBook con coperchio | Stesse chiavi di `firmware-27-gated` più `lidClosed`: coperchio chiuso = mai alimentatore staccato (decisione di Alessio del 23/10/2026, un MacBook chiuso con monitor esterno che va a batteria finisce in stop). I test ci aggiungono `externalDisplay`: monitor esterno collegato = mai alimentatore staccato, anche a coperchio aperto (decisione del 23/10/2026, stessa prova) |
| `firmware-27-gated-senza-chie` | Come sopra, senza chiave dell'alimentatore | Caso limite costruito apposta: nessuno schema, stato unico "non disponibile" |
| `nessuna-chiave` | Mac senza controllo della ricarica, macchina virtuale | Caso limite costruito apposta |

Nessuna riga di codice di batt o Battery Toolkit è copiata: dai loro sorgenti e dalle issue vengono solo i fatti (nomi, dimensioni, byte, comportamento).

## Servizio con un profilo finto (macchine virtuali, Mac senza batteria)

Con `BATTERYGUARD_FAKE_SMC` il servizio usa il profilo al posto dell'SMC vero: non tocca nessuna chiave vera, non chiede root, la carica simulata avanza col tempo vero (6 punti al minuto collegato) e viene scritta in `fake-battery` accanto al battito.

Senza installare niente:

```
H=/Applications/BatteryGuard.app/Contents/MacOS/batteryguard-helper
P=/Users/Shared/smc-profiles   # copia di questa cartella: i profili non sono dentro l'app
mkdir -p /tmp/bg
BATTERYGUARD_FAKE_SMC=$P/firmware-27.json BATTERYGUARD_DEBUG_STATUS_FILE=/tmp/bg/status $H daemon
BATTERYGUARD_FAKE_SMC=$P/chte.json $H probe
```

Con il servizio installato dall'app (per provare l'interfaccia): il demone di launchd non eredita l'ambiente, la variabile va nel plist.

```
PL=/Library/LaunchDaemons/com.alessiocardelli.batteryguard.helper.plist
sudo /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:BATTERYGUARD_FAKE_SMC string $P/chte.json" $PL
sudo launchctl bootout system/com.alessiocardelli.batteryguard.helper; sudo launchctl bootstrap system $PL
BATTERYGUARD_FAKE_SMC=$P/chte.json /Applications/BatteryGuard.app/Contents/MacOS/BatteryGuard
```

L'app con la stessa variabile legge la batteria simulata dal servizio e mette nella segnalazione le chiavi del profilo. Con `nessuna-chiave` o `firmware-27-gated-senza-chie` il pannello mostra lo stato unico "non disponibile"; con `firmware-27-gated` il servizio va in modalità alimentatore e sopra soglia il pannello mostra "A batteria". Il profilo deve stare in un percorso leggibile da root (non in una cartella protetta dell'utente come Scrivania o Documenti).
