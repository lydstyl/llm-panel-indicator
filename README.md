# llm-panel-indicator

Indicateur **temps réel de l'activité des LLM locaux** dans la barre système du panneau **COSMIC** (Pop!_OS 24.04)
et dans la **zone de notification Windows** (voir la section Windows plus bas).

Le panneau affiche **une pastille par machine**, toujours visible, colorée selon son état ; le popup
(clic gauche) détaille nœud par nœud : occupation, modèle chargé, file de prompts, liens.

```
  ⬤ ⬤ ⬤ ⬤      pastilles G (Gabriel .224) · M (Marie .57) · L (Louis .206) · S (SkillORP .249)

  🟢 vert    aucune tâche en cours — machine disponible
  🟠 orange  une partie des slots tourne, au moins un slot encore libre (ex. Marie 1/2)
  🔴 rouge   tous les slots tournent — machine saturée
  ⚫ gris    serveur arrêté ou PC hors ligne
```

Les pastilles sont dessinées en **SVG** (un seul par ligne — cbar n'accepte qu'une image par ligne) :
lettres blanches sur fond coloré, donc lisibles quel que soit le thème clair/sombre du panneau.

## Installation (un PC Pop!_OS / COSMIC)

```bash
curl -fsSL https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main/install.sh | bash
```

Ça n'utilise **ni sudo ni compilation** :

| Étape | Effet |
|---|---|
| 1 | installe l'applet hôte [`cbar`](https://github.com/alexandreprates/cbar) (release précompilée) dans `~/.local` |
| 2 | met de côté les plugins de démonstration de cbar (sinon ils s'affichent dans le panneau) |
| 3 | installe `plugin/llm-status.5s.sh` dans `~/.config/cbar/plugins/` |
| 4 | déclare l'applet dans l'aile droite du panneau COSMIC (sauvegarde `.bak-llm-indicator-*`) |
| 5 | exécute le plugin une fois et affiche la sortie attendue |

Le panneau recharge sa configuration **à chaud** : l'applet apparaît immédiatement (aucun logout).
Sur une machine où l'applet ne serait pas déclaré automatiquement : clic droit sur le panneau →
*Paramètres du panneau* → *Applets* → **cbar**.

Option `--no-panel` pour ne pas toucher à la configuration du panneau.

## Comment ça marche

```
llama-server /slots  ─┐
dashboard.lan /api/* ─┼─►  llm-status.5s.sh  ──►  cbar  ──►  panneau COSMIC
prompts.gab.lan/stats ┘        (python3)
```
- **Source de vérité des slots : `/slots` de chaque `llama-server`.** Le nombre de tâches simultanées
  n'est jamais écrit en dur : si un serveur est relancé avec `-np 2` au lieu de `1`, le compteur
  (`2/4` → `2/5`) suit automatiquement au cycle suivant. Idem pour le nom du modèle et le port
  (détectés via `dashboard.lan`, `llm_cmd` puis `/props`).
- **Aucune modification de l'infrastructure** : le plugin ne fait que lire des endpoints existants
  (cartes PC du dashboard, `/slots`, `/props`, statistiques de la file de prompts).
- **Résilience** : un nœud injoignable est marqué « hors ligne », un serveur arrêté « serveur arrêté »,
  et le plugin ne sort jamais en erreur (un code de sortie non nul afficherait `llm-status.5s.sh !`).
- Intervalle = nom du fichier (`.5s` = 5 s). Fréquence réglable en le renommant.
- **Indépendant du DNS** : les noms `.lan` peuvent échouer (systemd-resolved qui bascule sur
  1.1.1.1). Chaque appel au dashboard réessaie sur l'IP `192.168.3.102` avec un `Host: dashboard.lan`
  explicite, et les nœuds sont interrogés directement en IP — le plugin marche même sans résolution.

## Déployer sur plusieurs PC

```bash
curl -fsSL https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main/install.sh | bash
# ou, depuis une machine qui a les accès SSH :
LLM_INDICATOR_HOSTS="laptop gabriel-desktop-linux" ./scripts/deploy-all.sh
```

`scripts/deploy-all.sh` enchaîne l'installeur en SSH sur chaque hôte (liste via
`LLM_INDICATOR_HOSTS`), et rapporte les échecs sans s'arrêter.

L'installeur déclare l'applet dans **le ou les panneaux réellement actifs**, dont les noms sont lus
dans `~/.config/cosmic/com.system76.CosmicPanel/v1/entries` (le panneau s'appelle « Panel » sur
certaines machines, « Dock » sur d'autres — patcher le mauvais fichier ne produit *aucune* erreur et
*aucun* effet). Juste après une modification de ce repo, `raw.githubusercontent.com` peut servir
l'ancienne version pendant plusieurs minutes (CDN) : passer alors par l'API GitHub, indiquée en tête
de `install.sh`.

## Configuration

**Nœuds surveillés** — par défaut `.224` (dual-boot Windows/Pop), `Marie .57`, `Louis .206`, `SkillORP .249`
(dans cet ordre : pastilles **G, M, L, S**).
Surcharge via `~/.config/cbar/env` :

```bash
# une seule ligne par variable (le JSON doit tenir sur une ligne)
LLM_NODES_JSON='[{"id":"224","letter":"G","label":"Gabriel .224","ip":"192.168.3.224","card":null},{"id":"marie","letter":"M","label":"Marie .57","ip":"192.168.3.57","card":"marie"},{"id":"louis","letter":"L","label":"Louis .206","ip":"192.168.3.206","card":"louis"},{"id":"skillorp","letter":"S","label":"SkillORP .249","ip":"192.168.3.249","card":"boncoin"}]'
LLM_DASH_URL="http://dashboard.lan"
LLM_QUEUE_URL="http://prompts.gab.lan"
LLM_HTTP_TIMEOUT="2.5"
```

