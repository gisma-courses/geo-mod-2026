"""Minimal real import; invoke only through QGIS's supplied Python launcher."""
import argparse
import ctypes
import faulthandler
import json
import os
from pathlib import Path
import sys
import traceback

faulthandler.enable(all_threads=True)
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
report = {'python': sys.executable, 'prefix': sys.prefix,
          'launcher': os.environ.get('QGIS_PYTHON_LAUNCHER'),
          'environment': {k: os.environ.get(k) for k in
                          ['OSGEO4W_ROOT', 'QGIS_PREFIX_PATH', 'PYTHONHOME',
                           'PYTHONPATH', 'QT_PLUGIN_PATH', 'GDAL_DATA', 'PROJ_DATA']}}

def native_modules():
    if sys.platform != 'win32':
        return []
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    psapi = ctypes.WinDLL('psapi', use_last_error=True)
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    psapi.EnumProcessModulesEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE),
                                          wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.DWORD]
    psapi.GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE,
                                         wintypes.LPWSTR, wintypes.DWORD]
    handle = kernel.GetCurrentProcess()
    modules = (wintypes.HMODULE * 4096)()
    needed = wintypes.DWORD()
    if not psapi.EnumProcessModulesEx(handle, modules, ctypes.sizeof(modules), ctypes.byref(needed), 3):
        raise ctypes.WinError(ctypes.get_last_error())
    paths = []
    for i in range(min(len(modules), needed.value // ctypes.sizeof(wintypes.HMODULE))):
        name = ctypes.create_unicode_buffer(32768)
        if psapi.GetModuleFileNameExW(handle, modules[i], name, len(name)):
            paths.append(name.value)
    return sorted(set(paths))

try:
    from qgis.core import Qgis
    from osgeo import gdal
    report.update(status='PASS', qgis=Qgis.QGIS_VERSION, gdal=gdal.VersionInfo())
except Exception:
    report.update(status='FAIL', error=traceback.format_exc())
finally:
    try:
        report['loaded_modules'] = native_modules()
    except Exception:
        report['module_inventory_error'] = traceback.format_exc()
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2), flush=True)
sys.exit(0 if report['status'] == 'PASS' else 1)
