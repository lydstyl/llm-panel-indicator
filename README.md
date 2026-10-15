# llm-panel-indicator

Indicateur **temps réel de l'activité des LLM locaux** dans la barre système du panneau **COSMIC** (Pop!_OS 24.04).

Le panneau affiche `🤖 2/4` = **tâches en cours / slots de génération disponibles**, et le popup
(clic gauche) détaille nœud par nœud : occupation, modèle chargé, file de prompts, liens.

```
⚪ 🤖 0/4                 tout est libre
🟢 🤖 2/4                 deux générations en cours
🟢 🤖 2/4 · ⏳3           + 3 prompts en attente dans la file
⚫ 🤖 —                   aucun LLM local joignable
```

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

## Configuration

**Nœuds surveillés** — par défaut `.224` (dual-boot Windows/Pop), `Louis .206`, `Marie .57`.
Surcharge via `~/.config/cbar/env` :

```bash
# une seule ligne par variable (le JSON doit tenir sur une ligne)
LLM_NODES_JSON='[{"id":"224","label":".224","ip":"192.168.3.224","card":null},{"id":"louis","label":"Louis .206","ip":"192.168.3.206","card":"louis"},{"id":"marie","label":"Marie .57","ip":"192.168.3.57","card":"marie"}]'
LLM_DASH_URL="http://dashboard.lan"
LLM_QUEUE_URL="http://prompts.gab.lan"
LLM_HTTP_TIMEOUT="2.5"
```

`card` = nom de la carte du dashboard (`/api/pc-<card>`) ; `null` = nœud Windows/Strata
(utilise `/api/llm-224`). Le nœud `.224` est automatiquement compté **une seule fois**,
que la machine ait booté Windows (Strata) ou Pop OS (llama.cpp).

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
