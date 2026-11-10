#!/usr/bin/env bash
# TauDEM-Rechenweg zum Quarto-Arbeitsblatt geo-mod-2026.
# Alternative zur QGIS-Processing-Datei; benötigt zusätzlich gdalinfo und Python 3 für die Rasterprüfung.
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
  SUFFIX=kap05                         # optional für wasser/sediment

Basis: projiziertes GeoTIFF in Metern; quadratische, ungedrehte Rasterzellen.
Gerinneschwellen 2/5 ha werden aus der tatsächlichen Zellfläche berechnet.
Der Auslass wird wie im Processing-Standard ohne Verschiebung verwendet.

Randprüfung bleibt aktiv (es wird KEIN -nc übergeben).
Vorhandene Ausgaben werden nicht überschrieben. Für Szenarien einen Suffix verwenden.
USAGE
}

[[ $# -gt 0 ]] || { usage; exit 2; }
MODE=$1; shift
MPIEXEC=${MPIEXEC:-mpiexec}
NPROC=${NPROC:-2}
SUFFIX=${SUFFIX:-}
[[ "$SUFFIX" =~ ^[A-Za-z0-9_-]{0,40}$ ]] || { echo "Ungültiger SUFFIX" >&2; exit 2; }
EXTRA=${SUFFIX:+_$SUFFIX}
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

new_outputs() {
  local candidate
  for candidate in "$@"; do
    [[ ! -e "$candidate" ]] || { echo "Ausgabe existiert bereits: $candidate" >&2; exit 2; }
  done
}

thresholds() {
  command -v gdalinfo >/dev/null || { echo "Fehlt für die Rasterprüfung: gdalinfo" >&2; return 127; }
  command -v python3 >/dev/null || { echo "Fehlt für die Rasterprüfung: python3" >&2; return 127; }
  gdalinfo -json "$1" | python3 -c '
import json, math, sys
info = json.load(sys.stdin)
gt = info.get("geoTransform")
if not gt or gt[2] != 0 or gt[4] != 0:
    sys.exit("DGM benötigt ein ungedrehtes Rastergitter.")
dx, dy = abs(gt[1]), abs(gt[5])
if dx <= 0 or dy <= 0 or not math.isclose(dx, dy, rel_tol=1e-6):
    sys.exit("DGM benötigt quadratische Rasterzellen.")
wkt = info.get("coordinateSystem", {}).get("wkt", "")
if not wkt.startswith(("PROJCRS[", "PROJCS[")):
    sys.exit("DGM benötigt ein projiziertes KBS in Metern.")
# Der letzte lineare Einheitenfaktor in projiziertem WKT beschreibt die Achseneinheit.
import re
units = re.findall(r"(?:LENGTHUNIT|UNIT)\[\s*\"[^\"]*\"\s*,\s*([0-9.eE+-]+)", wkt)
if not units or not math.isclose(float(units[-1]), 1.0):
    sys.exit("DGM benötigt Meter als lineare KBS-Einheit.")
n1, n2 = math.ceil(20000 / (dx * dy)), math.ceil(50000 / (dx * dy))
if n1 == n2:
    sys.exit("Die Schwellen fallen bei dieser Zellfläche zusammen.")
print(n1, n2)
'
}


case "$MODE" in
  basis)
    [[ $# == 2 ]] || { usage; exit 2; }
    DEM=$1; OUT=$2; must_file "$DEM"
    COUNTS=$(thresholds "$DEM")
    read -r SMALL_CELLS LARGE_CELLS <<< "$COUNTS"
    new_outputs "$OUT/fel.tif" "$OUT/p.tif" "$OUT/sd8.tif" "$OUT/ad8.tif" \
      "$OUT/src_2ha.tif" "$OUT/src_5ha.tif" "$OUT/ang.tif" "$OUT/slp.tif" "$OUT/sca.tif" "$OUT/twi.tif"
    mkdir -p "$OUT"
    run PitRemove -z "$DEM" -fel "$OUT/fel.tif"
    run D8FlowDir -fel "$OUT/fel.tif" -p "$OUT/p.tif" -sd8 "$OUT/sd8.tif"
    run AreaD8 -p "$OUT/p.tif" -ad8 "$OUT/ad8.tif"
    run Threshold -ssa "$OUT/ad8.tif" -src "$OUT/src_2ha.tif" -thresh "$SMALL_CELLS"
    run Threshold -ssa "$OUT/ad8.tif" -src "$OUT/src_5ha.tif" -thresh "$LARGE_CELLS"
    run DinfFlowDir -fel "$OUT/fel.tif" -ang "$OUT/ang.tif" -slp "$OUT/slp.tif"
    run AreaDinf -ang "$OUT/ang.tif" -sca "$OUT/sca.tif"
    run TWI -slp "$OUT/slp.tif" -sca "$OUT/sca.tif" -twi "$OUT/twi.tif"
    ;;
  becken)
    [[ $# == 2 ]] || { usage; exit 2; }
    OUT=$1; POINT=$2; must_file "$POINT"; must_file "$OUT/p.tif"
    new_outputs "$OUT/becken.tif"
    run GageWatershed -p "$OUT/p.tif" -o "$POINT" -gw "$OUT/becken.tif"
    ;;
  wasser)
    [[ $# == 2 ]] || { usage; exit 2; }
    OUT=$1; WEIGHT=$2; must_file "$WEIGHT"; must_file "$OUT/p.tif"
    new_outputs "$OUT/volumen_gewichtet_m3$EXTRA.tif"
    run AreaD8 -p "$OUT/p.tif" -wg "$WEIGHT" -ad8 "$OUT/volumen_gewichtet_m3$EXTRA.tif"
    ;;
  sediment)
    [[ $# == 3 ]] || { usage; exit 2; }
    OUT=$1; SUPPLY=$2; CAPACITY=$3
    must_file "$OUT/ang.tif"; must_file "$SUPPLY"; must_file "$CAPACITY"
    new_outputs "$OUT/transport$EXTRA.tif" "$OUT/ablagerung$EXTRA.tif"
    run DinfTransLimAccum -ang "$OUT/ang.tif" -tsup "$SUPPLY" -tc "$CAPACITY" \
      -tla "$OUT/transport$EXTRA.tif" -tdep "$OUT/ablagerung$EXTRA.tif"
    ;;
  *) usage; exit 2;;
esac
