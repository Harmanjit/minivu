# Edycja

Edycja odbywa się w widoku obrazu. Zmiany są przechowywane jako lista kroków
i widoczne od razu, ale nic na dysku się nie zmienia, dopóki ich nie
zachowasz.

## Otwieranie narzędzia

Wybierz narzędzie z menu **Obraz** lub przesuń wskaźnik do lewej krawędzi
widoku obrazu i wybierz je z panelu. Elementy sterujące narzędzia zajmują
miejsce panelu, a narzędzie pozostaje otwarte podczas pracy.

- **Zastosuj** dodaje zmianę do obrazu, **Anuluj** ją pomija, a **Wyzeruj**
  przywraca początkowe ustawienia elementów sterujących.
- W panelu **Obróć i odbij** oraz **Efekty kolorów** stosują każdy przycisk
  od razu; **Gotowe** je zamyka.
- W narzędziach do rysowania i malowania wybranie innego polecenia stosuje
  to, co już zrobiono, zamiast to odrzucać.

## Narzędzia

- **Obróć w lewo**, **Obróć w prawo**, **Odbij w poziomie**, **Odbij w
  pionie**.
- **Zmień rozmiar/próbkowanie…** ustawia nowy rozmiar w pikselach lub
  procentach, z zachowaniem proporcji lub bez, za pomocą jednego z 11 filtrów
  próbkowania, od prostokątnego i dwuliniowego po Lanczos 8.
- **Rozmiar płótna…** powiększa lub zmniejsza płótno wokół obrazu, w
  pikselach lub procentach. Wybierz położenie obrazu za pomocą
  zakotwiczenia 3 × 3 i wypełnij nowe miejsce kolorem lub pozostaw je
  przezroczyste. Mniejsze płótno przycina obraz.
- **Kadruj…**: przeciągnij prostokąt lub jego uchwyty. Wybierz proporcje
  Dowolne, oryginalny kształt obrazu albo 1:1, 4:3, 3:2, 16:9 lub 5:4, w
  pionie lub w poziomie.
- **Wyprostuj…** obraca obraz o maksymalnie 45° w dowolną stronę i odcina
  puste narożniki.
- **Perspektywa…** prostuje coś sfotografowanego pod kątem, na przykład
  dokument lub budynek. Przeciągnij cztery uchwyty narożników na narożniki
  czegoś, co powinno być prostokątne, lub kliknij **Auto**, aby to znaleźć.
  **Pokaż wynik** pokazuje podgląd korekty.
- **Dopasuj > Korekty RAW…**, tylko dla surowych plików z aparatu:
  ekspozycja, wzmocnienie (kontrast), odzyskiwanie jasnych partii, balans
  bieli i redukcja szumu, zaczynając od ustawień samego aparatu. minivu nie
  może zachować zmian w miejsce pliku RAW, więc zachowaj wynik za pomocą
  **Zachowaj jako…**.
- **Dopasuj > Oświetlenie…**: jasność, kontrast, gamma, cienie i jasne
  partie.
- **Dopasuj > Kolory…**: odcień, nasycenie, jasność, temperatura i
  zabarwienie oraz osobno czerwony, zielony i niebieski.
- **Dopasuj > Krzywe…** i **Poziomy…** do precyzyjnej kontroli tonów.
- **Dopasuj > Automatyczne ulepszanie** poprawia tony i kolory jednym
  kliknięciem. Jeśli zdjęcie niczego nie wymaga, minivu wydaje sygnał
  dźwiękowy.
- **Dopasuj > Wyostrz…**, **Rozmycie…** i **Redukcja szumu…**. Redukcja
  szumu wygładza ziarno i zachowuje krawędzie; jej suwak Ostrość przywraca
  szczegóły.
- **Edytuj komentarz…** ustawia komentarz przechowywany w pliku JPEG.
  Zostaje on zapisany w pliku po kliknięciu Zachowaj w edytorze komentarza.
- **Edytuj metadane…** (**⌘I**) zmienia informacje o pliku. Zobacz
  Metadane poniżej.

Informacje o efektach, rysowaniu i retuszu znajdziesz w temacie
[Efekty i retusz](help:Effects).

## Metadane

Metadane to informacje przechowywane razem ze zdjęciem: kto je wykonał,
kiedy, gdzie, a także tytuł lub słowa kluczowe. **Obraz > Edytuj metadane…**
(**⌘I**) pozwala je edytować dla pokazanego obrazu lub dla wszystkich
obrazów zaznaczonych w przeglądarce.

