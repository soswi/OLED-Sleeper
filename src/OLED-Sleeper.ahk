#SingleInstance force
#Requires AutoHotkey v2.0

;===============================================================================
; OLED Sleeper
;
; Description:
;   Prevents OLED burn-in on secondary displays by monitoring user activity.
;   If no mouse or window activity is detected on a given monitor for a defined
;   idle time, it will either black out the screen or dim it to a specific
;   brightness level, based on the provided arguments.
;
;   v2.1 Update:
;   - Added Pixel Content Detection (prevents sleep during videos/games).
;   - Optimized blackout sequence to reduce stutter.
;   - Independent monitor sleeping logic.
;
; Dependencies:
;   - ControlMyMonitor.exe (located in the ..\tools directory)
;   - MultiMonitorTool.exe (located in the ..\tools directory)
;
; Usage:
;   Run the script with two arguments:
;   1. A semicolon-separated list of monitor configurations.
;      - For blackout: \\.\DISPLAY_ID:blackout
;      - For dimming:  \\.\DISPLAY_ID:dim:LEVEL
;   2. Idle threshold in milliseconds (e.g., 30000 for 30s)
;===============================================================================


; ==============================================================================
; GLOBAL SETTINGS (User Configuration)
; ==============================================================================
global PrimaryMonitorBlackout           := 1  ; 1 = Allow primary to sleep, 0 = Primary always stays on
global SleepRegardlessOfOutsideActivity := 1  ; 1 = Monitor sleeps if IT is idle, even if you type on another screen
                                              ; 0 = If you are active ANYWHERE, ALL monitors stay awake
global KeepActiveIfCursorPresent        := 0  ; 1 = Monitor won't sleep if cursor is hovering (even if not moving)
                                              ; 0 = Monitor sleeps if cursor is static (unless moving)

; --- Content Awareness Settings ---
global DetectContentChanges             := 1   ; 1 = Check for significant screen changes (video/games)
global PixelCheckInterval               := 500 ; ms (Check pixels every X ms, distinct from main timer)
global PixelSampleCount                 := 30  ; How many points to check per screen
global PixelChangeThreshold             := 5   ; How many points must change to count as "Activity"


; === PATH DEFINITIONS ===
; Build robust paths relative to the script's location.
global ProjectRoot := A_ScriptDir . "\.."
global LogFile     := ProjectRoot . "\OLED-Sleeper.log"
global MultiTool   := ProjectRoot . "\tools\MultiMonitorTool\MultiMonitorTool.exe"
global ControlTool := ProjectRoot . "\tools\ControlMyMonitor\ControlMyMonitor.exe"
global TempCsvFile := ProjectRoot . "\monitors_sleeper_temp.csv"
global RestoreFile := ProjectRoot . "\config\sleeper_restore.dat"


; === CONFIGURATION VARIABLES ===
global MonitorConfigList := ""   ; Stores the raw input list of monitor configurations
global IdleThreshold := 0        ; Time (ms) before a monitor is considered idle
global CheckInterval := 200      ; Frequency (ms) to check each monitor's state
global CursorHidden := false     ; Tracks cursor visibility state


; === INTERNAL STATE ===
global MonitoredScreens := []    ; List of monitor state maps for each target screen
global LastPixelCheck   := 0     ; Timestamp for the last heavy pixel check


; ==============================================================================
; LOGGING FUNCTION — Appends messages to log file with timestamps
; ==============================================================================
Log(message) {
    global LogFile
    try FileAppend(Format("{1} - {2}`n", A_Now, message), LogFile)
}


; ==============================================================================
; INITIALIZATION BLOCK — Validates inputs, prepares state, and builds monitor list
; ==============================================================================

Log("--- Script started (v2.1) ---")

; --- Restore Brightness from Previous Session (if needed) ---
if FileExist(RestoreFile) {
    Log("Restore file found. Restoring brightness from previous session.")
    try {
        loop read RestoreFile
        {
            parts := StrSplit(A_LoopReadLine, ":")
            if (parts.Length = 2) {
                id := parts[1]
                brightness := Integer(parts[2])
                Log("Restoring brightness for " . id . " to " . brightness . "%")
                SetBrightness(id, brightness)
            }
        }
        FileDelete(RestoreFile)
        Log("Brightness restored and restore file deleted.")
    } catch {
        Log("ERROR: Failed to process brightness restore file.")
    }
}

