@echo off
rem Hilfsskript fuer start.cmd/run.cmd: setzt PORT.
rem   choose-port.cmd <Port>  -> genau diesen Port verwenden
rem   choose-port.cmd         -> 8090, falls belegt 8095
if not "%~1"=="" (
  set "PORT=%~1"
  exit /b 0
)
set "PORT=8090"
powershell -NoProfile -Command "if (Get-NetTCPConnection -LocalPort 8090 -State Listen -ErrorAction SilentlyContinue) { exit 1 }"
if errorlevel 1 (
  echo Port 8090 ist belegt - weiche auf 8095 aus.
  set "PORT=8095"
)
exit /b 0
