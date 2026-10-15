#!/usr/bin/env bash
# Indicateur LLM local dans le panneau COSMIC — installeur idempotent (Pop!_OS / COSMIC).
#
#   curl -fsSL https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --no-panel     # sans toucher à la config du panneau
#
# Ce que ça fait, dans l'ordre :
#   1. installe l'applet hôte « cbar » (release précompilée, dans ~/.local — aucun sudo) si absente ;
#   2. sort les plugins de démonstration de cbar du dossier scanné (sinon ils s'affichent dans le panneau) ;
#   3. installe le plugin llm-status.5s.sh dans ~/.config/cbar/plugins/ ;
#   4. ajoute l'applet à l'aile droite du panneau COSMIC (sauvegarde du fichier avant modif) ;
#   5. exécute le plugin une fois pour vérifier la sortie.
#
# Relançable sans risque : rien n'est dupliqué, la config du panneau n'est modifiée qu'une seule fois.
set -euo pipefail

RAW="${LLM_INDICATOR_RAW:-https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main}"
PLUGIN_NAME="llm-status.5s.sh"
APPLET_ID="io.github.alexprates.CBar"
CBAR_INSTALLER="https://raw.githubusercontent.com/alexandreprates/cbar/main/scripts/install-latest.sh"

HOME_DIR="${HOME}"
PLUGIN_DIR="${HOME_DIR}/.config/cbar/plugins"
SHOWCASE_DIR="${HOME_DIR}/.config/cbar/showcase"
CBAR_BIN="${HOME_DIR}/.local/bin/cbar"

SKIP_PANEL=0
for arg in "$@"; do
    case "$arg" in
        --no-panel) SKIP_PANEL=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    esac
done

step() { printf '\n▸ %s\n' "$*"; }
note() { printf '  · %s\n' "$*"; }

command -v curl    >/dev/null || { echo "✗ curl est requis." >&2; exit 1; }
command -v python3 >/dev/null || { echo "✗ python3 est requis." >&2; exit 1; }

step "1/5 — applet hôte cbar"
if [[ -x "$CBAR_BIN" ]]; then
    note "déjà installé : $CBAR_BIN"
else
    curl -fsSL "$CBAR_INSTALLER" | bash
    note "installé : $CBAR_BIN"
fi

step "2/5 — plugins de démonstration mis de côté"
mkdir -p "$PLUGIN_DIR" "$SHOWCASE_DIR"
shopt -s nullglob
moved=0
for f in "$PLUGIN_DIR"/showcase-*.sh; do
    mv "$f" "$SHOWCASE_DIR/"
    moved=$((moved + 1))
done
shopt -u nullglob
note "$moved plugin(s) déplacé(s) vers $SHOWCASE_DIR"

step "3/5 — plugin indicateur"
curl -fsSL "${RAW}/plugin/${PLUGIN_NAME}" -o "${PLUGIN_DIR}/${PLUGIN_NAME}.new"
chmod 0755 "${PLUGIN_DIR}/${PLUGIN_NAME}.new"
mv "${PLUGIN_DIR}/${PLUGIN_NAME}.new" "${PLUGIN_DIR}/${PLUGIN_NAME}"
note "installé : ${PLUGIN_DIR}/${PLUGIN_NAME}"

step "4/5 — panneau COSMIC"
if [[ "$SKIP_PANEL" -eq 1 ]]; then
    note "ignoré (--no-panel) — ajouter l'applet à la main : clic droit sur le panneau → Paramètres → Applets"
else
    # ⚠️ Le panneau actif ne s'appelle pas forcément « Panel » : les noms sont listés dans
    # com.system76.CosmicPanel/v1/entries (ex. « Dock » sur le desktop .224, « Panel » sur le laptop).
    # Patcher un panneau non listé ne produit AUCUN effet (vécu : applet invisible, aucun log).
    python3 - "$HOME_DIR" "$APPLET_ID" <<'PY'
import os, re, shutil, sys, time

home, applet = sys.argv[1], sys.argv[2]
cosmic = os.path.join(home, ".config", "cosmic")
entries = os.path.join(cosmic, "com.system76.CosmicPanel", "v1", "entries")

names = []
if os.path.exists(entries):
    # ⚠️ COSMIC écrit ce tableau avec une virgule finale (`["Dock",]`) : ce n'est PAS du JSON
    # valide, json.loads échoue. On extrait donc les chaînes, sans dépendre de la syntaxe.
    names = re.findall(r'"([^"]+)"', open(entries).read())
if not names:
    names = ["Panel"]  # repli : nom par défaut de COSMIC

patched = 0
for name in names:
    cfg = os.path.join(cosmic, "com.system76.CosmicPanel.%s" % name, "v1", "plugins_wings")
    if not os.path.exists(cfg):
        print("  ! panneau « %s » : %s absent — l'ajouter à la main (Paramètres → Applets)" % (name, cfg))
        continue
    src = open(cfg).read()
    if applet in src:
        print("  · panneau « %s » : applet déjà déclaré" % name)
        patched += 1
        continue
    m = re.search(r"\],\s*\[", src)
    if not m:
        print("  ! panneau « %s » : structure inattendue de plugins_wings" % name)
        continue
    shutil.copy2(cfg, "%s.bak-llm-indicator-%s" % (cfg, time.strftime("%Y%m%d-%H%M%S")))
    open(cfg, "w").write(src[: m.end()] + '\n    "%s",' % applet + src[m.end():])
    print("  · panneau « %s » : applet ajouté en tête de l'aile droite" % name)
    patched += 1

if not patched:
    print("  ! aucun panneau actif modifié — ajouter l'applet à la main (Paramètres → Applets)")
PY
fi

step "5/5 — contrôle du plugin"
echo
if out="$("${PLUGIN_DIR}/${PLUGIN_NAME}" 2>&1 | head -1)"; then
    note "panneau affichera : ${out}"
else
    note "⚠️ le plugin n'a rien renvoyé — vérifier l'accès à dashboard.lan"
fi

cat <<'EOF'

Terminé.
  · Le panneau COSMIC recharge tout seul : l'applet apparaît dans la seconde qui suit.
  · Clic gauche sur l'applet → détail par nœud, file de prompts, liens.
  · Clic droit → Paramètres cbar (plugins, dossier, catalogue).
  · Fréquence : renommer le fichier (llm-status.30s.sh, llm-status.1m.sh...).
  · Nœuds surveillés : ~/.config/cbar/env → LLM_NODES_JSON='[{"id":"...","label":"...","ip":"..."}]'
EOF
