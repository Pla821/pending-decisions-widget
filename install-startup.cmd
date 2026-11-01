@echo off
rem Adds ONE shortcut to YOUR OWN Startup folder that runs start-widget.cmd at logon.
rem Nothing else: no files copied, no settings.json change, no hooks, no registry, no admin.
rem Remove it again with uninstall-startup.cmd. (PDW_STARTUP overrides the folder, for testing.)
setlocal
set "SD=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup"
if defined PDW_STARTUP set "SD=%PDW_STARTUP%"
if not exist "%SD%" mkdir "%SD%"
set "LNK=%SD%\Pending Decisions Widget.lnk"
set "TGT=%~dp0start-widget.cmd"
if not exist "%TGT%" (echo Cannot find start-widget.cmd next to this file. & pause & exit /b 1)
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK); $s.TargetPath=$env:TGT; $s.WorkingDirectory=Split-Path $env:TGT; $s.WindowStyle=7; $s.Save()"
if exist "%LNK%" (echo Done. The widget will start at your next logon. Shortcut: %LNK%) else (echo Could not create the shortcut. If security software blocked it, stop here and ask IT.)
pause
