param(
    [string]$GodotExecutable = "",
    [switch]$InstallBuildDependencies,
    [switch]$SkipGodotExport,
    [switch]$CreateArchive
)

function Get-GodotPckEntries {
    param([Parameter(Mandatory = $true)][string]$PckPath)

    $stream = [System.IO.File]::OpenRead((Resolve-Path -LiteralPath $PckPath).Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $magic = [System.Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($magic -ne "GDPC") {
            throw "Invalid Godot PCK header: $PckPath"
        }
        $packVersion = $reader.ReadUInt32()
        if ($packVersion -ne 4) {
            throw "Unsupported Godot PCK format $packVersion; update the release audit before shipping."
        }
        $stream.Seek(32, [System.IO.SeekOrigin]::Begin) | Out-Null
        $directoryOffset = $reader.ReadUInt64()
        if ($directoryOffset -ge [uint64]$stream.Length) {
            throw "Invalid Godot PCK directory offset: $directoryOffset"
        }
        $stream.Seek([int64]$directoryOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $entryCount = $reader.ReadUInt32()
        if ($entryCount -gt 1000000) {
            throw "Unreasonable Godot PCK entry count: $entryCount"
        }
        for ($index = 0; $index -lt $entryCount; $index++) {
            $pathLength = $reader.ReadUInt32()
            if ($pathLength -eq 0 -or $pathLength -gt 1048576) {
                throw "Invalid Godot PCK path length at entry $index"
            }
            $path = [System.Text.Encoding]::UTF8.GetString(
                $reader.ReadBytes([int]$pathLength)
            ).TrimEnd([char]0)
            $offset = $reader.ReadUInt64()
            $size = $reader.ReadUInt64()
            $null = $reader.ReadBytes(16)
            $flags = $reader.ReadUInt32()
            [pscustomobject]@{
                Path = $path
                Offset = $offset
                Size = $size
                Flags = $flags
            }
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path $repoRoot "companion-core"
$godotRoot = Join-Path $repoRoot "godot"
$buildRoot = Join-Path $repoRoot "build"
$releaseRoot = Join-Path $buildRoot "SpringHavenPlaytest"
$python = Join-Path $coreRoot ".venv\Scripts\python.exe"

if (-not (Test-Path -LiteralPath $python)) {
    throw "Companion Core virtual environment is missing: $python"
}

if ($InstallBuildDependencies) {
    & $python -m pip install "pyinstaller>=6.10,<7"
    if ($LASTEXITCODE -ne 0) { throw "PyInstaller installation failed" }
}

& $python -c "import PyInstaller"
if ($LASTEXITCODE -ne 0) {
    throw "PyInstaller is not installed. Re-run with -InstallBuildDependencies."
}

New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$pyInstallerWork = Join-Path $buildRoot ".pyinstaller"
$pyInstallerDist = Join-Path $pyInstallerWork "dist"
$pyInstallerBuild = Join-Path $pyInstallerWork "build"
$entryPoint = Join-Path $coreRoot "tools\core_entry.py"

& $python -m PyInstaller `
    --noconfirm `
    --clean `
    --onefile `
    --name spring-haven-core `
    --paths (Join-Path $coreRoot "src") `
    --distpath $pyInstallerDist `
    --workpath $pyInstallerBuild `
    --specpath $pyInstallerWork `
    $entryPoint
if ($LASTEXITCODE -ne 0) { throw "Companion Core packaging failed" }

if (Test-Path -LiteralPath $releaseRoot) {
    $resolvedBuild = (Resolve-Path $buildRoot).Path
    $resolvedRelease = (Resolve-Path $releaseRoot).Path
    if (-not $resolvedRelease.StartsWith($resolvedBuild, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace a release directory outside build/: $resolvedRelease"
    }
    Remove-Item -LiteralPath $resolvedRelease -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $releaseRoot "companion-core\bin") -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $pyInstallerDist "spring-haven-core.exe") `
    -Destination (Join-Path $releaseRoot "companion-core\bin\spring-haven-core.exe")
Copy-Item -LiteralPath (Join-Path $coreRoot "config") `
    -Destination (Join-Path $releaseRoot "companion-core\config") -Recurse
Copy-Item -LiteralPath (Join-Path $repoRoot "PLAYTEST_README.txt") `
    -Destination (Join-Path $releaseRoot "PLAYTEST_README.txt")

if (-not $SkipGodotExport) {
    if (-not $GodotExecutable) {
        $GodotExecutable = (Get-Command godot -ErrorAction SilentlyContinue).Source
    }
    if (-not $GodotExecutable -or -not (Test-Path -LiteralPath $GodotExecutable)) {
        throw "Godot 4.7 executable was not found. Pass -GodotExecutable or use -SkipGodotExport."
    }
    $gameExecutable = Join-Path $releaseRoot "SpringHaven.exe"
    $godotArguments = @(
        "--headless",
        "--path", ('"' + $godotRoot + '"'),
        "--export-release", '"Windows Playtest"',
        ('"' + $gameExecutable + '"')
    ) -join " "
    $godotProcess = Start-Process -FilePath $GodotExecutable `
        -ArgumentList $godotArguments -WindowStyle Hidden -Wait -PassThru
    if ($godotProcess.ExitCode -ne 0) { throw "Godot export failed" }
    if (-not (Test-Path -LiteralPath $gameExecutable)) {
        throw "Godot reported success but did not create SpringHaven.exe"
    }
}

$forbiddenFiles = Get-ChildItem -LiteralPath $releaseRoot -Recurse -File | Where-Object {
    $_.FullName -match "user_data|provider_key|heartloom\.sqlite|knowledge\.sqlite|local_assets"
}
if ($forbiddenFiles) {
    throw "Release contains local-only data: $($forbiddenFiles.FullName -join ', ')"
}

$releasePck = Join-Path $releaseRoot "SpringHaven.pck"
if (Test-Path -LiteralPath $releasePck) {
    $forbiddenPckEntries = Get-GodotPckEntries -PckPath $releasePck | Where-Object {
        $_.Path -match "(^|/)(local_assets|user_data)/" -or
        $_.Path -match "(^|/)(heartloom|knowledge)\.sqlite($|[./])" -or
        $_.Path -match "(^|/)provider_key($|[./])"
    }
    if ($forbiddenPckEntries) {
        throw "Release PCK contains local-only entries: $($forbiddenPckEntries.Path -join ', ')"
    }
    Write-Host "PCK privacy audit passed."
}

if ($CreateArchive) {
    $archive = Join-Path $buildRoot "SpringHavenPlaytest-win64.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    Compress-Archive -LiteralPath $releaseRoot -DestinationPath $archive -CompressionLevel Optimal
    Write-Host "Archive: $archive"
}

Write-Host "Playable build: $releaseRoot"
