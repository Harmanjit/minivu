# Outils

Le menu **Outils** agit sur ce que vous regardez. Dans le navigateur, un
outil utilise les images sélectionnées, ou toutes les images affichées
lorsque rien n’est sélectionné. Dans la visionneuse, il utilise l’image à
l’écran. Les outils qui créent des images, ainsi que le diaporama, ignorent
les vidéos.

## Diaporama

**Outils > Lancer le diaporama** lit les images en plein écran, avec le HDR
comme dans la visionneuse. Il s’ouvre sur l’écran choisi par **La visionneuse
plein écran s’ouvre sur** dans **Réglages > Visionneuse**. Si vous partez d’une
seule image sélectionnée, tout le dossier est lu à partir de celle-ci.

- **Espace** met en pause et reprend, les touches fléchées font avancer ou
  reculer, et **Échap** arrête le diaporama. Déplacez le pointeur pour faire
  apparaître la barre de commandes.
- Choisissez la durée par diapositive, l’ordre (dans l’ordre ou aléatoire),
  le fait de recommencer ou non à la fin, les légendes, et l’une des huit
  transitions ou une transition aléatoire dans **Réglages > Diaporama**.
- Ajoutez-y aussi de la musique : morceaux MP3, AAC, WAV ou AIFF, ou
  dossiers en contenant. La musique disparaît en fondu à la fin du
  diaporama.

### Exporter en vidéo

**Outils > Exporter la vidéo du diaporama…** enregistre le diaporama sous
forme de fichier vidéo, à lire ou à envoyer n’importe où.

- Choisissez la résolution (720p, 1080p, 4K ou la taille de votre écran),
  la fréquence d’images, le codec (H.264, ou HEVC pour des fichiers plus
  petits), la qualité, et MP4 ou MOV.
- La vidéo utilise la durée des diapositives, la transition, l’ordre, les
  légendes et la musique définis dans **Réglages > Diaporama**. Chaque
  image apparaît une seule fois.
- La vidéo est en plage dynamique standard : les photos HDR font l’objet
  d’une adaptation de la tonalité.
- Exporter… demande où l’enregistrer. Une barre de progression avec un
  bouton Annuler s’affiche ensuite.

## Convertir par lot

**Outils > Convertir par lot…** enregistre des copies de nombreuses images
dans un autre format.

- Choisissez le format et ses options, comme dans Enregistrer sous, ainsi
  qu’une destination : un dossier, ou à côté des originaux. **Supprimer le
  lieu** exclut la position GPS des copies ; cette option est activée au
  départ.
- Vous pouvez aussi renommer les copies à l’aide d’un motif, les
  redimensionner (selon le grand côté, la largeur, la hauteur ou un
  pourcentage), les faire pivoter ou leur appliquer une symétrie, et
  conserver ou supprimer leurs métadonnées.
- **Modifications** répertorie les modifications du préréglage choisi,
  créé dans la visionneuse avec **Fichier > Enregistrer comme
  préréglage…**, et les applique à chaque image. **Filigrane** ajoute un
  filigrane. Consultez [Édition d’images](help:Editing) et
  [Effets et retouches](help:Effects).
- **Conserver le HDR** conserve le HDR des photos HDR en JPEG, HEIC et
  AVIF. Cette option nécessite le profil colorimétrique Conserver l’original
  ou Display P3, et 8 bits ; sinon, les photos HDR sont écrites en plage
  dynamique standard, et la feuille l’indique.
- **Préréglage**, en haut, conserve tous les choix sous un nom, pour les
  réutiliser.
- La conversion s’exécute en arrière-plan avec une barre de progression et
  un bouton Annuler, et répertorie les fichiers qui n’ont pas pu être
  convertis.
- minivu demande confirmation avant tout remplacement, et un fichier
  remplacé est placé dans la corbeille.

**Fichiers multipages** détermine ce qu’il advient des PDF, des TIFF
multipages et des animations : **Première page uniquement** ou **Chaque
page**. Chaque page crée un seul fichier contenant toutes les pages en TIFF
et en GIF, et un fichier par page dans les autres formats.

## Renommer par lot

**Outils > Renommer par lot…** renomme de nombreux fichiers à la fois à
partir d’un motif composé de texte et de jetons : le nom d’origine, un
compteur, la date de prise de vue, la date de modification, la taille en
pixels et l’extension. Ajoutez une recherche et un remplacement ainsi
qu’une casse, et vérifiez la liste avant/après en direct, qui signale les
conflits avant toute modification. L’ensemble du changement de nom
constitue une seule étape d’**Édition > Annuler**. Un **Préréglage**
conserve un motif sous un nom.

## Pages et bandes

- **Outils > Extraire les pages…** enregistre chaque page d’un PDF ou d’un
  TIFF multipage, ou chaque image d’une animation, dans un fichier distinct.
  Choisissez toutes les pages ou une plage, ainsi que le format, comme dans
  Convertir par lot. Les noms utilisent le jeton `{page}`, le numéro de
  page : « scan-03.png ».
- **Outils > Créer un fichier multipage…** réunit les images dans un seul
  fichier : un TIFF multipage, un PDF, un GIF animé ou, si votre Mac peut
  l’écrire, un HEIC animé. Faites glisser les éléments de la liste pour
  changer l’ordre.
