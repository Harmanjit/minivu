# Confidentialité

## Aucun réseau

minivu ne se connecte jamais à Internet. Il s’exécute dans l’App Sandbox
sans l’autorisation réseau : macOS ne le laisse donc ouvrir aucune
connexion. Il n’y a ni compte, ni analyse, ni rapport de plantage, ni
recherche de mises à jour, et cette aide fait partie de l’app.

## Ce que minivu peut voir

La sandbox limite minivu à :

- votre dossier **Images** ;
- les dossiers et fichiers que vous choisissez dans une zone de dialogue
  d’ouverture ou d’enregistrement, que vous déposez sur minivu ou que vous
  ouvrez avec minivu depuis le Finder ;
- les dossiers de sa barre latérale et les dossiers récents de Copier vers
  et Déplacer vers, qu’il mémorise à l’aide de signets que seuls ce Mac et
  cette app peuvent utiliser ;
- son propre conteneur, `~/Library/Containers/com.minivu.app`.

Il ne fonctionne qu’avec le stockage interne de votre Mac, et non avec les
cartes mémoire, les disques externes ou les partages réseau.

## Ce que minivu conserve

Dans son conteneur, uniquement sur votre Mac :

- **Le catalogue** des notes par étoiles, des marques et des ordres
  personnalisés.
- **Le cache des vignettes**, que **Réglages > Vignettes > Vider le cache
  des vignettes** vide.
- **Les réglages**, y compris les dossiers de la barre latérale, les
  dossiers récents, la musique des diaporamas et les éditeurs externes.

## Ce que minivu modifie dans vos fichiers

Uniquement ce que vous demandez :

- **Enregistrer** écrit sur l’original, après confirmation. **Enregistrer
  sous**, Convertir par lot, Planche contact et Fond d’écran montage créent
  de nouveaux fichiers.
- La rotation et la symétrie dans le navigateur modifient la balise
  d’orientation d’un JPEG, et Modifier le commentaire modifie son
  commentaire.
- Renommer, Déplacer, Copier, Nouveau dossier et Renommer par lot modifient
  des noms et des dossiers, et peuvent être annulés.
- **Placer dans la corbeille**, ainsi que le remplacement d’un fichier du
  même nom, placent des éléments dans la corbeille. minivu ne supprime pas
  vos fichiers.
- Les fichiers sont d’abord écrits entièrement, puis mis en place : un
  enregistrement interrompu ne laisse donc jamais un fichier à moitié écrit.

minivu écrit aussi dans **Images/minivu Captures** (captures d’écran) et
**Images/minivu Wallpapers** (montages, et copies créées pour Définir comme
fond d’écran, dont il conserve les dix plus récentes).

## Autorisations

- **Enregistrement de l’écran**, uniquement si vous utilisez Capture >
  Écran entier ou Sélection. Vous pouvez la désactiver dans Réglages
  Système > Confidentialité et sécurité.
- **Impression**, via la zone de dialogue d’impression standard.

La détection des yeux rouges trouve les visages à l’aide du framework
Vision d’Apple, sur votre Mac.
