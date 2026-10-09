#!/bin/bash
# Lance les mesures du banc SHaRC / NRC / DLSS (SDK NVIDIA RTXGI 2.0, Windows).
# Runs the SHaRC / NRC / DLSS bench (NVIDIA RTXGI 2.0 SDK, Windows).
#
# Usage (Git Bash) :
#   ./windows/run.sh                 tout / everything            (~6-8 h sur RTX 5080)
#   ./windows/run.sh --rapide        1 repetition, sans 4K / 1 repetition, no 4K   (~2 h)
#   ./windows/run.sh sharc|nrc|cout|dlss [--rapide]     une seule suite / one suite
#   ./windows/run.sh --test          verification en ~10 min avant le vrai banc / 10-min sanity check
# Reprenable : les executions deja completes sont sautees. Resumable: completed runs are skipped.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WD="$HERE/windows"
SDK="$(cat "$WD/.sdk_path" 2>/dev/null)"
[ -n "$SDK" ] && [ -f "$SDK/Bin/Pathtracer.exe" ] || { echo "ERREUR : lancer d'abord ./windows/setup.sh / run setup.sh first"; exit 1; }
OUT="$HERE/results/sdk"
OUTW=$(cygpath -m "$OUT")
mkdir -p "$OUT"
SUITE=all; RAPIDE=0; TEST=0
for a in "$@"; do case $a in --rapide|--quick) RAPIDE=1;; --test) TEST=1;; sharc|nrc|cout|dlss|all) SUITE=$a;; *) echo "argument inconnu : $a"; exit 1;; esac; done
REPS=2; [ $RAPIDE = 1 ] && REPS=1
if [ $TEST = 1 ]; then OUT="$HERE/results/test"; OUTW=$(cygpath -m "$OUT"); mkdir -p "$OUT"; fi
JOURNAL="$OUT/journal.txt"
log () { echo "$(date '+%F %T') $*" | tee -a "$JOURNAL"; }

# ---- informations sur la machine (une fois)
if [ ! -f "$HERE/results/systeme.txt" ]; then
  { echo "date : $(date '+%F %T')"
    nvidia-smi --query-gpu=name,driver_version,memory.total,power.limit,clocks.max.graphics --format=csv 2>/dev/null
    echo; powershell -NoProfile -Command "(Get-CimInstance Win32_Processor).Name; (Get-CimInstance Win32_OperatingSystem).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem).Version; '{0:N0} Go RAM' -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB)" 2>/dev/null
  } > "$HERE/results/systeme.txt"
fi

cd "$SDK/Bin"
TL () {   # timeline par scenario (etats de states.txt)
  case $1 in
    nuit) echo "0:150,1:300,0:150";; lampe0) echo "1:60,2:150,1:150";; lampe1) echo "1:60,5:150,1:150";;
    auvent) echo "7:100,6:150,7:150";; panneau) echo "0:100,3:150,0:150";;
  esac
}
complete () { [ -f "$1/errors.csv" ] && [ $(grep -vc '^#' "$1/errors.csv") -ge $2 ]; }
launch () {   # dossier largeur hauteur delai_max_s inactivite_max_s
  # Surveillance : si plus aucun fichier du dossier n'est ecrit pendant <inactivite> s, le GPU est fige -> on tue.
  # Watchdog: if no file in the run folder is written for <inactivite> s, the GPU hung -> kill.
  local cfg="$(cygpath -m "$1/cfg.txt")" t=0 rc=0
  ./Pathtracer.exe -scene BistroBench2 -width $2 -height $3 -bench "$cfg" > "$1/console.txt" 2>&1 &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    sleep 10; t=$((t + 10))
    if [ $t -ge $4 ] || [ -z "$(find "$1" -type f -newermt "$5 seconds ago" 2>/dev/null | head -1)" ]; then
      log "  bloque ou trop long apres ${t} s -> arret / hung or too long -> killed"
      taskkill //F //IM Pathtracer.exe > /dev/null 2>&1; sleep 5; rc=124; break
    fi
  done
  [ $rc = 0 ] && { wait $pid; rc=$?; }
  taskkill //F //IM Pathtracer.exe > /dev/null 2>&1
  return $rc
}

