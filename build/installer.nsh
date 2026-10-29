; REQ-ENR-4: the Windows installer installs the Heimdall App, the Bridge, or both.
;
; electron-builder includes this file in the installer and the uninstaller build
; (BUILD_UNINSTALLER). Its NSIS runs with -WX, so everything only the installer
; uses stays behind !ifndef BUILD_UNINSTALLER, and pages/functions are defined
; inside the hook macros, where MUI2 is already included.
;
; The Bridge component runs the bundled bootstrap (resources\bridge\install.ps1),
; which verifies the bundled archive against SHA256SUMS and execs
; `ham-bridge setup` without --headless, so ham-bridge opens the approval page.
; "Bridge only" then removes the app files again: ham-bridge setup has copied
; what the Bridge needs into its own profile, and the Bridge's tray owns its
; uninstall (REQ-ENR-6).
;
; The Bridge is a per-user service, so setup must run as the signed-in user.
; When the user picks "Anyone who uses this computer", the sections run in the
; elevated inner UAC instance (possibly as another account that supplied admin
; credentials); there, setup is handed back to the outer, non-elevated instance
; with UAC_AsUser_Call, the way electron-builder starts the app as the user.
;
; Silent installs: /COMPONENTS=app|bridge|both (default app, so an unattended
; install never waits on a browser approval) and /HUB=<url>. App auto-updates
; (--updated) never touch the Bridge; it updates itself (ham-bridge update).

!ifndef BUILD_UNINSTALLER
  !include LogicLib.nsh
  !include FileFunc.nsh
  !include nsDialogs.nsh

  Var HeimdallComponents
  Var HeimdallHub
  Var HeimdallRadioBoth
  Var HeimdallRadioApp
  Var HeimdallRadioBridge

  !define HEIMDALL_DEFAULT_HUB "https://hub.brolabs.ai"
!endif

!macro customInit
  StrCpy $HeimdallComponents "both"
  ${If} ${Silent}
    StrCpy $HeimdallComponents "app"
  ${EndIf}
  StrCpy $HeimdallHub "${HEIMDALL_DEFAULT_HUB}"
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/COMPONENTS=" $R1
  ${IfNot} ${Errors}
    ${If} $R1 == "app"
    ${OrIf} $R1 == "bridge"
    ${OrIf} $R1 == "both"
      StrCpy $HeimdallComponents $R1
    ${Else}
      MessageBox MB_ICONSTOP|MB_OK "/COMPONENTS must be app, bridge or both (got $R1)." /SD IDOK
      Quit
    ${EndIf}
  ${EndIf}
  ClearErrors
  ${GetOptions} $R0 "/HUB=" $R1
  ${IfNot} ${Errors}
  ${AndIf} $R1 != ""
    StrCpy $HeimdallHub $R1
  ${EndIf}
!macroend

!macro customPageAfterChangeDir
  Page custom HeimdallComponentsPage HeimdallComponentsLeave

  Function HeimdallComponentsPage
    ; An update keeps whatever was installed; there is nothing to choose.
    ${If} ${isUpdated}
      Abort
    ${EndIf}
    !insertmacro MUI_HEADER_TEXT "Choose what to install" "Install the Heimdall app, the Heimdall Bridge, or both."
    nsDialogs::Create 1018
    Pop $0
    ${If} $0 == error
      Abort
    ${EndIf}
    ${NSD_CreateLabel} 0 0 100% 36u "The App is the Heimdall desktop window. The Bridge connects this computer to your Heimdall Hub so agents can run here; setting it up opens your browser to approve this computer."
    Pop $0
    ${NSD_CreateRadioButton} 0 42u 100% 12u "App and Bridge (recommended)"
    Pop $HeimdallRadioBoth
    ${NSD_CreateRadioButton} 0 58u 100% 12u "App only"
    Pop $HeimdallRadioApp
    ${NSD_CreateRadioButton} 0 74u 100% 12u "Bridge only"
    Pop $HeimdallRadioBridge
    ${If} $HeimdallComponents == "app"
      ${NSD_Check} $HeimdallRadioApp
    ${ElseIf} $HeimdallComponents == "bridge"
      ${NSD_Check} $HeimdallRadioBridge
    ${Else}
      ${NSD_Check} $HeimdallRadioBoth
    ${EndIf}
    nsDialogs::Show
  FunctionEnd

  Function HeimdallComponentsLeave
    ${NSD_GetState} $HeimdallRadioApp $0
    ${NSD_GetState} $HeimdallRadioBridge $1
    ${If} $0 == ${BST_CHECKED}
      StrCpy $HeimdallComponents "app"
    ${ElseIf} $1 == ${BST_CHECKED}
      StrCpy $HeimdallComponents "bridge"
    ${Else}
      StrCpy $HeimdallComponents "both"
    ${EndIf}
  FunctionEnd

  ; Runs in the outer, non-elevated installer instance (UAC_AsUser_Call from the
  ; elevated inner one). In: $1 = hub URL, $INSTDIR synced. Out: $0 = exit code.
  ; The outer instance has no log window, so setup runs in its own console.
  Function HeimdallBridgeSetupAsUser
    ClearErrors
    ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\resources\bridge\install.ps1" -Bundle "$INSTDIR\resources\bridge\heimdall-local-windows-amd64.zip" -ChecksumFile "$INSTDIR\resources\bridge\SHA256SUMS" -Hub "$1" -Interactive' $0
    ${If} ${Errors}
      StrCpy $0 "error"
    ${EndIf}
  FunctionEnd