; --- Handle required command-line arguments ---
if A_Args.Length < 2 {
    Log("ERROR: Not enough arguments passed.")
    MsgBox("This script requires 2 arguments:`n1. Monitor configuration list`n2. Idle timeout (ms).", "Error", 48)
    ExitApp
}

MonitorConfigList := A_Args[1]
IdleThreshold := Integer(A_Args[2])

Log("Monitor Config list: " . MonitorConfigList)
Log("Idle threshold: " . IdleThreshold . " ms")
Log("Settings: PrimaryBlackout=" . PrimaryMonitorBlackout . ", IndependentSleep=" . SleepRegardlessOfOutsideActivity . ", ContentDetect=" . DetectContentChanges)

; --- Ensure cleanup on script exit ---
OnExit(CleanupOnExit)

primaryRect := GetPrimaryRect()

; --- Parse and initialize each monitor configuration ---
for config in StrSplit(MonitorConfigList, ";") {
    parts := StrSplit(config, ":")
    id := Trim(parts[1])

    if id = ""
        continue

    Log("Attempting to initialize monitor: " . id)
    monitorRect := GetMonitorRect(id)

    if monitorRect {
        
        ; --- Pixel Sampling Setup (Grid Generation) ---
        samplePoints := []
        if (DetectContentChanges) {
            ; Generate a grid of points to check for content changes (videos/games)
            stepX := (monitorRect["Right"] - monitorRect["Left"]) / (PixelSampleCount // 3)
            stepY := (monitorRect["Bottom"] - monitorRect["Top"]) / 4
            loop (PixelSampleCount // 3) {
                i := A_Index
                loop 3 { ; 3 rows of checks
                    j := A_Index
                    px := monitorRect["Left"] + (i * stepX) - (stepX / 2)
                    py := monitorRect["Top"] + (j * stepY)
                    samplePoints.Push({x: Integer(px), y: Integer(py), color: 0})
                }
            }
        }

        ; Base state for any monitored screen
        screenState := Map(
            "ID", id,
            "Rect", monitorRect,
            "IsPrimary", RectsEqual(monitorRect, primaryRect),
            "OriginalBrightness", -1, ; -1 indicates not yet recorded
            "IsModified", false,
            "LastActiveTime", A_TickCount,
            "SamplePoints", samplePoints
        )

        if (screenState["IsPrimary"])
            Log("Monitor " . id . " detected as PRIMARY.")

        action := Trim(parts[2])
        if (action = "blackout") {
            blackoutGui := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
            ; WS_EX_NOACTIVATE (0x08000000) | WS_EX_TRANSPARENT (0x20)
            ; We use transparent initially to allow click-through while "hidden" (Alpha 0)
            blackoutGui.Opt("+E0x08000020 +Owner") 
            blackoutGui.BackColor := "000000"

            ; Precompute geometry + show options once (avoids resize lag on every blackout)
            x := monitorRect["Left"], y := monitorRect["Top"]
            w := monitorRect["Right"] - monitorRect["Left"]
            h := monitorRect["Bottom"] - monitorRect["Top"]
            showOpts := "x" x " y" y " w" w " h" h " NoActivate"

            screenState["Action"] := "blackout"
            screenState["Gui"] := blackoutGui
            screenState["ShowOpts"] := showOpts

            ; Initialization: Show the window but make it fully transparent (Alpha 0).
            ; This keeps the window in the DWM composition stack, preventing stutter
            ; when we later make it visible (Alpha 255).
            blackoutGui.Show(showOpts)
            WinSetTransparent(0, blackoutGui.Hwnd)

            Log("Monitor initialized: " . id)
        }
        else if (action = "dim" && parts.Length = 3) {
            screenState["Action"] := "dim"
            screenState["TargetDimLevel"] := Integer(Trim(parts[3]))
            Log("Monitor initialized: " . id . " with target dim level: " . screenState["TargetDimLevel"] . "%")
        }
        else {
            Log("WARNING: Invalid monitor configuration skipped: " . config)
            continue
        }

        MonitoredScreens.Push(screenState)
    } else {
        Log("ERROR: Could not find monitor ID: " . id)
        MsgBox("Monitor not found: " . id ".`nPlease verify the ID and ensure MultiMonitorTool.exe is available.", "Warning", 48)
    }
}

if MonitoredScreens.Length = 0 {
    Log("FATAL: No valid monitors were initialized.")
    MsgBox("Initialization failed. No monitors found. Exiting.", "Error", 48)
    ExitApp
}

Log("Initialization complete. Monitoring " . MonitoredScreens.Length . " screen(s).")
SetTimer(CheckAllMonitors, CheckInterval)
return


; ==============================================================================
; MAIN LOOP — Checks each monitored screen for user activity or inactivity
; ==============================================================================

CheckAllMonitors(*) {
    global MonitoredScreens, IdleThreshold, LastPixelCheck, PixelCheckInterval
    global PrimaryMonitorBlackout, SleepRegardlessOfOutsideActivity, KeepActiveIfCursorPresent
    global DetectContentChanges, PixelChangeThreshold

    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)

    ; Global physical idle time (mouse/keyboard inactivity)
    globalIdleMs := A_TimeIdlePhysical
    
    ; Determine if there is any global input happening (< 100ms means user is active)
    globalInputActive := (globalIdleMs < 100)

    ; Throttle pixel checking to save CPU (run independently of main loop speed)
    runPixelCheck := (DetectContentChanges && (A_TickCount - LastPixelCheck > PixelCheckInterval))
    if runPixelCheck
        LastPixelCheck := A_TickCount

    for screen in MonitoredScreens {
        rect := screen["Rect"]
        activity := false
        isMouseOnScreen := (mx >= rect["Left"] && mx < rect["Right"] && my >= rect["Top"] && my < rect["Bottom"])

        ; ---------------------------
        ; ACTIVITY DETECTION RULES
        ; ---------------------------
        
        ; Rule 1: Global Activity (if configured to wake all monitors)
        if (!SleepRegardlessOfOutsideActivity && globalInputActive) {
            activity := true
        }
        
        ; Rule 2: Mouse Movement on THIS monitor
        else if (isMouseOnScreen && globalInputActive) {
            activity := true
        }
        
        ; Rule 3: Static Cursor Presence (if configured)
        else if (isMouseOnScreen && KeepActiveIfCursorPresent) {
            activity := true
        }

        ; Rule 4: Content Changes (Pixel Sampling)
        ; Prevents sleep if a video or game is playing, even if no input is detected.
        if (!activity && !screen["IsModified"] && runPixelCheck) {
            changes := 0
            CoordMode("Pixel", "Screen")
            for point in screen["SamplePoints"] {
                try {
                    currentColor := PixelGetColor(point.x, point.y)
                    if (currentColor != point.color) {
                        changes++
                        point.color := currentColor ; Update stored color
                    }
                }
            }
            
            ; If enough pixels changed, consider it "Active"
            if (changes >= PixelChangeThreshold) {
                activity := true
                ; Debug Log: Log("Activity detected via pixels on " . screen["ID"])
            }
        }

        ; Update Last Active Time if activity was detected
        if (activity) {
            screen["LastActiveTime"] := A_TickCount
        }

        currentMonitorIdle := A_TickCount - screen["LastActiveTime"]


        ; ---------------------------
        ; REACTION: WAKE UP
        ; ---------------------------
        if (activity && screen["IsModified"]) {
            Log("Activity detected on " . screen["ID"] . ". Waking up.")

            ; Always restore cursor immediately when waking up
            ShowCursor()

            if (screen["Action"] = "dim") {
                Log("Restoring brightness to " . screen["OriginalBrightness"] . "%.")
                SetBrightness(screen["ID"], screen["OriginalBrightness"])
            } else {
                Log("Restoring transparency and click-through.")
                
                ; Restore Sequence to prevent visual glitches:
                ; 1. Enable Click-through (+E0x20)
                ; 2. Set Transparency to 0 (Invisible)
                screen["Gui"].Opt("+E0x20")
                WinSetTransparent(0, screen["Gui"].Hwnd)
            }

            screen["IsModified"] := false
            ClearRestoreState(screen["ID"])
        }

        ; ---------------------------
        ; REACTION: GO TO SLEEP
        ; ---------------------------
        else if (!activity && !screen["IsModified"] && currentMonitorIdle > IdleThreshold) {
            
            ; Guard: Check if Primary monitor is allowed to sleep
            if (screen["IsPrimary"] && !PrimaryMonitorBlackout) {
                continue
            }

            if (screen["Action"] = "dim") {
                ; DIM needs original brightness (tool call), BLACKOUT does not.
                currentBrightness := GetBrightness(screen["ID"])
                screen["OriginalBrightness"] := currentBrightness
                SaveRestoreState(screen["ID"], currentBrightness)
        
                Log(screen["ID"] . " exceeded idle threshold. Dimming from " . currentBrightness . "% to " . screen["TargetDimLevel"] . "%.")
                SetBrightness(screen["ID"], screen["TargetDimLevel"]) ; non-blocking is fine in most cases
            } 
            else { 
                ; blackout
                Log(screen["ID"] . " exceeded idle threshold. Blacking out.")
                
                ; Only hide cursor if it's currently on the screen going to sleep
                if (isMouseOnScreen) {
                    HideCursor()
                }

                ; No external tools here -> no stutter from RunWait/Exec.
                
                ; Blackout Sequence (Optimized for less stutter):
                ; 1. Make window Opaque (255) - Visual Blackout first
                WinSetTransparent(255, screen["Gui"].Hwnd)
                
                ; 2. Ensure it's correctly positioned (NoActivate prevents focus stealing)
                screen["Gui"].Show("NoActivate") 
                
                ; 3. Block Clicks (-E0x20). 
                ; Doing this last hides the style-change stutter behind the already black screen.
                screen["Gui"].Opt("-E0x20") 
            }

            screen["IsModified"] := true
        }
    }
}


