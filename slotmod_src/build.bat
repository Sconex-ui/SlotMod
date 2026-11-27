@echo off
rem Builds SlotMod.exe and slotmod.dll into ..\SlotMod (needs Visual Studio 2022 with C++ x64 tools)
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul
where cl >nul 2>nul || (echo cl.exe not found. Run this from an "x64 Native Tools Command Prompt for VS" or install VS 2022 with "Desktop development with C++". & exit /b 1)
cd /d "%~dp0"
if not exist ..\SlotMod mkdir ..\SlotMod
cl /nologo /O2 /LD /MT slotmod.c /Fe:..\SlotMod\slotmod.dll /link kernel32.lib user32.lib || exit /b 1
cl /nologo /O2 /MT injector.c /Fe:..\SlotMod\SlotMod.exe /link /SUBSYSTEM:WINDOWS kernel32.lib user32.lib shell32.lib || exit /b 1
del /q *.obj ..\SlotMod\*.exp ..\SlotMod\*.lib 2>nul
echo Built ..\SlotMod\SlotMod.exe and ..\SlotMod\slotmod.dll