!macroend

; Same as electron-builder's default finish page, except that "Run Heimdall" is
; hidden and skipped when only the Bridge was installed (there is no app).
!macro customFinishPage
  !define MUI_FINISHPAGE_RUN
  !define MUI_FINISHPAGE_RUN_FUNCTION "HeimdallStartApp"
  !define MUI_PAGE_CUSTOMFUNCTION_SHOW HeimdallFinishShow
  !insertmacro MUI_PAGE_FINISH

  ; After MUI_PAGE_FINISH, which declares $mui.FinishPage.Run. Mirrors
  ; electron-builder's own finish-page StartApp function: its StartApp macro
  ; declares Var /GLOBAL startAppArgs and installSection.nsh already inserts it
  ; (doStartApp), so inserting it here too fails makensis with
  ; 'variable "startAppArgs" already declared'.
  Function HeimdallStartApp
    ${If} $HeimdallComponents != "bridge"
      ${If} ${isUpdated}
        StrCpy $1 "--updated"
      ${Else}
        StrCpy $1 ""
      ${EndIf}
      ${StdUtils.ExecShellAsUser} $0 "$launchLink" "open" "$1"
    ${EndIf}
  FunctionEnd

  Function HeimdallFinishShow
    ${If} $HeimdallComponents == "bridge"
      ShowWindow $mui.FinishPage.Run ${SW_HIDE}
    ${EndIf}
  FunctionEnd
!macroend

!macro customInstall
  ${IfNot} ${isUpdated}
  ${AndIf} $HeimdallComponents != "app"
    DetailPrint "Setting up the Heimdall Bridge for $HeimdallHub (approve this computer in your browser)..."
    SetDetailsPrint both
    ${If} ${UAC_IsInnerInstance}
      ; Elevated per-machine install: never set the Bridge up as the admin.
      DetailPrint "Running Bridge setup as the signed-in user in a separate window..."
      Push $1
      StrCpy $1 $HeimdallHub
      StrCpy $0 "not run"
      !insertmacro UAC_AsUser_Call Function HeimdallBridgeSetupAsUser ${UAC_SYNCREGISTERS}|${UAC_SYNCINSTDIR}
      Pop $1
    ${Else}
      nsExec::ExecToLog '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\resources\bridge\install.ps1" -Bundle "$INSTDIR\resources\bridge\heimdall-local-windows-amd64.zip" -ChecksumFile "$INSTDIR\resources\bridge\SHA256SUMS" -Hub "$HeimdallHub" -Interactive'
      Pop $0
    ${EndIf}
    ${If} $0 != 0
      ${If} $HeimdallComponents == "bridge"
        ; Nothing usable was installed: leave no app behind and fail the install.
        ExecWait '"$INSTDIR\${UNINSTALL_FILENAME}" /S _?=$INSTDIR'
        Delete "$INSTDIR\${UNINSTALL_FILENAME}"
        RMDir /r "$INSTDIR"
        MessageBox MB_ICONSTOP|MB_OK "Heimdall Bridge setup failed (exit code $0); nothing was installed. Run the installer again, or set up the Bridge later from the Heimdall app." /SD IDOK
        SetErrorLevel 2
        Quit
      ${EndIf}
      MessageBox MB_ICONEXCLAMATION|MB_OK "Heimdall Bridge setup failed (exit code $0). The app is installed; finish the Bridge from Settings > Bridges." /SD IDOK
    ${ElseIf} $HeimdallComponents == "bridge"
      DetailPrint "Bridge only: removing the Heimdall app files."
      ExecWait '"$INSTDIR\${UNINSTALL_FILENAME}" /S _?=$INSTDIR'
      Delete "$INSTDIR\${UNINSTALL_FILENAME}"
      RMDir /r "$INSTDIR"
    ${EndIf}
  ${EndIf}
!macroend
