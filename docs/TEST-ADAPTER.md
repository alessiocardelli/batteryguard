# Prova dal vivo della modalità alimentatore (1.0.4)

Scopo: provare sul MacBook Air di Alessio (macOS 26.5.1, schema CHTE) il distacco vero dell'alimentazione con `CHIE`, quello che BatteryGuard usa da solo sui Mac col firmware bloccato (macOS 27 beta 4+, 15.8, 26.7). Sul suo Mac CHTE funziona, quindi la modalità va forzata con la variabile `BATTERYGUARD_DEBUG_FORCE_ADAPTER=1` nel plist del servizio.

Questa prova scrive sull'SMC vero (`CHIE`) e chiede la password. Durata: 30-45 minuti, quasi tutti di attesa.

## 0. Prima di cominciare

- AlDente Pro chiuso (si contende l'SMC).
- Mac collegato all'alimentatore, carica tra 52 e 80%.
- Terminale aperto. Le variabili sotto valgono per tutta la sessione del Terminale:

```
APP=/Applications/BatteryGuard.app
H=/Library/PrivilegedHelperTools/com.alessiocardelli.batteryguard.helper
PL=/Library/LaunchDaemons/com.alessiocardelli.batteryguard.helper.plist
LABEL=system/com.alessiocardelli.batteryguard.helper
DIR="/Library/Application Support/BatteryGuard"
LOG=/Library/Logs/BatteryGuard/helper.log
```

## 1. Installa l'app 1.0.4

1. Esci da BatteryGuard (icona > Esci).
2. Sostituisci l'app con quella appena compilata e aprila una volta (se macOS la blocca: Impostazioni di Sistema > Privacy e sicurezza > Apri comunque):

```
rm -rf "$APP" && ditto ~/Documents/Claude/projects/charge-limit/app/dist/BatteryGuard.app "$APP" && open "$APP"
```

## 2. Controllo in sola lettura (non scrive niente)

```
$APP/Contents/MacOS/batteryguard-helper probe
```

Atteso, tra le altre righe:

```
CHIE  tipo=hex_  byte=1  valore=00
schema rilevato: CHTE
```

`valore=00` vuol dire alimentazione collegata. Se CHIE manca o non ha `byte=1`, fermati: la prova non si può fare su questo Mac.

## 3. Installa il servizio 1.0.4 con la modalità forzata

```
sudo sh $APP/Contents/Resources/install.sh $APP/Contents/MacOS/batteryguard-helper 80 $(id -u)
sudo /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:BATTERYGUARD_DEBUG_FORCE_ADAPTER string 1" $PL
sudo launchctl bootout $LABEL; sudo launchctl bootstrap system $PL
```

Il primo comando ferma il servizio 1.0.3 (che rimette CHTE a zero uscendo) e installa il nuovo; il secondo aggiunge la variabile; il terzo riavvia il servizio per fargliela leggere.

Controllo, dopo 10 secondi:

```
tail -3 $LOG
cat "$DIR/status"
```

Atteso nel log: `prova: modalità alimentatore forzata` e `avvio, schema adapter (CHIE), soglia 80%`. Nel battito: `state=running`, `scheme=adapter`, `adapter=attached` (o `cut` se la carica è già a 80).

Attenzione: da qui fino al passo 8 non usare **Attiva** o **Aggiorna** nel pannello. Reinstallano il servizio e tolgono la variabile. Spostare la soglia nel pannello invece va bene.

## 4. Stacco sopra soglia

Porta la soglia esattamente alla carica di adesso, così il distacco è immediato e il ritorno arriva dopo soli 2 punti. Il file della soglia è tuo, non serve sudo. Accetta valori tra 50 e 80:

```
P=$(pmset -g batt | grep -Eo '[0-9]+%' | tr -d %); echo "carica $P%"
printf 'limit=%s\n' "$P" > "$DIR/config"
```

Entro 10 secondi:

```
pmset -g batt
cat "$DIR/status"
tail -2 $LOG
```

Atteso:
- `pmset`: `Now drawing from 'Battery Power'` anche col cavo inserito
- battito: `adapter=cut`
- log: `batteria NN% >= NN%: alimentatore staccato, il Mac va a batteria`
- pannello: sotto la batteria compare **A batteria** al posto di **In pausa**

Da notare per il resoconto (non verificato da nessuna fonte): cosa fa il LED del MagSafe, se macOS mostra la notifica di alimentatore scollegato, se cambia la luminosità dello schermo (impostazioni a batteria).

## 5. Ritorno ad AC sotto soglia - 2

Lascia il Mac acceso e in uso (non in stop) finché la carica non scende di 2 punti. Per seguirlo:

```
while true; do date '+%H:%M:%S'; pmset -g batt | sed -n '1p;2p'; sleep 60; done
```

(Ctrl-C per fermarlo.) Atteso: a soglia - 2 torna `Now drawing from 'AC Power'`, il log dice `batteria NN% <= NN%: alimentatore riattaccato` e il Mac riprende a caricare fino alla soglia, dove stacca di nuovo.

## 6. Sonno (facoltativo, 2 minuti)

Con `adapter=cut` (se serve rifai il passo 4):

```
pmset sleepnow
```

Risveglia il Mac dopo almeno 30 secondi, poi:

```
tail -5 $LOG
```

Atteso: `sonno in arrivo: alimentatore riattaccato` prima del sonno, `risveglio` dopo, e di nuovo `alimentatore staccato` al primo ciclo se la carica è ancora sopra soglia.

## 7. Servizio ucciso male (facoltativo)

Con `adapter=cut`:

```
sudo launchctl kill SIGKILL $LABEL
sleep 15; grep -E 'avvio' $LOG | tail -3
```

Atteso: launchd rilancia il servizio e il log dice `avvio: alimentatore trovato staccato, riattaccato (CHIE)`, poi `avvio, schema adapter (CHIE)` e, sopra soglia, un nuovo distacco.

## 8. Disinstallazione: deve tornare ad AC

Con `adapter=cut`, dal pannello **Disattiva il limite** > **Disattiva**, oppure da Terminale:

```
sudo sh $APP/Contents/Resources/uninstall.sh
pmset -g batt
```

Atteso: `Now drawing from 'AC Power'` e Mac in carica.

## 9. Ritorno alla normalità

Apri il pannello e clicca **Attiva il limite di ricarica**: reinstalla il servizio senza la variabile, con lo schema CHTE di sempre. Controllo:

```
cat "$DIR/status"
```

Atteso: `scheme=CHTE`, niente riga `adapter=`.

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
2. Togli tutto: `sudo sh $APP/Contents/Resources/uninstall.sh`.
3. Ultima risorsa: spegni il Mac (non riavvio), aspetta 30 secondi, riaccendi. È la procedura di Apple per azzerare lo stato dell'SMC sui Mac con Apple Silicon; che azzeri anche CHIE non è verificato.

Staccare e riattaccare il cavo non serve: il distacco è nell'SMC, non nel cavo.
