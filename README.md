# Control Room

Un blocco Tern persistente per rientrare nei lavori paralleli: una pagina con
tutti i pane delle sessioni di questa finestra (terminali, agenti, blocchi),
con lo stato che Tern riporta, ordinati per **attenzione prima** e **attività
recente dopo**. Da lì salti al pane, sbirci le sue ultime righe, chiedi un
aggiornamento a un agente, parcheggi o ripristini un pane.

Non è un gestore di TODO: non salva elenchi, note o riepiloghi. Ogni riga è
letta da Tern a ogni aggiornamento; i messaggi degli agenti sono il loro ultimo
messaggio reale, non riassunti.

## La pagina

```
Control Room  18 panes · 7 sessions · updated 3s ago           [Live] [Refresh r]
Attention 0 │ Running 1 │ Waiting 10 │ Idle 7
Panes 18   Agents 11   Failures 1
[⌕ filter /]                  [All | Attention | Active] [Flat | Session | Project]
Pane · Where · Status · Last · Age              ┌ pane selezionato        [Go ⏎] ┐
…righe…                                         │ fatti · azioni · peek · messaggi │
```

- **Testata**: conteggio pane e sessioni, quando è arrivato l'ultimo rapporto
  dalla finestra; il badge dice `Live`, `Stale` (nessun rapporto da più di 25 s)
  o `No window report` (nessuna finestra ha ancora riferito: si vede solo ciò
  che sa il daemon).
- **Strip di numeri**: quanti pane richiedono attenzione (e perché: agenti in
  attesa di input, falliti), quanti lavorano (agenti, comandi), quanti aspettano
  un prompt, quanti sono inattivi.
- **Viste**: *Panes* (tutti), *Agents* (solo i pane con un agente), *Failures*
  (i comandi falliti visti da questa finestra, vedi sotto).
- **Tabella**: un punto colorato per stato, titolo, sessione › tab (o *parked*),
  stato, ultimo risultato (ultimo comando con esito e durata, oppure l'ultimo
  messaggio dell'agente) e da quanto è cambiata. Le colonne meno importanti si
  nascondono quando il blocco è stretto. Il tasto destro su una riga offre le
  stesse azioni della scheda.
- **Scheda del pane selezionato**: accanto alla tabella quando il blocco è largo
  almeno 110 colonne, sotto altrimenti. Mostra cartella, programma, comando in
  corso e da quanto, ultimo comando con exit code, modello e comando
  dell'agente, l'ultimo messaggio dell'agente (Markdown, troncato a 1500
  caratteri) e, dopo un *Peek*, le ultime righe del pane e gli ultimi scambi
  della chat.

| Stato | Quando |
| --- | --- |
| **attenzione** (rosso/ambra) | agente in attesa del tuo input; turno di un agente fallito; turno finito e non ancora visto; prompt non consegnato; ultimo comando fallito; programma uscito con codice ≠ 0; pane che non è partito; alert non visto |
| **in esecuzione** (accent) | agente che lavora; comando in esecuzione (con la riga di comando) |
| **in attesa** (pending) | agente fermo in attesa di un prompt |
| **inattivo** (grigio) | tutto il resto |

L'ordinamento è: livello (attenzione → in esecuzione → in attesa → inattivo),
poi attività più recente, poi posizione del tab. Raggruppando per sessione o
per progetto, i gruppi seguono lo stesso criterio (il gruppo con la riga più
urgente va in alto).

## Tasti

| Tasto | Azione |
| --- | --- |
| `↑`/`↓` (`k`/`j`), `PgUp`/`PgDn`, `Home`/`End` | seleziona |
| `Enter` (`o`, doppio clic) | vai al pane: cambia sessione se serve, ripristina un pane parcheggiato, lo mette a fuoco |
| `.` | *peek*: legge le ultime 12 righe del pane (e per un agente gli ultimi 4 messaggi della chat) e le mostra nella scheda |
| `u` | chiedi un aggiornamento all'agente selezionato |
| `p` | parcheggia il pane / ripristinalo (resta a fuoco Control Room) |
| `x` | archivia il problema della riga (vedi sotto) |
| `/` | filtra: digita, `Enter` conferma, `Esc` cancella |
| `Tab`/`⇧Tab` (`]`/`[`) | vista: Panes → Agents → Failures |
| `v` | ambito: tutto → richiede attenzione → non inattivo |
| `g` | raggruppa: nessuno → per sessione → per progetto |
| `r` | aggiorna ora |

