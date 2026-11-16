# Privacy

## Nessuna rete

minivu non si connette mai a Internet. Viene eseguito nella sandbox delle app
senza l’autorizzazione di rete, quindi macOS non gli permette di aprire
alcuna connessione. Non ci sono account, analisi, segnalazioni di arresti
anomali né controlli degli aggiornamenti, e questo aiuto fa parte dell’app.

Testo live, Rimuovi sfondo, Copia soggetto, il rilevamento degli occhi rossi,
la funzione Automatico di Prospettiva e Immagini simili di Trova duplicati
usano il framework Vision di Apple, sul tuo Mac. Nulla viene inviato altrove.

**Archivio > Condividi…** passa i file al servizio di condivisione che
scegli, come AirDrop o Mail, che poi li invia. minivu stesso non apre alcuna
connessione.

## Cosa può vedere minivu

La sandbox limita minivu a:

- la cartella **Immagini**;
- le cartelle e i file che scegli in un pannello Apri o Salva, che trascini
  su minivu o che apri con minivu dal Finder;
- le cartelle nella barra laterale e le cartelle recenti di Copia in e Sposta
  in, che ricorda con segnalibri utilizzabili solo da questo Mac e da questa
  app;
- un’immagine scelta per una filigrana, che ricorda con un segnalibro di
  sola lettura;
- il proprio contenitore, `~/Library/Containers/com.minivu.app`.

Funziona solo con l’archiviazione interna del tuo Mac, non con schede di
memoria, unità esterne o condivisioni di rete.

## Cosa conserva minivu

Nel proprio contenitore, solo sul tuo Mac:

- **Il catalogo** delle valutazioni a stelle, dei tag, degli ordini
  personalizzati, delle raccolte, delle cartelle smart e dei dettagli delle
  foto letti per filtri e ricerche.
- **La cache delle miniature**, con le impronte create da Trova duplicati,
  che **Impostazioni > Miniature > Svuota cache delle miniature** svuota.
- **Le impostazioni**, incluse le cartelle della barra laterale, le cartelle
  recenti, la musica delle presentazioni, gli editor esterni e i preset.

Le ricerche leggono solo le cartelle che minivu può vedere, sul tuo Mac.
minivu non interroga Spotlight.

## Cosa modifica minivu nei tuoi file

Solo ciò che chiedi:

- **Salva** scrive sopra l’originale, dopo aver chiesto conferma. **Salva
  come**, Converti in blocco, Estrai pagine, Crea file multipagina, Striscia
  di immagini, Foglio provini, Montaggio, Esporta video della presentazione
  e Crea galleria web creano nuovi file.
- La rotazione e la riflessione nel browser modificano il tag di
  orientamento di un JPEG, e Modifica commento ne modifica il commento.
- **Modifica metadati** scrive i dettagli che modifichi nel file, oppure in
  un file sidecar XMP accanto a esso.
- **Immagine > Etichetta** imposta il tag colore del Finder del file. Le
  stelle e i tag vengono scritti nei file solo se attivi **Scrivi le
  valutazioni nei file (XMP)** nelle impostazioni.
- Un’azione di minivu nell’app Comandi rapidi può convertire, ridimensionare,
  rinominare, valutare o etichettare i file che minivu può modificare.
- Rinomina, Sposta, Copia, Nuova cartella e Rinomina in blocco modificano
  nomi e cartelle, e possono essere annullati.
- **Sposta nel Cestino**, e la sostituzione di un file con lo stesso nome,
  mettono gli elementi nel Cestino. minivu non elimina i tuoi file.
- I file vengono prima scritti per intero e poi messi al loro posto, così un
  salvataggio interrotto non lascia mai un file a metà.

**Posizione.** Salva come, Converti in blocco, Crea galleria web e le azioni
di Comandi rapidi escludono la posizione GPS e i nomi dei luoghi, a meno che
tu non disattivi **Rimuovi posizione**. Salva mantiene tutto, posizione
inclusa. La posizione di un video viene mostrata ma mai rimossa.

minivu scrive anche in **Immagini/minivu Captures** (catture dello schermo) e
**Immagini/minivu Wallpapers** (montaggi e copie create per Imposta come
sfondo della scrivania, di cui conserva le dieci più recenti).

## Autorizzazioni

- **Registrazione schermo**, solo se usi Cattura > Schermo intero o
  Selezione. Puoi disattivarla in Impostazioni di Sistema > Privacy e
  sicurezza.
- **Stampa**, tramite il pannello di stampa standard.
