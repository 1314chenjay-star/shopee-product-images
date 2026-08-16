@echo off
chcp 65001 >nul
set "ROOT=%~dp0"

title TinySnow Coupang 數據採集工具 V1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%_system\start\coupang_only.ps1"
if errorlevel 1 (
  echo.
  echo Coupang tool failed.
  pause
)
