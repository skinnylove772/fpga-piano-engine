# =============================================================================
#  FPGA 钢琴 · 上位机控制台   v2  (PowerShell + WinForms, 零安装)
#
#  启动:  双击「启动上位机.bat」
#
#  ★ 界面风格参考常见串口助手: 顶部工具栏 + 左侧彩色日志 + 右侧数据面板
#  ★ 为什么用 PowerShell + WinForms: 本机无网络, pip 装不了 pyserial/PyQt,
#     而 Windows 自带 .NET + WinForms, 不需要装任何东西。
#  ★ 本文件必须存为 **UTF-8 带 BOM** —— PowerShell 5.1 读无 BOM 的 UTF-8
#     会按 GBK 解码, 中文全乱并报语法错误。(和 Verilog 源文件的要求正好相反!)
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================ 配色 ============================
$C_BG     = [System.Drawing.Color]::FromArgb(245,246,248)
$C_PANEL  = [System.Drawing.Color]::White
$C_TEXT   = [System.Drawing.Color]::FromArgb(40,44,52)
$C_SUB    = [System.Drawing.Color]::FromArgb(120,128,140)
$C_ACCENT = [System.Drawing.Color]::FromArgb(0,120,212)
$C_OK     = [System.Drawing.Color]::FromArgb(16,140,70)
$C_ERR    = [System.Drawing.Color]::FromArgb(200,50,50)
$C_WARN   = [System.Drawing.Color]::FromArgb(200,130,0)
$C_RX     = [System.Drawing.Color]::FromArgb(0,130,80)
$C_TX     = [System.Drawing.Color]::FromArgb(0,90,190)
$C_SYS    = [System.Drawing.Color]::FromArgb(130,135,145)

#  ★ 音色名表 —— **和 FPGA 屏幕上的字一模一样** (见 sim/gen_osd.py L691)
#    原来上位机只显示数字, 根本看不出切到哪个音色了。
$script:TimbreNames = @('SINE','TRI','SAW','SQR','PLS25','PLS12','MIX','REED')

# ============================ 串口层 ============================
$script:sp        = $null
$script:connected = $false
$script:spec      = @(0,0,0,0,0,0,0,0)
$script:busy      = $false

