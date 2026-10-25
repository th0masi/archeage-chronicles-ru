@echo off
setlocal
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Enable-Russian.ps1" -GameRoot "%~dp0." -Culture en %*
set "ru_exit_code=%errorlevel%"
echo.
pause
exit /b %ru_exit_code%
