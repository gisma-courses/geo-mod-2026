#!/usr/bin/env bash
# TauDEM-Rechenweg zum Quarto-Arbeitsblatt geo-mod-2026.
# Aufruf: basis DEM5 OUTDIR | becken OUTDIR AUSLASS.shp | wasser OUTDIR GEWICHTE.tif
#          | sediment OUTDIR ANGEBOT.tif KAPAZITAET.tif
set -euo pipefail

usage() {
  cat <<'USAGE'
Aufrufe (aus dem Projektverzeichnis):
  bash scripts/taudem_burgwald.sh basis processing/dgm5.tif results
  bash scripts/taudem_burgwald.sh becken results processing/auslass.shp
  bash scripts/taudem_burgwald.sh wasser results processing/runoff_zelle_m3.tif
  bash scripts/taudem_burgwald.sh sediment results processing/angebot.tif processing/kapazitaet.tif

Optionale Umgebung:
  TAUDEM_BIN=/pfad/zu/taudem-binaries   # falls nicht auf PATH
  MPIEXEC=mpirun                       # Standard mpiexec
  NPROC=2                              # Standard 2

Randprüfung bleibt aktiv (es wird KEIN -nc übergeben).
Die Ergebnisse dürfen für Szenarien nicht ohne Sicherung überschrieben werden.
USAGE
}

[[ $# -gt 0 ]] || { usage; exit 2; }
MODE=$1; shift
MPIEXEC=${MPIEXEC:-mpiexec}
NPROC=${NPROC:-2}
[[ "$NPROC" =~ ^[1-9][0-9]*$ ]] || { echo "NPROC muss positiv ganzzahlig sein" >&2; exit 2; }
command -v "$MPIEXEC" >/dev/null || { echo "Fehlt: $MPIEXEC" >&2; exit 127; }

resolve() {
  local executable=$1
  if [[ -n "${TAUDEM_BIN:-}" ]]; then
    [[ -x "$TAUDEM_BIN/$executable" ]] || { echo "Fehlt: $TAUDEM_BIN/$executable" >&2; exit 127; }
    printf '%s' "$TAUDEM_BIN/$executable"
  else
    command -v "$executable" || { echo "Fehlt TauDEM-Programm $executable (PATH/TAUDEM_BIN)" >&2; exit 127; }
  fi
}

run() {
  local executable=$1; shift
  local path
  path=$(resolve "$executable")
  printf '\n> %s -n %s %s' "$MPIEXEC" "$NPROC" "$executable"
  printf ' %q' "$@"
  printf '\n'
  "$MPIEXEC" -n "$NPROC" "$path" "$@"
}

must_file() { [[ -f "$1" ]] || { echo "Eingabedatei fehlt: $1" >&2; exit 2; }; }

case "$MODE" in
  basis)
    [[ $# == 2 ]] || { usage; exit 2; }
    DEM=$1; OUT=$2; must_file "$DEM"; mkdir -p "$OUT"
    run PitRemove -z "$DEM" -fel "$OUT/fel.tif"
    run D8FlowDir -fel "$OUT/fel.tif" -p "$OUT/p.tif" -sd8 "$OUT/sd8.tif"
    run AreaD8 -p "$OUT/p.tif" -ad8 "$OUT/ad8.tif"
    run Threshold -ssa "$OUT/ad8.tif" -src "$OUT/src_2ha.tif" -thresh 800
    run Threshold -ssa "$OUT/ad8.tif" -src "$OUT/src_5ha.tif" -thresh 2000
    run DinfFlowDir -fel "$OUT/fel.tif" -ang "$OUT/ang.tif" -slp "$OUT/slp.tif"
    run AreaDinf -ang "$OUT/ang.tif" -sca "$OUT/sca.tif"
    run TWI -slp "$OUT/slp.tif" -sca "$OUT/sca.tif" -twi "$OUT/twi.tif"
    ;;
  becken)
    [[ $# == 2 ]] || { usage; exit 2; }
    OUT=$1; POINT=$2; must_file "$POINT"; must_file "$OUT/p.tif"; must_file "$OUT/src_2ha.tif"
    run MoveOutletsToStreams -p "$OUT/p.tif" -src "$OUT/src_2ha.tif" -o "$POINT" -om "$OUT/auslass_auf_gerinne.shp" -md 2
    echo "Kontrolliere dist_moved und die verschobene Punktlage in QGIS."
    run GageWatershed -p "$OUT/p.tif" -o "$OUT/auslass_auf_gerinne.shp" -gw "$OUT/becken.tif"
    ;;
  wasser)
    [[ $# == 2 ]] || { usage; exit 2; }
    OUT=$1; WEIGHT=$2; must_file "$WEIGHT"; must_file "$OUT/p.tif"
    run AreaD8 -p "$OUT/p.tif" -wg "$WEIGHT" -ad8 "$OUT/volumen_gewichtet_m3.tif"
    ;;
  sediment)
    [[ $# == 3 ]] || { usage; exit 2; }
    OUT=$1; SUPPLY=$2; CAPACITY=$3
    must_file "$OUT/ang.tif"; must_file "$SUPPLY"; must_file "$CAPACITY"
    run DinfTransLimAccum -ang "$OUT/ang.tif" -tsup "$SUPPLY" -tc "$CAPACITY" \
      -tla "$OUT/transport.tif" -tdep "$OUT/ablagerung.tif"
    ;;
  *) usage; exit 2;;
esac
