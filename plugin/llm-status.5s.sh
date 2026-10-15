#!/usr/bin/env python3
"""cbar plugin — état temps réel des LLM locaux du LAN, une pastille par PC.

Panneau COSMIC : une pastille par machine, toujours visible, avec la couleur de son état :
    🟢 vert    aucune tâche en cours (tout est disponible)
    🟠 orange  une partie des slots tourne, au moins un slot encore libre (ex. Marie 1/2)
    🔴 rouge   tous les slots tournent (machine saturée)
    ⚫ gris    serveur arrêté ou PC hors ligne
Le rendu est un SVG unique (cbar n'accepte qu'une image par ligne) : lettres G / M / L en
blanc sur pastille colorée — la couleur ne dépend donc pas du thème clair/sombre.

Source de vérité des slots : l'API HTTP de chaque llama-server (/slots) — jamais une valeur
écrite en dur. Un serveur relancé avec -np 2 au lieu de 1 change donc la pastille tout seul
(orange possible sur une machine à 2 slots, sans rien reconfigurer).
Le port et le nom du modèle sont détectés dynamiquement (dashboard, llm_cmd, /props).

Résilience réseau : les noms `.lan` dépendent du DNS de la box, que systemd-resolved peut
ignorer en basculant sur 1.1.1.1. Chaque appel au dashboard réessaie donc sur l'IP avec un
en-tête Host explicite, et les nœuds sont interrogés directement en IP.

Sortie (format cbar) : 1re ligne = panneau (image SVG), puis « --- », puis entrées du popup.
Toujours exit 0 : un code de sortie non nul afficherait « llm-status ! » dans le panneau.
"""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = float(os.environ.get("LLM_HTTP_TIMEOUT", "2.5"))
DEFAULT_PORT = 8080

# Étiquettes de couleur (même vocabulaire que le dashboard)
COLOR_FREE = "#22c55e"     # disponible
COLOR_PARTIAL = "#f59e0b"  # partiellement occupé (au moins un slot libre)
COLOR_BUSY = "#ef4444"     # tous les slots occupés
COLOR_OFF = "#6b7280"      # arrêté / hors ligne

# Cibles du dashboard : (base, en-tête Host à forcer ou None). 2e = repli sans DNS.
DASH_TARGETS = [
    (os.environ.get("LLM_DASH_URL", "http://dashboard.lan"), None),
    (
        os.environ.get("LLM_DASH_FALLBACK", "http://192.168.3.102"),
        os.environ.get("LLM_DASH_HOST_HEADER", "dashboard.lan"),
    ),
]
# Cibles de la file de prompts (port direct en repli).
QUEUE_TARGETS = [
    (os.environ.get("LLM_QUEUE_URL", "http://prompts.gab.lan"), None),
    (os.environ.get("LLM_QUEUE_FALLBACK", "http://192.168.3.102:8108"), None),
]

# Machines surveillées : id, lettre de la pastille, libellé, IP, carte dashboard
# (card=None → nœud Windows/Strata, interrogé via /api/llm-224).
DEFAULT_NODES = [
    {"id": "224", "letter": "G", "label": "Gabriel .224", "ip": "192.168.3.224", "card": None},
    {"id": "marie", "letter": "M", "label": "Marie .57", "ip": "192.168.3.57", "card": "marie"},
    {"id": "louis", "letter": "L", "label": "Louis .206", "ip": "192.168.3.206", "card": "louis"},
]

_working = {}  # mémorise la cible qui répond (évite les timeouts à répétition)


def _fetch(url, host=None, timeout=TIMEOUT):
    """GET JSON ; None si injoignable ou réponse invalide. Jamais d'exception."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cbar-llm-status"})
        if host:
            req.add_header("Host", host)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except Exception:
        return None


def get_json(path, kind="dash", timeout=TIMEOUT):
    """GET JSON sur les cibles de `kind`, dans l'ordre (celle qui marche passe en premier)."""
    targets = DASH_TARGETS if kind == "dash" else QUEUE_TARGETS
    order = list(range(len(targets)))
    if kind in _working and _working[kind] in order:
        order.remove(_working[kind])
        order.insert(0, _working[kind])

    for idx in order:
        base, host = targets[idx]
        data = _fetch(base + path, host=host, timeout=timeout)
        if data is not None:
            _working[kind] = idx
            return data
    return None