Gli stessi comandi sono pulsanti nella scheda, nei tab e nel menu del tasto
destro della riga. Il filtro cerca, parola per parola, in titolo, cartella,
programma, sessione, tab, stato, comando in corso, ultimo comando e
comando/modello dell'agente. Vista, filtro, ambito e raggruppamento sono
salvati con il blocco.

**Archiviare (`x`)** vale per il problema *corrente* di quel pane (quel comando
fallito, con quell'exit code e quella durata, quell'uscita, o quel turno
fallito): un nuovo fallimento sullo stesso pane torna in evidenza. Le
archiviazioni stanno nel `kv.json` del plugin e vengono ripulite quando il
pane non esiste più.

**Peek (`.`)** chiede alla finestra di leggere il pane con `cx.session:read`
(ultime 12 righe, con quante ne restano sopra) e, per un agente omp, gli ultimi
4 messaggi con `cx.agents:transcript`. È una lettura una tantum, non entra
nello snapshot: la scheda la mostra finché resta selezionato quel pane. Serve
soprattutto dove la shell non emette i marcatori OSC 133 e Tern non riporta
i comandi.

**Chiedere un aggiornamento (`u`)** invia all'agente, con
`cx.agents:ask`, questo prompt:

> Status check from Control Room: in a few lines, what have you done so far,
> what are you doing now, and is anything blocking you or waiting on me?

La risposta resta fissata nella scheda (sezione *Reply to the update request*,
e nella riga con il prefisso `update:`) anche se l'agente riprende subito a
lavorare: sparisce solo quando un turno successivo finisce con un messaggio
più nuovo, che allora compare come *Last message from the agent*. Il testo è
l'ultimo messaggio dell'agente alla fine del turno che risponde alla
richiesta. Se dopo 10 minuti non è arrivata nessuna risposta, la richiesta
viene lasciata cadere.

Per cambiare il testo della richiesta, imposta la chiave `ask_prompt` nel
`kv.json` del plugin (`<state>/plugin-data/control-room/kv.json`).

**Failures** elenca gli ultimi 20 comandi con exit ≠ 0 arrivati come evento
`command_finished` a una finestra con il plugin caricato, solo per i pane
ancora aperti. Stanno nel `kv.json` (chiave `failures`), quindi sopravvivono
al reload. Il tasto destro su una riga porta al pane o ne fa il peek.

## Aprirlo

- Palette: **Open Control Room** (porta a fuoco quello già aperto nella
  finestra, altrimenti lo apre in un nuovo tab);
- tasti: `ctrl+alt+shift+r` (`cmd+alt+shift+r` su macOS). Per un'altra
  combinazione aggiungi in `settings.json` una voce `keybinds`, che vince su
  tutto (`ctrl+alt+shift+c` di suo è del canvas, `canvas.copy_as_png`):

  ```json
  { "keybinds": { "ctrl+alt+shift+c": "plugin.control-room.open" } }
  ```

- palette: **New Control Room block**, per aprirne altri.

Il blocco è un pane del daemon: sopravvive alla chiusura delle finestre, ai
reload del plugin e ai riavvii del daemon.

## Installazione

Serve Tern 0.9 o successivo, sulla macchina dove girano i pane.

Da GitHub (Tern lo clona con `git` nella sua cartella dei plugin):

```sh
tern plugin install github.com/Ioshiro/tern-control-room
```

Per aggiornarlo: `tern plugin install github.com/Ioshiro/tern-control-room --force`.

Da una copia locale, per usarlo dalla cartella in cui si trova (consigliato
mentre lo si modifica, Tern lo ricarica a ogni salvataggio):

```sh
git clone https://github.com/Ioshiro/tern-control-room
tern plugin link ./tern-control-room
```

