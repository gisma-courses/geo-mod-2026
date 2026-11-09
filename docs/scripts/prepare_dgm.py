# -*- coding: utf-8 -*-
"""DGM-Kacheln für das QGIS/TauDEM-Arbeitsblatt vorbereiten.

Installation wie beim TauDEM-Skript: In QGIS unter Verarbeitung ->
Werkzeugkiste -> Skripte -> Neues Skript erstellen speichern.

Dieses Werkzeug bereitet ausschließlich Rasterdaten auf. Es berechnet
KEINE Senkenfüllung, Fließrichtungen, Einzugsgebiete oder Sedimentflüsse.
QGIS 3.34+, GDAL-Python-Bindings aus der QGIS-Installation; Linux/Windows.
"""

import hashlib
import json
import math
from pathlib import Path

from osgeo import gdal, osr
from qgis.core import (
    QgsProcessingAlgorithm,
    QgsProcessingException,
    QgsProcessingOutputRasterLayer,
    QgsProcessingOutputString,
    QgsProcessingParameterCrs,
    QgsProcessingParameterFile,
    QgsProcessingParameterFolderDestination,
    QgsProcessingParameterNumber,
    QgsProcessingContext,
)


class PrepareDgmProcessing(QgsProcessingAlgorithm):
    INPUT_DIR = "INPUT_DIR"
    OUT_DIR = "OUT_DIR"
    TARGET_CRS = "TARGET_CRS"
    RESOLUTION = "RESOLUTION"
    DEM = "DEM"
    VRT = "VRT"
    REPORT = "REPORT"

    def name(self):
        return "dgm_vorbereiten"

    def displayName(self):
        return "DGM vorbereiten: Kacheln mosaikieren und Arbeitsraster erzeugen"

    def group(self):
        return "Modellieren in der Geographie"

    def groupId(self):
        return "geo_mod_2026"

    def createInstance(self):
        return PrepareDgmProcessing()

    def shortHelpString(self):
        return (
            "Fasst benachbarte DGM-GeoTIFF-Kacheln zu einem virtuellen Mosaik "
            "zusammen und erzeugt daraus ein einheitliches, in Metern "
            "aufgelöstes GeoTIFF für TauDEM.\n\n"
            "Eingabeordner: Nur die benötigten DGM-Kacheln als .tif/.tiff "
            "ablegen (keine Unterordner). Alle Kacheln müssen ein Band, "
            "dasselbe KBS, dieselbe Zellweite und ein gemeinsames "
            "Rastergitter besitzen; überlappende Kacheln werden abgelehnt.\n\n"
            "Ziel-KBS leer lassen, um das KBS der Eingangsdaten zu "
            "übernehmen; ansonsten ein projiziertes KBS mit Metereinheit "
            "angeben (für den Burgwald: EPSG:25832). "
            "Standard-Zellweite: 5 m, im Dialog frei veränderbar. "
            "Das Arbeitsraster wird mit GDAL Average aus dem Mosaik erzeugt.\n\n"
            "Ausgaben im Ergebnisordner: dgm_mosaik.vrt, ein DGM mit "
            "auflösungsabhängigem Namen (z. B. dgm5.tif oder dgm10.tif), "
            "dgm_pruefung.json. Bestehende Dateien werden NICHT überschrieben. "
            "Die VRT-Datei verweist weiterhin auf die Originalkacheln: "
            "Quellordner daher nicht verschieben oder löschen.\n\n"
            "Das Werkzeug kontrolliert Georeferenzierung, Kachelanordnung "
            "und das Ausgaberaster. Fehlende Werte werden gezählt, "
            "aber nicht durch eine eigene Lückenfüllung ergänzt. "
            "Achtung: Average bildet Mittelwerte aus gültigen Quellpixeln; "
            "kleine NoData-Lücken können im gröberen Zielraster unsichtbar werden. "
            "Eine fachliche Prüfung von DGM-Grenzen und "
            "Kachelübergängen bleibt nötig. "
            "PitRemove und alle hydrologischen Annahmen gehören erst "
            "zum separaten TauDEM-Werkzeug."
        )

    def initAlgorithm(self, config=None):
        self.addParameter(QgsProcessingParameterFile(
            self.INPUT_DIR,
            "Ordner mit DGM-Kacheln (.tif/.tiff)",
            behavior=QgsProcessingParameterFile.Folder))
        self.addParameter(QgsProcessingParameterFolderDestination(
            self.OUT_DIR, "Ergebnisordner für Mosaik, Arbeitsraster und Prüfbericht"))
        self.addParameter(QgsProcessingParameterNumber(
            self.RESOLUTION, "Zellweite des Arbeitsrasters (Meter)",
            type=QgsProcessingParameterNumber.Double,
            defaultValue=5.0, minValue=0.01))
        self.addParameter(QgsProcessingParameterCrs(
            self.TARGET_CRS, "Ziel-KBS (leer = KBS der Kacheln)",
            optional=True))
        self.addOutput(QgsProcessingOutputRasterLayer(
            self.DEM, "Aufbereitetes DGM (GeoTIFF)"))
        self.addOutput(QgsProcessingOutputString(
            self.VRT, "Virtuelles Kachelmosaik (VRT)"))
        self.addOutput(QgsProcessingOutputString(
            self.REPORT, "Prüfbericht (JSON)"))

    @staticmethod
    def _spatial_reference(wkt, label):
        if not wkt:
            raise QgsProcessingException(label + ": Koordinatenreferenzsystem fehlt.")
        ref = osr.SpatialReference()
        if ref.ImportFromWkt(wkt) != 0:
            raise QgsProcessingException(label + ": KBS kann nicht gelesen werden.")
        return ref

    @staticmethod
    def _inspect_tiles(paths):
        """Metadaten prüfen, ohne die Eingabedaten zu verändern."""
        tiles = []
        reference = None
        ref_gt = None
        for path in paths:
            ds = gdal.Open(str(path), gdal.GA_ReadOnly)
            if ds is None:
                raise QgsProcessingException("DGM nicht lesbar: " + str(path))
            try:
                if ds.RasterCount != 1:
                    raise QgsProcessingException(
                        "DGM benötigt genau ein Höhenband: " + path.name)
                srs = PrepareDgmProcessing._spatial_reference(
                    ds.GetProjection(), path.name)
                gt = ds.GetGeoTransform()
                if ds.RasterXSize < 1 or ds.RasterYSize < 1:
                    raise QgsProcessingException("Leere Rasterkachel: " + path.name)
                if gt[1] <= 0 or gt[5] >= 0 or abs(gt[2]) > 1e-10 or abs(gt[4]) > 1e-10:
                    raise QgsProcessingException(
                        "Nur nordorientierte, nicht gedrehte Rasterkacheln: " + path.name)
                if reference is None:
                    reference, ref_gt = srs, gt
                else:
                    if not reference.IsSame(srs):
                        raise QgsProcessingException(
                            "Unterschiedliche Quell-KBS; Kacheln getrennt prüfen: " + path.name)
                    if not math.isclose(gt[1], ref_gt[1], rel_tol=1e-8) or \
                       not math.isclose(gt[5], ref_gt[5], rel_tol=1e-8):
                        raise QgsProcessingException(
                            "Unterschiedliche Quell-Pixelgrößen: " + path.name)
                    # Gleicher Zellursprung modulo der Pixelweite.
                    col = (gt[0] - ref_gt[0]) / ref_gt[1]
                    row = (gt[3] - ref_gt[3]) / ref_gt[5]
                    if abs(col - round(col)) > 1e-5 or \
                       abs(row - round(row)) > 1e-5:
                        raise QgsProcessingException(
                            "Kachel nicht auf gemeinsamem Rastergitter: " + path.name)
                xmin = gt[0]
                xmax = gt[0] + ds.RasterXSize * gt[1]
                ymax = gt[3]
                ymin = gt[3] + ds.RasterYSize * gt[5]
                tiles.append({
                    "datei": str(path),
                    "breite_pixel": ds.RasterXSize,
                    "hoehe_pixel": ds.RasterYSize,
                    "ausdehnung": [xmin, ymin, xmax, ymax],
                    "pixelgroesse": [gt[1], abs(gt[5])],
                    "nodata_quelle": ds.GetRasterBand(1).GetNoDataValue(),
                })
            finally:
                ds = None

        for i, first in enumerate(tiles):
            a = first["ausdehnung"]
            for second in tiles[i + 1:]:
                b = second["ausdehnung"]
                ox = min(a[2], b[2]) - max(a[0], b[0])
                oy = min(a[3], b[3]) - max(a[1], b[1])
                tol = max(1e-7, abs(ref_gt[1]) * 1e-6)
                if ox > tol and oy > tol:
                    raise QgsProcessingException(
                        "Überlappende Kacheln (Priorität unklar): " +
                        Path(first["datei"]).name + " und " +
                        Path(second["datei"]).name)
        return tiles, reference, ref_gt

    @staticmethod
    def _validity_counts(ds, feedback):
        """Gültigkeitsmaske in Streifen lesen, ohne das DGM vollständig zu laden."""
        mask_band = ds.GetRasterBand(1).GetMaskBand()
        width, height = ds.RasterXSize, ds.RasterYSize
        invalid = 0
        for y in range(0, height, 256):
            if feedback.isCanceled():
                raise QgsProcessingException("DGM-Aufbereitung abgebrochen.")
            rows = min(256, height - y)
            data = mask_band.ReadRaster(0, y, width, rows,
                                        buf_type=gdal.GDT_Byte)
            if data is None:
                raise QgsProcessingException("Gültigkeitsmaske nicht lesbar.")
            invalid += data.count(b"\x00")
        return width * height - invalid, invalid

    @staticmethod
    def _sha256(path):
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def processAlgorithm(self, parameters, context, feedback):
        input_value = self.parameterAsFile(parameters, self.INPUT_DIR, context)
        output_value = self.parameterAsFileOutput(parameters, self.OUT_DIR, context)
        if not input_value or not output_value:
            raise QgsProcessingException("Eingabe- und Ergebnisordner angeben.")

        input_dir = Path(input_value).expanduser().resolve()
        out_dir = Path(output_value).expanduser().resolve()
        if not input_dir.is_dir():
            raise QgsProcessingException("Eingabeordner existiert nicht: " + str(input_dir))
        if input_dir == out_dir:
            raise QgsProcessingException(
                "Eingabe- und Ergebnisordner müssen verschieden sein.")
        paths = sorted((p.resolve() for p in input_dir.iterdir()
                        if p.is_file() and p.suffix.lower() in (".tif", ".tiff")),
                       key=lambda p: p.name.casefold())
        if not paths:
            raise QgsProcessingException("Keine GeoTIFF-Kacheln im Eingabeordner gefunden.")
        resolution = self.parameterAsDouble(parameters, self.RESOLUTION, context)
        if not math.isfinite(resolution) or resolution <= 0:
            raise QgsProcessingException("Die Ziel-Zellweite muss positiv sein.")

        feedback.pushInfo("{} GeoTIFF-Kachel(n) gefunden.".format(len(paths)))
        tiles, source_srs, source_gt = self._inspect_tiles(paths)
        target = self.parameterAsCrs(parameters, self.TARGET_CRS, context)
        if target.isValid():
            target_srs = self._spatial_reference(target.toWkt(), "Ziel-KBS")
        else:
            target_srs = source_srs
        if not target_srs.IsProjected() or \
           not math.isclose(target_srs.GetLinearUnits(), 1.0, abs_tol=1e-8):
            raise QgsProcessingException(
                "Ziel-KBS muss projiziert sein und Meter als Längeneinheit verwenden.")
        target_wkt = target_srs.ExportToWkt()

        out_dir.mkdir(parents=True, exist_ok=True)
        vrt_path = out_dir / "dgm_mosaik.vrt"
        resolution_tag = ("%g" % resolution).replace(".", "p")
        dem_path = out_dir / ("dgm" + resolution_tag + ".tif")
        report_path = out_dir / "dgm_pruefung.json"
        outputs = (vrt_path, dem_path, report_path)
        existing = [str(p) for p in outputs if p.exists()]
        if existing:
            raise QgsProcessingException(
                "Bestehende Ausgaben werden nicht überschrieben:\n" + "\n".join(existing))
        if any(p in outputs for p in paths):
            raise QgsProcessingException("Ausgabedatei ist zugleich Eingabekachel.")

        completed = False
        vrt = None
        dst = None
        try:
            if feedback.isCanceled():
                raise QgsProcessingException("DGM-Aufbereitung abgebrochen.")
            feedback.pushInfo("1/3: Virtuelles Mosaik (ohne Änderung der Quellwerte)")
            vrt = gdal.BuildVRT(str(vrt_path), [str(p) for p in paths],
                                options=gdal.BuildVRTOptions(
                                    resolution="user",
                                    xRes=source_gt[1], yRes=abs(source_gt[5]),
                                    resampleAlg="nearest"))
            if vrt is None:
                raise QgsProcessingException("GDAL konnte kein VRT-Mosaik erzeugen.")
            vrt.FlushCache()

            feedback.pushInfo("2/3: Einheitliches Arbeitsraster (Average, {} m)".format(
                resolution))
            def progress(fraction, message, unused):
                feedback.setProgress(10 + 75 * fraction)
                return 0 if feedback.isCanceled() else 1

            options = gdal.WarpOptions(
                format="GTiff", dstSRS=target_wkt,
                xRes=resolution, yRes=resolution,
                targetAlignedPixels=True,
                resampleAlg="average", outputType=gdal.GDT_Float32,
                dstNodata=-9999.0,
                creationOptions=["COMPRESS=DEFLATE", "TILED=YES", "PREDICTOR=3"],
                callback=progress)
            dst = gdal.Warp(str(dem_path), vrt, options=options)
            if dst is None or feedback.isCanceled():
                raise QgsProcessingException("GDAL Warp fehlgeschlagen oder abgebrochen.")
            dst.FlushCache()
            dst = None
            vrt = None

            feedback.pushInfo("3/3: Ausgaberaster und NoData prüfen")
            output_ds = gdal.Open(str(dem_path), gdal.GA_ReadOnly)
            if output_ds is None or output_ds.RasterCount != 1:
                raise QgsProcessingException("Ausgabe-GeoTIFF ist nicht lesbar.")
            try:
                actual_srs = self._spatial_reference(
                    output_ds.GetProjection(), "Ausgabe")
                if not actual_srs.IsSame(target_srs):
                    raise QgsProcessingException("Ausgabe-KBS entspricht nicht dem Ziel-KBS.")
                gt = output_ds.GetGeoTransform()
                if not math.isclose(gt[1], resolution, rel_tol=1e-7) or \
                   not math.isclose(abs(gt[5]), resolution, rel_tol=1e-7):
                    raise QgsProcessingException("Ausgabe-Zellweite stimmt nicht.")
                valid, invalid = self._validity_counts(output_ds, feedback)
                if valid == 0:
                    raise QgsProcessingException("Ausgabe enthält keine gültigen DGM-Zellen.")
                width, height = output_ds.RasterXSize, output_ds.RasterYSize
                xmin, ymax = gt[0], gt[3]
                xmax = xmin + width * gt[1]
                ymin = ymax + height * gt[5]
                output_info = {
                    "crs_wkt": output_ds.GetProjection(),
                    "pixelgroesse_meter": [gt[1], abs(gt[5])],
                    "dimensionen": [width, height],
                    "ausdehnung": [xmin, ymin, xmax, ymax],
                    "gueltige_zellen": valid,
                    "nodata_zellen": invalid,
                    "nodata_wert": output_ds.GetRasterBand(1).GetNoDataValue(),
                }
            finally:
                output_ds = None

            for info, path in zip(tiles, paths):
                if feedback.isCanceled():
                    raise QgsProcessingException("DGM-Aufbereitung abgebrochen.")
                info["sha256"] = self._sha256(path)
            report = {
                "verfahren": "GDAL BuildVRT (nearest) -> Warp (average)",
                "gdal_version": gdal.VersionInfo("--version"),
                "eingabeordner": str(input_dir),
                "quell_kbs_wkt": source_srs.ExportToWkt(),
                "kacheln": tiles,
                "ausgabe_vrt": str(vrt_path),
                "ausgabe_dgm": str(dem_path),
                "zielauflosung_meter": resolution,
                "ausgabe": output_info,
                "hinweise": [
                    "Das VRT verweist auf die ursprünglichen Quelldateien.",
                    "Keine gesonderte NoData-Lückenfüllung; GDAL Average kann kleine Quelllücken im gröberen Zielpixel verdecken.",
                    "Senkenfüllung und Hydrologie sind NICHT Teil dieser Aufbereitung.",
                    "Der hydrologische Zuflussbereich kann über diese DGM-Kacheln hinausreichen.",
                    "Kachelübergänge und Datenqualität fachlich in QGIS kontrollieren.",
                ],
            }
            report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2),
                                   encoding="utf-8")
            completed = True
            feedback.setProgress(100)
            feedback.pushInfo("Arbeitsraster: " + str(dem_path))
            feedback.pushInfo("Gültige Zellen: {}; NoData: {}".format(valid, invalid))
            if invalid:
                feedback.pushInfo(
                    "ACHTUNG: Ausgabe enthält NoData. Kachelabdeckung/Masken prüfen.")
            if context.project() is not None:
                details = QgsProcessingContext.LayerDetails(
                    "DGM {} m (aufbereitet)".format(resolution),
                    context.project(), self.DEM)
                context.addLayerToLoadOnCompletion(str(dem_path), details)
            return {
                self.OUT_DIR: str(out_dir),
                self.DEM: str(dem_path),
                self.VRT: str(vrt_path),
                self.REPORT: str(report_path),
            }
        except Exception as exc:
            if isinstance(exc, QgsProcessingException):
                raise
            raise QgsProcessingException("DGM-Aufbereitung fehlgeschlagen: " + str(exc))
        finally:
            dst = None
            vrt = None
            if not completed:
                # Ausschließlich Dateien dieses neuen Laufs entfernen.
                for path in outputs:
                    try:
                        path.unlink(missing_ok=True)
                    except OSError:
                        feedback.pushInfo("Unvollständige Ausgabe bitte prüfen: " + str(path))
