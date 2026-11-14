@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Insiders\VC\Auxiliary\Build\vcvars64.bat" >nul
cl /nologo /EHsc /O2 /MT lagprobe.cpp /Fe:lagprobe.exe /link d3d11.lib dxgi.lib user32.lib
