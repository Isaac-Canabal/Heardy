@echo off
REM Arranca las dos mitades del servidor MINIMIZADAS, sin quedarse esperando
REM en primer plano — pensado para Tareas Programadas de Windows (arranque
REM automático al iniciar sesión), no para uso manual en una terminal.
REM Para uso manual normal seguí usando run.bat.

setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    exit /b 1
)
if not exist ".pot-provider\server\build\main.js" (
    exit /b 1
)

start "HeardyPot" /min "%~dp0run-pot.bat"

REM El proveedor tarda un par de segundos en escuchar — misma espera que
REM ya usa run.bat, para que la API no arranque antes de que responda.
timeout /t 6 /nobreak >nul

start "HeardyAPI" /min "%~dp0run-api.bat"
endlocal
