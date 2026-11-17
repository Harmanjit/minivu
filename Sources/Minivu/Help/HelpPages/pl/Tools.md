# Narzędzia

Menu **Narzędzia** działa na tym, co oglądasz. W przeglądarce narzędzie
używa zaznaczonych obrazów lub, gdy nic nie jest zaznaczone, wszystkich
pokazanych obrazów. W widoku obrazu używa obrazu widocznego na ekranie.
Narzędzia, które tworzą obrazy, oraz pokaz slajdów pomijają wideo.

## Pokaz slajdów

**Narzędzia > Rozpocznij pokaz slajdów** odtwarza obrazy na pełnym ekranie, z
HDR tak jak w widoku obrazu. Pokaz otwiera się na ekranie wybranym w opcji
**Widok obrazu na pełnym ekranie otwiera się na** w **Ustawienia > Widok
obrazu**. Rozpoczęcie od jednego zaznaczonego obrazu odtwarza cały folder od
tego miejsca.

- **Spacja** wstrzymuje i wznawia pokaz, klawisze strzałek przechodzą o
  krok, a **Esc** kończy pokaz. Przesuń wskaźnik, aby wyświetlić pasek
  sterowania.
- Czas wyświetlania slajdu, kolejność (po kolei lub losowo), rozpoczynanie
  od nowa na końcu, podpisy oraz jedno z ośmiu przejść lub przejście losowe
  wybierzesz w **Ustawienia > Pokaz slajdów**.
- Tam dodasz też muzykę: utwory MP3, AAC, WAV lub AIFF albo foldery z nimi.
  Muzyka cichnie po zakończeniu pokazu.

### Eksportowanie jako wideo

**Narzędzia > Eksportuj wideo z pokazem slajdów…** zachowuje pokaz slajdów
jako plik wideo, który można odtworzyć lub wysłać w dowolne miejsce.

- Wybierz rozdzielczość (720p, 1080p, 4K lub rozmiar Twojego ekranu),
  liczbę klatek na sekundę, kodek (H.264 lub HEVC dla mniejszych plików),
  jakość oraz MP4 lub MOV.
- Wideo używa czasu slajdu, przejścia, kolejności, podpisów i muzyki
  ustawionych w **Ustawienia > Pokaz slajdów**. Każdy obraz pojawia się raz.
- Wideo ma standardowy zakres dynamiczny: zdjęcia HDR są mapowane tonalnie.
- Eksportuj… pyta, gdzie je zachować. Następnie pojawia się pasek postępu z
  przyciskiem Anuluj.

## Konwersja wsadowa

**Narzędzia > Konwersja wsadowa…** zachowuje kopie wielu obrazów w innym
formacie.

- Wybierz format i jego opcje, tak jak w oknie Zachowaj jako, oraz miejsce
  docelowe: folder lub obok oryginałów. **Usuń lokalizację** pomija w
  kopiach pozycję GPS; jest domyślnie włączona.
- Opcjonalnie zmień nazwy kopii według wzorca, zmień ich rozmiar (według
  dłuższego boku, szerokości, wysokości lub procentu), obróć je lub odbij
  oraz zachowaj lub usuń ich metadane.
- **Zmiany** wymienia zmiany wybranego presetu, utworzonego w widoku obrazu
  za pomocą **Plik > Zachowaj zmiany jako preset…**, i stosuje je do każdego
  obrazu. **Znak wodny** dodaje znak wodny. Zobacz [Edycja](help:Editing) i
  [Efekty i retusz](help:Effects).
- **Zachowaj HDR** zachowuje zdjęcia HDR jako HDR w formatach JPEG, HEIC i
  AVIF. Wymaga profilu kolorów Zachowaj oryginalny lub Display P3 oraz 8
  bitów; w przeciwnym razie zdjęcia HDR są zapisywane w standardowym
  zakresie dynamicznym, o czym informuje arkusz.
- **Preset** u góry zachowuje wszystkie wybory pod nazwą, aby można było ich
  użyć ponownie.
