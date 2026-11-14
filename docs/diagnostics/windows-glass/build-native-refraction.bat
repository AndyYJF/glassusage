@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /std:c++17 /EHsc /O2 /MT /DNATIVE_REFRACTION /I "C:\Users\AndyYan\Desktop\codex\glassusage\windows\flutter\ephemeral" flutter_bridge_probe.cpp /Fe:native_refraction_probe.exe /link /MANIFEST:EMBED /MANIFESTINPUT:flutter_bridge_probe.manifest d3d11.lib dxgi.lib dcomp.lib dwmapi.lib d3dcompiler.lib user32.lib gdi32.lib ole32.lib
if errorlevel 1 exit /b %errorlevel%
cl /nologo /EHsc /O2 /MT /DNATIVE_REFRACTION lagprobe.cpp /Fe:lagprobe_refraction.exe /link d3d11.lib dxgi.lib user32.lib
