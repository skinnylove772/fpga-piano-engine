# 弦音芯生 — 基于 FPGA 的实时多音色合成电子乐器引擎

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 高云半导体 · **选题二**
>
> 开发板：Sipeed Tang Nano 20K（GW2AR-18C / GW2AR-LV18QN88C8/I7）
> 工具链：Gowin EDA V1.9.12　|　团队编号：**44964**

一台**没有 CPU 的电子琴**：全部声音运算、交互识别、效果处理与可视化显示，
都由一片 20K 门级的国产 FPGA 用硬件逻辑逐样本、逐声部并行完成。

---

## 一、关键指标

| 指标 | 数值 | 说明 |
|---|---|---|
| **复音数** | **32 声部** | 每声部含独立 24 位相位累加器 + 频率控制 + ADSR 包络 |
| **输出采样率** | **93 750 Hz** | I2S 位时钟 3 MHz ÷ 32 位/帧 |
| **振荡器吞吐量** | **3 000 000 次/秒** | 32 × 93 750，未使用过采样 |
| **演奏延迟** | **≈ 68 µs**（数字链路）<br>**≈ 80 µs**（至音频接口） | 全硬件确定性，抖动 ≤ 1 个采样周期 |
| **音色** | **8 种** | SINE / TRI / SAW / SQR / PLS25 / PLS12 / MIX / REED |
| **表情维度** | **5 维** | 力度 / 滑音 / 颤音 / 八度 / 变调 |
| **效果器** | **3 个**（RTL 实现） | 混响（2 梳状 + 2 全通）/ 延迟（87.4 ms）/ 合唱 |
| **资源占用** | Logic 19 011/20 736（92%）<br>CLS 10 034/10 368（97%）<br>BSRAM 46/46、DSP 19/24 | **MULT18X18 = 32**，与 32 声部一一对应 |

---

## 二、功能特性

### 演奏

- **十路红外光电弦**：遮挡光路即触发发声，多根同时遮挡即构成**和弦**
- **PAJ7620 手势**（非接触）：左右 → 八度，前后 → 力度，画圈 → 颤音
- **旋转编码器**：6 个页面切换 + 12 项参数调节
- **弦功能槽位**：10 槽可配置为 音弦 / 变调 / 音色 / 八度 / 力度 / 音量
- **键位自定义**：上位机可改写每个槽位的音高

### 合成

- 波表：**8 音色 × 8 级抗混叠子表 × 512 点 × 16 位**（单块 64 KiB ROM，采样帧内分时读取）
- 相位步长 `step = f × 2²⁴ / fs`，频率分辨率 0.0056 Hz；八度切换即一次移位
- ADSR 包络四段状态机，延音电平 4 档（100/50/25/12.5%）
- 混音按活跃声部数归一（32/N），和值与增益同拍锁存避免爆音

### 可视化

- **480×272 RGB 液晶**，6 个页面（HOME / MAIN / GRAPH / PARAM / MUSIC / TEST）
- **李萨如图形**：单音为圆、八度为"8"字，直接反映音程
- **8 段音高分布柱图**
- **WS2812 灯链 70 槽**（PCB 10 + 灯带 60，物理 80 颗）：弹奏流光、曲目指引、开机彩色铺展

### 智能化联动

- **脱机演奏**：内置 3 首曲目编入 bitstream，掉电不丢，LED 逐音指引
- **在线曲谱下载**：上位机 31 首曲库 → 串口下载至 2047 音 RAM
- **演奏录音回传**：记录「音高 + 力度 + 毫秒时间戳」事件流，PC 端导出 CSV 或重新合成 WAV

---

## 三、目录结构

```
piano.gprj                 Gowin 工程文件
_build.tcl                 命令行一键编译脚本
如何编译.txt                **编译/烧录说明（含中文路径警告，务必先读）**
src/
  top.v                    顶层：时钟、例化、键位扫描、测试模式、录音事件
  synth_engine.v           32 声部并行合成引擎（generate 展开）
  voice.v                  单声部：相位累加器 + 波表查表 + ADSR + 滑音
  adsr_env.v               ADSR 包络
  wave_rom.v               波表 ROM（8 音色 × 8 级 × 512 点）
  note_step.v              音符号 -> 24 位相位步长
  chorus.v / delay_fx.v / reverb_fx.v / fx_decim.v   三个效果器 + 公共抽取滤波
  audio_drive.v            I2S 串行发送（BCK / WS / DIN）
  spectrum.v               8 段音高分布
  lissajous.v              李萨如图形（BSRAM 位图）
  paj7620.v / i2c_master.v 手势传感器
  rotary_enc.v / menu_fsm.v / rotary_menu.v          编码器与菜单
  score_rom.v / score_ram.v / score_player.v         曲谱与播放/指引
  rec_ram.v                演奏录音缓冲
  uart_cmd.v / uart_rx_off.v / uart_tx_off.v         上位机串口协议
  ws2812_drv.v / ws2812_led.v                        LED 灯链
  osd_*.v / font5x7.v / vga_timing.v                 屏幕显示
  gowin_rpll/ gowin_vpll/                            PLL
  piano.cst                引脚约束
tbl/
  wave_tbl.mi              波表数据（$readmemh 载入，不可删）
upper/
  gui.ps1                  上位机主程序（PowerShell WinForms）
  keymap.json / scorelib_cache.json / 启动上位机.bat
impl/pnr/
  piano.fs                 **预编译比特流，可直接烧录**
  device.cfg               SSPI 引脚复用设置（不可删）
doc/
  FPGA_Piano_Technical_Report.pdf   设计报告
```

