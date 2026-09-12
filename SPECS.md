# Micara pour Mac — spécification (réécriture Swift du bridge Electron)

Décidé le 12/09/2026 avec Nicolas. Le bridge Electron (`../bridge/`) reste en
place jusqu'à parité ; ce dossier devient ensuite le repo public `micara-mac`.
Modèle : Eyesaver (`PROJECTS/eyesaver`) — même forme, même style, même build.

## Ce que fait l'app

1. **Installation** : `git clone … && ./build.sh --install`. Le script installe
   BlackHole 16ch s'il manque (`sudo installer -pkg`, mot de passe une fois),
   compile, copie dans `/Applications`, lance. Open at Login activé d'office.
2. **Première ouverture** : l'app appelle `POST /api/device/register` (anonyme),
   reçoit un **code d'espace permanent** + un jeton api → fichier 0600 (`TokenFile`, le trousseau redemandait le mot de passe à chaque build ad hoc). Zéro login.
3. **Menu bar** (icône, pas de Dock, pas de fenêtre) :
   `Créer une réunion` / `Terminer la réunion`, `Mixage ▸ Dominance + gate |
   Somme`, `Ouvrir au démarrage`, `Réinstaller le micro Micara`, `Vérifier les
   mises à jour`, `Partager Micara`, `Star on GitHub`, `Quitter`.
4. **Créer une réunion** :
   - `ensure` de l'agrégat CoreAudio « Micara » (UID
     `com.getmicara.bridge.aggregate`, sous-device `BlackHole16ch_UID`) ;
   - mémorise le micro par défaut courant, force « Micara » ;
   - connecte le WS `wss://app.getmicara.com/ws?token=…&role=bridge` ;
   - liseré **bleu fixe et fin** sur tous les écrans (click-through) ;
   - barre en bas, `NSPanel` non-activant, style Eyesaver.
5. **Barre** : logo · vu-mètre du mix · un point par téléphone (vert connecté,
   orange en reconnexion, disparaît après 30 s sans retour) · `Couper` /
   `Réactiver` · `Terminer`. **Hover** → le QR code se déploie au-dessus avec
   l'animation Eyesaver. QR = `https://app.getmicara.com/r/<code>`, généré par
   `CIQRCodeGenerator`, modules arrondis, sans fond blanc.
6. **Couper** : les téléphones ne partent plus dans BlackHole (gain 0 local).
   Aucun message serveur, les téléphones ne peuvent pas se réactiver. Le micro
   du Mac continue.
7. **Terminer** : ferme les pairs et le WS, restaure le micro par défaut
   d'avant, cache barre et liseré. Les téléphones voient le bridge partir et
   retentent tout seuls (comportement PWA actuel).

## Audio

```
téléphone n ─WebRTC─▶ PCM 48 kHz ─▶ gate+dominance ─┐
micro du Mac (AVAudioEngine, AEC) ────────────────┴─▶ mix ─▶ limiteur ─▶ BlackHole 16ch (ch 1-2)
                                                              └─▶ vu-mètre de la barre
```

- L'agrégat « Micara » n'existe que pour le **nom** vu dans Teams/Zoom. Il
  n'enveloppe que BlackHole : le micro du Mac est mixé **en logiciel**, comme
  aujourd'hui (`engine.js`, `LOCAL_ID`). Raison : un agrégat concatène les
  canaux, Teams ne prendrait que les deux premiers.
