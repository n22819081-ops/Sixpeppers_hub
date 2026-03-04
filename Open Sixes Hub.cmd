@echo off
cd /d "%~dp0"

REM Launch FriendHub hidden so the user cannot accidentally close it.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SixesHub_MediaMaintenance_patched_v6_4_2_ui.ps1"

exit /b
