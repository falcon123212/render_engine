"""Analyse du bench CUDA -> Markdown. Usage : python analyse_cuda.py <results/cuda>

Qualite : erreur moyenne sur les 30 images qui suivent le dernier evenement de chaque scenario (plus bas = mieux).
Gain G  : erreur de la baseline / erreur de la methode, moyenne geometrique sur les scenarios
          (G >= 2 : rupture ; 1,15-2 : gain net ; 0,87-1,15 : equivalent ; < 0,87 : regression).
          Deux definitions : "config fixe" = la meilleure baseline unique (un moteur choisit un reglage et le garde) ;
          "par scenario" = la meilleure baseline choisie separement pour chaque scenario (plus severe : adversaire
          qui saurait d'avance quel evenement arrive).
Scenes en boites : les baselines (SHaRC, accumulation) recoivent 1,53 a 1,57 fois plus de rayons pour couter le meme
temps GPU que la methode a dependances (calibre sur RTX 4060).
Scenes publiques (maillages) : ce budget est MESURE sur chaque scene et sur ce GPU (cuda/budget.py), 8 rayons par point.
"""
import glob
import json
import math
import os
import sys

D = sys.argv[1]
J = lambda f: [json.loads(l) for l in open(os.path.join(D, f)) if l.strip().startswith("{")] if os.path.exists(os.path.join(D, f)) else []
NOTRE = ["v3", "v4-A2C memoire verifiee+rampe", "v5-A instantanes", "v5-A instantanes verifies", "v5-AB instantanes+projection"]
gm = lambda g: math.exp(sum(math.log(max(x, 1e-9)) for x in g) / len(g))
verdict = lambda G: "rupture" if G >= 2 else "gain net" if G >= 1.15 else "equivalent" if G >= 0.87 else "regression"
tot = lambda r: r["trace"] + r["decide"] + r["update"] + r["swap"]


def gains(rows):
    """{methode: (fixe publiees, par scenario publiees, fixe toutes, par scenario toutes)}"""
    scen = list(dict.fromkeys(r["scen"] for r in rows))
    meth = list(dict.fromkeys(r["name"] for r in rows))
    E = {(r["scen"], r["name"]): r["post"] for r in rows}
    base = [m for m in meth if m.startswith("SHaRC") or m.startswith("Accum")]
    pub = [m for m in base if "memoire" not in m and "instantanes" not in m]   # baselines telles que publiees
    out = {}
    for m in NOTRE + ["Oracle"]:
        if m not in meth:
            continue
        g = []
        for B in (pub, base):
            g.append(min(gm([E[(s, b)] / max(E[(s, m)], 1e-9) for s in scen]) for b in B))
            g.append(gm([min(E[(s, b)] for b in B) / max(E[(s, m)], 1e-9) for s in scen]))
        out[m] = g
    return scen, meth, E, out


def scen_section(f, titre):
    rows = [r for r in J(f) if r.get("type") == "scen"]
    if not rows:
        return None
    scen, meth, E, G = gains(rows)
    print(f"\n## {titre}\n")
    print("| Scenario | " + " | ".join(m for m in meth) + " |")
    print("|---|" + "---|" * len(meth))
    for s in scen:
        print(f"| {s} | " + " | ".join(f"{E.get((s, m), float('nan')) * 100:.1f} %" for m in meth) + " |")
    print("\n| Methode | G vs publiees, config fixe | G vs publiees, par scenario | G vs + memoire/instantanes, config fixe | G vs + memoire/instantanes, par scenario |")
    print("|---|---|---|---|---|")
    for m, g in G.items():
        print(f"| {m} | " + " | ".join(f"{x:.2f} ({verdict(x)})" for x in g) + " |")
    return G


def timing_section(f, titre):
    rows = [r for r in J(f) if r.get("type") == "timing"]
    sc = [r for r in J(f) if r.get("type") == "scene"]
    if not rows:
        return
    print(f"\n## {titre} ({f}, {sc[0]['np'] if sc else '?'} points, {sc[0]['gpu'] if sc else ''})\n")
    print("| Methode | trace | decision | mise a jour | echange | total ms/image | evenement ms |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['name']} | {r['trace']:.3f} | {r['decide']:.3f} | {r['update']:.3f} | {r['swap']:.3f} | {tot(r):.3f} | {r['event']:.3f} |")


print("# Bench CUDA : cache a dependances contre les baselines\n")
if os.path.exists(os.path.join(D, "systeme_cuda.txt")):
    print("```\n" + open(os.path.join(D, "systeme_cuda.txt"), errors="replace").read().strip() + "\n```\n")

