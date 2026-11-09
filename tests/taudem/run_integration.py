"""Real QGIS/TauDEM/MPI integration test. Run with QGIS's Python, never mocks."""
import argparse
import faulthandler
import gc
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time
import traceback
import zipfile

REPO = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).parent / 'fixtures'
SOURCE = REPO / 'scripts/taudem_burgwald_processing.py'
QGIS_APP = None
NAMES = ['PitRemove', 'D8FlowDir', 'AreaD8', 'Threshold', 'DinfFlowDir',
         'AreaDinf', 'TWI', 'GageWatershed', 'DinfTransLimAccum']


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def worker(args):
    global QGIS_APP
    # Set profile paths before importing Qt/QGIS. Everything stays in the evidence folder.
    profile = args.work_dir / 'qgis profile'
    os.environ.update(QT_QPA_PLATFORM='offscreen', PYTHONDONTWRITEBYTECODE='1',
                      XDG_DATA_HOME=str(profile / 'data'),
                      XDG_CONFIG_HOME=str(profile / 'config'))
    if sys.platform == 'win32':
        os.environ['APPDATA'] = str(profile / 'AppData' / 'Roaming')
        os.environ['LOCALAPPDATA'] = str(profile / 'AppData' / 'Local')
    report = {'platform': sys.platform, 'script_sha256': hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
              'tests': [], 'complete': False, 'phase': 'QGIS import'}
    report_path = args.work_dir / 'report.json'
    app = None
    try:
        import numpy as np
        import psutil
        from osgeo import gdal, osr
        import qgis
        from qgis.PyQt import sip
        from qgis.core import (Qgis, QgsApplication, QgsProcessingContext,
                               QgsProcessingFeedback, QgsProject, QgsRasterLayer)
        report.update(qgis=Qgis.QGIS_VERSION, gdal=gdal.VersionInfo(),
                      python=sys.version, mpi=str(args.mpi))
        # The application outlives all local project/context/layer objects in exercise().
        app = QgsApplication([], False)
        QGIS_APP = app
        app.initQgis()

        def exercise():
            def passed(name, details):
                report['tests'].append({'name': name, 'status': 'PASS', 'details': details})
                write_json(report_path, report)
                print('PASS:', name, flush=True)

            class Feedback(QgsProcessingFeedback):
                def __init__(self):
                    super().__init__()
                    self.lines = []
                def pushInfo(self, line):
                    self.lines.append(str(line))

            def read(path):
                ds = gdal.Open(str(path))
                assert ds is not None, str(path)
                band = ds.GetRasterBand(1)
                array = band.ReadAsArray()
                valid = np.isfinite(array)
                if band.GetNoDataValue() is not None:
                    valid &= array != band.GetNoDataValue()
                return array, valid, ds.GetGeoTransform(), ds.GetProjection()

            report['phase'] = 'script-provider registration'
            candidates = [Path(QgsApplication.pkgDataPath()) / 'python' / 'plugins',
                          Path(qgis.__file__).parent.parent / 'plugins',
                          Path(sys.prefix) / 'Library' / 'python' / 'plugins',
                          Path('/usr/share/qgis/python/plugins')]
            for candidate in candidates:
                if (candidate / 'processing').is_dir():
                    sys.path.insert(0, str(candidate))
            from processing.script import ScriptUtils
            folder = Path(ScriptUtils.defaultScriptsFolder())
            shutil.copy2(SOURCE, folder / SOURCE.name)
            assert (folder / SOURCE.name).read_bytes() == SOURCE.read_bytes()
            from processing.core.Processing import Processing
            Processing.initialize()
            import processing
            algorithm = QgsApplication.processingRegistry().algorithmById('script:taudem_burgwald')
            assert algorithm is not None
            passed('actual script provider', algorithm.id())
            # Initialize QGIS before exposing the separate TauDEM DLL directory.
            os.environ['PATH'] += os.pathsep + str(args.taudem_bin)
            resolved = {}
            for name in NAMES:
                custom = algorithm._resolve_exec(name, str(args.taudem_bin))
                path = algorithm._resolve_exec(name)
                assert Path(custom).resolve() == Path(path).resolve()
                if sys.platform == 'win32':
                    assert Path(custom).suffix.lower() == '.exe'
                resolved[name] = custom
            assert Path(algorithm._resolve_mpi(str(args.mpi))).is_file()
            passed('native executables: directory, PATH, MPI', resolved)

            dll_stop = threading.Event()
            dll_records = {}
            dll_phase = {'mode': None}
            dll_watch = None

            def loaded_gdal(process):
                return sorted({m.path for m in process.memory_maps()
                               if Path(m.path).name.lower().startswith('gdal')
                               and Path(m.path).suffix.lower() == '.dll'
                               and 'provider' not in Path(m.path).name.lower()})

            parent_gdal = []
            if sys.platform == 'win32':
                assert args.taudem_install_root, 'Windows DLL check requires installer root'
                parent_gdal = loaded_gdal(psutil.Process())
                assert parent_gdal, 'No actual QGIS/Python GDAL DLL observed'
                qgis_root = Path(os.environ.get('OSGEO4W_ROOT', sys.prefix)).resolve()
                assert all(Path(p).is_relative_to(qgis_root) for p in parent_gdal), parent_gdal
                report['qgis_runtime_root'] = str(qgis_root)

                def observe_installed_dlls():
                    while not dll_stop.is_set():
                        for child in psutil.Process().children(recursive=True):
                            try:
                                executable = Path(child.exe())
                                if executable.parent.resolve() != args.taudem_bin:
                                    continue
                                paths = loaded_gdal(child)
                                if paths:
                                    key = (dll_phase['mode'], child.pid, str(executable))
                                    dll_records[key] = paths
                            except (psutil.NoSuchProcess, psutil.AccessDenied):
                                continue
                        time.sleep(.002)

                dll_watch = threading.Thread(target=observe_installed_dlls, daemon=True)
                dll_watch.start()

            report['phase'] = 'reference data'
            manifest = json.loads((FIXTURES / 'manifest.json').read_text())
            archive = FIXTURES / 'reference.zip'
            assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest['reference_zip_sha256']
            data = args.work_dir / 'reference data with spaces'
            with zipfile.ZipFile(archive) as z:
                for filename, checksum in manifest['files_sha256'].items():
                    content = z.read(filename)
                    assert hashlib.sha256(content).hexdigest() == checksum
                    destination = data / filename
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(content)
            ctx = QgsProcessingContext()
            project = QgsProject()
            ctx.setProject(project)
            run_count = 0

            def run(mode, output, feedback=None, **inputs):
                nonlocal run_count
                run_count += 1
                feedback = feedback or Feedback()
                parameters = {'MODE': mode, 'OUT_DIR': str(output),
                              'BIN_DIR': str(args.taudem_bin) if mode % 2 == 0 else '',
                              'MPI': str(args.mpi), 'NPROC': 2, 'HA_1': 2., 'HA_2': 5.,
                              'MOVE': 0, 'SUFFIX': ''}
                parameters.update(inputs)
                dll_phase['mode'] = mode + 1
                write_json(args.work_dir / ('parameters-%02d.json' % run_count), {
                    k: v.source() if hasattr(v, 'source') else v for k, v in parameters.items()})
                try:
                    result = processing.run('script:taudem_burgwald', parameters,
                                            context=ctx, feedback=feedback)
                finally:
                    (args.work_dir / ('processing-%02d.log' % run_count)).write_text(
                        '\n'.join(feedback.lines) + '\n', encoding='utf-8')
                passed('real mode %d' % (mode + 1), result['FILES'].splitlines())
                return result

            def raster(path):
                return str(path)  # Let the real Processing context own its input layers.

            def point(path):
                return str(path) + '|layername=outlets'

            report['phase'] = 'four genuine calculations'
            baseline = data / 'baseline' / 'input'
            output = args.work_dir / 'results with spaces'
            run(0, output, DEM=raster(baseline / 'dem5.tif'))
            run(1, output, OUTLET=point(baseline / 'one-outlet.gpkg'))
            run(2, output, WEIGHTS=raster(baseline / 'local-volume.tif'))
            run(3, output, SUPPLY=raster(baseline / 'local-supply.tif'),
                CAPACITY=raster(baseline / 'capacity.tif'))
            checked = []
            for reference in sorted((data / 'baseline' / 'expected').glob('*.tif')):
                actual, mask, grid, crs = read(output / reference.name)
                expected, emask, egrid, ecrs = read(reference)
                layer = QgsRasterLayer(str(output / reference.name), 'result')
                try:
                    assert layer.isValid()
                finally:
                    sip.delete(layer)
                assert grid == egrid and actual.shape == expected.shape
                assert osr.SpatialReference(wkt=crs).IsSame(osr.SpatialReference(wkt=ecrs))
                assert np.array_equal(mask, emask), reference.name
                assert np.allclose(actual[mask], expected[emask], rtol=1e-5, atol=1e-5), reference.name
                checked.append(reference.name)
            assert len(checked) == 14
            passed('14 outputs: CRS, grid, NoData and reference values', checked)

            report['phase'] = 'known 800-cell and material controls'
            known = data / 'known' / 'input'
            out = args.work_dir / 'known results with spaces'
            out.mkdir()
            for name in ['p.tif', 'ang.tif']:
                shutil.copy2(known / name, out / name)
            run(2, out, WEIGHTS=raster(known / 'known-weights.tif'))
            run(1, out, OUTLET=point(known / 'known-800-outlet.gpkg'))
            run(3, out, SUPPLY=raster(known / 'known-supply.tif'),
                CAPACITY=raster(known / 'known-capacity.tif'))
            volume, valid, _, _ = read(out / 'volumen_gewichtet_m3.tif')
            basin, _, _, _ = read(out / 'becken.tif')
            transport, tv, _, _ = read(out / 'transport.tif')
            deposit, dv, _, _ = read(out / 'ablagerung.tif')
            expected = manifest['known_values']
            assert valid[22, 42] and np.isclose(volume[22, 42], expected['volume_m3'])
            assert int((basin == 7).sum()) == expected['catchment_cells']
            assert tv[10, 11] and dv[10, 11]
            assert np.isclose(transport[10, 11], expected['transport_ME'])
            assert np.isclose(deposit[10, 11], expected['deposition_ME'])
            assert np.isclose(deposit[dv].sum() + transport[22, 42], expected['total_supply_ME'])
            passed('800 cells = 200 m3; material 6 = 3 + 3', expected)

            if dll_watch is not None:
                dll_stop.set()
                dll_watch.join(timeout=5)
                observations = [{'mode': key[0], 'pid': key[1], 'exe': key[2], 'gdal': paths}
                                for key, paths in dll_records.items()]
                dll_evidence = {'qgis_before': parent_gdal,
                                'qgis_after': loaded_gdal(psutil.Process()),
                                'taudem_processes': observations}
                write_json(args.work_dir / 'windows-loaded-gdal.json', dll_evidence)
                assert not dll_watch.is_alive(), 'DLL observation thread did not stop'
                assert dll_evidence['qgis_after'] == parent_gdal, dll_evidence
                assert {entry['mode'] for entry in observations} >= {1, 2, 3, 4}, \
                    'Incomplete DLL observations; no DLL-compatibility conclusion possible'
                assert all(Path(path).is_relative_to(args.taudem_install_root)
                           for entry in observations for path in entry['gdal']), dll_evidence
                passed('actual GDAL DLL separation: QGIS and installed TauDEM', dll_evidence)

            report['phase'] = 'real MPI cancellation at startup'
            feedback = Feedback()
            observed = []
            stop = threading.Event()
            launcher = Path(algorithm._resolve_mpi(str(args.mpi))).resolve()

            def cancel_on_real_launcher():
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline and not stop.is_set():
                    for child in psutil.Process().children(recursive=True):
                        try:
                            if Path(child.exe()).resolve() == launcher:
                                observed.extend([child] + child.children(recursive=True))
                                feedback.cancel()
                                return
                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            continue
                    time.sleep(.01)
            watch = threading.Thread(target=cancel_on_real_launcher, daemon=True)
            watch.start()
            error = None
            try:
                run(0, args.work_dir / 'cancelled results', feedback=feedback,
                    DEM=raster(baseline / 'dem5.tif'))
            except Exception as exc:
                error = str(exc)
            finally:
                stop.set()
                watch.join(timeout=2)
            assert observed and feedback.isCanceled() and error, 'No observed genuine cancellation'
            _, alive = psutil.wait_procs(observed, timeout=8)
            alive = [p for p in alive if p.is_running() and p.status() != psutil.STATUS_ZOMBIE]
            assert not alive, 'MPI process tree survived cancellation'
            passed('real MPI startup cancellation', {'error': error,
                   'observed_pids': [p.pid for p in observed], 'surviving_processes': []})
            assert hashlib.sha256(SOURCE.read_bytes()).hexdigest() == report['script_sha256']
            ctx.temporaryLayerStore().removeAllMapLayers()
            report['complete'] = True
            report['phase'] = 'calculations and cancellation complete'
            write_json(report_path, report)

        exercise()
    except Exception:
        report['failure'] = traceback.format_exc()
        write_json(report_path, report)
        raise
    finally:
        if app is not None:
            gc.collect()  # Release cycles left by Processing exceptions before QGIS shutdown.
            app.exitQgis()
    print('QGIS_EXIT_COMPLETED', flush=True)