`letter` = lettre affichée dans la pastille du panneau ; `card` = nom de la carte du dashboard
(`/api/pc-<card>` — `boncoin` pour SkillORP, ancien nom de la carte), `null` pour un nœud
Windows/Strata (via `/api/llm-224`). Le nœud `.224` est
compté **une seule fois**, que la machine ait booté Windows ou Pop OS.

## Installation (Windows) — zone de notification

Windows 11 **n'autorise plus les greffons dans la barre des tâches** (l'API *DeskBands* de Windows 7
a disparu et l'Explorateur ne fournit aucune interface de ce type). L'équivalent le plus proche d'une
applet COSMIC est une **icône de zone de notification**, à épingler pour qu'elle reste visible en
permanence.

```powershell
irm https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main/windows/install-windows.ps1 | iex
```

Ou, si le dépôt vient d'être modifié (le CDN de `raw.githubusercontent` peut servir une version en
cache pendant plusieurs minutes) :

```powershell
irm "https://api.github.com/repos/lydstyl/llm-panel-indicator/contents/windows/install-windows.ps1?ref=main" | iex
```

L'installeur dépose deux fichiers dans `%USERPROFILE%\llm-tray\`, place un lanceur dans le dossier
**Démarrage** (démarrage automatique au logon, **sans droits administrateur ni tâche planifiée**),
démarre l'indicateur et rappelle comment épingler l'icône.

- **Icône** : une pastille par machine en ligne (**G / M / L / S**), même sémantique et mêmes couleurs que le panneau COSMIC
  (vert libre · orange partiel · rouge saturé · gris arrêté/hors ligne).
- **Survol** : état compact par machine (`G 0/1 · M 1/2 · L off · S 1/1`) — limité à 63 caractères par Windows.
- **Clic gauche** : ouvre `dashboard.lan`. **Clic droit** : état détaillé par nœud (occupation, modèle,
  file de prompts), liens, rafraîchir, quitter.
- **Zéro dépendance** : Windows PowerShell 5.1 + .NET Framework (`System.Windows.Forms` / `System.Drawing`).

Fichiers concernés : `windows/llm-tray.ps1` (l'indicateur), `windows/llm-tray.vbs` (lancement sans
console), `windows/install-windows.ps1` (installation).

**Tests sans Windows** — le cœur du script (sondage HTTP + calcul d'état) est exécutable depuis
Linux, coupé à la section interface, contre les vraies APIs du LAN :

```bash
windows/tests/run-core-tests.sh   # syntaxe + 7 contrôles d'intégrité (niveaux, cohérence, repli IP)
```

Notes techniques :

- ⚠️ **ENCODAGE — la panne n° 1, invisible :** PowerShell **5.1 lit un `.ps1` sans BOM comme de l'ANSI
  (CP1252)**, pas comme de l'UTF-8 → `·` s'affiche `Â·` et tous les accents cassent (constaté sur le
  laptop Windows 11). Les `.ps1` de ce dépôt sont donc **UTF-8 AVEC BOM**, `install-windows.ps1`
  réapplique le BOM après téléchargement, et `run-core-tests.sh` **échoue** si un `.ps1` perd son BOM.
  Le `.vbs` est maintenu en ASCII pur pour la même raison.
- ⚠️ Les **emoji dans les menus WinForms** (Segoe UI, sans fallback emoji fiable) sortent en carrés :
  les libellés du menu sont en texte simple.
- ⚠️ L'en-tête `Host` ne peut pas être passé par `-Headers` en PowerShell (interdit par .NET :
  *« The 'Host' header must be modified using the appropriate property or method »*) → le script
  utilise `HttpWebRequest.Host` pour joindre `dashboard.lan` par IP. Sans lui, nginx renvoie 404.
- ⚠️ Syntaxe **Windows PowerShell 5.1** : `$x = if (...) {...} else {...}` est du PowerShell 7 et
  provoque une erreur de syntaxe en 5.1 → `if/else` explicites.
- ⚠️ `NotifyIcon.Text` est limité à **63 caractères** (au-delà : exception) → troncature systématique.
- `GetHicon()` doit être suivi de `DestroyIcon` (P/Invoke) sinon **fuite de handles GDI** à chaque
  rafraîchissement (toutes les 5 s).
- Pour un affichage **dans** la barre des tâches Windows, il faudrait passer par TrafficMonitor
  (plugin DLL en C++ compilé contre son API) ou Rainmeter (skin en surimpression) : nettement plus
  lourd, non retenu ici.

## Vérification / dépannage

```bash
~/.config/cbar/plugins/llm-status.5s.sh        # doit afficher « 🟢 🤖 2/4 » puis le détail
pgrep -af cbar                                 # l'applet tourne (1 process par barre)
cat ~/.config/cosmic/com.system76.CosmicPanel.Panel/v1/plugins_wings   # applet déclaré ?
journalctl --user -b | grep -i cbar            # erreurs côté panneau
```

Si le plugin sort `🤖 —` : `dashboard.lan` est injoignable (DNS/box) ou aucun `llama-server` ne répond.

## Dépendances

- Pop!_OS 24.04+ / COSMIC (l'applet hôte est un applet COSMIC — ça ne marche **pas** sous GNOME)
- `python3` (stdlib uniquement), `curl`
- Accès LAN à `dashboard.lan` et aux `llama-server`

## Licence

MIT (le plugin et l'installeur). `cbar` est un projet tiers sous GPL-3.0, installé séparément
depuis ses propres releases.
