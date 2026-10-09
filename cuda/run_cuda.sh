#!/bin/bash
# Bench CUDA du cache a dependances (Linux ; marche aussi sous Windows avec Git Bash).
# CUDA bench of the dependency cache (Linux; also works on Windows with Git Bash).
#
#   ./cuda/run_cuda.sh             banc complet / full bench            (~20-40 min)
#   ./cuda/run_cuda.sh --test      verification rapide / quick check    (~1 min)
#   ./cuda/run_cuda.sh --debug     traces de debogage / debug traces    (~5 min)
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
case "$1" in --test) MODE=test;; --debug) MODE=debug;; --pack) MODE=pack;; "") ;; *) echo "argument inconnu / unknown argument: $1"; exit 1;; esac
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
if [ ! -f "poc_gpu_l3$EXT" ] || [ ! -f "poc_gpu_l8$EXT" ]; then
  step "compilation / build"
  if [ -n "$EXT" ]; then cmd //c "$(cygpath -w "$PWD/build_windows.bat")"; else ./build.sh; fi
fi

case $MODE in full) OUT="../results/cuda"; SEEDS=10;; test) OUT="../results/cuda_test"; SEEDS=1;; debug) OUT="../results/cuda_debug"; SEEDS=1;; esac
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

R res_170k.jsonl     ./poc_gpu_l3$EXT res scenes/scene_scale_170k.bin
R timing_43k.jsonl   ./poc_gpu_l3$EXT timing scenes/scene_scale_43k.bin
R timing_170k.jsonl  ./poc_gpu_l3$EXT timing scenes/scene_scale_170k.bin
R scen_main.jsonl    ./poc_gpu_l3$EXT scenf scenes/scene_main.bin $SEEDS scenes/scenarios_main.txt
R scen_holdout.jsonl ./poc_gpu_l3$EXT scenf scenes/scene_holdout.bin $SEEDS scenes/scenarios_main.txt
R scen_stress.jsonl  ./poc_gpu_l8$EXT scenf scenes/scene_stress.bin $SEEDS scenes/scenarios_stress.txt
PYTHONIOENCODING=utf-8 "$PY" analyse_cuda.py "$OUT" > "$OUT/RESULTATS_CUDA.md"
step "fini / done : $OUT/RESULTATS_CUDA.md"
[ $MODE = full ] && step "Pour renvoyer les resultats / to send results back : ./cuda/run_cuda.sh --pack"
exit 0
