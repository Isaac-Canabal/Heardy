@echo off
REM Arranca las dos mitades del servidor de descargas:
REM   - el proveedor de PO tokens, en una ventana aparte
REM   - la API, en esta ventana
REM
REM Ctrl+C aqui para la API; cierra la otra ventana para parar el proveedor.

setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo [ERROR] Falta el entorno virtual. Ejecuta setup.bat primero.
    exit /b 1
)
if not exist ".pot-provider\server\build\main.js" (
    echo [ERROR] El proveedor de PO tokens no esta compilado. Ejecuta setup.bat primero.
    exit /b 1
)

echo Arrancando el proveedor de PO tokens en una ventana aparte...
start "Heardy - PO token provider" cmd /k "%~dp0run-pot.bat"

REM El proveedor tarda un par de segundos en escuchar. Sin esta espera, el
REM primer /health dice que no responde y parece un fallo cuando no lo es.
timeout /t 4 /nobreak >nul

echo.
echo Arrancando la API...
echo.
call ".venv\Scripts\python.exe" -m app.main
endlocal
