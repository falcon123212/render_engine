#!/bin/bash
# Bench CUDA du cache a dependances (Linux ; marche aussi sous Windows avec Git Bash).
# CUDA bench of the dependency cache (Linux; also works on Windows with Git Bash).
#
#   ./cuda/run_cuda.sh             banc complet / full bench            (~20-40 min)
#   ./cuda/run_cuda.sh --test      verification rapide / quick check    (~1 min)
#   ./cuda/run_cuda.sh --debug     traces de debogage / debug traces    (~5 min)
#   ./cuda/run_cuda.sh --echelle   seulement temps + ressources a 530 k et 1 M points / only scale runs (~5-10 min)
#   ./cuda/run_cuda.sh --publiques       scenes publiques NVIDIA (Sponza, Bistro...) / public scenes   (~30-60 min)
#   ./cuda/run_cuda.sh --publiques-test  idem, 1 graine, CornellBox + Sponza seulement / quick check   (~5 min)
#     (scenes a telecharger avant : ./scenes_publiques/telecharger.sh [--bistro] ; python3 + numpy requis)
#   ./cuda/run_cuda.sh --pack      archive des resultats a renvoyer / results archive to send back
#
# Mode --debug (voir LINUX.md) :
#   - BENCH_DEBUG=1 : chaque lancement de noyau CUDA est verifie (erreur attribuee au bon noyau), trace sur stderr ;
#   - Nsight Systems (nsys), s'il est installe : profil avec les plages NVTX (bibliotheque de traces NVIDIA) ;
#   - compute-sanitizer, s'il est installe : verification memoire des noyaux sur une petite scene.
set -e
cd "$(dirname "$0")"
PY=$(command -v python3 || command -v python || true)
[ -n "$PY" ] || { echo "ERREUR : python3 introuvable / python3 not found"; exit 1; }
MODE=full
case "$1" in --test) MODE=test;; --debug) MODE=debug;; --pack) MODE=pack;; --echelle) MODE=echelle;; --publiques) MODE=pub;; --publiques-test) MODE=pubtest;; "") ;; *) echo "argument inconnu / unknown argument: $1"; exit 1;; esac
step () { echo "$(date '+%H:%M:%S') $*"; }

if [ $MODE = pack ]; then
  cd ..
  NOM="resultats_cuda_$(hostname)_$(date +%Y%m%d_%H%M).tar.gz"
  DIRS=""; for d in results/cuda results/cuda_test results/cuda_debug; do [ -d "$d" ] && DIRS="$DIRS $d"; done
  [ -n "$DIRS" ] || { echo "ERREUR : aucun resultat dans results/ / no results found"; exit 1; }
  tar -czf "$NOM" $DIRS
  step "archive : $(pwd)/$NOM ($(du -h "$NOM" | cut -f1)). A renvoyer / send it back."
  exit 0
fi

EXT=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXT=".exe";; esac
if [ ! -f "poc_gpu_l3$EXT" ] || [ ! -f "poc_gpu_l8$EXT" ] || [ poc_gpu.cu -nt "poc_gpu_l3$EXT" ] || [ prep_mesh.cuh -nt "poc_gpu_l3$EXT" ]; then
  step "compilation / build (sources plus recentes que le binaire / sources newer than binary)"
  if [ -n "$EXT" ]; then cmd //c "$(cygpath -w "$PWD/build_windows.bat")"; else ./build.sh; fi
fi

case $MODE in full|echelle|pub) OUT="../results/cuda"; SEEDS=10;; test|pubtest) OUT="../results/cuda_test"; SEEDS=1;; debug) OUT="../results/cuda_debug"; SEEDS=1;; esac
mkdir -p "$OUT"
{ date '+%F %T'; nvidia-smi --query-gpu=name,driver_version,memory.total,compute_cap --format=csv 2>/dev/null || true
  nvcc --version 2>/dev/null | tail -2; uname -a; grep PRETTY_NAME /etc/os-release 2>/dev/null || true; } > "$OUT/systeme_cuda.txt"