; ==============================================================================
; HELPER FUNCTIONS — Wrappers for external monitor tools & System calls
; ==============================================================================

; Sets monitor brightness to a specific value using ControlMyMonitor.exe
; Added 'wait' parameter to allow non-blocking execution
SetBrightness(monitorID, brightness, wait := false) {
    global ControlTool
    ; Writes VCP code 0x10 (decimal 16). Uses /SetValue.
    cmd := Format('"{1}" /SetValue "{2}\Monitor0" 10 {3}', ControlTool, monitorID, brightness)

    try {
        if wait
            RunWait(cmd,, "Hide")
        else
            Run(cmd,, "Hide")
    } catch {
        Log("ERROR: SetBrightness failed for " . monitorID . " -> " . brightness)
    }
}

; Gets the current brightness of a monitor
; Optimized to use ExecStdout for better control
GetBrightness(monitorID) {
    global ControlTool
    ; Reads VCP code 0x10 (decimal 16) from StdOut.
    cmd := Format('"{1}" /GetValue "{2}\Monitor0" 10', ControlTool, monitorID)

    try {
        out := ExecStdout(cmd, 1500)
        ; Extract the first integer found in output.
        if RegExMatch(out, "(\d+)", &m)
            return Integer(m[1])
    } catch as e {
        Log("ERROR: GetBrightness failed for " . monitorID . " -> " . e.Message)
    }
    return 50 ; Fallback safe value
}

