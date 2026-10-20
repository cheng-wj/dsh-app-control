@echo off
setlocal EnableDelayedExpansion

rem ============================================================================
rem  DSH Tools - close / update / reopen DeepSeek Harness
rem ----------------------------------------------------------------------------
rem  Usage:
rem    dsh-tools.bat status
rem        Show install path, CLI presence, running processes, plugin versions.
rem        Read only. Safe to run any time.
rem
rem    dsh-tools.bat restart [--delay=N]
rem        Close DSH, poll until every process is really gone, reopen it.
rem
rem    dsh-tools.bat update <pkg>@<version> [...] [--delay=N]
rem        Close DSH, run the bundled pnpm through the app CLI, reopen it.
rem        Example: dsh-tools.bat update dshmarket@1.66.44
rem
rem  Why this script exists
rem  ----------------------
rem  1) In-app market updates fail with {"code":"already-installed"}: while HMR
rem     is active, installBundle() refuses an installed package before pnpm
rem     ever runs. The reliable path is app-closed + bundled CLI + relaunch.
rem  2) taskkill WITHOUT /T leaves the python memory bridge alive as an orphan.
rem     The relaunched app then spawns a second bridge and both race on the
rem     same sqlite store. /T is not optional.
rem  3) Process death is POLLED, not slept on. A fixed sleep either wastes
rem     seconds or races the new instance into the dying process tree.
rem
rem  IMPORTANT
rem  ---------
rem  This script kills DSH, so it must NOT run as a child of the DSH process
rem  tree (taskkill /T would destroy it mid-run). Launch it via:
rem     powershell -ExecutionPolicy Bypass -File launch-detached.ps1 restart
rem
rem  PORTABILITY NOTE
rem  ----------------
rem  Git-for-Windows puts its own find.exe on PATH, which shadows the Windows
rem  find.exe and breaks `find /I "x"`. Every external tool here is therefore
rem  called by ABSOLUTE System32 path.
rem ============================================================================

set "EXE_NAME=DeepSeek Harness.exe"
set "PROFILE=%DSH_PROFILE%"
if not defined PROFILE set "PROFILE=desktop"
set "DELAY=%DSH_DELAY%"
if not defined DELAY set "DELAY=15"
set "SYSROOT=%SystemRoot%\System32"
set "FINDSTR=%SYSROOT%\findstr.exe"
set "TASKLIST=%SYSROOT%\tasklist.exe"
set "TASKKILL=%SYSROOT%\taskkill.exe"

rem ---- parse args -----------------------------------------------------------
rem Every mode shares ONE option loop, because the options are not mode
rem specific and duplicating the parser is how "update --delay 5" ended up
rem passing "--delay" and "5" to `dsh plugin add` as if they were packages.
rem
rem Two spellings must be accepted for every option:
rem   --delay=5   (what users naturally type)
rem   --delay 5   (what cmd.exe ACTUALLY delivers)
rem cmd treats '=' as an argument separator, so "--delay=5" arrives as two
rem arguments: "--delay" and "5". Testing only for "--delay=" therefore never
rem matched and the option was silently ignored.
rem
rem Options are also passed EXPLICITLY rather than through the environment:
rem this script is normally started via WMI, and a WMI-created process does
rem NOT inherit the caller's environment, so DSH_DELAY / DSH_PROFILE set by a
rem parent would silently not arrive. The env vars remain as a fallback for
rem people running the .bat by hand.
set "MODE=%~1"
if "%MODE%"=="" set "MODE=restart"

if /I "%MODE%"=="--help" goto USAGE
if /I "%MODE%"=="-h"     goto USAGE
if /I "%MODE%"=="status" goto MODE_SET
if /I "%MODE%"=="restart" goto MODE_SET
if /I "%MODE%"=="update" goto MODE_SET

echo [ERROR] unknown mode: %MODE%
goto USAGE

