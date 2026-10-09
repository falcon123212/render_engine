"""Analyse du banc SHaRC / NRC / DLSS -> tableaux Markdown (stdout) + resultats.json.
Bench analysis -> Markdown tables (stdout) + resultats.json.

Usage : python analyse.py <results/sdk>
Qualite : ecart de luminosite moyen |%| dans la zone touchee, apres l'evenement (10 / 30 / 90 images), pic,
          et 30 images apres le retour a l'etat initial. Plus bas = mieux ; "sanscache" = niveau du bruit seul.
Cout    : temps GPU par image (minuteurs GPU) compare a la methode de base (SHaRC ou NRC d'origine), image par image.
"""
import csv
import glob
import json
import os
import re
import sys

import numpy as np

OUT = sys.argv[1]
# scenario -> (image de l'evenement, image du retour, sondes)
SC = {
    "nuit": (150, 450, [(1, "zones au soleil / sunlit"), (0, "image entiere / whole")]),
    "lampe0": (60, 210, [(2, "zone du lampadaire 0 / lamp 0 area"), (0, "image entiere / whole")]),
    "lampe1": (60, 210, [(5, "zone du lampadaire 1 / lamp 1 area"), (6, "reste / rest")]),
    "auvent": (100, 250, [(7, "zone de l'auvent / canopy area"), (0, "image entiere / whole")]),
    "panneau": (100, 250, [(3, "zone du panneau / panel area"), (4, "reste / rest")]),
}
TITRE = {"nuit": "Tombee de la nuit / nightfall", "lampe0": "Lampadaire 0 eteint / lamp 0 off", "lampe1": "Lampadaire 1 eteint / lamp 1 off",
         "auvent": "Auvent de 12 x 10 m pose / large canopy appears", "panneau": "Panneau deplace / small panel moved"}
ORDRE = ["sanscache", "sharc", "sharc_vidage", "sharc_briques", "sharc_briques_dlssreset", "sharc_cible",
         "nrc", "nrc_intensifie", "nrc_contournement90", "nrc_p3_rebond3", "nrc_p2_c40"]
NOM = {"sanscache": "Sans cache (bruit seul) / no cache", "sharc": "SHaRC d'origine / original", "sharc_vidage": "SHaRC + vidage + instantanes complets",
       "sharc_briques": "SHaRC + vidage + instantanes compacts (methode retenue)", "sharc_briques_dlssreset": "  idem + historique DLSS efface",
       "sharc_cible": "SHaRC + invalidation ciblee", "nrc": "NRC d'origine / original", "nrc_intensifie": "NRC + apprentissage accelere",
       "nrc_contournement90": "NRC + contournement 90 img", "nrc_p3_rebond3": "NRC + contournement partiel (rebond 3)", "nrc_p2_c40": "NRC + contournement 40 img"}


def rows(p):
    try:
        r = list(csv.DictReader(l for l in open(p) if not l.startswith("#")))
    except OSError:
        return None
    return r


def runs(suite, res, sc, cfg):
    out = []
    for d in sorted(glob.glob(os.path.join(OUT, suite, res, sc, cfg, "r*"))):
        r = rows(os.path.join(d, "errors.csv"))
        if r and len(r) > 300:
            snap = open(os.path.join(d, "snapshots.txt")).read() if os.path.exists(os.path.join(d, "snapshots.txt")) else ""
            out.append((r, snap))
    return out


def cfgs(path):
    c = [os.path.basename(p) for p in glob.glob(os.path.join(path, "*")) if os.path.isdir(p)]
    return sorted(c, key=lambda x: ORDRE.index(x) if x in ORDRE else 99)


res_json = {}
print("# Resultats du banc SHaRC / NRC / DLSS\n")
if os.path.exists(os.path.join(OUT, "..", "systeme.txt")):
    print("```\n" + open(os.path.join(OUT, "..", "systeme.txt"), encoding="utf-8", errors="replace").read().strip() + "\n```\n")

