# Mixtape

Lecteur de musique privé : un serveur sur le PC de la maison + une app iPhone façon Apple Music installée avec SideStore.

## Serveur (PC Windows)
1. Télécharge le dossier `server` (ou le zip « Mixtape-Serveur »).
2. Double-clique sur `Installer.bat`.
3. Dépose tes sons dans `Musique\Mixtape`. La page « Mixtape - Gérer ma musique » (raccourci sur le Bureau) affiche l'adresse et le mot de passe pour l'iPhone.

Astuces : nomme les fichiers `Artiste - Titre.mp3`, range un album dans un sous-dossier, et pose une image dedans pour la pochette.

## App iPhone
Chaque modification du dossier `ios` déclenche une compilation sur GitHub (onglet Actions). Le fichier `Mixtape.ipa` est publié dans les Releases :
`https://github.com/kermiche78/mixtape/releases/latest/download/Mixtape.ipa`

Ouvre ce lien sur l'iPhone, puis installe le fichier avec SideStore.

### Mises à jour directement dans SideStore (sans Safari)
Ajoute une seule fois cette source dans SideStore (onglet Sources → +) :
`https://github.com/kermiche78/mixtape/releases/latest/download/source.json`
Ensuite, chaque nouvelle version apparaît dans l'onglet « Mes apps » → Mettre à jour.
