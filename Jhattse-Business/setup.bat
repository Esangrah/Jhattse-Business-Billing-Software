@echo off
SETLOCAL

:: BatchGotAdmin
::-------------------------------------
REM  --> Check for permissions
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"

REM --> If error flag set, we do not have admin.
if errorlevel 1 (
    echo Requesting administrative privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    set "params=%*"
    if defined params set "params=%params:"=""%"
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "cmd.exe", "/c ""%~f0"" %params%", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    del "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    pushd "%CD%"
    CD /D "%~dp0"
::--------------------------------------


:: Set paths for the installer files and target directories
SET "MSI_PATH=Jhattse-Business_2.5.35_x64_en-US.msi"
SET "EXE_PATH=template-server.exe"
SET "PDF_EXE_PATH=SumatraPDF-3.6.1-32.exe"
SET "NSSM_PATH=nssm.exe"
SET "ServiceName=TemplateServer"
:: Modify INSTALL_DIR as per the installation directory
SET "INSTALL_DIR=C:\Program Files\Jhattse-Business"
SET "RESULT=0"


echo.
echo  ============================================
echo   Jhattse Business - Setup
echo  ============================================
echo.

:: Check all installer files are present before touching anything
for %%F in ("%MSI_PATH%" "%EXE_PATH%" "%PDF_EXE_PATH%" "%NSSM_PATH%") do (
    if not exist "%%~F" (
        echo  [!!] Missing file: %%~F
        goto fail
    )
)

:: ── Step 1: Unblock all files (removes Mark-of-the-Web / SmartScreen flag) ───
echo  [1/8] Unblocking installer files...
powershell -Command "Get-ChildItem -Path '%~dp0' -Recurse | Unblock-File" >nul 2>&1
if errorlevel 1 (
    echo  [!!] Could not unblock files, continuing anyway...
) else (
    echo  [OK] Files unblocked
)
echo.

:: ── Step 2: Add Defender exclusion for install folder + Program Files dir ───
echo  [2/8] Adding Windows Defender exclusions...
powershell -Command "Add-MpPreference -ExclusionPath '%~dp0'" >nul 2>&1
powershell -Command "Add-MpPreference -ExclusionPath '%INSTALL_DIR%'" >nul 2>&1
powershell -Command "Add-MpPreference -ExclusionProcess 'template-server.exe'" >nul 2>&1
echo  [OK] Exclusions added
echo.

:: ── Step 3: Disable SmartScreen temporarily ──────────────────────────────────
echo  [3/8] Configuring SmartScreen...
powershell -Command "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -Value 'Off'" >nul 2>&1
echo  [OK] SmartScreen configured
echo.

:: ── Step 4: Remove old service FIRST (releases locks on nssm.exe / template-server.exe)
echo  [4/8] Removing old %ServiceName% service (if any)...
sc query %ServiceName% >nul 2>&1
if not errorlevel 1 (
    REM Stop the service if it's running, then delete it
    net stop %ServiceName% >nul 2>&1
    sc delete %ServiceName% >nul 2>&1
)
taskkill /F /IM template-server.exe >nul 2>&1
:: Wait until the service is really gone (up to ~10s)
set /a TRIES=0
:waitdelete
sc query %ServiceName% >nul 2>&1
if errorlevel 1 goto deleted
set /a TRIES+=1
if %TRIES% GEQ 10 (
    echo  [!!] Old service is still marked for deletion. Close Services window / reboot and retry.
    goto fail
)
timeout /t 1 >nul
goto waitdelete
:deleted
echo  [OK] Old service removed
echo.

:: ── Step 5: Install Jhattse-Business.msi (creates INSTALL_DIR) ───────────────
echo  [5/8] Installing Jhattse-Business.msi...
msiexec /i "%MSI_PATH%" /norestart
set "MSI_RC=%ERRORLEVEL%"
REM 3010 / 1641 = success, reboot required
if "%MSI_RC%"=="3010" set "MSI_RC=0"
if "%MSI_RC%"=="1641" set "MSI_RC=0"
if not "%MSI_RC%"=="0" (
    echo  [!!] MSI install failed, exit code %MSI_RC%
    goto fail
)
echo  [OK] MSI installed
echo.

:: ── Step 6: Copy nssm.exe, template-server.exe, SumatraPDF (folder now exists)
echo  [6/8] Copying nssm, template-server and SumatraPDF...
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"
copy /Y "%NSSM_PATH%" "%INSTALL_DIR%\nssm.exe" >nul
if errorlevel 1 ( echo  [!!] Failed to copy nssm.exe & goto fail )
copy /Y "%EXE_PATH%" "%INSTALL_DIR%\template-server.exe" >nul
if errorlevel 1 ( echo  [!!] Failed to copy template-server.exe & goto fail )
copy /Y "%PDF_EXE_PATH%" "%INSTALL_DIR%\SumatraPDF-3.4.6-32.exe" >nul
if errorlevel 1 ( echo  [!!] Failed to copy SumatraPDF & goto fail )
echo  [OK] Files copied
echo.

:: ── Step 7: Register template-server.exe as a service using nssm ────────────
echo  [7/8] Registering %ServiceName% service...
"%INSTALL_DIR%\nssm.exe" install %ServiceName% "%INSTALL_DIR%\template-server.exe"
if errorlevel 1 ( echo  [!!] Failed to register service & goto fail )
"%INSTALL_DIR%\nssm.exe" set %ServiceName% AppDirectory "%INSTALL_DIR%" >nul
"%INSTALL_DIR%\nssm.exe" set %ServiceName% Start SERVICE_AUTO_START >nul
echo  [OK] Service registered
echo.

:: ── Step 8: Start the service ────────────────────────────────────────────────
echo  [8/8] Starting %ServiceName% service...
net start %ServiceName%
if errorlevel 1 ( echo  [!!] Failed to start service & goto fail )
echo  [OK] Service started
goto cleanup

:fail
set "RESULT=1"

:: ── Cleanup ───────────────────────────────────────────────────────────────────
:cleanup
echo.
echo  Restoring security settings...
powershell -Command "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' -Name SmartScreenEnabled -Value 'Prompt'" >nul 2>&1
powershell -Command "Remove-MpPreference -ExclusionPath '%~dp0'" >nul 2>&1
echo  [OK] Security settings restored
echo.

if "%RESULT%"=="0" (
    echo  ============================================
    echo   [SUCCESS] Installation complete!
    echo   Jhattse Business is ready to use
    echo  ============================================
) else (
    echo  ============================================
    echo   [FAILED] Installation did not complete
    echo   See the [!!] message above / contact support
    echo  ============================================
)

pause
ENDLOCAL & exit /b %RESULT%
