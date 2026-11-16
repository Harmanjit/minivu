# Édition d’images

L’édition se fait dans la visionneuse. Vos modifications sont conservées
sous forme de liste d’étapes et s’affichent au fur et à mesure, mais rien
ne change sur le disque tant que vous n’enregistrez pas.

## Ouvrir un outil

Choisissez un outil dans le menu **Image**, ou placez le pointeur sur le
bord gauche de la visionneuse et choisissez-en un dans le panneau. Les
commandes de l’outil prennent la place du panneau, et l’outil reste ouvert
pendant que vous travaillez.

- **Appliquer** ajoute la modification à l’image, **Annuler** l’écarte et
  **Réinitialiser** remet les commandes dans leur état initial.
- Dans le panneau, **Rotation et symétrie** et **Effets de couleur**
  appliquent chaque bouton immédiatement ; **Terminé** les ferme.
- Dans les outils avec lesquels vous dessinez ou peignez, choisir une autre
  commande applique ce que vous avez fait jusque-là au lieu de l’abandonner.

## Les outils

- **Faire pivoter vers la gauche**, **Faire pivoter vers la droite**,
  **Symétrie horizontale**, **Symétrie verticale**.
- **Redimensionner/rééchantillonner…** définit une nouvelle taille en
  pixels ou en pourcentage, avec ou sans conservation des proportions, à
  l’aide de l’un des 11 filtres de rééchantillonnage, de Boîte et Bilinéaire
  à Lanczos 8.
- **Taille de la zone de travail…** agrandit ou réduit la zone de travail
  autour de l’image, en pixels ou en pourcentage. Choisissez la position de
  l’image avec l’ancrage 3 × 3, et remplissez le nouvel espace avec une
  couleur ou laissez-le transparent. Une zone de travail plus petite recadre
  l’image.
- **Recadrer…** : faites glisser le rectangle ou ses poignées. Choisissez
  Libre, la forme d’origine de l’image, ou 1:1, 4:3, 3:2, 16:9 ou 5:4, en
  portrait ou en paysage.
- **Redresser…** fait pivoter l’image jusqu’à 45° dans un sens ou dans
  l’autre et recadre les coins vides.
- **Perspective…** redresse un sujet photographié en biais, comme un
  document ou un bâtiment. Faites glisser les quatre poignées d’angle sur
  les coins d’un objet qui devrait être rectangulaire, ou cliquez sur
  **Auto** pour en trouver un. **Afficher le résultat** donne un aperçu de
  la correction.
- **Ajuster > Réglages RAW…**, pour les fichiers RAW d’appareil photo
  uniquement : exposition, renforcement (contraste), récupération des hautes
  lumières, balance des blancs et réduction du bruit, à partir des réglages
  de l’appareil photo. minivu ne peut pas enregistrer sur un fichier RAW :
  enregistrez donc le résultat avec **Enregistrer sous…**.
- **Ajuster > Éclairage…** : luminosité, contraste, gamma, ombres et hautes
  lumières.
- **Ajuster > Couleurs…** : teinte, saturation, clarté, température et
  nuance, ainsi que le rouge, le vert et le bleu séparément.
- **Ajuster > Courbes…** et **Niveaux…** pour un contrôle précis des tons.
- **Ajuster > Amélioration automatique** améliore les tons et les couleurs
  en un clic. Si la photo n’a besoin de rien, minivu émet un bip.
- **Ajuster > Netteté…**, **Flou…** et **Réduction du bruit…**. La
  réduction du bruit lisse le grain et préserve les contours ; son curseur
  Netteté fait revenir les détails.
- **Modifier le commentaire…** définit le commentaire stocké dans un
  fichier JPEG. Il est écrit dans le fichier lorsque vous cliquez sur
  Enregistrer dans l’éditeur de commentaire.
- **Modifier les métadonnées…** (**⌘I**) modifie les informations du
  fichier. Consultez Métadonnées ci-dessous.

Pour les effets, le dessin et la retouche, consultez
[Effets et retouches](help:Effects).

## Métadonnées