- **Opis:** tytuł, podpis, autor i prawa autorskie.
- **Słowa kluczowe:** dodaj słowa kluczowe, rozdzielone przecinkami, lub
  usuń jedno ze wszystkich obrazów.
- **Data wykonania:** przesuń datę o dni, godziny, minuty i sekundy lub
  ustaw nową datę i godzinę.
- **Lokalizacja:** **Usuń lokalizację** usuwa pozycję GPS i nazwy miejsc.

Przy kilku obrazach pole, którego wartość się różni, pokazuje „Mieszane”.
Pozostaw je puste, aby zachować własną wartość każdego pliku. Zapisywane są
tylko pola, które zmienisz.

Metadane są zapisywane w pliku bez ponownego kodowania obrazu. Surowe pliki
z aparatu oraz formaty, których minivu nie może zapisać ponownie, otrzymują
zamiast tego plik dodatkowy XMP: mały plik o tej samej nazwie obok zdjęcia,
który odczytują też inne aplikacje.

## Cofanie

**Edycja > Cofnij** i **Powtórz** przechodzą wstecz i naprzód przez zmiany,
do 50 kroków. Cofanie nie zużywa dodatkowej pamięci, więc możesz cofać się
tak często, jak chcesz. Po zachowaniu historia cofania zaczyna się od nowa.

## Zachowywanie

- **Plik > Zachowaj** zapisuje edytowany obraz w miejsce oryginału, w tym
  samym formacie, przestrzeni kolorów i głębi bitowej, razem z metadanymi.
  minivu pyta przed zastąpieniem oryginału; jeśli wybrano, aby więcej nie
  pytać, włącz ponownie opcję **Pytaj przed zachowaniem w miejsce oryginału**
  w **Ustawienia > Ogólne**.
- minivu nie może zapisywać z powrotem niektórych formatów, takich jak RAW,
  WebP, PDF, pliki animowane i wielostronicowe. W ich przypadku Zachowaj
  otwiera okno Zachowaj jako.
- **Plik > Zachowaj jako…** zachowuje nowy plik. Wybierz format (JPEG, PNG,
  HEIC, AVIF, jeśli Twój Mac może go zapisywać, TIFF, BMP, GIF, TGA, JPEG
  2000 lub ICO) i jego opcje: jakość, profil kolorów, metadane, tryb
  progresywny, 16 lub 10 bitów na kanał, kompresję TIFF i tło
  przezroczystości.
- **Usuń lokalizację**, w sekcji Zachowaj metadane, pomija w nowym pliku
  pozycję GPS i nazwy miejsc. Jest domyślnie włączona. Zachowaj oraz
  Zachowaj jako w miejsce oryginalnego pliku zawsze zachowują lokalizację.
  Panel pokazuje rozmiar pliku, jaki dadzą wybrane opcje, i może otworzyć
  porównanie oryginału ze skompresowanym wynikiem obok siebie w skali 100,
  200 lub 400%. Opcje są zapamiętywane dla każdego formatu.
- **Plik > Przywróć zachowaną wersję** odrzuca niezachowane zmiany.
- **Plik > Zachowaj zmiany jako preset…** zachowuje zmiany jako preset, aby
  **Narzędzia > Konwersja wsadowa…** mogła zastosować je do wielu obrazów.
  Arkusz wymienia kroki, których może użyć, oraz te, które pomija, z
  podaniem przyczyny. Zobacz [Narzędzia](help:Tools).
- Jeśli przejdziesz do innego obrazu, wrócisz do przeglądarki lub zakończysz
  pracę z niezachowanymi zmianami, minivu najpierw zapyta, czy je zachować.

> Jeśli inna aplikacja zmieni plik, gdy masz niezachowane zmiany, minivu
> zapyta, czy zachować Twoje zmiany, czy wczytać plik ponownie. Jeśli je
> zachowasz, Zachowaj zmieni się w Zachowaj jako, więc żadna wersja nie
> zostanie utracona.

Przy zachowywaniu zdjęcia JPEG, HEIC i AVIF z mapą wzmocnienia (dodatkowymi
danymi, które mówią ekranowi HDR, jak jasna może być każda część) pozostają w
HDR. Inne zdjęcia HDR są zachowywane w standardowym zakresie dynamicznym, a
minivu mówi o tym przed zachowaniem.