def parent(args):
    import psutil  # test-only dependency for actual process-tree observation/timeout cleanup
    args.work_dir.mkdir(parents=True, exist_ok=False)
    command = [sys.executable, '-X', 'faulthandler', str(Path(__file__).resolve()),
               '--worker', '--taudem-bin', str(args.taudem_bin), '--mpi', str(args.mpi),
               '--work-dir', str(args.work_dir)]
    if args.taudem_install_root:
        command += ['--taudem-install-root', str(args.taudem_install_root)]
    started = time.monotonic()
    timed_out = False
    with (args.work_dir / 'stdout.log').open('w', encoding='utf-8') as stdout, \
            (args.work_dir / 'stderr.log').open('w', encoding='utf-8') as stderr:
        process = subprocess.Popen(command, stdout=stdout, stderr=stderr,
                                   env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
        try:
            code = process.wait(timeout=180)
        except subprocess.TimeoutExpired:
            timed_out = True
            children = psutil.Process(process.pid).children(recursive=True)
            for child in children:
                try:
                    child.kill()
                except psutil.NoSuchProcess:
                    pass
            process.kill()
            code = process.wait()
    status = {'command': command, 'returncode': code, 'timed_out': timed_out,
              'elapsed_seconds': time.monotonic() - started}
    write_json(args.work_dir / 'process-status.json', status)
    print(json.dumps(status, indent=2))
    if code != 0:
        print((args.work_dir / 'stderr.log').read_text(encoding='utf-8', errors='replace'),
              file=sys.stderr)
    report_path = args.work_dir / 'report.json'
    complete = report_path.exists() and json.loads(report_path.read_text(encoding='utf-8')).get('complete')
    return 0 if code == 0 and complete and not timed_out else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--taudem-bin', type=Path, required=True)
    parser.add_argument('--mpi', type=Path, required=True)
    parser.add_argument('--work-dir', type=Path, required=True)
    parser.add_argument('--taudem-install-root', type=Path)
    parser.add_argument('--worker', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.taudem_bin = args.taudem_bin.resolve()
    args.mpi = args.mpi.resolve()
    args.work_dir = args.work_dir.resolve()
    if args.taudem_install_root:
        args.taudem_install_root = args.taudem_install_root.resolve()
    if args.worker:
        faulthandler.enable(all_threads=True)
        worker(args)
    else:
        sys.exit(parent(args))