GetPrimaryRect() {
    try {
        idx := MonitorGetPrimary()
        MonitorGet(idx, &l, &t, &r, &b)
        return Map("Left", l, "Top", t, "Right", r, "Bottom", b)
    } catch {
        ; Fallback: assume primary starts at (0,0)
        return Map("Left", 0, "Top", 0, "Right", 0, "Bottom", 0)
    }
}

RectsEqual(a, b) {
    return (a["Left"] = b["Left"]
        && a["Top"] = b["Top"]
        && a["Right"] = b["Right"]
        && a["Bottom"] = b["Bottom"])
}

; Gets a monitor's screen coordinates using MultiMonitorTool.exe
GetMonitorRect(monitorID) {
    global MultiTool, TempCsvFile
    Log("Querying geometry for: " . monitorID)

    ; Export current monitor data to temporary CSV file
    RunWait(Format('"{1}" /scomma "{2}"', MultiTool, TempCsvFile),, "Hide")
    if !FileExist(TempCsvFile) {
        Log("ERROR: Output CSV not found after running MultiMonitorTool.")
        return false
    }

    csvData := FileRead(TempCsvFile)
    ret := false
    
    try {
        Loop Parse csvData, "`n", "`r" {
            if A_Index = 1 || A_LoopField = ""
                continue ; Skip header or blank line

            columns := []
            Loop Parse A_LoopField, "CSV" {
                columns.Push(A_LoopField)
            }

            ; Column 13 = Monitor ID. Match against target.
            if (columns.Length >= 13 && columns[13] = monitorID) {
                Log("Found matching monitor entry.")

                ; Parse resolution and position
                res := StrSplit(columns[1], "X")
                width := Integer(Trim(res[1]))
                height := Integer(Trim(res[2]))

                pos := StrSplit(columns[2], ",")
                left := Integer(Trim(pos[1]))
                top := Integer(Trim(pos[2]))

                Log("Geometry: " . width . "x" . height . " @ " . left . "," . top)

                ret := Map(
                    "Left", left,
                    "Top", top,
                    "Right", left + width,
                    "Bottom", top + height
                )
                break
            }
        }
    }
    
    FileDelete(TempCsvFile)
    return ret
}

