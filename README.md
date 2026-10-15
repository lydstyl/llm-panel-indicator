# llm-panel-indicator

Indicateur **temps réel de l'activité des LLM locaux** dans la barre système du panneau **COSMIC** (Pop!_OS 24.04).

Le panneau affiche **une pastille par machine**, toujours visible, colorée selon son état ; le popup
(clic gauche) détaille nœud par nœud : occupation, modèle chargé, file de prompts, liens.

```
  ⬤ ⬤ ⬤        pastilles G (Gabriel .224) · M (Marie .57) · L (Louis .206)

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

## Configuration

**Nœuds surveillés** — par défaut `.224` (dual-boot Windows/Pop), `Louis .206`, `Marie .57`.
Surcharge via `~/.config/cbar/env` :

```bash
# une seule ligne par variable (le JSON doit tenir sur une ligne)
LLM_NODES_JSON='[{"id":"224","letter":"G","label":"Gabriel .224","ip":"192.168.3.224","card":null},{"id":"marie","letter":"M","label":"Marie .57","ip":"192.168.3.57","card":"marie"},{"id":"louis","letter":"L","label":"Louis .206","ip":"192.168.3.206","card":"louis"}]'
LLM_DASH_URL="http://dashboard.lan"
LLM_QUEUE_URL="http://prompts.gab.lan"
LLM_HTTP_TIMEOUT="2.5"
```

`letter` = lettre affichée dans la pastille du panneau ; `card` = nom de la carte du dashboard
(`/api/pc-<card>`), `null` pour un nœud Windows/Strata (via `/api/llm-224`). Le nœud `.224` est
compté **une seule fois**, que la machine ait booté Windows ou Pop OS.

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
