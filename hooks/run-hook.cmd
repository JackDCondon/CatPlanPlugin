@echo off
setlocal enabledelayedexpansion

set "bash_path="
for /f "delims=" %%i in ('where bash 2^>nul') do (
    set "bash_path=%%i"
    "!bash_path!" --version >nul 2>&1 && goto :found
)

if exist "%PROGRAMFILES%\Git\usr\bin\bash.exe" (
    set "bash_path=%PROGRAMFILES%\Git\usr\bin\bash.exe"
    goto :found
)
if exist "%PROGRAMFILES%\Git\bin\bash.exe" (
    set "bash_path=%PROGRAMFILES%\Git\bin\bash.exe"
    goto :found
)
if exist "C:\Program Files\Git\usr\bin\bash.exe" (
    set "bash_path=C:\Program Files\Git\usr\bin\bash.exe"
    goto :found
)
if exist "C:\Program Files\Git\bin\bash.exe" (
    set "bash_path=C:\Program Files\Git\bin\bash.exe"
    goto :found
)
if exist "C:\msys64\usr\bin\bash.exe" (
    set "bash_path=C:\msys64\usr\bin\bash.exe"
    goto :found
)

echo Error: bash not found
exit /b 1

:found
set "hook=%~1"
set "hook_dir=%~dp0"

if not exist "%hook_dir%%hook%" (
    echo Error: hook not found: %hook%
    exit /b 42
)

set "hook_args="
:parse_args
shift
if "%~1"=="" goto :run_hook
set hook_args=!hook_args! %1
goto :parse_args

:run_hook
cmd /c ""!bash_path!" "%hook_dir%!hook!"!hook_args!"
exit /b %errorlevel%
