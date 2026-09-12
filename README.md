<p align="center">
  <img src="Resources/icon.png" width="120" alt="">
</p>

<h1 align="center">Micara</h1>

Les téléphones de la salle deviennent les micros de votre réunion Teams, Zoom
ou Meet. Micara vit dans la barre de menus du Mac ; en réunion, un liseré bleu
entoure l'écran et une petite barre en bas montre le son qui passe.

## Installer

```sh
git clone https://github.com/GNRNicolas/micara-mac.git && cd micara-mac && ./build.sh --install
```

Le script compile l'app, la pose dans `/Applications` et la lance. Il faut
macOS 13 ou plus et les outils en ligne de commande Xcode
(`xcode-select --install`). Une seule fois, il demande votre mot de passe :
c'est pour installer **BlackHole**, le micro virtuel dans lequel Micara écrit.
Un micro virtuel est un pilote système, aucune app ne peut le poser sans ça.

Micara s'ouvre ensuite au démarrage du Mac, sans fenêtre ni icône dans le Dock.
Cherchez le micro dans la barre de menus, près de l'horloge.

## Utiliser

1. Dans Teams, Zoom ou Meet, choisissez le micro **Micara**. Micara le règle
   aussi comme micro par défaut du Mac pendant la réunion, et remet l'ancien à
   la fin.
2. Menu Micara → **Créer une réunion**. Le liseré bleu apparaît, la barre monte.
3. Survolez la barre : un QR code se déploie. Chaque participant le scanne
   avec son téléphone, autorise le micro, et c'est tout. Un point vert par
   téléphone connecté ; orange s'il décroche, il disparaît s'il ne revient pas.
4. **Couper** coupe tous les téléphones d'un coup, le micro du Mac continue.
   **Terminer** ferme la réunion.

Le code de l'espace est attribué à l'installation et ne change jamais : le QR
est le même à chaque réunion. Pas de compte, pas de mot de passe.

## Mixage

Menu → **Mixage** :

| Mode | Comportement |
|---|---|
| Dominance + gate (défaut) | Le téléphone le plus fort parle, les autres sont atténués de 18 dB. Un noise gate coupe les micros posés qui n'entendent que la salle. |
| Somme | Tous les flux additionnés, un limiteur évite la saturation. |

Le micro du Mac est toujours dans le mix, avec l'annulation d'écho de macOS.

## Permissions

**Micro**, demandée à la première réunion : Micara capte le micro du Mac pour
le mélanger aux téléphones. Rien d'autre. L'app est signée localement à
chaque installation, macOS redemande donc cette autorisation après une mise à
jour.

## Mise à jour

Une requête anonyme par jour vers GitHub. Quand une version sort, Micara le
dit ; **Mettre à jour** relance `git pull && ./build.sh --install` et
redémarre l'app.

## Dépannage

- Journal : `~/Library/Logs/micara.log`.
- Le micro « Micara » a disparu des réglages audio : menu → **Réinstaller le
  micro Micara**.
- `kill -USR1 $(pgrep -x Micara)` démarre ou termine une réunion sans passer
  par le menu.

[SPECS.md](SPECS.md) décrit l'architecture et les décisions.

## Licences

Micara : MIT. BlackHole (Existential Audio) : GPL-3.0, installeur embarqué tel
quel, texte de la licence dans l'app. LiveKit WebRTC : BSD.
