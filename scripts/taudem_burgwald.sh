#!/usr/bin/env bash
# TauDEM-Kommandozeilenweg zum geo-mod-2026-Arbeitsblatt (Linux).
# Entspricht den vier Modi von scripts/taudem_burgwald_processing.py.
# Keine QGIS-/PyQGIS-Abhängigkeit; erforderlich: Bash, GDAL (gdalinfo),
# Python 3 (Standardbibliothek), TauDEM-Binaries und ein MPI-Launcher.
set -euo pipefail

usage() {
  cat <<'HELP'
TauDEM-Berechnungen wie im QGIS-Processing-Skript (vom Projektverzeichnis aus):

  bash scripts/taudem_burgwald.sh basis \
    processing/myBurgwald/dgm5.tif resultate/myBurgwald

  bash scripts/taudem_burgwald.sh becken \
    resultate/myBurgwald data/auslass.gpkg

  bash scripts/taudem_burgwald.sh wasser \
    resultate/myBurgwald processing/runoff_zelle_m3.tif

  bash scripts/taudem_burgwald.sh sediment \
    resultate/myBurgwald processing/angebot.tif processing/kapazitaet.tif

  SUFFIX=kap05 bash scripts/taudem_burgwald.sh sediment \
    resultate/myBurgwald processing/angebot.tif processing/kapazitaet_kap05.tif

Optionale Umgebungsvariablen (entsprechen den QGIS-Parametern):
  TAUDEM_BIN=/pfad/zum/bin    TauDEM-Programme; leer = im PATH suchen
  MPIEXEC=mpiexec            MPI-Launcher oder voller Pfad (Standard mpiexec)
  NPROC=2                    Anzahl MPI-Prozesse (Standard 2)
  HA_1=2                     Kleine Gerinneschwelle in Hektar (Modus basis)
  HA_2=5                     Große Gerinneschwelle in Hektar (Modus basis)
  MOVE=0                     Auslass maximal N Zellen verschieben (Modus becken)
  STREAM=/pfad/src.tif       Gerinneraster bei MOVE>0; Standard OUT/src_2ha.tif
                            (bei HA_1 != 2 explizit angeben)
  OUTLET_LAYER=auslass       Name des Punktlayers in einem GeoPackage (automatisch
                            erkannt, wenn es genau einen Punktlayer enthält)
  SUFFIX=kap05              Ausgabesuffix in wasser/sediment; leer = ohne Suffix

Der Ergebnisordner muss für alle vier Modi derselbe sein. Die Modi bauen auf
bereits erzeugten p.tif (becken/wasser) bzw. ang.tif (sediment) auf.

Modus basis: projiziertes, ungedrehtes GeoTIFF in Metern mit quadratischen
Rasterzellen; HA_1 < HA_2. Ergebnisnamen analog QGIS, z. B. src_2ha.tif.
Modus becken: gespeicherter OGR-Punktlayer, insbesondere GeoPackage mit genau
1 Punkt und ganzzahligem Feld id. Bei MOVE>0 wird auslass_auf_gerinne.shp
angelegt; Lage/Attribut dist_moved anschließend in QGIS kontrollieren.
Für Shapefile-Auslass zusätzlich ogrinfo (aus GDAL) erforderlich.
Modus wasser/sediment: Eingaberaster müssen auf dem Rastergitter von p.tif
bzw. ang.tif liegen. NoData-Bereiche zusätzlich in QGIS prüfen.

Die TauDEM-Randprüfung bleibt aktiviert (KEIN -nc).
Vorhandene Ausgabedateien werden NICHT überschrieben. Bei einem abgebrochenen
Lauf entstandene Teildateien vor erneutem Start prüfen/entfernen.
HELP
}

fail() { printf 'Fehler: %s\n' "$*" >&2; exit 2; }
need_file() { [[ -f "$1" ]] || fail "Eingabedatei fehlt: $1"; }
need_tiff() {
  need_file "$1"
  case "${1,,}" in *.tif|*.tiff) ;; *) fail "Eingabe muss ein GeoTIFF sein: $1";; esac
}
need_tool() { command -v "$1" >/dev/null 2>&1 || fail "Benötigtes Programm nicht gefunden: $1"; }
new_outputs() {
  local path
  for path in "$@"; do
    [[ ! -e "$path" ]] || fail "Ausgabe existiert bereits (keine Überschreibung): $path"
  done
}

