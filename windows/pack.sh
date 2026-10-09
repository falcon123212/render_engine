#!/bin/bash
# Regroupe les resultats dans une archive a renvoyer (sans les images de reference).
# Packs the results into an archive to send back (reference images excluded).
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | tr ' ' '_' )
NOM="resultats_${GPU:-gpu}_$(date +%Y%m%d_%H%M).zip"
python - "$NOM" <<'EOF'
import os, sys, zipfile
nom = sys.argv[1]
with zipfile.ZipFile(nom, "w", zipfile.ZIP_DEFLATED) as z:
    for racine, _, fichiers in os.walk("results"):
        for f in fichiers:
            p = os.path.join(racine, f)
            if f.endswith(".bin") and (f.startswith("ref_") or f.startswith("frame_")):
                continue   # images lourdes, recalculables / heavy images, reproducible
            z.write(p)
print("Archive :", nom, f"({os.path.getsize(nom) / 1e6:.1f} Mo)")
EOF
