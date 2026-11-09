$ErrorActionPreference = 'Stop'
$evidence = $env:TAUDEM_CI_EVIDENCE
$stage = 'official QGIS MSI download'
try {
    $url = 'https://download.qgis.org/downloads/QGIS-OSGeo4W-3.44.15-1.msi'
    $installer = Join-Path $env:RUNNER_TEMP 'QGIS-OSGeo4W-3.44.15-1.msi'
    Invoke-WebRequest $url -OutFile $installer
    $hash = (Get-FileHash $installer -Algorithm SHA256).Hash
    $stage = 'official QGIS unattended installation'
    $log = Join-Path $evidence 'qgis-msi-install.log'
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn /norestart /L*v `"$log`"" -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "QGIS MSI installer exit $($process.ExitCode)" }
    $stage = 'find supplied QGIS Python launcher'
    $launcher = $null
    foreach ($folder in Get-ChildItem $env:ProgramFiles -Directory -Filter 'QGIS*') {
        foreach ($name in @('python-qgis-ltr.bat', 'python-qgis.bat')) {
            $candidate = Join-Path $folder.FullName "bin\$name"
            if (Test-Path $candidate) { $launcher = $candidate; break }
        }
        if ($launcher) { break }
    }
    if (-not $launcher) { throw 'Official QGIS installation supplied no Python launcher' }
    Copy-Item $launcher (Join-Path $evidence 'supplied-python-launcher.bat')
    "QGIS_PYTHON_LAUNCHER=$launcher" | Out-File $env:GITHUB_ENV -Append -Encoding utf8
    @{ status = 'INSTALLED'; installer = $url; sha256 = $hash; launcher = $launcher } |
        ConvertTo-Json | Set-Content (Join-Path $evidence 'qgis-installation.json')
} catch {
    @{ status = 'BLOCKED'; stage = $stage; error = $_.Exception.Message } |
        ConvertTo-Json | Set-Content (Join-Path $evidence 'qgis-installation.json')
    throw
}
