#!/usr/bin/env bash
# Déploie / met à jour l'indicateur sur plusieurs PC Pop!_OS/COSMIC du LAN, en SSH.
#
#   ./deploy-all.sh                       # hôtes par défaut (aliases ~/.ssh/config)
#   LLM_INDICATOR_HOSTS="laptop gabriel-desktop-linux" ./deploy-all.sh
#
# L'installeur distant est idempotent : relancer ce script = mettre à jour le plugin
# et la déclaration du panneau sur chaque machine.
set -uo pipefail

RAW="${LLM_INDICATOR_RAW:-https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main}"
HOSTS="${LLM_INDICATOR_HOSTS:-laptop gabriel-desktop-linux}"

fail=0
for host in $HOSTS; do
    printf '\n═══ %s ═══\n' "$host"
    if ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" \
        "curl -fsSL ${RAW}/install.sh | bash" </dev/null; then
        printf '✓ %s à jour\n' "$host"
    else
        printf '✗ %s : échec (machine éteinte, SSH refusé, ou pas de COSMIC ?)\n' "$host"
        fail=$((fail + 1))
    fi
done

printf '\n%d hôte(s) traité(s), %d échec(s)\n' "$(echo "$HOSTS" | wc -w)" "$fail"
exit 0
