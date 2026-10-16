!include "MUI2.nsh"
!include "WordFunc.nsh"

!ifndef APP_VERSION
  !define APP_VERSION "0.7.3"
!endif
!ifndef BUILD_DIR
  !define BUILD_DIR "..\..\build\windows\x64\runner\Release"
!endif
!ifndef OUT_FILE
  !define OUT_FILE "..\..\GlassUsage_${APP_VERSION}_x64-setup.exe"
!endif

Name "GlassUsage ${APP_VERSION}"
OutFile "${OUT_FILE}"
Unicode True
InstallDir "$LOCALAPPDATA\Programs\GlassUsage"
InstallDirRegKey HKCU "Software\GlassUsage" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ICON "..\runner\resources\app_icon.ico"
!define MUI_UNICON "..\runner\resources\app_icon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\glassusage.exe"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  ; Preserve existing install directory from legacy 0.6.x or previous 0.7.x install
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "InstallLocation"
  StrCmp $0 "" check_cmdline
  ; Strip surrounding double quotes if present (e.g. "C:\App\GlassUsage")
  StrCpy $1 $0 1
  StrCmp $1 '"' 0 apply_dir
  StrCpy $0 $0 "" 1
  StrCpy $1 $0 1 -1
  StrCmp $1 '"' 0 apply_dir
  StrCpy $0 $0 -1
  apply_dir:
  StrCmp $0 "" check_cmdline
  StrCpy $INSTDIR $0

  check_cmdline:
  ; Support /P (passive mode used by Tauri updater and in-app updater)
  ${WordFind} "$CMDLINE" "/P" "E+1{" $R0
  IfErrors 0 set_passive
  ${WordFind} "$CMDLINE" "/passive" "E+1{" $R0
  IfErrors 0 set_passive
  Goto done_init
  set_passive:
  SetSilent silent
  done_init:
FunctionEnd

Section "GlassUsage" SecMain
  SectionIn RO
  SetOutPath "$INSTDIR"

  ; Give exiting instance a moment to close, then ensure glassusage.exe is stopped
  Sleep 500
  nsExec::ExecToLog 'taskkill /F /IM glassusage.exe'
  Sleep 400

  File /r "${BUILD_DIR}\*.*"

  WriteRegStr HKCU "Software\GlassUsage" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Start Menu & Desktop Shortcuts
  CreateDirectory "$SMPROGRAMS\GlassUsage"
  CreateShortcut "$SMPROGRAMS\GlassUsage\GlassUsage.lnk" "$INSTDIR\glassusage.exe" "" "$INSTDIR\glassusage.exe" 0
  CreateShortcut "$SMPROGRAMS\GlassUsage\Uninstall GlassUsage.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\GlassUsage.lnk" "$INSTDIR\glassusage.exe" "" "$INSTDIR\glassusage.exe" 0

  ; Windows Add/Remove Programs Registration
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "DisplayName" "GlassUsage"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "MainBinaryName" "glassusage.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "Publisher" "GlassUsage"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "DisplayIcon" "$INSTDIR\glassusage.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage" "NoRepair" 1
SectionEnd

Function .onInstSuccess
  ; When invoked via in-app updater (/P or /S), automatically relaunch GlassUsage
  IfSilent 0 +2
  Exec '"$INSTDIR\glassusage.exe"'
FunctionEnd

Section "Uninstall"
  nsExec::ExecToLog 'taskkill /F /IM glassusage.exe'

  Delete "$DESKTOP\GlassUsage.lnk"
  Delete "$SMPROGRAMS\GlassUsage\GlassUsage.lnk"
  Delete "$SMPROGRAMS\GlassUsage\Uninstall GlassUsage.lnk"
  RMDir "$SMPROGRAMS\GlassUsage"

  ; Remove application binaries only; preserve %APPDATA%\com.glassusage.app user database & settings
  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\*.dll"
  Delete "$INSTDIR\glassusage.exe"
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GlassUsage"
  DeleteRegKey HKCU "Software\GlassUsage"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "GlassUsage"
SectionEnd
