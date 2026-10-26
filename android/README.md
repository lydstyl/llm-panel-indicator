# Android — indicateur LLM locaux dans la barre de notifications (Termux)

Le même indicateur que `plugin/` (Pop!_OS) et `windows/` (tray + bandeau HUD), sur le
**Pixel 8 Pro** : quatre pastilles carrées `G` `M` `L` `S` aux couleurs d'état, visibles d'un
coup d'œil dans le rideau et sur l'écran de verrouillage.

```
LLM · 1/4 actifs
G gris · M vert 0/2 · L gris · S gris
```

Aucune application à compiler, aucun root, aucune dépendance à Google Play.

## Ce qui est faisable — et ce qui ne l'est pas

| | |
|---|---|
| ❌ **Lettres colorées dans la barre d'état Android** | impossible. L'icône y est **monochrome et imposée à ~24 dp** par le système (comme le logo d'une app). Aucune app ne peut y afficher quatre lettres colorées. |
| ✅ **Notification permanente** (rideau + écran de verrouillage) | texte + **grande icône image** = un PNG de quatre pastilles-lettres réellement colorées. **C'est ce que livre ce dossier.** |
| ✅ **Widget d'écran d'accueil** 4×1 | possible, mais il faut un **APK Kotlin** : hors périmètre (voir « Phase 2 » plus bas). |

## Contrat réseau (identique au desktop)

| Lettre | Machine | IP | Carte dashboard |
|---|---|---|---|
| `G` | Gabriel .224 (dual-boot) | `192.168.3.224` | `/api/llm-224` |
| `M` | Marie .57 | `192.168.3.57` | `/api/pc-marie` |
| `L` | Louis .206 | `192.168.3.206` | `/api/pc-louis` |
| `S` | SkillORP .249 | `192.168.3.249` | `/api/pc-boncoin` (id de carte = `boncoin`) |

- Source de vérité de l'occupation : `GET http://<ip>:8080/slots` → `len` = nombre réel de slots
  (`-np 2` ⇒ 2), `is_processing` par slot. Les cartes du dashboard ne servent qu'à trouver le
  port (`llm_cmd --port`) et le nom du modèle.
- Dashboard : `http://192.168.3.102` **avec l'en-tête `Host: dashboard.lan`** (nginx sert un vhost
  par nom : sans cet en-tête, 404).
- **Jamais de DNS `*.lan` ni de mDNS pour sonder les nœuds** : toujours les IP (le DNS de la box
  est intermittent, et Android résout encore moins bien). Seul le *tap* vers le dashboard utilise
  `dashboard.lan`, parce qu'un navigateur ne peut pas forcer l'en-tête `Host`.
- Un serveur arrêté ou une machine muette = pastille **grise**, jamais une erreur visible.

### Couleurs (mêmes valeurs que le desktop)

| État | Condition | Couleur |
|---|---|---|
| libre | `busy == 0` | `#22C55E` vert |
| partiel | `0 < busy < slots` | `#F59E0B` orange |
| saturé | `busy >= slots` | `#EF4444` rouge |
| arrêté / muet | — | `#6B7280` gris |

## Installation (6 étapes)

1. **Téléphone** : ouvrir Termux (installé depuis **F-Droid**, jamais le Play Store) et lancer
   `sshd-on` (alias de `~/.bashrc`) pour permettre la copie depuis le serveur. Si tu préfères
   taper les commandes directement dans Termux, saute l'étape 2.
2. **Serveur** — copier le dossier sur le téléphone :
   ```bash
   scp -i ~/.ssh/id_ed25519_pixel -P 8022 -r android/termux u0_a365@192.168.3.56:~/
   ```
3. **Termux** — installer : `bash ~/termux/install-termux.sh`. Le script installe `python`,
   `imagemagick` et `termux-api`, copie les raccourcis dans `~/.shortcuts/`, puis exécute un
   **test à blanc** (un cycle complet, sans notification) : tu dois voir une ligne par nœud.
4. **Autorisations** (une seule fois, obligatoire) :
   *Paramètres Android → Applications → **Termux:API** → Autorisations → Notifications : autoriser.*
   Sans cette autorisation, `termux-notification` renvoie `rc=0` et n'affiche **rien**.
5. **Widget** : installer **Termux:Widget** depuis F-Droid → écran d'accueil, appui long →
   Widgets → Termux:Widget → ajouter `llm-start` et `llm-stop`.
6. **Utiliser** : un tap sur `llm-start` = l'indicateur tourne (mise à jour toutes les 20 s, tap
   sur la notification = dashboard). Un tap sur `llm-stop` = arrêt et notification retirée.

Aucun démarrage automatique au boot, aucun `termux-wake-lock` permanent : à l'arrêt, la
consommation est nulle. Écran éteint, Android peut geler la boucle : la notification reste alors
affichée avec le dernier état connu — c'est voulu.