# Die QGIS-Vorlage überprüft Rasterdimensionen, KBS und Ausdehnung.
# Hier werden die vollständigen GDAL-Geotransformen verglichen; so fallen
# auch halbzellige Verschiebungen oder Rasterrotationen zuverlässig auf.
check_grid() {
  local input=$1 reference=$2 label=$3
  need_tiff "$input"
  need_tiff "$reference"
  python3 - "$input" "$reference" "$label" <<'PY'
import json, math, subprocess, sys

def metadata(path):
    result = subprocess.run(['gdalinfo', '-json', path], capture_output=True, text=True)
    if result.returncode:
        sys.exit('Raster nicht lesbar: {}\n{}'.format(path, result.stderr))
    try:
        return json.loads(result.stdout)
    except ValueError as exc:
        sys.exit('Ungültige gdalinfo-Ausgabe für {}: {}'.format(path, exc))

source, target, label = sys.argv[1:]
a, b = metadata(source), metadata(target)
if a.get('size') != b.get('size'):
    sys.exit('{}: Rasterdimensionen unterscheiden sich von {}'.format(label, target))
ga, gb = a.get('geoTransform'), b.get('geoTransform')
if not ga or not gb or any(not math.isclose(x, y, rel_tol=0, abs_tol=1e-7)
                         for x, y in zip(ga, gb)):
    sys.exit('{}: Rasterursprung/Zellweite/Rotation stimmen nicht mit {} überein'.format(label, target))
wa = a.get('coordinateSystem', {}).get('wkt', '').strip()
wb = b.get('coordinateSystem', {}).get('wkt', '').strip()
if not wa or not wb or ''.join(wa.split()) != ''.join(wb.split()):
    sys.exit('{}: KBS-WKT unterscheidet sich von {}. Raster-KBS in QGIS prüfen.'.format(label, target))
PY
}

# Gibt Schwellwerte in Zellen und die dazugehörigen Ausgaben-Tags zurück.
# Dieselbe Rechnung und Benennung wie im QGIS-Processing-Skript.
thresholds() {
  local dem=$1 ha1=$2 ha2=$3
  python3 - "$dem" "$ha1" "$ha2" <<'PY'
import json, math, re, subprocess, sys
path, ha1_text, ha2_text = sys.argv[1:]
try:
    ha1, ha2 = float(ha1_text), float(ha2_text)
except ValueError:
    sys.exit('Gerinneschwellen müssen Zahlen sein.')
if not (math.isfinite(ha1) and math.isfinite(ha2) and 0 < ha1 < ha2):
    sys.exit('Gerinneschwellen müssen positiv sein: HA_1 < HA_2.')
result = subprocess.run(['gdalinfo', '-json', path], capture_output=True, text=True)
if result.returncode:
    sys.exit('DGM nicht lesbar: {}\n{}'.format(path, result.stderr))
info = json.loads(result.stdout)
if not path.lower().endswith(('.tif', '.tiff')):
    sys.exit('DGM muss ein gespeichertes GeoTIFF sein.')
if info.get('driverShortName') not in (None, 'GTiff'):
    sys.exit('DGM muss ein GeoTIFF sein.')
gt = info.get('geoTransform')
if not gt or len(gt) != 6 or abs(gt[2]) > 1e-12 or abs(gt[4]) > 1e-12:
    sys.exit('DGM benötigt ein ungedrehtes Rastergitter.')
dx, dy = abs(gt[1]), abs(gt[5])
if dx <= 0 or dy <= 0 or not math.isclose(dx, dy, rel_tol=1e-6):
    sys.exit('DGM benötigt quadratische Rasterzellen.')
wkt = info.get('coordinateSystem', {}).get('wkt', '')
if not wkt.startswith(('PROJCRS[', 'PROJCS[')):
    sys.exit('DGM benötigt ein projiziertes KBS in Metern.')
# Im projizierten WKT ist die letzte lineare Einheit die kartesische Achseneinheit.
units = re.findall(r'(?:LENGTHUNIT|UNIT)\[\s*"[^"]*"\s*,\s*([0-9.eE+-]+)', wkt)
if not units or not math.isclose(float(units[-1]), 1.0):
    sys.exit('DGM benötigt Meter als lineare KBS-Einheit.')
n1 = math.ceil(ha1 * 10000 / (dx * dy))
n2 = math.ceil(ha2 * 10000 / (dx * dy))
if n1 == n2:
    sys.exit('Beide Gerinneschwellen ergeben dieselbe Zellzahl.')
def tag(ha):
    return ('%g' % ha).replace('.', 'p') + 'ha'
print(n1, n2, tag(ha1), tag(ha2))
PY
}