# ---------------------------------------------------------------- qualite
for suite, titre in (("sharc", "SHaRC, cache seul (960x540, 4 ech./pixel)"), ("nrc", "NRC, cache seul (960x540, 4 ech./pixel)"),
                     ("dlss", "Image finale DLSS Ray Reconstruction (Performance, 1 ech./pixel)")):
    for res in sorted(os.listdir(os.path.join(OUT, suite))) if os.path.isdir(os.path.join(OUT, suite)) else []:
        print(f"\n## Qualite : {titre} - sortie {res}\n")
        for sc in SC:
            base = os.path.join(OUT, suite, res, sc)
            if not os.path.isdir(base):
                continue
            ev, back, probes = SC[sc]
            print(f"\n### {TITRE[sc]}\n")
            print("| Methode | Sonde | 10 img | 30 img | 90 img | Pic | Retour 30 img | Rep. | Cache garde | Instantane |")
            print("|---|---|---|---|---|---|---|---|---|---|")
            for cfg in cfgs(base):
                R = runs(suite, res, sc, cfg)
                if not R:
                    continue
                kept = [float(x) for _, s in R for x in re.findall(r"kept=([\d.]+)%", s)]
                snapb = [int(x) for _, s in R for x in re.findall(r"save .*?bytes=(\d+)", s)]
                for bit, pn in probes:
                    try:
                        b = np.array([[float(x[f"p{bit}_bias"]) for x in r] for r, _ in R])
                    except KeyError:
                        continue
                    q = dict(abs10=float(np.abs(b[:, ev:ev + 10]).mean()), abs30=float(np.abs(b[:, ev:ev + 30]).mean()),
                             abs90=float(np.abs(b[:, ev:ev + 90]).mean()), pic=float(np.abs(b[:, ev:ev + 30].mean(0)).max()),
                             retour30=float(np.abs(b[:, back:back + 30]).mean()), reps=len(R),
                             kept=float(np.mean(kept)) if kept else None, snap_mo=float(np.mean(snapb)) / 1e6 if snapb else None,
                             serie=[float(x) for x in b[:, ev - 10:ev + 90].mean(0)])
                    res_json.setdefault(suite, {}).setdefault(res, {}).setdefault(sc, {}).setdefault(cfg, {})[f"p{bit}"] = q
                    k = f"{q['kept']:.0f} %" if q["kept"] is not None else ""
                    s = f"{q['snap_mo']:.1f} Mo" if q["snap_mo"] is not None else ""
                    print(f"| {NOM.get(cfg, cfg)} | {pn} | {q['abs10']:.1f} % | {q['abs30']:.1f} % | {q['abs90']:.1f} % | {q['pic']:.1f} % | {q['retour30']:.1f} % | {q['reps']} | {k} | {s} |")

# ---------------------------------------------------------------- cout
CB = os.path.join(OUT, "cout")
if os.path.isdir(CB):
    for res in sorted(os.listdir(CB)):
        print(f"\n## Cout GPU - {res} (minuteurs GPU, 4 ech./pixel, 8 rebonds max)\n")
        for sc in ("nuit", "lampe0"):
            base = os.path.join(CB, res, sc)
            if not os.path.isdir(base):
                continue
            ev = SC[sc][0]
            ms = {}
            for cfg in cfgs(base):
                R = runs("cout", res, sc, cfg)
                if R:
                    ms[cfg] = np.mean([[float(x["gpu_ms"]) for x in r] for r, _ in R], 0)
            print(f"\n### {TITRE[sc]}\n")
            print("| Methode | ms/image avant | ms/image apres (90 img) | vs base : 3 img | 10 img | 90 img | total par evenement | hors evenement |")
            print("|---|---|---|---|---|---|---|---|")
            for cfg, m in ms.items():
                basecfg = "nrc" if cfg.startswith("nrc") else ("sharc" if cfg.startswith("sharc") else None)
                line = f"| {NOM.get(cfg, cfg)} | {m[ev - 60:ev].mean():.2f} | {m[ev:ev + 90].mean():.2f} |"
                if basecfg and basecfg in ms and cfg != basecfg:
                    b = ms[basecfg]
                    off = float(np.median(m[20:ev - 10] - b[20:ev - 10]))   # derive d'horloge / cout permanent
                    d = m - b - off
                    pc = lambda x: x / b[ev:ev + 90].mean() * 100
                    r = dict(e3=float(d[ev:ev + 3].mean()), e10=float(d[ev:ev + 10].mean()), e90=float(d[ev:ev + 90].mean()), total=float(d[ev:ev + 90].sum()), off=off)
                    res_json.setdefault("cout", {}).setdefault(res, {}).setdefault(sc, {})[cfg] = r
                    line += f" {r['e3']:+.1f} ms ({pc(r['e3']):+.0f} %) | {r['e10']:+.1f} ({pc(r['e10']):+.0f} %) | {r['e90']:+.1f} ({pc(r['e90']):+.0f} %) | {r['total']:+.0f} ms | {off:+.2f} ms |"
                else:
                    line += " (base) | | | | |"
                print(line)
json.dump(res_json, open(os.path.join(OUT, "..", "resultats.json"), "w"), indent=1)
print("\n_Ecart de luminosite = |moyenne de la zone / verite - 1| ; verite = path tracing 8 ech. x 256 (ou 192) images. "
      "Hors evenement = ecart median avant l'evenement (retire du surcout)._")
