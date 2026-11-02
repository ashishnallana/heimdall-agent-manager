; The Windows installer installs the Ninjy app only. Bridge discovery,
; installation, profile selection and approval belong to the in-app setup wizard.
; Keep legacy Bridge-component requests from silently installing something else.
!ifndef BUILD_UNINSTALLER
  !include LogicLib.nsh
  !include FileFunc.nsh

  !macro customInit
    ${GetParameters} $R0
    ClearErrors
    ${GetOptions} $R0 "/COMPONENTS=" $R1
    ${IfNot} ${Errors}
      ${If} $R1 != "app"
        MessageBox MB_ICONSTOP|MB_OK "This installer installs the Ninjy app only. Install the app without /COMPONENTS, then set up the Bridge in Ninjy's setup wizard." /SD IDOK
        SetErrorLevel 2
        Quit
      ${EndIf}
    ${EndIf}
    ClearErrors
    ${GetOptions} $R0 "/HUB=" $R1
    ${IfNot} ${Errors}
      MessageBox MB_ICONSTOP|MB_OK "Bridge Hub selection has moved to Ninjy's setup wizard. Install the app without /HUB, then set up the Bridge in Ninjy." /SD IDOK
      SetErrorLevel 2
      Quit
    ${EndIf}
  !macroend
!endif
