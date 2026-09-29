@echo off
rem Launch the game itself (not the editor) for quick UI checks.
rem ASCII-only on purpose: cmd.exe parses .cmd files in the system ANSI codepage,
rem so non-ASCII content gets mangled and breaks the script.
rem Override the Godot binary with the GODOT_BIN environment variable.
setlocal enabledelayedexpansion
set "GODOT=%GODOT_BIN%"
if defined GODOT if exist "%GODOT%" goto :run

for %%P in (
  "E:\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64_console.exe"
  "E:\Godot_v4.7-stable_win64.exe\Godot_v4.7-stable_win64.exe"
  "D:\Godot\Godot_v4.7-stable_win64.exe"
  "C:\Godot\Godot_v4.7-stable_win64.exe"
) do (
  if exist %%P if not defined GODOT set "GODOT=%%~P"
)
if not defined GODOT for /f "delims=" %%W in ('where godot 2^>nul') do (
  if not defined GODOT set "GODOT=%%W"
)
if not defined GODOT (
  echo [ERROR] Godot 4.7 not found.
  echo Set GODOT_BIN to the Godot executable, or edit the paths above.
  pause
  exit /b 1
)

:run
cd /d "%~dp0godot"
echo Launching game with: "%GODOT%"
"%GODOT%" --path . %*
endlocal
