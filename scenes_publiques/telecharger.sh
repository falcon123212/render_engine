#!/bin/bash
# Telecharge les scenes publiques de NVIDIA (depot officiel RTXGI-Assets, glTF) dans scenes_publiques/RTXGI-Assets/.
# Downloads NVIDIA's public scenes (official RTXGI-Assets repo, glTF) into scenes_publiques/RTXGI-Assets/.
#
#   ./scenes_publiques/telecharger.sh            CornellBox, Bathroom, LivingRoom, Sponza (~100 Mo, 1-2 min)
#   ./scenes_publiques/telecharger.sh --bistro   idem + Bistro (+2,3 Go)
#
# Rien n'est redistribue par ce depot : les scenes viennent directement de NVIDIA (licences dans chaque dossier ;
# Bistro : CC-BY 4.0, Amazon Lumberyard). Nothing is redistributed here: scenes come straight from NVIDIA.
# Relancer le script est sans danger (reprise / mise a jour). Safe to rerun.
set -e
cd "$(dirname "$0")"
command -v git >/dev/null || { echo "ERREUR : git introuvable / git not found"; exit 1; }
URL=https://github.com/NVIDIAGameWorks/RTXGI-Assets.git
DEST=RTXGI-Assets
SCENES="CornellBox Bathroom LivingRoom Sponza"
case "$1" in --bistro) SCENES="$SCENES Bistro";; "") ;; *) echo "argument inconnu / unknown argument: $1"; exit 1;; esac
step () { echo "$(date '+%H:%M:%S') $*"; }

if [ ! -d "$DEST/.git" ]; then
  step "clone partiel (seuls les dossiers demandes sont telecharges) / sparse clone"
  git clone --filter=blob:none --sparse "$URL" "$DEST"
fi
step "scenes : $SCENES"
git -C "$DEST" sparse-checkout set $SCENES
git -C "$DEST" pull -q --ff-only || true

echo
ok=1
for s in $SCENES; do
  g=$(find "$DEST/$s" -name '*.gltf' 2>/dev/null | head -1)
  if [ -n "$g" ]; then printf '  OK  %-11s %6s  %s\n' "$s" "$(du -sh "$DEST/$s" | cut -f1)" "$g"
  else printf '  ECHEC / FAILED  %s : aucun .gltf\n' "$s"; ok=0; fi
done
[ $ok = 1 ] && step "fini / done" || { step "ECHEC : relancer le script / rerun the script"; exit 1; }
