@echo off
rem Builds the CE Cams desktop client (nx_open 6.1.2 + your license key + CE Cams branding).
rem   build_ce_cams.bat            release build with installer
rem   build_ce_cams.bat -Dev       faster developer build
rem   build_ce_cams.bat -Root D:\ce
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ce_cams_build.ps1" %*
echo.
pause