def nodes_config():
    """Liste des machines : surchargée par LLM_NODES_JSON (~/.config/cbar/env)."""
    raw = os.environ.get("LLM_NODES_JSON", "").strip()
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list) and data:
                return data
        except json.JSONDecodeError:
            pass
    return DEFAULT_NODES


def port_from_cmd(cmd):
    """Extrait --port / --listen-port d'une ligne de commande llama-server."""
    if not cmd:
        return None
    m = re.search(r"(?:^|\s)--(?:listen-)?port\s+(\d+)", cmd)
    return int(m.group(1)) if m else None


def decode_cmd(card):
    """llm_cmd est exposé en clair, parfois en base64 selon le backend."""
    for key in ("llm_cmd", "llm_cmd_b64"):
        raw = card.get(key)
        if not raw or raw == "—":
            continue
        if key.endswith("_b64"):
            try:
                return base64.b64decode(raw).decode("utf-8", "ignore")
            except Exception:
                continue
        return raw
    return ""


def probe_node(node):
    """Une machine : carte dashboard (modèle/port, enrichissement) + /slots (source de vérité)."""
    res = {
        "id": node["id"],
        "letter": (node.get("letter") or (node.get("label") or "?")[:1]).upper(),
        "label": node["label"],
        "ip": node["ip"],
        "state": "offline",  # online | stopped | offline
        "model": "",
        "port": None,
        "active": 0,
        "slots": 0,
    }

    card = get_json("/api/pc-" + str(node["card"])) if node.get("card") else None
    card_ok = bool(card) and not card.get("error")

    if node["id"] == "224":
        # .224 = dual-boot : Strata sous Windows, llama.cpp sous Pop OS (jamais les deux).
        info = get_json("/api/llm-224")
        if info and info.get("state") == "running":
            res["model"] = info.get("model") or ""
            res["port"] = info.get("port") or DEFAULT_PORT
        elif card_ok and card.get("llm_status") == "active":
            res["model"] = card.get("llm_model") or ""
            res["port"] = port_from_cmd(decode_cmd(card))
        elif card_ok:
            res["state"] = "stopped"
            return res
    elif card_ok:
        if card.get("llm_status") != "active":
            res["state"] = "stopped"
            return res
        res["model"] = card.get("llm_model") or ""
        res["port"] = port_from_cmd(decode_cmd(card))
        total = card.get("llm_slots_total")
        if str(total).isdigit():
            res["slots"] = int(total)  # repli si /slots est injoignable

    # /slots décide de l'état : le serveur répond = la machine est en ligne.
    for port in (res["port"], DEFAULT_PORT):
        if not port:
            continue
        slots = _fetch("http://%s:%s/slots" % (res["ip"], port))
        if isinstance(slots, list):
            res["state"] = "online"
            res["port"] = port
            res["slots"] = len(slots) or 1
            res["active"] = sum(1 for s in slots if s.get("is_processing"))
            break

    if res["state"] == "online":
        if not res["model"] and res["port"]:
            props = _fetch("http://%s:%s/props" % (res["ip"], res["port"]))
            if props:
                res["model"] = (props.get("model_path") or "").split("/")[-1]
        if not res["slots"]:
            res["slots"] = 1
    elif res["slots"]:
        res["state"] = "online"  # /slots muet mais le collecteur annonce le serveur actif

    return res


def node_level(node):
    """Niveau d'occupation : free | partial | busy | off."""
    if node["state"] != "online" or not node["slots"]:
        return "off"
    if node["active"] <= 0:
        return "free"
    if node["active"] >= node["slots"]:
        return "busy"
    return "partial"


def level_color(level):
    return {
        "free": COLOR_FREE,
        "partial": COLOR_PARTIAL,
        "busy": COLOR_BUSY,
        "off": COLOR_OFF,
    }[level]


LEVEL_DOT = {"free": "🟢", "partial": "🟠", "busy": "🔴", "off": "⚫"}


