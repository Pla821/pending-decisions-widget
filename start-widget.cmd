@echo off
rem Manual start (no install, no startup shortcut, no settings.json change): double-click to run the widget from this folder.
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\bin\widget.ps1"
