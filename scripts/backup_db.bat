@echo off
REM Nightly backup of UH_GCR_Inventory (Windows). Run from Task Scheduler.
REM One-time setup (as the same Windows user that runs this task):
REM   mysql_config_editor set --login-path=gcr_dba --host=localhost --user=gcr_dba --password
set "MYSQLBIN=C:\Program Files\MySQL\MySQL Server 8.0\bin"
set "BACKUPDIR=C:\GCR\backups"
set "COPYDIR=E:\GCR_Backups"
if not exist "%BACKUPDIR%" mkdir "%BACKUPDIR%"
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set STAMP=%%i
set "OUT=%BACKUPDIR%\UH_GCR_Inventory_%STAMP%.sql"

"%MYSQLBIN%\mysqldump.exe" --login-path=gcr_dba --single-transaction --routines --triggers --events --set-gtid-purged=OFF --result-file="%OUT%" UH_GCR_Inventory
if errorlevel 1 (
  echo FAILED %STAMP% >> "%BACKUPDIR%\backup_log.txt"
  exit /b 1
)
copy "%OUT%" "%COPYDIR%\" >nul
forfiles /p "%BACKUPDIR%" /m UH_GCR_Inventory_*.sql /d -30 /c "cmd /c del @path" 2>nul
echo OK %STAMP% >> "%BACKUPDIR%\backup_log.txt"