- Konwersja działa w tle z paskiem postępu i przyciskiem Anuluj, a na końcu
  wymienia pliki, których nie można było przekonwertować.
- minivu pyta, zanim cokolwiek zostanie zastąpione, a zastąpiony plik trafia
  do kosza.

**Pliki wielostronicowe** określa, co dzieje się z plikami PDF,
wielostronicowymi plikami TIFF i animacjami: **Tylko pierwsza strona** lub
**Każda strona**. Każda strona tworzy jeden plik ze wszystkimi stronami w
formatach TIFF i GIF oraz osobny plik dla każdej strony w innych formatach.

## Wsadowa zmiana nazw

**Narzędzia > Wsadowa zmiana nazw…** zmienia nazwy wielu plików naraz według
wzorca złożonego z tekstu i elementów: oryginalnej nazwy, licznika, daty
wykonania, daty modyfikacji, rozmiaru w pikselach i rozszerzenia. Dodaj
znajdowanie i zastępowanie oraz wielkość liter, a następnie sprawdź listę
„przed i po” aktualizowaną na bieżąco, która wskazuje konflikty, zanim
cokolwiek się zmieni. Cała zmiana nazw to jeden krok polecenia **Edycja >
Cofnij**. **Preset** zachowuje wzorzec pod nazwą.

## Strony i paski

- **Narzędzia > Wyodrębnij strony…** zachowuje każdą stronę pliku PDF lub
  wielostronicowego pliku TIFF albo każdą klatkę animacji jako osobny plik.
  Wybierz wszystkie strony lub zakres oraz format, tak jak w konwersji
  wsadowej. Nazwy używają elementu `{page}`, czyli numeru strony:
  „scan-03.png”.
- **Narzędzia > Utwórz plik wielostronicowy…** łączy obrazy w jeden plik:
  wielostronicowy TIFF, PDF, animowany GIF lub, jeśli Twój Mac może go
  zapisywać, animowany HEIC. Przeciągaj elementy listy, aby zmienić
  kolejność.
- **Narzędzia > Pasek obrazów…** łączy obrazy w jeden obraz, obok siebie,
  jeden nad drugim lub w siatce, z wybranym odstępem i tłem. Pasek otwiera
  się w widoku obrazu.

## Znajdowanie duplikatów

**Narzędzia > Znajdź duplikaty…** znajduje kopie wśród zaznaczonych obrazów,
w folderze lub w folderze i jego podfolderach.

- **Identyczne pliki** znajduje pliki o dokładnie tej samej zawartości.
  **Podobne obrazy** znajduje obrazy, które wyglądają podobnie, na przykład
  kopie o zmienionym rozmiarze, edytowane wersje i serie zdjęć. Przesuń
  suwak **Podobieństwo**, aby zaostrzyć lub złagodzić kryteria.
- W każdej grupie minivu sugeruje jeden plik do zachowania: o najwyższej
  rozdzielczości, największy lub najstarszy, zgodnie z Twoim wyborem.
  **Wskaż sugerowane** wskazuje wszystkie pozostałe do przeniesienia do
  kosza; nic nie jest wskazane, dopóki o to nie poprosisz.
- **Przenieś do kosza…** przenosi wskazane pliki do kosza po zapytaniu.
  **Pokaż w przeglądarce** i **Porównaj** pokazują znalezione pliki.

## Drukowanie i ustawienia strony

**Plik > Drukuj…** używa standardowego panelu drukowania z opcjami układu
minivu: liczbą obrazów na stronę, dopasowaniem lub wypełnieniem, obracaniem
obrazów, aby wypełniały komórki, marginesami, odstępami i podpisami, z
podglądem na żywo. **Plik > Ustawienia strony…** pozwala wybrać papier.

## Arkusz stykowy

**Narzędzia > Arkusz stykowy…** rozmieszcza miniatury na stronach: kolumny,
wiersze, odstępy, podpisy, nagłówek, rozmiar strony i tło. Zachowaj go jako
JPEG, PNG, TIFF lub wielostronicowy PDF.