:MODE_SET
shift
set "PKGS="
:MAIN_LOOP
if "%~1"=="" goto RESOLVE
set "ARG=%~1"

if /I "!ARG!"=="--delay" (
    set "DELAY=%~2"
    if "%~2"=="" set "DELAY=15"
    shift
    shift
    goto MAIN_LOOP
)
if /I "!ARG!"=="--profile" (
    set "PROFILE=%~2"
    if "%~2"=="" set "PROFILE=desktop"
    shift
    shift
    goto MAIN_LOOP
)

rem Fallback spellings. cmd.exe normally splits on '=', so these only show up
rem when the argument reached us quoted; keep them working all the same.
echo !ARG! | "%FINDSTR%" /I /C:"--delay=" >nul
if not errorlevel 1 (
    set "DELAY=!ARG:--delay=!"
    shift
    goto MAIN_LOOP
)
echo !ARG! | "%FINDSTR%" /I /C:"--profile=" >nul
if not errorlevel 1 (
    set "PROFILE=!ARG:--profile=!"
    shift
    goto MAIN_LOOP
)

rem Anything else is a package spec (update mode) and is collected here so the
rem install loop never has to re-examine the raw argument list.
set "PKGS=!PKGS! !ARG!"
shift
goto MAIN_LOOP

:TAKE_DELAY
echo %~1 | "%FINDSTR%" /I /C:"--delay=" >nul
if errorlevel 1 goto :eof
set "DELAY=%~1"
set "DELAY=!DELAY:--delay=!"
goto :eof

rem ---- locate the installation ---------------------------------------------
:RESOLVE
set "APP_EXE="
if defined DSH_EXE (
    if exist "%DSH_EXE%" set "APP_EXE=%DSH_EXE%"
)
if not defined APP_EXE (
    if exist "%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe" (
        set "APP_EXE=%LOCALAPPDATA%\Programs\DeepSeek Harness\DeepSeek Harness.exe"
    )
)
if not defined APP_EXE (
    if exist "C:\Users\ZY\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe" (
        set "APP_EXE=C:\Users\ZY\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe"
    )
)
if not defined APP_EXE (
    echo [ERROR] cannot find "%EXE_NAME%".
    echo         looked in %%LOCALAPPDATA%%\Programs and C:\Users\ZY\AppData\Local\Programs
    echo         set DSH_EXE to override.
    exit /b 3
)

for %%I in ("%APP_EXE%") do set "INSTALL_DIR=%%~dpI"
set "CLI=%INSTALL_DIR%resources\runtime\cli\bin\dsh.cmd"
set "PROFILE_DIR=%USERPROFILE%\.dsh\profiles\%PROFILE%"

if /I "%MODE%"=="status"  goto DO_STATUS
if /I "%MODE%"=="restart" goto DO_RESTART
goto DO_UPDATE

rem ===========================================================================
rem  STATUS
rem ===========================================================================
:DO_STATUS
echo ============================================================
echo  DSH status
echo ============================================================
echo  install  : %INSTALL_DIR%
echo  profile  : %PROFILE%
echo  profile  : %PROFILE_DIR%
echo  cli      : %CLI%
echo.
if exist "%CLI%" (echo  cli ok    : yes) else (echo  cli ok    : NO  ^<-- updates will fail)
if exist "%PROFILE_DIR%\cordis.patch.yml" (echo  patch    : yes) else (echo  patch    : NO)
echo.
echo  --- running processes ---
"%TASKLIST%" /FI "IMAGENAME eq %EXE_NAME%" /NH >"%TEMP%\_dsh_ps.txt" 2>nul
"%FINDSTR%" /I /C:"%EXE_NAME%" "%TEMP%\_dsh_ps.txt" >nul 2>&1
if errorlevel 1 (
    echo  DSH is NOT running
) else (
    "%TASKLIST%" /FI "IMAGENAME eq %EXE_NAME%" 2>nul
)
del "%TEMP%\_dsh_ps.txt" >nul 2>&1
echo.
echo  --- python bridge ---
"%TASKLIST%" /FI "IMAGENAME eq python.exe" 2>nul
echo.
echo  --- installed plugins (direct dependencies) ---
call :LIST_PLUGINS
echo ============================================================
exit /b 0

