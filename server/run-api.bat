@echo off
REM Arranca solo la API de descargas (sin el proveedor de PO tokens).
REM Usa run.bat si quieres levantar las dos cosas de una vez.

setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo [ERROR] Falta el entorno virtual. Ejecuta setup.bat primero.
    exit /b 1
)

echo API de descargas de Heardy
echo Deja esta ventana abierta. Ctrl+C para parar.
echo.
call ".venv\Scripts\python.exe" -m app.main
endlocal
