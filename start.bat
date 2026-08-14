@echo off
chcp 65001 >nul
set "ROOT=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%start\TinySnow工具.ps1"
if errorlevel 1 (
  echo.
  echo 工具發生錯誤，請查看 logs 資料夾。
  pause
)