Les métadonnées sont les informations stockées avec une photo : qui l’a
prise, quand, où, ainsi qu’un titre ou des mots-clés. **Image > Modifier
les métadonnées…** (**⌘I**) les modifie pour l’image affichée, ou pour
chaque image sélectionnée dans le navigateur.

- **Description :** titre, légende, créateur et copyright.
- **Mots-clés :** ajoutez des mots-clés, séparés par des virgules, ou
  supprimez-en un de chaque image.
- **Date de prise de vue :** décalez la date de quelques jours, heures,
  minutes et secondes, ou définissez une nouvelle date et heure.
- **Lieu :** **Supprimer le lieu** retire la position GPS et les noms de
  lieux.

Avec plusieurs images, un champ dont la valeur diffère affiche « Mixte ».
Laissez-le vide pour conserver la valeur propre à chaque fichier. Seuls les
champs que vous modifiez sont écrits.

Les métadonnées sont écrites dans le fichier sans réencoder l’image. Les
fichiers RAW d’appareil photo, et les formats que minivu ne peut pas
réécrire, reçoivent plutôt un fichier annexe XMP : un petit fichier du même
nom placé à côté de la photo, que les autres apps savent lire aussi.

## Annuler

**Édition > Annuler** et **Rétablir** permettent de reculer et d’avancer
dans vos modifications, jusqu’à 50 étapes. L’annulation ne consomme pas de
mémoire supplémentaire : revenez en arrière aussi souvent que vous le
souhaitez. Après l’enregistrement, l’historique d’annulation repart de zéro.

## Enregistrer

- **Fichier > Enregistrer** écrit l’image modifiée sur l’original, dans le
  même format, le même espace colorimétrique et la même profondeur de bits,
  avec ses métadonnées. minivu demande confirmation avant de remplacer
  l’original ; si vous lui avez indiqué de ne plus le demander, réactivez
  **Demander avant d’enregistrer sur l’original** dans **Réglages >
  Général**.
- minivu ne peut pas réécrire certains formats, comme RAW, WebP, PDF, ainsi
  que les fichiers animés et multipages. Pour ceux-ci, Enregistrer
  ouvre Enregistrer sous.
- **Fichier > Enregistrer sous…** enregistre un nouveau fichier. Choisissez
  le format (JPEG, PNG, HEIC, AVIF si votre Mac peut l’écrire, TIFF, BMP,
  GIF, TGA, JPEG 2000 ou ICO) et ses options : qualité, profil
  colorimétrique, métadonnées, progressif, 16 ou 10 bits par canal,
  compression TIFF et arrière-plan de la transparence.
- **Supprimer le lieu**, sous Conserver les métadonnées, exclut la position
  GPS et les noms de lieux du nouveau fichier. Cette option est activée au
  départ. Enregistrer, ainsi qu’Enregistrer sous sur le fichier original,
  conservent toujours le lieu. Le panneau indique la taille de fichier que
  donneront les options, et peut ouvrir une comparaison côte à côte de
  l’original et du résultat compressé à 100, 200 ou 400 %. Les options sont mémorisées pour chaque format.
- **Fichier > Revenir à la version enregistrée** supprime vos modifications
  non enregistrées.
- **Fichier > Enregistrer comme préréglage…** conserve les modifications
  sous forme de préréglage, afin que **Outils > Convertir par lot…** puisse
  les appliquer à de nombreuses images. La feuille répertorie les étapes
  qu’il peut utiliser et celles qu’il écarte, avec la raison. Consultez
  [Outils](help:Tools).
- Si vous passez à une autre image, revenez au navigateur ou quittez
  l’app alors que des modifications ne sont pas enregistrées, minivu vous
  demande d’abord s’il faut les enregistrer.

> Si une autre app modifie le fichier alors que vous avez des
> modifications non enregistrées, minivu vous demande s’il faut conserver
> vos modifications ou recharger le fichier. Si vous les conservez,
> Enregistrer devient Enregistrer sous : aucune des deux versions n’est
> perdue.

L’enregistrement d’une photo HDR sur l’original l’écrit sous forme d’image
à plage dynamique standard.
