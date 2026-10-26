#!/usr/bin/env bash
# Ouvre le dashboard dans le navigateur — c'est ce script que le TAP sur la notification exécute.
#
# Pourquoi un script : `termux-notification --action` n'est PAS un intent. Termux:API exécute
# `$PREFIX/bin/sh -c <action>` ; une action du genre « view:http://… » ne fait donc RIEN, sans
# aucune erreur. Il faut appeler termux-open-url depuis un script.
#
# Note : le nom `dashboard.lan` (et non l'IP) est nécessaire — nginx sert un vhost par nom,
# et un navigateur ne peut pas forcer l'en-tête Host.

if command -v termux-open-url >/dev/null 2>&1; then
  termux-open-url 'http://dashboard.lan/' >/dev/null 2>&1
else
  am start -a android.intent.action.VIEW -d 'http://dashboard.lan/' >/dev/null 2>&1
fi

command -v termux-toast >/dev/null 2>&1 && timeout 5 termux-toast -g middle "Ouverture du dashboard…" 2>/dev/null
exit 0
