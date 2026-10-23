# Prova dal vivo della modalità alimentatore (1.0.4)

Scopo: provare sul MacBook Air di Alessio (macOS 26.5.1, schema CHTE) il distacco vero dell'alimentazione con `CHIE`, quello che BatteryGuard usa da solo sui Mac col firmware bloccato (macOS 27 beta 4+, 15.8, 26.7). Sul suo Mac CHTE funziona, quindi la modalità va forzata con la variabile `BATTERYGUARD_DEBUG_FORCE_ADAPTER=1` nel plist del servizio.

Regola da provare (decisione del 23/10): in modalità alimentatore il servizio **non stacca mai l'alimentatore se è collegato un monitor esterno**, anche a coperchio aperto. Se il monitor si collega mentre l'alimentatore è staccato, riattacca subito. Quando il monitor si scollega aspetta 30 secondi prima di poter staccare. Motivo: nella prima prova, dopo il riattacco a coperchio chiuso macOS è rimasto a batteria per circa 2 minuti ed è andato in stop (`Clamshell Sleep`), e chi tiene il Mac chiuso ha sempre un monitor esterno.

Il servizio vede il monitor dall'IORegistry (un `DCPAVServiceProxy` con `Location` = `External` per ogni monitor collegato), senza sessione grafica. Sul Mac di Alessio con il Dell collegato è verificato in sola lettura il 23/10; con il Dell scollegato no: lo verifica il passo (c).

Questa prova scrive sull'SMC vero (`CHIE`) e chiede la password. Durata: 20-30 minuti. Serve il monitor Dell.

## 0. Prima di cominciare