R () {   # fichier_sortie commande... : saute ce qui est deja fait / skips what is already done
  local out=$1; shift
  [ -s "$OUT/$out" ] && { step "deja fait / already done : $out"; return; }
  step "$out"
  "$@" > "$OUT/$out.tmp" && mv "$OUT/$out.tmp" "$OUT/$out"
}

if [ $MODE = debug ]; then
  export BENCH_DEBUG=1
  step "1/3 traces BENCH_DEBUG (stderr -> $OUT/trace_*.log)"
  for job in "timing scene_scale_43k.bin" "scenf scene_main.bin 1 scenarios_main.txt" "scenf_l8 scene_stress.bin 1 scenarios_stress.txt"; do
    set -- $job
    exe=./poc_gpu_l3$EXT; m=$1
    [ $m = scenf_l8 ] && { exe=./poc_gpu_l8$EXT; m=scenf; }
    log="$OUT/trace_${1}_${2%.bin}.log"
    rc=0
    if [ $m = timing ]; then $exe timing "scenes/$2" > "$OUT/${1}_${2%.bin}.jsonl" 2> "$log" || rc=$?
    else $exe scenf "scenes/$2" $3 "scenes/$4" > "$OUT/${1}_${2%.bin}.jsonl" 2> "$log" || rc=$?; fi
    tail -1 "$log"
    [ $rc = 0 ] || { step "ECHEC (code $rc) : voir $log"; }
  done
  unset BENCH_DEBUG
  if command -v nsys >/dev/null; then
    step "2/3 profil Nsight Systems avec plages NVTX -> $OUT/profil.nsys-rep"
    nsys profile --trace=cuda,nvtx --force-overwrite=true -o "$OUT/profil" ./poc_gpu_l3$EXT timing scenes/scene_scale_43k.bin > /dev/null
    nsys stats --report nvtx_sum,cuda_gpu_kern_sum --format csv --output "$OUT/profil" "$OUT/profil.nsys-rep" > /dev/null 2>&1 || true
    ls "$OUT"/profil* 2>/dev/null
  else
    step "2/3 nsys absent : profil NVTX saute (installer Nsight Systems pour l'activer)"
  fi
  if command -v compute-sanitizer >/dev/null; then
    step "3/3 compute-sanitizer memcheck (petite scene, quelques minutes)"
    compute-sanitizer --tool memcheck --print-limit 20 ./poc_gpu_l3$EXT timing scenes/scene_scale_43k.bin > "$OUT/sanitizer.log" 2>&1 || true
    tail -3 "$OUT/sanitizer.log"
  else
    step "3/3 compute-sanitizer absent : verification memoire sautee"
  fi
  step "fini : traces dans $OUT/. Pour renvoyer : ./cuda/run_cuda.sh --pack"
  exit 0
fi

