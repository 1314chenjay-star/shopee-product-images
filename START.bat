@echo off
chcp 65001 >nul
set "ROOT=%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%_system\start\self_check.ps1"
if errorlevel 1 (
  echo.
  echo Startup self-check failed. Please use the latest release.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%_system\start\menu_beginner.ps1"
if errorlevel 1 (
  echo.
  echo Tool failed. See _system\logs for details.
  pause
)
