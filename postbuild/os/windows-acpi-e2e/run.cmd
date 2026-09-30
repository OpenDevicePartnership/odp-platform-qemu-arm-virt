@echo off
setlocal EnableExtensions
set ROOT=C:\odp-e2e
set SERVICE=thermal
set FAILURE=invalid Windows ACPI E2E service selection
set "COMMAND_EXIT="
del /f /q "%ROOT%\result.txt" "%ROOT%\thermal.log" "%ROOT%\ucsi.log" "%ROOT%\battery.log" "%ROOT%\rtc.log" >nul 2>&1
if not "%~2"=="" goto fail
if "%~1"=="ucsi" goto ucsi
if "%~1"=="battery" set SERVICE=battery
if "%~1"=="rtc" set SERVICE=rtc
if not "%~1"=="" if not "%~1"=="%SERVICE%" goto fail

set FAILURE=ec-test-cli declarative %SERVICE% test failed
C:\ectest\ec-test-cli.exe --source acpi script run "%ROOT%\%SERVICE%.test" > "%ROOT%\%SERVICE%.log" 2>&1
goto check

:ucsi
set SERVICE=ucsi
set FAILURE=UCSI smoke test failed
"%ROOT%\smoke.exe" > "%ROOT%\%SERVICE%.log" 2>&1

:check
set "COMMAND_EXIT=%ERRORLEVEL%"
if not "%COMMAND_EXIT%"=="0" goto fail

> "%ROOT%\result.txt" echo PASS: Windows ACPI E2E
goto shutdown

:fail
>> "%ROOT%\%SERVICE%.log" echo FAIL: %FAILURE%
if defined COMMAND_EXIT >> "%ROOT%\%SERVICE%.log" echo Exit code: %COMMAND_EXIT%
> "%ROOT%\result.txt" echo FAIL: Windows ACPI E2E

:shutdown
shutdown /s /f /t 0
