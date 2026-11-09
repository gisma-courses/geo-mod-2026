$ErrorActionPreference = 'Stop'
$evidence = $env:TAUDEM_CI_EVIDENCE
New-Item -ItemType Directory -Force $evidence | Out-Null
$stage = 'Microsoft MPI runtime installation'
try {
    $mpi = Join-Path $env:ProgramFiles 'Microsoft MPI\Bin\mpiexec.exe'
    if (-not (Test-Path $mpi)) {
        $runtime = Join-Path $evidence 'msmpisetup.exe'
        Invoke-WebRequest 'https://github.com/microsoft/Microsoft-MPI/releases/download/v10.1.1/msmpisetup.exe' -OutFile $runtime
        $process = Start-Process $runtime -ArgumentList '-unattend' -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "MPI runtime installer exit $($process.ExitCode)" }
    }
    if (-not (Test-Path $mpi)) { throw "MPI launcher missing: $mpi" }

    $stage = 'official TauDEM installer download'
    $url = 'https://github.com/dtarb/TauDEM/releases/download/v5.5.0/TauDEM550_setup_x64.exe'
    $expectedHash = 'fa56043b6c99e59ff6338ebe6b86dafd81c894963cc1af02e96db103f694a7f0'
    $installer = Join-Path $evidence 'TauDEM550_setup_x64.exe'
    Invoke-WebRequest $url -OutFile $installer
    $actualHash = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Official installer SHA256 mismatch: $actualHash" }
    $stage = 'official TauDEM unattended installation'
    $install = Join-Path $env:RUNNER_TEMP 'Official TauDEM with spaces'
    $log = Join-Path $evidence 'taudem-installer.log'
    $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$install`" /LOG=`"$log`""
    $process = Start-Process $installer -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin @(0, 3010)) { throw "TauDEM installer exit $($process.ExitCode)" }
    $stage = 'installed program and DLL inventory'
    $bin = Join-Path $install 'TauDEM5Exe'
    $programs = @('pitremove', 'd8flowdir', 'aread8', 'threshold', 'dinfflowdir',
                  'areadinf', 'twi', 'gagewatershed', 'dinftranslimaccum')
    foreach ($name in $programs) {
        if (-not (Test-Path (Join-Path $bin "$name.exe"))) { throw "Installed binary missing: $name.exe" }
    }
    $dlls = @(Get-ChildItem $install -Recurse -Filter 'gdal*.dll')
    if ($dlls.Count -eq 0) { throw 'Official installer supplied no GDAL DLLs' }
    Get-ChildItem $install -Recurse -File | Where-Object { $_.Extension -in @('.exe', '.dll') } |
        ForEach-Object { [PSCustomObject]@{ path = $_.FullName; version = $_.VersionInfo.FileVersion; sha256 = (Get-FileHash $_.FullName).Hash } } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidence 'installed-binaries.json')
    "TAUDEM_TEST_BIN=$bin" | Out-File $env:GITHUB_ENV -Append -Encoding utf8
    "TAUDEM_TEST_MPI=$mpi" | Out-File $env:GITHUB_ENV -Append -Encoding utf8
    "TAUDEM_INSTALL_ROOT=$install" | Out-File $env:GITHUB_ENV -Append -Encoding utf8
    @{ status = 'INSTALLED'; installer = $url; sha256 = $actualHash; mpi = $mpi; taudem = $bin; bundled_gdal = @($dlls.FullName) } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $evidence 'installation.json')
} catch {
    @{ status = 'BLOCKED'; stage = $stage; error = $_.Exception.Message } |
        ConvertTo-Json | Set-Content (Join-Path $evidence 'installation.json')
    throw
}
