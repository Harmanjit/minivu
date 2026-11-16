# Privacy

## Nessuna rete

minivu non si connette mai a Internet. Viene eseguito nella sandbox delle app
senza l’autorizzazione di rete, quindi macOS non gli permette di aprire
alcuna connessione. Non ci sono account, analisi, segnalazioni di arresti
anomali né controlli degli aggiornamenti, e questo aiuto fa parte dell’app.

## Cosa può vedere minivu

La sandbox limita minivu a:

- la cartella **Immagini**;
- le cartelle e i file che scegli in un pannello Apri o Salva, che trascini
  su minivu o che apri con minivu dal Finder;
- le cartelle nella barra laterale e le cartelle recenti di Copia in e Sposta
  in, che ricorda con segnalibri utilizzabili solo da questo Mac e da questa
  app;
- il proprio contenitore, `~/Library/Containers/com.minivu.app`.

Funziona solo con l’archiviazione interna del tuo Mac, non con schede di
memoria, unità esterne o condivisioni di rete.

## Cosa conserva minivu

Nel proprio contenitore, solo sul tuo Mac:

- **Il catalogo** delle valutazioni a stelle, dei tag e degli ordini
  personalizzati.
- **La cache delle miniature**, che **Impostazioni > Miniature > Svuota cache
  delle miniature** svuota.
- **Le impostazioni**, incluse le cartelle della barra laterale, le cartelle
  recenti, la musica delle presentazioni e gli editor esterni.

## Cosa modifica minivu nei tuoi file

Solo ciò che chiedi:

- **Salva** scrive sopra l’originale, dopo aver chiesto conferma. **Salva
  come**, Converti in blocco, Foglio provini e Montaggio creano nuovi file.
- La rotazione e la riflessione nel browser modificano il tag di
  orientamento di un JPEG, e Modifica commento ne modifica il commento.
- Rinomina, Sposta, Copia, Nuova cartella e Rinomina in blocco modificano
  nomi e cartelle, e possono essere annullati.
- **Sposta nel Cestino**, e la sostituzione di un file con lo stesso nome,
  mettono gli elementi nel Cestino. minivu non elimina i tuoi file.
- I file vengono prima scritti per intero e poi messi al loro posto, così un
  salvataggio interrotto non lascia mai un file a metà.

minivu scrive anche in **Immagini/minivu Captures** (catture dello schermo) e
**Immagini/minivu Wallpapers** (montaggi e copie create per Imposta come
sfondo della scrivania, di cui conserva le dieci più recenti).

## Autorizzazioni

- **Registrazione schermo**, solo se usi Cattura > Schermo intero o
  Selezione. Puoi disattivarla in Impostazioni di Sistema > Privacy e
  sicurezza.
- **Stampa**, tramite il pannello di stampa standard.

Il rilevamento degli occhi rossi trova i volti con il framework Vision di
Apple, sul tuo Mac.
