#Requires AutoHotkey v2.0
#SingleInstance Force

LogFile := "E:\Projects\check-d-lhy\.workbuddy\memory\ahk-oneshot.log"

WriteLog(msg) {
    global LogFile
    try {
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend(ts " | " msg "`n", LogFile, "UTF-8")
    }
}

WriteLog("=== 一次性测试开始 ===")

hwnd := WinExist("WorkBuddy")
if !hwnd {
    WriteLog("FAIL: 未找到 WorkBuddy 窗口")
    ExitApp 1
}

title := WinGetTitle(hwnd)
WinGetClientPos &cx, &cy, &cw, &ch, hwnd
WriteLog("OK 窗口 hwnd=" hwnd " title=[" title "] client=" cw "x" ch " origin=(" cx "," cy ")")

WinRestore hwnd
WinActivate hwnd
if !WinWaitActive(hwnd, , 5) {
    WriteLog("FAIL: 激活失败")
    ExitApp 1
}
WriteLog("OK 已激活")
Sleep 800

CoordMode "Mouse", "Screen"
clickX := cx + Round(cw * 0.59)
clickY := cy + Round(ch * 0.83)
WriteLog("点击坐标 (" clickX "," clickY ")")
Click clickX, clickY
Sleep 500

SendText "按 docs/scheduler/值守规程.md 执行值守"
Sleep 500
Send "{Enter}"
WriteLog("OK 已发送值守指令")
Sleep 1500

WriteLog("=== 一次性测试结束 ===")
ExitApp 0
