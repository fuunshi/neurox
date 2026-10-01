@echo off
rem ---------------------------------------------------------------------------
rem `make up` on Windows, for anyone whose fingers already know it.
rem
rem This is a two-line forwarding shim: everything it can do lives in
rem neurox.ps1 beside it, which is the file to read and the file to edit. It
rem exists so that the README's `make up` is not a lie on Windows, and so that
rem cmd.exe users do not have to know PowerShell is involved.
rem
rem -ExecutionPolicy Bypass is here because the default policy on a stock
rem Windows machine refuses to run an unsigned .ps1, and "the script I cloned
rem from my own repository" is not a thing to make somebody configure first.
rem It applies to this one invocation; nothing about the machine is changed.
rem ---------------------------------------------------------------------------

setlocal

rem Prefer PowerShell 7 when it is here -- it is faster and its console output is
rem better -- and fall back to the Windows PowerShell that is always present.
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0neurox.ps1" %*
exit /b %ERRORLEVEL%
