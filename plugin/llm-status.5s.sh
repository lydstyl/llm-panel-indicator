#!/usr/bin/env python3
"""cbar plugin — occupation temps réel des LLM locaux du LAN (dashboard.lan).

Affiche dans le panneau COSMIC :  🟢 🤖 <tâches actives>/<slots totaux en ligne>
Popup : détail par nœud + file de prompts (Prompt Queue).

Source de vérité des slots : l'API HTTP de chaque llama-server (/slots), donc si un
serveur est relancé avec -np 2 au lieu de 1, le compteur suit tout seul (aucune config).
Le nom du modèle et le port sont lus dynamiquement (dashboard.lan + /props).

Sortie (format cbar) : 1re ligne = texte du panneau, puis « --- », puis entrées du popup.
Toujours exit 0 (un code de sortie non nul afficherait « <plugin> ! » dans le panneau).
"""

from __future__ import annotations

import base64
import json
import os
import re
import urllib.request
from concurrent.futures import ThreadPoolExecutor

DASH = os.environ.get("LLM_DASH_URL", "http://dashboard.lan")
PQ = os.environ.get("LLM_QUEUE_URL", "http://prompts.gab.lan")
TIMEOUT = float(os.environ.get("LLM_HTTP_TIMEOUT", "2.5"))
DEFAULT_PORT = 8080

# Nœuds surveillés : id, libellé, IP. Le port est détecté (llm_cmd puis /props puis 8080).
DEFAULT_NODES = [
    {"id": "224", "label": ".224", "ip": "192.168.3.224", "card": None},
    {"id": "louis", "label": "Louis .206", "ip": "192.168.3.206", "card": "louis"},
    {"id": "marie", "label": "Marie .57", "ip": "192.168.3.57", "card": "marie"},
]


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


def get_json(url, timeout=TIMEOUT):
    """GET JSON → dict/list, ou None si injoignable / invalide. Jamais d'exception."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cbar-llm-status"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except Exception:
        return None


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
    """Interroge un nœud : carte dashboard (modèle/port/état) + /slots (occupation réelle)."""
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

    card = None
    if node.get("card"):
        card = get_json(f"{DASH}/api/pc-{node['card']}")

    if node["id"] == "224":
        # .224 = dual-boot : soit Strata (Windows), soit llama.cpp (Pop OS).
        info = get_json(f"{DASH}/api/llm-224")
        if info and info.get("state") == "running":
            res["state"] = "online"
            res["model"] = info.get("model") or ""
            res["port"] = info.get("port") or DEFAULT_PORT
        elif card and not card.get("error") and card.get("llm_status") == "active":
            res["state"] = "online"
            res["model"] = card.get("llm_model") or ""
            res["port"] = port_from_cmd(decode_cmd(card))
        elif card and not card.get("error"):
            res["state"] = "stopped"
            return res
    else:
        if not card or card.get("error"):
            return res
        if card.get("llm_status") != "active":
            res["state"] = "stopped"
            return res
        res["state"] = "online"
        res["model"] = card.get("llm_model") or ""
        res["port"] = port_from_cmd(decode_cmd(card))
        total = card.get("llm_slots_total")
        if str(total).isdigit():
            res["slots"] = int(total)  # repli si /slots est injoignable

    # /slots = source de vérité (nb de slots et occupation réelle)
    if res["state"] == "online":
        for port in (res["port"], DEFAULT_PORT):
            if not port:
                continue
            slots = get_json(f"http://{res['ip']}:{port}/slots")
            if isinstance(slots, list):
                res["port"] = port
                res["slots"] = len(slots) or 1
                res["active"] = sum(1 for s in slots if s.get("is_processing"))
                break
        # /props : nom de modèle à jour si la carte ne le donne pas
        if not res["model"] and res["port"]:
            props = get_json(f"http://{res['ip']}:{res['port']}/props")
            if props:
                res["model"] = (props.get("model_path") or "").split("/")[-1]
        if not res["slots"]:
            res["slots"] = 1

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

    queue = get_json(f"{PQ}/api/stats") or {}
    counts = queue.get("counts", {}) if isinstance(queue, dict) else {}
    q_run = counts.get("in_progress", 0) or 0
    q_wait = counts.get("pending", 0) or 0

    # --- première ligne = panneau ---
    dot = "🟢" if active else ("⚪" if online else "⚫")
    head = f"{dot} 🤖 {active}/{capacity}" if online else f"{dot} 🤖 —"
    if q_run or q_wait:
        head += f" · ⏳{q_run + q_wait}"
    print(head)

    # --- popup ---
    print("---")
    for n in probed:
        if n["state"] == "online":
            icon = "🟢" if n["active"] else "⚪"
            line = f"{icon} {n['label']} — {n['active']}/{n['slots']} · {short_model(n['model'])}"
        elif n["state"] == "stopped":
            line = f"⚫ {n['label']} — serveur arrêté"
        else:
            line = f"⚫ {n['label']} — hors ligne"
        print(f"{line} | disabled=true")

    if online:
        print(f"🖥️ {active} tâche(s) en cours · {capacity} slot(s) sur {len(online)} serveur(s) | disabled=true")
    else:
        print("🖥️ Aucun LLM local en ligne | disabled=true")

    if q_run or q_wait:
        print(f"⏳ File de prompts : {q_run} en cours, {q_wait} en attente | href={PQ}/")
    else:
        print(f"⏳ File de prompts : vide | href={PQ}/")

    print(f"🖥️ Dashboard complet | href={DASH}/")
    print("🔄 Rafraîchir | refresh=true")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:  # jamais d'exit non nul : cbar afficherait « <plugin> ! »
        print("🤖 —")
        print("---")
        print(f"⚠️ Erreur du plugin : {type(err).__name__}: {err} | disabled=true")
        print("🔄 Rafraîchir | refresh=true")
