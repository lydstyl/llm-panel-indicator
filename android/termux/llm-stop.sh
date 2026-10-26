#!/usr/bin/env bash
# Arrête l'indicateur LLM (raccourci Termux:Widget « llm-stop »).
#
# Arrêt propre : on retire le drapeau (la boucle sort d'elle-même), puis on tue le PID
# enregistré, puis la classe de caractères en filet de sécurité. On retire aussi la
# notification permanente — sinon elle reste affichée avec un état figé.

set -u
STATE="$HOME/.llm-indicator"

toast() { command -v termux-toast >/dev/null 2>&1 && timeout 5 termux-toast -g middle "$1" 2>/dev/null || true; }

rm -f "$STATE/run.flag"                       # 1. la boucle voit le drapeau disparu et sort
if [ -f "$STATE/pid" ]; then
  kill "$(cat "$STATE/pid" 2>/dev/null)" 2>/dev/null || true
fi
sleep 1
pkill -f 'llm-indicator[.]py' 2>/dev/null || true   # 2. filet (classe de caractères, piège pkill -f)
sleep 0.5
rm -f "$STATE/pid"

# 3. La notification permanente n'a plus de sens : on la retire (timeout : jamais d'appel qui pend).
timeout 10 termux-notification-remove llm-indicator >/dev/null 2>&1 || true

if pgrep -f 'llm-indicator[.]py' >/dev/null 2>&1; then
  echo "encore actif : $(pgrep -f 'llm-indicator[.]py' | tr '\n' ' ')"
  toast "Indicateur encore actif"
  exit 1
fi
echo "indicateur arrêté, notification retirée"
toast "Indicateur LLM arrêté"
