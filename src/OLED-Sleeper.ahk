#SingleInstance force
#Requires AutoHotkey v2.0

;===============================================================================
; OLED Sleeper
;
; Description:
;   Prevents OLED burn-in by monitoring activity per screen.
;   Now supports independent monitor sleeping and advanced activity rules.
;
; Dependencies:
;   - ControlMyMonitor.exe (located in the ..\tools directory)
;   - MultiMonitorTool.exe (located in the ..\tools directory)
;
; Usage:
;   Run the script with two arguments:
;   1. Monitor list (e.g. "\\.\DISPLAY2:blackout;\\.\DISPLAY3:dim:15")
;   2. Idle threshold in milliseconds (e.g. 30000)
;===============================================================================

; ==============================================================================
; GLOBAL SETTINGS
; ==============================================================================
global PrimaryMonitorBlackout           := 1  ; 1 = Allow primary to sleep, 0 = Primary always stays on
global SleepRegardlessOfOutsideActivity := 1  ; 1 = Monitor sleeps if IT is idle, even if you type on another screen
                                              ; 0 = If you are active ANYWHERE, ALL monitors stay awake
global KeepActiveIfCursorPresent        := 0  ; 1 = Monitor won't sleep if cursor is hovering (even if not moving)
                                              ; 0 = Monitor sleeps if cursor is static (unless moving)

; ==============================================================================
; PATH DEFINITIONS
; ==============================================================================
global ProjectRoot := A_ScriptDir . "\.."
global LogFile     := ProjectRoot . "\OLED-Sleeper.log"
global MultiTool   := ProjectRoot . "\tools\MultiMonitorTool\MultiMonitorTool.exe"
global ControlTool := ProjectRoot . "\tools\ControlMyMonitor\ControlMyMonitor.exe"
global TempCsvFile := ProjectRoot . "\monitors_sleeper_temp.csv"
global RestoreFile := ProjectRoot . "\config\sleeper_restore.dat"

; ==============================================================================
; INTERNAL STATE
; ==============================================================================
global MonitorConfigList := ""
global IdleThreshold     := 0
global CheckInterval     := 200
global CursorHidden      := false
global MonitoredScreens  := []


; ==============================================================================
; LOGGING
; ==============================================================================
Log(message) {
    global LogFile
    try FileAppend(Format("{1} - {2}`n", A_Now, message), LogFile)
}

; ==============================================================================
; INITIALIZATION
; ==============================================================================
Log("--- Script started ---")

; --- Restore Brightness from Previous Session ---
if FileExist(RestoreFile) {
    Log("Restore file found. Restoring brightness.")
    try {
        loop read RestoreFile {
            parts := StrSplit(A_LoopReadLine, ":")
            if (parts.Length = 2) {
                SetBrightness(parts[1], Integer(parts[2]))
            }
        }
        FileDelete(RestoreFile)
    } catch {
        Log("ERROR: Failed to process restore file.")
    }
}

; --- Argument Parsing ---
if A_Args.Length < 2 {
    MsgBox("Requires 2 arguments:`n1. Config List`n2. Idle Timeout (ms)", "Error", 48)
    ExitApp
}

MonitorConfigList := A_Args[1]
IdleThreshold := Integer(A_Args[2])

Log("Config: " . MonitorConfigList)
Log("Threshold: " . IdleThreshold)
Log("Settings: PrimaryBlackout=" . PrimaryMonitorBlackout . ", IndependentSleep=" . SleepRegardlessOfOutsideActivity . ", KeepActiveCursor=" . KeepActiveIfCursorPresent)

OnExit(CleanupOnExit)

; --- Monitor Setup ---
primaryRect := GetPrimaryRect()