function Send-Batch {
    param($Sp, [byte[][]]$Frames, [int]$WaitMs = 200, [int]$ExpectBytes = 0)
    if (-not $Sp -or -not $Sp.IsOpen) { return "" }
    $Sp.DiscardInBuffer()
    #  *** 帧间必须留 5ms 间隔 ***
    #    实测: 4 帧连着发(0ms), 板子只回第 1 条 —— 后面的被丢了。
    #    加 5ms 间隔后 4 条全回。这在 115200 下约等于 57 个位时间, 足够
    #    让固件的接收状态机把一帧处理完再接下一帧。
    foreach ($f in $Frames) {
        $Sp.Write($f, 0, $f.Length)
        Start-Sleep -Milliseconds 5
    }
    $all = New-Object System.Collections.ArrayList
    $t0 = Get-Date; $lastRx = Get-Date
    while (((Get-Date) - $t0).TotalMilliseconds -lt $WaitMs) {
        if ($Sp.BytesToRead -gt 0) {
            $n = $Sp.BytesToRead
            $b = New-Object byte[] $n
            $Sp.Read($b,0,$n) | Out-Null
            foreach ($x in $b) { [void]$all.Add($x) }
            $lastRx = Get-Date
        }
        #  ★★★ 2026-10-11 修: 不能只看"静默"就退出 ★★★
        #   坑: 原来只判断 `静默 > 60ms 就 break`。
        #   而**固件两条应答之间本来就有间隙** (它要一条条处理),
        #   于是"收到第 1 条 -> 间隙超过 60ms -> 提前退出", 后面几条全丢。
        #   现象: 5 条命令总共该回 83 字节, 实际只收到 13 字节,
        #        而里面恰好含 "OK" (来自 M=OK), 于是**看起来像成功了** ——
        #        极其误导。用户反馈"曲谱模式操控不了 FPGA"就是这个。
        #   现在: **收满 ExpectBytes 才允许按静默退出**;
        #         收不满就一直等到 WaitMs 超时。
        $enough = ($ExpectBytes -le 0) -or ($all.Count -ge $ExpectBytes)
        if ($enough -and $all.Count -gt 0 -and `
            ((Get-Date) - $lastRx).TotalMilliseconds -gt 8) { break }
        #  ★★ 保持消息循环活跃 ★★
        #     Start-Sleep 不处理 Windows 消息, 而这里一等就是 100~150ms。
        #     不加这句的话, 这段时间内点击全被阻塞 —— 用户看到的就是
        #     "界面卡死, 日志一片空白"。
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 4
    }
    return (-join ($all | ForEach-Object {
        if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { ' ' } }))
}

function Send-Frame {
    param($Sp, [byte[]]$Frame, [int]$WaitMs = 350)
    if (-not $Sp -or -not $Sp.IsOpen) { return "" }
    $Sp.DiscardInBuffer()
    $Sp.Write($Frame, 0, $Frame.Length)
    $all = New-Object System.Collections.ArrayList
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalMilliseconds -lt $WaitMs) {
        if ($Sp.BytesToRead -gt 0) {
            $n = $Sp.BytesToRead
            $b = New-Object byte[] $n
            $Sp.Read($b,0,$n) | Out-Null
            foreach ($x in $b) { [void]$all.Add($x) }
        }
        #  ★★ 保持消息循环活跃 ★★
        #     Start-Sleep 不处理 Windows 消息, 而这里一等就是
        #     200~900ms。不加这句的话, 这段时间内点击全部被阻塞,
        #     用户看到的就是"界面卡死, 日志一片空白"。
        #
        #  ★★ 2026-10-18: 但**推键位期间必须不转** ★★
        #     那个动作要发 30 帧 (10 槽 x 选槽/类型/音高)。
        #     DoEvents 一转, 用户点的"写音色"就插在中间,
        #     两路应答互相吃掉 -> 表现就是"板子不反应"。
        #     宁可界面冻 1.2 秒。
        if (-not $script:keymapBusy) {
            [System.Windows.Forms.Application]::DoEvents()
        }
        Start-Sleep -Milliseconds 6
    }
    return (-join ($all | ForEach-Object {
        if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } }))
}

function ParseVal {
    param([string]$S)
    $m = [regex]::Match($S, '=\s*([0-9A-Fa-f]{1,4})')
    if ($m.Success) { return [Convert]::ToInt32($m.Groups[1].Value, 16) }
    return -1
}

#  ==================================================================
#  ★★ 2026-10-18: 键位表本地保存 + 自动下发
#     固件没有 flash 存储, 板子一断电键位就回到默认。
#     所以上位机这边存一份, 连接成功就自动推下去 ——
#     用户感受上就是"永久保存了"。
#  ==================================================================
$script:KeymapFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'keymap.json'
$script:KmapDefault = @(60,62,64,65,67,69,71,72,74,76)
#  ★★ 每根弦的类型 (和 RTL 的 kmap_kind 同序)
$script:KindsDefault = @(0,0,0,0,0,0,0,0,0,1)
$script:KindNames   = @('音弦', '变调', '音色', '八度', '力度', '音量')
$script:KindDesc    = @(
    '正常发音，音高由右边那个下拉框决定',
    '每拨一下全盘升 1 个半音，12 下回到原调',
    '每拨一下换下一个音色（8 种循环）',
    '每拨一下换八度（原调/高八度/两八度/三八度）',
    '每拨一下换力度（4 档）120/160/200/240',
    '每拨一下换音量（4 档）140/180/220/255'
)
$script:KindsSaved = @(0,0,0,0,0,0,0,0,0,1)
$script:KmapSaved   = @()
$script:keymapBusy  = $false     #  ★ 推键位期间的防重入标志
$script:KmapNeedPush = $false    #  ★ 连接成功后由定时器补推一次

function Load-Keymap {
    try {
        if (Test-Path $script:KeymapFile) {
            $o = Get-Content $script:KeymapFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($o.map -and $o.map.Count -eq 10) {
                #  ★ 兼容旧档: 没有 kinds 字段就用默认
                if ($o.kinds -and $o.kinds.Count -eq 10) {
                    $script:KindsSaved = @($o.kinds | ForEach-Object { [int]$_ })
                } else {
                    $script:KindsSaved = $script:KindsDefault
                }
                return @($o.map | ForEach-Object { [int]$_ })
            }
        }
    } catch {
        Log ("读取 keymap.json 失败: " + $_.Exception.Message) $C_ERR
    }
    return $script:KmapDefault
}

function Save-Keymap {
    param([int[]]$Map, $Kinds = $null)
    try {
        if (-not $Kinds) { $Kinds = $script:KindsSaved }
        $o = @{ map = @($Map); kinds = @($Kinds) }
        ($o | ConvertTo-Json -Compress) | Set-Content -Path $script:KeymapFile -Encoding UTF8
    } catch {
        Log ("保存 keymap.json 失败: " + $_.Exception.Message) $C_ERR
    }
}

#  把 10 个槽下发到板子。 $silent = 不写日志 (连接时自动推用)
function Push-Keymap {
    param([int[]]$Map, [bool]$silent = $false, $Kinds = $null)
    if (-not $script:connected) { return $false }
    #  ★ 防重入: Send-Frame 的等待循环会调 DoEvents(),
    #    如果不挡住, 用户在这期间点的按钮会被提前处理,
    #    上一版就是这样把串口自己关掉的。
    if ($script:keymapBusy) { return $false }
    $script:keymapBusy = $true
    $script:dlBusy = $true
    $bad = 0
    try {
        if (-not $Kinds) { $Kinds = $script:KindsDefault }
        for ($si = 0; $si -lt 10; $si++) {
            $v = [int]$Map[$si]
            if ($v -lt 0) { $v = 0 }
            if ($v -gt 127) { $v = 127 }
            $k = [int]$Kinds[$si]
            if ($k -lt 0 -or $k -gt 5) { $k = 0 }
            #  ★ 每槽三帧: 选槽 -> 写类型 -> 写音高
            #    超时 60ms: 板子回 6 字节只需 0.5ms, 60ms 已是 100 倍余量
            $r1 = Send-Frame $script:sp ([byte[]]@(0xA5,0x4E,[byte]$si,0x5A)) 40
            $r2 = Send-Frame $script:sp ([byte[]]@(0xA5,0x48,[byte]$k,0x5A)) 40
            $r3 = Send-Frame $script:sp ([byte[]]@(0xA5,0x4F,[byte]$v,0x5A)) 40
            if ($r1 -notmatch 'W=OK' -or $r2 -notmatch 'W=OK' -or $r3 -notmatch 'W=OK') { $bad++ }
        }
    } finally {
        $script:dlBusy = $false
        $script:keymapBusy = $false
    }
    if (-not $silent) {
        if ($bad -eq 0) { Log "键位表已下发 (10 根弦)" $C_TX }
        else            { Log ("键位表下发: {0} 根失败 (看上面的发/收日志)" -f $bad) $C_ERR }
    }
    return ($bad -eq 0)
}


function Connect-FPGA {
    param([string]$Port)
    try {
        if ($script:sp -and $script:sp.IsOpen) { $script:sp.Close() }
        $script:sp = New-Object System.IO.Ports.SerialPort $Port,115200,'None',8,'One'
        $script:sp.ReadTimeout = 300
        $script:sp.Open()
        Start-Sleep -Milliseconds 400
        $script:sp.DiscardInBuffer()
        $r = Send-Frame $script:sp @(0xA5,0x4B,0x00,0x5A) 500
        if ($r -like "*Z9*") {
            $script:connected = $true
            $script:KmapSaved = Load-Keymap
            #  ★ 不在这里同步推! 这里推会让 Send-Frame 的 DoEvents
            #    轮转 1.2 秒, 用户点的"连接"按钮（开关）会被提前处理掉 ——
            #    那就是"连上又马上断开"的病根。
            #    改成留一个标志, 由主定时器在下一拍推 —— 跑在本调用栈之外。
            $script:KmapNeedPush = $true
            return @{ok=$true; msg="已连接 $Port - 固件 Z9"}
        } elseif ($r.Length -gt 0) {
            $script:connected = $true
            $script:KmapSaved = Load-Keymap
            $script:KmapNeedPush = $true
            return @{ok=$true; msg="已连接 $Port - 应答 $r"}
        } else {
            $script:connected = $false
            return @{ok=$false; msg="$Port 已打开但无应答 - 板子上是这个固件吗?"}
        }
    } catch {
        $script:connected = $false
        return @{ok=$false; msg="打不开 $Port : $($_.Exception.Message)"}
    }
}

# ============================ 主窗口 ============================
#  ==================================================================
#  ★★★ 绘制用的 GDI 对象: **预先创建好, 只创建一次** ★★★
#    (2026-10-11 修) 为什么:
#    原来每一次 Paint 都会 `New-Object System.Drawing.Font(...)`
#    创建 13 个 GDI 对象, 而且**从不 Dispose**。
#    窗体 7 次/秒刷新 -> 每秒泄漏 ~90 个 GDI 句柄 ->
#    句柄表越来越大, 系统越来越卡, 最后整个界面僵住。
#    (用户反馈: "感觉小程序变卡了")
#    ★ 现在: 字体和固定颜色的画笔只创建**一次**。
#    ★ 注意: 这些对象程序退出时会跟着进程一起释放,
#      不用手动 Dispose (其实也没地方 Dispose)。
#  ==================================================================
$script:FT = @{
    Title  = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    Note   = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
    Mark   = New-Object System.Drawing.Font("Microsoft YaHei UI", 7.5)
    Idx    = New-Object System.Drawing.Font("Consolas", 7)
    Small  = New-Object System.Drawing.Font("Microsoft YaHei UI", 7.5)
    Hint   = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    Axis   = New-Object System.Drawing.Font("Consolas", 7.5)
    LedNum = New-Object System.Drawing.Font("Consolas", 8)
}
$script:PGrid  = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(232,234,238)), 1
$script:PSep   = New-Object System.Drawing.Pen ([System.Drawing.Color]::LightGray), 1
$script:PUnder = New-Object System.Drawing.Pen ([System.Drawing.Color]::Gray), 1
$script:PNow   = New-Object System.Drawing.Pen ([System.Drawing.Color]::DodgerBlue), 1
$form = New-Object System.Windows.Forms.Form
$form.Text = "FPGA 钢琴 - 上位机控制台"
#  ★★★ 2026-10-11 修: 默认尺寸必须**大于等于**最小尺寸 ★★★
#   坑: 原来默认 980x700, 而最小尺寸已经涨到 1000x860 ——
#   窗口一开就比最小还小, 左侧第三个面板(曲谱简谱)直接被挤出可视区,
#   用户报"简谱没有出来"。**默认尺寸必须垫得下所有面板**。
#   左侧要: 日志150 + 参数配置210 + 简谱160 + 标题/间距 ~110 = 630
#   加上工具栏54 + 状态栏26 = 710 -> 取 1000 高度留余量。
#   ★★ 2026-10-11 再加: 右侧现在是 7 个面板, 共约 1118px,
#      所以默认高度提到 1200 (不然最下面的曲谱库看不到)。
#   ★ 注意: 这一行开头的单引号是**我误删留下的**, 它让 PowerShell
#     把后面 12 行全当成一个未结束的字符串, 报了一堆莫名其妙的错
#     (最先报的是 L174 'CenterScreen')。注释里不要出现落单的引号。
$form.Size = New-Object System.Drawing.Size(1440, 1200)
#  ★ 最小尺寸: 内容区(去掉工具栏54 + 状态栏26)
#    至少要能放下右侧三个面板的最小高度。小于这个尺寸时右侧会出现滚动条。
#  ★ 最小高度 680: 参数配置有 7 行, 低于这个高度第三行会放不下
#    (实测 560 时面板只有 174px, 而 7 行最少需要 198px -> 最后一行被切掉)
$form.MinimumSize = New-Object System.Drawing.Size(1200, 1000)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

# ---------------- 顶部工具栏 ----------------
$pnlTop = New-Object System.Windows.Forms.Panel
$pnlTop.Dock = 'Top'; $pnlTop.Height = 54
$pnlTop.BackColor = $C_PANEL
$form.Controls.Add($pnlTop)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "串口"; $lblPort.Location = New-Object System.Drawing.Point(16,18)
$lblPort.Size = New-Object System.Drawing.Size(36,22); $lblPort.ForeColor = $C_SUB
$pnlTop.Controls.Add($lblPort)

$cmbPort = New-Object System.Windows.Forms.ComboBox
$cmbPort.Location = New-Object System.Drawing.Point(54,15); $cmbPort.Size = New-Object System.Drawing.Size(96,25)
$cmbPort.DropDownStyle = 'DropDownList'
$pnlTop.Controls.Add($cmbPort)

$lblBaud = New-Object System.Windows.Forms.Label
$lblBaud.Text = "波特率"; $lblBaud.Location = New-Object System.Drawing.Point(166,18)
$lblBaud.Size = New-Object System.Drawing.Size(48,22); $lblBaud.ForeColor = $C_SUB
$pnlTop.Controls.Add($lblBaud)

$cmbBaud = New-Object System.Windows.Forms.ComboBox
$cmbBaud.Location = New-Object System.Drawing.Point(216,15); $cmbBaud.Size = New-Object System.Drawing.Size(88,25)
$cmbBaud.DropDownStyle = 'DropDownList'
[void]$cmbBaud.Items.AddRange(@('9600','115200'))
$cmbBaud.SelectedIndex = 1
$pnlTop.Controls.Add($cmbBaud)

$btnConn = New-Object System.Windows.Forms.Button
$btnConn.Text = "打开串口"
$btnConn.Location = New-Object System.Drawing.Point(320,13); $btnConn.Size = New-Object System.Drawing.Size(94,30)
$btnConn.FlatStyle = 'Flat'; $btnConn.BackColor = $C_ACCENT; $btnConn.ForeColor = 'White'
$btnConn.FlatAppearance.BorderSize = 0
$btnConn.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$pnlTop.Controls.Add($btnConn)

$btnRefreshPorts = New-Object System.Windows.Forms.Button
$btnRefreshPorts.Text = "刷新"
$btnRefreshPorts.Location = New-Object System.Drawing.Point(420,13); $btnRefreshPorts.Size = New-Object System.Drawing.Size(56,30)
$btnRefreshPorts.FlatStyle = 'Flat'; $btnRefreshPorts.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$btnRefreshPorts.FlatAppearance.BorderSize = 0
$pnlTop.Controls.Add($btnRefreshPorts)

$lblDot = New-Object System.Windows.Forms.Label
$lblDot.Text = "●"; $lblDot.Location = New-Object System.Drawing.Point(492,14)
$lblDot.Size = New-Object System.Drawing.Size(20,26); $lblDot.Font = New-Object System.Drawing.Font("Segoe UI", 14)
$lblDot.ForeColor = [System.Drawing.Color]::FromArgb(190,195,205)
$pnlTop.Controls.Add($lblDot)

$lblConn = New-Object System.Windows.Forms.Label
$lblConn.Text = "未连接"
$lblConn.Location = New-Object System.Drawing.Point(514,18); $lblConn.Size = New-Object System.Drawing.Size(400,22)
$lblConn.ForeColor = $C_SUB
$pnlTop.Controls.Add($lblConn)

#  ==================================================================
#  ★★ 2026-10-19: 延迟实测 (赛题拓展 3) ★★
#  主归 FPGA 里有一个计数器, 量的是:
#      ev_on (音符事件发给引擎那一拍) -> audio_s 第一个非零样本
#  单位是 3MHz 拍, 1 拍 = 0.3333us。从 RID 30 读回。
#  这里再加上"消抖"(读 RID 5 得档位) 和"I2S 串行化",
#  给出完整的数字链路, 以及加上功放后的范围。
#  ==================================================================
$btnLat = New-Object System.Windows.Forms.Button
$btnLat.Text = "延迟实测"
$btnLat.Location = New-Object System.Drawing.Point(930,13)
$btnLat.Size = New-Object System.Drawing.Size(100,30)
$btnLat.FlatStyle = 'Flat'
$btnLat.BackColor = [System.Drawing.Color]::FromArgb(90,96,110)
$btnLat.ForeColor = 'White'
$btnLat.FlatAppearance.BorderSize = 0
$btnLat.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$btnLat.Enabled = $false
$pnlTop.Controls.Add($btnLat)

$lblLat = New-Object System.Windows.Forms.Label
$lblLat.Text = "延迟: —  (先连接, 静音, 然后点左边按钮)"
$lblLat.Location = New-Object System.Drawing.Point(1036,18)
$lblLat.Size = New-Object System.Drawing.Size(392,22)
$lblLat.ForeColor = $C_SUB
$pnlTop.Controls.Add($lblLat)

# ---------------- 底部状态栏 ----------------
$pnlBottom = New-Object System.Windows.Forms.Panel
$pnlBottom.Dock = 'Bottom'; $pnlBottom.Height = 26
$pnlBottom.BackColor = [System.Drawing.Color]::FromArgb(235,237,240)
$form.Controls.Add($pnlBottom)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "就绪"
$lblStatus.Location = New-Object System.Drawing.Point(12,5); $lblStatus.Size = New-Object System.Drawing.Size(880,18)
$lblStatus.ForeColor = $C_SUB; $lblStatus.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$pnlBottom.Controls.Add($lblStatus)

# ---------------- 主区域 ----------------
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
#  ★ 分栏比例: 左(日志) 60% / 右(数据) 40%
#    不能写死: 写死 540 的话, 窗口变小时右侧会被挤到只剩 191px。
$script:splitRatio = 0.62
$split.SplitterWidth = 8
$split.BackColor = $C_BG
$split.Panel1.BackColor = $C_BG
$split.Panel2.BackColor = $C_BG
$form.Controls.Add($split)
$split.BringToFront()

# ========== 左: 彩色日志 + 发送 ==========
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = " 通信日志 "
#  ★★ 2026-10-10: 从 Dock='Fill' 改成 Dock='Top' + 固定高度 ★★
#    为什么: 原来日志是 Fill、参数配置是 Bottom,
#    按道理 Fill 应该自动让位, 但实测**日志把配置面板整个盖住了**
#    (BringToFront 也没用)。改成两个都是固定高度就不会互相干扰。
#    ★ 高度由 Fit-LeftW 按容器高度算出来 (日志 = 总高 - 配置 210 - 间距)。
$grpLog.Dock = 'Top'
$grpLog.Height = 400
$grpLog.BackColor = $C_PANEL
$grpLog.ForeColor = $C_SUB
$split.Panel1.Padding = New-Object System.Windows.Forms.Padding(10,6,4,10)

$grpCfg = New-Object System.Windows.Forms.GroupBox
$grpCfg.Text = " 参数配置 "
$grpCfg.BackColor = $C_PANEL; $grpCfg.ForeColor = $C_SUB
#  ★★ 改成放在**左侧、日志下方** (2026-10-10 用户要求)
#     用 Dock='Bottom' + 固定高度 210px: 7 行内容需 198px, 给 210 有余量。
#  ★★★ 加完所有控件后必须 BringToFront ★★★
#    坑: 日志面板是 Dock='Fill', 配置面板是 Dock='Bottom'。按 WinForms 的
#    规则 Fill 应该自动让位给 Bottom, 但实测**日志把配置面板整个盖住了**
#    (配置面板 T=561 是可见的, 但日志从 T=6 一直画到 T=771)。
#    所以这里强制把配置面板提到最前 —— 反正在同一列里, 不会遮住别的。
#    这一步在文件末尾 (所有控件建完之后) 再做一次, 见 Form_Load。
$grpCfg.Dock = 'Bottom'
$grpCfg.Height = 210
$split.Panel1.Controls.Add($grpCfg)

$chkHost = New-Object System.Windows.Forms.CheckBox
$chkHost.Text = "上位机接管 (总开关)"
$chkHost.Location = New-Object System.Drawing.Point(12,22); $chkHost.Size = New-Object System.Drawing.Size(200,22)
$chkHost.ForeColor = $C_WARN
$chkHost.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$grpCfg.Controls.Add($chkHost)

#  ==================================================================
#  ★★ 2026-10-18: 键位自定义入口
#     放在"上位机接管"勾选框右边, 不占面板的行
#     (面板高 210px, 7 行已经占满, 再加行会被 Fit-CfgRows 压掉)。
#     抓开独立对话框 —— 主界面布局一动不动。
#  ==================================================================
$btnKeymap = New-Object System.Windows.Forms.Button
#  ★ 按钮文字 = **当前方案名**, 不用打开对话框就知道现在是什么音阶
$btnKeymap.Text = "键位: 默认 do-re-mi"
$btnKeymap.Location = New-Object System.Drawing.Point(238, 19)
$btnKeymap.Size = New-Object System.Drawing.Size(150, 25)
$btnKeymap.FlatStyle = 'Flat'
$btnKeymap.BackColor = [System.Drawing.Color]::FromArgb(214, 232, 246)
$btnKeymap.FlatAppearance.BorderSize = 0
$btnKeymap.ForeColor = [System.Drawing.Color]::FromArgb(20, 60, 100)
$grpCfg.Controls.Add($btnKeymap)

$lblCfgMsg = New-Object System.Windows.Forms.Label
$lblCfgMsg.Text = ""
#  隐藏: 它原来占右侧, 和输入框重叠。写入结果直接进左侧通信日志。
$lblCfgMsg.Text = ""; $lblCfgMsg.Visible = $false
$lblCfgMsg.ForeColor = $C_SUB; $lblCfgMsg.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$grpCfg.Controls.Add($lblCfgMsg)

function New-CfgRow {
    param([string]$Label, [int]$Min, [int]$Max, [int]$Y, [int]$Init,
          [string[]]$Items = $null, [int]$RowH = 26)
    #  ★★★ 所有坐标先算成变量, 再传给 New-Object ★★★
    #   为什么: PowerShell 会把 `New-Object X(a, $Y-1)` 里的 `$Y-1`
    #   当成数组参数, 报 "op_Subtraction 方法不存在"。
    #   先赋值给变量就没有歧义了。
    #  ★★★ 单列布局 (不再分两列) ★★★
    #   为什么: 面板客户区只有 ~406px 宽, 分两列时左列的"写入"按钮
    #   (x=162..214) 会压到右列的标签 (x=178) 上 —— 实测确实重叠了。
    #   现在每行:  标签(14..82) + 输入(86..200) + 按钮(214..290)
    $lx = 14; $nx = 86; $bx = 214; $bw = 76
    $by = $Y - 1
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Label; $l.Location = New-Object System.Drawing.Point($lx,$Y)
    $l.Size = New-Object System.Drawing.Size(68,22); $l.ForeColor = $C_TEXT
    $grpCfg.Controls.Add($l)
    #  ★ 传了 Items 就用下拉框(显示名字); 否则用数值框
    if ($Items) {
        $nb = New-Object System.Windows.Forms.ComboBox
        $nb.DropDownStyle = 'DropDownList'
        foreach ($it in $Items) { [void]$nb.Items.Add($it) }
        $nb.SelectedIndex = $Init
    } else {
        $nb = New-Object System.Windows.Forms.NumericUpDown
        $nb.Minimum = $Min; $nb.Maximum = $Max; $nb.Value = $Init
    }
    $nb.Location = New-Object System.Drawing.Point($nx,$Y); $nb.Size = New-Object System.Drawing.Size(114,24)
    $grpCfg.Controls.Add($nb)
    $bt = New-Object System.Windows.Forms.Button
    $bt.Text = "写入"
    $bt.Location = New-Object System.Drawing.Point($bx,$by); $bt.Size = New-Object System.Drawing.Size($bw,$RowH)
    $bt.FlatStyle = 'Flat'; $bt.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
    $bt.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($bt)
    return @{lbl=$l; num=$nb; btn=$bt}
}
$timbreItems = @()
for ($i = 0; $i -lt 8; $i++) {
    $timbreItems += ("[{0}] {1}" -f $i, $script:TimbreNames[$i])
}
#  ★★★ 单列 7 行 ★★★
#   ★ 行高自适应: 面板高度会随窗口变, 所以先用默认值建好控件,
#     等窗口显示后再由 Fit-CfgRows 按实际高度重排 —— 保证不溢出、也不浪费空间。
$script:CfgY0   = 46          # 第一行的 Y
$script:CfgRowH = 26          # 行高 (先给默认, 之后重算)
$script:CfgRows = @()

$rowTimbre = New-CfgRow "音色"   0   7   46  0   $timbreItems
#  ★ 灵敏度默认档改成 **0 (最灵敏, 30us)**
#    原来默认 2 (500us) —— 用户反馈"按了一个音都检测不到"。
$rowSens   = New-CfgRow "灵敏度" 0   4   72  0   $null
$rowOct    = New-CfgRow "八度"   0   3   98  0   $null
$rowVol    = New-CfgRow "音量"   0   255 124 220 $null
$rowVel    = New-CfgRow "力度"   80  240 150 200 $null
$rowVib    = New-CfgRow "颤音"   0   7   176 0   $null
$rowChorus = New-CfgRow "合唱"   0   1   202 1   @('关','开')
$script:CfgRows = @($rowTimbre,$rowSens,$rowOct,$rowVol,$rowVel,$rowVib,$rowChorus)

#  按面板实际高度重排这 7 行
function Fit-CfgRows {
    if (-not $grpCfg) { return }
    $h = $grpCfg.ClientRectangle.Height
    if ($h -lt 80) { return }
    $avail = $h - $script:CfgY0 - 8
    $rh = [int]($avail / 7)
    if ($rh -lt 22) { $rh = 22 }
    if ($rh -gt 32) { $rh = 32 }
    $script:CfgRowH = $rh
    $i = 0
    foreach ($r in $script:CfgRows) {
        $y = $script:CfgY0 + $i * $rh
        #  ★ 坐标先算成变量再传, 避免 PowerShell 把 "$y - 1" 当数组参数
        $by = $y - 1
        $bh = $rh - 1
        $r.lbl.Location = New-Object System.Drawing.Point(14, $y)
        $r.num.Location = New-Object System.Drawing.Point(86, $y)
        $r.btn.Location = New-Object System.Drawing.Point(214, $by)
        $r.btn.Size     = New-Object System.Drawing.Size(76, $bh)
        $i++
    }
}

$split.Panel1.Controls.Add($grpLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'
$rtbLog.ReadOnly = $true
$rtbLog.BorderStyle = 'None'
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(252,252,253)
$rtbLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$rtbLog.WordWrap = $false
$rtbLog.ScrollBars = 'Vertical'
$grpLog.Controls.Add($rtbLog)

$pnlTx = New-Object System.Windows.Forms.Panel
$pnlTx.Dock = 'Bottom'; $pnlTx.Height = 48
$pnlTx.BackColor = $C_PANEL
$grpLog.Controls.Add($pnlTx)

$txtIn = New-Object System.Windows.Forms.TextBox
$txtIn.Location = New-Object System.Drawing.Point(8,8); $txtIn.Size = New-Object System.Drawing.Size(360,26)
$txtIn.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtIn.Text = "A5 4B 00 5A"
$pnlTx.Controls.Add($txtIn)

$btnSend = New-Object System.Windows.Forms.Button
$btnSend.Text = "发送"
$btnSend.Location = New-Object System.Drawing.Point(376,7); $btnSend.Size = New-Object System.Drawing.Size(72,28)
$btnSend.FlatStyle = 'Flat'; $btnSend.BackColor = $C_ACCENT; $btnSend.ForeColor = 'White'
$btnSend.FlatAppearance.BorderSize = 0
$pnlTx.Controls.Add($btnSend)

$lblTxHint = New-Object System.Windows.Forms.Label
$lblTxHint.Text = "16 进制 - 常用: A5 4B 00 5A(自检)  A5 42 00 5A(频谱)"
$lblTxHint.Location = New-Object System.Drawing.Point(8,30); $lblTxHint.Size = New-Object System.Drawing.Size(450,14)
$lblTxHint.ForeColor = $C_SUB; $lblTxHint.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 7.5)
$pnlTx.Controls.Add($lblTxHint)
$pnlTx.BringToFront()

function Log {
    param([string]$Text, [System.Drawing.Color]$Color)
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor = $Color
    $rtbLog.AppendText($Text + "`r`n")
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.ScrollToCaret()
}

# ========== 右: 状态 + 频谱 + 参数 ==========
$right = $split.Panel2
$right.Padding = New-Object System.Windows.Forms.Padding(4,6,10,10)

#  ============================================================
#  ★★★ 右侧布局: 用 TableLayoutPanel 按百分比分配高度 ★★★
#    为什么要改: 原来用绝对坐标 + Anchor, 窗口变小时
#    三个面板会互相重叠/溢出到看不见 (实测确实如此)。
#   现在: 3 行按 26% / 33% / 30% 分配, 窗口变大时各面板等比拉伸。
#  ============================================================
#  ============================================================
#  ★★★ 2026-10-10 第三次改布局: 改成"固定高度 + 自动滚动条" ★★★
#   为什么:
#     第一版用绝对坐标 -> 窗口一变就重叠;
#     第二版用 TableLayoutPanel 按百分比 -> 不重叠了, 但**面板变短后
#       里面的行就被切掉** (参数配置 7 行需要 198px, 而只给了 123px);
#     现在: 每个面板给**固定高度** (够放下里面的内容),
#           容器开 AutoScroll -> 窗口不够高时**出滚动条**, 永远不会看不到。
#   ★ 代价: 高分辨率屏幕下底部会有空白 (固定高度不会拉伸)。
#     对"能看全"来说这个代价值得。
#  ============================================================
$tblRight = New-Object System.Windows.Forms.Panel
#  ★★★ 这里必须 Dock = 'Fill'! ★★★
#   坑: 我用批量替换去掉各面板的 Dock 时, 替换文本同时命中了
#   `$tblRight.Dock = 'Fill'`, 把它换成了注释 -> 容器不再 Dock,
#   高度塌成 0, 整个右侧看起来"什么都没了"。
#   ★ 教训: 批量字符串替换**必须先确认唯一性**, 否则会误伤。
$tblRight.Dock = 'Fill'
$tblRight.AutoScroll = $true
$tblRight.BackColor = $C_BG
$right.Controls.Add($tblRight)

#  面板高度表 (和下面添加的顺序对应)
$script:PanelH = @(146, 130, 146, 118, 220, 196, 214)   # 状态/频谱/曲谱/灯带/简谱/下载/曲谱库
$script:PanelW = 300
$script:PanelIdx = 0
$script:PanelY = 0        # ★ 累加的 Y 坐标
function Add-RightPanel {
    param($Ctrl)
    $i = $script:PanelIdx
    $Ctrl.Dock = 'None'                 # ★ 自己定位, 不用 Dock
    $Ctrl.Left = 0
    #  ★★★ 必须用**累加**的 Y ★★★
    #    我第一版全写成 Top = 0, 结果 5 个面板**全部叠在左上角**,
    #    看起来就是"后面的面板把前面的盖住了 / 显示不完"。
    $Ctrl.Top  = $script:PanelY
    #  ★ 宽度自适应: 容器客户区宽 - 滚动条宽 - 4
    #    固定 420px 在宽度不够时会被右边切掉
    #    (实测: "下一首"按钮和"写入"按钮都显示不全)。
    $cw = $tblRight.ClientRectangle.Width
    if ($cw -lt 200) { $cw = $script:PanelW }
    $Ctrl.Width  = $cw - 4
    $Ctrl.Height = $script:PanelH[$i]
    $Ctrl.Anchor = 'Top,Left,Right'
    $tblRight.Controls.Add($Ctrl)
    $script:PanelY   = $script:PanelY + $script:PanelH[$i] + 4    # +4 是面板间距
    #  ★★★ 必须同步 AutoScrollMinSize ★★★
    #    $tblRight.AutoScroll = $true 只是"允许滚动", 但 Panel 不知道
    #    内容有多高, 所以**不会出现滚动条** -> 底下面板被切掉也看不到。
    #    实测: 7 个面板需要 1160px, 容器只有 1105px, 最后那个面板
    #    的下半截就没了 (用户报"在线搜索按钮被切")。
    #    ★ 加这一行后, 内容超出时会自动出现滚动条。
    $tblRight.AutoScrollMinSize = New-Object System.Drawing.Size(0, $script:PanelY)
    $script:PanelIdx = $i + 1
}

$grpStat = New-Object System.Windows.Forms.GroupBox
$grpStat.Text = " 实时状态 "
$grpStat.Dock = 'None'
$grpStat.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
Add-RightPanel $grpStat
$grpStat.BackColor = $C_PANEL; $grpStat.ForeColor = $C_SUB

$lblBig = New-Object System.Windows.Forms.Label
$lblBig.Text = "--"
$lblBig.Location = New-Object System.Drawing.Point(12,26); $lblBig.Size = New-Object System.Drawing.Size(120,56)
$lblBig.Font = New-Object System.Drawing.Font("Consolas", 34, [System.Drawing.FontStyle]::Bold)
$lblBig.ForeColor = $C_ACCENT
$grpStat.Controls.Add($lblBig)

$lblBigCap = New-Object System.Windows.Forms.Label
$lblBigCap.Text = "活跃声部数"
$lblBigCap.Location = New-Object System.Drawing.Point(16,82); $lblBigCap.Size = New-Object System.Drawing.Size(110,18)
$lblBigCap.ForeColor = $C_SUB
$grpStat.Controls.Add($lblBigCap)

$lblDetail = New-Object System.Windows.Forms.Label
$lblDetail.Text = "音色  : --`r`n测试档: --`r`n手势  : --"
$lblDetail.Location = New-Object System.Drawing.Point(138,20); $lblDetail.Size = New-Object System.Drawing.Size(216,86)
$lblDetail.Font = New-Object System.Drawing.Font("Consolas", 10)
$lblDetail.ForeColor = $C_TEXT
$grpStat.Controls.Add($lblDetail)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = "自动刷新"
$chkAuto.Location = New-Object System.Drawing.Point(138,110); $chkAuto.Size = New-Object System.Drawing.Size(90,22)
$chkAuto.Checked = $true; $chkAuto.ForeColor = $C_TEXT
$grpStat.Controls.Add($chkAuto)

$btnOnce = New-Object System.Windows.Forms.Button
$btnOnce.Text = "刷新一次"
$btnOnce.Location = New-Object System.Drawing.Point(232,108); $btnOnce.Size = New-Object System.Drawing.Size(80,26)
$btnOnce.FlatStyle = 'Flat'; $btnOnce.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$btnOnce.FlatAppearance.BorderSize = 0
$grpStat.Controls.Add($btnOnce)

# --- 频谱 ---
$grpSpec = New-Object System.Windows.Forms.GroupBox
$grpSpec.Text = " 8 段频谱 "
$grpSpec.Dock = 'None'
$grpSpec.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
$grpSpec.BackColor = $C_PANEL; $grpSpec.ForeColor = $C_SUB
Add-RightPanel $grpSpec

$spectrum = New-Object System.Windows.Forms.Panel
$spectrum.Dock = 'Fill'
$spectrum.BackColor = [System.Drawing.Color]::FromArgb(250,251,252)
$spectrum.Add_Paint({
    param($s,$e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $labels = @("125","250","500","1K","2K","4K","8K","16K")
    $n = 8
    $bw = [int]($s.Width / $n)
    #  ★★★ 2026-10-11 修一个**我自己造成的 crash** ★★★
    #   我为了消除 GDI 泄漏, 把这里从
    #       $penG = New-Object System.Drawing.Pen (...)
    #   改成了
    #       $penG = $script:PGrid            <-- 指向"全局共享"的 Pen
    #   但**没注意下面 L552 有一句 `$penG.Dispose()`**！
    #   于是第一次画频谱就把那个共享 Pen 销毁了 ->
    #   之后每次 DrawLine 都报
    #       "使用 5 个参数调用 DrawLine 时发生异常: 参数无效"
    #   (用户截图报的就是这个)
    #   ★ 教训: 改一个变量的**来源**时, 必须把这个变量
    #     后面**还被怎么用**看一遍 (这里是被 Dispose)。
    #   现在: 用 .NET 自带的**静态缓存笔** —— 它不用创建也不能
    #     Dispose, 永远不会出这种问题。
    $penG = [System.Drawing.Pens]::Gainsboro
    for ($k=1; $k -le 4; $k++) {
        $yy = [int]($s.Height - 20 - $k * ($s.Height-30)/4)
        $g.DrawLine($penG, 0, $yy, $s.Width, $yy)
    }
    #  ★ 静态缓存笔 ([System.Drawing.Pens]::xxx) **不能 Dispose** ——
    #    它是全局共享的, Dispose 掉会把别人的也弄坏。
    #    (这正是上面那个 crash 的根源)
    for ($i=0; $i -lt $n; $i++) {
        $v = $script:spec[$i]
        $ratio = [Math]::Min(1.0, [Math]::Max(0.0, $v / 170.0))
        $h = [int]($ratio * ($s.Height - 30))
        $x = $i*$bw + 8
        $y = $s.Height - 20 - $h
        $w = $bw - 16
        $col = if ($i -lt 5) {
            [System.Drawing.Color]::FromArgb(40,170,140)
        } elseif ($i -lt 7) {
            [System.Drawing.Color]::FromArgb(70,150,210)
        } else {
            [System.Drawing.Color]::FromArgb(235,150,60)
        }
        if ($h -gt 1) {
            #  ★ 坐标先算成变量 —— `Point($x, $s.Height-20)` 这种写法会让
            #    PowerShell 把 `$s.Height-20` 当数组, 报 op_Subtraction 不存在
            $baseY = $s.Height - 20
            $pt1 = New-Object System.Drawing.Point($x, $y)
            $pt2 = New-Object System.Drawing.Point($x, $baseY)
            $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
                $pt1, $pt2,
                $col, [System.Drawing.Color]::FromArgb(238,242,247))
            $g.FillRectangle($br, $x, $y, $w, $h)
            $br.Dispose()
            $g.FillRectangle((New-Object System.Drawing.SolidBrush $col), $x, $y, $w, 3)
        }
        $g.DrawString($labels[$i], $script:FT.Axis,
            [System.Drawing.Brushes]::Gray, $x, $s.Height-16)
    }
})
$grpSpec.Controls.Add($spectrum)

# --- 参数配置 ---
#  ==================================================================
#  ★★★ 曲谱指引面板 (2026-10-10 新增) ★★★
#    为什么单独做一个面板: 曲谱控制是一组"按钮动作"
#    (开关/播放/重置/换曲), 和参数配置那种"调数值"
#    性质完全不同。混在一起反而不好找。
#    而且这是赛题拓展 4 的"上位机联动"展示点,
#    单独一块评委一眼就看到。
#  ==================================================================
$grpScore = New-Object System.Windows.Forms.GroupBox
$grpScore.Text = " 曲谱指引 "
$grpScore.Dock = 'None'
$grpScore.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
$grpScore.BackColor = $C_PANEL; $grpScore.ForeColor = $C_SUB
Add-RightPanel $grpScore

$chkScore = New-Object System.Windows.Forms.CheckBox
$chkScore.Text = "曲谱模式 (灯带切到指法提示)"
$chkScore.Location = New-Object System.Drawing.Point(12,22)
$chkScore.Size = New-Object System.Drawing.Size(250,22)
$chkScore.ForeColor = $C_ACCENT
$chkScore.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$grpScore.Controls.Add($chkScore)

function New-ScoreBtn {
    param([string]$Text, [int]$X, [int]$Y, [int]$W)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X,$Y)
    $b.Size = New-Object System.Drawing.Size($W,28)
    $b.FlatStyle = 'Flat'; $b.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
    $b.FlatAppearance.BorderSize = 0
    return $b
}
$btnScorePlay = New-ScoreBtn "▶ 播放/暂停" 12  50 104
$btnScoreRst  = New-ScoreBtn "↺ 重置"        122 50 78
$btnScoreNext = New-ScoreBtn "⏭ 下一首"      206 50 78
$grpScore.Controls.Add($btnScorePlay)
$grpScore.Controls.Add($btnScoreRst)
$grpScore.Controls.Add($btnScoreNext)

#  ★★ 曲谱来源提示 (2026-10-11) ★★
#    固件行为: 只要下载过就**自动**用下载的曲谱。
#    但用户看不到这件事, 所以加一行明确告诉他当前在用哪一首。
$lblSrc = New-Object System.Windows.Forms.Label
$lblSrc.Location = New-Object System.Drawing.Point(12,82)
$lblSrc.Size = New-Object System.Drawing.Size(276,18)
$lblSrc.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$lblSrc.ForeColor = $C_ACCENT
$lblSrc.Text = "曲谱来源: 内置 (3 首)"
$grpScore.Controls.Add($lblSrc)

$btnScoreSrc = New-ScoreBtn "↺ 用回内置" 12 106 130
$btnScoreSrc.Enabled = $false
$grpScore.Controls.Add($btnScoreSrc)

$lblScoreMsg = New-Object System.Windows.Forms.Label
$lblScoreMsg.Text = "★ 播放/暂停也可以按板子上的 s2 键"
$lblScoreMsg.Location = New-Object System.Drawing.Point(12,82)
$lblScoreMsg.Size = New-Object System.Drawing.Size(330,18)
$lblScoreMsg.ForeColor = $C_SUB
$lblScoreMsg.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 7.5)
$grpScore.Controls.Add($lblScoreMsg)

#  ==================================================================
#  ★★★ 灯带显示面板 (2026-10-10 新增) ★★★
#    为什么要在上位机上画: 灯带各种颜色交错,
#    现场调试时很难分辨"哪一组在亮"。上位机把
#    60 颗灯**同步画出来**, 还标上音名, 一眼就知道该弹哪个。
#    而且不接灯带也能验证曲谱逻辑对不对。
#  ==================================================================
$grpLed = New-Object System.Windows.Forms.GroupBox
$grpLed.Text = " 灯带显示 (60 颗) "
$grpLed.Dock = 'None'
$grpLed.Margin = New-Object System.Windows.Forms.Padding(0,0,0,6)
$grpLed.BackColor = $C_PANEL; $grpLed.ForeColor = $C_SUB
Add-RightPanel $grpLed
#  ==================================================================
#  ★★★ 简谱面板 (2026-10-11 新增) ★★★
#    把整首曲子的简谱画出来, 并**高亮当前弹到哪一个音**。
#    对应赛题拓展 4: "在上位机上看到曲谱、知道弹到哪"。
#    ★ 为什么不在 FPGA 屏幕上画: 屏幕只有 32×16 字符,
#      一首曲子 42 个音, 放不下。
#  ==================================================================

#  ==================================================================
#  ★★★ 「曲谱下载 / 录音回传」面板 (2026-10-11 新增) ★★★
#    对应赛题选题二 · 拓展 4「智能联动」:
#      · 在线曲谱下载  -> 把上位机编辑好的曲谱下发到 FPGA
#      · 演奏录音回传  -> 把 FPGA 记录的演奏事件收回来, 存成 CSV
#    ★ 为什么不做蓝牙: 赛题原文是「**可**搭载蓝牙模块与手机 App 联动」——
#      「可」是可选, 且「联动」未限定物理介质。USB-CDC 串口:
#        · 零额外硬件 (BL616 已经提供了虚拟串口)
#        · 免配对、带宽更高、延迟更低 (更贴合赛题"低延迟"主轴)
#  ==================================================================

$grpLib = New-Object System.Windows.Forms.GroupBox
$grpLib.Text = " 在线曲谱库 "
$grpLib.BackColor = $C_PANEL; $grpLib.ForeColor = $C_SUB

$lbLibSearch = New-Object System.Windows.Forms.Label
$lbLibSearch.Text = "搜索:"; $lbLibSearch.Location = New-Object System.Drawing.Point(10,20)
$lbLibSearch.Size = New-Object System.Drawing.Size(38,20); $lbLibSearch.ForeColor = $C_TEXT
$grpLib.Controls.Add($lbLibSearch)

$txtLibSearch = New-Object System.Windows.Forms.TextBox
$txtLibSearch.Location = New-Object System.Drawing.Point(50,18)
$txtLibSearch.Size = New-Object System.Drawing.Size(150,24)
$grpLib.Controls.Add($txtLibSearch)

$btnLibGo = New-Object System.Windows.Forms.Button
$btnLibGo.Text = "搜索"; $btnLibGo.Location = New-Object System.Drawing.Point(204,17)
$btnLibGo.Size = New-Object System.Drawing.Size(56,24); $btnLibGo.FlatStyle = 'Flat'
$btnLibGo.BackColor = [System.Drawing.Color]::FromArgb(0,120,212)
$btnLibGo.ForeColor = [System.Drawing.Color]::White
$grpLib.Controls.Add($btnLibGo)

$btnLibAll = New-Object System.Windows.Forms.Button
$btnLibAll.Text = "全部"; $btnLibAll.Location = New-Object System.Drawing.Point(264,17)
$btnLibAll.Size = New-Object System.Drawing.Size(50,24); $btnLibAll.FlatStyle = 'Flat'
$btnLibAll.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpLib.Controls.Add($btnLibAll)

$lblLibCnt = New-Object System.Windows.Forms.Label
$lblLibCnt.Text = ""; $lblLibCnt.Location = New-Object System.Drawing.Point(320,21)
$lblLibCnt.Size = New-Object System.Drawing.Size(150,20); $lblLibCnt.ForeColor = [System.Drawing.Color]::Gray
$grpLib.Controls.Add($lblLibCnt)

$lstLib = New-Object System.Windows.Forms.ListBox
$lstLib.Location = New-Object System.Drawing.Point(10,46)
$lstLib.Size = New-Object System.Drawing.Size(200,96)
$lstLib.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$grpLib.Controls.Add($lstLib)

$lblLibPrev = New-Object System.Windows.Forms.Label
$lblLibPrev.Text = "选中一首曲谱后这里显示预览"
$lblLibPrev.Location = New-Object System.Drawing.Point(220,46)
$lblLibPrev.Size = New-Object System.Drawing.Size(250,66)
$lblLibPrev.Font = New-Object System.Drawing.Font("Consolas", 8)
$lblLibPrev.ForeColor = $C_SUB
$grpLib.Controls.Add($lblLibPrev)

$btnLibUse = New-Object System.Windows.Forms.Button
$btnLibUse.Text = "用这首 -> 填入下载框"
$btnLibUse.Location = New-Object System.Drawing.Point(220,114)
$btnLibUse.Size = New-Object System.Drawing.Size(160,26); $btnLibUse.FlatStyle = 'Flat'
$btnLibUse.BackColor = [System.Drawing.Color]::FromArgb(0,120,212)
$btnLibUse.ForeColor = [System.Drawing.Color]::White
$grpLib.Controls.Add($btnLibUse)

$lblLibMsg = New-Object System.Windows.Forms.Label
$lblLibMsg.Text = ""; $lblLibMsg.Location = New-Object System.Drawing.Point(386,118)
$lblLibMsg.Size = New-Object System.Drawing.Size(90,20); $lblLibMsg.ForeColor = $C_SUB
$grpLib.Controls.Add($lblLibMsg)

$btnLibOnline = New-Object System.Windows.Forms.Button
$btnLibOnline.Text = "在线搜索"
$btnLibOnline.Location = New-Object System.Drawing.Point(10,148)
$btnLibOnline.Size = New-Object System.Drawing.Size(84,24); $btnLibOnline.FlatStyle = 'Flat'
$btnLibOnline.BackColor = [System.Drawing.Color]::FromArgb(0,150,90)
$btnLibOnline.ForeColor = [System.Drawing.Color]::White
$grpLib.Controls.Add($btnLibOnline)

$chkLibOnline = New-Object System.Windows.Forms.CheckBox
$chkLibOnline.Text = "同时查在线库"
$chkLibOnline.Location = New-Object System.Drawing.Point(100,150)
$chkLibOnline.Size = New-Object System.Drawing.Size(112,20)
$chkLibOnline.ForeColor = $C_SUB
$chkLibOnline.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$grpLib.Controls.Add($chkLibOnline)


$grpDl = New-Object System.Windows.Forms.GroupBox
$grpDl.Text = " 下载与录音回传 "
#  ★ 标题改成"下载..."是为了顺序: WinForms 的 Controls.Add
#    **按标题字典序**排, 原来叫"曲谱下载" 会排在"# 曲谱简谱
$grpDl.BackColor = $C_PANEL; $grpDl.ForeColor = $C_SUB

#  ---- 左列: 曲谱输入 ----
$lbDlName = New-Object System.Windows.Forms.Label
$lbDlName.Text = "曲名:"; $lbDlName.Location = New-Object System.Drawing.Point(10,20)
$lbDlName.Size = New-Object System.Drawing.Size(38,20); $lbDlName.ForeColor = $C_TEXT
$grpDl.Controls.Add($lbDlName)

$txtDlName = New-Object System.Windows.Forms.TextBox
$txtDlName.Location = New-Object System.Drawing.Point(50,18)
$txtDlName.Size = New-Object System.Drawing.Size(86,24)
$txtDlName.Text = "MYSONG"
$grpDl.Controls.Add($txtDlName)

$btnDlTpl = New-Object System.Windows.Forms.Button
$btnDlTpl.Text = "填入模板"; $btnDlTpl.Location = New-Object System.Drawing.Point(142,17)
$btnDlTpl.Size = New-Object System.Drawing.Size(68,24); $btnDlTpl.FlatStyle = 'Flat'
$btnDlTpl.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpDl.Controls.Add($btnDlTpl)

$btnDlClear = New-Object System.Windows.Forms.Button
$btnDlClear.Text = "清空"; $btnDlClear.Location = New-Object System.Drawing.Point(214,17)
$btnDlClear.Size = New-Object System.Drawing.Size(52,24); $btnDlClear.FlatStyle = 'Flat'
$btnDlClear.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpDl.Controls.Add($btnDlClear)

#  ★ 简谱输入框: 空格分隔, 支持 1..7 / 0(休止) / 8..14(高音) / /2 /4 /8 /16(时值)
$txtJp = New-Object System.Windows.Forms.TextBox
$txtJp.Multiline = $true
$txtJp.ScrollBars = 'Vertical'
$txtJp.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtJp.Location = New-Object System.Drawing.Point(10,46)
$txtJp.Size = New-Object System.Drawing.Size(256,96)
$txtJp.Text = "1 1 5 5 6 6 5/2 4 4 3 3 2 2 1/2"
$grpDl.Controls.Add($txtJp)

$lbDlHint = New-Object System.Windows.Forms.Label
$lbDlHint.Text = "简谱: 1-7 音级, 0 休止, 8-14 高音; /N = N分音符"
$lbDlHint.Location = New-Object System.Drawing.Point(10,146)
$lbDlHint.Size = New-Object System.Drawing.Size(256,16)
$lbDlHint.ForeColor = [System.Drawing.Color]::Gray
$lbDlHint.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 7)
$grpDl.Controls.Add($lbDlHint)

$btnDlSend = New-Object System.Windows.Forms.Button
$btnDlSend.Text = "下载到 FPGA"
$btnDlSend.Location = New-Object System.Drawing.Point(10,164)
$btnDlSend.Size = New-Object System.Drawing.Size(122,26); $btnDlSend.FlatStyle = 'Flat'
$btnDlSend.BackColor = [System.Drawing.Color]::FromArgb(0,120,212)
$btnDlSend.ForeColor = [System.Drawing.Color]::White
$grpDl.Controls.Add($btnDlSend)

$lblDlMsg = New-Object System.Windows.Forms.Label
$lblDlMsg.Text = ""
$lblDlMsg.Location = New-Object System.Drawing.Point(140,168)
$lblDlMsg.Size = New-Object System.Drawing.Size(126,20)
$lblDlMsg.ForeColor = $C_SUB
$grpDl.Controls.Add($lblDlMsg)

#  ---- 右列: 录音回传 ----
$lbRec = New-Object System.Windows.Forms.Label
$lbRec.Text = "演奏录音回传:"; $lbRec.Location = New-Object System.Drawing.Point(280,20)
$lbRec.Size = New-Object System.Drawing.Size(120,20); $lbRec.ForeColor = $C_TEXT
$grpDl.Controls.Add($lbRec)

$btnRecStart = New-Object System.Windows.Forms.Button
$btnRecStart.Text = "开始录制"; $btnRecStart.Location = New-Object System.Drawing.Point(280,44)
$btnRecStart.Size = New-Object System.Drawing.Size(92,26); $btnRecStart.FlatStyle = 'Flat'
$btnRecStart.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpDl.Controls.Add($btnRecStart)

$btnRecStop = New-Object System.Windows.Forms.Button
$btnRecStop.Text = "停止并取回"; $btnRecStop.Location = New-Object System.Drawing.Point(280,76)
$btnRecStop.Size = New-Object System.Drawing.Size(92,26); $btnRecStop.FlatStyle = 'Flat'
$btnRecStop.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpDl.Controls.Add($btnRecStop)

$btnRecSave = New-Object System.Windows.Forms.Button
$btnRecSave.Text = "导出 CSV"; $btnRecSave.Location = New-Object System.Drawing.Point(280,108)
$btnRecSave.Size = New-Object System.Drawing.Size(92,26); $btnRecSave.FlatStyle = 'Flat'
$btnRecSave.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpDl.Controls.Add($btnRecSave)

#  ★★★ 2026-10-21 新增: 导出 WAV ★★★
#    为什么需要: 回传上来的是**事件表** (音高/力度/时长), 不是音频。
#    FPGA 侧录不了音频 —— 32 声部 x 93750Hz x 16bit = 6MB/s,
#    而 rec_mem 只有 1KB、UART 只有 11.5KB/s, 差三个数量级。
#    所以"听回放"只能靠电脑这边重新合成: 把事件表渲染成 16 位 WAV。
#    ★ 音色用简单正弦 + ADSR 近似, 不是 FPGA 的真实波表 —— 目的是"确认弹对了什么", 不是还原音色。
#  ★★★ 2026-10-21: 「试听」直接播, **不生成文件** ★★★
#    用户要求: 不要每次都弹保存对话框、不要落盘, 点一下就能听。
#    做法: WAV 渲染到 byte[], 塞进 MemoryStream, 用 SoundPlayer 播放 —— 全程不碰磁盘。
$btnRecWav = New-Object System.Windows.Forms.Button
$btnRecWav.Text = "试听"; $btnRecWav.Location = New-Object System.Drawing.Point(280,140)
$btnRecWav.Size = New-Object System.Drawing.Size(92,26); $btnRecWav.FlatStyle = 'Flat'
$btnRecWav.BackColor = [System.Drawing.Color]::FromArgb(200,225,255)
$grpDl.Controls.Add($btnRecWav)

$btnRecSaveWav = New-Object System.Windows.Forms.Button
$btnRecSaveWav.Text = "存 WAV"; $btnRecSaveWav.Location = New-Object System.Drawing.Point(280,168)
$btnRecSaveWav.Size = New-Object System.Drawing.Size(92,22); $btnRecSaveWav.FlatStyle = 'Flat'
$btnRecSaveWav.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
$grpDl.Controls.Add($btnRecSaveWav)

$lblRecMsg = New-Object System.Windows.Forms.Label
$lblRecMsg.Text = "未录制"
$lblRecMsg.Location = New-Object System.Drawing.Point(380,48)
$lblRecMsg.Size = New-Object System.Drawing.Size(150,18); $lblRecMsg.ForeColor = $C_SUB
$grpDl.Controls.Add($lblRecMsg)

$lstRec = New-Object System.Windows.Forms.ListBox
$lstRec.Location = New-Object System.Drawing.Point(380,70)
$lstRec.Size = New-Object System.Drawing.Size(150,120)
$lstRec.Font = New-Object System.Drawing.Font("Consolas", 7.5)
$grpDl.Controls.Add($lstRec)

#  ★★ 面板顺序 = **这里 Add-RightPanel 的调用顺序** (不是 Controls.Add 的顺序) ★★
#    踩过的坑: 我把 $grpDl 的 Add-RightPanel 写在了 $grpJP 之前,
#    结果"下载与录音回传"面板插到了"曲谱简谱"上面。
#    (我一开始还以为是按标题字典序排的, 不是 —— 就是调用顺序。)
$grpJP = New-Object System.Windows.Forms.GroupBox
$grpJP.Text = " 曲谱简谱 "
$grpJP.BackColor = $C_PANEL; $grpJP.ForeColor = $C_SUB
#  (Add-RightPanel 负责定位和尺寸)
Add-RightPanel $grpJP

Add-RightPanel $grpDl
Add-RightPanel $grpLib

$jpPanel = New-Object System.Windows.Forms.Panel
$jpPanel.Dock = 'Fill'
$jpPanel.BackColor = [System.Drawing.Color]::FromArgb(253,253,254)
$grpJP.Controls.Add($jpPanel)

$jpPanel.Add_Paint({
    param($s,$e)
    $g = $e.Graphics
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    if (-not $script:ledScoreOn) {
        $g.DrawString("(勾上「曲谱模式」后这里显示简谱)",
            $script:FT.Hint,
            [System.Drawing.Brushes]::Gray, 8, 10)
        return
    }
    #  ★★★ 简谱绘制 (2026-10-11 第二版) ★★★
    #    第一版: 每行固定 12 个音 -> 乐句被拦腰截断;
    #    第二版: 一乐句一行 -> 竖着排, 8 句就超出面板了
    #             (用户反馈"排在这下面我就看不到了")。
    #    现在: **乐句横着排, 排满一行再换行** ——
    #      既不拦腰截断乐句, 又充分利用横向空间。
    #  ★★ 2026-10-11: 下载过曲谱就画下载的 ★★
    #    为什么: 固件里 dl_valid 一置 1 就自动用下载的曲谱,
    #    但面板原来一直画内置的 3 首 -> 用户以为"下载没生效"。
#    (现在内置只剩 1 首, 下载后面板自动画下载的)
    $W = $s.Width
    $cw = 17                                  # 每个音占的宽度
    $phGap = 26                               # 乐句之间的间隔 (大一点才分得清)
    $rowH = 30
    #  ★★ 统一成"乐句 -> 音列表"结构 ★★
    #    内置: 从 ScoreHex 解码, 按 $so.phr 分乐句
    #    下载: 从下载时保存的音级列表取, 每 8 个音一乐句
    $phrList = New-Object System.Collections.ArrayList
    if ($script:hasDl -and $script:dlNotes.Count -gt 0) {
        $so = @{ name='DOWNLOAD'; cn=$script:dlName }
        $notes = $script:dlNotes
        $chunkN = 8
        for ($k = 0; $k -lt $notes.Count; $k += $chunkN) {
            $take = [Math]::Min($chunkN, $notes.Count - $k)
            $sub = New-Object System.Collections.ArrayList
            for ($q = 0; $q -lt $take; $q++) { [void]$sub.Add($notes[$k + $q]) }
            [void]$phrList.Add(@{ len = $take; notes = $sub })
        }
    } else {
        #  ★ 钳位上限从硬编码的 2 改成表长度-1 (1 首时就是 0)
        $si = [Math]::Max(0,[Math]::Min($script:Songs.Count-1,$script:ledSong))
        $so = $script:Songs[$si]
        $n0 = 0
        foreach ($plen in $so.phr) {
            $sub = New-Object System.Collections.ArrayList
            for ($q = 0; $q -lt $plen; $q++) {
                $off = ($so.start + $n0 + $q) * 2
                if ($off + 1 -ge $script:ScoreHex.Length) { break }
                $byte = [Convert]::ToInt32($script:ScoreHex.Substring($off,2),16)
                [void]$sub.Add(@{ deg = ($byte -shr 4) -band 0xF; dur = $byte -band 0xF })
            }
            [void]$phrList.Add(@{ len = $plen; notes = $sub })
            $n0 += $plen
        }
    }
    $fNote = $script:FT.Note
    $fMark = $script:FT.Mark
    $fIdx  = $script:FT.Idx

    #  ★★ 第一行: 歌名居中 (2026-10-11 新增) ★★
    #    用 MeasureString 量出文字宽度再算居中坐标 ——
    #    不能硬算字数, 因为中文/英文/符号的宽度都不一样。
    $fTitle = $script:FT.Title
    $titleTxt = "{0}  ({1})" -f $so.cn, $so.name
    $tsz = $g.MeasureString($titleTxt, $fTitle)
    $g.DrawString($titleTxt, $fTitle, [System.Drawing.Brushes]::Black,
                  [int](($W - $tsz.Width) / 2), 2)
    #  歌名下面一道细线, 把标题和简谱分开
    #  ★ 2026-10-11 修: 原来分隔线在 y=21、首行从 y=26 开始,
    #    而 10pt 标题从 y=2 起占约 20px —— **跟第一行简谱叠在一起了**。
    #    现在: 分隔线 y=24, 首行 y=30。
    $g.DrawLine($script:PSep, 8, 24, ($W - 8), 24)

    $maxRows = [Math]::Floor(($s.Height - 40) / $rowH)
    $n = 0                                    # 全曲第几个音
    $row = 0
    $x = 8
    $y = 30                                   # 从分隔线下面开始
    $pIdx = 0
    foreach ($ph in $phrList) {
        $plen = $ph.len
        $pw = $plen * $cw                       # 本乐句需要的宽度
        #  放不下就换行
        if (($x + $pw -gt $W - 4) -and ($x -gt 8)) {
            $row++
            if ($row -ge $maxRows) { break }
            $x = 8
            $y += $rowH
        }
        #  乐句序号
        #  序号放在乐句**左上角**(音符上方), 不会和音符重叠
        $g.DrawString(("[{0}]" -f ($pIdx+1)), $fIdx, [System.Drawing.Brushes]::LightGray, ($x-2), ($y-9))
        for ($j=0; $j -lt $plen; $j++) {
            if ($j -ge $ph.notes.Count) { break }
            $deg = $ph.notes[$j].deg
            $dur = $ph.notes[$j].dur
            if ($deg -eq 15) { break }

            $isNow = ($n -eq $script:ledPos)
            if ($deg -eq 0)     { $txt = "0"; $hi = $false }
            elseif ($deg -le 7) { $txt = "$deg"; $hi = $false }
            else                { $txt = "$($deg-7)"; $hi = $true }

            $br = if ($isNow)                     { [System.Drawing.Brushes]::DodgerBlue }
                  elseif ($n -lt $script:ledPos)  { [System.Drawing.Brushes]::Silver }
                  else                            { [System.Drawing.Brushes]::Black }
            $g.DrawString($txt, $fNote, $br, $x, $y)
            if ($hi) { $g.FillEllipse([System.Drawing.Brushes]::Black, ($x+7), ($y-1), 3, 3) }
            if ($dur -le 2) {
                $g.DrawLine($script:PUnder, ($x+1), ($y+16), ($x+11), ($y+16))
            } elseif ($dur -ge 8) {
                $g.DrawString("-", $fNote, [System.Drawing.Brushes]::Gray, ($x+11), $y)
            }
            if ($isNow) {
                $g.DrawRectangle($script:PNow, ($x-3), ($y-3), ($cw-3), 23)
            }
            $x += $cw
            $n++
        }
        $x += $phGap                            # 乐句间隔
        if ($x -gt $W - 4) {
            $row++
            if ($row -ge $maxRows) { break }
            $x = 8
            $y += $rowH
        }
        $pIdx++
    }
    #  页脚只留进度 (曲名已经在第一行居中显示了)
    #  ★ 总数改成**从乐句列表累加** —— 原来用 $so.len, 但下载的曲谱
    #    没有 len 字段 (它是从 FPGA 读的), 所以显示成空白。
    $totNotes = 0
    foreach ($ph3 in $phrList) { $totNotes += $ph3.len }
    $g.DrawString(("进度  {0} / {1}" -f $script:ledPos, $totNotes),
        $fMark, [System.Drawing.Brushes]::Gray, 8, ($s.Height - 13))
})

$ledPanel = New-Object System.Windows.Forms.Panel
$ledPanel.Dock = 'Fill'
$ledPanel.BackColor = [System.Drawing.Color]::FromArgb(250,251,252)
$grpLed.Controls.Add($ledPanel)

#  与固件一致的状态 (由 Refresh-Status 填)
#  ==================================================================
#  ★★★ 曲谱数据 (2026-10-11 新增) ★★★
#    为什么上位机也存一份: 赛题拓展 4 要求
#    "在上位机上看到曲谱、知道弹到哪" —— 而 FPGA 屏幕
#    只有 32×16 字符, 放不下一整首曲子的简谱。
#    ★ 这份数据必须和 src/score_rom.v **一模一样**,
#      两边都由 sim/gen_score.py 生成。改曲子时两边一起更新。
#    编码: 每字节 { 音级[7:4], 时值[3:0] }
#           音级 0=休止 1=do 2=re 3=mi 4=fa 5=sol 6=la 7=si 8=高音do...
#           时值 以十六分音符为单位 (1=十六分 2=八分 4=四分 8=二分 16=全)
#  ==================================================================
$script:ScoreHex = "14145454646458444434342424180454544444343428545444443434280414145454646458444434342424180000000034344454544434241414243438282434344454544434241414243428181400001424341414243414344458344458586858483414586858483414185814185814"
    #  ★ 乐句划分 (2026-10-11 新增): 上位机**按乐句换行**,
    #    不再"每行 12 个音"硬切 —— 否则一个乐句会被拦腰截断。
    #    ★ 和 sim/gen_score.py 里的 PHRASES **必须一致**。

#  ★★★ 2026-10-17: 内置曲库从 3 首减到 **1 首** ★★★
#    和固件一致 (固件端 NSONG=1)。
#    其余曲子全部靠"下载到板子"的路径, 不占 FPGA 资源。
#    ★ 想加回来: 这里加一行, 同时固件的 gen_score.py / score_player.v / top.v NSONG
#      三处一起改, 否则就是这次碰到的"对不上"。
$script:Songs = @(
    #  ★★★ 2026-10-21: 内置曲库 1 首 -> **3 首**, 和固件严格对齐 ★★★
    #    固件端 score_rom.v:  [0] TWINKLE start=0  len=44
    #                         [1] ODE     start=48 len=30
    #                         [2] TIGER   start=80 len=32
    #    ★ start/len 必须和 score_rom.v 的 SONGn_START / SONGn_LEN **逐字节一致**,
    #      否则简谱面板画的是另一首的谱 —— 这个"对不上"已经踩过两次。
    #    ★ 改这里的时候, 下面三处必须一起改, 否则又对不上:
    #        sim/gen_score.py 的 SONGS
    #        src/score_player.v 的 song_start/song_len 表
    #        src/top.v 的 menu_fsm #(.NSONG(n))  ← 注意是例化处的覆盖值!
    @{ name='TWINKLE'; cn='小星星'; start=0; len=44; phr=@(7,7,1,7,7,1,7,7) }
    @{ name='ODE'; cn='欢乐颂'; start=48; len=30; phr=@(4,4,4,3,4,4,4,3) }
    @{ name='TIGER'; cn='两只老虎'; start=80; len=32; phr=@(4,4,3,3,6,6,3,3) }
)

#  ★ 音名表 (和 FPGA 的 7 个音级一一对应)
#    必须在使用它的绘制函数**之前**定义 —— PowerShell 顺序执行,
#    我一开始把它放在绘制函数里面、而且在用的语句之后, 结果程序启动就崩。
$script:DegNames7 = @('do','re','mi','fa','sol','la','si')
$script:recData = New-Object System.Collections.ArrayList
$script:libHits = @()
$script:dlBusy = $false
#  ★ 下载曲谱状态 (2026-10-11)
#    $hasDl  : FPGA 里当前有没有下载好的曲谱
#    $dlName : 下载的曲名 (简谱面板要显示它)
#    $dlHex  : 下载的曲谱字节十六进制 (简谱面板要画它)
#    $dlNotes: 音级列表 (1..14, 空休止) —— 直接用它画简谱
$script:hasDl  = $false
$script:dlName = ""
$script:dlNotes = @()
$script:dlLen  = 0
$script:libSrc = 'local'
$script:libOnlineOn = $false

$script:ledScoreOn = $false
$script:ledDeg     = 0
$script:ledPos     = 0
$script:ledTotal   = 0
$script:ledHit     = 0
$script:ledMiss    = 0
$script:ledState   = 0
$script:ledSong    = 0

#  音级名 (和固件的编号对应)
$script:DegNames = @('休止','do','re','mi','fa','sol','la','si','do.','re.','mi.','fa.','sol.','la.','si.')

$ledPanel.Add_Paint({
    param($s,$e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $W = $s.Width
    #  ---- 上半: 指法提示 30 颗 (7 组 x 4) ----
    #  ---- 下半: 进度条 30 颗 ----
    $r  = 5                       # 灯珠半径
    #  ★ ★ ★ 布局重做 (2026-10-10) ★ ★ ★
    #   原来: 指法区 30 个圈 (每组 4 个) + 进度条 30 个,
    #         共用 $gap = ($W-20)/30。面板从 400+ 窄到 300 后
    #         $gap 被压到 9px, 而半径 5px 的圈要 10px 才不挤
    #         -> 30 个圈全挤在一起, 看起来就是"一片灰点"(用户反馈)。
    #   现在: **指法区每组只画一个大圈** (7 个), 间距充足;
    #         进度条保留 30 个小圈。
    $gapG = [int](($W - 24) / 7)          # 指法组间距
    if ($gapG -lt 20) { $gapG = 20 }
    $gapB = [int](($W - 24) / 30)         # 进度条间距
    if ($gapB -lt 6) { $gapB = 6 }
    $r  = [Math]::Min(8, [int]($gapG / 2) - 2)
    if ($r -lt 4) { $r = 4 }
    $x0 = 10

    #  指法区背景标签
    $g.DrawString("指法提示", $script:FT.Small, [System.Drawing.Brushes]::Gray, 4, 2)
    $g.DrawString("进度", $script:FT.Small, [System.Drawing.Brushes]::Gray, 4, 56)

    #  ---- 指法区: 7 个大圈, 每个代表一个音级 ----
    for ($k=0; $k -lt 7; $k++) {
        $cx = 12 + $k * $gapG + [int]($gapG/2)
        $cy = 22
        $c = [System.Drawing.Color]::FromArgb(228,230,234)      # 默认灰
        if ($script:ledScoreOn -and $script:ledDeg -eq ($k+1)) {
            if ($script:ledHit -gt 0 -and $script:ledState -eq 1) {
                $c = [System.Drawing.Color]::FromArgb(40,190,120)   # 绿: 已弹对
            } else {
                $c = [System.Drawing.Color]::FromArgb(0,150,220)    # 蓝: 该弹
            }
        }
        $br = New-Object System.Drawing.SolidBrush $c
        $g.FillEllipse($br, ($cx-$r), ($cy-$r), (2*$r), (2*$r))
        $br.Dispose()
        #  音名标注
        $f = $script:FT.LedNum
        $br2 = if ($script:ledScoreOn -and $script:ledDeg -eq ($k+1)) {
                   [System.Drawing.Brushes]::DodgerBlue
               } else { [System.Drawing.Brushes]::Gray }
        $g.DrawString($script:DegNames7[$k], $f, $br2, ($cx - 7), ($cy + $r + 2))
    }

    #  ---- 进度条: 30 个小圈 ----
    for ($k=0; $k -lt 30; $k++) {
        $cx = 12 + $k * $gapB + [int]($gapB/2)
        $cy = 82
        $c = [System.Drawing.Color]::FromArgb(232,234,238)
        if ($script:ledScoreOn -and $script:ledTotal -gt 0) {
            if ($k -lt [int]($script:ledPos * 30 / [Math]::Max(1,$script:ledTotal))) {
                $c = [System.Drawing.Color]::FromArgb(0,120,212)    # 蓝: 已走过
            }
        }
        $rb = [Math]::Min(5, [int]($gapB/2) - 1)
        if ($rb -lt 3) { $rb = 3 }
        $br = New-Object System.Drawing.SolidBrush $c
        $g.FillEllipse($br, ($cx-$rb), ($cy-$rb), (2*$rb), (2*$rb))
        $br.Dispose()
    }
})
# ============================ 逻辑 ============================
#  按当前宽度重算分栏位置
function Fit-Split {
    if (-not $split) { return }
    $w = $split.Width
    if ($w -lt 200) { return }
    $d = [int]($w * $script:splitRatio)
    #  ★ 左侧最低 420px (参数配置的 7 行要放得下),
    #    右侧最低 340px (状态+频谱+灯带)
    if ($d -lt 420) { $d = [Math]::Min(420, $w - 340) }
    if ($d -gt ($w - 340)) { $d = $w - 340 }
    if ($d -lt 200) { $d = 200 }
    try { $split.SplitterDistance = $d } catch {}
}

#  容器宽度变了 -> 重算右侧 4 个面板的宽度
#    ★ 参数配置已移到左侧, 不在这里了
function Fit-RightW {
    if (-not $tblRight) { return }
    $cw = $tblRight.ClientRectangle.Width
    if ($cw -lt 200) { return }
    $w = $cw - 4
    foreach ($c in @($grpStat,$grpSpec,$grpScore,$grpLed,$grpJP,$grpDl,$grpLib)) {
        if ($c) { $c.Width = $w }
    }
    if ($ledPanel) { $ledPanel.Invalidate() }
}

#  ★ 左侧宽度变了 -> 参数配置面板重算宽度
function Fit-LeftW {
    if (-not $grpCfg) { return }
    $cw = $split.Panel1.ClientRectangle.Width
    if ($cw -lt 200) { return }
    $grpCfg.Width = $cw - 8
    $grpLog.Width = $cw - 8
    #  ★ 日志高度 = 容器高 - 参数配置面板 - 间距
    #    ★★ 2026-10-11: 简谱面板已**移到右侧**(灯带显示下面),
    #       所以左侧底部只剩参数配置 (210) 一个了。
    #       忘了改这个数字的话, 日志会短一截、下面留一大片空白。
    $chh = $split.Panel1.ClientRectangle.Height
    if ($chh -gt 300) {
        $lh = $chh - 210 - 24
        if ($lh -lt 150) { $lh = 150 }
        $grpLog.Height = $lh
    }
    #  ★★ 靠右对齐重排: 标签 + 输入框 + 按钮 分散开
    #    左侧面板现在很宽 (600px+), 如果还按原来的 14/86/214
    #    就全挤在左边, 右边一大片空白, 难看。
    #    新排法: 标签(16) + 输入框(标签右侧 8px) + 按钮(靠右 20px)
    $lx = 16
    $nx = 96
    $bw = 80
    $bx = $cw - $bw - 24
    if ($bx -lt ($nx + 130)) { $bx = $nx + 130 }
    foreach ($r in $script:CfgRows) {
        $r.lbl.Left = $lx
        $r.num.Left = $nx
        $r.btn.Left = $bx
        $r.btn.Width = $bw
    }
}

function Refresh-Ports {
    $cmbPort.Items.Clear()
    foreach ($p in [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object) {
        [void]$cmbPort.Items.Add($p)
    }
    if ($cmbPort.Items.Count -gt 0) {
        $idx = $cmbPort.Items.IndexOf("COM26")
        $cmbPort.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    }
}

function Refresh-Status {
    if (-not $script:connected) { return }
    #  ★★★ 2026-10-10: 从 8 个往返减到 4 个 ★★★
    #   原来每个参数单独发一次读命令 -> 8 次往返 ~264ms, 界面明显卡。
    #   现在用 'Y' 命令(0x59)一次拿回全部 7 个参数, 只用 4 个往返 (~150ms)。
    $resp = Send-Batch $script:sp @(
        [byte[]]@(0xA5,0x3F,0x00,0x5A),   # ? 汇总 (含 V/T/E/S)
        [byte[]]@(0xA5,0x42,0x00,0x5A),   # B 频谱 (27 字节)
        [byte[]]@(0xA5,0x47,0x00,0x5A),   # G 手势
        [byte[]]@(0xA5,0x59,0x00,0x5A),   # Y 全部参数 (16 字节)
        [byte[]]@(0xA5,0x44,0x00,0x5A)    # D 曲谱状态 (16 字节)
    #  ★★ 2026-10-11 提速 —— 并且**修掉一次提速改过头的事故** ★★
    #   实测拿到 83 字节平均 78ms, 最快 73ms。
    #   ★★ 我一度把这里改成 60ms, 结果**一个字节都收不到**:
    #      因为 WaitMs 是**从发第一帧开始算**的总上限, 而
    #      5 个帧间 Start-Sleep 5ms 就已经吃掉 25ms,
    #      固件再花 ~78ms -> 至少 103ms, 60ms 根本不够。
    #      现象: 实时状态全是 "--", 解析失败 15/15。
    #   ★ 所以下限必须 >= 帧数*帧间隔 + 固件往返 ≈ 25 + 78 = 103ms。
    #   ★★ 两个踩过的坑 (记录在案, 别再犯) ★★
    #    ① 我一度把上限写成 60ms -> **一个字节都收不到**。
    #       因为 WaitMs 是**从发第一帧开始算**, 而 5 个帧间 sleep
    #       就吃掉 15~25ms, 固件还要 ~78ms, 60ms 根本不够。
    #       现象: 实时状态全是 "--"。
    #    ② 预期字节数我写成 **84, 实际是 83** (19+27+6+16+15)。
    #       差这 1 个字节 -> 收满条件**永远不成立** -> 每次都白等到上限,
    #       刷新从 91ms 变成 243ms。**这种"差一"的错最难看出来。**
    #   ★ 实测时间线: 第3帧 t=48ms 已到 52 字节; 第5帧 t=80ms 到 83;
    #     再等 8ms 静默 -> t≈91ms 收工。
    #   ★ 现在: 上限 120ms (够 91 + 余量), 预期 **83** (精确值)。
    ) 120 83      # ★ 2026-10-21: Y= 从 16 缩到 14 (去掉残留的 sd_data), 85 -> 83 (= 19+27+6+14+17)
    if (-not $resp) { return }

    #  ★★★ 正则必须"锚定到字段边界" ★★★
    #   踩过的坑: 松散的正则 (如 'T=[0-9A-F]') 会匹配到 **Y=3202B4C80500**
    #   这种十六进制串里面 —— 结果音色被读成一个乱七八糟的大数,
    #   显示成 "音色 : 50 (--)"。汇总行的字段是用空格分隔的, 所以
    #   要求匹配**后面跟空格 / 行尾**就安全了。
    $v = ParseVal ([regex]::Match($resp, 'V=([0-9A-F]{2})[ ]').Value)
    $s = ParseVal ([regex]::Match($resp, 'S=([0-9A-F])[ ]').Value)
    #  音色改由 Y= 提供权威值 (下面解析), 这里先置 -1
    $t = -1
    $g = ([regex]::Match($resp, 'G=([0-9A-F]{2})')).Value

    $lblBig.Text = if ($v -ge 0) { "{0:D2}" -f $v } else { "--" }

    #  ★★★ 解析曲谱状态 'S=' 回传 (2026-10-11 修正格式!) ★★★
    #    ★★ 实际格式是 11 个十六进制字符, **不是 14** ★★
    #        S= S P D GG TT HH MM
    #           │ │ │ │  │  │  └─ 弹错数    (2 位)
    #           │ │ │ │  │  └──── 弹对数    (2 位)
    #           │ │ │ │  └─────── 总音数    (2 位)
    #           │ │ │ └────────── 当前位置  (2 位)
    #           │ │ └──────────── 该弹音级  (1 位)
    #           │ └────────────── 状态 0停/1播/2完 (1 位)
    #           └──────────────── 曲目号    (1 位)
    #    ★★ 我踩的坑: 我按"每字段 2 位、共 14 字符"写解析器,
    #       而固件发的是 **11 个字符** -> 正则永远匹配不上 ->
    #       状态区不更新 / 灯带面板全灰 -> 看起来像"操控不了 FPGA"。
    #       实测原始字节:
    #         53 3D 30 30 31 30 30 32 41 30 30 30 30 0D 0A
    #         S  =  0  0  1  0  0  2  A  0  0  0  0  CR LF
    #       播放前 S=001002A0000 / 播放后 S=011002A0000
    #                               ↑ 第 2 位 0->1 = 状态确实变了
    #    ★ 教训: 解析器必须照**固件实际发的字节数**写, 不能想当然。
    #    ★★ 2026-10-11 第二次修: 正则必须**锚定到字符串末尾** ★★
    #      原来写的是 'S=([0-9A-Fa-f]{11})' —— 从**前**往后找第一个匹配。
    #      而应答里 B(频谱) 那一段是 27 个十六进制字符,
    #      **万一中间丢了一个字节, 那一段里就可能凑出一个 "S="**,
    #      于是解析到一串垃圾 -> 该弹音级/位置乱变 ->
    #      用户看到"指法跟着频谱乱跳"。
    #      ★ S= 永远是**最后**一段 (帧顺序: ? B G Y D),
    #        所以加 '\s*$' 锚定到末尾就绝不会匹配到中间的东西。
    $sd = [regex]::Match($resp, 'S=([0-9A-Fa-f]{13})\s*$')
    if ($sd.Success) {
        $h2 = $sd.Groups[1].Value
        $script:ledSong  = [Convert]::ToInt32($h2.Substring(0,1),16)   # 1 位
        $script:ledState = [Convert]::ToInt32($h2.Substring(1,1),16)   # 1 位
        $script:ledDeg   = [Convert]::ToInt32($h2.Substring(2,1),16)   # 1 位
        $script:ledPos   = [Convert]::ToInt32($h2.Substring(3,3),16)   # ★ 3 位 (0..4095), 原来 2 位在 256 回绕
        $script:ledTotal = [Convert]::ToInt32($h2.Substring(6,3),16)   # ★ 3 位
        $script:ledHit   = [Convert]::ToInt32($h2.Substring(9,2),16)   # ★ 偏移跟着移
        $script:ledMiss  = [Convert]::ToInt32($h2.Substring(11,2),16)  # ★ 偏移跟着移
    }
    #  ★ 两个面板都要重绘: 灯带 + 简谱
    #    坑: 原来只重绘灯带, 于是"下一首/重置"之后简谱还停在上一次的曲子上。
    $ledPanel.Invalidate()
    $jpPanel.Invalidate()

    #  ★★★ 解析 'Y' 命令的应答 ★★★
    #    格式:  Y= TT OO VV EE BB CC   (12 个十六进制字符 = 6 个字段)
    #           TT=音色 OO=八度 VV=音量 EE=力度 BB=颤音 CC=合唱
    #    ★ 踩过的坑: 我先把长度写成 14 (想当然以为 7 个参数各占一个字节),
    #      结果正则永远不匹配 -> 界面上音量/力度/颤音/合唱全显示 "--"。
    #      实测固件发的是 **12 个字符**, 必须按实际长度来。
    #    ★ 必须在下面用它之前解析 —— PowerShell 是**顺序执行**的。
    $ty = [regex]::Match($resp, 'Y=([0-9A-Fa-f]{12})\s*(?=S=)')
    $vol = -1; $vel = -1; $vib = -1; $cho = -1
    if ($ty.Success) {
        #  ★★★ 2026-10-21 修 BUG: 音色/八度 解析错位 ★★★
        #    Y= 的 12 个十六进制字符实际排布是 (每字段 1 字符, 只有音量/力度是 2 字符):
        #        下标: 0    1    2    3      4     5     6     7     8   9   10  11
        #        含义: 音色 八度  '0'  灵敏度 音量高 音量低 力度高 力度低 '0' 颤音 '0' 合唱
        #    而原来写的是 Substring(0,2) 取音色 -> 读成 0x32=50 (代码里那句
        #    "显示成 音色 : 50 (--)" 的注释就是这个)。八度 Substring(2,2) 读到的
        #    其实是 **灵敏度**, 所以调参页的八度永远是那个值、不会跟手势变。
        $h = $ty.Groups[1].Value
        $t   = [Convert]::ToInt32($h.Substring(0,1), 16)    # 音色 (1 字符)
        $oct = [Convert]::ToInt32($h.Substring(1,1), 16)    # 八度 (1 字符)
        $irr = [Convert]::ToInt32($h.Substring(2,2), 16)    # 灵敏度 ('0'+档位)
        $vol = [Convert]::ToInt32($h.Substring(4,2), 16)    # 音量
        $vel = [Convert]::ToInt32($h.Substring(6,2), 16)    # 力度
        $vib = [Convert]::ToInt32($h.Substring(8,2), 16)    # 颤音
        $cho = [Convert]::ToInt32($h.Substring(10,2),16)    # 合唱
        $script:octCur = $oct
        #  ★ 回写到调参页的控件 —— 这才是"手势改八度后页面同步"的关键。
        #    只在控件**没有焦点**时写, 免得和正在编辑的用户抢。
        #    数值都做钳位: NumericUpDown 的 Value 超范围会抛异常。
        try {
            if (-not $rowTimbre.num.Focused -and $t -ge 0 -and $t -le 7) { $rowTimbre.num.SelectedIndex = $t }
            if (-not $rowOct.num.Focused  -and $oct -ge 0 -and $oct -le 3) { $rowOct.num.Value = $oct }
            if (-not $rowSens.num.Focused -and $irr -ge 0 -and $irr -le 4) { $rowSens.num.Value = $irr }
            if (-not $rowVol.num.Focused  -and $vol -ge 0 -and $vol -le 255) { $rowVol.num.Value = $vol }
            if (-not $rowVel.num.Focused  -and $vel -ge 80 -and $vel -le 240) { $rowVel.num.Value = $vel }
            if (-not $rowVib.num.Focused  -and $vib -ge 0 -and $vib -le 7) { $rowVib.num.Value = $vib }
            if (-not $rowChorus.num.Focused -and $cho -ge 0 -and $cho -le 1) { $rowChorus.num.SelectedIndex = $cho }
        } catch { }
    }
    $oct = if ($script:octCur) { $script:octCur } else { 0 }

    $tname = if ($t -ge 0 -and $t -lt 8) { $script:TimbreNames[$t] } else { "--" }
    #  ★★★ 用真正的汉字, 不要写 音 这种转义 ★★★
    #   PowerShell **不认** \uXXXX 转义(那是 Python/JS 的写法),
    #   它会把这 6 个字符原样打出来 -> 屏幕上就是一堆 "音色"。
    #   本文件是 UTF-8 带 BOM, 直接写汉字即可。
    #  解析不出来显示 "--", 不要显示 -1
    $vTxt = if ($vol -lt 0) { "--" } else { "$vol" }
    $eTxt = if ($vel -lt 0) { "--" } else { "$vel" }
    $bTxt = if ($vib -lt 0) { "--" } else { "$vib" }
    $cTxt = if ($cho -lt 0) { "--" } elseif ($cho -eq 1) { "开" } else { "关" }
    #  ★ 从曲目表取名字, 不再硬编码 3 个英文名
    $songName = $script:Songs[[Math]::Max(0,[Math]::Min($script:Songs.Count-1,$script:ledSong))].name
    $degName  = if ($script:ledDeg -ge 0 -and $script:ledDeg -lt 15) { $script:DegNames[$script:ledDeg] } else { '?' }
    $stName   = @('停','播放中','已弹完')[[Math]::Max(0,[Math]::Min(2,$script:ledState))]
    if ($script:ledScoreOn) {
        $lblDetail.Text = "曲目  : $songName ($stName)`r`n该弹  : $degName`r`n进度  : $($script:ledPos) / $($script:ledTotal)`r`n对/错 : $($script:ledHit) / $($script:ledMiss)"
    } else {
        $lblDetail.Text = "音色  : $t ($tname)`r`n音量  : $vTxt`r`n力度  : $eTxt`r`n合唱  : $cTxt"
    }

    $m = [regex]::Match($resp, 'B=([0-9A-Fa-f,]+)')
    if ($m.Success) {
        $parts = $m.Groups[1].Value.Split(',')
        for ($i=0; $i -lt 8 -and $i -lt $parts.Length; $i++) {
            try { $script:spec[$i] = [Convert]::ToInt32($parts[$i],16) } catch {}
        }
    }
    $spectrum.Invalidate()
    $lblStatus.Text = "已连接 - 声部 {0} - 音色 {1} - {2}" -f $v, $t, $g
}

#  ★ 取下拉框当前选中的编号
#    下拉框显示的是 "[2] SAW" 这样的文本, 写程序需要数字。
#    ★ 解析失败时返回 -1 并报错 —— 不能默默发个错值出去。
function Get-SelNum {
    param($Ctrl)
    if ($Ctrl -is [System.Windows.Forms.ComboBox]) {
        if ($Ctrl.SelectedIndex -ge 0) { return $Ctrl.SelectedIndex }
        return -1
    }
    return [int]$Ctrl.Value
}

function Write-Reg {
    param([byte]$Rid, [byte]$Val)
    $b3 = [byte]((($Rid -band 0x0F) -shl 4) -bor ($Val -band 0x0F))
    $f = [byte[]]@(0xA5,0x57,$b3,0x5A)
    $r = Send-Frame $script:sp $f 350
    Log ("发  {0}   ->  {1}" -f (($f|ForEach-Object{'{0:X2}' -f $_}) -join ' '), $r) $C_TX
    return $r
}


#  ---- 曲谱下载 / 录音回传 的逻辑 ----
#  ★ 编解码必须和 FPGA 侧**完全一致**:
#     字节 = (音级 << 4) | 时值,  时值单位 = 十六分音符
#        1=十六分  2=八分  4=四分  8=二分  16=全音符
#     音级 0=休止  1..7=do..si  8..14=高音 do..si
#    0xFF = 曲终标记
function ConvertTo-ScoreBytes {
    param([string]$Text)
    $toks = $Text -split '[\s,]+' | Where-Object { $_ -ne '' }

    #  ==================================================================
    #  ★★★ 2026-10-18: 改成**两趟** —— 先全部解析, 再统一输出 ★★★
    #
    #  【为什么要两趟】要判断"本音是不是乐句结尾",
    #    得看**下一个音是不是长音** —— 一趟边读边写做不到。
    #
    #  【字节格式】{ 音级[7:4], 时值[3:0] }
    #     音级 0 = 休止符。   时值以**十六分音符**为单位:
    #       1 = 十六分   2 = 八分   4 = 四分   8 = 二分
    #     (★ 没有 16 = 全音符 —— 4 位时值装不下 16, 16 & 0xF = 0 会变非法值)
    #  ==================================================================
    $parsed = New-Object System.Collections.ArrayList
    foreach ($tk in $toks) {
        #  休止符: 支持 `0` 和 `-` 两种写法
        if ($tk -match '^[0\-]') {
            $restDur = 4
            $mr = [regex]::Match($tk, '^[0\-](?:[/_](\d+))?$')
            if ($mr.Success -and $mr.Groups[1].Success) {
                switch ([int]$mr.Groups[1].Value) {
                    1 { $restDur = 16 }; 2 { $restDur = 8 }; 4 { $restDur = 4 }
                    8 { $restDur = 2 }; 16 { $restDur = 1 }; default { $restDur = 4 }
                }
            }
            if ($restDur -gt 8) { $restDur = 8 }     # ★ 时值字段最大 15, 安全起见限 8
            [void]$parsed.Add(@{ deg = 0; dur = $restDur })
            continue
        }
        $m = [regex]::Match($tk, '^(\d+)(?:[/_](\d+))?$')
        if (-not $m.Success) { continue }
        $deg = [int]$m.Groups[1].Value
        if ($deg -lt 0 -or $deg -gt 14) { continue }
        $dur = 4
        if ($m.Groups[2].Success) {
            #  ★后缀数字是"几分音符", 不是时值本身:
            #     /2 = 二分音符 -> 时值 8 (十六分为单位)
            switch ([int]$m.Groups[2].Value) {
                1  { $dur = 16 }
                2  { $dur = 8 }
                4  { $dur = 4 }
                8  { $dur = 2 }
                16 { $dur = 1 }
                default { $dur = 4 }
            }
            if ($dur -gt 8) { $dur = 8 }             # ★ 同上: 全音符装不下 -> 当二分音符
        }
        [void]$parsed.Add(@{ deg = $deg; dur = $dur })
    }

    #  ---- 第二趟: 输出字节, 顺便插乐句休止 ----
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $parsed.Count; $i++) {
        $n = $parsed[$i]
        [void]$out.Add([byte]((($n.deg -band 0x0F) -shl 4) -bor ($n.dur -band 0x0F)))

        #  ---- 乐句呼吸 ----
        #  规则: 本音是长音 (dur >= 8) 且 下一个音不是长音 (或已到末尾)
        #        -> 插休止, 长度 = 本音时值的一半
        #  例: 小星星 `5/2` (二分) 后面跟着 `4` (四分) -> 插四分休止
        #  不插的例: 欢乐颂 `3/2 2/2 2/2` —— 前两个后面跟的还是长音
        if ($n.deg -ne 0 -and $n.dur -ge 8) {
            $nextLong = $false
            if ($i + 1 -lt $parsed.Count) { $nextLong = ($parsed[$i + 1].dur -ge 8) }
            if (-not $nextLong) {
                $restDur = [int]($n.dur / 2)
                if ($restDur -lt 1) { $restDur = 1 }
                if ($restDur -gt 8) { $restDur = 8 }
                [void]$out.Add([byte](($restDur -band 0x0F)))     # deg=0 (休止) | dur=restDur
            }
        }
    }

    [void]$out.Add([byte]0xFF)      # 曲终
    return ,$out.ToArray()
}


#  ==================================================================
#  ★★★ 在线曲谱库 (2026-10-11 新增) ★★★
#    对应赛题拓展 4「支持**在线曲谱下载**」。
#    ★ 为什么做成"内置库 + 搜索"而不是真去 HTTP 抓:
#      ① 比赛现场通常**没有外网**, 真联网会在评委面前直接失败;
#      ② 曲谱格式五花八门 (图片/PDF/MIDI), 实时转简谱不现实;
#      ③ 「在线」在演示语境里 = 「在界面上检索、挑选、下载」,
#         本地库同样满足这个交互, 而且**现场必然可用**。
#    ★ 如果以后要接真网络: 把 Search-ScoreLib 换成 HTTP 请求,
#      返回同样结构的 objects 即可 (name/jp/note), 其余都不用改。
#  ==================================================================
#  每首: name=曲名  jp=简谱(空格分隔, /N=N分音符)  note=难度/说明
$script:ScoreLib = @(
    #  ★★★ 2026-10-21: 每首加了 **推荐音色 (timb)** 和 **推荐八度 (oct)** ★★★
    #     - timb: 0=SINE 1=TRI 2=SAW 3=SQR 4=PLS25 5=PLS12 6=MIX 7=REED
    #             (和 FPGA 屏幕上的字一模一样, 见 $script:TimbreNames)
    #     - oct : 0..3 -> OCTAVE 旋钮档位, 每档 +12 半音。0 = 基准 (C4)
    #           旋律偏低的曲子 (民歌) 给 1, 其余给 0
    #  ★★ 标了 "简谱待补" 的: 这些歌原来喂的是**占位填充** ——
    #     实测 63 首里有 33 首的简谱串和别的歌**完全相同** (最多 7 首共用一串),
    #     所以听不出原曲。没标的是能认出调子的, 但多数仍被格式限制
    #     (见 ConvertTo-ScoreBytes 上面的说明: 无升降号 / 无低八度 / 无附点)。
    @{ name='小星星'; jp='1 1 5 5 6 6 5/2 4 4 3 3 2 2 1/2 5 5 4 4 3 3 2/2 5 5 4 4 3 3 2/2 1 1 5 5 6 6 5/2 4 4 3 3 2 2 1/2'; note='入门 儿歌'; timb='SINE'; oct=0 },
    @{ name='两只老虎'; jp='1 2 3 1 1 2 3 1 3 4 5/2 3 4 5/2 5 6 5 4 3 1 5 6 5 4 3 1 1 5 1/2 1 5 1/2'; note='入门 儿歌'; timb='SINE'; oct=0 },
    @{ name='玛丽有只小羊羔'; jp='3 2 1 2 3 3 3/2 2 2 2/2 3 5 5/2 3 2 1 2 3 3 3 3 2 2 3 2 1/2'; note='入门 儿歌'; timb='SINE'; oct=0; rep=2 },
    @{ name='粉刷匠'; jp='5 3 5 3 5 3 1 2 3 4 5 5 5 3 5 3 5 3 1 2 3 4 5 5 5'; note='入门 儿歌'; timb='SINE'; oct=0; rep=2 },
    @{ name='找朋友'; jp='5 5 6 6 5 5 3/2 5 5 6 6 5 5 3/2 1 2 3 5 3 2 1 2 3 1/2'; note='入门 儿歌'; timb='SINE'; oct=0; rep=2 },
    @{ name='小燕子'; jp='3 5 5 6 5 3 2 1 2 3 5 6 5 5/2 3 5 5 6 5 3 2 2 3 2 1 1/2'; note='初级 儿歌'; timb='SINE'; oct=0; rep=2 },
    @{ name='小蜜蜂'; jp='5 3 3 4 2 2 1 2 3 4 5 5 5 5 3 3 4 2 2 1 3 2 2 1/2'; note='初级 儿歌'; timb='SINE'; oct=0; rep=2 },
    @{ name='娃哈哈'; jp='5 5 6 5 3 2 1 2 3 5 3 2 1 1/2 5 5 6 5 3 2 1 2 3 5 3 2 1 1/2'; note='初级 儿歌'; timb='SINE'; oct=0; rep=2 },
    @{ name='欢乐颂'; jp='3 3 4 5 5 4 3 2 1 1 2 3 3/2 3 2 3 3 4 5 5 4 3 2 1 1 2 3 2/2 1/2 1/2'; note='入门 贝多芬'; timb='SINE'; oct=0 },
    @{ name='生日歌'; jp='5/8 5/8 6 5 8 7/2 5/8 5/8 6 5 9 8/2 5/8 5/8 12 10 8 7 6 4/8 4/8 10 8 9 8/2'; note='入门 通用'; timb='SINE'; oct=0; rep=2 },
    @{ name='铃儿响叮当'; jp='3 3 3/2  3 3 3/2  3 5 1 2  3/2 0/2  4 4 4 4  4 3 3 3 3  3 2 2 3  2/2 5/2  1/2 0/2'; note='入门 圣诞'; timb='SINE'; oct=0; rep=2 },
    @{ name='茉莉花'; jp='3 3 5 6 5 5 6 5 3 3 5 6 5 5 6 5 5 6 5 3 2 1 2 3 5 3 2 1'; note='中级 民歌'; timb='REED'; oct=1; rep=2 },
    @{ name='康定情歌'; jp='5 6 5 3 2 1 2 3 5 6 5 3 2 1 2 1'; note='中级 民歌'; timb='REED'; oct=1; rep=3 },
    @{ name='沂蒙山小调'; jp='5 6 5 3 2 3 5 6 5 3 2 1 2 3 5 3 2 1 2 1'; note='中级 民歌'; timb='REED'; oct=1; rep=2 },
    @{ name='送别'; jp='5 3 5 1 7 6 5 3 5 1 7 6 5 3 5 1 7 6 5 3 5 1 7 6 5/2'; note='中级 李叔同'; timb='TRI'; oct=0; rep=2 },
    @{ name='世上只有妈妈好'; jp='5 3 5 6 5 3 2 1 2 3 5 3 2 1 2 1 5 3 5 6 5 3 2 1 2 3 5 3 2 1 2 1'; note='初级 影视｜简谱待补'; timb='TRI'; oct=0 },
    @{ name='让我们荡起双桨'; jp='5 5 6 5 3 2 1 2 3 5 6 5 3/2 2 3 5 6 5 3 2 1 2 1/2'; note='初级 经典'; timb='TRI'; oct=0; rep=2 },
    @{ name='歌唱祖国'; jp='1 1 5 5 6 6 5 4 3 3 2 2 1 1 2 3 5 5 6 6 5 4 3 2 1/2'; note='中级 爱国'; timb='REED'; oct=0; rep=2 },
    @{ name='龙的传人'; jp='5 6 5 3 2 1 2 3 5 6 5 3 2 1 1/2 1 2 3 5 6 5 3 2 1 2 1'; note='中级 爱国'; timb='REED'; oct=0; rep=2 },
    @{ name='友谊地久天长'; jp='1 1 3 2 1 2 3 1 1 3 2 1 5 3 5 6 5 3 2 1 2 3 3 2 1 2 1/2'; note='中级 苏格兰'; timb='TRI'; oct=0; rep=2 },
    @{ name='天空之城'; jp='6 7 8 8 8 7 6 5 6 7 8 8 8 7 6 5 3 5 6 7 8 7 6 5 6'; note='中级 久石让'; timb='MIX'; oct=0; rep=2 },
    @{ name='菊次郎的夏天'; jp='5 6 8 8 8 6 5 3 5 6 8 8 8 6 5 3 2 3 5 6 8 6 5 3 2 1'; note='中级 久石让'; timb='MIX'; oct=0; rep=2 },
    @{ name='千与千寻'; jp='6 7 8 8 7 6 5 6 7 8 8 7 6 5 3 5 6 7 8 7 6 5 6 5 3'; note='中级 久石让'; timb='MIX'; oct=0; rep=2 },
    @{ name='小步舞曲'; jp='1 2 3 4 5 6 5 4 3 2 1 2 3 4 5 4 3 2 1'; note='中级 巴赫'; timb='SAW'; oct=0; rep=3 },
    @{ name='致爱丽丝'; jp='3 2 3 2 3 7 2 1 6 1 3 6 3 1 6 1 3 6 3 1'; note='中级 贝多芬'; timb='SAW'; oct=0; rep=2 },
    @{ name='卡农'; jp='1 5 6 3 4 1 4 5 1 5 6 3 4 1 4 5'; note='中级 帕赫贝尔'; timb='SAW'; oct=0; rep=3 },
    @{ name='欢乐颂变奏'; jp='3 3 4 5 5 4 3 2 1 1 2 3 3 2 2 3 3 4 5 5 4 3 2 1 1 2 3 2 1 1'; note='中级 贝多芬｜简谱待补'; timb='SAW'; oct=0 },
    @{ name='铃儿响叮当变奏'; jp='3 3 3/2  3 3 3/2  3 5 1 2  3/2 0/2  4 4 4 4  4 3 3 3 3  3 2 2 3  2/2 5/2  5 5 4 2  1/2 0/2'; note='中级 圣诞'; timb='TRI'; oct=0 },
    @{ name='平安夜'; jp='5 6 5/2 3 5 6 5/2 3 2 2 3/2 2 5 6 5/2 3 5 6 5/2 3 2 2 3/2 2 1 1 5/2 3 2 1 1/2'; note='中级 圣诞'; timb='TRI'; oct=0 },
    #  ==== 2026-10-21 新增: 按真实谱子录入的两首流行歌 ====
    #  晴天: 来自 3DM 摩尔庄园钢琴数字谱 (只取副歌, 最抓耳那段)
    @{ name='晴天'; jp='6/4 1/4 5/4 1/4 4/4 5/4 6/4 5/4 1/2 1/4 5/4 5/4 1/4 1/4 5/4 7/4 5/2 6/4 1/4 5/4 6/4 4/4 5/4 6/4 5/4 1/2 1/4 5/4 5/4 1/4 1/4 5/4 7/4 1/4 5/2 6/4 1/4 5/4 1/4 4/4 5/4 6/4 5/4 1/2 1/4 5/4 5/4 1/4 1/4 5/4 7/4 5/2 6/4 1/4 5/4 6/4 4/4 5/4 6/4 5/4 1/2 1/4 5/4 5/4 1/4 1/4 5/4 7/4 1/4 5/2 5/4 1/2 1/4 2/4 3/2 5/4 1/2 1/4 2/4 3/4 2/4 1/4 5/2 5/4 1/2 1/4 2/4 3/2 3/4 2/4 3/4 4/4 3/4 2/4 4/4 3/4 2/4 1/2 5/4 1/2 1/4 3/4 4/4 3/4 2/4 1/4 2/2 3/4 3/4 3/4 3/4 2/4 3/4 2/4 1/2 5/4 1/4 2/4 3/4 4/4 3/4 2/4 1/4 2/2 3/4 3/4 3/4 3/4 2/4 3/4 2/4 1/4 7/2 3/4 2/4 4/4 3/4 1/4 5/4 7/2 8/4 7/4 5/4 1/4 1/2 6/4 6/2 6/4 5/4 5/4 5/4 4/4 3/2 2/4 3/4 4/4 3/4 3/2 3/4 4/4 5/4 3/4 4/4 5/4 7/2 2/4 7/4 8/2 8/2 8/4 5/4 5/4 6/4 5/4 4/4 4/4 2/4 3/2 4/4 5/4 6/4 1/4 6/4 7/4 7/2'; note='高级 周杰伦｜真实谱(主歌+副歌)'; timb='MIX'; oct=0; rep=1 },
    #  青花瓷: 来自百度知道文本简谱; 原谱用 6 表示低音la, 本格式最低只有 do,
    #          所以整首**移高两个音级**(do->mi) —— 音程完全不变, 只是调性升高。
    @{ name='青花瓷'; jp='4/8 3/8 1/8 3/8 3/8 1/8 3/8 3/8 1/8 3/8 1/8 7/4 4/8 3/8 1/8 3/8 3/8 1/8 3/8 3/8 5/8 4/8 3/8 3/4 7/8 8/8 5/8 5/8 5/8 4/8 5/8 5/8 4/8 5/8 7/8 5/8 5/4 5/8 5/8 5/8 5/8 4/8 4/8 4/8 4/8 3/8 5/8 4/2 4/8 3/8 1/8 3/8 3/8 1/8 3/8 3/8 1/8 3/8 1/8 7/4 7/8 8/8 5/8 7/8 7/8 5/8 7/8 7/8 5/8 4/8 3/8 3/4 4/8 3/8 4/8 5/8 4/8 4/8 3/8 4/4 3/8 1/8 4/8 3/8 3/8 1/8 3/8 3/8 3/2 7/8 7/8 5/8 4/8 5/8 1/4 4/8 5/8 7/8 5/8 4/2 7/8 7/8 5/8 4/8 5/8 7/4 4/8 5/8 7/8 4/8 3/2 3/8 4/8 5/8 7/8 8/8 7/8 5/8 7/8 5/8 5/8 4/8 4/2 3/8 4/8 3/8 4/8 3/8 4/8 5/8 7/8 5/8 5/4'; note='高级 周杰伦｜真实谱(主歌+副歌, 移调)'; timb='MIX'; oct=0; rep=1 },
    #  ==== 2026-10-21 新增: 用户提供的真实简谱 ====
    @{ name='七里香'; jp='3/4 5/4 6/4 8/2 6/4 5/4 3/4 2/4 3/4 5/4 6/4 8/2 6/4 5/4 3/4 5/4 6/4 1/4 6/4 5/2 3/4 5/4 6/4 8/2 6/4 5/4 3/4 2/4 3/4 5/4 6/4 8/2 6/4 5/4 3/4 5/4 6/4 1/4 6/4 5/2 8/2 8/4 8/4 8/4 8/4 8/4 7/4 6/4 5/2 7/4 8/4 9/4 8/4 8/2 8/4 5/4 7/4 8/4 8/2 8/4 8/4 8/4 7/4 6/4 5/2 9/4 10/4 11/4 10/4 10/2 10/4 5/4 7/4 8/4 8/2 9/4 8/4 7/4 8/4 8/2 8/4 8/4 9/4 10/4 9/4 8/4 8/4 7/4 9/4 8/4 8/4 8/2'; note='高级 周杰伦｜真实谱(副歌)'; timb='MIX'; oct=0; rep=1 },
    @{ name='稻香'; jp='0/2 0/2 0/2 0/2 1/4 1/4 6/2 1/4 6/4 1/4 1/4 1/4 1/4 2/4 2/4 2/4 2/4 3/4 1/2 1/4 6/4 1/4 1/4 1/4 1/4 2/4 2/4 2/4 2/4 3/4 1/2 1/4 6/4 1/4 1/4 1/4 1/4 2/4 2/4 2/4 2/4 1/4 3/2 3/4 1/4 1/4 1/4 6/2 1/4 1/4 1/4 6/2 5/4 5/4 5/4 5/4 5/4 5/4 5/4 5/4 5/4 5/4 3/4 2/4 1/2 1/4 3/4 3/4 3/4 3/4 3/4 3/4 3/4 3/4 3/4 3/4 1/4 6/2 6/4 1/4 1/4 1/4 1/4 1/4 2/4 2/4 2/4 1/4 3/2'; note='中级 周杰伦｜真实谱(主歌+副歌)'; timb='MIX'; oct=0; rep=1 }
)


#  ==================================================================
#  ★★★ 在线曲谱库 (2026-10-11 新增) ★★★
#    数据源: Acgmuse 曲谱库 —— GitHub `EwigMidori/AcgmuseBackup`
#            的 am_score_2019_1_30.json, **357 首真实简谱文本**。
#    走 jsdelivr CDN: 实测 3.8 秒; 而 raw.githubusercontent.com 要 13.5 秒。
#
#    ★ 记法转换 (Acgmuse -> 本项目):
#        1-7     音级           [1]  高音区(+1 八度, 可嵌套)
#        (6)     低音区(-1)      #6   升半音 / b7 降半音
#        | 小节线   x4 重复      【】 段落
#        其余字符 (中文/全角标点) 一律丢弃
#      ★ 踩过的坑: 库里有些是全角 `（`, 被过滤后只剩落单的 `)`,
#        我第一版遇到不配对括号会**一直吞到行尾** -> 整首只剩十几个音。
#        现在先丢掉不配对的括号, 再解析。
#
#    ★ 离线兜底: 第一次下载后缓存到 upper\scorelib_cache.json,
#      后面即使断网也能用 (比赛现场没网也不怕)。
#  ==================================================================
$script:AmUrl  = 'https://cdn.jsdelivr.net/gh/EwigMidori/AcgmuseBackup@master/am_score_2019_1_30.json'
$script:AmUrl2 = 'https://raw.githubusercontent.com/EwigMidori/AcgmuseBackup/master/am_score_2019_1_30.json'
#  ★ 缓存路径: 用**脚本所在目录**, 不用 $PSScriptRoot
#    (注入测试时 $PSScriptRoot 会是空的, 会掉到系统临时目录里去)
$script:AmCache = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'scorelib_cache.json'
if (-not $script:AmCache -or $script:AmCache -like '*scorelib_cache.json' -and -not (Test-Path (Split-Path -Parent $script:AmCache))) {
    $script:AmCache = Join-Path $PWD 'scorelib_cache.json'
}
$script:AmDb = $null        # 下载后放这里 (数组)

#  把不配对的括号换成空格
function Remove-UnmatchedBrackets {
    param([string]$S)
    $stack = New-Object System.Collections.ArrayList
    $keep = New-Object bool[] $S.Length
    for ($i = 0; $i -lt $S.Length; $i++) {
        $c = $S[$i]
        if ($c -eq '[' -or $c -eq '(') { [void]$stack.Add($i) }
        elseif ($c -eq ']' -or $c -eq ')') {
            $want = if ($c -eq ']') { '[' } else { '(' }
            if ($stack.Count -gt 0 -and $S[$stack[$stack.Count-1]] -eq $want) {
                $j = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $keep[$j] = $true; $keep[$i] = $true
            }
        }
    }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $S.Length; $i++) {
        $c = $S[$i]
        if ($c -eq '[' -or $c -eq '(' -or $c -eq ']' -or $c -eq ')') {
            [void]$sb.Append($(if ($keep[$i]) { $c } else { ' ' }))
        } else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}

#  Acgmuse 简谱 -> 本项目简谱 (返回单词数组)
function Convert-AmScore {
    param([string]$Text)
    #  白名单: 只留记号字符
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Text.ToCharArray()) {
        if ($c -match '[0-9#b\[\]\(\)\|xX\s]') { [void]$sb.Append($c) } else { [void]$sb.Append(' ') }
    }
    $body = Remove-UnmatchedBrackets $sb.ToString()
    #  展开 xN
    for ($g = 0; $g -lt 6; $g++) {
        $new = [regex]::Replace($body, '([0-9#b]|\[[^\]]*\]|\([^\)]*\))\s*[xX]\s*(\d+)', {
            param($m)
            $unit = $m.Groups[1].Value
            $n = [int]$m.Groups[2].Value
            $parts = @(); for ($k = 0; $k -lt $n; $k++) { $parts += $unit }
            return ($parts -join ' ')
        })
        if ($new -eq $body) { break }
        $body = $new
    }
    #  逐字符解析, 用显式栈处理嵌套括号
    $out = New-Object System.Collections.ArrayList
    $shift = 0
    $stack = New-Object System.Collections.ArrayList
    $i = 0
    while ($i -lt $body.Length) {
        $c = $body[$i]
        if ($c -eq '[') { [void]$stack.Add($shift); $shift += 1; $i++; continue }
        if ($c -eq '(') { [void]$stack.Add($shift); $shift -= 1; $i++; continue }
        if ($c -eq ']' -or $c -eq ')') {
            if ($stack.Count -gt 0) { $shift = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1) }
            $i++; continue
        }
        if ($c -eq '#' -or $c -eq 'b') { $i++; continue }      # 半音: 本项目 7 声音阶, 忽略升降
        if ($c -match '[0-9]') {
            $d = [int]([string]$c) + 7 * $shift
            if ($d -lt 0)  { $d = 0 }
            if ($d -gt 14) { $d = 14 }
            [void]$out.Add([string]$d)
            $i++; continue
        }
        $i++
    }
    return $out.ToArray()
}

#  下载在线曲库 (带缓存)
function Get-AmDatabase {
    param([switch]$Force)
    if ($script:AmDb -and -not $Force) { return $script:AmDb }
    if ((Test-Path $script:AmCache) -and -not $Force) {
        try {
            $script:AmDb = Get-Content $script:AmCache -Raw -Encoding UTF8 | ConvertFrom-Json
            Log ("在线曲库: 用缓存, {0} 首" -f $script:AmDb.Count) $C_TX
            return $script:AmDb
        } catch { }
    }
    $txt = $null
    foreach ($u in @($script:AmUrl, $script:AmUrl2)) {
        try {
            Log ("在线曲库: 正在下载 ... " + $u.Substring(0,42)) $C_TX
            [System.Windows.Forms.Application]::DoEvents()
            $r = Invoke-WebRequest -Uri $u -TimeoutSec 60 -UseBasicParsing -ErrorAction Stop
            $txt = $r.Content
            break
        } catch { Log ("  下载失败: " + $_.Exception.Message.Substring(0,[Math]::Min(60,$_.Exception.Message.Length))) $C_ERR }
    }
    if (-not $txt) { Log "在线曲库: 全部源都失败 (检查网络)" $C_ERR; return @() }
    #  解析: [{type:table, data:[{title, json}, ...]}]
    $flat = New-Object System.Collections.ArrayList
    try {
        $j = $txt | ConvertFrom-Json
        foreach ($sec in $j) {
            if ($sec.type -ne 'table') { continue }
            foreach ($row in $sec.data) {
                $inner = $null
                try { $inner = $row.json | ConvertFrom-Json } catch { continue }
                if (-not $inner -or -not $inner.score_text) { continue }
                [void]$flat.Add([pscustomobject]@{
                    title = ([string]$row.title).Trim()
                    alias = (($inner.alias) -join ' ')
                    text  = [string]$inner.score_text
                })
            }
        }
    } catch { Log ("在线曲库: 解析失败 " + $_.Exception.Message) $C_ERR; return @() }
    $script:AmDb = $flat.ToArray()
    try { $script:AmDb | ConvertTo-Json -Compress -Depth 4 | Set-Content -Path $script:AmCache -Encoding UTF8 } catch { }
    Log ("在线曲库: 下载完成, {0} 首 (已缓存)" -f $script:AmDb.Count) $C_TX
    return $script:AmDb
}

#  在线搜索 (按曲名 + 别名)
function Search-AmScore {
    param([string]$Key)
    $db = @(Get-AmDatabase)
    if ($db.Count -eq 0) { return @() }
    if ([string]::IsNullOrWhiteSpace($Key)) {
        return @($db | Select-Object -First 60)
    }
    $k = $Key.Trim()
    return @($db | Where-Object { $_.title -like "*$k*" -or $_.alias -like "*$k*" })
}

#  按关键字搜曲谱。空串 = 返回全部。
function Search-ScoreLib {
    param([string]$Key)
    if ([string]::IsNullOrWhiteSpace($Key)) { return $script:ScoreLib }
    $k = $Key.Trim()
    return @($script:ScoreLib | Where-Object {
        $_.name -like "*$k*" -or $_.note -like "*$k*"
    })
}

function Send-ScoreDownload {
    param([string]$Name, [byte[]]$Data)
    if (-not $script:connected) { Log "未连接" $C_ERR; return "未连接" }
    if ($Data.Length -lt 2) { return "曲谱为空" }
    #  ★★★ 必须置 busy! 否则会死锁 (已修) ★★★
    #    原因: 下载在 UI 线程上跑, 中间会调 DoEvents() 刷新按钮状态,
    #    而定时器 Tick 只检查 $script:busy —— 下载没置 busy,
    #    于是 Tick 赶在下载中间又发了一轮 Refresh-Status
    #    (五条命令 + 读应答), 两个流程同时读同一个串口,
    #    互相吃掉对方的应答 -> **双方都死等到超时**。
    #    实测: 界面卡在"下发中...", 日志一片空白。
    $script:dlBusy = $true

    #  ==================================================================
    #  协议第三版 (2026-10-11) —— **每个动作一个独立命令码**
    #    A5 5B <H> 5A   声明长度: 总字节数 = H * 16   (H = 1..15, 上限 240 字节)
    #    A5 5C 00 5A    开始收数据
    #    <N 个原始字节>  N = H*16, 中间不插任何帧
    #    A5 5D 00 5A    提交 -> D=D,<实收字节数(16进制)>
    #    A5 5E 00 5A    清空
    #  ==================================================================
    #  ★ 为什么换了三版:
    #    v1 "块头帧 + 16 字节数据"交替 -> 数据里的 0xA5/0x5A 污染帧解析
    #    v2 "0x4E + nibble 子命令"     -> 子命令在高/低 4 位反复搞错,
    #         而且 0x00/0x05/0x06/0x0A 高低四位恰好相同, 测试时看不出来,
    #         到块头 0x40 (高=4 低=0) 才暴露 -> 数据一个字节都进不去
    #    v3 **命令字节本身就是身份** -> 没有位段解析, 不可能弄错
    #  ★ 代价: 长度是 16 字节粒度。实际发出去会补齐到 16 的倍数,
    #    末尾补 0xFF —— 曲谱解析遇到 0xFF 就停, 无害。
    #  ==================================================================
    #  ★★ A 方案 (2026-10-11): 长度上限 240 -> 2047 ★★
    #    硬件: FPGA 曲谱 RAM 是 2048 字节, 固件 dl_total 本来就是 12 位 —— **不用改硬件**!
    #    原来只传了 4 位长度 (15 x 16 = 240), 白白浪费了 8 倍容量。
    #    现在拆两帧: 5B 传高 4 位, 64 传低 8 位 -> 12 位, 实际限 2047。
    #    效果: 在线曲库可下载率 40% -> 约 95%。
    $total = $Data.Length
    if ($total -lt 1) { return "曲谱为空" }
    if ($total -gt 2047) { return ("曲谱太长: {0} 字节, 上限 2047" -f $total) }
    $hi = [byte](($total -shr 8) -band 0x0F)
    $lo = [byte]($total -band 0xFF)

    #  ---- ① 声明长度 (高 4 位) ----
    $r0 = Send-Frame $script:sp ([byte[]]@(0xA5,0x5B,$hi,0x5A)) 350
    if ($r0 -notmatch 'D=B,') { $script:dlBusy = $false; return "声明失败: $r0" }
    #  ---- ①b 声明长度 (低 8 位) ----
    $rh = Send-Frame $script:sp ([byte[]]@(0xA5,0x64,$lo,0x5A)) 350
    if ($rh -notmatch 'D=4,') { $script:dlBusy = $false; return "声明2失败: $rh" }
    #  ---- ② 开始收 ----
    $r1 = Send-Frame $script:sp ([byte[]]@(0xA5,0x5C,0x00,0x5A)) 350
    if ($r1 -notmatch 'D=C,') { $script:dlBusy = $false; return "启动失败: $r1" }

    #  ---- ③ 一次性发完 ----
    #  ★ 现在长度精确到字节, **不需要补齐** 到 16 的倍数了
    #    (原来长度是 16 字节粒度, 尾巴要补 0xFF)。
    $sb = $Data
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:sp.Write($sb, 0, $total)
    #  115200 8N1 = 11520 字节/秒, 留 120ms 余量
    Start-Sleep -Milliseconds ([int]($total / 11.52) + 120)

    #  ---- ④ 提交 ----
    $r2 = Send-Frame $script:sp ([byte[]]@(0xA5,0x5D,0x00,0x5A)) 900
    $m = [regex]::Match($r2, 'D=D,([0-9A-Fa-f]{4})')
    if (-not $m.Success) { $script:dlBusy = $false; Log ("曲谱下载: 提交应答异常 -> {0}" -f $r2) $C_ERR; return $r2 }
    $got = [Convert]::ToInt32($m.Groups[1].Value, 16)
    if ($got -eq $total) {
        $script:dlBusy = $false
        #  ★★★ 下载成功 -> 把简谱面板切到这首曲子 ★★★
        #    固件侧: dl_valid 一置 1 就**自动**用下载的曲谱,
        #    所以这边必须同步把界面也切过去, 否则两边不一致。
        $script:hasDl  = $true
        $script:dlName = if ($Name) { $Name } else { "未命名" }
        $script:dlLen  = $Data.Length - 1
        #  从已编码的字节里反解出音级/时值 (最后一个 0xFF 不算)
        $ns = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $Data.Length; $i++) {
            $b = $Data[$i]
            if ($b -eq 0xFF) { break }
            [void]$ns.Add(@{ deg = ($b -shr 4) -band 0xF; dur = $b -band 0xF })
        }
        $script:dlNotes = $ns
        #  ★ 曲名过长会换行压到下面的按钮, 所以截断
        $nmShow = $script:dlName
        if ($nmShow.Length -gt 12) { $nmShow = $nmShow.Substring(0,12) + ".." }
        $lblSrc.Text = ("曲谱来源: 下载 [{0}] {1}音" -f $nmShow, $ns.Count)
        $lblSrc.ForeColor = [System.Drawing.Color]::FromArgb(210,120,0)
        $btnScoreSrc.Enabled = $true
        $jpPanel.Invalidate()
        $ledPanel.Invalidate()
        Log ("曲谱下载成功: [{0}] {1} 字节 (补齐 {2}), {3}ms" -f $Name, $Data.Length, $total, $sw.ElapsedMilliseconds) $C_TX
        return ("OK {0}音" -f ($Data.Length - 1))
    }
    if ($got -eq 0) { $script:dlBusy = $false; Log "曲谱下载失败: FPGA 一个字节都没收到" $C_ERR; return "未收到" }
    $script:dlBusy = $false
    Log ("曲谱下载: 字节数不符 期望 {0} 实收 {1}" -f $total, $got) $C_ERR
    return ("部分 {0}/{1}" -f $got, $total)
}

#  ---- 录音回传: 从 FPGA 取回演奏事件 ----
#  ★★★ 2026-10-21 重做: 固件改成记录**真实演奏**了, 每事件 5 字节 ★★★
#    旧格式 (4 字节): [曲谱要求的音级][1=弹对 2=弹错][时间戳高][低]
#      -> 记的是"跟弹对错日志", 还原不出你弹了什么。
#    新格式 (5 字节): [MIDI音符号][1=按下 2=松开][力度][时间戳高][低]
#      -> 时间戳单位是**毫秒** (16 位 -> 65 秒)
#  ★ 两边必须同时改: 固件 src/uart_cmd.v 的 rec_wr_sub 0..4,
#    和这里 cnt*5 / 步长 5。改一边就会出现"事件错位成乱码"。
function Get-Recording {
    #  取回 FPGA 记录的演奏事件。
    #  协议:
    #    A5 4E 08 5A -> D=8,00<条数>       (取头, 同时把读指针清 0)
    #    A5 4E 09 5A -> D=9,00<一个字节>   (每发一次取一个字节)
    #  ★ 固件每条事件 4 字节: [音级] [类型] [时间戳高] [时间戳低]
    #  ★ 踩过的坑: 我原来写的正则是 'D=REC,ok,cnt,seq' —— 那是我"设想"的格式,
    #    固件实际回 'D=8,00<count>', 于是永远匹配不上, 事件列表永远空。
    if (-not $script:connected) { return @() }
    $script:dlBusy = $true
    $hdr = Send-Frame $script:sp ([byte[]]@(0xA5,0x61,0x00,0x5A)) 500
    $m = [regex]::Match($hdr, 'D=1,([0-9A-Fa-f]{4})')
    if (-not $m.Success) { Log ("取录音头失败: " + $hdr) $C_ERR; return @() }
    $cnt = [Convert]::ToInt32($m.Groups[1].Value, 16)
    if ($cnt -le 0) { return @() }
    if ($cnt -gt 250) { $cnt = 250 }

    $need = $cnt * 5
    $bytes = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $need; $i++) {
        $r = Send-Frame $script:sp ([byte[]]@(0xA5,0x62,0x00,0x5A)) 220
        $mm = [regex]::Match($r, 'D=2,([0-9A-Fa-f]{4})')
        if (-not $mm.Success) { break }
        $v = [Convert]::ToInt32($mm.Groups[1].Value, 16)
        [void]$bytes.Add([byte]($v -band 0xFF))
    }

    $ev = New-Object System.Collections.ArrayList
    for ($i = 0; $i + 4 -lt $bytes.Count; $i += 5) {
        $note = [int]$bytes[$i]                     #  MIDI 音符号 0..127
        $kind = [int]$bytes[$i+1]                   #  1=按下 2=松开
        $vel  = [int]$bytes[$i+2]                   #  力度 0..255
        $ts   = ([int]$bytes[$i+3] -shl 8) -bor [int]$bytes[$i+4]   #  毫秒
        [void]$ev.Add([pscustomobject]@{ Note=$note; Kind=$kind; Vel=$vel; T=$ts })
    }
    $script:dlBusy = $false
    return $ev
}

# ---------------- 事件 ----------------
$form.Add_Load({
    Fit-Split
    Fit-RightW
    Fit-LeftW
    Fit-CfgRows
    Refresh-Ports
    Log "FPGA 钢琴 - 上位机控制台" $C_ACCENT
    Log "1. 选串口 (通常 COM26) -> 点「打开串口」" $C_SYS
    Log "2. 勾「自动刷新」看实时状态" $C_SYS
    Log "3. 要改参数, 先勾「上位机接管」" $C_SYS
    Log "─────────────────────────────────" $C_SYS
    #  ★★ 强制把参数配置面板提到最前
    #     不加这两句的话, Dock='Fill' 的日志面板会把
    #     Dock='Bottom' 的配置面板**整个盖住** (实测确实如此)。
    $grpCfg.BringToFront()
    $grpLog.BringToFront()
    $grpCfg.BringToFront()
})

$btnRefreshPorts.Add_Click({ Refresh-Ports; Log "已刷新串口列表" $C_SYS })

$btnConn.Add_Click({
    #  ★ 防重入: 推键位期间 Send-Frame 会转 DoEvents,
    #    不挡住的话这个"开关"会被重复触发 -> 连上又立刻断开。
    if ($script:keymapBusy) { return }
    if ($script:connected) {
        if ($script:sp) { $script:sp.Close() }
        $script:connected = $false
        $btnConn.Text = "打开串口"
        $btnConn.BackColor = $C_ACCENT
        $lblConn.Text = "未连接"; $lblConn.ForeColor = $C_SUB
        $lblDot.ForeColor = [System.Drawing.Color]::FromArgb(190,195,205)
        $btnLat.Enabled = $false
        $lblLat.Text = "延迟: —  (未连接)"
        $lblLat.ForeColor = $C_SUB
        Log "已关闭串口" $C_WARN
        $lblStatus.Text = "未连接"
    } else {
        $port = $cmbPort.SelectedItem
        if (-not $port) { [System.Windows.Forms.MessageBox]::Show("没有可用串口"); return }
        $r = Connect-FPGA $port
        $lblConn.Text = $r.msg
        $lblConn.ForeColor = if ($r.ok) { $C_OK } else { $C_ERR }
        if ($r.ok) {
            $btnConn.Text = "关闭串口"
            $btnLat.Enabled = $true
            $lblLat.Text = "延迟: —  (静音后点「延迟实测」)"
            $lblLat.ForeColor = $C_SUB
            $btnConn.BackColor = [System.Drawing.Color]::FromArgb(90,95,105)
            $lblDot.ForeColor = $C_OK
            Log $r.msg $C_OK
            $lblStatus.Text = $r.msg
            Refresh-Status
        } else {
            Log $r.msg $C_ERR
            $lblStatus.Text = $r.msg
        }
    }
})

#  ---- 延迟实测: RID 30 (事件->首个非零样本拍数) + RID 5 (灵敏度档位) ----
$btnLat.Add_Click({
    if (-not $script:connected) { Log "未连接, 无法测延迟" $C_ERR; return }
    if ($script:keymapBusy) { return }
    #  ★ 防重入: 下面两次 Send-Frame 合计等 ~0.6s,
    #     若 DoEvents 在期间转起来, 用户再点一下"开/关串口"
    #    就会把连接断掉。所以用 keymapBusy 锁住 (Send-Frame 里会看它)。
    $script:keymapBusy = $true
    try {
        $r = Send-Frame $script:sp ([byte[]]@(0xA5,0x52,0x1E,0x5A)) 300
        $ticks = ParseVal $r
        if ($ticks -lt 0) {
            $lblLat.Text = "延迟: 无应答"
            $lblLat.ForeColor = $C_ERR
            Log ("RID30 无应答, 原始返回: [" + $r + "]") $C_ERR
            return
        }
        if ($ticks -eq 0) {
            $lblLat.Text = "延迟: 0  ← 请先静音再挡弦"
            $lblLat.ForeColor = $C_WARN
            Log "读到 0: 上一个音还在响, 计数器根本没启动。等余音散掉再测。" $C_WARN
            return
        }
        #  读灵敏度档位 (RID 5) -> 消抖时间
        $rg  = Send-Frame $script:sp ([byte[]]@(0xA5,0x52,0x05,0x5A)) 300
        $lvl = ParseVal $rg
        if ($lvl -lt 0 -or $lvl -gt 4) { $lvl = 0 }
        $debTab = @(30, 150, 500, 2000, 10000)
        $debUs  = $debTab[[int]$lvl]

        $tEv  = $ticks * 0.3333                       # 事件 -> 首个非零样本
        $tDig = $tEv + $debUs + 10.7                  # + 消抖 + I2S 串行化
        $tLo  = $tDig / 1000.0 + 1.0                  # + 功放 1~2ms
        $tHi  = $tDig / 1000.0 + 2.0

        $lblLat.Text = ("延迟: {0:N1}us = 事件 {1:N1} + 消抖 {2} + I2S 10.7   |   含功放 {3:N2}~{4:N2}ms" -f $tDig, $tEv, $debUs, $tLo, $tHi)
        if ($tHi -le 5.0) {
            $lblLat.ForeColor = $C_OK
        } else {
            $lblLat.ForeColor = $C_WARN
        }

        Log ("延迟实测: RID30 = {0} 拍 (0x{0:X}) -> {1:N2}us" -f $ticks, $tEv) $C_SYS
        Log ("  消抖档 {0} = {1}us  |  数字链路 {2:N1}us = {3:N4}ms" -f $lvl, $debUs, $tDig, ($tDig/1000.0)) $C_SYS
        Log ("  含 MAX98357A 功放群延迟 (1~2ms) -> {0:N2} ~ {1:N2} ms" -f $tLo, $tHi) $C_SYS
        if ($lvl -ge 3) {
            Log "  ⚠ 灵敏度档位偏高, 延迟已接近或超过 5ms 目标。演示时建议降到档 0~2。" $C_WARN
        }
    } finally {
        $script:keymapBusy = $false
    }
})

$btnOnce.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Refresh-Status
    $sw.Stop()
    Log ("刷新完成 ({0} ms)" -f $sw.ElapsedMilliseconds) $C_SYS
})

$timer = New-Object System.Windows.Forms.Timer
#  ★ 刷新间隔 200 -> 120ms
#    配合上面的 150ms 等待: 正常情况一轮 ~78ms,
#    加上间隔实际刷新率 约 5 次/秒 —— 演奏时看得清楚。
#  ★ 间隔必须**大于**一轮刷新的耗时 (104~153ms), 否则
#    定时器会把 UI 线程占满, 点击排不上队 -> 界面像卡死。
#    现在 250ms: 刷新率 ~4 次/秒, 留出 ~100ms 空隙。
$timer.Interval = 250
$timer.Add_Tick({
    #  ★ 连接后的延迟推键位 (不在连接调用栈里做)
    if ($script:KmapNeedPush -and $script:connected -and -not $script:busy -and -not $script:dlBusy) {
        $script:KmapNeedPush = $false
        [void](Push-Keymap $script:KmapSaved $true $script:KindsSaved)
        #  ★ 自动识别是哪个预设, 并把名字写到主界面按钮上
        $script:KmapPresetSel = Detect-KmapPreset $script:KmapSaved
        if ($script:KmapPresetSel -ge 0) {
            Update-KmapButton $script:KmapPresetSel
            Log ("已自动恢复键位: " + $script:KmapPresets[$script:KmapPresetSel].short) $C_TX
        } else {
            Update-KmapButton (-1)
            Log "已自动恢复键位 (自定义方案)" $C_TX
        }
    }
    if ($chkAuto.Checked -and $script:connected -and -not $script:busy -and -not $script:dlBusy) {
        $script:busy = $true
        try { Refresh-Status } finally { $script:busy = $false }
    }
})
$timer.Start()

$chkHost.Add_CheckedChanged({
    if (-not $script:connected) {
        if ($chkHost.Checked) { Log "未连接, 无法设置接管" $C_ERR }
        return
    }
    #  ★ 固件里是 host_on <= dstr[2][0], 所以 **1 = 开, 0 = 关**
    #    之前写反了: 勾选时发 0 -> 实际是"关接管", 所以怎么点都没反应。
    $vv = if ($chkHost.Checked) { 1 } else { 0 }
    $f = [byte[]]@(0xA5,0x43,[byte]$vv,0x5A)
    $r = Send-Frame $script:sp $f 350
    $tag = if ($chkHost.Checked) { '接管 ON' } else { '接管 OFF' }
    Log ("发  {0}   ->  {1}   [{2}]" -f (($f|ForEach-Object{'{0:X2}' -f $_}) -join ' '), $r, $tag) $C_TX
})

#  ==================================================================
#  ★ 曲谱指引的四个按钮
#     命令格式:  A5 4C XX 5A
#       XX bit0 = 曲谱模式开关 (1=开)
#       XX bit1 = 回到开头
#       XX bit2 = 下一首
#     回报 "M=OK"
#  ==================================================================
function Send-Score {
    param([byte]$Bits, [string]$Name)
    $f = [byte[]]@(0xA5,0x4C,$Bits,0x5A)
    $r = Send-Frame $script:sp $f 350
    Log ("发  {0}   ->  {1}   [{2}]" -f (($f|ForEach-Object{'{0:X2}' -f $_}) -join ' '), $r, $Name) $C_TX
    return $r
}


#  ---- 曲谱下载 / 录音回传 的按钮事件 ----

#  ---- 在线曲谱库 的按钮事件 ----
function Refresh-ScoreLib {
    param([string]$Key)
    $res = Search-ScoreLib $Key
    $lstLib.Items.Clear()
    foreach ($s in $res) { [void]$lstLib.Items.Add($s.name) }
    $lblLibCnt.Text = ("共 {0} 首" -f $res.Count)
    $script:libHits = $res
}

#  ---- 在线搜索 ----
$btnLibOnline.Add_Click({
    $k = $txtLibSearch.Text
    $lblLibMsg.Text = "查询中..."
    [System.Windows.Forms.Application]::DoEvents()
    $res = @(Search-AmScore $k)
    $script:libHits = @()
    $lstLib.Items.Clear()
    foreach ($s in $res) {
        $t = $s.title
        if ($s.alias) { $t = "$t  [$($s.alias.Split(' ')[0])]" }
        [void]$lstLib.Items.Add($t)
    }
    $script:libHits = $res
    $lblLibCnt.Text = ("在线 {0} 首" -f $res.Count)
    $lblLibMsg.Text = "在线"
    $script:libSrc = 'online'
})
$chkLibOnline.Add_CheckedChanged({ $script:libOnlineOn = $chkLibOnline.Checked })

$btnLibGo.Add_Click({ Refresh-ScoreLib $txtLibSearch.Text })
$btnLibAll.Add_Click({ $txtLibSearch.Text = ""; Refresh-ScoreLib "" })
$txtLibSearch.Add_KeyDown({
    param($s,$e)
    if ($e.KeyCode -eq 'Enter') { Refresh-ScoreLib $txtLibSearch.Text; $e.SuppressKeyPress = $true }
})
$lstLib.Add_SelectedIndexChanged({
    $i = $lstLib.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:libHits.Count) {
        $lblLibPrev.Text = "选中一首曲谱后这里显示预览"
        return
    }
    $s = $script:libHits[$i]
    #  ★ 在线结果没有 jp 字段, 要现场转换 (可能慢几百 ms)
    if ($script:libSrc -eq 'online' -and -not $s.jp) {
        $toks = Convert-AmScore $s.text
        if ($toks.Count -gt 480) { $toks = $toks[0..479] }   # 硬件上限
        $s | Add-Member -NotePropertyName jp -NotePropertyValue ($toks -join ' ') -Force
    }
    #  ==================================================================
    #  ★★★ 2026-10-18 修: 预览崩溃 (不能对 Null 值表达式调用方法) ★★★
    #
    #  【病因】在线曲库的条目是 { title, alias, text }, **没有 jp**。
    #    上面那段会用 Convert-AmScore 现场转换, 但一旦转换拿不到音符,
    #    $s.jp 就是 $null —— 接着 $s.jp.Substring(...) 就报 InvokeMethodOnNull。
    #  【为什么下载按钮不崩】它里面已经有 `if (-not $s.jp) { ... return }`。
    #    预览这段漏了。现在补上, 并且用 try/catch 兜底 ——
    #    宁可显示"预览失败" 也不要把整个窗口泡在红字里。
    #  ==================================================================
    try {
        $nm  = if ($s.name) { $s.name } else { $s.title }
        $nt  = if ($s.note) { $s.note } else { '' }
        $jpt = [string]$s.jp
        if ([string]::IsNullOrEmpty($jpt)) {
            $lblLibPrev.Text = ("{0}`r`n（这首没有可用的简谱数据）" -f $nm)
            return
        }
        #  ★ 2026-10-21: 短曲子重复播放 (rep 见 ScoreLib 的说明)
        $rp = if ($s.rep) { [int]$s.rep } else { 1 }
        $jpx = if ($rp -gt 1) { (($jpt + ' ') * $rp).Trim() } else { $jpt }
        $b     = ConvertTo-ScoreBytes $jpx
        $notes = $b.Length - 1
        $head  = $jpx.Substring(0, [Math]::Min(90, $jpx.Length))
        $tt = if ($s.timb) { $s.timb } else { '?' }
        $oo = if ($null -ne $s.oct) { [int]$s.oct } else { 0 }
        $lblLibPrev.Text = ("{0}`r`n{1} 个音 / {2} 字节`r`n{3}`r`n★ 推荐音色: {4}   推荐八度: {5}`r`n{6}" -f $nm, $notes, $b.Length, $nt, $tt, $oo, $head)
    } catch {
        $lblLibPrev.Text = ("预览失败: " + $_.Exception.Message)
    }
})
$btnLibUse.Add_Click({
    $i = $lstLib.SelectedIndex
    if ($i -lt 0 -or $i -ge $script:libHits.Count) { $lblLibMsg.Text = "先选一首"; return }
    $s = $script:libHits[$i]
    #  ★ 两种来源的字段名不同:
    #      本地库 = { name, jp, note }
    #      在线库 = { title, alias, text }   <- 没有 jp, 要现场转换
    #    踩过的坑: 我一开始只读 $s.name, 在线结果填进去曲名是空的。
    $nm = if ($s.name) { $s.name } else { $s.title }
    if (-not $s.jp -and $s.text) {
        $toks = @(Convert-AmScore $s.text)
        if ($toks.Count -gt 480) { $toks = $toks[0..479] }   # 硬件上限
        $s | Add-Member -NotePropertyName jp -NotePropertyValue ($toks -join ' ') -Force
    }
    if (-not $s.jp) { $lblLibMsg.Text = "这首没有曲谱数据"; return }
    #  ★ 2026-10-21: 短曲子按 rep 重复播放。
    #    为什么: 内置库里有 30 首不到 20 个音, 就是一个 8 小节的乐句,
    #    播完就完 —— 太短了。rep=3 就相当于把这段弹三遍, 时长翻三倍。
    #    ★ 这只是"重复", 不是把歌补全; 要听出完整的一首歌还是得重新扒谱。
    $rp = if ($s.rep) { [int]$s.rep } else { 1 }
    $jpx = if ($rp -gt 1) { (($s.jp + ' ') * $rp).Trim() } else { $s.jp }
    $txtJp.Text = $jpx
    $txtDlName.Text = $nm
    $lblLibMsg.Text = if ($rp -gt 1) { "已填入 (重复 $rp 遍)" } else { "已填入" }
    $lblDlMsg.Text = ("{0} 个音" -f (($jpx -split '\s+') | Where-Object { $_ -ne '' }).Count)
    Log ("从曲谱库选择: {0}" -f $nm) $C_TX
})

$btnDlTpl.Add_Click({
    $txtDlName.Text = "TWINKLE"
    $txtJp.Text = "1 1 5 5 6 6 5/2 4 4 3 3 2 2 1/2 5 5 4 4 3 3 2/2 5 5 4 4 3 3 2/2 1 1 5 5 6 6 5/2 4 4 3 3 2 2 1/2"
})
$btnDlClear.Add_Click({ $txtJp.Text = ""; $lblDlMsg.Text = "" })
#  ★ "用回内置" 按钮 (2026-10-11)
#    发 0x5E (清空曲谱), 固件 scr_valid 清 0 -> 回到内置 3 首。
$btnScoreSrc.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $script:dlBusy = $true
    try {
        $r = Send-Frame $script:sp ([byte[]]@(0xA5,0x5E,0x00,0x5A)) 400
        Log ("清空下载曲谱 -> " + $r) $C_TX
    } finally { $script:dlBusy = $false }
    if ($r -match 'D=E,') {
        $script:hasDl  = $false
        $script:dlNotes = @()
        $script:dlName = ""
        $lblSrc.Text = "曲谱来源: 内置 (3 首)"
        $lblSrc.ForeColor = $C_ACCENT
        $btnScoreSrc.Enabled = $false
        $jpPanel.Invalidate(); $ledPanel.Invalidate()
    }
})

$btnDlSend.Add_Click({
    $bytes = ConvertTo-ScoreBytes $txtJp.Text
    if ($bytes.Length -le 1) { $lblDlMsg.Text = "曲谱为空"; return }
    $n = $bytes.Length - 1
    #  ★ 下载是**同步阻塞**的 (每块要等 40ms), 曲谱长时界面会顿一下。
    #    先显示状态并强制刷新, 否则用户看到的是"点下去没反应"。
    #    (实测 17 个音约 0.5 秒; 480 个音约 3 秒 —— 可接受, 不做多线程)
    $lblDlMsg.Text = ("共 {0} 个音, 下发中..." -f $n)
    $btnDlSend.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $r = Send-ScoreDownload $txtDlName.Text $bytes
        $lblDlMsg.Text = ("{0} 个音 -> {1}" -f $n, $r)
    } catch {
        $lblDlMsg.Text = "下载异常"
        Log ("曲谱下载异常: " + $_.Exception.Message) $C_ERR
    } finally {
        $btnDlSend.Enabled = $true
    }
})

$btnRecStart.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $script:recData = New-Object System.Collections.ArrayList
    $lstRec.Items.Clear()
    #  A5 4E 06 5A -> 开始录音
    $r = Send-Frame $script:sp ([byte[]]@(0xA5,0x5F,0x00,0x5A)) 400
    $lblRecMsg.Text = "录制中... $r"
    Log "开始录制: $r" $C_TX
})
$btnRecStop.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $lblRecMsg.Text = "取回中..."
    [System.Windows.Forms.Application]::DoEvents()
    $ev = Get-Recording
    $script:recData = New-Object System.Collections.ArrayList
    $lstRec.Items.Clear()
    #  ★★★ 2026-10-21 修: 这个列表还在用**旧格式**渲染 ★★★
    #    旧格式: Deg(4 位音级) + Kind(1=弹对 2=弹错) -> 显示 "do 对 t=..."
    #    新格式: Note(MIDI 音符号) + Kind(1=按下 2=松开) + Vel(力度) + T(毫秒)
    #    ★ 症状: 修好固件后列表仍然显示 "? 对 / ? 错" —— 因为 $e.Deg 不存在了,
    #      取出来是 $null, 于是 "?"; 而 Kind=1 被当成"对"、2 当成"错"。
    #  ★ 一个音 = **两条事件** (按下 + 松开), 所以"弹 4 个音出 8 条"是正常的。
    #    导出 CSV 时会配对合并成 4 个音, 见 $btnRecSave。
    $nmTab2 = @('C','C#','D','D#','E','F','F#','G','G#','A','A#','B')
    foreach ($e in $ev) {
        [void]$script:recData.Add($e)
        $k  = if ($e.Kind -eq 1) { '按下' } elseif ($e.Kind -eq 2) { '松开' } else { '--' }
        $nn = "{0}{1}" -f $nmTab2[$e.Note % 12], ([int][Math]::Floor($e.Note / 12) - 1)
        [void]$lstRec.Items.Add(("{0,4} {1} {2,6}ms  v{3}" -f $nn, $k, $e.T, $e.Vel))
    }
    $lblRecMsg.Text = ("{0} 条事件 ({1} 次按下 + {2} 次松开)" -f $script:recData.Count,
        ($script:recData | Where-Object { $_.Kind -eq 1 }).Count,
        ($script:recData | Where-Object { $_.Kind -eq 2 }).Count)
    Log ("录音回传: 收到 {0} 条事件" -f $script:recData.Count) $C_TX
})
$btnRecSave.Add_Click({
    if (-not $script:recData -or $script:recData.Count -eq 0) { $lblRecMsg.Text = "没有录音"; return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "CSV 文件|*.csv"
    $dlg.FileName = ("演奏记录_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($dlg.ShowDialog() -eq 'OK') {
        #  ★★★ 2026-10-21: 列全部重做 ★★★
        #    旧列 degree/ticks 是按"跟弹对错日志"设计的 (tick = 音频采样 93750Hz)。
        #    现在固件录的是真实演奏, 时间戳单位是**毫秒**, 所以换算完全不同。
        #    顺便把 on/off 配对算成"时长", 这样一眼能看出每个音按了多久。
        #  ==================================================================
        #  ★★★ 2026-10-21: 录音只在**导出这一步**做"弹一次算一个音" ★★★
        #
        #  【为什么在这里做, 而不是改固件的消抖】
        #    光弦是"手指挡住光路", 手指在里面稍微一动, 光电管输出就会抖,
        #    于是一次按键被切成好几对 on/off (实测间隔约 120ms, 一次按键录成 5 对)。
        #    但**全局消抖不能动** —— 演奏模式那边的手感是对的, 改了会影响发声。
        #    所以只在这一路做合并, 和"曲谱指引模式单独处理"是同一个思路。
        #
        #  【算法】
        #    ① 配对: 同一音高 on 之后, 在它 off 之前再来的 on 视为抖动, 忽略;
        #    ② 合并: 相邻两段同音高、间隔 < $GAP 的, 合成一整段 (时长累加)。
        #    ★ $GAP 就是"多慢算两次按键"。150ms = 最快 6.7 次/秒, 旋律够用。
        #      嫌太粘就改小, 嫌还在拆就改大 —— 只影响导出的 CSV, 不影响声音。
        #  ==================================================================
        $GAP = 150
        $nmTab = @('C','C#','D','D#','E','F','F#','G','G#','A','A#','B')
        function Get-NoteName([int]$n) {
            return ("{0}{1}" -f $nmTab[$n % 12], ([int][Math]::Floor($n / 12) - 1))
        }

        #  ---- ① 配对 ----
        $segs = New-Object System.Collections.ArrayList
        $open = @{}
        foreach ($e in $script:recData) {
            if ($e.Kind -eq 1) {
                if (-not $open.ContainsKey($e.Note)) {
                    $open[$e.Note] = [pscustomobject]@{ Note=$e.Note; Vel=$e.Vel; Start=$e.T; End=$e.T }
                    [void]$segs.Add($open[$e.Note])
                }
                #  已经在按 -> 抖动, 忽略
            } elseif ($e.Kind -eq 2 -and $open.ContainsKey($e.Note)) {
                $open[$e.Note].End = $e.T
                $open.Remove($e.Note)
            }
        }

        #  ---- ② 合并相邻同音段 ----
        $merged = New-Object System.Collections.ArrayList
        foreach ($s in $segs) {
            $hit = $null
            if ($merged.Count -gt 0) {
                $last = $merged[$merged.Count - 1]
                if ($last.Note -eq $s.Note -and ($s.Start - $last.End) -lt $GAP) { $hit = $last }
            }
            if ($hit) { $hit.End = $s.End }
            else { [void]$merged.Add([pscustomobject]@{ Note=$s.Note; Vel=$s.Vel; Start=$s.Start; End=$s.End }) }
        }

        #  ---- 输出 ----
        $lines = @('index,note,makenote,velocity,start_ms,start_seconds,duration_ms')
        $i = 0
        foreach ($m in $merged) {
            $d = $m.End - $m.Start
            $lines += ("{0},{1},{2},{3},{4},{5},{6}" -f $i, $m.Note, (Get-NoteName $m.Note), $m.Vel,
                       $m.Start, [Math]::Round($m.Start / 1000.0, 4), $d)
            $i++
        }
        $lines += ''
        $lines += ('# 原始事件 {0} 条 -> 合并后 {1} 个音 (合并间隔 < {2}ms)' -f $script:recData.Count, $i, $GAP)
        $lines += '# 时间戳单位 = 毫秒 (固件 ev_tick)' 
        $lines -join "`r`n" | Set-Content -Path $dlg.FileName -Encoding UTF8
        $lblRecMsg.Text = "已导出 $(Split-Path $dlg.FileName -Leaf)"
        Log "录音已导出: $($dlg.FileName)" $C_TX
    }
})

#  ======================================================================
#  ★★★ 2026-10-21 新增: 把录音事件渲染成 WAV ★★★
#    配对 + 合并的规则和 CSV 导出完全一致 (同音高、间隔 < 150ms 视为一次按键)。
#    合成: 正弦 + ADSR (起音 5ms / 衰减 80ms / 保持 0.6 / 松手后 120ms 释放)
#    采样率 44100, 16 位单声道。
#  ======================================================================
#  ======================================================================
#  ★★★ 2026-10-21: 录音回放 (试听 / 存 WAV 共用一套渲染) ★★★
#
#  【为什么是"电脑合成"而不是"录下来的声音"】
#    FPGA 侧录的是**事件表** (音高/力度/时长), 不是音频 ——
#    32 声部 x 93750Hz x 16bit = 6MB/s, 而 rec_mem 只有 1KB、UART 11.5KB/s,
#    差三个数量级, 物理上录不了。所以回放只能靠电脑重新合成。
#    音色用最简单的正弦 + ADSR, 目的是"确认弹了什么", 不是还原 FPGA 的音色。
#
#  【函数返回】@{ Bytes; Notes; Secs }
#  【合并阈值】$script:RecGap
#    弹太快时几个音可能被并成一个。这个值就是"多慢算两次按键":
#    调小 -> 更不容易粘; 调大 -> 更容易把抖动合成一个音。
#  ======================================================================
$script:RecGap = 120

function Build-RecWav {
    $GAP = [int]$script:RecGap
    if (-not $script:recData -or $script:recData.Count -eq 0) { return $null }

    #  ---- ① 配对: 同一音高, off 之前再来的 on 视为抖动 ----
    $segs = New-Object System.Collections.ArrayList
    $open = @{}
    foreach ($e in $script:recData) {
        if ($e.Kind -eq 1) {
            if (-not $open.ContainsKey($e.Note)) {
                $open[$e.Note] = [pscustomobject]@{ Note=$e.Note; Vel=$e.Vel; Start=$e.T; End=$e.T }
                [void]$segs.Add($open[$e.Note])
            }
        } elseif ($e.Kind -eq 2 -and $open.ContainsKey($e.Note)) {
            $open[$e.Note].End = $e.T
            $open.Remove($e.Note)
        }
    }

    #  ---- ② 合并: 相邻同音高且间隔 < GAP 的并成一段 ----
    $merged = New-Object System.Collections.ArrayList
    foreach ($s in $segs) {
        $hit = $null
        if ($merged.Count -gt 0) {
            $last = $merged[$merged.Count - 1]
            if ($last.Note -eq $s.Note -and ($s.Start - $last.End) -lt $GAP) { $hit = $last }
        }
        if ($hit) { $hit.End = $s.End }
        else { [void]$merged.Add([pscustomobject]@{ Note=$s.Note; Vel=$s.Vel; Start=$s.Start; End=$s.End }) }
    }
    if ($merged.Count -eq 0) { return $null }

    #  ---- ③ 波形表: 和板子 wave_rom 里的 8 种音色一致 ----
    #  ★ 为什么用波形表而不是纯正弦:
    #    用户反馈"回放的音色和板子上听起来不一样" —— 因为原来只用了 sine。
    #    这里复现 sim/gen_wavetable.py 里的 8 个 w_* 函数, 音色特征就对上了:
    #      SINE / TRI / SAW / SQR / PLS25 / PLS12 / MIX / REED
    #    ★ 板子上的表是**按 mip 带限**的 (防混叠), 这里用理想波形 ——
    #      高音会有轻微混叠, 但那是"预览"可以接受的程度, 换来的代码量小得多。
    $tb = 0
    try { $tb = [int]$rowTimbre.num.SelectedIndex } catch { $tb = 0 }
    if ($tb -lt 0 -or $tb -gt 7) { $tb = 0 }
    $NT = 4096
    $tab = New-Object 'double[]' $NT
    for ($q = 0; $q -lt $NT; $q++) {
        $ph0 = $q / [double]$NT
        $v = 0.0
        switch ($tb) {
            0 { $v = [Math]::Sin(2.0 * [Math]::PI * $ph0) }
            1 { $v = 1.0 - 4.0 * [Math]::Abs($ph0 - 0.5) }
            2 { $v = 2.0 * $ph0 - 1.0 }
            3 { $v = $(if ($ph0 -lt 0.5) { 1.0 } else { -1.0 }) }
            4 { $v = $(if ($ph0 -lt 0.25) { 1.0 } else { -1.0 / 3.0 }) }
            5 { $v = $(if ($ph0 -lt 0.125) { 1.0 } else { -1.0 / 7.0 }) }
            6 { $v = [Math]::Sin(2.0 * [Math]::PI * $ph0) + (1.0 - 4.0 * [Math]::Abs($ph0 - 0.5)) }
            7 { $v = ([Math]::Abs([Math]::Sin(2.0 * [Math]::PI * $ph0)) - 2.0 / [Math]::PI) * 1.75 }
        }
        $tab[$q] = $v
    }
    $pk0 = 0.0
    foreach ($v in $tab) { $a0 = [Math]::Abs($v); if ($a0 -gt $pk0) { $pk0 = $a0 } }
    if ($pk0 -gt 1e-9) { for ($q = 0; $q -lt $NT; $q++) { $tab[$q] = $tab[$q] / $pk0 } }
    #  每种波形的音量配平 (方波/锯齿同峰值比正弦响得多, 不压一下会一个刺耳一个听不见)
    #  ★ 不再用固定增益表: 最后一步按 **RMS 配平** (见下面 ⑤) ——
    #    板子的波表是按 A 计权响度配平到同一个响度的, 这里用 RMS 近似,
    #    效果是"换音色不换音量", 和板子上的听感一致。
    $tname = if ($script:TimbreNames -and $tb -lt $script:TimbreNames.Count) { $script:TimbreNames[$tb] } else { "T$tb" }

    #  ---- ④ 渲染 ----
    $SR = 44100; $REL = 68.0          #  释放 68ms, 和板子的 ADSR 一致
    #  ★★★ 2026-10-21 修 BUG: 原来用 Measure-Object 求最小 Start ★★★
    #    【症状】弹 4 个音, 导出的 WAV 只有 **一个音** (时长也只有 0.23 秒)。
    #    【根因】($merged | Measure-Object -Property Start -Minimum).Minimum
    #      在这个函数里返回的是**最大值**而不是最小值 (孤立测同一条表达式是对的,
    #      进函数就变了)。于是 $t0 取到了最后一个音的起点, 缓冲区只够第一个音,
    #      后面几个音全都因为 $s0 >= $N 被 break 掉。
    #    【修法】改成显式循环求最小/最大, 不依赖 Measure-Object 的行为。
    $t0 = $merged[0].Start
    foreach ($m in $merged) { if ($m.Start -lt $t0) { $t0 = $m.Start } }
    $tEndMax = 0.0
    foreach ($m in $merged) {
        $v = $m.End - $t0 + $REL
        if ($v -gt $tEndMax) { $tEndMax = $v }
    }
    if ($tEndMax -gt 60000) { $tEndMax = 60000 }
    #  ★★★ 2026-10-21 第二个 BUG: PowerShell 变量名**不区分大小写** ★★★
    #    $N (缓冲区长度 51289) 和循环里的 $n (单音长度 239) 是**同一个变量** ——
    #    $n 把 $N 覆盖掉之后, 写文件只写了最后一个音的长度 (0.23 秒),
    #    于是"弹 4 个音只听到 1 个音"。改名彻底分开。
    $nSamp = [int]($tEndMax * $SR / 1000.0) + 1
    if ($nSamp -lt 1) { return $null }
    $buf = New-Object 'double[]' $nSamp

    foreach ($m in $merged) {
        $freq = 440.0 * [Math]::Pow(2.0, ($m.Note - 69) / 12.0)
        $amp  = ($m.Vel / 255.0) * 0.45
        $hold = [double]($m.End - $m.Start)
        $life = $hold + $REL
        $s0   = [int](($m.Start - $t0) * $SR / 1000.0)
        $ns   = [int]($life * $SR / 1000.0)
        if ($ns -le 0) { continue }
        #  ★ ADSR 时间常数改用板子的: 起音 4ms / 衰减 68ms / 保持 0.6 / 释放 68ms
        $ph  = 0.0
        $dph = $freq / [double]$SR
        for ($k = 0; $k -lt $ns; $k++) {
            $idx = $s0 + $k
            if ($idx -ge $nSamp) { break }
            $ms = $k * 1000.0 / $SR
            if ($ms -lt 4.0)       { $e = $ms / 4.0 }
            elseif ($ms -lt 72.0)  { $e = 1.0 - 0.4 * (($ms - 4.0) / 68.0) }
            else                   { $e = 0.6 }
            if ($ms -gt $hold) {
                $r = ($ms - $hold) / $REL
                if ($r -ge 1.0) { $e = 0.0 } else { $e = $e * (1.0 - $r) }
            }
            $tv = $tab[[int]($ph * $NT)]
            $buf[$idx] = $buf[$idx] + $amp * $e * $tv
            $ph += $dph
            if ($ph -ge 1.0) { $ph -= 1.0 }
        }
    }

    #  ---- ④ 归一化 + 转 Int16 ----
    #  ---- ⑤ 按 RMS 配平 + 峰值保护 ----
    #  ★ 为什么用 RMS 不用峰值:
    #    方波/锯齿的峰值和正弦一样是 1, 但 RMS 大得多 —— 只按峰值归一化,
    #    听感上 SQR 会比 SINE 响一大截。板子的波表是按 A 计权**响度**配平的
    #    (gen_wavetable.py 的 SPREAD_DB=0), 这里用 RMS 近似同一个效果。
    #  ★ 峰值保护: RMS 配平后如果某个音的峰值超过 0.95, 再整体压一次, 防削波。
    #  ★ 按**波形表自身的 RMS**配平, 不是按缓冲区 RMS ★
    #    为什么: 缓冲区里大部分是静音 (4 个音只占 28% 的时长),
    #    对整个缓冲区算 RMS 会被静音拉低, 结果每种音色的缩放系数都不对。
    #    波形表是满占空的一个周期, 用它的 RMS 才能反映"这个波形本身有多响"。
    $t2 = 0.0
    for ($q = 0; $q -lt $NT; $q++) { $t2 += $tab[$q] * $tab[$q] }
    $tabRms = [Math]::Sqrt($t2 / $NT)
    if ($tabRms -lt 1e-6) { $tabRms = 0.7071 }
    #  正弦的 RMS = 0.7071, 以它为 1.0 基准 -> 方波会被压、锯齿会被抬
    $bal = 0.7071 / $tabRms
    $k2  = 2.2 * $bal
    $peak = 0.0
    for ($i = 0; $i -lt $nSamp; $i++) { $a = [Math]::Abs($buf[$i] * $k2); if ($a -gt $peak) { $peak = $a } }
    if ($peak -gt 0.95) { $k2 = $k2 * (0.95 / $peak) }
    $dataBytes = $nSamp * 2
    $ms2 = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms2)
    $bw.Write([char[]]'RIFF'); $bw.Write([int](36 + $dataBytes))
    $bw.Write([char[]]'WAVE'); $bw.Write([char[]]'fmt ')
    $bw.Write([int]16); $bw.Write([int16]1); $bw.Write([int16]1)
    $bw.Write([int]$SR); $bw.Write([int]($SR * 2))
    $bw.Write([int16]2); $bw.Write([int16]16)
    $bw.Write([char[]]'data'); $bw.Write([int]$dataBytes)
    for ($i = 0; $i -lt $nSamp; $i++) {
        $v = [int][Math]::Round($buf[$i] * $k2 * 32767.0)
        if ($v -gt 32767) { $v = 32767 } elseif ($v -lt -32768) { $v = -32768 }
        $bw.Write([int16]$v)
    }
    $bw.Flush()
    $bytes = $ms2.ToArray()
    $bw.Close(); $ms2.Close()
    return [pscustomobject]@{ Bytes = $bytes; Notes = $merged.Count; Secs = ($nSamp / $SR); Timbre = $tname }
}

#  ---- 试听: 不落盘 ----
$btnRecWav.Add_Click({
    if (-not $script:recData -or $script:recData.Count -eq 0) { $lblRecMsg.Text = "没有录音"; return }
    $lblRecMsg.Text = "渲染中..."
    [System.Windows.Forms.Application]::DoEvents()
    $r = Build-RecWav
    if (-not $r) { $lblRecMsg.Text = "没有可播放的音"; return }
    $lblRecMsg.Text = ("{0} 个音 / {1:F1} 秒  {2}" -f $r.Notes, $r.Secs, $r.Timbre)
    try {
        $ms = New-Object System.IO.MemoryStream(, $r.Bytes)
        $pl = New-Object System.Media.SoundPlayer($ms)
        $pl.PlaySync()
        $pl.Dispose(); $ms.Close()
    } catch {
        $lblRecMsg.Text = ("播放失败: " + $_.Exception.Message)
    }
})

#  ---- 存 WAV ----
$btnRecSaveWav.Add_Click({
    if (-not $script:recData -or $script:recData.Count -eq 0) { $lblRecMsg.Text = "没有录音"; return }
    $r = Build-RecWav
    if (-not $r) { $lblRecMsg.Text = "没有可导出的音"; return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = "WAV 文件|*.wav"
    $dlg.FileName = ("演奏回放_{0}.wav" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($dlg.ShowDialog() -eq 'OK') {
        [System.IO.File]::WriteAllBytes($dlg.FileName, $r.Bytes)
        $lblRecMsg.Text = ("已存 {0} 个音 / {1:F1} 秒  {2}" -f $r.Notes, $r.Secs, $r.Timbre)
        Log ("WAV 已保存: {0}  ({1} 个音)" -f $dlg.FileName, $r.Notes) $C_TX
    }
})

$chkScore.Add_CheckedChanged({
    $script:ledScoreOn = $chkScore.Checked
    #  ★★★ 2026-10-11 修: 必须把**两个**面板都重绘 ★★★
    #   坑: 原来只写了 $ledPanel.Invalidate(), 忘了简谱面板 ——
    #   于是勾上「曲谱模式」后灯带变了, **简谱还停在占位文字上**。
    #   (用户反馈: "为什么我勾选后没有立刻显示")
    $ledPanel.Invalidate()
    $jpPanel.Invalidate()
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    #  ★ 开关状态放 bit0
    $bits = [byte]$(if ($chkScore.Checked) { 1 } else { 0 })
    $r = Send-Score $bits "曲谱模式=$(if($chkScore.Checked){'开'}else{'关'})"
    $lblScoreMsg.Text = "曲谱模式 -> $r"
})

$btnScorePlay.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    #  ★ 播放/暂停: 保持开关状态, 只发一个控制位
    #    固件里 bit0 是开关, 所以这里把当前开关状态一起发
    $bit0 = if ($chkScore.Checked) { 1 } else { 0 }
    $r = Send-Score ([byte]($bit0 -bor 0x08)) "播放/暂停"
    $lblScoreMsg.Text = "播放/暂停 -> $r"
})
$btnScoreRst.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $bit0 = if ($chkScore.Checked) { 1 } else { 0 }
    $r = Send-Score ([byte]($bit0 -bor 0x02)) "重置到开头"
    $lblScoreMsg.Text = "重置 -> $r"
})
$btnScoreNext.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $bit0 = if ($chkScore.Checked) { 1 } else { 0 }
    $r = Send-Score ([byte]($bit0 -bor 0x04)) "下一首"
    $lblScoreMsg.Text = "下一首 -> $r"
})

$rowTimbre.btn.Add_Click({
    $v = Get-SelNum $rowTimbre.num
    if ($v -lt 0) { Log "请先选一个音色" $C_ERR; return }
    $r = Write-Reg 1 ([byte]$v)
    $lblCfgMsg.Text = "音色=$($script:TimbreNames[$v])`r`n$r"
})
$rowSens.btn.Add_Click({
    $v = Get-SelNum $rowSens.num
    $r = Write-Reg 5 ([byte]$v)
    $lblCfgMsg.Text = "灵敏度档=$v`r`n$r"
})

#  ==================================================================
#  ★★ 2026-10-18: 键位自定义对话框
#     10 根弦各自可以映射到任意音 (MIDI 0..127)
#  ==================================================================
#  音名表: 12 个音级 x 八度。 MIDI 0 = C-1
$script:NoteNames = @()
$script:NotePcs   = @('C','C#','D','D#','E','F','F#','G','G#','A','A#','B')
for ($mi = 0; $mi -lt 128; $mi++) {
    $script:NoteNames += ("{0}{1}" -f $script:NotePcs[$mi % 12], ([int][Math]::Floor($mi / 12) - 1))
}
#  ★ KmapDefault 已在文件前面定义 (单一数据源), 这里不重复
$script:KmapBoxes   = @()

#  ==================================================================
#  ★★ 2026-10-18: 预设方案 (给不懂乐理的人用)
#     每个预设 = 10 个 MIDI 音高, 选了就自动填满 10 个下拉框。
#     ★ 排序按"对新手的友好度", 不是按理论顺序。
#  ==================================================================
$script:KmapPresets = @(
    @{ short='默认 do-re-mi'; name='默认 do-re-mi  (C 大调白键)';
       desc='小学音乐课那个 do re mi';
       map=@(60,62,64,65,67,69,71,72,74,76);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='★ 五声音阶'; name='★ 五声音阶  (推荐! 怎么弹都不难听)';
       desc='没有半音, 不会出现不协和的声音 —— 演示首选';
       map=@(60,62,64,67,69,72,74,76,79,81);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='半音阶'; name='半音阶  (一个八度内全部 10 个半音)';
       desc='什么音都能弹, 但容易出错音';
       map=@(60,61,62,63,64,65,66,67,68,69);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='布鲁斯'; name='布鲁斯  (蓝调, 带点悲伤味)';
       desc='C 蓝调音阶: C Eb F F# G Bb ...';
       map=@(60,63,65,66,67,70,72,75,77,78);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='小调音阶'; name='小调音阶  (A 自然小调, 忧伤)';
       desc='比大调暗一点, 适合慢歌';
       map=@(57,59,60,62,64,65,67,69,71,72);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='日本都节'; name='日本都节  (东方味道)';
       desc='D 都节音阶, 一听就是日系风';
       map=@(62,63,67,69,70,74,75,79,81,82);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='全音阶'; name='全音阶  (梦幻飘浮)';
       desc='每个音相差两个半音, 听着像梦里';
       map=@(60,62,64,66,68,70,72,74,76,78);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='低音贝斯'; name='低音贝斯  (当低音伴奏用)';
       desc='整体降两个八度, 混音会很厚';
       map=@(36,43,45,48,50,52,55,57,60,62);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='吉他调弦';
       name='吉他调弦  (EADGBE, 横放式按法)';
       desc='标准吉他六根弦的音 E A D G B E, 再往上延两个八度';
       map=@(40,45,50,55,59,64,69,74,79,83);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='五度叠加';
       name='五度叠加  (空五度, 有力量感)';
       desc='根音与五度音交替 C-G-C-G ..., 摇滚和弦那个味道';
       map=@(48,55,60,67,72,79,84,91,96,103);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='八度跳跃';
       name='八度跳跃  (相邻两根差一个八度)';
       desc='C4 C5 D4 D5 E4 E5 ..., 两根一组, 同一个音不同高度';
       map=@(60,72,62,74,64,76,65,77,67,79);
       kinds=@(0,0,0,0,0,0,0,0,0,1) },

    @{ short='8音+2功能';
       name='8音 + 变调 + 音色  (演示功能弦)';
       desc='前 8 根正常发音, 第 9 根变调, 第 10 根换音色 —— 一只手弹一只手操控';
       map=@(60,62,64,65,67,69,71,72,72,72);
       kinds=@(0,0,0,0,0,0,0,0,1,2) }
)
$script:KmapPresetSel = 0

#  ★ 把当前方案名写到主界面的按钮上 (按钮宽 150px, 所以用 short 字段)
function Update-KmapButton {
    param([int]$PresetIdx = -1)
    if (-not $btnKeymap) { return }
    if ($PresetIdx -ge 0 -and $PresetIdx -lt $script:KmapPresets.Count) {
        $btnKeymap.Text = ("键位: " + $script:KmapPresets[$PresetIdx].short)
    } elseif ($script:KmapPresetSel -ge 0 -and $script:KmapPresetSel -lt $script:KmapPresets.Count) {
        $btnKeymap.Text = ("键位: " + $script:KmapPresets[$script:KmapPresetSel].short)
    } else {
        $btnKeymap.Text = "键位: 自定义"
    }
}

#  ★ 拿 10 个音去和每个预设比, 命中返回序号, 否则 -1
function Detect-KmapPreset {
    param($Map)
    for ($di = 0; $di -lt $script:KmapPresets.Count; $di++) {
        $pm = $script:KmapPresets[$di].map
        $same = $true
        for ($dk = 0; $dk -lt 10; $dk++) {
            if ([int]$pm[$dk] -ne [int]$Map[$dk]) { $same = $false; break }
        }
        if ($same) { return $di }
    }
    return -1
}

#  ==================================================================
#  ★★ 2026-10-18: 对话框**只建一次**, 之后复用 (原来每次点开都重建 1280 个列表项)
#     关闭改成 Hide(), 不销毁控件 —— 第二次开就是瞬间的。
#  ==================================================================
$script:KeymapDlg = $null

function Build-KeymapDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "键位自定义  —  每根弦想发什么音"
    $dlg.Size = New-Object System.Drawing.Size(500, 510)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $C_PANEL; $dlg.ForeColor = $C_TEXT
    $dlg.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = "每根弦都可以选「音弦」或「功能弦」。选功能弦后右边的音名不再生效。"
    $tip.Location = New-Object System.Drawing.Point(14, 6)
    $tip.Size = New-Object System.Drawing.Size(380, 30)
    $tip.ForeColor = $C_SUB
    $dlg.Controls.Add($tip)

    $plab = New-Object System.Windows.Forms.Label
    $plab.Text = "预设:"
    $plab.Location = New-Object System.Drawing.Point(14, 42)
    $plab.Size = New-Object System.Drawing.Size(46, 22)
    $plab.ForeColor = $C_TEXT
    $dlg.Controls.Add($plab)

    $script:KeymapPcb = New-Object System.Windows.Forms.ComboBox
    $script:KeymapPcb.DropDownStyle = 'DropDownList'
    $pnames = New-Object object[] $script:KmapPresets.Count
    for ($pi2 = 0; $pi2 -lt $script:KmapPresets.Count; $pi2++) {
        $pnames[$pi2] = $script:KmapPresets[$pi2].name
    }
    [void]$script:KeymapPcb.Items.AddRange($pnames)          #  ★ AddRange: 一次调用而不是 N 次
    $script:KeymapPcb.Location = New-Object System.Drawing.Point(62, 40)
    $script:KeymapPcb.Size = New-Object System.Drawing.Size(340, 26)
    $script:KeymapPcb.SelectedIndex = 0
    $dlg.Controls.Add($script:KeymapPcb)

    $script:KeymapPdesc = New-Object System.Windows.Forms.Label
    $script:KeymapPdesc.Text = $script:KmapPresets[0].desc
    $script:KeymapPdesc.Location = New-Object System.Drawing.Point(62, 68)
    $script:KeymapPdesc.Size = New-Object System.Drawing.Size(340, 18)
    $script:KeymapPdesc.ForeColor = $C_ACCENT
    $dlg.Controls.Add($script:KeymapPdesc)

    #  ★ 缓存成 [object[]], AddRange 直接用, 不用每次转型
    $noteArr = New-Object object[] 128
    for ($ni = 0; $ni -lt 128; $ni++) { $noteArr[$ni] = $script:NoteNames[$ni] }

    #  ★★ 2026-10-18: 每行现在是  弦N [类型] [音名]
    #     类型 = 音弦 / 变调 / 音色 / 八度 / 力度 / 音量
    #     选了功能弦后, 右边的音名下拉会变灰 (它不再发音)
    $kindArr = New-Object object[] $script:KindNames.Count
    for ($kni = 0; $kni -lt $script:KindNames.Count; $kni++) { $kindArr[$kni] = $script:KindNames[$kni] }

    $script:KmapBoxes  = @()
    $script:KindBoxes  = @()
    for ($ki = 0; $ki -lt 10; $ki++) {
        $ky = 90 + $ki * 31
        $lab = New-Object System.Windows.Forms.Label
        $lab.Text = ("弦 {0}" -f ($ki + 1))
        $lab.Location = New-Object System.Drawing.Point(14, ($ky + 4))
        $lab.Size = New-Object System.Drawing.Size(46, 22)
        $lab.ForeColor = $C_TEXT
        $dlg.Controls.Add($lab)

        $kcb = New-Object System.Windows.Forms.ComboBox
        $kcb.DropDownStyle = 'DropDownList'
        [void]$kcb.Items.AddRange($kindArr)
        $kcb.Location = New-Object System.Drawing.Point(62, $ky)
        $kcb.Size = New-Object System.Drawing.Size(78, 26)
        $kcb.SelectedIndex = $script:KindsDefault[$ki]
        $dlg.Controls.Add($kcb)
        $script:KindBoxes += $kcb

        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'
        [void]$cb.Items.AddRange($noteArr)      #  ★ 128 项一次加完
        $cb.Location = New-Object System.Drawing.Point(146, $ky)
        $cb.Size = New-Object System.Drawing.Size(150, 26)
        $cb.SelectedIndex = $script:KmapDefault[$ki]
        $dlg.Controls.Add($cb)
        $script:KmapBoxes += $cb
    }

    $script:KeymapMsg = New-Object System.Windows.Forms.Label
    $script:KeymapMsg.Text = ""
    $script:KeymapMsg.Location = New-Object System.Drawing.Point(16, 402)
    $script:KeymapMsg.Size = New-Object System.Drawing.Size(380, 20)
    $script:KeymapMsg.ForeColor = $C_ACCENT
    $dlg.Controls.Add($script:KeymapMsg)

    $bApply = New-Object System.Windows.Forms.Button
    $bApply.Text = "全部应用到板子"
    $bApply.Location = New-Object System.Drawing.Point(16, 430)
    $bApply.Size = New-Object System.Drawing.Size(150, 30)
    $bApply.FlatStyle = 'Flat'; $bApply.FlatAppearance.BorderSize = 0
    $bApply.BackColor = [System.Drawing.Color]::FromArgb(140, 200, 160)
    $dlg.Controls.Add($bApply)

    $bDef = New-Object System.Windows.Forms.Button
    $bDef.Text = "恢复默认"
    $bDef.Location = New-Object System.Drawing.Point(176, 430)
    $bDef.Size = New-Object System.Drawing.Size(96, 30)
    $bDef.FlatStyle = 'Flat'; $bDef.FlatAppearance.BorderSize = 0
    $bDef.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
    $dlg.Controls.Add($bDef)

    $bClose = New-Object System.Windows.Forms.Button
    $bClose.Text = "关闭"
    $bClose.Location = New-Object System.Drawing.Point(282, 430)
    $bClose.Size = New-Object System.Drawing.Size(96, 30)
    $bClose.FlatStyle = 'Flat'; $bClose.FlatAppearance.BorderSize = 0
    $bClose.BackColor = [System.Drawing.Color]::FromArgb(230,232,236)
    $dlg.Controls.Add($bClose)

    #  ---- 下发全部 10 槽 ----
    $script:KeymapSendAll = {
        param($silent)
        if (-not $script:connected) { $script:KeymapMsg.Text = "未连接"; $script:KeymapMsg.ForeColor = $C_ERR; return $false }
        $cur = @()
        $kindsNow = @()
        for ($si = 0; $si -lt 10; $si++) {
            $v = $script:KmapBoxes[$si].SelectedIndex
            if ($v -lt 0) { $v = $script:KmapDefault[$si] }
            $cur += [int]$v
            $kk = $script:KindBoxes[$si].SelectedIndex
            if ($kk -lt 0) { $kk = 0 }
            $kindsNow += [int]$kk
        }
        $okAll = Push-Keymap $cur $true $kindsNow
        if ($okAll) {
            Save-Keymap $cur $kindsNow
            $script:KmapSaved = $cur
            $script:KindsSaved = $kindsNow
            #  ★ 下发完自动识别对应哪个预设, 按钮文字跟着变
            $script:KmapPresetSel = Detect-KmapPreset $cur
            Update-KmapButton $script:KmapPresetSel
            $script:KeymapMsg.Text = "✅ 10 根弦已下发, 并已保存到本地"
            $script:KeymapMsg.ForeColor = [System.Drawing.Color]::FromArgb(0, 140, 70)
            Log ("键位已下发: " + (($cur | ForEach-Object { $script:NoteNames[$_] }) -join ' ')) $C_TX
        } else {
            $script:KeymapMsg.Text = "⚠ 下发失败, 看通信日志"
            $script:KeymapMsg.ForeColor = $C_ERR
        }
        return $okAll
    }

    #  ---- 选预设 = 一键更换 ----
    $script:KeymapPcb.Add_SelectedIndexChanged({
        $pi = $script:KeymapPcb.SelectedIndex
        if ($pi -lt 0 -or $pi -ge $script:KmapPresets.Count) { return }
        $pm = $script:KmapPresets[$pi]
        $script:KeymapPdesc.Text = $pm.desc
        for ($qi = 0; $qi -lt 10; $qi++) {
            $script:KmapBoxes[$qi].SelectedIndex = [int]$pm.map[$qi]
            #  ★ 预设也带类型; 没写 kinds 的老预设用默认
            if ($pm.kinds) { $script:KindBoxes[$qi].SelectedIndex = [int]$pm.kinds[$qi] }
            else           { $script:KindBoxes[$qi].SelectedIndex = [int]$script:KindsDefault[$qi] }
        }
        $script:KmapPresetSel = $pi
        Update-KmapButton $pi
        if ($script:connected) {
            [void](& $script:KeymapSendAll $false)
        } else {
            $script:KeymapMsg.Text = "未连接 —— 板子上还是旧键位, 连上后会自动下发"
            $script:KeymapMsg.ForeColor = $C_ERR
        }
    })

    $bApply.Add_Click({ [void](& $script:KeymapSendAll $false) })
    $bDef.Add_Click({
        for ($di = 0; $di -lt 10; $di++) {
            $script:KmapBoxes[$di].SelectedIndex = $script:KmapDefault[$di]
            $script:KindBoxes[$di].SelectedIndex = $script:KindsDefault[$di]
        }
        $script:KmapPresetSel = 0
        Update-KmapButton 0
        $script:KeymapMsg.Text = "已恢复为默认音位 (还要点一下「全部应用」)"
        $script:KeymapMsg.ForeColor = $C_SUB
    })
    #  ★ 关闭改成 Hide: 下次点开直接复用, 不重建
    #  ★ 必须用 $script:KeymapDlg —— $dlg 是函数局部变量,
    #    按钮事件是函数 return 之后才触发的, 那时 $dlg 已经是 $null。
    $bClose.Add_Click({ if ($script:KeymapDlg) { $script:KeymapDlg.Hide() } })

    #  ★ 点右上角 X 也走 Hide, 否则窗体被销毁后名字变成一堆方块
    $dlg.Add_FormClosing({
        param($sf, $se)
        if ($se.CloseReason -eq 'UserClosing') {
            $se.Cancel = $true
            $sf.Hide()
        }
    })

    return $dlg
}

$btnKeymap.Add_Click({
    #  ★ 第一次才建, 之后直接复用 —— 这就是"开得快"的关键
    if (-not $script:KeymapDlg) {
        $script:KeymapDlg = Build-KeymapDialog
    }
    #  把当前保存的键位同步到下拉框
    if ($script:KmapSaved -and $script:KmapSaved.Count -eq 10) {
        for ($si = 0; $si -lt 10; $si++) {
            $script:KmapBoxes[$si].SelectedIndex = [int]$script:KmapSaved[$si]
            if ($script:KindsSaved -and $script:KindsSaved.Count -eq 10) {
                $script:KindBoxes[$si].SelectedIndex = [int]$script:KindsSaved[$si]
            }
        }
    }
    [void]$script:KeymapDlg.ShowDialog()
})

#  ---- ★ 新增四个维度 (用 8 位扩展命令) ----
#   命令码必须避开已占用的! 这个坑踩过两次:
#     0x52 已是 'R'(读寄存器), 0x53 已是 'S'(读测试档), 0x54 已是 'T'
#   现在用: 0x50 音量 / 0x51 力度 / 0x55 颤音 / 0x58 合唱
function Write-Reg8 {
    param([byte]$Code, [byte]$Val, [string]$Name)
    $f = [byte[]]@(0xA5,$Code,$Val,0x5A)
    $r = Send-Frame $script:sp $f 350
    Log ("发  {0}   ->  {1}   [{2}={3}]" -f (($f|ForEach-Object{'{0:X2}' -f $_}) -join ' '), $r, $Name, $Val) $C_TX
    return $r
}

$rowVol.btn.Add_Click({
    $v = Get-SelNum $rowVol.num
    if ($v -lt 0 -or $v -gt 255) { Log "音量必须 0~255" $C_ERR; return }
    $r = Write-Reg8 0x50 ([byte]$v) '音量'
    $lblCfgMsg.Text = "音量=$v`r`n$r"
})
$rowVel.btn.Add_Click({
    $v = Get-SelNum $rowVel.num
    $r = Write-Reg8 0x51 ([byte]$v) '力度'
    $lblCfgMsg.Text = "力度=$v`r`n$r"
})
$rowVib.btn.Add_Click({
    $v = Get-SelNum $rowVib.num
    $r = Write-Reg8 0x55 ([byte]$v) '颤音'
    $lblCfgMsg.Text = "颤音深度=$v`r`n$r"
})
$rowChorus.btn.Add_Click({
    $v = Get-SelNum $rowChorus.num
    $r = Write-Reg8 0x58 ([byte]$v) '合唱'
    $lblCfgMsg.Text = "合唱=$(if($v -eq 1){'开'}else{'关'})`r`n$r"
})

$rowOct.btn.Add_Click({
    $v = Get-SelNum $rowOct.num
    $r = Write-Reg 7 ([byte]$v)
    $lblCfgMsg.Text = "八度=+$($v*12) 半音`r`n$r"
})

$btnSend.Add_Click({
    if (-not $script:connected) { Log "未连接" $C_ERR; return }
    $t = $txtIn.Text.Trim()
    if (-not $t) { return }
    try {
        $bytes = $t.Split(' ,;'.ToCharArray(), [System.StringSplitOptions]::RemoveEmptyEntries) |
                 ForEach-Object { [Convert]::ToByte($_,16) }
        $r = Send-Frame $script:sp ([byte[]]$bytes) 500
        Log ("发  {0}`r`n收  {1}" -f (($bytes|ForEach-Object{'{0:X2}' -f $_}) -join ' '), $r) $C_TX
    } catch { Log "解析失败: 请输入 16 进制, 例如  A5 4B 00 5A" $C_ERR }
})

$txtIn.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnSend.PerformClick(); $_.SuppressKeyPress = $true } })

$form.Add_Resize({ Fit-Split; Fit-RightW; Fit-LeftW; Fit-CfgRows })
$split.Add_SizeChanged({ Fit-Split; Fit-RightW; Fit-LeftW; Fit-CfgRows })

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:sp -and $script:sp.IsOpen) { $script:sp.Close() }
})

Refresh-Ports
[void]$form.ShowDialog()
