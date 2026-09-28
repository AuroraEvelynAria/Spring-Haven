# Full-project GDScript compile pre-check.
# Root cause this fixes: GDScript edits without an editor running ("blind edits")
# historically shipped parse errors. --headless --editor --quit scans ALL scripts
# with full project context (autoloads registered). Do NOT use per-script
# --check-only: it cannot resolve autoload identifiers and false-positives.
#
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

$log = [System.IO.Path]::GetTempFileName()
& $GodotBin --headless --editor --quit --path $ProjectDir > $log 2>&1
$code = $LASTEXITCODE
$errors = Select-String -Path $log -Pattern "SCRIPT ERROR|Parse Error|Compile Error"
if ($code -ne 0 -or $errors) {
    $errors | ForEach-Object { $_.Line }
    Write-Host "--- full output (last 40 lines) ---"
    Get-Content $log -Tail 40
    Remove-Item $log
    exit 1
}
Remove-Item $log
$count = (Get-ChildItem $ProjectDir -Recurse -Filter *.gd |
    Where-Object { $_.FullName -notmatch '\\\.godot\\' }).Count
Write-Host "GDScript pre-check passed: $count scripts, 0 compile errors"
