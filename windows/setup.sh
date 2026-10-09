#!/bin/bash
# Installe le banc : SDK NVIDIA RTXGI 2.0 a un commit fige, patch du banc, scene de test, compilation.
# Installs the bench: NVIDIA RTXGI 2.0 SDK at a pinned commit, bench patch, test scene, build.
#
# Usage (Git Bash) : ./windows/setup.sh [dossier SDK, sans espaces / SDK folder, no spaces]   (defaut / default : C:/bench/RTXGI)
set -e
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-/c/bench/RTXGI}"
COMMIT=10b5770   # "Update assets" ; sous-modules : Donut fc690f9, NRD 33e10fa, NRC 266125d (v0.14.1), SHaRC 0b9f58b (v1.6.5), Assets 6c3caa6

say () { echo; echo "=== $*"; }
case "$DEST" in *" "*) echo "ERREUR : le dossier du SDK ne doit pas contenir d'espace (ShaderMake echoue). / ERROR: no spaces in the SDK path."; exit 1;; esac
for c in git cmake python; do command -v $c >/dev/null || { echo "ERREUR : '$c' introuvable / not found"; exit 1; }; done
python -c "import numpy" 2>/dev/null || { echo "ERREUR : module Python numpy manquant -> pip install numpy / missing numpy"; exit 1; }

say "1/5 Clone du SDK RTXGI (~10 Go avec les sous-modules) / cloning"
if [ ! -d "$DEST/.git" ]; then
  git clone https://github.com/NVIDIAGameWorks/RTXGI.git "$DEST"
fi
cd "$DEST"
git checkout -q $COMMIT
git submodule update --init --recursive

say "2/5 Patch du banc / bench patch"
if git apply --check -R --whitespace=nowarn "$HERE/windows/patch/rtxgi_bench.patch" 2>/dev/null; then
  echo "deja applique / already applied"
else
  git apply --whitespace=nowarn "$HERE/windows/patch/rtxgi_bench.patch"
fi

say "3/5 Scene de test (Bistro + panneau mobile) / test scene"
cp "$HERE/windows/assets/BistroBench2.scene.json" Assets/Media/
mkdir -p Assets/Media/BenchBox
cp "$HERE/windows/assets/BenchBox/"* Assets/Media/BenchBox/

say "4/5 Configuration CMake / configure"
KIT=$(ls -d "/c/Program Files (x86)/Windows Kits/10/bin/10."* 2>/dev/null | sort -V | tail -1)
[ -f "$KIT/x64/fxc.exe" ] || { echo "ERREUR : Windows SDK (fxc.exe) introuvable -> installer le Windows 10/11 SDK via Visual Studio Installer"; exit 1; }
KITW=$(cygpath -m "$KIT")
GEN="${CMAKE_GENERATOR:-Visual Studio 17 2022}"
cmake -S . -B build -G "$GEN" -A x64 -DSHADERMAKE_FXC_PATH="$KITW/x64/fxc.exe" -DSHADERMAKE_DXC_PATH="$KITW/x64/dxc.exe"

say "5/5 Compilation (Release, cible Pathtracer, 10-30 min) / build"
cmake --build build --config Release --target Pathtracer --parallel

[ -f Bin/Pathtracer.exe ] || { echo "ERREUR : Bin/Pathtracer.exe absent apres compilation / missing after build"; exit 1; }
echo "$(cygpath -m "$DEST")" > "$HERE/windows/.sdk_path"
say "OK : banc installe dans $DEST. Etape suivante / next : ./windows/run.sh"