Verifica con `tern plugin list`, che deve mostrare
`control-room 0.2.0 Control Room — 1 blocks, 0 lenses, window  ready`.
Per rimuoverlo: `tern plugin remove control-room` (o `tern plugin unlink control-room`
se era collegato).

## Come funziona

```
window.luau (in ogni finestra)               host.luau (nel daemon)
  legge cx.session, cx.sessions,  ── snapshot ─▶  blocco "room": viste, filtro,
  cx.agents a ogni evento e ogni 5 s   ── peek ──▶  ordinamento, pagina
  esegue go / park / ask / peek  ◀── control-room://<azione>/<pane> ──
```

Il blocco gira nel daemon, che conosce solo titolo, cartella e "busy" dei
pane. Sessioni, tab, agenti, comandi e parcheggio sono visibili solo dalla
metà finestra del plugin, che quindi:

1. legge il modello di Tern a ogni evento (fuoco, pane/tab aperti o chiusi,
   comando iniziato/finito, titolo, cartella, stato e fine turno di un agente,
   sessione chiusa) e, come battito, ogni 5 secondi; invia lo snapshot al
   blocco come evento di vista; il blocco tiene solo l'ultimo;
2. riceve le azioni dal blocco come link `control-room://…`, accettati solo
   se vengono da un blocco Control Room, e li esegue una volta sola anche con
   più finestre aperte; un *peek* risponde con un secondo evento di vista.

Lo stato tenuto dalla finestra è: quando ha visto cambiare un pane (Tern non
lo riporta), quale agente ha avuto l'ultimo turno fallito, e la richiesta di
aggiornamento in corso con la sua risposta; si azzera al reload. Senza
snapshot da più di 25 secondi il blocco lo segnala; finché nessuna finestra
ha riferito, mostra solo ciò che sa il daemon.

## Limiti noti

- **I comandi richiedono l'integrazione della shell** (marcatori OSC 133):
  senza, Tern non riporta comando in corso, ultimo comando ed exit code, e
  quelle informazioni mancano (non vengono dedotte). Su Windows, PowerShell 5
  in questa configurazione non li emetteva. Il *peek* mostra comunque le
  ultime righe del pane.
- Lo snapshot copre le sessioni **di questa finestra** (`cx.session`), come
  le vede Tern. Il client web non esegue Lua: lì il blocco mostra l'ultimo
  stato ricevuto, che invecchia (e lo dice).
- "Da quanto" conta da quando la finestra ha visto il cambiamento: dopo un
  reload resta vuoto finché qualcosa cambia.
- Il messaggio dell'agente è quello che riporta `cx.agents:list()`
  (`last_message`); la chat del *peek* viene da `cx.agents:transcript`, che
  per gli agenti non omp è vuota. I messaggi di soli tool call compaiono come
  `(N tool calls, no text)`.

## Sviluppo

- `host.luau`: il blocco (pagina, viste, tasti, filtri, ordinamento).
- `window.luau`: snapshot, peek, azioni, comando di palette e tasto.
- `common.luau`: tipi dello snapshot e del peek, classificazione degli stati,
  utilità.

Controllo dei tipi con [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp):

```sh
tern plugin types .
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau common.luau
```

`dev/` contiene due aiuti per provarlo senza agenti o shell reali:

- `dev/fake_agent.py`: un "agente" che segnala lavoro/attesa con OSC 9;4.
  Imposta come comando degli agenti `python -u <percorso>/dev/fake_agent.py`
  e apri un blocco agente;
- `dev/osc133.ps1`: in un pane PowerShell, `& dev/osc133.ps1 -Line 'npm test' -Status 3`
  simula un comando che finisce con quell'exit code (compare in *Failures*).

Per provarlo senza toccare la propria configurazione, avvia Tern con una
configurazione e un daemon separati:

```sh
TERN_CONFIG_DIR=/tmp/tern-dev TERN_DAEMON_SOCKET=/tmp/tern-dev.sock tern --control 47911 .
TERN_CONFIG_DIR=/tmp/tern-dev tern plugin link .
tern ctl --control 47911 plugins run plugin.control-room.open
```

## Licenza

MIT, vedi `LICENSE`.
