@echo off
:: Wrapper to run the PowerShell boot entry script as Administrator
:: Double-click this file or run from cmd.

echo ============================================
echo  USB Boot Entry Manager
echo  Adds USB drive to Windows Boot Manager
echo  (for password-locked BIOS machines)
echo ============================================
echo.

:: Check for admin
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -Verb RunAs -FilePath 'powershell.exe' -ArgumentList '-ExecutionPolicy Bypass -File \"%~dp0add-windows-boot-entry.ps1\" %*'"
    exit /B
)

powershell.exe -ExecutionPolicy Bypass -File "%~dp0add-windows-boot-entry.ps1" %*

echo.
pause