- **Outils > Bande d’images…** réunit les images en une seule image, côte à
  côte, les unes au-dessus des autres ou en grille, avec l’espacement et
  l’arrière-plan que vous choisissez. La bande s’ouvre dans la visionneuse.

## Rechercher les doublons

**Outils > Rechercher les doublons…** trouve les copies parmi les images
sélectionnées, dans le dossier, ou dans le dossier et ses sous-dossiers.

- **Fichiers identiques** trouve les fichiers dont le contenu est
  exactement le même. **Images similaires** trouve les images qui se
  ressemblent, comme les copies redimensionnées, les versions modifiées et
  les rafales. Déplacez le curseur **Similarité** pour rendre la recherche
  plus stricte ou plus souple.
- Dans chaque groupe, minivu suggère un fichier à garder : celui de plus
  haute résolution, le plus volumineux ou le plus ancien, selon votre choix.
  **Cocher les suggestions** coche tous les autres ; rien n’est coché tant
  que vous ne le demandez pas.
- **Placer dans la corbeille…** place les fichiers cochés dans la corbeille,
  après confirmation. **Afficher dans le navigateur** et **Comparer**
  affichent les fichiers trouvés.

## Imprimer et format d’impression

**Fichier > Imprimer…** utilise la zone de dialogue d’impression standard
avec les options de disposition de minivu : images par page, adapter ou
remplir, rotation des images pour remplir les cellules, marges, espacement
et légendes, avec un aperçu en direct. **Fichier > Format d’impression…**
permet de choisir le papier.

## Planche contact

**Outils > Planche contact…** dispose des vignettes sur des pages :
colonnes, lignes, espacement, légendes, en-tête, format de page et
arrière-plan. Enregistrez-la au format JPEG, PNG, TIFF ou PDF multipage.

## Galerie web

**Outils > Créer une galerie web…** crée un dossier de pages web qui
présentent les images : une page de vignettes, et une page pour chaque
image avec des liens Previous et Next. Ouvrez son fichier index.html dans
n’importe quel navigateur web, depuis votre Mac ou après avoir copié le
dossier sur un site web.

- Choisissez le titre, la taille des vignettes et des images, les colonnes,
  un thème clair, sombre ou automatique, l’ordre et les légendes.
- Les images sont au format JPEG, HEIC (Safari uniquement) ou AVIF. Les
  métadonnées peuvent être conservées, et **Supprimer le lieu** est activé
  au départ. **Inclure les fichiers originaux** ajoute un lien de
  téléchargement pour chaque original.
- Les pages n’utilisent aucun script et ne chargent rien depuis Internet.

## Fond d’écran montage et fond d’écran

- **Outils > Fond d’écran montage…** crée un collage des images à la taille
  de votre écran, sous forme de grille, de mosaïque ou de tirages
  éparpillés, et le définit comme fond d’écran. Les montages sont
  enregistrés dans **Images/minivu Wallpapers**.
- **Outils > Définir comme fond d’écran** utilise une image telle quelle.

## Capture

**Outils > Capture** prend une image de l’écran entier, d’une fenêtre ou d’une
sélection que vous tracez (relâcher la souris capture, **Échap** annule). Les
captures sont enregistrées sous forme de fichiers PNG dans **Images/minivu
Captures** et s’ouvrent dans la visionneuse.

La capture de l’écran entier ou d’une sélection nécessite l’autorisation
Enregistrement de l’écran. macOS la demande la première fois ; vous pouvez
la modifier ultérieurement dans **Réglages Système > Confidentialité et
sécurité > Enregistrement de l’écran et de l’audio du système**. Choisir
une fenêtre dans le sélecteur de fenêtres du système ne nécessite aucune
autorisation.

## Éditeurs externes

**Outils > Ouvrir dans un éditeur externe** envoie les images
sélectionnées, ou l’image affichée, à une autre app. Le premier éditeur de
la liste correspond à **⌘E**. Choisissez **Modifier la liste des
éditeurs…** pour ajouter des apps dans **Réglages > Éditeurs**.

Lorsqu’un éditeur enregistre un fichier, minivu affiche la nouvelle
version. Si ce fichier contenait des modifications non enregistrées dans
minivu, celui-ci vous demande s’il faut les conserver ou recharger le
fichier.

## Raccourcis

minivu ajoute des actions à l’app Raccourcis : **Convertir des images**,
**Redimensionner des images**, **Renommer des images**, **Attribuer une note**,
**Définir l’étiquette de couleur** et **Ouvrir dans minivu**. Recherchez
« minivu » parmi les actions de l’app Raccourcis pour les utiliser dans vos
propres raccourcis. L’exécution d’un tel raccourci ouvre minivu s’il n’est pas
ouvert. Les actions ne fonctionnent qu’avec les fichiers du stockage interne de
votre Mac. **Renommer des images** ne fonctionne que dans votre dossier Images
et dans les dossiers de la barre latérale de minivu ; si un fichier se trouve
ailleurs, aucun n’est renommé.

Pour utiliser un raccourci depuis le Finder, créez-en un qui reçoit des images
et activez **Utiliser comme action rapide** dans ses détails. Il apparaît alors
dans le menu contextuel du Finder, sous **Actions rapides**.