for config in StrSplit(MonitorConfigList, ";") {
    parts := StrSplit(config, ":")
    id := Trim(parts[1])
    if id = ""
        continue

    monitorRect := GetMonitorRect(id)
    if monitorRect {
        isPrimary := RectsEqual(monitorRect, primaryRect)
        
        ; Setup Screen State Object
        screenState := Map(
            "ID", id,
            "Rect", monitorRect,
            "IsPrimary", isPrimary,
            "OriginalBrightness", -1,
            "IsModified", false,
            "LastActiveTime", A_TickCount,
            "Action", "",
            "Gui", "",
            "TargetDimLevel", 0
        )

        action := Trim(parts[2])
        
        if (action = "blackout") {
            ; Create GUI immediately but keep hidden/transparent
            blackoutGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020") ; WS_EX_NOACTIVATE | TRANSPARENT
            blackoutGui.BackColor := "000000"
            
            x := monitorRect["Left"], y := monitorRect["Top"]
            w := monitorRect["Right"] - monitorRect["Left"]
            h := monitorRect["Bottom"] - monitorRect["Top"]
            
            screenState["Action"] := "blackout"
            screenState["Gui"] := blackoutGui
            screenState["ShowOpts"] := "x" x " y" y " w" w " h" h " NoActivate"
            
            ; Initial show (invisible)
            blackoutGui.Show(screenState["ShowOpts"])
            WinSetTransparent(0, blackoutGui.Hwnd)
        } 
        else if (action = "dim" && parts.Length = 3) {
            screenState["Action"] := "dim"
            screenState["TargetDimLevel"] := Integer(Trim(parts[3]))
        }
        else {
            continue
        }

        MonitoredScreens.Push(screenState)
        Log("Initialized monitor: " . id . (isPrimary ? " [PRIMARY]" : ""))
    }
}

SetTimer(CheckAllMonitors, CheckInterval)
return

; ==============================================================================
; MAIN LOOP
; ==============================================================================
CheckAllMonitors(*) {
    global MonitoredScreens, IdleThreshold
    global PrimaryMonitorBlackout, SleepRegardlessOfOutsideActivity, KeepActiveIfCursorPresent

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    
    ; Physical idle time (keyboard/mouse anywhere)
    globalIdleMs := A_TimeIdlePhysical
    
    ; Is there ANY user input happening right now?
    globalInputActive := (globalIdleMs < 100) 

    for screen in MonitoredScreens {
        rect := screen["Rect"]
        
        ; 1. Check if mouse is on this specific monitor
        isMouseOnScreen := (mx >= rect["Left"] && mx < rect["Right"] && my >= rect["Top"] && my < rect["Bottom"])
        
        ; 2. Determine "Activity" based on Settings
        isActive := false

        ; RULE A: If "SleepRegardless" is OFF, global activity wakes everyone.
        if (!SleepRegardlessOfOutsideActivity && globalInputActive) {
            isActive := true
        }
        ; RULE B: Mouse movement on THIS monitor always counts as activity.
        else if (isMouseOnScreen && globalInputActive) {
            isActive := true
        }
        ; RULE C: Static cursor presence (if configured).
        else if (isMouseOnScreen && KeepActiveIfCursorPresent) {
            isActive := true
        }

        ; 3. Update State Timers
        if (isActive) {
            screen["LastActiveTime"] := A_TickCount
        }

        ; 4. Calculate Idle Time for this monitor
        currentMonitorIdle := A_TickCount - screen["LastActiveTime"]
        
        ; ---------------------------------------------------------
        ; LOGIC: WAKE UP
        ; ---------------------------------------------------------
        if (isActive && screen["IsModified"]) {
            Log("Waking up: " . screen["ID"])
            
            ShowCursor() 

            if (screen["Action"] = "dim") {
                SetBrightness(screen["ID"], screen["OriginalBrightness"])
            } else {
                ; Restore transparency (make invisible) and click-through
                screen["Gui"].Opt("+E0x20") 
                WinSetTransparent(0, screen["Gui"].Hwnd)
            }
            
            screen["IsModified"] := false
            ClearRestoreState(screen["ID"])
        }
        
        ; ---------------------------------------------------------
        ; LOGIC: GO TO SLEEP
        ; ---------------------------------------------------------
        else if (!isActive && !screen["IsModified"] && currentMonitorIdle > IdleThreshold) {
            
            if (screen["IsPrimary"] && !PrimaryMonitorBlackout) {
                continue
            }

            Log("Sleeping: " . screen["ID"])
            
            currentB := GetBrightness(screen["ID"])
            screen["OriginalBrightness"] := currentB
            SaveRestoreState(screen["ID"], currentB)

            if (screen["Action"] = "dim") {
                SetBrightness(screen["ID"], screen["TargetDimLevel"])
            } else {
                ; Only hide cursor if it's actually on this screen
                if (isMouseOnScreen) {
                    HideCursor()
                }

                ; Make opaque and block clicks
                screen["Gui"].Opt("-E0x20") 
                WinSetTransparent(255, screen["Gui"].Hwnd)
                screen["Gui"].Show("NoActivate") 
            }
            
            screen["IsModified"] := true
        }
    }
}

