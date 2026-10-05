@echo off
rem build_shim.bat — compile les objets shim K3-gallery (kx_skia platform
rem Windows + kx_scenes/kx_draw canoniques) → obj\*.obj (/MT, C++20).
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set KX=%~dp0..\..\..
set SKIA=%KX%\deps\skia
set OUT=%SKIA%\out\K0
set SHIM=%KX%\spikes\k3-gallery\shim
set OBJ=%KX%\spikes\k3-gallery\obj
mkdir %OBJ% 2>nul

set INC=/I%SHIM% /I%SKIA% /I%SKIA%\third_party\externals\dawn\include /I%OUT%\gen\third_party\dawn\include
set DEF=/DNDEBUG /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS /DNOMINMAX /DWIN32_LEAN_AND_MEAN /DSK_GANESH /DSK_GRAPHITE /DSK_CODEC_DECODES_BMP /DSK_CODEC_DECODES_WBMP /DSK_ASSUME_GL=1

for %%F in (kx_skia kx_scenes kx_draw) do (
  cl /nologo /std:c++20 /EHsc /O2 /MT /bigobj /W3 %DEF% %INC% ^
    /c %SHIM%\%%F.cpp /Fo%OBJ%\%%F.obj || exit /b 1
)

rem kx_a11y_win : PAS de WIN32_LEAN_AND_MEAN — UIAutomationCore.h a besoin
rem des types ole2 complets (IAccessible, IRawElementProvider*).
set DEFA11Y=/DNDEBUG /D_CRT_SECURE_NO_WARNINGS /D_CRT_NONSTDC_NO_WARNINGS
cl /nologo /std:c++20 /EHsc /O2 /MT /bigobj /W3 %DEFA11Y% ^
  /c %SHIM%\kx_a11y_win.cpp /Fo%OBJ%\kx_a11y_win.obj || exit /b 1

rem Client de vérification UIA (hors shim) : dump l'arbre depuis le HWND.
if exist %SHIM%\..\uia\uia_dump.cpp (
  cl /nologo /std:c++20 /EHsc /O2 /MT %DEFA11Y% ^
    /Fe:%KX%\spikes\k3-gallery\build\uia_dump.exe ^
    /Fo%OBJ%\uia_dump.obj %SHIM%\..\uia\uia_dump.cpp ^
    /link ole32.lib oleaut32.lib uiautomationcore.lib user32.lib || exit /b 1
)
endlocal