- AlDente Pro chiuso (si contende l'SMC).
- Mac collegato all'alimentatore, carica tra 52 e 80%, coperchio aperto, Dell collegato.
- Esci da BatteryGuard (icona > Esci).
- Terminale aperto. Le variabili sotto valgono per tutta la sessione del Terminale:

```
APP=/Applications/BatteryGuard.app
H=/Library/PrivilegedHelperTools/com.alessiocardelli.batteryguard.helper
PL=/Library/LaunchDaemons/com.alessiocardelli.batteryguard.helper.plist
LABEL=system/com.alessiocardelli.batteryguard.helper
DIR="/Library/Application Support/BatteryGuard"
LOG=/Library/Logs/BatteryGuard/helper.log
```

Installa l'app 1.0.4 appena compilata e aprila una volta (se macOS la blocca: Impostazioni di Sistema > Privacy e sicurezza > Apri comunque):

```
rm -rf "$APP" && ditto ~/Documents/Claude/projects/charge-limit/app/dist/BatteryGuard.app "$APP" && open "$APP"
```

Controllo in sola lettura (non scrive niente):

```
$APP/Contents/MacOS/batteryguard-helper probe | grep -E 'CHIE|schema'; $APP/Contents/MacOS/batteryguard-helper status | grep -E 'coperchio|monitor'
```

Atteso: `CHIE  tipo=hex_  byte=1  valore=00`, `schema rilevato: CHTE`, `coperchio: aperto`, `monitor esterno: collegato`. Se CHIE manca o non ha `byte=1`, fermati: la prova non si può fare su questo Mac.

## (a) Il chip tiene le scritture? (1 minuto, scrive sull'SMC)

Con il servizio di sempre (schema CHTE, che CHIE non la tocca), coperchio aperto e cavo inserito. Il comando stacca e riattacca l'alimentazione 3 volte da solo, anche con il Dell collegato: prova il chip, non la regola del monitor. Alla fine riattacca sempre; Ctrl-C è ignorato finché non ha finito.

```
sudo $APP/Contents/MacOS/batteryguard-helper selftest-adapter; pmset -g batt | head -1
```

Atteso: 6 righe `ciclo N stacca/riattacca` con `riletto` uguale a `scritto`, `macOS a batteria` o `ad alimentatore` dopo pochi millisecondi o secondi, nessun `DIVERSO`, nessun `tornato a`, poi `esito: il chip accetta e tiene le scritture, macOS segue` e `Now drawing from 'AC Power'`. Copia l'uscita intera nel resoconto: i tempi servono. Se l'esito dice problemi, fermati qui.

## Installazione con la modalità forzata (un blocco solo)

Ferma il servizio di sempre (che rimette CHTE a zero uscendo), installa il 1.0.4, aggiunge la variabile, lo riavvia e porta la soglia alla carica di adesso, così il Mac è sopra soglia da subito. Il file della soglia è tuo, non serve sudo (accetta valori tra 50 e 80).

```
sudo sh $APP/Contents/Resources/install.sh $APP/Contents/MacOS/batteryguard-helper 80 $(id -u) && \
sudo /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:BATTERYGUARD_DEBUG_FORCE_ADAPTER string 1" $PL && \
sudo launchctl bootout $LABEL; sudo launchctl bootstrap system $PL; \
P=$(pmset -g batt | grep -Eo '[0-9]+%' | tr -d %); printf 'limit=%s\n' "$P" > "$DIR/config"; echo "soglia $P%"; \
sleep 10; tail -4 $LOG; cat "$DIR/status"
```

Atteso nel log: `prova: modalità alimentatore forzata`, `avvio, schema adapter (CHIE), soglia NN%` e `monitor esterno collegato: alimentatore già collegato, 00 riscritto`. Nel battito: `state=running`, `scheme=adapter`, `adapter=attached`, `lid=open`, `display=external`.

Attenzione: da qui fino al ritorno alla normalità non usare **Attiva** o **Aggiorna** nel pannello. Reinstallano il servizio e tolgono la variabile. Spostare la soglia nel pannello invece va bene.

## (b) Dell collegato, sopra soglia: NON deve staccare (2 minuti)

```
for i in $(seq 1 24); do printf '%s  ' "$(date +%T)"; tr '\n' ' ' < "$DIR/status"; pmset -g batt | head -1; sleep 5; done
```

Atteso per tutti i 2 minuti: `adapter=attached`, `display=external`, `Now drawing from 'AC Power'`. Nel pannello sotto la batteria **In pausa** (o in carica), mai **A batteria**. Se compare `adapter=cut` la regola non funziona: vai a "Se qualcosa va storto".

## (c) Scollega il Dell: stacco dopo 30 secondi

Lancia il blocco e, quando suona, scollega il cavo del Dell. Il blocco misura quanto passa tra lo scollegamento visto dal servizio e il distacco dell'alimentatore.

```
printf '\a'; echo "$(date +%T) SCOLLEGA il Dell"
until grep -q display=internal "$DIR/status"; do sleep 1; done; T0=$(date +%s); echo "$(date +%T) monitor scollegato per il servizio"
$APP/Contents/MacOS/batteryguard-helper status | grep monitor; ioreg -r -c DCPAVServiceProxy -d1 | grep '"Location"'
until grep -q adapter=cut "$DIR/status"; do sleep 1; done; echo "$(date +%T) alimentatore staccato dopo $(( $(date +%s) - T0 )) s"
pmset -g batt | head -1; tail -3 $LOG
```

Atteso:
- `monitor esterno: nessuno` e una sola riga `"Location" = "Embedded"` (nessuna `External`): è la verifica del rilevamento a Dell scollegato
- `alimentatore staccato dopo` tra 30 e 40 secondi (il servizio controlla ogni 5)
- `Now drawing from 'Battery Power'` col cavo inserito
- nel log `monitor esterno scollegato: niente distacco per 30 secondi`, poi `batteria NN% >= NN%: alimentatore staccato, il Mac va a batteria`

Se il blocco resta fermo su `until grep -q display=internal` per più di 10 secondi dopo lo scollegamento, il servizio non vede lo scollegamento: Ctrl-C, copia l'uscita di `ioreg -r -c DCPAVServiceProxy -d1 | grep '"Location"'` e `cat "$DIR/status"` nel resoconto e passa al ritorno alla normalità.

## (d) Ricollega il Dell con l'alimentatore staccato: riattacco e ritorno ad AC

Con `adapter=cut` (lo è alla fine del passo c), lancia il blocco e, quando suona, ricollega il Dell. Misura due tempi: dal monitor visto al riattacco del servizio, e dal riattacco al momento in cui macOS torna su AC.

```
printf '\a'; echo "$(date +%T) RICOLLEGA il Dell"
until grep -q display=external "$DIR/status"; do sleep 0.2; done; T0=$(date +%s); echo "$(date +%T) monitor collegato per il servizio"
until grep -q adapter=attached "$DIR/status"; do sleep 0.2; done; echo "$(date +%T) alimentatore riattaccato dopo $(( $(date +%s) - T0 )) s"
until pmset -g batt | grep -q "AC Power"; do sleep 1; done; echo "$(date +%T) macOS su AC dopo $(( $(date +%s) - T0 )) s"
tail -3 $LOG; pmset -g log | grep -E 'Using (AC|Batt)|Clamshell Sleep' | tail -5
```

Atteso: riattacco entro 1-2 secondi (notifica di IOKit, al massimo 5 col controllo a ogni ciclo), nel log `monitor esterno collegato: alimentatore riattaccato`, e `macOS su AC` entro pochi secondi. Il tempo di `macOS su AC` è il dato chiave: nella prima prova, a coperchio chiuso, macOS ci ha messo circa 2 minuti. Se dopo 3 minuti non è tornato su AC, Ctrl-C e vai a "Se qualcosa va storto".

Copia nel resoconto l'uscita intera di (b), (c) e (d), anche se è tutto in ordine.

## Ritorno alla normalità (un blocco solo)

Salva il log (la disinstallazione lo cancella), disinstalla, reinstalla il servizio normale (schema CHTE, senza variabile, soglia 80) e controlla:

```
cp $LOG ~/Desktop/batteryguard-helper-$(date +%H%M).log; \
sudo sh $APP/Contents/Resources/uninstall.sh; pmset -g batt | head -1; \
sudo sh $APP/Contents/Resources/install.sh $APP/Contents/MacOS/batteryguard-helper 80 $(id -u); \
sleep 10; cat "$DIR/status"
```

Atteso: `disinstallato`, `Now drawing from 'AC Power'`, `installato: ... (soglia 80%)`, poi nel battito `scheme=CHTE` e niente riga `adapter=`.

## Se qualcosa va storto

Il Mac resta a batteria col cavo inserito (`Battery Power` in `pmset -g batt`), in ordine:

1. Riattacca l'alimentazione (riattacca CHIE qualunque cosa rilevi, poi rimette la ricarica normale):
   ```
   sudo $H enable-charging
   ```
   Se il servizio è già stato tolto e quel file non c'è più:
   ```
   sudo $APP/Contents/MacOS/batteryguard-helper enable-charging
   ```
   Atteso: `alimentatore riattaccato (CHIE)`.
2. Togli tutto e torna alla normalità con il blocco qui sopra.
3. Ultima risorsa: spegni il Mac (non riavvio), aspetta 30 secondi, riaccendi. È la procedura di Apple per azzerare lo stato dell'SMC sui Mac con Apple Silicon; che azzeri anche CHIE non è verificato.

Staccare e riattaccare il cavo non serve: il distacco è nell'SMC, non nel cavo.
