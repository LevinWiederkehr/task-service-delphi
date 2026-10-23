@echo off
rem Baut und startet den Task-Service. Optional: run.cmd <Port>
rem Ohne Angabe wird 8090 verwendet (siehe contracts/openapi/task-service.yaml),
rem ist 8090 belegt, automatisch 8095.
setlocal
call "%~dp0choose-port.cmd" %1 || exit /b 1

where dcc64 >nul 2>&1
if errorlevel 1 (
  echo FEHLER: "dcc64" wurde nicht gefunden. Pruefe, ob der Delphi-bin-Ordner im PATH ist,
  echo oder oeffne TaskService.dpr direkt in der Delphi-IDE und starte mit F9.
  exit /b 1
)

rem Alte .dcu loeschen: wurde das Projekt zwischendurch in der IDE mit Ziel
rem "Win32" statt "Win64" compiliert (z.B. durch versehentliches F9), bleiben
rem inkompatible 32-Bit-.dcu-Dateien liegen, die dcc64 danach mit "Falsches
rem Unit-Format" ablehnt. Deshalb hier immer sauber neu bauen.
del /q "%~dp0*.dcu" >nul 2>&1

echo Baue Task-Service ...
dcc64 -Q -B "%~dp0TaskService.dpr"
if errorlevel 1 exit /b 1

echo Starte Task-Service auf Port %PORT% ... (Beenden mit Ctrl+C)
"%~dp0TaskService.exe"