- Mixage « Dominance + gate » = portage 1:1 de `bridge/renderer/mixer.cjs`
  avec les constantes de `MIX` (gate −45/−50 dBFS, hold 400 ms, duck −18 dB,
  marge 3 dB, dwell 300 ms, attaque 50 ms, release 300 ms, tick 50 ms, gain
  d'entrée +10 dB). « Somme » = gains à 1, limiteur seul.
- Sortie vers BlackHole : `AVAudioEngine` dont l'`outputNode` est fixé sur le
  device BlackHole (`kAudioOutputUnitProperty_CurrentDevice`). Jamais le device
  par défaut du système.
- Réception WebRTC : `LiveKitWebRTC.xcframework` (fork LiveKit 150.7871.02,
  symboles `LKRTC…`). Retenu après spike : le build Google « stasel » n'expose
  pas le PCM des pistes distantes ; celui de LiveKit a
  `LKRTCAudioTrack.addRenderer` → `AVAudioPCMBuffer` par piste, et un ADM
  pilotable (`outputDevice`) en plan B. Téléchargé par `curl` dans `Vendor/`
  (gitignoré) et lié en `binaryTarget` local : SwiftPM échoue à télécharger
  dès que le trousseau a plusieurs identifiants github.com (cas de `gh`
  multi-comptes).
- Permission Micro (TCC) demandée à la première réunion. La signature ad hoc
  change à chaque build → redemandée après chaque réinstallation. Acceptable.

## Protocole serveur (inchangé sauf une route)

WS bridge : `welcome{space.secretCode, iceServers}`, `phone-joined{phoneId}`,
`phone-left{phoneId}`, `offer{sdp,phoneId}` → `answer`, `ice` bidirectionnel.
L'app envoie encore `stream-state{phoneId,live}` (utile aux journaux serveur) ;
`speaking` n'est plus émis (plus de dashboard participant).
Heartbeat `POST /api/bridge/heartbeat {version, state}` toutes les 30 s, comme
avant.

**Nouveau (fait, testé)** : `POST /api/device/register` → `{ token, code,
space }`. Chaque Mac est un utilisateur fantôme `device-<id>@micara.local`
(mot de passe aléatoire jamais communiqué) : zéro changement de schéma, le
dashboard super admin compte les installations. Jeton `kind='api'`.
Anti-abus : `authLimiter`. Test : `server/test-device-register.js`.

## Mise à jour

Comme Eyesaver : une requête par jour vers les releases GitHub de
`GNRNicolas/micara-mac`. Différence : `Mettre à jour` lance
`git pull && ./build.sh --install` dans le checkout d'origine, dont
`build.sh --install` a noté le chemin (`defaults write com.getmicara.mac
sourcePath`), puis l'app est relancée par le script. Sans checkout connu (app
copiée à la main), on ouvre la page de release.

## Forme du code

Paquet SwiftPM (imposé par la dépendance binaire), cible macOS 13, arm64
d'abord. Fichiers :

| Fichier | Rôle |
|---|---|
| `Sources/Micara/main.swift` | AppDelegate, menu, cycle réunion |
| `Sources/Micara/App.swift` | `Settings`, `AppLog` |
| `Sources/Micara/Account.swift` | enregistrement anonyme, code, jeton (fichier 0600), heartbeat |
| `Sources/Micara/Updater.swift` | vérification GitHub + mise à jour par le script |
| `Sources/Micara/Style.swift` | couleurs, géométrie (Eyesaver + `accent` bleu) |
| `Sources/Micara/Bar.swift` | pill, points, vu-mètre, QR au hover (repris d'Eyesaver) |
| `Sources/Micara/Borders.swift` | liseré par écran (repris d'Eyesaver, bleu, fin, sans pulse) |
| `Sources/Micara/Aggregate.swift` | portage de `micara-audio.c` : list/status/ensure/remove |
| `Sources/Micara/Audio.swift` | AVAudioEngine, micro local, sortie BlackHole, vu-mètre |
| `Sources/Micara/Signal.swift` | WebSocket + pairs WebRTC, états des points |
| `Sources/MicaraCore/Mixer.swift` | `DominanceMixer`, pur, sans AppKit |
| `Sources/MicaraCore/Protocol.swift` | messages WS, Codable |
| `Sources/MicaraCore/PhoneRoster.swift` | état des points (vert / orange / fantôme 30 s) |
| `Tests/MicaraCoreTests/` | mixage (cas de `test-mixer.mjs`), protocole |
| `build.sh` | Eyesaver + BlackHole + `swift build -c release` |
| `Resources/` | `icon.png` (1024, ex-bridge), `tray-gray*.png`, `BlackHole16ch-0.7.1.pkg`, GPL-3.0 |
| `Vendor/` | `LiveKitWebRTC.xcframework`, téléchargé par `build.sh`, gitignoré |

Couleurs : liseré et accent bleu (valeur à fixer avec le logo), ink/night
d'Eyesaver pour le reste. Tout le style hérite de `PillBackground`,
`PillButton`, `Borders` d'Eyesaver.

## Hors périmètre (pour l'instant)

Redesign de la PWA téléphone, sort du dashboard web, Intel, signature
Developer ID, mute à distance, noms d'acteurs.

## Ordre de travail

1. Spike WebRTC : recevoir une piste d'un téléphone et la sortir dans BlackHole
   via AVAudioEngine. Tranche le plan A/B ci-dessus.
2. Route `/api/device/register` + stockage du jeton.
3. Aggregate.swift + bascule du micro par défaut, avec restauration.
4. Mixer.swift + tests.
5. Barre, liseré, QR, menu.
6. build.sh, BlackHole, mise à jour, README, repo public.