# Für die GeoPackage-Eingabe ist kein QGIS nötig: SQLite kann das OGR-Layer
# sowie den einen Auslass und dessen ganzzahliges id-Feld prüfen.
gpkg_layer() {
  local gpkg=$1 requested=${2:-}
  python3 - "$gpkg" "$requested" <<'PY'
import pathlib, sqlite3, sys
path, requested = sys.argv[1:]
try:
    con = sqlite3.connect(pathlib.Path(path).resolve().as_uri() + '?mode=ro', uri=True)
    layers = con.execute('SELECT table_name, column_name FROM gpkg_geometry_columns '
                         "WHERE upper(geometry_type_name) = 'POINT'").fetchall()
    names = [row[0] for row in layers]
    if requested:
        if requested not in names:
            sys.exit('GeoPackage-Punktlayer nicht gefunden: {}. Vorhanden: {}'.format(requested, names))
        name = requested
    else:
        if len(names) != 1:
            sys.exit('GeoPackage benötigt genau einen Punktlayer oder OUTLET_LAYER. Vorhanden: {}'.format(names))
        name = names[0]
    identifier = '"' + name.replace('"', '""') + '"'
    cols = con.execute('PRAGMA table_info({})'.format(identifier)).fetchall()
    ids = [c for c in cols if c[1].lower() == 'id']
    if not ids or 'INT' not in ids[0][2].upper():
        sys.exit('Der Punktlayer benötigt ein ganzzahliges Feld id.')
    geom_col = next(col for layer, col in layers if layer == name)
    geometry = '"' + geom_col.replace('"', '""') + '"'
    rows = con.execute('SELECT id, {} FROM {}'.format(geometry, identifier)).fetchall()
    if len(rows) != 1 or type(rows[0][0]) is not int or rows[0][1] is None:
        sys.exit('Der Punktlayer benötigt genau einen gültigen Auslasspunkt mit ganzzahliger id.')
    print(name)
except sqlite3.Error as exc:
    sys.exit('GeoPackage konnte nicht geprüft werden: {}'.format(exc))
PY
}

resolve_executable() {
  local name=$1 path
  if [[ -n "${TAUDEM_BIN:-}" ]]; then
    path="${TAUDEM_BIN%/}/$name"
    [[ -f "$path" && -x "$path" ]] || fail "TauDEM-Programm fehlt oder ist nicht ausführbar: $path"
    printf '%s' "$path"
  else
    path=$(command -v "$name") || fail "TauDEM-Programm nicht im PATH: $name (TAUDEM_BIN setzen)"
    printf '%s' "$path"
  fi
}

