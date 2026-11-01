@echo off
rem Removes the startup shortcut made by install-startup.cmd. Does not touch anything else.
setlocal
set "SD=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
if defined PDW_STARTUP set "SD=%PDW_STARTUP%"
set "LNK=%SD%\Pending Decisions Widget.lnk"
if exist "%LNK%" (del "%LNK%" & echo Removed: %LNK%) else (echo Nothing to remove.)
pause
