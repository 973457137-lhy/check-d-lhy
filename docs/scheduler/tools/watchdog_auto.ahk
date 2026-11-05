#Requires AutoHotkey v2.0
#SingleInstance Force

SetTitleMatchMode 2

; ===== 自动值守版 v3：启动即开始，含窗口归位 + 5 小时上限 =====
global TargetWindow := "WorkBuddy"
global Interval := 1200000   ; 20 分钟
global Command := "按 docs/scheduler/值守规程.md 执行值守"
global LogFile := "E:\Projects\check-d-lhy\.workbuddy\memory\ahk-trigger.log"
global IsRunning := false

; 已验证可用的客户区尺寸（2026-11-04 22:59 / 11-05 13:32 两次成功即此尺寸）
global GoodW := 1006
global GoodH := 754

; 5 小时上限：到点自动停，避免忘记关掉一直跑
global MaxHours := 5
global RunUntil := 0

; F9：停止自动值守
F9::
{
    StopAutomation()
}

; F10：立即手动触发一次（不影响定时）
F10::
{
    SendMailCommand()
}

StartAutomation() {
    global IsRunning, Interval, MaxHours, RunUntil

    if IsRunning
        return

    if !WinExist(TargetWindow) {
        WriteLog("启动失败：未找到 WorkBuddy 窗口，60 秒后重试")
        SetTimer StartAutomation, -60000
        return
    }

    IsRunning := true
    RunUntil := A_TickCount + MaxHours * 3600 * 1000
    SetTimer SendMailCommand, Interval
    ; AHK v2 没有 A_NowAdd（那是 v1 的写法），必须用 DateAdd(A_Now, n, "Hours")。
    ; 写成 v1 形式会在启动时抛 "Call to nonexistent function"，导致这行日志永远写不出来。
    WriteLog("值守已启动，每20分钟触发，上限 " MaxHours " 小时（约至 "
        . FormatTime(DateAdd(A_Now, MaxHours, "Hours"), "HH:mm") . "）")

    ; 启动时先跑一次，验证链路
    SendMailCommand()
}

StopAutomation() {
    global IsRunning

    SetTimer SendMailCommand, 0
    IsRunning := false
    WriteLog("值守已停止（按 F9 或到上限）")
}

; 把窗口客户区归位到已验证尺寸；成功返回 true
NormalizeGeometry(hwnd) {
    global GoodW, GoodH

    WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    if (Abs(cw - GoodW) <= 2 && Abs(ch - GoodH) <= 2)
        return true

    ; 量出「外框 - 客户区」的差值，再按差值反推需要的外框尺寸
    WinGetPos &wx, &wy, &ww, &wh, "ahk_id " hwnd
    dx := ww - cw
    dy := wh - ch
    WinMove wx, wy, GoodW + dx, GoodH + dy, "ahk_id " hwnd
    Sleep 600

    WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    ok := (Abs(cw - GoodW) <= 8 && Abs(ch - GoodH) <= 8)
    WriteLog((ok ? "窗口已归位 " : "归位失败，实测 ") cw "x" ch
        . "（目标 " GoodW "x" GoodH . "）原为 " (cw) "x" ch)
    return ok
}

SendMailCommand() {
    global TargetWindow, Command, IsRunning, RunUntil, MaxHours

    ; 到 5 小时上限就自己停，不再空转
    if (IsRunning && RunUntil > 0 && A_TickCount > RunUntil) {
        StopAutomation()
        WriteLog("已达 " MaxHours " 小时上限，自动停止")
        return
    }

    hwnd := WinExist(TargetWindow)
    if !hwnd {
        WriteLog("未找到 WorkBuddy 窗口，本轮跳过")
        return
    }

    try {
        WinRestore "ahk_id " hwnd
        WinActivate "ahk_id " hwnd

        if !WinWaitActive("ahk_id " hwnd, , 5) {
            WriteLog("激活失败，本轮跳过")
            return
        }

        Sleep 1000
        Send "{Esc}"          ; 清掉可能的弹窗 / 下拉 / 自动补全
        Sleep 300

        ; 关键：窗口变形时先归位，归位不了就跳过（不盲点）
        if !NormalizeGeometry(hwnd) {
            WriteLog("窗口无法归位到 " GoodW "x" GoodH "，本轮跳过（避免点到错误位置）")
            return
        }

        WinGetClientPos &clientX, &clientY, &clientW, &clientH, "ahk_id " hwnd
        CoordMode "Mouse", "Screen"
        clickX := clientX + Round(clientW * 0.59)
        clickY := clientY + Round(clientH * 0.83)

        Click clickX, clickY
        Sleep 800

        SendText Command
        Sleep 800
        Send "{Enter}"
        Sleep 500
        Send "{Enter}"        ; 双 Enter 兜底：第一下被吞时第二下补上

        WriteLog("已发送值守指令 @(" clickX "," clickY ") 窗口 " clientW "x" clientH)
    }
    catch as err {
        WriteLog("出错：" err.Message)
    }
}

WriteLog(msg) {
    global LogFile
    try {
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend(ts " | " msg "`n", LogFile, "UTF-8")
    }
}

; ===== 启动后 2 秒自动开始，不需要人工按 F8 =====
SetTimer StartAutomation, -2000