; ==============================================================================
; HELPER FUNCTIONS
; ==============================================================================

SetBrightness(monitorID, brightness) {
    global ControlTool
    try RunWait(Format('"{1}" /SetValue "{2}\Monitor0" 10 {3}', ControlTool, monitorID, brightness),, "Hide")
}

GetBrightness(monitorID) {
    global ControlTool
    try return RunWait(Format('"{1}" /GetValue "{2}\Monitor0" 10', ControlTool, monitorID),, "Hide")
    return 50
}

HideCursor() {
    global CursorHidden
    if CursorHidden
        return
    DllCall("user32\ShowCursor", "Int", false)
    CursorHidden := true
}

ShowCursor() {
    global CursorHidden
    if !CursorHidden
        return
    DllCall("user32\ShowCursor", "Int", true)
    CursorHidden := false
}

GetPrimaryRect() {
    try {
        MonitorGet(MonitorGetPrimary(), &l, &t, &r, &b)
        return Map("Left", l, "Top", t, "Right", r, "Bottom", b)
    }
    return Map("Left", 0, "Top", 0, "Right", 0, "Bottom", 0)
}

GetMonitorRect(monitorID) {
    global MultiTool, TempCsvFile
    RunWait(Format('"{1}" /scomma "{2}"', MultiTool, TempCsvFile),, "Hide")
    if !FileExist(TempCsvFile)
        return false

    ret := false
    try {
        loop read TempCsvFile {
            if (A_Index > 1 && InStr(A_LoopReadLine, monitorID)) {
                Loop Parse A_LoopReadLine, "CSV" {
                    row := []
                    Loop Parse A_LoopReadLine, "CSV"
                        row.Push(A_LoopField)
                    
                    if (row.Length >= 13 && row[13] = monitorID) {
                        res := StrSplit(row[1], "X"), w := Integer(res[1]), h := Integer(res[2])
                        pos := StrSplit(row[2], ","), l := Integer(pos[1]), t := Integer(pos[2])
                        ret := Map("Left", l, "Top", t, "Right", l+w, "Bottom", t+h)
                        break
                    }
                }
            }
            if ret
                break
        }
    }
    FileDelete(TempCsvFile)
    return ret
}

RectsEqual(a, b) {
    return (a["Left"]=b["Left"] && a["Top"]=b["Top"] && a["Right"]=b["Right"] && a["Bottom"]=b["Bottom"])
}

; ==============================================================================
; STATE & CLEANUP
; ==============================================================================

SaveRestoreState(id, val) {
    global RestoreFile
    try FileAppend(id . ":" . val . "`n", RestoreFile)
}

ClearRestoreState(id) {
    global RestoreFile
    if !FileExist(RestoreFile)
        return
    
    text := ""
    loop read RestoreFile {
        if !InStr(A_LoopReadLine, id . ":")
            text .= A_LoopReadLine . "`n"
    }
    try {
        FileOpen(RestoreFile, "w").Write(text)
        if (text = "")
            FileDelete(RestoreFile)
    }
}

CleanupOnExit(ExitReason, ExitCode) {
    global MonitoredScreens
    ShowCursor()
    for screen in MonitoredScreens {
        if (screen["IsModified"]) {
            SetBrightness(screen["ID"], screen["OriginalBrightness"])
        }
        if (IsObject(screen["Gui"]))
            screen["Gui"].Destroy()
    }
    if FileExist(RestoreFile)
        FileDelete(RestoreFile)
}