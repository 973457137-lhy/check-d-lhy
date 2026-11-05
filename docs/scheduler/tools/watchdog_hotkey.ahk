#Requires AutoHotkey v2.0
#SingleInstance Force

SetTitleMatchMode 2

; ===== 基本配置 =====
; 说明：本脚本模拟「往 WorkBuddy 会话里发一条值守指令」，
; 目的是让值守跑在用户当前选中的自定义模型上，而不是后台定时任务的平台默认模型。
global TargetWindow := "WorkBuddy"
global Interval := 1200000   ; 20 分钟（用户指定；一轮值守约 3-8 分钟，留余量）
global Command := "按 docs/scheduler/值守规程.md 执行值守"
global LogFile := "E:\Projects\check-d-lhy\.workbuddy\memory\ahk-trigger.log"
global IsRunning := false

; F8：启动每 30 分钟自动值守
F8::
{
    StartAutomation()
}

; F9：停止
F9::
{
    StopAutomation()
}

; F10：立即触发一次（调试用）
F10::
{
    SendMailCommand()
}

StartAutomation() {
    global IsRunning, Interval

    if IsRunning
        return

    if !WinExist("WorkBuddy") {
        MsgBox "没有找到 WorkBuddy 窗口，请先打开软件。"
        return
    }

    IsRunning := true
    SetTimer SendMailCommand, Interval

    TrayTip "WorkBuddy 值守", "已启动，立即先跑一次，之后每20分钟触发。"

    ; 启动时立即执行一次：让用户马上看到效果，也避免等 20 分钟才发现没配好
    SendMailCommand()
}

StopAutomation() {
    global IsRunning

    SetTimer SendMailCommand, 0
    IsRunning := false

    TrayTip "WorkBuddy 值守", "已停止。"
}

SendMailCommand() {
    global TargetWindow, Command, LogFile

    hwnd := WinExist(TargetWindow)
    if !hwnd {
        WriteLog("未找到 WorkBuddy 窗口，本轮跳过")
        return
    }

    try {
        ; 1. 恢复并激活 WorkBuddy
        WinRestore "ahk_id " hwnd
        WinActivate "ahk_id " hwnd

        if !WinWaitActive("ahk_id " hwnd, , 5) {
            WriteLog("WorkBuddy 激活失败，本轮跳过")
            return
        }

        Sleep 800

        ; 2. 获取窗口客户区位置和尺寸
        WinGetClientPos &clientX, &clientY, &clientW, &clientH, "ahk_id " hwnd

        ; 3. 点击聊天输入框（按客户区相对位置计算）
        CoordMode "Mouse", "Screen"
        clickX := clientX + Round(clientW * 0.59)
        clickY := clientY + Round(clientH * 0.83)

        Click clickX, clickY
        Sleep 500

        ; 4. 输入值守指令并发送
        SendText Command
        Sleep 500
        Send "{Enter}"

        WriteLog("已发送值守指令")

        ; 5. 不最小化：让任务在可见状态跑，避免某些情况下输入框失焦导致发送失败
        ;    （如需恢复最小化行为，取消下一行注释）
        ; WinMinimize "ahk_id " hwnd
    }
    catch as err {
        WriteLog("自动发送出错：" err.Message)
    }
}

WriteLog(msg) {
    global LogFile
    try {
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        FileAppend(ts " | " msg "`n", LogFile, "UTF-8")
    }
}
