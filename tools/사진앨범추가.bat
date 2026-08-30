@echo off
chcp 65001 >nul
title Add Photo Album

if "%~1"=="" (
  set /p "DROP=Drop the photo folder here, or paste its path and press Enter: "
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0add-photo-album.ps1" "%DROP%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0add-photo-album.ps1" %*
)

echo.
pause