---

## 四、编译

> ⚠️ **路径必须纯英文**。Gowin 工具链不支持非 ASCII 路径，放在含中文的目录会报
> `ERROR (SP0002): Corrupted project file`。请把仓库放在如 `D:\fpga\piano` 的路径下。

### 图形界面

用 Gowin EDA 打开 `piano.gprj` → 确认 Top Module 为 **top** → 点 **Run All**

### 命令行

```bash
"C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe" _build.tcl
```

`_build.tcl` 内容：

```tcl
open_project piano.gprj
set_option -top_module top
set_option -place_option 2      # ← 必须: CLS 97%, 默认策略会布线失败
set_option -route_option 2
run all
```

---

## 五、烧录

**无需编译，仓库内已附预编译比特流**：

```bash
programmer_cli.exe -d GW2AR-18C -r 9 --fsFile impl/pnr/piano.fs --frequency 15MHz
```

| 参数 | 含义 |
|---|---|
| `-r 9` | 写入**外部 Flash**，掉电保持（脱机演奏需要） |
| `-r 2` | 只写 SRAM，断电即失 |

烧写 Flash **不会复位 FPGA**，需断电重上电后新配置才运行。

---

## 六、引脚分配（摘要）

| 功能 | 引脚 | 功能 | 引脚 |
|---|---|---|---|
| 系统时钟 27 MHz | 4 | I2S BCK / WS / DIN | **56 / 55 / 54** |
| 功放使能 PA_EN | 51 | WS2812 数据 | 80 |
| 编码器 A / B / 按键 | 15 / 16 / 17 | 按键 S1 / S2 | 88 / 87 |
| 上位机串口 TX / RX | 69 / 70 | 手势 I2C SCL / SDA | 85 / 86 |
| 光弦 key[0..6] | 71~76, 79 | 光弦 key[7..9] | 18 / 19 / 20 |
| LCD DCLK / HS / VS / DE | 77 / 25 / 26 / 48 | LCD R / G / B | 38~42 / 32~37 / 27~31 |

> 54 / 55 / 56 在 GW2AR-18C 上是 SSPI 专用引脚，需 `impl/pnr/device.cfg` 中
> `set SSPI regular_io = true` 才能作为普通 I/O 使用。

---

## 七、赛题要求对照

### 基础要求

| 条款 | 实现 |
|---|---|
| 多维交互 ≥ 2 维 | **5 维**：光弦 / 手势 / 编码器 / 弦功能 / 上位机 |
| 选音 · 触发 · 拨弦 · 力度 | 光弦遮挡触发；手势前后给力度；多弦同遮 = 和弦 |
| 纯 HDL 实时合成 | 全 Verilog，无 CPU、无软核 |
| 总延迟 ≤ 10 ms | **≈ 68 µs**（数字链路）/ **≈ 80 µs**（至音频接口） |
| 复音 ≥ 4 | **32** |
| 单音变调 / ADSR / 混音 | 滑音 + 八度 + 变调弦；`adsr_env.v`；按活跃声部归一 |
| 严禁预录 PCM | 波表仅存**单周期**，相位累加器逐样本合成 |

### 拓展要求

| 条款 | 实现 |
|---|---|
| 复音 ≥ 32 | **32 声部**，吞吐量 3 000 000 次/秒 |
| 表情 ≥ 3 维 | **5 维**（力度 / 滑音 / 颤音 / 八度 / 变调） |
| 音色 ≥ 2 种 | **8 种** |
| 混响 / 延迟 / 合唱 | 三个独立 RTL 模块 |
| 延迟 ≤ 5 ms 无抖动 | **≈ 68 µs**，抖动 ≤ 1 个采样周期 |
| 视听反馈 | LED 演奏指引 ✅ 李萨如图形 ✅ 实时频谱 ✅ |
| 脱机 LED 曲目指引 | ✅ 内置 3 首，掉电保持 |
| 在线曲谱下载 | ✅ 上位机 31 首 → 2047 音 |
| 键位自定义 | ✅ 10 槽 |
| 演奏录音回传 | ✅ 事件流 + CSV / WAV |
| 蓝牙 / 手机 App | 未实现（赛题为"可搭载"选项） |

---

## 八、说明

- 本工程为**纯硬件实时合成**，音频通路上不存在任何预录 PCM 数据：
  波表 ROM 中仅保存每种音色的**一个周期**波形（8 × 8 × 512 点），
  每个输出样本由相位累加器实时查表、乘包络后得到。
- 上位机的"试听"功能是在 **PC 端**按事件重新合成，不属于板上音频通路。
- 更完整的设计说明见 [`doc/FPGA_Piano_Technical_Report.pdf`](doc/FPGA_Piano_Technical_Report.pdf)。
