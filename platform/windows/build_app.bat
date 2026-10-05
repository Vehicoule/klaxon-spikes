@echo off
rem build_app.bat — K3-gallery Windows : link Zig 0.17 (gallery/main.zig +
rem module klaxon canonique) vers objets shim /MT + libs Skia/Dawn + SDL3.
rem Stage toutes les DLLs runtime dans build\.
setlocal
set KX=%~dp0..\..\..
set SKIA=%KX%\deps\skia
set OUT=%SKIA%\out\K0
set APP=%KX%\spikes\k3-gallery
set K0=%KX%\spikes\k0-windows
set ZIG=%KX%\tools\zig\zig-x86_64-windows-0.17.0\zig.exe
set VCLIB=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\lib\x64
set UCRT=C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64
set SDLDIR=%KX%\deps\sdl3\SDL3-3.2.16
set MB=%APP%\build\msvclibs
set BIN=%APP%\build

rem .lib copies (zig refuse les extensions .Lib majuscules)
mkdir %MB% 2>nul
for %%L in (opengl32 gdi32 user32 kernel32 dxguid advapi32 ole32 oleaut32 dwmapi UIAutomationCore) do copy /y "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64\%%L.lib" %MB%\ >nul
copy /y "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64\OneCore.Lib" %MB%\onecore.lib >nul
copy /y "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64\WS2_32.Lib" %MB%\ws2_32.lib >nul
copy /y "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64\Uuid.Lib" %MB%\uuid.lib >nul
copy /y "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64\dxva2.lib" %MB%\ >nul 2>nul
copy /y "%VCLIB%\delayimp.lib" %MB%\ >nul

rem DLLs runtime : SDL3 + Dawn D3D12 (dxc/dxil) + Vulkan (loader+ICDs) + Mesa GL
copy /y %SDLDIR%\lib\x64\SDL3.dll %BIN%\ >nul
for %%D in (dxcompiler.dll dxil.dll vulkan-1.dll vulkan_lvp.dll vk_swiftshader.dll vulkan_dzn.dll opengl32.dll libgallium_wgl.dll lvp_icd.x86_64.json icudtl.dat) do copy /y %K0%\build\%%D %BIN%\ >nul 2>nul

cd /d %APP%
%ZIG% build-exe -O ReleaseFast -target x86_64-windows-msvc -lc ^
  --dep klaxon -Mroot=gallery\main.zig -Mklaxon=klaxon\src\klaxon.zig ^
  --name gallery-windows -femit-bin=%BIN%\gallery-windows.exe ^
  obj\kx_skia.obj obj\kx_scenes.obj obj\kx_draw.obj obj\kx_a11y_win.obj ^
  %OUT%\skia.lib %OUT%\skparagraph.lib %OUT%\skshaper.lib ^
  %OUT%\skunicode_icu.lib %OUT%\skunicode_core.lib %OUT%\bentleyottmann.lib ^
  %OUT%\harfbuzz.lib %OUT%\icu.lib %OUT%\freetype2.lib %OUT%\libpng.lib ^
  %OUT%\zlib.lib %OUT%\skcms.lib %OUT%\dawn_combined.lib ^
  %SDLDIR%\lib\x64\SDL3.lib ^
  "%VCLIB%\libcmt.lib" "%VCLIB%\libvcruntime.lib" "%VCLIB%\libcpmt.lib" "%UCRT%\libucrt.lib" ^
  %MB%\opengl32.lib %MB%\gdi32.lib %MB%\user32.lib %MB%\kernel32.lib %MB%\delayimp.lib ^
  %MB%\dxguid.lib %MB%\onecore.lib %MB%\ws2_32.lib %MB%\advapi32.lib %MB%\ole32.lib %MB%\oleaut32.lib %MB%\uuid.lib %MB%\dwmapi.lib %MB%\UIAutomationCore.lib
if errorlevel 1 exit /b 1
endlocal
