# Control Room

Un blocco Tern persistente per rientrare nei lavori paralleli: una pagina con
tutti i pane delle sessioni di questa finestra (terminali, agenti, blocchi),
con lo stato che Tern riporta, ordinati per **attenzione prima** e **attività
recente dopo**. Da lì salti al pane, sbirci le sue ultime righe, chiedi un
aggiornamento a un agente, parcheggi o ripristini un pane. L'**Archivio**
elenca le sessioni omp chiuse, con ricerca in tutti i prompt che hai scritto,
e le riapre: puoi chiudere gli agenti che non usi senza perdere il filo.

Non è un gestore di TODO: non salva elenchi o riepiloghi propri. Ogni riga è
letta da Tern (o dai registri di omp, per l'Archivio) a ogni aggiornamento; i
messaggi degli agenti sono il loro ultimo messaggio reale, non riassunti.
L'unica cosa che scrive è la nota di passaggio che un agente lascia quando lo
archivi.

## La pagina

```
Control Room  18 panes · 7 sessions · updated 3s ago           [Live] [Refresh r]
Attention 0 │ Running 1 │ Waiting 10 │ Idle 7 │ Limits 62%
Panes 18   Agents 11   Failures 1   Limits 12   Archive 570
[⌕ filter /]                  [All | Attention | Active] [Flat | Session | Project]
Pane · Where · Status · Last · Age              ┌ pane selezionato        [Go ⏎] ┐
…righe…                                         │ fatti · azioni · peek · messaggi │
```

- **Testata**: conteggio pane e sessioni, quando è arrivato l'ultimo rapporto
  dalla finestra; il badge dice `Live`, `Stale` (nessun rapporto da più di 25 s),
  `Paused 4s` (un hook della finestra ha sforato il suo budget di tempo: Tern lo
  sospende e lo riprende da solo, da 5 s a 5 min) o `No window report` (nessuna
  finestra ha ancora riferito: si vede solo ciò che sa il daemon).
- **Strip di numeri**: quanti pane richiedono attenzione (e perché: agenti in
  attesa di input, falliti), quanti lavorano (agenti, comandi), quanti aspettano
  un prompt, quanti sono inattivi, e i **limiti** dei provider (vedi sotto).
- **Viste**: *Panes* (tutti), *Agents* (solo i pane con un agente), *Failures*
  (i comandi falliti visti da questa finestra, vedi sotto), *Limits* (limiti dei
  provider e credenziali non in uso, vedi sotto), *Archive* (le sessioni omp
  chiuse, vedi sotto).
- **Tabella**: un punto colorato per stato, titolo, sessione › tab (o *parked*),
  stato, ultimo risultato (ultimo comando con esito e durata, oppure l'ultimo
  messaggio dell'agente) e da quanto è cambiata. Le colonne meno importanti si
  nascondono quando il blocco è stretto. Il tasto destro su una riga offre le
  stesse azioni della scheda.
- **Scheda del pane selezionato**: accanto alla tabella quando ci sta, sotto
  altrimenti. La pagina sta nell'altezza del pane: scorrono solo la tabella e
  il corpo della scheda, non il blocco intero. Mostra cartella, programma, comando in
  corso e da quanto, ultimo comando con esito (`ok`, `exit N` o `interrupted`),
  modello e comando dell'agente, l'ultimo messaggio dell'agente (Markdown,
  troncato a 1500 caratteri), per un agente omp l'ultimo recap che omp ha scritto
  della sua sessione, i **servizi** che quella sessione omp tiene in background
  (`omp ps`: quelli in corso e quelli finiti da meno di 12 ore, con esito) e, dopo
  un *Peek*, le ultime righe del pane e gli ultimi scambi della chat.
- **Nomi**: un pane è chiamato col suo titolo; se il titolo è solo un percorso
  (`C:\Windows\system32\cmd.exe`) si accorcia al nome del file; se non dice nulla
  (blocchi file, git, browser, omp ripreso senza titolo) usa il file, la
  cartella del repository, l'indirizzo o il titolo che omp ha dato alla sessione.

| Stato | Quando |
| --- | --- |
| **attenzione** (rosso/ambra) | agente in attesa del tuo input; turno di un agente fallito; turno finito e non ancora visto; prompt non consegnato; ultimo comando fallito; programma uscito con codice ≠ 0; pane che non è partito; alert non visto. Un Ctrl-C (exit 130, o `0xC000013A` su Windows) non è un fallimento: la riga resta inattiva e il comando non entra in *Failures* |
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
| `u` | chiedi qualcosa all'agente selezionato (campo precompilato con lo status check) |
| `i` | interrompi il turno dell'agente (con conferma) |
| `f` | pin: pane in picture-in-picture sopra Control Room / rimettilo a posto |
| `n` | nuovo agente nella cartella del pane selezionato |
| `p` | parcheggia il pane / ripristinalo (resta a fuoco Control Room) |
| `a` | archivia l'agente: nota di passaggio, poi chiusura (con conferma) |
| `⇧U` | chiedi a tutti: un messaggio a ogni agente in elenco fermo al prompt |
| `⇧A` | archivia gli inattivi: ogni agente omp in elenco fermo da più di un'ora (con conferma) |
| `x` | archivia il problema della riga (vedi sotto) |
| `/` | filtra: digita, `Enter` conferma, `Esc` cancella; frecce, `Home`/`End` e `Canc` spostano il cursore, il mouse seleziona |
| `Tab`/`⇧Tab` (`]`/`[`) | vista: Panes → Agents → Failures → Limits → Archive |
| `v` | ambito: tutto → richiede attenzione → non inattivo |
| `g` | raggruppa: nessuno → per sessione → per progetto |
| `r` | aggiorna ora (in Limits: rilegge i limiti; nell'Archivio: rilegge le sessioni) |

Nell'Archivio `Enter` (o doppio clic) riprende la sessione, `⇧R` la riprende
e fa proseguire il turno interrotto, `.` ne mostra gli ultimi prompt e recap,
`c` copia `omp --resume <id>`, `/` cerca.

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

**Chiedere (`u`)** apre un campo precompilato con questo prompt, che puoi
riscrivere; `Enter` lo invia all'agente con `cx.agents:ask`:

> Status check from Control Room: in a few lines, what have you done so far,
> what are you doing now, and is anything blocking you or waiting on me?

La risposta resta fissata nella scheda (sezione *Reply to the update request*,
e nella riga con il prefisso `update:`) anche se l'agente riprende subito a
lavorare: sparisce solo quando un turno successivo finisce con un messaggio
più nuovo, che allora compare come *Last message from the agent*. Il testo è
l'ultimo messaggio dell'agente alla fine del turno che risponde alla
richiesta. Se dopo 10 minuti non è arrivata nessuna risposta, la richiesta
viene lasciata cadere.

Per cambiare il testo proposto, imposta la chiave `ask_prompt` nel
`kv.json` del plugin (`<state>/plugin-data/control-room/kv.json`).

**Chiedere a tutti (`⇧U`, *Ask all* nella vista Agents)** apre lo stesso campo
una volta sola e invia il testo a ogni agente dell'elenco fermo al prompt che
non deve già una risposta. **Archiviare gli inattivi (`⇧A`, *Archive idle*)**
archivia, dopo una conferma che dice quanti sono, ogni agente omp dell'elenco
fermo al prompt da più di 60 minuti (chiave `bulk_idle_minutes` nel
`kv.json`); ognuno scrive la sua nota e si chiude per conto suo. Entrambe
agiscono sulle righe che l'elenco mostra: filtro, ambito e raggruppamento
decidono a chi; i pulsanti ne mostrano il numero.

**Interrompere (`i`)** chiede conferma in una striscia in basso (`Enter`
conferma, `Esc` annulla) e poi manda Ctrl-C al turno in corso con
`cx.agents:interrupt`: l'agente e il suo blocco restano aperti.

**Pin (`f`)** mette il pane in picture-in-picture sopra Control Room
(`cx.layout:float`), anche se sta in un'altra sessione, così lo guardi senza
uscire; `f` di nuovo lo rimette dov'era: accanto al pane che aveva di fianco,
dallo stesso lato, nel suo tab (se quel pane è sparito, nel tab; se anche il
tab è sparito, in un nuovo tab della sua sessione). L'origine sta nel
`kv.json` (chiave `pinned`), quindi sopravvive al reload.

**Nuovo agente (`n`)** chiede un prompt e avvia un agente in un nuovo tab
nella cartella del pane selezionato (`cx.agents:start`).

**Failures** elenca gli ultimi 20 comandi con exit ≠ 0 arrivati come evento
`command_finished` a una finestra con il plugin caricato, solo per i pane
ancora aperti. Stanno nel `kv.json` (chiave `failures`), quindi sopravvivono
al reload. Il tasto destro su una riga porta al pane o ne fa il peek.

## Limiti dei provider

La vista **Limits** e l'ultima tessera della strip mostrano quello che `omp usage
--json` riporta: per ogni account di ogni provider le finestre di limite
(percentuale usata, quando si azzerano) e le **credenziali che omp ha disattivato**
con la causa (token revocato, refresh fallito). La tessera dice la percentuale
più alta, o `2 credentials off` se ci sono credenziali disattivate, e diventa
rossa se un limite è esaurito. `omp usage` impiega alcuni secondi: gira fuori dal
thread della UI, al caricamento, ogni 10 minuti, a un fine turno fallito (un limite
esaurito o una credenziale disattivata sono cause comuni) e con `r` nella vista.
L'ultimo rapporto sta nel `kv.json` (chiave `usage`): il blocco lo mostra subito
all'avvio.

Un proxy come CLIProxyAPI non compare: con la chiave client di `models.yml` non
espone nessun limite, e le percentuali di 5 ore e settimanali si leggono solo con
la sua chiave di gestione, facendo chiamare al proxy gli endpoint privati di
usage di Anthropic e OpenAI con il token di ogni account.

## Archivio

Le sessioni omp che nessun omp tiene aperte, dalla più recente: titolo,
progetto, dove era rimasta (la nota di passaggio, altrimenti l'ultimo recap di
omp, altrimenti il tuo ultimo prompt) e da quanto. La scheda mostra cartella,
numero di prompt, nota, recap e ultimo prompt; *Peek* aggiunge gli ultimi 6
prompt e 3 recap.

I dati sono quelli che omp tiene già, letti in sola lettura: `history.db`
(titoli, recap, ogni prompt con la sua sessione) e i nomi dei file in
`sessions/`. Una sessione è *aperta* se un omp ne tiene il lease
(`omp session lease`) o se un pane di Tern la mostra (`tern inspect`); quelle
restano fuori e la barra dice quante sono. L'elenco si rilegge quando apri la
vista (al più ogni 2 minuti), con `r` e quando si chiude un pane.

**Riprendere (`Enter`)** apre un tab nella cartella della sessione con
`omp --resume <file>`. Il resto lo fa omp: se la sessione è stata ripresa
altrove, omp apre la copia più recente. **Ripristinare (`⇧R`, *Restore*)** fa
lo stesso con `omp --restore <file>`: omp riprende anche ciò che il suo
ultimo processo aveva lasciato a metà (il turno interrotto e i subagent che
stava eseguendo), utile dopo un crash o un riavvio.

**Archiviare (`a`, nella vista Panes)** chiede conferma, poi chiede all'agente
una breve nota di passaggio (obiettivo, cosa è fatto, cosa resta, cosa non è
committato), la salva nel `kv.json` del plugin (chiave `notes`, le ultime 300)
e chiude l'agente con `cx.agents:stop`. Vale solo per un agente omp in attesa
di un prompt. Se non risponde entro 5 minuti, o la risposta è vuota, l'agente
resta aperto. La nota si lega alla sessione tramite il prompt di richiesta,
che porta un tag `[cr-<nonce>]` e finisce in `history.db` con l'id della
sessione.

**Cercare (`/`)** combina due livelli:

1. *Istantaneo*, a ogni tasto: le sessioni sono indicizzate una volta per
   elenco (titolo, progetto, cartella, nota, recap, ultimo prompt, tutto in
   minuscolo e senza accenti). Una parola vale per il campo migliore in cui
   compare (titolo 8, progetto 6, nota 5, recap 3, cartella e prompt 2), di
   più a inizio parola che dentro una parola. Se non compare, una variante
   con 1 errore (2 da 8 lettere) di una parola di titolo, progetto o nota vale
   meno.
2. *Profondo*, dopo 280 ms senza tasti: la finestra cerca in **tutti** i
   prompt che hai mai scritto con l'indice FTS5 di omp (`history_fts`, BM25,
   prefisso) e in tutti i recap. Una parola che non inizia nessuna parola
   dell'elenco viene cercata anche con le 3 più vicine (distanza di
   Levenshtein), così `swager` trova `swagger`. Il frammento del prompt
   trovato compare nella riga e nella scheda, con le parole in grassetto.

Ogni parola deve comparire da qualche parte (in uno dei due livelli); a parità
conta la recenza (dimezza ogni 14 giorni). Una ricerca su 3000 prompt e 570
sessioni richiede qualche decina di millisecondi, fuori dal thread della UI.

**Fuori dal blocco**: finché qualche pane richiede attenzione, il titolo
della finestra inizia con `⚠ N`, ogni tab che contiene pane da guardare porta
`⚠` e il loro numero davanti al nome, e la barra di stato (se attiva) mostra un
segmento `N need attention` che apre Control Room al clic.

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
`control-room 0.5.0 Control Room — 1 blocks, 0 lenses, window  ready`.
Per rimuoverlo: `tern plugin remove control-room` (o `tern plugin unlink control-room`
se era collegato).

## Come funziona

```
window.luau (in ogni finestra)               host.luau (nel daemon)
  legge cx.session, cx.sessions,  ── snapshot ─▶  blocco "room": viste, filtro,
  cx.agents a ogni evento e ogni 5 s   ── peek ──▶  ordinamento, pagina
  sessions.luau: history.db, lease  ── catalog/hits ─▶  archive.luau: indice, ranking
  esegue go / park / ask / peek / pin … ◀── control-room://<azione>/<pane|sessione> ──
```

Il blocco gira nel daemon, che conosce solo titolo, cartella e "busy" dei
pane. Sessioni, tab, agenti, comandi e parcheggio sono visibili solo dalla
metà finestra del plugin, che quindi:

1. legge il modello di Tern a ogni evento (fuoco, pane/tab aperti o chiusi,
   comando iniziato/finito, titolo, cartella, stato e fine turno di un agente,
   sessione chiusa) e, come battito, ogni 5 secondi; invia lo snapshot al
   blocco come evento di vista; il blocco tiene solo l'ultimo; uno snapshot non
   consegnato non conta come inviato e si riprova al giro dopo. L'elenco
   degli agenti (`cx.agents:list()`, la sola lettura lenta: 25–80 ms) si tiene
   tra una lettura e l'altra: un agente che inizia un turno (`agent_state`)
   aggiorna solo lo stato tenuto; si rilegge quando un turno finisce, si apre
   un pane, dopo un'azione o un *Refresh*, e sul battito: ogni 15 s mentre un
   agente lavora e un Control Room è nel tab a fuoco (l'ultimo messaggio di
   un agente al lavoro può restare indietro di 15 s), ogni 60 s altrimenti;
2. riceve le azioni dal blocco come link `control-room://…`, accettati solo
   se vengono da un blocco Control Room, e li esegue una volta sola anche con
   più finestre aperte; un *peek* risponde con un secondo evento di vista;
3. per l'Archivio interroga `history.db` con `cx.db` (sola lettura, fuori dal
   thread della UI) e chiede i lease a `omp session lease`; la ricerca
   profonda arriva come parole già scelte dal blocco, codificate in base64;
4. al caricamento, all'avvio di un blocco, alla fine di un turno e ogni
   minuto legge `tern inspect --json`: per ogni pane, da quanto non stampa
   nulla (`quiet_ms`) e quale sessione omp mostra; di quelle sessioni legge
   l'ultimo recap e il titolo in `history.db`, e chiede a `omp ps --all --json`
   i servizi in background che ciascuna possiede (circa 0,2 s, fuori dal
   thread della UI);
5. segna sulla **barra dei tab** i tab che contengono pane da guardare
   (`⚠ 2 · nome del tab`, con `tern.chrome.tab_title`): lo vedi anche con la
   barra di stato spenta e con Control Room chiuso. Il titolo della finestra
   (`⚠ N`) e il segmento della barra di stato restano.

Lo stato tenuto dalla finestra è: quando ha visto cambiare un pane (Tern non
lo riporta), quale agente ha avuto l'ultimo turno fallito, la richiesta
di aggiornamento in corso con la sua risposta e gli agenti in archiviazione;
si azzera al reload. Senza snapshot da più di 25 secondi il blocco lo
segnala; finché nessuna finestra ha riferito, mostra solo ciò che sa il
daemon.

## Limiti noti

- **I comandi richiedono l'integrazione della shell** (marcatori OSC 133):
  senza, Tern non riporta comando in corso, ultimo comando ed exit code, e
  quelle informazioni mancano (non vengono dedotte). Su Windows, PowerShell 5
  in questa configurazione non li emetteva. Il *peek* mostra comunque le
  ultime righe del pane.
- Lo snapshot copre le sessioni **di questa finestra** (`cx.session`), come
  le vede Tern. Il client web non esegue Lua: lì il blocco mostra l'ultimo
  stato ricevuto, che invecchia (e lo dice).
- "Da quanto" è il più recente tra il cambiamento visto dalla finestra e
  l'ultimo output del pane secondo il daemon (`quiet_ms`), che conta al più
  dall'avvio del daemon: dopo un riavvio di Tern i pane fermi da prima
  mostrano il tempo dal riavvio.
- Il recap di un agente vivo è quello che omp ha già scritto (non a ogni
  turno) e arriva entro un minuto; gli agenti non omp non ne hanno.
- Il messaggio dell'agente è quello che riporta `cx.agents:list()`
  (`last_message`); la chat del *peek* viene da `cx.agents:transcript`, che
  per gli agenti non omp è vuota. I messaggi di soli tool call compaiono come
  `(N tool calls, no text)`.
- L'Archivio legge lo schema interno di `history.db` di omp (`history`,
  `history_fts`, `session_titles`, `session_recaps`): un aggiornamento di omp
  che lo cambia mostra l'errore nella vista invece dell'elenco. Elenca solo
  le sessioni che hanno almeno un prompt o un recap registrato e il cui file
  esiste ancora; il percorso dei dati è `PI_CODING_AGENT_DIR`, altrimenti
  `~/.omp/agent`.
- La ricerca istantanea mette in grassetto le parole solo nei testi ASCII
  (quelli con lettere accentate restano senza evidenza); il frammento della
  ricerca profonda è sempre evidenziato.

## Sviluppo

- `host.luau`: il blocco (pagina, viste, tasti, filtri, ordinamento).
- `archive.luau`: indice e ranking dell'Archivio (lato blocco).
- `window.luau`: snapshot, peek, azioni, comando di palette e tasto.
- `sessions.luau`: elenco, lease, ricerca, peek e ripresa delle sessioni
  chiuse; note di passaggio (lato finestra).
- `common.luau`: tipi dello snapshot, del peek e dell'Archivio,
  classificazione degli stati, parole di ricerca, utilità.

Controllo dei tipi con [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp):

```sh
tern plugin types .
luau-lsp analyze --platform=standard --definitions=@tern=tern.d.luau host.luau window.luau common.luau sessions.luau archive.luau
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
