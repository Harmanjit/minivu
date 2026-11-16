# Modifica delle immagini

Le modifiche si effettuano nel visore. Le modifiche vengono conservate come
un elenco di passaggi e mostrate mentre le apporti, ma nulla cambia sul disco
finché non salvi.

## Aprire uno strumento

Scegli uno strumento dal menu **Immagine**, oppure sposta il puntatore sul
bordo sinistro del visore e sceglilo dal pannello. I controlli dello
strumento prendono il posto del pannello, che resta aperto mentre lavori.

- **Applica** aggiunge la modifica all’immagine, **Annulla** la esclude e
  **Ripristina** riporta i controlli alla posizione iniziale.
- Nel pannello, **Ruota e rifletti** ed **Effetti colore** applicano
  subito ogni pulsante; **Fine** li chiude.
- Negli strumenti con cui disegni o dipingi, scegliendo un altro comando
  viene applicato quanto fatto finora, invece di scartarlo.

## Gli strumenti

- **Ruota a sinistra**, **Ruota a destra**, **Rifletti orizzontalmente**,
  **Rifletti verticalmente**.
- **Ridimensiona/Ricampiona…** imposta nuove dimensioni in pixel o in
  percentuale, mantenendo o meno le proporzioni, con uno degli 11 filtri di
  ricampionamento, da Box e Bilineare a Lanczos 8.
- **Dimensioni tela…** ingrandisce o riduce la tela intorno all’immagine, in
  pixel o in percentuale. Scegli dove si trova l’immagine con l’ancoraggio
  3 × 3 e riempi il nuovo spazio con un colore o lascialo trasparente. Una
  tela più piccola ritaglia l’immagine.
- **Ritaglia…**: trascina il rettangolo o le sue maniglie. Scegli Libero, la
  forma originale dell’immagine oppure 1:1, 4:3, 3:2, 16:9 o 5:4, in
  verticale o in orizzontale.
- **Raddrizza…** ruota l’immagine fino a 45° in entrambe le direzioni e
  ritaglia gli angoli vuoti.
- **Prospettiva…** raddrizza un soggetto fotografato di sbieco, come un
  documento o un edificio. Trascina le quattro maniglie degli angoli sugli
  angoli di qualcosa che dovrebbe essere rettangolare, oppure fai clic su
  **Automatico** per trovarlo. **Mostra risultato** mostra un’anteprima della
  correzione.
- **Regola > Regolazioni RAW…**, solo per i file RAW della fotocamera:
  esposizione, potenziamento (contrasto), recupero delle alte luci,
  bilanciamento del bianco e riduzione rumore, partendo dalle impostazioni
  della fotocamera stessa. minivu non può salvare sopra un file RAW, quindi
  salva il risultato con **Salva come…**.
- **Regola > Illuminazione…**: luminosità, contrasto, gamma, ombre e alte
  luci.
- **Regola > Colori…**: tonalità, saturazione, luminosità, temperatura e
  tinta, e i canali rosso, verde e blu separati.
- **Regola > Curve…** e **Livelli…** per un controllo preciso dei toni.
- **Regola > Miglioramento automatico** migliora toni e colori con un solo
  clic. Se la foto non ha bisogno di nulla, minivu emette un segnale
  acustico.
- **Regola > Nitidezza…**, **Sfocatura…** e **Riduzione rumore…**. La
  riduzione rumore attenua la grana e mantiene i contorni; il cursore
  Nitidezza recupera i dettagli.
- **Modifica commento…** imposta il commento memorizzato in un file JPEG.
  Viene scritto nel file quando fai clic su Salva nell’editor dei commenti.
- **Modifica metadati…** (**⌘I**) modifica i dettagli del file. Consulta
  Metadati più avanti.

Per effetti, disegno e ritocco, consulta
[Effetti e ritocco](help:Effects).

## Metadati

I metadati sono le informazioni memorizzate con una foto: chi l’ha scattata,
quando, dove, e un titolo o delle parole chiave. **Immagine > Modifica
metadati…** (**⌘I**) li modifica per l’immagine visualizzata, o per tutte le
immagini selezionate nel browser.

- **Descrizione:** titolo, didascalia, autore e copyright.
- **Parole chiave:** aggiungi parole chiave, separate da virgole, oppure
  rimuovine una da tutte le immagini.
- **Data di scatto:** sposta la data di giorni, ore, minuti e secondi,
  oppure imposta una nuova data e ora.
- **Posizione:** **Rimuovi posizione** elimina la posizione GPS e i nomi
  dei luoghi.

Con più immagini, un campo il cui valore è diverso mostra “Misto”. Lascialo
vuoto per mantenere il valore di ogni file. Vengono scritti solo i campi che
modifichi.

I metadati vengono scritti nel file senza ricodificare l’immagine. I file RAW
della fotocamera, e i formati che minivu non può riscrivere, ricevono invece
un sidecar XMP: un piccolo file con lo stesso nome accanto alla foto, letto
anche da altre app.

## Annullare

**Modifica > Annulla** e **Ripeti** scorrono avanti e indietro tra le
modifiche, fino a 50 passaggi. Annullare non richiede memoria aggiuntiva,
quindi puoi tornare indietro tutte le volte che vuoi. Dopo il salvataggio,
la cronologia delle modifiche ricomincia.

## Salvare

- **Archivio > Salva** scrive l’immagine modificata sopra l’originale, nello
  stesso formato, spazio colore e profondità di bit, con i suoi metadati.
  minivu chiede conferma prima di sostituire l’originale; se gli hai detto
  di non chiederlo più, riattiva **Chiedi prima di sovrascrivere
  l’originale** in **Impostazioni > Generali**.
- minivu non può riscrivere alcuni formati, come RAW, WebP, PDF, file
  animati e multipagina. Per questi, Salva apre Salva come.
- **Archivio > Salva come…** salva un nuovo file. Scegli il formato (JPEG,
  PNG, HEIC, AVIF se il tuo Mac può scriverlo, TIFF, BMP, GIF, TGA, JPEG 2000
  o ICO) e le relative opzioni: qualità, profilo colore, metadati,
  progressivo, 16 o 10 bit per canale, compressione TIFF e sfondo per la
  trasparenza.
- **Rimuovi posizione**, sotto Mantieni metadati, esclude la posizione GPS e
  i nomi dei luoghi dal nuovo file. È attivata all’inizio. Salva, e Salva
  come sopra il file originale, mantengono sempre la posizione. Il pannello
  mostra le dimensioni del file risultanti dalle opzioni e può aprire un
  confronto affiancato tra l’originale e il risultato compresso al 100, 200
  o 400%. Le opzioni vengono ricordate per ogni formato.
- **Archivio > Ripristina versione salvata** elimina le modifiche non
  salvate.
- **Archivio > Salva modifiche come preset…** conserva le modifiche come
  preset, così **Strumenti > Converti in blocco…** può applicarle a molte
  immagini. Il foglio elenca i passaggi che può usare e quelli che esclude,
  con il motivo. Consulta [Strumenti](help:Tools).
- Se passi a un’altra immagine, torni al browser o esci con modifiche non
  salvate, minivu chiede prima se salvarle.

> Se un’altra app modifica il file mentre hai modifiche non salvate, minivu
> chiede se mantenere le modifiche o ricaricare il file. Se le mantieni,
> Salva diventa Salva come, così nessuna delle due versioni va persa.

Il salvataggio di una foto HDR sopra l’originale la scrive come immagine a
gamma dinamica standard.
