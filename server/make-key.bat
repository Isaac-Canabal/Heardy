@echo off
REM Genera una clave de API y la escribe en server\.env.
REM Windows no trae openssl, asi que se usa el modulo secrets de Python.

setlocal
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
    echo [ERROR] Falta el entorno virtual. Ejecuta setup.bat primero.
    exit /b 1
)

call ".venv\Scripts\python.exe" tools\make_key.py
endlocal
