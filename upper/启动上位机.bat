@echo off
rem ============================================================================
rem  FPGA Piano - PC Console   launcher  (2026-10-11 rewritten)
rem
rem  WHY REWRITTEN:
rem    The old version was:
rem      start "" powershell -NoProfile -ExecutionPolicy Bypass -STA
rem                   -WindowStyle Hidden -File "%~dp0gui.ps1"
rem    Two problems:
rem      1) -WindowStyle Hidden hid the console, so if the GUI crashed
rem         you saw NOTHING (just "0xc0000142 application failed");
rem      2) start "" created yet another child process. Repeated launches
rem         can exhaust the Windows desktop heap -> 0xc0000142.
rem
rem  NOW: run in the foreground, console VISIBLE, with a probe step.
rem ============================================================================

setlocal
cd /d "%~dp0"

echo ============================================
echo   FPGA Piano - PC Console
echo ============================================
echo.

echo [1/2] Checking PowerShell ...
powershell -NoProfile -Command "exit 0" >nul 2>&1
if errorlevel 1 goto PSFAIL
echo       OK.
echo.

echo [2/2] Starting GUI ...
echo.
echo   Keep this window open. Closing it closes the app.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0gui.ps1"
set RC=%errorlevel%
echo.
echo GUI exited (code %RC%).
if not "%RC%"=="0" echo   NOTE: non-zero exit - see errors above.
pause
exit /b %RC%

:PSFAIL
echo.
echo   [ERROR] PowerShell itself failed to start (0xc0000142).
echo.
echo   This is a Windows process-creation problem, NOT this app.
echo   Usual cause: too many processes launched -> desktop heap exhausted.
echo.
echo   Try, in order:
echo     1) Close extra PowerShell / cmd windows
echo     2) Sign out and sign back in   (most effective)
echo     3) Reboot
echo.
pause
exit /b 1
