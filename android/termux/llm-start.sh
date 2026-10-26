#!/usr/bin/env bash
# Démarre l'indicateur LLM en arrière-plan (raccourci Termux:Widget « llm-start »).
#
# Idempotent : si la boucle tourne déjà, ne fait rien et le dit.
# Détaché avec setsid + </dev/null : sans </dev/null le job part en « Stopped » (SIGTTIN)
# et meurt à la fermeture de Termux — piège vécu, ne pas retirer ces redirections.

set -u
STATE="$HOME/.llm-indicator"
SCRIPT="$STATE/llm-indicator.py"
[ -f "$SCRIPT" ] || SCRIPT="$HOME/termux/llm-indicator.py"

toast() { command -v termux-toast >/dev/null 2>&1 && timeout 5 termux-toast -g middle "$1" 2>/dev/null || true; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 absent : bash ~/termux/install-termux.sh"
  toast "python3 absent — lancer install-termux.sh"
  exit 1
fi
if [ ! -f "$SCRIPT" ]; then
  echo "llm-indicator.py introuvable ($SCRIPT)"
  toast "llm-indicator.py introuvable"
  exit 1
fi

# Déjà en cours ? (classe de caractères : évite de matcher sa propre ligne de commande)
if pgrep -f 'llm-indicator[.]py' >/dev/null 2>&1; then
  echo "déjà actif (pid $(pgrep -f 'llm-indicator[.]py' | tr '\n' ' '))"
  toast "Indicateur LLM déjà actif"
  exit 0
fi

mkdir -p "$STATE"
: > "$STATE/run.flag"                 # drapeau : présent = la boucle doit tourner
cd "$STATE" || exit 1
setsid nohup python3 "$SCRIPT" >> "$STATE/log" 2>&1 < /dev/null &
sleep 2

if pgrep -f 'llm-indicator[.]py' >/dev/null 2>&1; then
  echo "indicateur démarré (pid $(cat "$STATE/pid" 2>/dev/null))"
  toast "Indicateur LLM démarré"
else
  echo "ÉCHEC du démarrage — dernières lignes de $STATE/log :"
  tail -20 "$STATE/log" 2>/dev/null
  toast "Échec du démarrage — voir ~/.llm-indicator/log"
  exit 1
fi
