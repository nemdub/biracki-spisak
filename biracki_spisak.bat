@echo off
chcp 65001 >nul
powershell -ExecutionPolicy Bypass -File "%~dp0biracki_spisak.ps1"
pause
