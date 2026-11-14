@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /std:c++17 /EHsc /O2 /MT native_comp_probe.cpp /Fe:native_comp_probe.exe /link d3d11.lib dxgi.lib dcomp.lib user32.lib gdi32.lib ole32.lib
