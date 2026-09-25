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

echo Baue Task-Service ...
dcc64 "%~dp0TaskService.dpr"
if errorlevel 1 exit /b 1

echo Starte Task-Service auf Port %PORT% ... (Beenden mit Ctrl+C)
"%~dp0TaskService.exe"
