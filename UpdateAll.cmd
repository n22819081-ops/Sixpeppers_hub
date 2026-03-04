@echo off
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process cmd -Verb RunAs -ArgumentList '/c','\"%~f0\"'"
  exit /b
)


echo Running: winget upgrade --all
winget upgrade --all --accept-package-agreements --accept-source-agreements
echo.

REM Chocolatey check
where choco >nul 2>&1
if errorlevel 1 (
  echo Chocolatey is not installed.
  choice /m "Install Chocolatey to update more apps"
  if errorlevel 2 goto done

  echo Installing Chocolatey...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; iex ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
  echo.
)

where choco >nul 2>&1
if not errorlevel 1 (
  echo Running: choco upgrade all -y
  choco upgrade all -y
)

:done
echo.
echo Done.
pause
exit /b 0
