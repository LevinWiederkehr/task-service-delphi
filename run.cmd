@echo off
rem Baut und startet den Task-Service. Optional: run.cmd <Port>
rem Default-Port ist 8090 (siehe contracts/openapi/task-service.yaml). Falls der
rem auf diesem Rechner von einer anderen Anwendung belegt ist, einfach einen
rem anderen Port angeben, z.B.: run.cmd 8095
setlocal
set "PORT=%~1"
if "%PORT%"=="" set "PORT=8090"

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
dcc64 "%~dp0TaskService.dpr"
if errorlevel 1 exit /b 1

echo Starte Task-Service auf Port %PORT% ... (Beenden mit Ctrl+C)
"%~dp0TaskService.exe"
