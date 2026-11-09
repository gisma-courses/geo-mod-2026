# QGIS/TauDEM: echte Plattformtests

Der Workflow `.github/workflows/taudem-windows.yml` verwendet einen echten
`windows-2022`-Runner. Er ist vorbereitet; ohne einen ausgeführten grünen
Windows-Job ist Windows-Kompatibilität weiterhin **nicht nachgewiesen**.
Der Workflow wird auf einem getrennten Validierungsbranch veröffentlicht und dort ausgeführt.

Prüfstand 09.11.2026: Der portable Test lief unter Linux mit QGIS 3.34.4,
GDAL 3.8.4, TauDEM 5.6.0-beta und zwei echten MPI-Prozessen erfolgreich durch.
Alle Referenzprüfungen einschließlich Abbruch bestanden; Prozess-Exit-Code 0.
`actionlint` und die Python-Syntaxprüfung bestanden. Der Windows-Job wurde noch
nicht gestartet; die Windows-Installation ist damit noch nicht praktisch bestätigt.

## Plattformprüfung am vorhandenen Skript

| Stelle | Codebefund und Test |
|---|---|
| Programmauflösung | Linux sucht ursprüngliche und kleingeschriebene Namen. Windows ergänzt `.exe`; die normale Windows-Dateisuche berücksichtigt Groß-/Kleinschreibung nicht. Verzeichnis und `PATH` werden im echten Test verwendet. |
| MPI | Argumentliste mit `-n 2`, ohne Shell. Windows verwendet den vollständigen Pfad von MS-MPI, gewöhnlich unter `Program Files`. Installation und echte Ausführung werden getrennt protokolliert. |
| Leerzeichen | Eingabe-, Ausgabe- und Windows-Installationspfade enthalten absichtlich Leerzeichen. Es werden weder Programme umbenannt noch Namensverweise angelegt. |
| QGIS | QGIS-Python, Bindings, Qt und GDAL stammen aus derselben aktivierten Conda-Umgebung. Der echte Skriptprovider lädt eine bytegleiche Kopie des Repository-Skripts. |
| DLLs | TauDEM wird mit dem offiziellen `TauDEM550_setup_x64.exe` installiert (SHA-256 geprüft). Ein Beobachtungsthread erfasst die tatsächlich geladenen GDAL-DLL-Pfade der TauDEM-Prozesse für alle vier Modi. QGIS muss seine eigene GDAL-DLL behalten; TauDEM muss die DLL aus seinem Installationsverzeichnis laden. Der Test kompiliert nichts und ersetzt keine DLLs. |
| Abbruch | Windows verwendet im Skript `taskkill /T /F`, Linux die Prozessgruppe. Der Test beobachtet einen tatsächlich gestarteten MPI-Prozess und bricht dann über QGIS-Feedback ab. Er kontrolliert das Ende der beobachteten Prozesse. Dies prüft einen Abbruch beim MPI-Start, keinen lang laufenden Rechenfall. Ein äußerer Timeout führt zu einem fehlgeschlagenen Test. |

Offener Codebefund: Ein nicht erfolgreicher `taskkill`-Exit wird vom Skript nicht
ausgewertet; `wait()` besitzt keinen Timeout. Das bleibt unverändert und wird
nicht durch eine behauptete Windows-Prüfung übergangen. Die bekannten
ResourceWarnings wegen der Prozessausgabe bleiben ebenfalls unverändert.

## Referenzen und Sollwerte

`fixtures/reference.zip` enthält unveränderte kleine Eingaben und 14 Referenzraster
aus den bereits ausgeführten echten Tests vom 09.11.2026. Herkunft und SHA-256
stehen in `fixtures/manifest.json`. Die Quellen wurden nicht neu erzeugt.

Der Test führt alle vier Modi im QGIS-Processing-Framework mit echtem TauDEM und
MPI aus. Er vergleicht CRS, Rastergitter, NoData-Masken und Werte aller 14 Ausgaben
(mit dokumentierter Gleitkommatoleranz `rtol=atol=1e-5`). Hinzu kommen die vorhandenen
Kontrollen: genau 800 Gebietszellen, 200 m³ bei 10 mm und 25 m² Zellfläche sowie
6 ME Angebot = 3 ME Auslasstransport + 3 ME Ablagerung. Keine Mocks.

Die QGIS-Anwendung überlebt die lokalen Projekt-/Kontextobjekte und wird danach
kontrolliert beendet. Ein separater Elternprozess protokolliert den tatsächlichen
Exit-Code; eine PASS-Meldung vor einem Absturz genügt nicht.

## Ausführen unter Linux

Mit dem Python der installierten QGIS-Umgebung, einem neuen Ergebnisverzeichnis
und den tatsächlichen Pfaden zu TauDEM und MPI:

```bash
PYTHONDONTWRITEBYTECODE=1 QT_QPA_PLATFORM=offscreen /usr/bin/python3 \
  tests/taudem/run_integration.py \
  --taudem-bin /home/creu/apps/taudem/bin --mpi /usr/bin/mpiexec \
  --work-dir '/tmp/TauDEM CI run with spaces'
```

`psutil` ist eine zusätzliche Testabhängigkeit zur Beobachtung echter Prozesse;
das produktive QGIS-Skript erhält dadurch keine neue Python-Abhängigkeit.

## Installation und Nachweise

Windows: QGIS 3.44/Python 3.12 aus conda-forge, Microsoft MPI und der
offizielle TauDEM-5.5.0-Installer. Keine SDK-Installation und kein Compiler.
Aufgelöste Conda-Pakete, Download-/Binärprüfsummen und Installerlogs werden
aufbewahrt. Quellen: [QGIS-Paket](https://github.com/conda-forge/qgis-feedstock),
[TauDEM v5.5.0](https://github.com/dtarb/TauDEM/releases/tag/v5.5.0),
[Microsoft MPI](https://github.com/microsoft/Microsoft-MPI/releases/tag/v10.1.1).

Scheitert die Installation, bleiben der Job fehlgeschlagen, `BLOCKER.txt`,
`ci-step-status.json` und vorhandene Installerlogs erhalten. Ein fehlender
Testlauf wird nicht übersprungen und als bestanden gewertet. Bei Testfehlern
stehen Phase und Ausnahme im Bericht; stdout, stderr, einzelne Processing-Aufrufe,
Ein-/Ausgaberaster und Prozessstatus werden als Actions-Artefakt 30 Tage gesichert.

Der Workflow hat ausschließlich Leserechte auf Repository-Inhalte. Er führt
keinen Commit oder Push aus und verändert keine Kursseiten.

Unter Windows liegt der zusätzliche Nachweis in `windows-loaded-gdal.json`. Er enthält
die beobachteten Programme, PIDs und GDAL-DLL-Pfade sowie die QGIS-DLL-Pfade vor
und nach den Berechnungen. Unvollständige DLL-Beobachtung lässt den Test ebenfalls
fehlschlagen; daraus wird keine bestandene DLL-Kompatibilität abgeleitet.
