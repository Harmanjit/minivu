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
- **Ritaglia…**: trascina il rettangolo o le sue maniglie. Scegli Libero, la
  forma originale dell’immagine oppure 1:1, 4:3, 3:2, 16:9 o 5:4, in
  verticale o in orizzontale.
- **Raddrizza…** ruota l’immagine fino a 45° in entrambe le direzioni e
  ritaglia gli angoli vuoti.
- **Regola > Illuminazione…**: luminosità, contrasto, gamma, ombre e alte
  luci.
- **Regola > Colori…**: tonalità, saturazione, luminosità, temperatura e
  tinta, e i canali rosso, verde e blu separati.
- **Regola > Curve…** e **Livelli…** per un controllo preciso dei toni.
- **Regola > Nitidezza…** e **Sfocatura…**.
- **Modifica commento…** imposta il commento memorizzato in un file JPEG.
  Viene scritto nel file quando fai clic su Salva nell’editor dei commenti.

Per effetti, disegno e ritocco, consulta
[Effetti e ritocco](help:Effects).

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
- minivu non può riscrivere alcuni formati, come RAW, WebP, AVIF, PDF, file
  animati e multipagina. Per questi, Salva apre Salva come.
- **Archivio > Salva come…** salva un nuovo file. Scegli il formato (JPEG,
  PNG, HEIC, TIFF, BMP, GIF, TGA, JPEG 2000 o ICO) e le relative opzioni:
  qualità, profilo colore, metadati, progressivo, 16 bit, compressione TIFF
  e sfondo per la trasparenza. Il pannello mostra le dimensioni del file
  risultanti dalle opzioni e può aprire un confronto affiancato tra
  l’originale e il risultato compresso al 100, 200 o 400%. Le opzioni
  vengono ricordate per ogni formato.
- **Archivio > Ripristina versione salvata** elimina le modifiche non
  salvate.
- Se passi a un’altra immagine, torni al browser o esci con modifiche non
  salvate, minivu chiede prima se salvarle.

> Se un’altra app modifica il file mentre hai modifiche non salvate, minivu
> chiede se mantenere le modifiche o ricaricare il file. Se le mantieni,
> Salva diventa Salva come, così nessuna delle due versioni va persa.

Il salvataggio di una foto HDR sopra l’originale la scrive come immagine a
gamma dinamica standard.