def panel_svg(nodes):
    """Un seul SVG (cbar n'accepte qu'une image par ligne) : les pastilles G / M / L."""
    radius, gap, pad, height = 10.5, 6.0, 0.5, 22.0
    diameter = 2 * radius + 2 * pad
    step = diameter + gap
    width = len(nodes) * step - gap

    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="%.0f" height="%.0f" '
        'viewBox="0 0 %.0f %.0f">' % (width, height, width, height)
    ]
    for index, node in enumerate(nodes):
        cx = pad + radius + index * step
        color = level_color(node_level(node))
        parts.append('<circle cx="%.2f" cy="11" r="%.2f" fill="%s"/>' % (cx, radius, color))
        parts.append(
            '<text x="%.2f" y="15.4" text-anchor="middle" font-family="sans-serif" '
            'font-size="13" font-weight="700" fill="#ffffff">%s</text>'
            % (cx, node["letter"])
        )
    parts.append("</svg>")
    return "".join(parts)


def short_model(name):
    """Qwen3.8-…-00001-of-00004.gguf → nom court lisible."""
    if not name:
        return "?"
    base = name.split("/")[-1]
    base = re.sub(r"\.gguf$", "", base, flags=re.I)
    base = re.sub(r"-\d{5}-of-\d{5}$", "", base)
    return base if len(base) <= 34 else base[:31] + "…"


def main():
    nodes = [n for n in nodes_config() if n.get("ip")]
    with ThreadPoolExecutor(max_workers=max(len(nodes), 1)) as pool:
        probed = list(pool.map(probe_node, nodes))

    online = [n for n in probed if n["state"] == "online"]
    active = sum(n["active"] for n in online)
    capacity = sum(n["slots"] for n in online)

    stats = get_json("/api/stats", kind="queue")
    counts = stats.get("counts", {}) if isinstance(stats, dict) else {}
    q_run = counts.get("in_progress", 0) or 0
    q_wait = counts.get("pending", 0) or 0

    # --- 1re ligne = panneau : pastilles colorées (titre vide, image seule) ---
    print("| image=" + base64.b64encode(panel_svg(probed).encode()).decode())

    # --- popup ---
    print("---")
    for n in probed:
        level = node_level(n)
        if n["state"] == "online":
            line = "%s %s — %d/%d · %s" % (
                LEVEL_DOT[level], n["label"], n["active"], n["slots"], short_model(n["model"])
            )
        elif n["state"] == "stopped":
            line = "⚫ %s — serveur arrêté" % n["label"]
        else:
            line = "⚫ %s — hors ligne" % n["label"]
        print(line + " | disabled=true")

    if online:
        print(
            "🖥️ %d tâche(s) en cours · %d slot(s) sur %d serveur(s) en ligne | disabled=true"
            % (active, capacity, len(online))
        )
    else:
        print("🖥️ Aucun LLM local en ligne | disabled=true")

    queue_url = QUEUE_TARGETS[0][0] + "/"
    if stats is None:
        print("⏳ File de prompts : injoignable | disabled=true")
    elif q_run or q_wait:
        print("⏳ File de prompts : %d en cours, %d en attente | href=%s" % (q_run, q_wait, queue_url))
    else:
        print("⏳ File de prompts : vide | href=%s" % queue_url)

    print("Légende : 🟢 libre · 🟠 partiel · 🔴 saturé · ⚫ arrêté | disabled=true")
    print("🖥️ Dashboard complet | href=%s/" % DASH_TARGETS[0][0])
    print("🔄 Rafraîchir | refresh=true")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # jamais d'exit non nul : cbar afficherait « llm-status ! »
        fallback = (
            '<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">'
            '<circle cx="11" cy="11" r="10.5" fill="#6b7280"/>'
            '<text x="11" y="15.4" text-anchor="middle" font-family="sans-serif" '
            'font-size="13" font-weight="700" fill="#ffffff">?</text></svg>'
        )
        print("| image=" + base64.b64encode(fallback.encode()).decode())
        print("---")
        print("⚠️ Erreur du plugin : %s: %s | disabled=true" % (type(err).__name__, err))
        print("🔄 Rafraîchir | refresh=true")
