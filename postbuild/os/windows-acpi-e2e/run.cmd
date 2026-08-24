@echo off
setlocal EnableExtensions
set ROOT=C:\odp-e2e
del /f /q "%ROOT%\result.txt" "%ROOT%\thermal.log" >nul 2>&1

C:\ectest\ec-test-cli.exe --source acpi script run "%ROOT%\thermal.test" > "%ROOT%\thermal.log" 2>&1
if errorlevel 1 goto fail

> "%ROOT%\result.txt" echo PASS: Windows ACPI E2E
goto shutdown

:fail
>> "%ROOT%\thermal.log" echo FAIL: ec-test-cli declarative thermal test failed
> "%ROOT%\result.txt" echo FAIL: Windows ACPI E2E

:shutdown
shutdown /s /f /t 0