## Fichiers

| Fichier | Rôle |
|---|---|
| `termux/llm-indicator.py` | boucle de sondage (`ThreadPoolExecutor`, timeout 3 s), rendu du PNG, notification. `--once` pour un cycle unique. |
| `termux/install-termux.sh` | paquets, copies, permissions, test à blanc. Idempotent. |
| `termux/llm-start.sh` | démarrage détaché (`setsid nohup … </dev/null`), idempotent. |
| `termux/llm-stop.sh` | arrêt propre (drapeau + PID + `pkill`), retire la notification. |
| `termux/open-dashboard.sh` | appelé par le tap sur la notification (`termux-open-url`). |

Rendu de l'image, dans l'ordre : **ImageMagick** (`convert`/`magick`) → **Pillow** →
**PNG écrit à la main** (zlib + `struct`, police 5×7). Le PNG est **relu après écriture**
(en-tête `\x89PNG`, taille > 0) avant d'être passé à `--image-path` ; sans image valide, la
notification part quand même, en texte seul.

## Dépannage

| Symptôme | Cause / solution |
|---|---|
| `llm-start` ne fait rien | lire `~/.llm-indicator/log`. Si `python3 absent`, relancer `install-termux.sh`. |
| Notification invisible mais `rc=0` | permission **Notifications** non accordée à **Termux:API** (étape 4). Ne jamais conclure au succès sur le code retour. |
| Pastilles toutes grises | normal si aucun `llama-server` ne tourne. Vérifier depuis un PC : `curl -s http://192.168.3.57:8080/slots`. |
| Image absente dans la notification | `ls -l ~/.llm-indicator/status.png` : 200×52, en-tête PNG. Sinon `python3 ~/.llm-indicator/llm-indicator.py --once` affiche l'erreur de rendu. |
| Le tap n'ouvre pas le dashboard | `--action` est une **commande shell**, pas un intent : c'est `open-dashboard.sh` qui appelle `termux-open-url`. Depuis une session SSH, `termux-open-url` renvoie `rc=0` sans rien ouvrir (restrictions Android) — seul un vrai tap utilisateur compte. |
| `dashboard.lan` introuvable sur le téléphone | le navigateur ne peut pas forcer `Host:` ; utiliser `http://192.168.3.102/` si le DNS de la box est en vrac. |
| Deux indicateurs en double | `pkill -f 'llm-indicator[.]py'` (la classe `[.]` évite de tuer sa propre session). |
| `pkg install` qui pend | un `pkg` resté `Stopped` tient le verrou dpkg : `pkill -9 -f 'install -y pyt[h]on'` puis `dpkg --configure -a`. |

**Ne jamais utiliser `termux-notification-list`** : la commande pend indéfiniment et laisse des
zombies. La preuve côté machine, c'est une **capture d'écran** (`screencap -p`) relue sur le serveur.

## Réglages

| Variable d'environnement | Défaut | Effet |
|---|---|---|
| `LLM_INTERVAL` | `20` | secondes entre deux cycles |
| `LLM_HTTP_TIMEOUT` | `3` | timeout par requête (sondage parallèle) |
| `LLM_NODES_JSON` | — | remplace la liste des nœuds (même schéma que `plugin/`) |
| `LLM_DASH_URL` / `LLM_DASH_HOST` | `http://192.168.3.102` / `dashboard.lan` | cible du collecteur |

## Ajouter une machine

Une ligne dans `DEFAULT_NODES` de `termux/llm-indicator.py` (`letter`, `ip`, `card`), puis
relancer `install-termux.sh`. La largeur de l'image et la géométrie des pastilles s'adaptent
seules au nombre de nœuds.

## Phase 2 — APK avec widget d'écran d'accueil (non livré, non commencé)

À ne commencer **que sur demande explicite**, une fois la Phase 1 validée : Kotlin, `minSdk 26`,
`targetSdk 35/36`, Gradle, sideload (`adb install -r app-debug.apk`) — pas de Play Store, pas de
compte développeur. Contraintes déjà connues :

- **HTTP en clair interdit par défaut depuis Android 9** : sans `android:usesCleartextTraffic="true"`
  (ou un `network_security_config`), les appels vers `http://192.168.3.x` échouent en silence.
- `WorkManager` impose **15 min minimum** entre deux rafraîchissements → pour du « temps réel », il
  faut un **service de premier plan** (donc une notification permanente de toute façon) ou
  `AlarmManager` exact (permission « Alarmes et rappels » à accorder par l'utilisateur).
- Widget `AppWidgetProvider` + `RemoteViews` : les pastilles se dessinent en **Bitmap** côté app,
  avec la même géométrie que le desktop (`Get-ChipGrid` / `Get-ChipRow`).

## Licence

MIT, comme le reste du dépôt.
