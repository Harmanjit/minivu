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
- **Recadrer…** : faites glisser le rectangle ou ses poignées. Choisissez
  Libre, la forme d’origine de l’image, ou 1:1, 4:3, 3:2, 16:9 ou 5:4, en
  portrait ou en paysage.
- **Redresser…** fait pivoter l’image jusqu’à 45° dans un sens ou dans
  l’autre et recadre les coins vides.
- **Ajuster > Éclairage…** : luminosité, contraste, gamma, ombres et hautes
  lumières.
- **Ajuster > Couleurs…** : teinte, saturation, clarté, température et
  nuance, ainsi que le rouge, le vert et le bleu séparément.
- **Ajuster > Courbes…** et **Niveaux…** pour un contrôle précis des tons.
- **Ajuster > Netteté…** et **Flou…**.
- **Modifier le commentaire…** définit le commentaire stocké dans un
  fichier JPEG. Il est écrit dans le fichier lorsque vous cliquez sur
  Enregistrer dans l’éditeur de commentaire.

Pour les effets, le dessin et la retouche, consultez
[Effets et retouches](help:Effects).

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
- minivu ne peut pas réécrire certains formats, comme RAW, WebP, AVIF, PDF,
  ainsi que les fichiers animés et multipages. Pour ceux-ci, Enregistrer
  ouvre Enregistrer sous.
- **Fichier > Enregistrer sous…** enregistre un nouveau fichier. Choisissez
  le format (JPEG, PNG, HEIC, TIFF, BMP, GIF, TGA, JPEG 2000 ou ICO) et ses
  options : qualité, profil colorimétrique, métadonnées, progressif,
  16 bits, compression TIFF et arrière-plan de la transparence. Le panneau
  indique la taille de fichier que donneront les options, et peut ouvrir
  une comparaison côte à côte de l’original et du résultat compressé à 100,
  200 ou 400 %. Les options sont mémorisées pour chaque format.
- **Fichier > Revenir à la version enregistrée** supprime vos modifications
  non enregistrées.
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
