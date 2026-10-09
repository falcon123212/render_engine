#!/bin/bash
# Bench CUDA du cache a dependances (Linux, ou Windows avec Git Bash). ~20-40 min.
# CUDA bench of the dependency cache (Linux, or Windows with Git Bash).
#
# Usage : ./cuda/run_cuda.sh [--test]
set -e
cd "$(dirname "$0")"
OUT="../results/cuda"; SEEDS=10
[ "$1" = "--test" ] && { OUT="../results/cuda_test"; SEEDS=1; }
mkdir -p "$OUT"
EXT=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXT=".exe";; esac
if [ ! -f "poc_gpu_l3$EXT" ] || [ ! -f "poc_gpu_l8$EXT" ]; then
  if [ -n "$EXT" ]; then cmd //c "$(cygpath -w "$PWD/build_windows.bat")"; else ./build.sh; fi
fi
{ date '+%F %T'; nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv 2>/dev/null; nvcc --version 2>/dev/null | tail -2; uname -a; } > "$OUT/systeme_cuda.txt"
step () { echo "$(date '+%T') $*"; }
R () { local out=$1; shift; [ -s "$OUT/$out" ] && { step "deja fait : $out"; return; }; step "$out"; "$@" > "$OUT/$out.tmp" && mv "$OUT/$out.tmp" "$OUT/$out"; }
R res_170k.jsonl     ./poc_gpu_l3$EXT res scenes/scene_scale_170k.bin
R timing_43k.jsonl   ./poc_gpu_l3$EXT timing scenes/scene_scale_43k.bin
R timing_170k.jsonl  ./poc_gpu_l3$EXT timing scenes/scene_scale_170k.bin
R scen_main.jsonl    ./poc_gpu_l3$EXT scenf scenes/scene_main.bin $SEEDS scenes/scenarios_main.txt
R scen_holdout.jsonl ./poc_gpu_l3$EXT scenf scenes/scene_holdout.bin $SEEDS scenes/scenarios_main.txt
R scen_stress.jsonl  ./poc_gpu_l8$EXT scenf scenes/scene_stress.bin $SEEDS scenes/scenarios_stress.txt
PYTHONIOENCODING=utf-8 python analyse_cuda.py "$OUT" | tee "$OUT/RESULTATS_CUDA.md"
step "fini : $OUT/RESULTATS_CUDA.md"
