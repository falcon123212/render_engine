#!/bin/bash
# Compile le bench CUDA (Linux, ou Windows depuis Git Bash avec MSVC disponible).
# Builds the CUDA bench (Linux, or Windows from Git Bash with MSVC available).
# CUDA >= 12.8 requis pour les RTX 50 (Blackwell). CUDA >= 12.8 required for RTX 50 (Blackwell).
set -e
cd "$(dirname "$0")"
command -v nvcc >/dev/null || { echo "ERREUR : nvcc introuvable (installer le CUDA Toolkit) / nvcc not found"; exit 1; }
ARCH="${CUDA_ARCH:-native}"   # ex. sm_120 (RTX 50), sm_89 (RTX 40)
EXT=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) EXT=".exe";; esac
for L in 3 8; do
  nvcc -O3 -arch=$ARCH -std=c++17 -DGX=8 -DGY=4 -DGZ=4 -DNLIGHTS=$L poc_gpu.cu -o poc_gpu_l$L$EXT
done
echo "OK : poc_gpu_l3$EXT et poc_gpu_l8$EXT"
