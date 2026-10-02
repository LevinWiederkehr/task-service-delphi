@echo off
rem Startet den Task-Service OHNE zu bauen - fuer alle, die KEIN Delphi
rem installiert haben. TaskService.exe ist bereits fertig kompiliert im Repo
rem enthalten und laeuft als eigenstaendiges Windows-Programm (keine
rem Delphi-Laufzeit/DLLs noetig, nur normale Windows-System-DLLs).
rem
rem Optional: start.cmd <Port>  (Default: 8090)
rem
rem Wichtig: wenn sich am Delphi-Quellcode etwas aendert, muss jemand mit
rem Delphi (per run.cmd) neu bauen und die neue TaskService.exe committen -
rem start.cmd baut nichts, es startet nur, was schon da ist.
setlocal
set "PORT=%~1"
if "%PORT%"=="" set "PORT=8090"

if not exist "%~dp0TaskService.exe" (
  echo FEHLER: TaskService.exe wurde nicht gefunden. "git pull" ausfuehren,
  echo um die neueste vorkompilierte Version zu holen.
  exit /b 1
)

echo Starte Task-Service auf Port %PORT% ... (Beenden mit Ctrl+C)
"%~dp0TaskService.exe"
