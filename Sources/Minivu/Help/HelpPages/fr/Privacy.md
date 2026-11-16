# Confidentialité

## Aucun réseau

minivu ne se connecte jamais à Internet. Il s’exécute dans l’App Sandbox
sans l’autorisation réseau : macOS ne le laisse donc ouvrir aucune
connexion. Il n’y a ni compte, ni analyse, ni rapport de plantage, ni
recherche de mises à jour, et cette aide fait partie de l’app.

Texte en direct, Supprimer l’arrière-plan, Copier le sujet, la détection des
yeux rouges, le bouton Auto de Perspective et Images similaires de
Rechercher les doublons utilisent le framework Vision d’Apple, sur votre
Mac. Rien n’est envoyé nulle part.

**Fichier > Partager…** transmet les fichiers au service de partage que vous
choisissez, comme AirDrop ou Mail, qui les envoie ensuite. minivu lui-même
n’ouvre aucune connexion.

## Ce que minivu peut voir

La sandbox limite minivu à :

- votre dossier **Images** ;
- les dossiers et fichiers que vous choisissez dans une zone de dialogue
  d’ouverture ou d’enregistrement, que vous déposez sur minivu ou que vous
  ouvrez avec minivu depuis le Finder ;
- les dossiers de sa barre latérale et les dossiers récents de Copier vers
  et Déplacer vers, qu’il mémorise à l’aide de signets que seuls ce Mac et
  cette app peuvent utiliser ;
- une image choisie pour un filigrane, qu’il mémorise à l’aide d’un signet
  en lecture seule ;
- son propre conteneur, `~/Library/Containers/com.minivu.app`.

Il ne fonctionne qu’avec le stockage interne de votre Mac, et non avec les
cartes mémoire, les disques externes ou les partages réseau.

## Ce que minivu conserve

Dans son conteneur, uniquement sur votre Mac :

- **Le catalogue** des notes par étoiles, des marques, des ordres
  personnalisés, des collections, des dossiers intelligents, et des
  informations sur les photos lues pour les filtres et les recherches.
- **Le cache des vignettes**, avec les empreintes que crée Rechercher les
  doublons, que **Réglages > Vignettes > Vider le cache des vignettes**
  vide.
- **Les réglages**, y compris les dossiers de la barre latérale, les
  dossiers récents, la musique des diaporamas, les éditeurs externes et les
  préréglages.

Les recherches ne lisent que les dossiers que minivu peut voir, sur votre
Mac. minivu n’interroge pas Spotlight.

## Ce que minivu modifie dans vos fichiers

Uniquement ce que vous demandez :

- **Enregistrer** écrit sur l’original, après confirmation. **Enregistrer
  sous**, Convertir par lot, Extraire les pages, Créer un fichier multipage,
  Bande d’images, Planche contact, Fond d’écran montage, Exporter la vidéo
  du diaporama et Créer une galerie web créent de nouveaux fichiers.
- La rotation et la symétrie dans le navigateur modifient la balise
  d’orientation d’un fichier JPEG, HEIC, TIFF ou PNG, et Modifier le commentaire
  modifie le commentaire d’un JPEG.
- **Modifier les métadonnées** écrit les informations que vous modifiez dans
  le fichier, ou dans un fichier annexe XMP placé à côté.
- **Image > Étiquette** définit le tag de couleur du Finder du fichier. Les
  étoiles et les marques ne sont écrites dans les fichiers que si vous
  activez **Écrire les notes dans les fichiers (XMP)** dans les Réglages.
- Une action minivu de l’app Raccourcis peut convertir, redimensionner,
  renommer, noter ou étiqueter les fichiers que minivu peut modifier.
- Renommer, Déplacer, Copier, Nouveau dossier et Renommer par lot modifient
  des noms et des dossiers, et peuvent être annulés.
- **Placer dans la corbeille** place des éléments dans la corbeille. Quand une
  copie, un déplacement, un dépôt ou un collage remplace un fichier du même nom,
  l’ancien fichier va dans la corbeille. C’est aussi le cas d’un fichier que
  remplacent Convertir par lot, Extraire les pages, Planche contact ou Exporter
  la vidéo du diaporama.
- **Enregistrer**, ainsi que **Enregistrer sous**, Créer un fichier multipage,
  Bande d’images ou Enregistrer l’image vidéo sous sur un fichier existant,
  remplacent ce fichier définitivement. Il ne va pas dans la corbeille, et c’est
  irréversible.
- Les fichiers sont d’abord écrits entièrement, puis mis en place : un
  enregistrement interrompu ne laisse donc jamais un fichier à moitié écrit.

**Lieu.** Enregistrer sous, Convertir par lot, Créer une galerie web et les
actions Raccourcis excluent la position GPS et les noms de lieux, sauf si
vous désactivez **Supprimer le lieu**. Enregistrer conserve tout, lieu
compris. Le lieu d’une vidéo est affiché mais jamais supprimé.

minivu écrit aussi dans **Images/minivu Captures** (captures d’écran) et
**Images/minivu Wallpapers** (montages, et copies créées pour Définir comme
fond d’écran, dont il conserve les dix plus récentes).

## Autorisations

- **Enregistrement de l’écran**, uniquement si vous utilisez Capture >
  Écran entier ou Sélection. Vous pouvez la désactiver dans Réglages
  Système > Confidentialité et sécurité.
- **Impression**, via la zone de dialogue d’impression standard.
