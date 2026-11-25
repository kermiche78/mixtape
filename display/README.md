# Écran Swag (LilyGO T-Display S3)

L'écran affiche ton texte perso, ou le son en cours : avec la pochette quand tu écoutes sur Mixtape, avec le titre et l'artiste pour les autres apps (Spotify, Apple Music…).

## Installer le programme sur l'écran (une seule fois, depuis le PC)
1. Télécharge le fichier : https://github.com/kermiche78/mixtape/releases/download/ecran/EcranSwag.bin
2. Branche l'écran au PC avec un câble USB-C.
3. Dans Chrome ou Edge, ouvre https://espressif.github.io/esptool-js/
4. Clique sur **Connect**, choisis le port (« USB JTAG/serial debug unit » ou « COMx »), puis **Connecter**.
   - Rien dans la liste ? Débranche l'écran, garde appuyé le bouton du bas (BOOT), rebranche, relâche, et recommence.
5. Dans la ligne **Flash Address**, laisse `0x0` et choisis le fichier `EcranSwag.bin`.
6. Clique sur **Program** et attends la fin (environ 30 secondes).
7. Appuie sur le petit bouton RST sur le côté de l'écran (ou débranche / rebranche) : « swag » s'affiche.

## Relier l'écran à l'iPhone
1. Mixtape → Réglages → **Écran** → **Connecter l'écran**.
2. Autorise le Bluetooth pour Mixtape, puis accepte la **demande de jumelage**.
3. C'est fini : Mixtape se reconnecte toute seule dès que l'écran est allumé près de l'iPhone.

Le jumelage permet aussi d'afficher les autres apps. Si tu l'as refusé : Réglages de l'iPhone → Bluetooth → « Ecran Swag » → Oublier, puis recommence.

## Boutons
- Bouton du haut : appui court = son suivant, appui long = changer de mode (Texte / Musique / Auto)
- Bouton du bas : appui court = lecture / pause, appui long = luminosité

## Mise à jour
Chaque modification du dossier `display` recompile le programme sur GitHub (onglet Actions) et remplace `EcranSwag.bin` dans la version « ecran ». Réinstalle-le de la même façon.