## Galeria internetowa

**Narzędzia > Utwórz galerię internetową…** tworzy folder ze stronami
internetowymi pokazującymi obrazy: stroną z miniaturami i stroną dla
każdego obrazu z łączami do poprzedniego i następnego. Otwórz plik
index.html w dowolnej przeglądarce internetowej, z Maca lub po skopiowaniu
folderu do witryny internetowej.

- Wybierz tytuł, rozmiary miniatur i obrazów, liczbę kolumn, jasny, ciemny
  lub automatyczny motyw, kolejność i podpisy.
- Obrazy są w formacie JPEG, HEIC (tylko Safari) lub AVIF. Metadane można
  zachować, a **Usuń lokalizację** jest domyślnie włączona. **Dołącz
  oryginalne pliki** dodaje łącze do pobrania każdego oryginału.
- Strony nie używają skryptów i niczego nie wczytują z internetu.

## Tapeta z kolażu i tapeta biurka

- **Narzędzia > Tapeta z kolażu…** tworzy kolaż obrazów w rozmiarze ekranu,
  jako siatkę, mozaikę lub rozrzucone odbitki, i ustawia go jako tapetę
  biurka. Kolaże są zachowywane w folderze **Obrazki/minivu Wallpapers**.
- **Narzędzia > Ustaw jako tapetę biurka** używa jednego obrazu w obecnej
  postaci.

## Zrzut

**Narzędzia > Zrzut** wykonuje zdjęcie całego ekranu, okna lub przeciągniętego
zaznaczenia (puszczenie przycisku myszy wykonuje zrzut, **Esc** anuluje). Zrzuty
są zachowywane jako pliki PNG w folderze **Obrazki/minivu Captures** i otwierają
się w widoku obrazu.

Przechwytywanie całego ekranu lub zaznaczenia wymaga uprawnienia do
nagrywania ekranu. macOS pyta o nie za pierwszym razem; później możesz to
zmienić w **Ustawienia systemowe > Prywatność i ochrona > Nagrywanie ekranu
i dźwięku systemowego**. Wybranie okna w systemowym selektorze okien nie
wymaga uprawnienia.

## Edytory zewnętrzne

**Narzędzia > Otwórz w edytorze zewnętrznym** wysyła zaznaczone obrazy lub
pokazany obraz do innej aplikacji. Pierwszy edytor na liście otwiera się
skrótem **⌘E**. Wybierz **Edytuj listę edytorów…**, aby dodać aplikacje w
**Ustawienia > Edytory**.

Gdy edytor zachowa plik, minivu pokaże nową wersję. Jeśli w minivu były
niezachowane zmiany tego pliku, aplikacja zapyta, czy je zachować, czy
wczytać plik ponownie.

## Skróty

minivu dodaje czynności do aplikacji Skróty: **Konwertuj obrazy**, **Zmień
rozmiar obrazów**, **Zmień nazwy obrazów**, **Ustaw ocenę**, **Ustaw etykietę
kolorową** i **Otwórz w minivu**. Wyszukaj „minivu” wśród czynności w aplikacji
Skróty, aby używać ich we własnych skrótach. Jeśli minivu nie jest otwarte,
skrót uruchamia je bez okna, a minivu kończy działanie minutę po ostatniej
czynności; **Otwórz w minivu** otwiera okna jak zwykle. Czynności działają tylko
z plikami na wewnętrznym dysku Maca. **Zmień nazwy obrazów** działa tylko w
folderze Obrazki i w folderach z paska bocznego minivu; jeśli którykolwiek plik
jest gdzie indziej, nie zmienia nazwy żadnego.

Aby używać skrótu z Findera, utwórz skrót, który odbiera obrazy, i włącz w jego
szczegółach **Użyj jako szybkiej czynności**. Pojawi się wtedy w menu podręcznym
Findera w sekcji **Szybkie czynności**.