resolve_mpi() {
  local launcher=${MPIEXEC:-mpiexec}
  [[ -n "$launcher" ]] || fail 'MPIEXEC darf nicht leer sein.'
  if [[ "$launcher" == */* ]]; then
    [[ -x "$launcher" ]] || fail "MPI-Launcher fehlt oder ist nicht ausführbar: $launcher"
    printf '%s' "$launcher"
  else
    command -v "$launcher" || fail "MPI-Launcher nicht gefunden: $launcher"
  fi
}

run() {
  local executable=$1; shift
  local path=${BINARIES[$executable]}
  printf '\n> %q -n %q %q' "$MPI_LAUNCHER" "$NPROC" "$path"
  printf ' %q' "$@"
  printf '\n'
  "$MPI_LAUNCHER" -n "$NPROC" "$path" "$@"
}

[[ $# -gt 0 ]] || { usage; exit 2; }
case "$1" in -h|--help|help) usage; exit 0;; esac
MODE=$1; shift
NPROC=${NPROC:-2}
SUFFIX=${SUFFIX:-}
MOVE=${MOVE:-0}
HA_1=${HA_1:-2}
HA_2=${HA_2:-5}
[[ "$NPROC" =~ ^[1-9][0-9]*$ ]] || fail 'NPROC muss positiv ganzzahlig sein.'
[[ "$MOVE" =~ ^(0|[1-9][0-9]*)$ ]] || fail 'MOVE muss eine nichtnegative ganze Zahl sein.'
[[ "$SUFFIX" =~ ^[A-Za-z0-9_-]{0,40}$ ]] || fail 'SUFFIX: nur Buchstaben, Ziffern, _ und - (max. 40).'
EXTRA=${SUFFIX:+_$SUFFIX}
need_tool python3
need_tool gdalinfo

declare -a PROGRAMS OUTPUTS
PROGRAMS=(); OUTPUTS=()
case "$MODE" in
  basis)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    DEM=$1; OUT=$2
    need_tiff "$DEM"
    read -r COUNT1 COUNT2 TAG1 TAG2 <<< "$(thresholds "$DEM" "$HA_1" "$HA_2")"
    [[ -n "${TAG1:-}" && -n "${TAG2:-}" ]] || fail 'Gerinneschwellen konnten nicht ermittelt werden.'
    printf 'Zellschwellen: %s Zellen (%s), %s Zellen (%s)\n' "$COUNT1" "$TAG1" "$COUNT2" "$TAG2"
    OUTPUTS=("$OUT/fel.tif" "$OUT/p.tif" "$OUT/sd8.tif" "$OUT/ad8.tif"
             "$OUT/src_$TAG1.tif" "$OUT/src_$TAG2.tif" "$OUT/ang.tif"
             "$OUT/slp.tif" "$OUT/sca.tif" "$OUT/twi.tif")
    PROGRAMS=(PitRemove D8FlowDir AreaD8 Threshold DinfFlowDir AreaDinf TWI)
    ;;
  becken)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    OUT=$1; POINT=$2
    need_file "$POINT"
    need_file "$OUT/p.tif"
    OGR_OPTIONS=()
    if [[ "${POINT,,}" == *.gpkg ]]; then
      POINT_LAYER=$(gpkg_layer "$POINT" "${OUTLET_LAYER:-}")
      OGR_OPTIONS=(-lyrname "$POINT_LAYER")
    elif [[ "${POINT,,}" == *.shp ]]; then
      need_file "${POINT%.*}.shx"
      need_file "${POINT%.*}.dbf"
      need_tool ogrinfo
      OGR_META=$(ogrinfo -ro -so -al "$POINT") || fail "Shapefile nicht mit ogrinfo lesbar: $POINT"
      grep -Eiq '^[[:space:]]*Geometry:[[:space:]]*Point([[:space:]]|$)' <<< "$OGR_META" \n        || fail "Auslass muss ein Punktlayer sein: $POINT"
      grep -Eq '^[[:space:]]*Feature Count:[[:space:]]*1[[:space:]]*$' <<< "$OGR_META" \n        || fail "Auslass-Shapefile muss genau einen Punkt enthalten: $POINT"
      grep -Eiq '^[[:space:]]*id:[[:space:]]*Integer(64)?([[:space:]]|$)' <<< "$OGR_META" \n        || fail "Auslass-Shapefile benötigt ganzzahliges Feld id: $POINT"
      # Sonstige OGR-Formate können über das QGIS-Skript verwendet werden;
      # dieser Kommandozeilenweg unterstützt GeoPackage und Shapefile.
    else
      fail 'Auslass muss GeoPackage (.gpkg) oder Shapefile (.shp) sein.'
    fi
    OUTPUTS=("$OUT/becken.tif")
    PROGRAMS=(GageWatershed)
    if (( MOVE > 0 )); then
      STREAM=${STREAM:-$OUT/src_2ha.tif}
      need_file "$STREAM"
      check_grid "$STREAM" "$OUT/p.tif" 'Gerinneraster'
      MOVED="$OUT/auslass_auf_gerinne.shp"
      for ext in shp shx dbf prj cpg; do OUTPUTS+=("$OUT/auslass_auf_gerinne.$ext"); done
      PROGRAMS=(MoveOutletsToStreams GageWatershed)
    fi
    ;;
  wasser)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    OUT=$1; WEIGHT=$2
    need_file "$OUT/p.tif"
    check_grid "$WEIGHT" "$OUT/p.tif" 'Gewichtsraster'
    OUTPUTS=("$OUT/volumen_gewichtet_m3$EXTRA.tif")
    PROGRAMS=(AreaD8)
    ;;
  sediment)
    [[ $# -eq 3 ]] || { usage; exit 2; }
    OUT=$1; SUPPLY=$2; CAPACITY=$3
    need_file "$OUT/ang.tif"
    check_grid "$SUPPLY" "$OUT/ang.tif" 'Materialangebot'
    check_grid "$CAPACITY" "$OUT/ang.tif" 'Transportkapazität'
    OUTPUTS=("$OUT/transport$EXTRA.tif" "$OUT/ablagerung$EXTRA.tif")
    PROGRAMS=(DinfTransLimAccum)
    ;;
  *) usage; fail "Unbekannter Modus: $MODE";;
esac

# Vor dem ersten MPI-Lauf sämtliche Dateikonflikte und Programme prüfen.
new_outputs "${OUTPUTS[@]}"
MPI_LAUNCHER=$(resolve_mpi)
declare -A BINARIES
for executable in "${PROGRAMS[@]}"; do
  BINARIES[$executable]=$(resolve_executable "$executable")
done
# Bei einer externen TauDEM-Installation sollen eventuelle gemeinsame
# Bibliotheken und weitere TauDEM-Programme ebenfalls erreichbar sein.
if [[ -n "${TAUDEM_BIN:-}" ]]; then export PATH="$TAUDEM_BIN:$PATH"; fi
mkdir -p "$OUT"
printf 'Modus: %s | MPI-Prozesse: %s | Ergebnisordner: %s\n' "$MODE" "$NPROC" "$OUT"

case "$MODE" in
  basis)
    run PitRemove -z "$DEM" -fel "$OUT/fel.tif"
    run D8FlowDir -fel "$OUT/fel.tif" -p "$OUT/p.tif" -sd8 "$OUT/sd8.tif"
    run AreaD8 -p "$OUT/p.tif" -ad8 "$OUT/ad8.tif"
    run Threshold -ssa "$OUT/ad8.tif" -src "$OUT/src_$TAG1.tif" -thresh "$COUNT1"
    run Threshold -ssa "$OUT/ad8.tif" -src "$OUT/src_$TAG2.tif" -thresh "$COUNT2"
    run DinfFlowDir -fel "$OUT/fel.tif" -ang "$OUT/ang.tif" -slp "$OUT/slp.tif"
    run AreaDinf -ang "$OUT/ang.tif" -sca "$OUT/sca.tif"
    run TWI -slp "$OUT/slp.tif" -sca "$OUT/sca.tif" -twi "$OUT/twi.tif"
    ;;
  becken)
    if (( MOVE > 0 )); then
      run MoveOutletsToStreams -p "$OUT/p.tif" -src "$STREAM" -o "$POINT" \
        "${OGR_OPTIONS[@]}" -om "$MOVED" -md "$MOVE"
      POINT=$MOVED
      OGR_OPTIONS=()
      printf '\nAuslass verschoben: %s; Lage und dist_moved in QGIS prüfen.\n' "$POINT"
    fi
    run GageWatershed -p "$OUT/p.tif" -o "$POINT" "${OGR_OPTIONS[@]}" -gw "$OUT/becken.tif"
    ;;
  wasser)
    run AreaD8 -p "$OUT/p.tif" -wg "$WEIGHT" -ad8 "$OUT/volumen_gewichtet_m3$EXTRA.tif"
    ;;
  sediment)
    run DinfTransLimAccum -ang "$OUT/ang.tif" -tsup "$SUPPLY" -tc "$CAPACITY" \
      -tla "$OUT/transport$EXTRA.tif" -tdep "$OUT/ablagerung$EXTRA.tif"
    ;;
esac

# Wie im QGIS-Skript: Ausgaben prüfen, die unmittelbar ausgewertet werden.
if [[ "$MODE" == basis ]]; then
  NEED_OUTPUTS=("$OUT/ad8.tif" "$OUT/src_$TAG1.tif" "$OUT/sca.tif" "$OUT/twi.tif")
elif [[ "$MODE" == becken ]]; then
  NEED_OUTPUTS=("$OUT/becken.tif")
else
  NEED_OUTPUTS=("${OUTPUTS[@]}")
fi
for file in "${NEED_OUTPUTS[@]}"; do need_file "$file"; done
printf '\nErstellt:\n'
for file in "${OUTPUTS[@]}"; do
  if [[ -f "$file" ]]; then printf '  %s\n' "$file"; fi
done