refs () {   # resolution  images_par_etat
  local R=$1 W=${1%x*} H=${1#*x} d="$OUT/refs/$1"
  [ -f "$d/ref/ref_7.bin" ] && [ -f "$d/probes.bin" ] && return
  mkdir -p "$d/ref"
  { echo "mode ref"; echo "tech none"; echo "spp 8"; echo "out $(cygpath -m "$d/ref")"; echo "warmup 5"; echo "refframes $2"; cat "$WD/states.txt"; } > "$d/cfg.txt"
  log "references $R (8 etats x $2 images)"
  local essai
  for essai in 1 2 3; do
    launch "$d" $W $H 14400 900 && [ -f "$d/ref/ref_7.bin" ] && break
    log "  references $R incompletes (essai $essai) -> on recommence / incomplete, retrying"
  done
  python "$WD/sondes.py" "$(cygpath -m "$d")" > "$d/sondes.txt" || log "  ERREUR : sondes $R"
}

run () {   # suite resolution scenario config rep tech options...
  local suite=$1 R=$2 sc=$3 n=$4 rep=$5 t=$6; shift 6
  local W=${R%x*} H=${R#*x} d="$OUT/$suite/$R/$sc/$n/r$rep" tl=$(TL $sc)
  local frames=$(echo $tl | tr "," "\n" | cut -d: -f2 | awk '{s+=$1} END {print s+1}')
  complete "$d" $frames && return
  mkdir -p "$d"
  local extra=() delai=1800 rd="$OUT/refs/$R"
  case $R in 3840x2160) delai=5400;; esac
  if [ $suite = dlss ]; then
    extra=("denoiser dlssrr" "dlss perf" "spp 1"); rd="$OUT/refs/$R"
  else
    extra=("denoiser accum" "spp 4")
  fi
  { echo "mode run"; echo "tech $t"; for x in "${extra[@]}"; do echo "$x"; done; for x in "$@"; do echo "$x"; done
    echo "out $(cygpath -m "$d")"; echo "warmup $((60 + 11 * rep))"
    if [ $suite != cout ]; then echo "refs $(cygpath -m "$rd/ref")"; echo "probes $(cygpath -m "$rd/probes.bin")"; fi
    cat "$WD/states.txt"; echo "timeline $tl"; } > "$d/cfg.txt"
  for essai in 1 2; do
    launch "$d" $W $H $delai 240
    complete "$d" $frames && { log "ok      $suite $R $sc $n r$rep"; return; }
    log "ECHEC   $suite $R $sc $n r$rep (essai $essai, code $?) -> nouvel essai"
  done
  log "ABANDON $suite $R $sc $n r$rep"
}

SHARC_CFGS () {   # suite res scenario rep
  run $1 $2 $3 sanscache $4 none
  run $1 $2 $3 sharc $4 sharc
  run $1 $2 $3 sharc_vidage $4 sharc "snapshots 1" "eventboost 30" "eventclear 1"
  run $1 $2 $3 sharc_briques $4 sharc "snapshots 1" "compactsnap 1" "eventboost 30" "eventclear 1"
}
NRC_CFGS () {
  run $1 $2 $3 nrc $4 nrc
  run $1 $2 $3 nrc_contournement90 $4 nrc "eventboost 90" "eventbypass 90"
  run $1 $2 $3 nrc_p3_rebond3 $4 nrc "eventboost 90" "eventbypass 90" "bypassbounces 3"
}

if [ $TEST = 1 ]; then
  log "=== test rapide : une execution par suite, references courtes (resultats non significatifs)"
  refs 960x540 16
  run sharc 960x540 lampe0 sharc_briques 0 sharc "snapshots 1" "compactsnap 1" "eventboost 30" "eventclear 1"
  run nrc 960x540 lampe0 nrc_p3_rebond3 0 nrc "eventboost 90" "eventbypass 90" "bypassbounces 3"
  run cout 1920x1080 lampe0 sharc 0 sharc
  refs 1920x1080 16
  run dlss 1920x1080 lampe0 sharc_briques_dlssreset 0 sharc "snapshots 1" "compactsnap 1" "eventboost 30" "eventclear 1" "dlssreset 1"
  cd "$HERE" && PYTHONIOENCODING=utf-8 python "$WD/analyse.py" "$OUT" > "$OUT/RESULTATS_test.md"
  n=$(grep -c " ok      " "$JOURNAL"); log "=== test termine : $n/4 executions ok (voir $OUT/journal.txt et RESULTATS_test.md)"
  exit 0
fi
log "=== debut : suite $SUITE, $REPS repetition(s)"
if [ $SUITE = all ] || [ $SUITE = sharc ] || [ $SUITE = nrc ]; then refs 960x540 256; fi

if [ $SUITE = all ] || [ $SUITE = sharc ]; then
  for rep in $(seq 0 $((REPS - 1))); do for sc in nuit lampe0 lampe1 auvent panneau; do
    SHARC_CFGS sharc 960x540 $sc $rep
    run sharc 960x540 $sc sharc_cible $rep sharc "snapshots 1" "compactsnap 1" "depinv 1"
  done; done
fi
if [ $SUITE = all ] || [ $SUITE = nrc ]; then
  for rep in $(seq 0 $((REPS - 1))); do for sc in nuit lampe0 auvent; do
    run nrc 960x540 $sc sanscache $rep none
    NRC_CFGS nrc 960x540 $sc $rep
    run nrc 960x540 $sc nrc_intensifie $rep nrc "eventboost 30"
    run nrc 960x540 $sc nrc_p2_c40 $rep nrc "eventboost 90" "eventbypass 40"
  done; done
fi
if [ $SUITE = all ] || [ $SUITE = cout ]; then
  RES="1920x1080 3840x2160"; [ $RAPIDE = 1 ] && RES="1920x1080"
  for R in $RES; do for rep in $(seq 0 $((REPS - 1))); do for sc in nuit lampe0; do
    SHARC_CFGS cout $R $sc $rep
    NRC_CFGS cout $R $sc $rep
  done; done; done
fi
if [ $SUITE = all ] || [ $SUITE = dlss ]; then
  RES="1920x1080 3840x2160"; [ $RAPIDE = 1 ] && RES="1920x1080"
  for R in $RES; do
    refs $R 192
    NR=$REPS; [ $R = 3840x2160 ] && NR=1
    for rep in $(seq 0 $((NR - 1))); do for sc in lampe0 nuit auvent; do
      SHARC_CFGS dlss $R $sc $rep
      run dlss $R $sc sharc_briques_dlssreset $rep sharc "snapshots 1" "compactsnap 1" "eventboost 30" "eventclear 1" "dlssreset 1"
      run dlss $R $sc nrc $rep nrc
      run dlss $R $sc nrc_contournement90 $rep nrc "eventboost 90" "eventbypass 90"
    done; done
  done
fi
log "=== fin. Analyse :"
cd "$HERE" && PYTHONIOENCODING=utf-8 python "$WD/analyse.py" "$OUT" | tee "$HERE/results/RESULTATS.md"
log "Resultats : results/RESULTATS.md. Pour les envoyer / to send them back : ./windows/pack.sh"
