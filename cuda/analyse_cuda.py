"""Analyse du bench CUDA -> Markdown. Usage : python analyse_cuda.py <results/cuda>

Qualite : erreur moyenne sur les 30 images qui suivent le dernier evenement de chaque scenario (plus bas = mieux).
Gain G  : erreur de la meilleure baseline / erreur de la methode, moyenne geometrique sur les scenarios
          (G >= 2 : rupture ; 1,15-2 : gain net ; 0,87-1,15 : equivalent ; < 0,87 : regression).
Les baselines (SHaRC, accumulation) recoivent 1,53 a 1,57 fois plus de rayons pour couter le meme temps GPU que
la methode a dependances (calibre sur RTX 4060 ; voir timing_*.jsonl pour le rapport sur ce GPU).
"""
import json
import math
import os
import sys

D = sys.argv[1]
J = lambda f: [json.loads(l) for l in open(os.path.join(D, f)) if l.strip().startswith("{")] if os.path.exists(os.path.join(D, f)) else []
NOTRE = ["v3", "v4-A2C memoire verifiee+rampe", "v5-A instantanes", "v5-A instantanes verifies", "v5-AB instantanes+projection"]

print("# Bench CUDA : cache a dependances contre les baselines\n")
if os.path.exists(os.path.join(D, "systeme_cuda.txt")):
    print("```\n" + open(os.path.join(D, "systeme_cuda.txt"), errors="replace").read().strip() + "\n```\n")
for f, titre in (("scen_main.jsonl", "Scene principale"), ("scen_holdout.jsonl", "Scene de validation (jamais vue pendant la mise au point)"),
                 ("scen_stress.jsonl", "Scene stress (8 lampes, mur mobile, boites)")):
    rows = [r for r in J(f) if r.get("type") == "scen"]
    if not rows:
        continue
    scen = list(dict.fromkeys(r["scen"] for r in rows))
    meth = list(dict.fromkeys(r["name"] for r in rows))
    E = {(r["scen"], r["name"]): r["post"] for r in rows}
    base = [m for m in meth if m.startswith("SHaRC") or m.startswith("Accum")]
    pub = [m for m in base if "memoire" not in m and "instantanes" not in m]   # baselines telles que publiees
    print(f"\n## {titre}\n")
    print("| Scenario | " + " | ".join(m for m in meth) + " |")
    print("|---|" + "---|" * len(meth))
    for s in scen:
        print(f"| {s} | " + " | ".join(f"{E.get((s, m), float('nan')) * 100:.1f} %" for m in meth) + " |")
    print("\n| Methode | G vs baselines publiees | Verdict | G vs baselines + memoire/instantanes | Verdict |")
    print("|---|---|---|---|---|")
    for m in NOTRE + ["Oracle"]:
        if m not in meth:
            continue
        out = []
        for B in (pub, base):
            g = [min(E[(s, b)] for b in B) / max(E[(s, m)], 1e-9) for s in scen]
            G = math.exp(sum(math.log(x) for x in g) / len(g))
            out += [f"{G:.2f}", "rupture" if G >= 2 else "gain net" if G >= 1.15 else "equivalent" if G >= 0.87 else "regression"]
        print(f"| {m} | " + " | ".join(out) + " |")
for f in ("timing_43k.jsonl", "timing_170k.jsonl"):
    rows = [r for r in J(f) if r.get("type") == "timing"]
    sc = [r for r in J(f) if r.get("type") == "scene"]
    if not rows:
        continue
    print(f"\n## Temps GPU par image ({f}, {sc[0]['np'] if sc else '?'} points, {sc[0]['gpu'] if sc else ''})\n")
    print("| Methode | trace | decision | mise a jour | echange | total ms/image | evenement ms |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        tot = r["trace"] + r["decide"] + r["update"] + r["swap"]
        print(f"| {r['name']} | {r['trace']:.3f} | {r['decide']:.3f} | {r['update']:.3f} | {r['swap']:.3f} | {tot:.3f} | {r['event']:.3f} |")
rows = J("res_170k.jsonl")
if rows:
    print("\n## Ressources (scene 170 k points)\n")
    for r in rows:
        if r.get("type") == "vram":
            print(f"- VRAM : contexte {r['contexte_mb']:.0f} Mo, scene {r['scene_mb']:.0f} Mo, tous les tampons du cache {r['cache_tous_buffers_mb']:.0f} Mo ; RAM pic {r['ram_pic_mb']:.0f} Mo")
        if r.get("type") == "cpu":
            print(f"- CPU {r['name']} : {r['cpu_ms_par_frame']:.3f} ms CPU / image, {r['mur_ms_par_frame']:.3f} ms reels / image")
