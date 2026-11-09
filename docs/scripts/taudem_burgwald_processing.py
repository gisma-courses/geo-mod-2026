# -*- coding: utf-8 -*-
"""QGIS-Processing-Skript für den Rechenweg des geo-mod-2026-Worksheets.

Nur QGIS/PyQGIS als Python-Abhängigkeit. TauDEM und MPI werden als externe
Programme ausgeführt; Linux und Windows verwenden dieselbe Skriptdatei.

Installation: In QGIS -> Verarbeitung -> Werkzeugkiste -> Skripte -> Neues
Skript erstellen; diese Datei dort speichern oder in den QGIS-Skriptordner
kopieren. Kein zusätzliches Plugin erforderlich.
"""

import math
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading

from qgis.core import (
    QgsProcessing,
    QgsProcessingAlgorithm,
    QgsProcessingContext,
    QgsProcessingException,
    QgsProcessingOutputString,
    QgsProcessingParameterEnum,
    QgsProcessingParameterFolderDestination,
    QgsProcessingParameterNumber,
    QgsProcessingParameterRasterLayer,
    QgsProcessingParameterString,
    QgsProcessingParameterVectorLayer,
    QgsRasterLayer,
    QgsUnitTypes,
)


class TaudemBurgwaldProcessing(QgsProcessingAlgorithm):
    MODE = "MODE"
    DEM = "DEM"
    OUTLET = "OUTLET"
    STREAM = "STREAM"
    WEIGHTS = "WEIGHTS"
    SUPPLY = "SUPPLY"
    CAPACITY = "CAPACITY"
    OUT_DIR = "OUT_DIR"
    HA_1 = "HA_1"
    HA_2 = "HA_2"
    MOVE = "MOVE"
    SUFFIX = "SUFFIX"
    NPROC = "NPROC"
    BIN_DIR = "BIN_DIR"
    MPI = "MPI"

    MODES = [
        "1 – Grundlage (PitRemove, D8, D∞, Schwellen, TWI)",
        "2 – Einzugsgebiet am Auslass (GageWatershed)",
        "3 – Gewichtete Abflussakkumulation (AreaD8)",
        "4 – Transport und Ablagerung (DinfTransLimAccum)",
    ]

    def name(self):
        return "taudem_burgwald"

    def displayName(self):
        return "TauDEM: Abflusswege, Einzugsgebiet, Wasser, Sediment"

    def group(self):
        return "Modellieren in der Geographie"

    def groupId(self):
        return "geo_mod_2026"

    def createInstance(self):
        return TaudemBurgwaldProcessing()

    def shortHelpString(self):
        return (
            "Vier aufeinander aufbauende Berechnungen für EIN Einzugsgebiet. "
            "Als Ergebnisordner bei allen Durchläufen denselben Ordner wählen.\n\n"
            "Modus 1: DGM (GeoTIFF, projiziert in Metern) wählen. Erzeugt "
            "fel, p, sd8, ad8, zwei src-Raster, ang, slp, sca und twi. "
            "Die Schwellen in ha werden anhand der DEM-Zellfläche in "
            "Anzahlen von Rasterzellen umgerechnet.\n\n"
            "Modus 2: Punktlayer mit ganzzahligem Feld id wählen; p.tif "
            "muss im Ergebnisordner liegen. Verschieben ist STANDARDMÄSSIG AUS. "
            "Bei aktivierter Verschiebung wird das src-Raster benötigt "
            "(standardmäßig src_2ha.tif). Punktlage kontrollieren.\n\n"
            "Modus 3: Gewichtsraster in m³ pro Zelle wählen; p.tif "
            "muss im Ergebnisordner liegen.\n\n"
            "Modus 4: Materialangebot und Transportkapazität in denselben "
            "Materialeinheiten wählen; ang.tif muss im Ergebnisordner liegen.\n\n"
            "Alle Eingaberaster müssen deckungsgleich sein (Rasterweite, "
            "Ursprung, Ausdehnung, CRS und NoData). Bei vorhandenen "
            "Ausgabedateien bricht das Skript ab und überschreibt NICHTS. "
            "Für einen zweiten Wasser-/Sediment-Durchlauf einen Suffix wählen.\n\n"
            "Plattform: Linux und Windows. TauDEM-Binaries und MPI sind "
            "separat zu installieren. TauDEM-Verzeichnis leer lassen, wenn "
            "die Programme im PATH liegen. MPI-Befehl: mpiexec oder "
            "vollständiger Pfad zum ausführbaren MPI-Launcher. "
            "Keine Shell, keine zusätzlichen Python-Pakete."
        )

    def initAlgorithm(self, config=None):
        self.addParameter(QgsProcessingParameterEnum(
            self.MODE, "Berechnung", options=self.MODES, defaultValue=0))
        self.addParameter(QgsProcessingParameterRasterLayer(
            self.DEM, "DGM für Modus 1 (GeoTIFF, Meter-KBS)", optional=True))
        self.addParameter(QgsProcessingParameterVectorLayer(
            self.OUTLET, "Auslasspunkte für Modus 2 (OGR-Datei, Feld id)",
            types=[QgsProcessing.TypeVectorPoint], optional=True))
        self.addParameter(QgsProcessingParameterRasterLayer(
            self.STREAM, "Gerinneraster für Verschiebung (Modus 2; sonst src_2ha.tif)",
            optional=True))
        self.addParameter(QgsProcessingParameterRasterLayer(
            self.WEIGHTS, "Volumenbeiträge in m³ pro Zelle (Modus 3)", optional=True))
        self.addParameter(QgsProcessingParameterRasterLayer(
            self.SUPPLY, "Lokales Materialangebot (Modus 4)", optional=True))
        self.addParameter(QgsProcessingParameterRasterLayer(
            self.CAPACITY, "Transportkapazität (Modus 4)", optional=True))
        self.addParameter(QgsProcessingParameterFolderDestination(
            self.OUT_DIR, "Ergebnisordner (in allen Modi derselbe)"))
        self.addParameter(QgsProcessingParameterNumber(
            self.HA_1, "Kleine Gerinneschwelle in ha (Modus 1)",
            type=QgsProcessingParameterNumber.Double, defaultValue=2.0, minValue=0.0001))
        self.addParameter(QgsProcessingParameterNumber(
            self.HA_2, "Große Gerinneschwelle in ha (Modus 1)",
            type=QgsProcessingParameterNumber.Double, defaultValue=5.0, minValue=0.0001))
        self.addParameter(QgsProcessingParameterNumber(
            self.MOVE, "Auslass maximal um N Zellen verschieben (Modus 2; 0 = aus)",
            type=QgsProcessingParameterNumber.Integer, defaultValue=0, minValue=0))
        self.addParameter(QgsProcessingParameterString(
            self.SUFFIX, "Optionaler Ausgabesuffix für Modus 3/4 (z. B. kap05)",
            defaultValue="", optional=True))
        self.addParameter(QgsProcessingParameterNumber(
            self.NPROC, "MPI-Prozesse", type=QgsProcessingParameterNumber.Integer,
            defaultValue=2, minValue=1))
        self.addParameter(QgsProcessingParameterString(
            self.BIN_DIR, "TauDEM-Binärverzeichnis (leer = PATH)",
            defaultValue="", optional=True))
        self.addParameter(QgsProcessingParameterString(
            self.MPI, "MPI-Launcher (mpiexec oder voller Pfad)",
            defaultValue="mpiexec"))
        self.addOutput(QgsProcessingOutputString(
            "FILES", "Erzeugte Dateien (Pfade)"))

    @staticmethod
    def _file_from_raster(layer, label):
        if layer is None:
            raise QgsProcessingException("Eingabe fehlt: {}".format(label))
        # TauDEM erwartet normale Rasterdateien, keine QGIS-/GDAL-URI.
        path = os.path.expanduser(layer.source())
        if not path.lower().endswith((".tif", ".tiff")) or not Path(path).is_file():
            raise QgsProcessingException(
                "{} muss eine gespeicherte GeoTIFF-Datei sein: {}".format(label, path))
        return str(Path(path).resolve())

    @staticmethod
    def _need(path):
        if not Path(path).is_file():
            raise QgsProcessingException("Erforderliche Datei fehlt: {}".format(path))
        return str(path)

    @staticmethod
    def _vector_file(layer):
        if layer is None:
            raise QgsProcessingException("Auslass-Punktlayer fehlt.")
        if layer.fields().indexFromName("id") < 0:
            raise QgsProcessingException("Punktlayer benötigt ein Feld 'id' (Ganzzahl).")
        if layer.featureCount() != 1:
            raise QgsProcessingException("Die Übung erwartet genau einen Auslasspunkt.")
        source_parts = layer.source().split("|")
        source = str(Path(os.path.expanduser(source_parts[0])).resolve())
        if not Path(source).is_file():
            raise QgsProcessingException("Auslass muss als OGR-Datei gespeichert sein: " + source)
        opts = []
        for part in source_parts[1:]:
            if part.lower().startswith("layername="):
                opts = ["-lyrname", part.split("=", 1)[1]]
        return source, opts

    @staticmethod
    def _check_grid(input_layer, reference_path, label):
        """GeoTIFF muss dasselbe Rastergitter wie die Routingdatei besitzen."""
        ref = QgsRasterLayer(str(reference_path), "Referenzraster")
        if not ref.isValid():
            raise QgsProcessingException("Routingraster nicht lesbar: " + str(reference_path))
        if input_layer.crs() != ref.crs() or input_layer.width() != ref.width() or \
                input_layer.height() != ref.height():
            raise QgsProcessingException(label + ": CRS oder Rasterdimensionen stimmen nicht ")
        a, b = input_layer.extent(), ref.extent()
        tol = max(abs(ref.rasterUnitsPerPixelX()), abs(ref.rasterUnitsPerPixelY())) * 1e-6
        if any(abs(getattr(a, attr)() - getattr(b, attr)()) > tol
               for attr in ("xMinimum", "xMaximum", "yMinimum", "yMaximum")):
            raise QgsProcessingException(label + ": Ausdehnung/Pixelursprung stimmt nicht mit "
                                         + str(reference_path) + " überein.")

    @staticmethod
    def _resolve_exec(name, custom_dir=""):
        ext = ".exe" if sys.platform == "win32" else ""
        if custom_dir:
            folder = Path(os.path.expandvars(os.path.expanduser(custom_dir))).resolve()
            candidate = folder / (name + ext)
            if not candidate.is_file() and sys.platform.startswith("linux"):
                candidate = folder / name.lower()
            if not candidate.is_file():
                raise QgsProcessingException("TauDEM-Programm fehlt: " + str(candidate))
            return str(candidate)
        found = shutil.which(name + ext) or shutil.which(name)
        if not found and sys.platform.startswith("linux"):
            found = shutil.which(name.lower())
        if not found:
            raise QgsProcessingException("TauDEM-Programm nicht im PATH: " + name)
        return found

    @staticmethod
    def _resolve_mpi(value):
        value = os.path.expandvars(os.path.expanduser(value.strip().strip('"')))
        if not value:
            raise QgsProcessingException("MPI-Launcher fehlt.")
        if os.path.isabs(value) or "/" in value or "\\" in value:
            if not Path(value).is_file():
                raise QgsProcessingException("MPI-Launcher nicht gefunden: " + value)
            return str(Path(value).resolve())
        found = shutil.which(value)
        if not found:
            raise QgsProcessingException("MPI-Launcher nicht im PATH: " + value)
        return found

    @staticmethod
    def _validate_new_outputs(paths):
        existing = [str(p) for p in paths if p.exists()]
        if existing:
            raise QgsProcessingException(
                "Ausgaben existieren bereits, keine Überschreibung:\n" +
                "\n".join(existing) +
                "\nNeuen Ergebnisordner oder für Wasser/Sediment einen Suffix verwenden.")

    @staticmethod
    def _kill_process_tree(proc):
        if proc.poll() is not None:
            return
        if sys.platform == "win32":
            try:
                subprocess.run(
                    ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=5, check=False)
            except (OSError, subprocess.TimeoutExpired):
                proc.kill()
        else:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    def _run(self, exe, args, launcher, nproc, env, feedback):
        command = [launcher, "-n", str(nproc), exe] + [str(a) for a in args]
        feedback.pushInfo("TauDEM: " + " ".join(command))
        popen_kwargs = {"stdout": subprocess.PIPE, "stderr": subprocess.STDOUT,
                        "stdin": subprocess.DEVNULL, "env": env, "text": True,
                        "errors": "replace", "bufsize": 1}
        if sys.platform == "win32":
            popen_kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        else:
            popen_kwargs["start_new_session"] = True
        try:
            proc = subprocess.Popen(command, **popen_kwargs)
        except OSError as exc:
            raise QgsProcessingException("TauDEM konnte nicht gestartet werden: " + str(exc))

        events = queue.Queue()

        def collect_lines():
            try:
                for line in proc.stdout:
                    events.put(line.rstrip("\r\n"))
            finally:
                events.put(None)

        thread = threading.Thread(target=collect_lines, daemon=True)
        thread.start()
        finished_stream = False
        try:
            while not finished_stream or proc.poll() is None:
                if feedback.isCanceled():
                    self._kill_process_tree(proc)
                    raise QgsProcessingException("Berechnung abgebrochen; Teil-Dateien ggf. löschen.")
                try:
                    line = events.get(timeout=0.2)
                except queue.Empty:
                    continue
                if line is None:
                    finished_stream = True
                elif line:
                    feedback.pushInfo(line)
            exit_code = proc.wait()
        finally:
            if proc.poll() is None:
                self._kill_process_tree(proc)
            proc.wait()
        if exit_code != 0:
            raise QgsProcessingException(
                "TauDEM-Fehler (Exit-Code {}) bei {}. Ausgabe im QGIS-Log prüfen.".format(
                    exit_code, Path(exe).name))

    @staticmethod
    def _threshold_tag(ha):
        return ("%g" % ha).replace(".", "p") + "ha"

    def processAlgorithm(self, parameters, context, feedback):
        mode = self.parameterAsEnum(parameters, self.MODE, context)
        out_value = self.parameterAsFileOutput(parameters, self.OUT_DIR, context)
        if not out_value:
            raise QgsProcessingException("Ergebnisordner fehlt.")
        out_dir = Path(os.path.expanduser(out_value)).resolve()
        out_dir.mkdir(parents=True, exist_ok=True)

        nproc = self.parameterAsInt(parameters, self.NPROC, context)
        custom_dir = self.parameterAsString(parameters, self.BIN_DIR, context).strip()
        launcher_name = self.parameterAsString(parameters, self.MPI, context)
        suffix = self.parameterAsString(parameters, self.SUFFIX, context).strip()
        if not re.fullmatch(r"[A-Za-z0-9_-]{0,40}", suffix):
            raise QgsProcessingException("Suffix: nur Buchstaben, Ziffern, _ und - (max. 40).")
        extra = "_" + suffix if suffix else ""

        steps = []
        paths = []
        load_paths = []

        if mode == 0:
            dem_layer = self.parameterAsRasterLayer(parameters, self.DEM, context)
            dem = self._file_from_raster(dem_layer, "DGM")
            if dem_layer.crs().mapUnits() != QgsUnitTypes.DistanceMeters:
                raise QgsProcessingException("DGM benötigt ein projiziertes KBS in Metern.")
            dx = abs(dem_layer.rasterUnitsPerPixelX())
            dy = abs(dem_layer.rasterUnitsPerPixelY())
            if dx <= 0 or dy <= 0 or not math.isclose(dx, dy, rel_tol=1e-6):
                raise QgsProcessingException("DGM benötigt quadratische Rasterzellen.")
            ha1 = self.parameterAsDouble(parameters, self.HA_1, context)
            ha2 = self.parameterAsDouble(parameters, self.HA_2, context)
            if not 0 < ha1 < ha2:
                raise QgsProcessingException("Gerinneschwellen müssen positiv sein: klein < groß.")
            n1 = math.ceil(ha1 * 10000 / (dx * dy))
            n2 = math.ceil(ha2 * 10000 / (dx * dy))
            tag1, tag2 = self._threshold_tag(ha1), self._threshold_tag(ha2)
            if n1 == n2:
                raise QgsProcessingException("Beide Gerinneschwellen entsprechen derselben Zellzahl.")
            feedback.pushInfo("Zellfläche: {:g} m²; Schwellen: {} und {} Zellen".format(
                dx * dy, n1, n2))
            fn = lambda s: out_dir / (s + ".tif")
            fel, p, sd8, ad8 = map(fn, ("fel", "p", "sd8", "ad8"))
            src1, src2 = fn("src_" + tag1), fn("src_" + tag2)
            ang, slp, sca, twi = map(fn, ("ang", "slp", "sca", "twi"))
            paths = [fel, p, sd8, ad8, src1, src2, ang, slp, sca, twi]
            steps = [
                ("PitRemove", ["-z", dem, "-fel", fel]),
                ("D8FlowDir", ["-fel", fel, "-p", p, "-sd8", sd8]),
                ("AreaD8", ["-p", p, "-ad8", ad8]),
                ("Threshold", ["-ssa", ad8, "-src", src1, "-thresh", n1]),
                ("Threshold", ["-ssa", ad8, "-src", src2, "-thresh", n2]),
                ("DinfFlowDir", ["-fel", fel, "-ang", ang, "-slp", slp]),
                ("AreaDinf", ["-ang", ang, "-sca", sca]),
                ("TWI", ["-slp", slp, "-sca", sca, "-twi", twi]),
            ]
            load_paths = [ad8, src1, sca, twi]
        elif mode == 1:
            outlet_layer = self.parameterAsVectorLayer(parameters, self.OUTLET, context)
            outlet, ogr_options = self._vector_file(outlet_layer)
            p = self._need(out_dir / "p.tif")
            move = self.parameterAsInt(parameters, self.MOVE, context)
            becken = out_dir / "becken.tif"
            paths = [becken]
            if move:
                source_layer = self.parameterAsRasterLayer(parameters, self.STREAM, context)
                stream = (self._file_from_raster(source_layer, "Gerinneraster")
                          if source_layer is not None
                          else self._need(out_dir / "src_2ha.tif"))
                if source_layer is not None:
                    self._check_grid(source_layer, p, "Gerinneraster")
                moved = out_dir / "auslass_auf_gerinne.shp"
                # Shapefile has mehrere Seiten-Dateien; kompletter Satz darf nicht existieren.
                paths += [moved.with_suffix(ext) for ext in
                          (".shp", ".shx", ".dbf", ".prj", ".cpg")]
                steps.append(("MoveOutletsToStreams", [
                    "-p", p, "-src", stream, "-o", outlet] + ogr_options +
                    ["-om", moved, "-md", move]))
                outlet = str(moved)
                ogr_options = []
            steps.append(("GageWatershed", ["-p", p, "-o", outlet] +
                          ogr_options + ["-gw", becken]))
            load_paths = [becken]
        elif mode == 2:
            weight_layer = self.parameterAsRasterLayer(parameters, self.WEIGHTS, context)
            weight = self._file_from_raster(weight_layer, "Gewichtsraster")
            p = self._need(out_dir / "p.tif")
            self._check_grid(weight_layer, p, "Gewichtsraster")
            result = out_dir / ("volumen_gewichtet_m3" + extra + ".tif")
            paths = [result]
            steps = [("AreaD8", ["-p", p, "-wg", weight, "-ad8", result])]
            load_paths = [result]
        elif mode == 3:
            supply_layer = self.parameterAsRasterLayer(parameters, self.SUPPLY, context)
            cap_layer = self.parameterAsRasterLayer(parameters, self.CAPACITY, context)
            supply = self._file_from_raster(supply_layer, "Materialangebot")
            cap = self._file_from_raster(cap_layer, "Transportkapazität")
            ang = self._need(out_dir / "ang.tif")
            self._check_grid(supply_layer, ang, "Materialangebot")
            self._check_grid(cap_layer, ang, "Transportkapazität")
            transport = out_dir / ("transport" + extra + ".tif")
            deposit = out_dir / ("ablagerung" + extra + ".tif")
            paths = [transport, deposit]
            steps = [("DinfTransLimAccum", ["-ang", ang, "-tsup", supply,
                                             "-tc", cap, "-tla", transport,
                                             "-tdep", deposit])]
            load_paths = paths[:]
        else:
            raise QgsProcessingException("Unbekannter Modus: {}".format(mode))

        self._validate_new_outputs(paths)
        # Prüfen ALLE ausführbaren Programme, bevor teure Berechnungen beginnen.
        launcher = self._resolve_mpi(launcher_name)
        binaries = {name: self._resolve_exec(name, custom_dir)
                    for name, _ in steps}
        env = os.environ.copy()
        if custom_dir:
            bindir = str(Path(os.path.expandvars(os.path.expanduser(custom_dir))).resolve())
            env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
        feedback.pushInfo("Plattform: {}; MPI: {}; Prozesse: {}".format(
            sys.platform, launcher, nproc))

        count = len(steps)
        for index, (name, args) in enumerate(steps, start=1):
            if feedback.isCanceled():
                raise QgsProcessingException("Berechnung abgebrochen.")
            feedback.pushInfo("Schritt {}/{}: {}".format(index, count, name))
            self._run(binaries[name], args, launcher, nproc, env, feedback)
            feedback.setProgress(100.0 * index / count)

        missing = [str(p) for p in load_paths if not p.is_file()]
        if missing:
            raise QgsProcessingException(
                "TauDEM wurde beendet, aber Ausgabe(n) fehlen:\n" + "\n".join(missing))
        for p in load_paths:
            if context.project() is not None:
                details = QgsProcessingContext.LayerDetails(
                    p.stem, context.project(), self.OUT_DIR)
                context.addLayerToLoadOnCompletion(str(p), details)
        feedback.pushInfo("Ergebnisse: " + ", ".join(str(p) for p in paths if p.is_file()))
        if mode == 1 and move:
            feedback.pushInfo("Achtung: verschobenen Auslass und 'dist_moved' in QGIS prüfen!")
        return {self.OUT_DIR: str(out_dir),
                "FILES": "\n".join(str(p) for p in paths if p.is_file())}
