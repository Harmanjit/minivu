# Prywatność

## Bez sieci

minivu nigdy nie łączy się z internetem. Działa w App Sandbox bez
uprawnienia do sieci, więc macOS w ogóle nie pozwala mu nawiązać połączenia.
Nie ma konta, analityki, raportowania awarii ani sprawdzania uaktualnień, a
ta pomoc jest częścią aplikacji.

## Co minivu widzi

Sandbox ogranicza minivu do:

- folderu **Obrazki**;
- folderów i plików wybranych w oknie Otwórz lub Zachowaj, upuszczonych na
  minivu albo otwartych za pomocą minivu z Findera;
- folderów z jego paska bocznego i ostatnich folderów poleceń Kopiuj do i
  Przenieś do, które zapamiętuje za pomocą zakładek możliwych do użycia
  tylko na tym Macu i w tej aplikacji;
- własnego kontenera, `~/Library/Containers/com.minivu.app`.

Działa tylko z wewnętrznym dyskiem Maca, a nie z kartami pamięci, dyskami
zewnętrznymi czy zasobami sieciowymi.

## Co minivu przechowuje

W swoim kontenerze, wyłącznie na Twoim Macu:

- **Katalog** ocen w gwiazdkach, oznaczeń i własnych kolejności.
- **Bufor miniatur**, który opróżnia polecenie **Ustawienia > Miniatury >
  Wyczyść bufor miniatur**.
- **Ustawienia**, w tym foldery z paska bocznego, ostatnie foldery, muzykę
  do pokazów slajdów i edytory zewnętrzne.

## Co minivu zmienia w plikach

Tylko to, o co poprosisz:

- **Zachowaj** zapisuje w miejsce oryginału po zapytaniu. **Zachowaj jako**,
  Konwersja wsadowa, Arkusz stykowy i Tapeta z kolażu tworzą nowe pliki.
- Obracanie i odbijanie w przeglądarce zmienia znacznik orientacji pliku
  JPEG, a Edytuj komentarz zmienia jego komentarz.
- Zmień nazwę, Przenieś, Kopiuj, Nowy folder i Wsadowa zmiana nazw zmieniają
  nazwy i foldery, a te zmiany można cofnąć.
- **Przenieś do kosza** oraz zastąpienie pliku o tej samej nazwie umieszczają
  rzeczy w koszu. minivu nie usuwa Twoich plików.
- Pliki są najpierw zapisywane w całości, a dopiero potem umieszczane na
  miejscu, więc przerwane zachowywanie nigdy nie pozostawia połowy pliku.

minivu zapisuje także w folderach **Obrazki/minivu Captures** (zrzuty
ekranu) i **Obrazki/minivu Wallpapers** (kolaże oraz kopie utworzone przez
polecenie Ustaw jako tapetę biurka, z których przechowuje dziesięć
najnowszych).

## Uprawnienia

- **Nagrywanie ekranu**, tylko jeśli używasz polecenia Zrzut > Cały ekran
  lub Zaznaczenie. Możesz je wyłączyć w Ustawienia systemowe > Prywatność i
  ochrona.
- **Drukowanie**, za pomocą standardowego panelu drukowania.

Wykrywanie czerwonych oczu znajduje twarze za pomocą frameworku Vision firmy
Apple, na Twoim Macu.
