#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Indicateur LLM locaux — notification permanente de la barre Android (Termux).

Android n'autorise pas de lettres colorées dans la barre d'état : l'icône y est monochrome
et imposée à ~24 dp par le système. Ce que ce script affiche, c'est donc une **notification
permanente** (rideau + écran de verrouillage) dont la **grande icône** est une image PNG de
quatre pastilles carrées portant G / M / L / S, réellement colorées, plus un titre et un
texte lisibles d'un coup d'œil.

    LLM · 1/4 actifs
    G gris · M vert 0/2 · L gris · S gris

Rafraîchissement toutes les 20 s tant que l'indicateur tourne (aucun autostart, aucun
wake-lock permanent : 0 % de batterie à l'arrêt, choix explicite de Gabriel).

Source de vérité de l'occupation : `GET http://<ip>:8080/slots` de chaque llama-server
(`len` = nombre réel de slots, `is_processing` par slot) — les cartes du dashboard ne
servent qu'à trouver le port et le nom du modèle. Jamais de dépendance au DNS `*.lan`
(le DNS de la box est intermittent) : IP en dur + en-tête `Host` pour le dashboard.

Ce script ne sort JAMAIS en code non nul : il tourne en boucle et gère ses erreurs
en interne (un code de sortie non nul ferait « planter » l'indicateur aux yeux de Gabriel).

Usage :
    python3 llm-indicator.py            # boucle (20 s), notification permanente
    python3 llm-indicator.py --once     # un seul cycle, affiche l'état, écrit le PNG, sort
    python3 llm-indicator.py --once --no-notify   # idem sans toucher aux notifications
"""

from __future__ import annotations

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor

TIMEOUT = float(os.environ.get("LLM_HTTP_TIMEOUT", "3"))
INTERVAL = float(os.environ.get("LLM_INTERVAL", "20"))
DEFAULT_PORT = 8080

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(HOME, ".llm-indicator")
FLAG = os.path.join(STATE_DIR, "run.flag")   # présent = l'indicateur doit tourner
PIDFILE = os.path.join(STATE_DIR, "pid")
PNG = os.path.join(STATE_DIR, "status.png")
LOG = os.path.join(STATE_DIR, "log")

# Couleurs d'état — identiques au desktop (plugin COSMIC + tray Windows).
COLORS = {
    "free": "#22C55E",     # vert    : aucun slot occupé
    "partial": "#F59E0B",  # orange  : au moins un slot libre
    "busy": "#EF4444",     # rouge   : tous les slots occupés
    "off": "#6B7280",      # gris    : serveur arrêté ou machine muette
}
LABELS = {"free": "vert", "partial": "orange", "busy": "rouge", "off": "gris"}

# Dashboard : toujours par IP + en-tête Host (nginx sert un vhost par nom → 404 sinon).
DASH_BASE = os.environ.get("LLM_DASH_URL", "http://192.168.3.102")
DASH_HOST = os.environ.get("LLM_DASH_HOST", "dashboard.lan")

# Ordre des pastilles = ordre d'affichage. `card` = id de carte dashboard (SkillORP = « boncoin »).
DEFAULT_NODES = [
    {"id": "224", "letter": "G", "label": "Gabriel .224", "ip": "192.168.3.224", "card": None},
    {"id": "marie", "letter": "M", "label": "Marie .57", "ip": "192.168.3.57", "card": "marie"},
    {"id": "louis", "letter": "L", "label": "Louis .206", "ip": "192.168.3.206", "card": "louis"},
    {"id": "skillorp", "letter": "S", "label": "SkillORP .249", "ip": "192.168.3.249", "card": "boncoin"},
]


# ─────────────────────────────────────────────────────────────── outils généraux

def _log(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


def fetch_json(url, host=None, timeout=TIMEOUT):
    """GET JSON ; None si injoignable ou réponse invalide. Jamais d'exception."""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "llm-indicator-android"})
        if host:
            req.add_header("Host", host)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except Exception:
        return None


def dash_get(path, timeout=TIMEOUT):
    return fetch_json(DASH_BASE + path, host=DASH_HOST, timeout=timeout)


def nodes_config():
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


def short_model(name):
    if not name:
        return "?"
    base = name.split("/")[-1]
    base = re.sub(r"\.gguf$", "", base, flags=re.I)
    base = re.sub(r"-\d{5}-of-\d{5}$", "", base)
    return base if len(base) <= 34 else base[:31] + "…"


# ─────────────────────────────────────────────────────────── sondage des nœuds

def probe_node(node):
    """Une machine : carte dashboard (port + modèle) puis /slots (source de vérité)."""
    res = {
        "id": node["id"],
        "letter": (node.get("letter") or (node.get("label") or "?")[:1]).upper(),
        "label": node.get("label") or node["ip"],
        "ip": node["ip"],
        "state": "stopped",   # online | stopped (serveur muet) | offline (carte en erreur)
        "model": "",
        "port": None,
        "active": 0,
        "slots": 0,
    }

    card = dash_get("/api/pc-" + str(node["card"])) if node.get("card") else None
    if not isinstance(card, dict):
        card = {}
    card_ok = bool(card) and not card.get("error")

    if node["id"] == "224":
        # .224 = dual-boot : un seul serveur à la fois (Strata Windows / llama.cpp Pop OS).
        info = dash_get("/api/llm-224")
        if not isinstance(info, dict):
            info = {}
        if info.get("state") == "running":
            res["model"] = info.get("model") or ""
            res["port"] = info.get("port") or DEFAULT_PORT
        elif card_ok and card.get("llm_status") == "active":
            res["model"] = card.get("llm_model") or ""
            res["port"] = port_from_cmd(card.get("llm_cmd"))
        else:
            res["state"] = "offline" if (info is None and not card_ok) else "stopped"
            return res
    elif card_ok:
        if card.get("llm_status") != "active":
            return res
        res["model"] = card.get("llm_model") or ""
        res["port"] = port_from_cmd(card.get("llm_cmd"))
        total = card.get("llm_slots_total") or ""
        if str(total).isdigit():
            res["slots"] = int(total)   # repli si /slots est injoignable

    # /slots décide de l'état : le serveur répond = la machine est en ligne.
    for port in (res["port"], DEFAULT_PORT):
        if not port:
            continue
        slots = fetch_json("http://%s:%s/slots" % (res["ip"], port))
        if isinstance(slots, list):
            res["state"] = "online"
            res["port"] = port
            res["slots"] = len(slots) or 1
            res["active"] = sum(1 for s in slots if s.get("is_processing"))
            break

    if res["state"] == "online":
        if not res["model"] and res["port"]:
            props = fetch_json("http://%s:%s/props" % (res["ip"], res["port"]))
            if props:
                res["model"] = (props.get("model_path") or "").split("/")[-1]
        if not res["slots"]:
            res["slots"] = 1
    elif res["slots"]:
        # /slots muet mais le collecteur annonce le serveur actif → repli « libre ».
        res["state"] = "online"

    return res


def node_level(node):
    """free | partial | busy | off."""
    if node["state"] != "online" or not node["slots"]:
        return "off"
    if node["active"] <= 0:
        return "free"
    if node["active"] >= node["slots"]:
        return "busy"
    return "partial"


def probe_all(nodes):
    """Sondage en PARALLÈLE : en séquentiel, un nœud éteint mange tout le budget (3 s × 4)."""
    with ThreadPoolExecutor(max_workers=max(len(nodes), 1)) as pool:
        return list(pool.map(probe_node, nodes))


# ───────────────────────────────────────────────────────────── rendu de l'image

# Géométrie : 4 pastilles carrées de 42 px, 8 px d'écart, 4 px de marge → 200 × 52.
CHIP_W, CHIP_H = 42, 42
PAD, GAP, Y0 = 4, 8, 5
IMG_W = PAD * 2 + CHIP_W * len(DEFAULT_NODES) + GAP * (len(DEFAULT_NODES) - 1)
IMG_H = CHIP_H + 2 * Y0


def chip_geometry(count):
    """[(x, y, w, h)] — même géométrie pour les trois moteurs de rendu."""
    return [(PAD + i * (CHIP_W + GAP), Y0, CHIP_W, CHIP_H) for i in range(count)]


def _imagemagick():
    for cand in ("magick", "convert"):
        path = shutil.which(cand)
        if path:
            return path
    return None


def render_imagemagick(nodes, path):
    """Rendu prioritaire : ImageMagick (`pkg install imagemagick`)."""
    exe = _imagemagick()
    if not exe:
        return False
    parts_dir = os.path.join(STATE_DIR, ".parts")
    try:
        shutil.rmtree(parts_dir, ignore_errors=True)
        os.makedirs(parts_dir, exist_ok=True)
        blocs = []
        pad_img = os.path.join(parts_dir, "pad.png")
        gap_img = os.path.join(parts_dir, "gap.png")
        subprocess.run([exe, "-size", "%dx%d" % (PAD, IMG_H), "xc:none", pad_img],
                       check=True, capture_output=True, timeout=30)
        subprocess.run([exe, "-size", "%dx%d" % (GAP, IMG_H), "xc:none", gap_img],
                       check=True, capture_output=True, timeout=30)
        blocs.append(pad_img)
        for index, node in enumerate(nodes):
            level = node_level(node)
            color = COLORS[level]
            chip = os.path.join(parts_dir, "chip%d.png" % index)
            subprocess.run(
                [exe, "-size", "%dx%d" % (CHIP_W, IMG_H), "xc:none",
                 "-fill", color, "-draw", "rectangle 0,%d %d,%d" % (Y0, CHIP_W - 1, Y0 + CHIP_H - 1),
                 "-fill", "white", "-pointsize", "30", "-gravity", "center",
                 "-annotate", "+0+0", node["letter"], chip],
                check=True, capture_output=True, timeout=30,
            )
            blocs.append(chip)
            if index < len(nodes) - 1:
                blocs.append(gap_img)
        blocs.append(pad_img)
        subprocess.run([exe] + blocs + ["+append", "-background", "none", "png32:" + path],
                       check=True, capture_output=True, timeout=30)
    except Exception as exc:      # noqa: BLE001 — jamais bloquant
        _log("rendu ImageMagick : échec (%s)" % exc)
        return False
    finally:
        shutil.rmtree(parts_dir, ignore_errors=True)
    return png_valide(path)


def _charger_police(taille):
    from PIL import ImageFont
    candidats = (
        "/system/fonts/Roboto-Regular.ttf",
        "/system/fonts/RobotoCondensed-Regular.ttf",
        "/system/fonts/DroidSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    )
    for chemin in candidats:
        if os.path.exists(chemin):
            try:
                return ImageFont.truetype(chemin, taille)
            except Exception:
                continue
    try:
        return ImageFont.load_default()
    except Exception:
        return None


def render_pillow(nodes, path):
    """Repli 1 : Pillow (`pip install pillow`)."""
    try:
        from PIL import Image, ImageDraw
    except Exception:
        return False
    try:
        img = Image.new("RGBA", (IMG_W, IMG_H), (0, 0, 0, 0))
        dessin = ImageDraw.Draw(img)
        police = _charger_police(30)
        for (x, y, w, h), node in zip(chip_geometry(len(nodes)), nodes):
            rvb = COLORS[node_level(node)].lstrip("#")
            dessin.rectangle([x, y, x + w - 1, y + h - 1],
                             fill=(int(rvb[0:2], 16), int(rvb[2:4], 16), int(rvb[4:6], 16), 255))
            if police is not None:
                try:
                    dessin.text((x + w / 2, y + h / 2), node["letter"], font=police,
                                fill=(255, 255, 255, 255), anchor="mm")
                except Exception:
                    dessin.text((x + 8, y + 6), node["letter"], font=police,
                                fill=(255, 255, 255, 255))
        img.save(path, "PNG")
    except Exception as exc:      # noqa: BLE001
        _log("rendu Pillow : échec (%s)" % exc)
        return False
    return png_valide(path)


# Police 5×7 minimale (dernier recours, aucune dépendance).
POLICE = {
    "G": ("01110", "10001", "10000", "10111", "10001", "10001", "01110"),
    "M": ("10001", "11011", "10101", "10001", "10001", "10001", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
}


def _ecrire_png(path, largeur, hauteur, rgba):
    """Encode un PNG RGBA 8 bits à la main (zlib + struct) — stdlib pure."""
    lignes = bytearray()
    for y in range(hauteur):
        lignes.append(0)                                   # filtre « None » par ligne
        lignes += rgba[y * largeur * 4:(y + 1) * largeur * 4]

    def bloc(genre, donnees):
        corps = genre + donnees
        return (struct.pack(">I", len(donnees)) + corps
                + struct.pack(">I", zlib.crc32(corps) & 0xFFFFFFFF))

    entete = struct.pack(">IIBBBBB", largeur, hauteur, 8, 6, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(bloc(b"IHDR", entete))
        fh.write(bloc(b"IDAT", zlib.compress(bytes(lignes), 9)))
        fh.write(bloc(b"IEND", b""))


def render_pure(nodes, path):
    """Repli 2 (dernier recours) : PNG écrit à la main, lettres en 5×7 agrandies."""
    try:
        rgba = bytearray(IMG_W * IMG_H * 4)
        for (x, y, w, h), node in zip(chip_geometry(len(nodes)), nodes):
            rvb = COLORS[node_level(node)].lstrip("#")
            r, v, b = int(rvb[0:2], 16), int(rvb[2:4], 16), int(rvb[4:6], 16)
            for yy in range(y, y + h):
                base = (yy * IMG_W + x) * 4
                for xx in range(w):
                    p = base + xx * 4
                    rgba[p:p + 4] = bytes((r, v, b, 255))
            glyphe = POLICE.get(node["letter"], POLICE["L"])
            echelle = 4                                  # 5×7 → 20×28 px
            tx = x + (w - 5 * echelle) // 2
            ty = y + (h - 7 * echelle) // 2
            for ligne, motif in enumerate(glyphe):
                for colonne, bit in enumerate(motif):
                    if bit != "1":
                        continue
                    for dy in range(echelle):
                        for dx in range(echelle):
                            px = tx + colonne * echelle + dx
                            py = ty + ligne * echelle + dy
                            p = (py * IMG_W + px) * 4
                            rgba[p:p + 4] = b"\xff\xff\xff\xff"
        _ecrire_png(path, IMG_W, IMG_H, rgba)
    except Exception as exc:      # noqa: BLE001
        _log("rendu pur Python : échec (%s)" % exc)
        return False
    return png_valide(path)


def png_valide(path):
    """Relit le PNG écrit : fichier non vide ET en-tête PNG — sinon on ne l'envoie pas."""
    try:
        if not os.path.isfile(path) or os.path.getsize(path) < 100:
            return False
        with open(path, "rb") as fh:
            return fh.read(8) == b"\x89PNG\r\n\x1a\n"
    except Exception:
        return False


def render(nodes):
    """Image des pastilles : ImageMagick → Pillow → PNG à la main. Ne bloque jamais."""
    os.makedirs(STATE_DIR, exist_ok=True)
    for moteur in (render_imagemagick, render_pillow, render_pure):
        if moteur(nodes, PNG):
            return True
    _log("aucun moteur de rendu n'a produit d'image valide — notification texte seule")
    return False


# ─────────────────────────────────────────────────────────────── notification

def resumer(nodes):
    """(titre, texte) — mêmes mots que le desktop : vert / orange / rouge / gris."""
    actifs = sum(1 for n in nodes if node_level(n) != "off")
    titre = "LLM · %d/%d actifs" % (actifs, len(nodes))
    morceaux = []
    for node in nodes:
        niveau = node_level(node)
        if niveau == "off":
            morceaux.append("%s gris" % node["letter"])
        else:
            morceaux.append("%s %s %d/%d"
                            % (node["letter"], LABELS[niveau], node["active"], node["slots"]))
    return titre, " · ".join(morceaux)


def notifier(titre, texte, image=None):
    """Mise à jour de la MÊME notification (--id constant). Timeout 10 s obligatoire."""
    if not shutil.which("termux-notification"):
        _log("termux-notification absent (pkg install termux-api + app Termux:API)")
        return
    cmd = ["termux-notification",
           "--id", "llm-indicator", "--ongoing", "--priority", "low", "--alert-once",
           "--title", titre, "--content", texte,
           "--action", "sh %s" % os.path.join(STATE_DIR, "open-dashboard.sh")]
    if image and png_valide(image):
        cmd += ["--image-path", image]        # chemin ABSOLU obligatoire (pas de ~)
    try:
        res = subprocess.run(["timeout", "10"] + cmd,
                             capture_output=True, text=True, timeout=15)
        detail = (res.stderr or res.stdout or "").strip()
        # rc=0 ne prouve RIEN : sans la permission « Notifications » pour Termux:API,
        # termux-notification renvoie 0 et n'affiche rien (vérification = capture d'écran).
        if res.returncode != 0:
            _log("termux-notification rc=%s %s" % (res.returncode, detail))
    except Exception as exc:      # noqa: BLE001
        _log("termux-notification : exception (%s)" % exc)


# ──────────────────────────────────────────────────────────────────── boucles

def cycle(nodes, image=True):
    """Un cycle complet : sondage, image, notification. Retourne (titre, texte, nodes)."""
    sondes = probe_all(nodes)
    if image:
        render(sondes)
    titre, texte = resumer(sondes)
    return titre, texte, sondes


def run_once():
    nodes = nodes_config()
    titre, texte, sondes = cycle(nodes)
    for node in sondes:
        niveau = node_level(node)
        if niveau == "off":
            detail = "%s gris" % node["letter"]
        else:
            detail = "%s %s %d/%d" % (node["letter"], LABELS[niveau], node["active"], node["slots"])
        print("%-28s %s" % (detail, short_model(node["model"])))
    print("titre    : %s" % titre)
    print("texte    : %s" % texte)
    if os.path.exists(PNG):
        print("image    : %s (%d octets, %dx%d)"
              % (PNG, os.path.getsize(PNG), IMG_W, IMG_H))
    else:
        print("image    : ABSENTE")
    if "--no-notify" not in sys.argv:
        notifier(titre, texte, PNG)
        print("notification : envoyée (rc de termux-notification consigné dans %s)" % LOG)
    return 0


def run_loop():
    nodes = nodes_config()
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(PIDFILE, "w", encoding="utf-8") as fh:
        fh.write(str(os.getpid()))
    _log("démarrage (pid %d, intervalle %.0f s)" % (os.getpid(), INTERVAL))

    while True:
        # Arrêt propre : drapeau retiré (llm-stop) OU fichier PID pointant ailleurs / disparu.
        if not os.path.exists(FLAG):
            _log("drapeau absent → arrêt")
            break
        try:
            pid_lu = open(PIDFILE, encoding="utf-8").read().strip()
        except Exception:
            pid_lu = ""
        if pid_lu != str(os.getpid()):
            _log("pid remplacé (%r) → arrêt" % pid_lu)
            break

        try:
            titre, texte, _ = cycle(nodes)
            _log("%s | %s" % (titre, texte))
            notifier(titre, texte, PNG)
        except Exception as exc:      # noqa: BLE001 — la boucle ne doit jamais mourir
            _log("cycle en erreur (ignorée) : %s" % exc)

        # Attente découpée : réagit vite à un arrêt pendant les 20 s.
        for _ in range(int(INTERVAL * 2)):
            if not os.path.exists(FLAG):
                break
            time.sleep(0.5)
        else:
            continue
        _log("drapeau absent → arrêt")
        break

    try:
        os.unlink(PIDFILE)
    except Exception:
        pass
    _log("arrêté")
    return 0


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    if "--once" in sys.argv:
        return run_once()
    return run_loop()


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as exc:      # noqa: BLE001 — jamais de code de sortie non nul
        _log("fatale (ignorée) : %s" % exc)
        sys.exit(0)
