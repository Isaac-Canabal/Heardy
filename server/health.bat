@echo off
REM Comprueba que el servidor responde y que el proveedor de PO tokens esta vivo.

setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo [ERROR] Falta el entorno virtual. Ejecuta setup.bat primero.
    exit /b 1
)

call ".venv\Scripts\python.exe" tools\health.py %*
endlocal
