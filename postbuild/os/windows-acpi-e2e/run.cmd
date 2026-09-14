@echo off
setlocal EnableExtensions
set ROOT=C:\odp-e2e
set LOG=%ROOT%\thermal.log
set FAILURE=invalid Windows ACPI E2E service selection
set "COMMAND_EXIT="
del /f /q "%ROOT%\result.txt" "%ROOT%\thermal.log" "%ROOT%\ucsi.log" >nul 2>&1
if not "%~2"=="" goto fail
if "%~1"=="ucsi" goto ucsi
if "%~1"=="" goto thermal
if not "%~1"=="thermal" goto fail

:thermal
set FAILURE=ec-test-cli declarative thermal test failed
C:\ectest\ec-test-cli.exe --source acpi script run "%ROOT%\thermal.test" > "%ROOT%\thermal.log" 2>&1
set "COMMAND_EXIT=%ERRORLEVEL%"
if not "%COMMAND_EXIT%"=="0" goto fail
goto pass

:ucsi
set LOG=%ROOT%\ucsi.log
set FAILURE=UCSI smoke test failed
"%ROOT%\smoke.exe" > "%LOG%" 2>&1
set "COMMAND_EXIT=%ERRORLEVEL%"
if not "%COMMAND_EXIT%"=="0" goto fail

:pass
> "%ROOT%\result.txt" echo PASS: Windows ACPI E2E
goto shutdown

:fail
>> "%LOG%" echo FAIL: %FAILURE%
if defined COMMAND_EXIT >> "%LOG%" echo Exit code: %COMMAND_EXIT%
> "%ROOT%\result.txt" echo FAIL: Windows ACPI E2E

:shutdown
shutdown /s /f /t 0
