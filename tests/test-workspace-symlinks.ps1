$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$TestDir = Join-Path ([System.IO.Path]::GetTempPath()) "codex-docker-symlink-test-$PID"
$BundleDir = Join-Path $TestDir "bundle"
$WorkspaceDir = Join-Path $TestDir "workspace"
$OutsideDir = Join-Path $TestDir "workspace-outside"
$FakeBin = Join-Path $TestDir "bin"
$OutputPath = Join-Path $TestDir "external-link-output"
$LauncherPath = Join-Path $BundleDir "codex-docker.ps1"
$OriginalPath = $env:PATH
$OriginalLocation = Get-Location

try {
    # ARRANGE
    New-Item -ItemType Directory -Path (Join-Path $WorkspaceDir "config") -Force | Out-Null
    New-Item -ItemType Directory -Path $BundleDir, $OutsideDir, $FakeBin -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectDir "codex-docker.ps1") -Destination $LauncherPath
    Set-Content -LiteralPath (Join-Path $FakeBin "docker.cmd") -Value "@exit /b 0" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $WorkspaceDir "config\service.conf") -Value "internal"
    Set-Content -LiteralPath (Join-Path $OutsideDir "service.conf") -Value "external"
    Set-Location $WorkspaceDir
    New-Item -ItemType SymbolicLink -Path "service.conf" -Target "config\service.conf" | Out-Null
    $env:PATH = "$FakeBin;$OriginalPath"

    # ACT
    & pwsh -NoProfile -File $LauncherPath build
    if ($LASTEXITCODE -ne 0) {
        throw "Internal workspace symbolic link was rejected"
    }

    # ASSERT
    $ExternalTarget = Join-Path $OutsideDir "service.conf"
    New-Item -ItemType SymbolicLink -Path "external.conf" -Target $ExternalTarget | Out-Null
    & pwsh -NoProfile -File $LauncherPath build *> $OutputPath
    if ($LASTEXITCODE -eq 0) {
        throw "External workspace symbolic link was accepted"
    }
    $Output = Get-Content -LiteralPath $OutputPath -Raw
    if ($Output -notmatch "symbolic link outside the workspace") {
        throw "External workspace symbolic link failed without the expected diagnostic"
    }
}
finally {
    $env:PATH = $OriginalPath
    Set-Location $OriginalLocation
    if (Test-Path -LiteralPath $TestDir) {
        Remove-Item -LiteralPath $TestDir -Recurse -Force
    }
}
