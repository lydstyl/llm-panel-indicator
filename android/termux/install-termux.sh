#!/usr/bin/env bash
# Installation de l'indicateur LLM locaux dans Termux (Pixel 8 Pro).
#
# À lancer DANS Termux, après avoir copié le dossier termux/ sur le téléphone :
#     bash ~/termux/install-termux.sh
#
# Idempotent : peut être relancé après une mise à jour sans rien casser.
# Ce script n'installe QUE python + imagemagick + termux-api (aucune dépendance lourde),
# copie les raccourcis dans ~/.shortcuts/ et vérifie ce qui est réellement présent.

set -u

STATE="$HOME/.llm-indicator"
SHORTCUTS="$HOME/.shortcuts"
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== Indicateur LLM locaux — installation Termux =="
echo "source : $SRC"
echo

# 0. Vérifie qu'on est bien dans Termux (et pas sur un PC par erreur).
case "${PREFIX:-}" in
  *com.termux*) ;;
  *) echo "ERREUR : ce script doit tourner DANS Termux (PREFIX=$PREFIX)."; exit 1 ;;
esac

# 1. Wake-lock le temps de l'installation (réseau souvent instable), relâché à la fin.
if command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock 2>/dev/null || true
fi
trap 'command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock 2>/dev/null || true' EXIT

# 2. Dépendances. DEBIAN_FRONTEND=noninteractive + --force-confnew : jamais de prompt dpkg
#    qui bloque (un prompt non répondu tient le verrou dpkg et fait pendre les installs suivantes).
echo "-- paquets : python, imagemagick, termux-api"
export DEBIAN_FRONTEND=noninteractive
pkg update -y >/dev/null 2>&1 || true
pkg install -y -o Dpkg::Options::="--force-confnew" python imagemagick termux-api 2>&1 | tail -5

echo
echo "-- versions installées"
python3 --version 2>&1 | sed 's/^/   /'
if command -v convert >/dev/null 2>&1; then
  echo "   convert : $(command -v convert)"
elif command -v magick >/dev/null 2>&1; then
  echo "   magick  : $(command -v magick)"
else
  echo "   ImageMagick ABSENT (l'image sera rendue par Pillow ou en Python pur : ça marche aussi)"
fi
python3 - <<'PY' 2>/dev/null || echo "   Pillow absent (repli Python pur disponible)"
try:
    import PIL
    print("   pillow : %s" % PIL.__version__)
except Exception:
    raise SystemExit(1)
PY
if command -v termux-notification >/dev/null 2>&1; then
  echo "   termux-notification : OK"
else
  echo "   termux-notification ABSENT -> pkg install termux-api + app Termux:API depuis F-Droid"
fi

# 3. Copie des fichiers d'exécution dans ~/.llm-indicator (autonome, indépendant de ~/termux).
mkdir -p "$STATE" "$SHORTCUTS"
cp -f "$SRC/llm-indicator.py" "$STATE/llm-indicator.py"
cp -f "$SRC/open-dashboard.sh" "$STATE/open-dashboard.sh"
chmod +x "$STATE/llm-indicator.py" "$STATE/open-dashboard.sh"

# 4. Raccourcis Termux:Widget (sans extension : c'est le nom affiché dans le widget).
cp -f "$SRC/llm-start.sh" "$SHORTCUTS/llm-start"
cp -f "$SRC/llm-stop.sh"  "$SHORTCUTS/llm-stop"
chmod +x "$SHORTCUTS/llm-start" "$SHORTCUTS/llm-stop"

echo
echo "-- fichiers en place"
ls -l "$STATE/llm-indicator.py" "$STATE/open-dashboard.sh" "$SHORTCUTS/llm-start" "$SHORTCUTS/llm-stop" | sed 's/^/   /'

# 5. Contrôle de sortie : un seul cycle, sans notification (preuve que le sondage marche).
echo
echo "-- test à blanc (python3 ~/.llm-indicator/llm-indicator.py --once --no-notify)"
python3 "$STATE/llm-indicator.py" --once --no-notify

cat <<'FIN'

== À FAIRE À LA MAIN (une seule fois) ==
 1. Autoriser les NOTIFICATIONS pour l'app Termux:API
    Paramètres Android → Applications → Termux:API → Autorisations → Notifications : autoriser
    (sans ça, termux-notification renvoie rc=0 et n'affiche RIEN)
 2. Installer Termux:Widget depuis F-Droid (même source que Termux, jamais le Play Store)
 3. Écran d'accueil : appui long → Widgets → Termux:Widget → ajouter llm-start et llm-stop
 4. Un tap sur llm-start = indicateur actif. Un tap sur llm-stop = arrêt + notification retirée.
FIN
