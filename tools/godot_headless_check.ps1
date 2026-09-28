# Full-project GDScript compile pre-check (two steps).
# Root cause this fixes: GDScript edits without an editor running ("blind edits")
# historically shipped parse errors. Step 1 imports the project; step 2 is the
# REAL gate: --script tools/compile_check.gd force-loads EVERY .gd under
# scripts/tools/scenes with full project context. Step 1 alone does NOT compile
# scripts nobody loads (a fresh class_name file with a parse error once sailed
# through it and only surfaced in the user's editor).
# Usage:
#   powershell -File tools\godot_headless_check.ps1 -GodotBin "E:\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64.exe"
#   (optional -ProjectDir, defaults to <repo>/godot)
# Exit code 0 = clean, 1 = parse/compile errors found (full output tail printed).
# NOTE: kept ASCII-only on purpose; Windows PowerShell 5.1 misreads BOM-less UTF-8.
param(
    [Parameter(Mandatory = $true)][string]$GodotBin,
    [string]$ProjectDir
)

# $PSScriptRoot is unavailable inside param defaults on PS 5.1
if (-not $ProjectDir) {
    $ProjectDir = Join-Path $PSScriptRoot "..\godot"
}

# The main Godot exe is a GUI-subsystem binary: PowerShell returns immediately
# with no output and no exit code. Prefer the *_console.exe wrapper when present.
$consoleWrapper = Join-Path (Split-Path $GodotBin) `
    (([System.IO.Path]::GetFileNameWithoutExtension($GodotBin)) + "_console.exe")
if (Test-Path $consoleWrapper) {
    $GodotBin = $consoleWrapper
}

# Step 1: import (builds .godot cache; surfaces import-time script errors)
$log = [System.IO.Path]::GetTempFileName()
& $GodotBin --headless --editor --quit --path $ProjectDir > $log 2>&1
$importErrors = Select-String -Path $log -Pattern "SCRIPT ERROR|Parse Error|Compile Error"

# Step 2: force-load every .gd (same gate as CI)
$scanLog = [System.IO.Path]::GetTempFileName()
& $GodotBin --headless --path $ProjectDir --script res://tools/compile_check.gd > $scanLog 2>&1
$scanCode = $LASTEXITCODE
$scanSummary = Select-String -Path $scanLog -Pattern "COMPILE_CHECK"
$scanErrors = Select-String -Path $scanLog -Pattern "SCRIPT ERROR|Parse Error|Compile Error|COMPILE FAIL"

if ($importErrors -or $scanCode -ne 0 -or $scanErrors -or -not $scanSummary) {
    if ($importErrors) { $importErrors | ForEach-Object { $_.Line } }
    if ($scanErrors) { $scanErrors | ForEach-Object { $_.Line } }
    Write-Host "--- full output (last 40 lines) ---"
    Get-Content $scanLog -Tail 40
    Remove-Item $log -ErrorAction SilentlyContinue
    Remove-Item $scanLog -ErrorAction SilentlyContinue
    exit 1
}
Remove-Item $log -ErrorAction SilentlyContinue
Remove-Item $scanLog -ErrorAction SilentlyContinue
$count = (Get-ChildItem $ProjectDir -Recurse -Filter *.gd |
    Where-Object { $_.FullName -notmatch '\\\.godot\\' }).Count
Write-Host "GDScript pre-check passed: $count scripts, 0 compile errors (import + full load scan)"