rem ===========================================================================
rem  RESTART
rem ===========================================================================
:DO_RESTART
call :COUNTDOWN
call :CLOSE_APP
if errorlevel 1 exit /b 4
call :REOPEN
exit /b %errorlevel%

rem ===========================================================================
rem  UPDATE  (close -> pnpm add -> reopen)
rem ===========================================================================
:DO_UPDATE
if not exist "%CLI%" (
    echo [ERROR] bundled CLI not found:
    echo         %CLI%
    exit /b 5
)

rem Validate BEFORE the countdown closes the app. Without this, an update with
rem no packages would kill DSH, install nothing, and relaunch it for no reason.
if "!PKGS!"=="" (
    echo [ERROR] update mode needs at least one package argument.
    echo         example: dsh-tools.bat update dshmarket@1.66.44
    echo         (options --delay N and --profile NAME are not packages)
    exit /b 2
)

call :COUNTDOWN
call :CLOSE_APP
if errorlevel 1 exit /b 4

echo.
echo [update] profile=%PROFILE%
set "UPDATE_RC=0"
set "UPDATE_FAILED="

rem PKGS was collected by the shared option parser, so options such as
rem "--delay 5" can never reach this loop and be installed as a package name.
rem The install loop therefore just walks the list; there is nothing left to
rem filter out.
for %%P in (!PKGS!) do (
    echo.
    echo [update] installing %%P
    call "%CLI%" plugin --profile %PROFILE% add "%%P"
    if errorlevel 1 (
        echo [ERROR] install failed for %%P
        set "UPDATE_FAILED=!UPDATE_FAILED! %%P"
        set "UPDATE_RC=6"
    )
)

echo.
if "%UPDATE_RC%"=="0" (
    echo [update] all packages processed successfully
) else (
    echo [update] finished WITH ERRORS on:!UPDATE_FAILED!
)
call :REOPEN
exit /b %UPDATE_RC%

rem ===========================================================================
rem  subroutines
rem ===========================================================================

:COUNTDOWN
if "%DELAY%"=="0" goto :eof
echo.
echo ============================================================
echo  DeepSeek Harness will close in %DELAY% seconds.
echo  Save your work. Press Ctrl+C now to abort.
echo ============================================================
set /a _cd=%DELAY%
:CD_LOOP
if !_cd! LEQ 0 goto :eof
<nul set /p "=^|  !_cd! ...  "
call :SLEEP1
set /a _cd-=1
goto CD_LOOP

:SLEEP1
ping -n 2 127.0.0.1 >nul 2>&1
goto :eof

:LIST_PLUGINS
rem node lives outside the cmd PATH here, so resolve it with where.exe first
set "NODE_EXE="
for /f "delims=" %%N in ('"%SYSROOT%\where.exe" node 2^>nul') do if not defined NODE_EXE set "NODE_EXE=%%N"
if not defined NODE_EXE (
    echo   [node not on PATH - cannot list versions]
    exit /b 0
)
"%NODE_EXE%" "%~dp0list-plugins.js" "%PROFILE_DIR%"
if errorlevel 1 echo   [list-plugins.js reported a problem]
exit /b 0

:IS_RUNNING
rem sets ERRORLEVEL 1 when NOT running
"%TASKLIST%" /FI "IMAGENAME eq %EXE_NAME%" /NH >"%TEMP%\_dsh_ps.txt" 2>nul
"%FINDSTR%" /I /C:"%EXE_NAME%" "%TEMP%\_dsh_ps.txt" >nul 2>&1
set "IS_RUNNING_RC=%errorlevel%"
del "%TEMP%\_dsh_ps.txt" >nul 2>&1
exit /b %IS_RUNNING_RC%

