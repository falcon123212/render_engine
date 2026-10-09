"""Budget de rayons des baselines a temps GPU egal, mesure sur une scene : python budget.py <timing.jsonl>

Le classique coute a + b * x ms par image pour x fois plus de rayons (droite par "Classique 1.0x" et "Classique 2.0x").
La methode (v4-A2C suivi 1/4) coute T ms par image, plus le cout de ses evenements amorti sur 50 images.
Budget = x tel que a + b * x = T. Affiche x avec 2 decimales (borne a [1 ; 4]).
"""
import json
import sys

R = {}
for line in open(sys.argv[1]):
    if line.strip().startswith("{"):
        r = json.loads(line)
        if r.get("type") == "timing":
            R[r["name"]] = r
tot = lambda r: r["trace"] + r["decide"] + r["update"] + r["swap"]
c1, c2, v4 = tot(R["Classique 1.0x"]), tot(R["Classique 2.0x"]), R["v4-A2C suivi 1/4"]
x = 1.0 + (tot(v4) + v4["event"] / 50.0 - c1) / max(c2 - c1, 1e-9)
print(f"{min(4.0, max(1.0, x)):.2f}")