if [ $MODE = pub ] || [ $MODE = pubtest ]; then
  # Scenes publiques : glTF -> maillage (convertir.py) -> scene du bench (prep : BVH, points de cache, lampes, cube,
  # references ; mis en cache dans scenes_publiques/cache/) -> temps par image -> budget a temps egal -> scenarios.
  "$PY" -c "import numpy" 2>/dev/null || { echo "ERREUR : numpy manquant -> sudo apt install python3-numpy (ou pip install numpy) / numpy missing"; exit 1; }
  PUBD=../scenes_publiques; A=$PUBD/RTXGI-Assets; CACHE=$PUBD/cache; mkdir -p "$CACHE"
  export BENCH_RAYONS=8
  LISTE="cornellbox:CornellBox/cornell_box.gltf bathroom:Bathroom/LAZIENKA.gltf livingroom:LivingRoom/living_room.gltf sponza:Sponza/glTF/Sponza.gltf bistro:Bistro/bistro.gltf"
  [ $MODE = pubtest ] && LISTE="cornellbox:CornellBox/cornell_box.gltf sponza:Sponza/glTF/Sponza.gltf"
  n_ok=0
  for spec in $LISTE; do
    n=${spec%%:*}; g=$A/${spec#*:}
    if [ ! -f "$g" ]; then step "$n : scene absente, sautee (./scenes_publiques/telecharger.sh) / scene missing, skipped"; continue; fi
    if [ ! -s "$CACHE/$n.mesh" ]; then
      step "$n : conversion glTF -> maillage / converting"
      "$PY" ../scenes_publiques/convertir.py "$g" "$CACHE/$n.mesh.tmp" > "$CACHE/$n.maillage.json" && mv "$CACHE/$n.mesh.tmp" "$CACHE/$n.mesh"
    fi
    if [ ! -s "$CACHE/$n.bin" ]; then
      step "$n : preparation (BVH, points de cache, references ; 1 a 10 min) / preparing"
      ./poc_gpu_l3$EXT prep "$CACHE/$n.mesh" "$CACHE/$n.bin.tmp" > "$CACHE/$n.prep.jsonl" 2> "$CACHE/$n.prep.log" \
        || { tail -5 "$CACHE/$n.prep.log"; step "ECHEC preparation $n : voir $CACHE/$n.prep.log"; continue; }
      mv "$CACHE/$n.bin.tmp" "$CACHE/$n.bin"
    fi
    cp "$CACHE/$n.prep.jsonl" "$OUT/prep_$n.jsonl" 2>/dev/null || true; cp "$CACHE/$n.prep.log" "$OUT/prep_$n.log" 2>/dev/null || true
    cp "$CACHE/$n.maillage.json" "$OUT/maillage_$n.json" 2>/dev/null || true
    R timing_pub_$n.jsonl ./poc_gpu_l3$EXT timing "$CACHE/$n.bin"
    B=$("$PY" budget.py "$OUT/timing_pub_$n.jsonl")
    step "$n : budget des baselines a temps egal / equal-time baseline budget = ${B}x"
    R scen_pub_$n.jsonl ./poc_gpu_l3$EXT scenf "$CACHE/$n.bin" $SEEDS scenes/scenarios_publiques.txt $B
    n_ok=$((n_ok + 1))
  done
  unset BENCH_RAYONS
  [ $n_ok -gt 0 ] || { echo "ERREUR : aucune scene publique trouvee -> ./scenes_publiques/telecharger.sh / no public scene found"; exit 1; }
fi
if [ $MODE = full ] || [ $MODE = test ]; then
R res_170k.jsonl     ./poc_gpu_l3$EXT res scenes/scene_scale_170k.bin
R timing_43k.jsonl   ./poc_gpu_l3$EXT timing scenes/scene_scale_43k.bin
R timing_170k.jsonl  ./poc_gpu_l3$EXT timing scenes/scene_scale_170k.bin
R scen_main.jsonl    ./poc_gpu_l3$EXT scenf scenes/scene_main.bin $SEEDS scenes/scenarios_main.txt
R scen_holdout.jsonl ./poc_gpu_l3$EXT scenf scenes/scene_holdout.bin $SEEDS scenes/scenarios_main.txt
R scen_stress.jsonl  ./poc_gpu_l8$EXT scenf scenes/scene_stress.bin $SEEDS scenes/scenarios_stress.txt
fi
if [ $MODE = full ] || [ $MODE = echelle ]; then   # grandes scenes (taille reelle d'un cache de moteur), compressees dans le depot
  for n in 530k 1M; do
    [ -f scenes/scene_scale_$n.bin ] || { step "decompression / unpacking scene_scale_$n.bin"; gzip -dc scenes/scene_scale_$n.bin.gz > scenes/scene_scale_$n.bin; }
  done
  R timing_530k.jsonl ./poc_gpu_l3$EXT timing scenes/scene_scale_530k.bin
  R timing_1M.jsonl   ./poc_gpu_l3$EXT timing scenes/scene_scale_1M.bin
  R res_1M.jsonl      ./poc_gpu_l3$EXT res scenes/scene_scale_1M.bin
fi
PYTHONIOENCODING=utf-8 "$PY" analyse_cuda.py "$OUT" > "$OUT/RESULTATS_CUDA.md"
step "fini / done : $OUT/RESULTATS_CUDA.md"
[ $MODE != test ] && [ $MODE != pubtest ] && step "Pour renvoyer les resultats / to send results back : ./cuda/run_cuda.sh --pack"
exit 0