# ------------------------------------------------------------------ scenes publiques (maillages)
PUB = sorted(os.path.basename(p)[9:-6] for p in glob.glob(os.path.join(D, "scen_pub_*.jsonl")))
ORDRE = ["cornellbox", "bathroom", "livingroom", "sponza", "bistro"]
PUB.sort(key=lambda n: ORDRE.index(n) if n in ORDRE else 99)
if PUB:
    print("\n# Scenes publiques (NVIDIA RTXGI-Assets)\n")
    print("Scenes glTF converties (scenes_publiques/convertir.py), preparees par `poc_gpu_l3 prep` : BVH, points de cache par "
          "grille de hachage (comme SHaRC), 3 lampes et un cube mobile places automatiquement, references convergees. "
          "8 rayons par point et par image ; historiques en images. Budget des baselines mesure sur chaque scene.\n")
    resume = []
    for n in PUB:
        prep = next((r for r in J(f"prep_{n}.jsonl") if r.get("type") == "prep"), None)
        tim = {r["name"]: r for r in J(f"timing_pub_{n}.jsonl") if r.get("type") == "timing"}
        info = ""
        if prep:
            info = (f"{prep['triangles'] / 1000:.0f} k triangles, " if prep['triangles'] >= 1000 else f"{prep['triangles']} triangles, ") + (f"{prep['np'] / 1000:.0f} k points (cellule {prep['cellule_m'] * 100:.1f} cm), "
                    f"bruit propre de la reference {max(prep['bruit_ref']) * 100:.1f} % au plus")
        G = scen_section(f"scen_pub_{n}.jsonl", f"Scene publique : {n}" + (f" ({info})" if info else ""))
        timing_section(f"timing_pub_{n}.jsonl", f"Temps GPU par image, {n}")
        if G and tim.get("Classique 1.0x") and tim.get("v4-A2C suivi 1/4"):
            c1, c2, v4 = tot(tim["Classique 1.0x"]), tot(tim["Classique 2.0x"]), tim["v4-A2C suivi 1/4"]
            b = 1 + (tot(v4) + v4["event"] / 50 - c1) / max(c2 - c1, 1e-9)
            resume.append((n, c1, tot(v4), b, G))
    if resume:
        print("\n## Resume des scenes publiques\n")
        print("| Scene | Classique ms/image | v4 ms/image | Surcout v4 | Budget baselines | v4-A2C vs + mem/inst (fixe / par scen.) | v5-A vs + mem/inst (fixe / par scen.) | v5-A vs publiees (fixe) |")
        print("|---|---|---|---|---|---|---|---|")
        for n, c1, v4, b, G in resume:
            g4, g5 = G.get("v4-A2C memoire verifiee+rampe"), G.get("v5-A instantanes")
            print(f"| {n} | {c1:.3f} | {v4:.3f} | +{(v4 / c1 - 1) * 100:.0f} % | {b:.2f}x | "
                  + (f"{g4[2]:.2f} / {g4[3]:.2f}" if g4 else "-") + " | " + (f"{g5[2]:.2f} / {g5[3]:.2f}" if g5 else "-") + " | "
                  + (f"{g5[0]:.2f}" if g5 else "-") + " |")

# ------------------------------------------------------------------ scenes en boites
for f, titre in (("scen_main.jsonl", "Scene principale"), ("scen_holdout.jsonl", "Scene de validation (jamais vue pendant la mise au point)"),
                 ("scen_stress.jsonl", "Scene stress (8 lampes, mur mobile, boites)")):
    scen_section(f, titre)
for f in ("timing_43k.jsonl", "timing_170k.jsonl", "timing_530k.jsonl", "timing_1M.jsonl"):
    timing_section(f, "Temps GPU par image")
for f in ("res_170k.jsonl", "res_1M.jsonl"):
    rows = J(f)
    if not rows:
        continue
    sc = [r for r in rows if r.get("type") == "scene"]
    print(f"\n## Ressources ({f}, {sc[0]['np'] if sc else '?'} points)\n")
    for r in rows:
        if r.get("type") == "vram":
            print(f"- VRAM : contexte {r['contexte_mb']:.0f} Mo, scene {r['scene_mb']:.0f} Mo, tous les tampons du cache {r['cache_tous_buffers_mb']:.0f} Mo ; RAM pic {r['ram_pic_mb']:.0f} Mo")
        if r.get("type") == "cpu":
            print(f"- CPU {r['name']} : {r['cpu_ms_par_frame']:.3f} ms CPU / image, {r['mur_ms_par_frame']:.3f} ms reels / image")
