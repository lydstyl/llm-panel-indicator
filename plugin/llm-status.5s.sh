#!/usr/bin/env python3
"""cbar plugin — occupation temps réel des LLM locaux du LAN (dashboard + /slots).

Affiche dans le panneau COSMIC :  🟢 🤖 <tâches actives>/<slots totaux en ligne>
Popup (clic gauche) : détail par nœud, file de prompts, liens.

Source de vérité des slots : l'API HTTP de chaque llama-server (/slots) — jamais une valeur
écrite en dur. Un serveur relancé avec -np 2 au lieu de 1 fait donc passer le compteur de
« 2/4 » à « 2/5 » au cycle suivant, sans rien reconfigurer.
Le port et le nom du modèle sont détectés dynamiquement (dashboard, llm_cmd, /props).

Résilience réseau : les noms `.lan` dépendent du DNS de la box, que systemd-resolved peut
ignorer en basculant sur 1.1.1.1. Chaque appel au dashboard réessaie donc sur l'IP avec un
en-tête Host explicite, et les nœuds sont interrogés directement en IP : le plugin
fonctionne même sans résolution de noms.

Sortie (format cbar) : 1re ligne = texte du panneau, puis « --- », puis entrées du popup.
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

# Nœuds surveillés : id, libellé, IP, carte dashboard (None = nœud Windows/Strata).
DEFAULT_NODES = [
    {"id": "224", "label": ".224", "ip": "192.168.3.224", "card": None},
    {"id": "louis", "label": "Louis .206", "ip": "192.168.3.206", "card": "louis"},
    {"id": "marie", "label": "Marie .57", "ip": "192.168.3.57", "card": "marie"},
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
    """Liste des nœuds : surchargée par LLM_NODES_JSON (~/.config/cbar/env)."""
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
    """Un nœud : carte dashboard (modèle/port, enrichissement) + /slots (source de vérité)."""
    res = {
        "id": node["id"],
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

    # /slots décide de l'état : le serveur répond = le nœud est en ligne.
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

    # --- première ligne = panneau ---
    dot = "🟢" if active else ("⚪" if online else "⚫")
    head = ("%s 🤖 %d/%d" % (dot, active, capacity)) if online else (dot + " 🤖 —")
    if q_run or q_wait:
        head += " · ⏳%d" % (q_run + q_wait)
    print(head)

    # --- popup ---
    print("---")
    for n in probed:
        if n["state"] == "online":
            icon = "🟢" if n["active"] else "⚪"
            line = "%s %s — %d/%d · %s" % (icon, n["label"], n["active"], n["slots"], short_model(n["model"]))
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

    print("🖥️ Dashboard complet | href=%s/" % DASH_TARGETS[0][0])
    print("🔄 Rafraîchir | refresh=true")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # jamais d'exit non nul : cbar afficherait « llm-status ! »
        print("🤖 —")
        print("---")
        print("⚠️ Erreur du plugin : %s: %s | disabled=true" % (type(err).__name__, err))
        print("🔄 Rafraîchir | refresh=true")