HideCursor() {
    global CursorHidden
    if CursorHidden
        return

    while DllCall("user32\ShowCursor", "Int", false, "Int") >= 0 {
    }
    CursorHidden := true
}

ShowCursor() {
    global CursorHidden
    if !CursorHidden
        return

    while DllCall("user32\ShowCursor", "Int", true, "Int") < 0 {
    }
    CursorHidden := false
}

ExecStdout(cmd, timeoutMs := 1500) {
    ; Runs a process and returns its StdOut as text.
    ; Uses a simple timeout to avoid hanging the script if the tool stalls.
    sh := ComObject("WScript.Shell")
    ex := sh.Exec(cmd)

    start := A_TickCount
    while (ex.Status = 0) {
        if (A_TickCount - start > timeoutMs) {
            try ex.Terminate()
            throw Error("ExecStdout timeout: " cmd)
        }
        Sleep(10)
    }
    return ex.StdOut.ReadAll()
}


; ==============================================================================
; STATE MANAGEMENT FUNCTIONS — Manages the sleeper_restore.dat file
; ==============================================================================

SaveRestoreState(monitorID, brightness) {
    global RestoreFile
    Log("Saving restore state for " . monitorID . " -> " . brightness . "%")

    content := ""
    found := false
    if FileExist(RestoreFile) {
        loop read RestoreFile
        {
            if InStr(A_LoopReadLine, monitorID . ":") {
                content .= monitorID . ":" . brightness . "`n"
                found := true
            } else {
                content .= A_LoopReadLine . "`n"
            }
        }
    }
    if !found {
        content .= monitorID . ":" . brightness . "`n"
    }

    try {
        file := FileOpen(RestoreFile, "w", "UTF-8")
        file.Write(Trim(content, "`n"))
        file.Close()
    } catch {
        Log("ERROR: Failed to write to restore file.")
    }
}

ClearRestoreState(monitorID) {
    global RestoreFile
    ; Log("Clearing restore state for " . monitorID)

    if !FileExist(RestoreFile)
        return

    content := ""
    loop read RestoreFile
    {
        if !InStr(A_LoopReadLine, monitorID . ":") {
            content .= A_LoopReadLine . "`n"
        }
    }

    try {
        file := FileOpen(RestoreFile, "w", "UTF-8")
        file.Write(Trim(content, "`n"))
        file.Close()
        ; If the file is now empty, delete it
        if (file.Length = 0) {
            FileDelete(RestoreFile)
        }
    } catch {
        Log("ERROR: Failed to clear from restore file.")
    }
}


; ==============================================================================
; CLEANUP FUNCTION — Destroys GUI overlays and restores brightness on manual exit
; ==============================================================================

CleanupOnExit(ExitReason, ExitCode) {
    global MonitoredScreens
    Log("--- Exiting (Reason: " . ExitReason . ") ---")

    ShowCursor()

    for screen in MonitoredScreens {
        try {
            ; Since OnExit only triggers from a tray menu exit, we always restore.
            if (screen['IsModified']) {
                Log("Restoring brightness for monitor: " . screen['ID'] . " to " . screen['OriginalBrightness'] . "%")
                SetBrightness(screen['ID'], screen['OriginalBrightness'])
            }
            if (screen.Has("Gui") && IsObject(screen['Gui'])) {
                screen['Gui'].Destroy()
                Log("Destroyed GUI for monitor: " . screen['ID'])
            }
        } catch {
            Log("WARNING: Failed to clean up for: " . screen['ID'])
        }
    }
    
    if FileExist(RestoreFile) {
        FileDelete(RestoreFile)
    }

    Log("Cleanup completed.")
}