:CLOSE_APP
echo.
echo [1/2] closing DSH ...
"%TASKKILL%" /IM "%EXE_NAME%" /T /F >nul 2>&1

set /a _wait=0
:WAIT_LOOP
call :IS_RUNNING
if errorlevel 1 goto WAIT_OK
set /a _wait+=1
if !_wait! LSS 30 (
    call :SLEEP1
    goto WAIT_LOOP
)

echo [warn] still alive after 30s, running a second kill pass ...
"%TASKKILL%" /IM "%EXE_NAME%" /T /F >nul 2>&1
call :SLEEP1
call :SLEEP1
call :IS_RUNNING
if not errorlevel 1 (
    echo [ERROR] cannot terminate DSH. aborting BEFORE touching plugins,
    echo         so a half-closed app is never left behind.
    exit /b 1
)

:WAIT_OK
echo [1/2] all DSH processes are gone

rem an orphan bridge would race the new instance on the same sqlite store
tasklist /FI "IMAGENAME eq python.exe" /NH >"%TEMP%\_dsh_py.txt" 2>nul
"%FINDSTR%" /I /C:"python.exe" "%TEMP%\_dsh_py.txt" >nul 2>&1
if not errorlevel 1 (
    echo [warn] python.exe still present - likely the memory bridge.
    echo        NOT killing blindly; if the store looks corrupted check:
    echo        tasklist /FI "IMAGENAME eq python.exe"
)
del "%TEMP%\_dsh_py.txt" >nul 2>&1
exit /b 0

:REOPEN
echo.
echo [2/2] starting DSH ...

rem CRITICAL: do NOT replace this with `start "" "%APP_EXE%"`.
rem A GUI app started with `start` inherits THIS cmd window's console.
rem Closing this window then delivers CTRL_CLOSE_EVENT to the app and Electron
rem exits -- that is exactly the "I closed the script and DSH died too" bug.
rem WMI parents the app to WmiPrvSE instead, so it shares no console with us.
set "LAUNCH_PS=%~dp0launch-app.ps1"
if not exist "%LAUNCH_PS%" (
    echo [ERROR] launch-app.ps1 is missing next to this script.
    echo         refusing to fall back to `start`, which would make DSH die
    echo         when this window is closed.
    exit /b 8
)
set "NEW_PID="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCH_PS%" "%APP_EXE%"`) do set "NEW_PID=%%P"
if not defined NEW_PID (
    echo [ERROR] could not start DSH through launch-app.ps1.
    echo         start it manually: "%APP_EXE%"
    exit /b 8
)
echo [2/2] DSH launched, pid=!NEW_PID! -- no console attached, so closing
echo       this window will NOT close DSH.

set /a _boot=0
:BOOT_LOOP
call :SLEEP1
call :IS_RUNNING
if not errorlevel 1 goto BOOT_OK
set /a _boot+=1
if !_boot! LSS 40 goto BOOT_LOOP
echo [ERROR] DSH did not come back within 40s.
echo         start it manually: "%APP_EXE%"
exit /b 7

:BOOT_OK
echo [2/2] DSH is running again
echo.
echo ============================================================
echo  DONE
echo ============================================================
exit /b 0

:USAGE
echo.
echo DSH Tools
echo.
echo   dsh-tools.bat status
echo   dsh-tools.bat restart [--delay=N]
echo   dsh-tools.bat update ^<pkg^>@^<version^> [more...] [--delay=N]
echo.
echo env: DSH_PROFILE (default desktop), DSH_DELAY (default 15), DSH_EXE
echo.
echo This script kills DSH, so it must NOT run as a child of DSH.
echo Use: powershell -ExecutionPolicy Bypass -File launch-detached.ps1 ^<args^>
echo.
exit /b 0
