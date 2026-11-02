// top.v —— 基于 FPGA 的实时多音色合成电子乐器引擎 (Tang Nano 20K / GW2AR-LV18)

//   M1 音频地基: 一帧一个采样(tick = b_cnt==19), 左右声道送同一个值;
//                PA_EN 常开(不再跟随包络开关, 消除咔哒声)。
//   M2 并行引擎: 32 个完全并行的独立振荡器声部 + 每声部独立 ADSR + 力度缩放
//                + 饱和混音 + 自动增益归一化; 8 种音色; 测试模式用于频谱验证。
//   OSD 状态屏 : 480x272 RGB LCD 显示模式/音色/声部数/音名/实时波形。
module top(
    input        clk  ,  // 27MHz 晶振
    input  [9:0] key  ,
    input        s1   ,  // 板载按键1 (88), 按下=0: 八度切换
    input        s2   ,  // 板载按键2 (87), 按下=0: 下一个音色
    input        enc_a,  // 编码器 A 相 (模块丝印 CLK / A / S1)
    input        enc_b,  // 编码器 B 相 (模块丝印 DT  / B / S2)
    input        enc_sw,  // 编码器按键 (低有效)
    output       ws2812_dout,
    output       i2c_scl,
    inout        i2c_sda,
    //audio接口
    output       HP_BCK,  // I2S 位时钟 3MHz (采样率 93750Hz)
    output       HP_WS ,  // 左右声道切换 (低=左)
    output       HP_DIN,  // I2S 串行数据
    output       PA_EN ,  // 功放使能 (MAX98357A 的 SD/MODE, 常高)
    input        uart_rx ,
    output       uart_tx ,
    //RGB LCD 接口 (480x272, 与 HDMI 共用 40P 排针, 二者只能选一个)
    output       lcd_dclk,  // 像素时钟 9MHz
    output       lcd_hs  ,  // 行同步
    output       lcd_vs  ,  // 场同步
    output       lcd_de  ,  // 数据有效
    output [4:0] lcd_r   ,  // 红
    output [5:0] lcd_g   ,  // 绿
    output [4:0] lcd_b  // 蓝
);

    localparam NVOICE = 32;

    wire clk_4m5_w;  // PLL CLKOUT = 4.5MHz (本设计未直接使用, 留给以后扩展)
    wire clk_aud_w;  // PLL CLKOUTD3 = 3MHz, 音频位时钟 (采样率 93750Hz)

    reg [19:0] por_cnt;
    reg        rst_n;
    always @(posedge clk)
        if (!por_cnt[19]) por_cnt <= por_cnt + 1'b1;  // 计满后保持, 不回绕
    always @(posedge clk)
        rst_n <= por_cnt[19];

    Gowin_rPLL pll_27m_6m (
        .clkout   (clk_4m5_w),
        .clkoutd3 (clk_aud_w),
        .reset    (~rst_n),
        .clkin    (clk)
    );

    // 1. 采样帧同步
    //    b_cnt 是 audio_drive 的帧内位计数器(0~31), 一帧 = 一个输出采样。
    //    引擎在 b_cnt==19 推进一拍, 3 拍流水后音频在 b_cnt==22 稳定;
    //    而 audio_drive 在两个声道分别于 b_cnt==2 / ==18 取走数据 ——
    //    两次取到的是同一个采样值, 采样率 = 3MHz/32 = 93750 Hz。
    wire [4:0]  b_cnt;
    wire [15:0] audio_w;
    wire        req_w;
    wire        tick = (b_cnt == 5'd19);

    wire signed [15:0] pm_w;  // 颤音 LFO 输出 -> synth_engine 的 pm
    wire signed [15:0] audio_s;
    wire [7:0]  ucmd_byte;
    wire        ucmd_txreq;
    wire [2:0]  ucmd_cfg_timbre;
    wire        ucmd_cfg_timbre_en;
    wire        ucmd_host_on;  // 接管开关状态 (电平)
    wire [69:0] ucmd_keymap;
    wire [29:0] ucmd_kmap_kind;
    reg        str_timb_evt;  //  切下一个音色
    reg        str_oct_evt;  //  八度 +1
    reg        str_vel_evt;  //  力度 +1 档
    reg  [1:0] str_volx;
    reg        str_vol_on;
    //  扩展 8 位参数 (由 'A5 5X VV 5A' 写入)
    wire [7:0]  ucmd_cfg_vel;
    wire [2:0]  ucmd_cfg_vib;
    wire        ucmd_cfg_chorus;
    wire [7:0]  ucmd_cfg_fxamt;
    wire       menu_gest_w;  // 1 = 手势生效, 0 = 完全屏蔽
    wire       menu_ctype_w;
    wire       menu_dtype_w;
    wire       menu_rtype_w;
    //    synth_engine 的例化在前 (它要用 glide_lvl), 而 u_menu 在后。
    //    在中间声明的话前半段引用会被当成 1 位隐式线网 —— 高位全丢,
    wire [2:0]  menu_glide_w;  // 菜单里的滑音档位 0..6
    wire        menu_on_gl;  // 1 = 菜单改过滑音 (盖子) = 菜单说了算
    wire        ucmd_cfg_vel_en;
    wire        ucmd_cfg_vib_en;
    wire        ucmd_cfg_chorus_en;
    //      s1 = 测试模式入口, s2 = 播放/暂停 —— 两个键都用掉了,
    //      "换曲/重置"只能给上位机。而且这本来就是拓展 4 讲的
    //      "上位机联动", 用串口反而是加分项。
    wire        ucmd_score_set;  // 单拍脉冲: 设置曲谱模式开关
    wire        ucmd_score_on;  // 设置成什么 (1=开曲谱模式)
    //    原因: 它们在 uart_cmd 里是 27MHz 域的单拍脉冲
    //    (宽 37ns), 而这里读的时钟是 3MHz (546ns) ——
    //    现在: uart_cmd 每收到一次命令就**翻转**一下,
    //    这里用"检测边沿"变回单拍脉冲 —— 靠边沿传递
    //    是跨时钟域的标准做法, 不会丢。
    wire        ucmd_score_rst_tg;
    wire        ucmd_score_next_tg;
    wire        ucmd_score_play_tg;
    wire        sc_beat_on;  // 每拍前 1/4 为高, 给灯带做节拍引导
    //    27MHz 域的单拍脉冲只有 37ns, 3MHz 域采不到。
    //    做法和上位机命令一样: 27MHz 侧翻 toggle,
    //    3MHz 侧打拍再异或 -> 边沿就是单拍脉冲。
    wire        enc_step, enc_dir, enc_press, enc_long;
    wire [7:0]  enc_pos;
    wire        enc_play, enc_home;
    localparam [7:0] DEFAULT_VOL = 8'd128;
    wire [7:0] str_vol = (str_volx == 2'd0) ? 8'd144 :
                         (str_volx == 2'd1) ? 8'd184 :
                         (str_volx == 2'd2) ? 8'd216 : 8'd248;
    wire [7:0] vol_use = ucmd_host_on ? ucmd_cfg_master
                       : (menu_on_v ? menu_vol_w
                       : (str_vol_on ? str_vol : DEFAULT_VOL));

    //  ---- \u65b9\u5411\u662f\u7535\u5e73, 3MHz \u57df\u76f4\u63a5\u6253\u62cd\u91c7 ----
    reg enc_dir_s0, enc_dir_s1;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin enc_dir_s0 <= 1'b1; enc_dir_s1 <= 1'b1; end
        else        begin enc_dir_s0 <= enc_dir; enc_dir_s1 <= enc_dir_s0; end
    end

    reg [1:0]  song_s0, song_s1;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            song_s0 <= 2'd0; song_s1 <= 2'd0;
        end else begin
            song_s0 <= menu_song_w;  song_s1 <= song_s0;
        end
    end

    wire        sc_hit_pulse;
    wire [10:0] scr_waddr;  // uart_cmd -> score_ram 写口 (27MHz)
    wire [7:0]  scr_wdata;
    wire        scr_we;
    wire [10:0] scr_len;  // 下载曲谱字节数
    wire        scr_valid;  // 1 = 有下载好的曲谱
    wire [10:0] scr_raddr;  // score_player -> score_ram 读地址
    wire [7:0]  scr_rdata;
    wire        ev_valid;  // 1 = 有一个录音事件
    wire [6:0]  ev_deg;
    wire [1:0]  ev_kind;  // 1=note on  2=note off
    wire [15:0] ev_t16;  // 时间戳 (毫秒)
    wire [7:0]  ev_vel_w;  // 力度
    reg  [15:0] ev_tick;  // 毫秒计数器
    reg  [11:0] ev_msdiv;  // 3MHz -> 1ms 分频 (3000)
    wire        sc_miss_pulse;
    wire [3:0]  sc_want_deg;
    wire [9:0]  sc_note_pos;
    wire [9:0]  sc_note_total;
    reg         score_on;  // 曲谱模式开关 (s2 和上位机共同驱动)
    wire [1:0]  sc_state;  // 曲谱状态 0=停 1=播 2=弹完
    wire [1:0]  sc_song_idx;
    wire [7:0]  sc_hit_cnt;

    wire [7:0]  sc_miss_cnt;
    wire [16:0] ucmd_cfg_irrise;
    wire [7:0]  ucmd_cfg_master;
    wire [1:0]  ucmd_cfg_octave;
    wire        ucmd_cfg_valid;
    reg  [1:0]  oct_idx;
    //    light_lvl / light_valid / light_tog / light_disp / dist_cm / dist_valid / dist_tog
    //    全部随模块一起删除 (它们的消费者已经一个不剩)。
    wire [2:0]  vib_depth;  // 实际颤音档位 (menu_on_vb ? menu_vib_w : vib_ges)
    //    它是 menu_fsm 的 tst_act 输出 = "**当前停在 TEST 页**" (menu_fsm.v:412)。
    //    测试模式要在文件前半段 (L1690 附近) 用到它,
    wire        menu_tst_w;
    wire        menu_tst_step;
    wire        menu_tst_dir;
    wire        i2c_sda_oe;  // SDA 输出使能 (0 = 释放, 靠上拉拉高)
    wire        i2c_sda_o;  // SDA 要驱动的值
    wire        i2c_sda_i;  // SDA 实际读回的值
    wire        i2c_scl_drv;  // 驱动器给出的 SCL (直接送引脚, 上电即生效)
    wire        i2c_sda_oe_d, i2c_sda_o_d;  // 驱动器的 SDA 三态信号
    //---- PAJ7620U2 (驱动已按 CSDN 文章那套方案重写, 详见 src/paj7620.v 文件头) ----
    wire [7:0]  paj_ges1_raw;  // 0x43 原始字节 (上/下/左/右/前/后/顺/逆)
    wire [7:0]  paj_ges2_raw;  // 0x44 原始字节 (bit0 = 挥动)
    wire [3:0]  paj_ges;  // 1..9 = 九种手势, 0 = 无手势
    wire [7:0]  paj_wa0;  // §4.4 读 0x00 的实际值 (应为 0x20)
    wire [7:0]  paj_wa1;
    wire [3:0]  paj_phase;  // 0=正常 1=唤醒 2=Bank0+握手 3=写表 4=等稳定
    wire        paj_err;  // 最近一笔事务从机没应答
    wire [3:0]  paj_ecnt;  // 连续读手势失败计数 (到 ERR_MAX 就整颗重初始化)
    wire [3:0]  paj_rej;
    wire [5:0]  paj_fail_idx;
    wire        paj_tog;  // 数据更新握手
    assign i2c_scl   = i2c_scl_drv;
    assign i2c_sda   = i2c_sda_oe_d ? i2c_sda_o_d : 1'bz;
    assign i2c_sda_i = i2c_sda;  // 读回的是引脚本身 (开漏必须回读实际电平)

    wire [3:0]  ges_now = paj_ges;
    localparam [23:0] GES_HOLD = 24'd13500000;  // 500ms @27MHz
    reg [3:0]  ges_lat;
    reg [23:0] ges_hold_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ges_lat      <= 4'd0;
            ges_hold_cnt <= 24'd0;
        end else if (ges_now != 4'd0) begin
            ges_lat      <= ges_now;  // 有新手势 -> 锁存并重新计时
            ges_hold_cnt <= GES_HOLD;
        end else if (ges_hold_cnt != 24'd0) begin
            ges_hold_cnt <= ges_hold_cnt - 24'd1;  // 保持期内继续显示
        end else begin
            ges_lat      <= 4'd0;  // 保持期满 -> 回到"无手势"
        end
    end

    reg [23:0] tick_cnt;
    reg [3:0]  tick_digit;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt   <= 24'd0;
            tick_digit <= 4'd0;
        end else if (tick_cnt == 24'd8100000) begin  // 0.3s @27MHz
            tick_cnt   <= 24'd0;
            tick_digit <= (tick_digit == 4'd9) ? 4'd0 : (tick_digit + 4'd1);
        end else begin
            tick_cnt <= tick_cnt + 24'd1;
        end
    end
    wire        dist_show_tog = tick_digit[0];  // 用自由计数器驱动刷新, 与器件通不通无关

    localparam [24:0] FIDX_HOLD = 25'd32400000;
    reg [24:0] fidx_cnt;
    reg [1:0]  fidx_step;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fidx_cnt  <= 25'd0;
            fidx_step <= 2'd0;
        end else if (fidx_cnt == FIDX_HOLD) begin
            fidx_cnt  <= 25'd0;
            fidx_step <= fidx_step + 2'd1;  // 0 -> 1 -> 2 -> 3(=0) 自然回绕
        end else begin
            fidx_cnt <= fidx_cnt + 25'd1;
        end
    end
    //     也当第 3 段用 (等价于 %3 的效果, 但不需要除法器)。
    wire [7:0] fidx_show = (fidx_step == 2'd0) ? 8'd44
                         : (fidx_step == 2'd1) ? (8'd30 + {4'd0, paj_fail_idx[5:4]})
                         :                       (8'd30 + {4'd0, paj_fail_idx[3:0]});
    wire       fidx_active = (paj_fail_idx != 6'd63);

    wire [3:0]  ges_idx = ges_lat;  // 屏幕用锁存值, 不用瞬时值
    wire [7:0]  dist_show =
                        fidx_active ? fidx_show
                        : (paj_phase == 4'd2 && paj_wa0 != 8'h20) ? paj_wa0
                        : (paj_phase != 4'd0) ? (8'd50 + {4'd0, paj_phase})
                        //     屏幕上有 8x  -> 读回来的位模式本身就是乱的 (链路问题)
                        //     从来没有 8x, 手势还是报错 -> 模式是干净的一位, 只是
                        //                                  方向报错了 (传感器算法问题)
                        : (paj_rej != 4'd0) ? (8'd80 + {4'd0, paj_rej})
                        : (paj_ecnt != 4'd0)  ? (8'd70 + {4'd0, paj_ecnt})
                        :                       (8'd60 + {4'd0, ges_idx});

    wire [7:0] spec_b0, spec_b1, spec_b2, spec_b3;
    wire [7:0] spec_b4, spec_b5, spec_b6, spec_b7;

wire [16*NVOICE-1:0] voice_led_w;

    //    给 GRAPH 页的"32 个独立振荡器"指示点用。
    //    赛题现场验证要求能观测出对应数量的独立谱峰;
    //    测试模式 32 个声部 32 个不同频率, 这 32 个点就是 32 个谱峰。
    wire [31:0] vbusy_w = {
        voice_led_w[16*31+8], voice_led_w[16*30+8], voice_led_w[16*29+8], voice_led_w[16*28+8],
        voice_led_w[16*27+8], voice_led_w[16*26+8], voice_led_w[16*25+8], voice_led_w[16*24+8],
        voice_led_w[16*23+8], voice_led_w[16*22+8], voice_led_w[16*21+8], voice_led_w[16*20+8],
        voice_led_w[16*19+8], voice_led_w[16*18+8], voice_led_w[16*17+8], voice_led_w[16*16+8],
        voice_led_w[16*15+8], voice_led_w[16*14+8], voice_led_w[16*13+8], voice_led_w[16*12+8],
        voice_led_w[16*11+8], voice_led_w[16*10+8], voice_led_w[16* 9+8], voice_led_w[16* 8+8],
        voice_led_w[16* 7+8], voice_led_w[16* 6+8], voice_led_w[16* 5+8], voice_led_w[16* 4+8],
        voice_led_w[16* 3+8], voice_led_w[16* 2+8], voice_led_w[16* 1+8], voice_led_w[16* 0+8]
    };

    wire [7:0] spec_val;
    wire [2:0] spec_idx;
    wire [1:0] spec_low;

    spectrum #(.NVOICE(NVOICE)) u_spec (
        .clk     (clk_aud_w),
        .rst_n   (rst_n),
        .vbus    (voice_led_w),
        .barval  (spec_val),
        .baridx  (spec_idx),
        .barlow  (spec_low),
        .bnd0    (spec_b0),
        .bnd1    (spec_b1),
        .bnd2    (spec_b2),
        .bnd3    (spec_b3),
        .bnd4    (spec_b4),
        .bnd5    (spec_b5),
        .bnd6    (spec_b6),
        .bnd7    (spec_b7),
        .tst_mode(1'b0)
    );

    wire signed [15:0] audio_ch;
wire signed [15:0] audio_dl;  // 延迟输出
wire signed [15:0] audio_rv;
    wire signed [15:0] voice0_w;  // 0 号声部输出(带包络)
    wire signed [15:0] voice1_w;  // 1 号声部输出(带包络)
    wire signed [15:0] voice0_s;  // 0 号声部包络前的波形
    wire signed [15:0] voice1_s;  // 1 号声部包络前的波形
    wire [7:0]  voice0_ph;  // 0 号声部相位高 8 位 -> 李萨如的 X
    wire [7:0]  voice1_ph;  // 1 号声部相位高 8 位 -> 李萨如的 Y

//    Y 取 1 号声部相位; 1 号声部空闲时 (只弹了一个音)
//    改用 0 号声部的**正交副本** (相位 +90°, 8 位量程 256 -> +64):
//      X = sin(ωt),  Y = sin(ωt + 90°) = cos(ωt)   ->  单位圆
wire        v1_busy  = voice_led_w[16*1 + 8];
wire [7:0]  lis_y_eff = v1_busy ? voice1_ph : (voice0_ph + 8'd64);

    localparam IR_CH  = 10;

    localparam IR_ADAPT = 1'b0;

    localparam [16:0] DB_CYC    = 17'd6000;  // 2ms   @3MHz (机械键)
    wire [16:0] IR_RISE_CYC = ucmd_cfg_irrise;
    //  下降沿固定 30us: 松手立刻停, 和敏感度无关。
    localparam [16:0] DB_IR_CYC = 17'd90;  // 30us @3MHz (光弦的下降沿判据)

    reg [9:0] key_s0, key_s1;
    always @(posedge clk_aud_w) begin
        key_s0 <= key;
        key_s1 <= key_s0;
    end

    localparam [19:0] IR_CAL_CYC  = 20'd300000;  // 100ms @3MHz: 学习窗口
    //  "连续这么久没动" 才更新本底 = 1ms @3MHz。
    //  取 1ms 而不是几拍: 演奏时的抖动/噪声**绝不能**被学成本底。
    localparam [18:0] IR_STABLE   = 19'd3000;

    reg [19:0] cal_cnt;  // 离学习窗口结束还有多久
    reg [18:0] idle_cnt [0:IR_CH-1];  // 每路"电平连续没动"的计时
    reg [9:0]  ir_idle;  // 每路学到的本底电平
    integer    k;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            cal_cnt  <= 20'd0;
            ir_idle  <= 10'd0;
            for (k = 0; k < IR_CH; k = k + 1) idle_cnt[k] <= 19'd0;
        end else begin
            if (cal_cnt != IR_CAL_CYC) cal_cnt <= cal_cnt + 1'b1;
            //    不产生任何额外逻辑。
            if (cal_cnt != IR_CAL_CYC) begin
                //  ---- 学习窗口内: 连续 1ms 没动就更新本底 ----
                for (k = 0; k < IR_CH; k = k + 1) begin
                    if (key_s1[k] != ir_idle[k]) begin
                        if (idle_cnt[k] == IR_STABLE) begin
                            ir_idle[k]  <= key_s1[k];  // 定格成本底
                            idle_cnt[k] <= 19'd0;
                        end else
                            idle_cnt[k] <= idle_cnt[k] + 1'b1;
                    end else
                        idle_cnt[k] <= 19'd0;
                end
            end
        end
    end

    localparam [9:0] KEY_POL_INV = 10'b00_0000_0000;
    //                               ^^ ^^^^ ^^^^
    //                     bit9..7 = 1 (新三路取反), bit6..0 = 0 (原七路不变)

    localparam [9:0] KEY_EN = 10'b11_1111_1111;

    integer n;
    reg [9:0] key_act;
    always @* begin
        for (n = 0; n < 10; n = n + 1) begin
            if (n < IR_CH)
                key_act[n] = (IR_ADAPT ? (cal_cnt == IR_CAL_CYC) & (key_s1[n] ^ ir_idle[n])
                                       : (key_s1[n] ^ KEY_POL_INV[n]))
                             & KEY_EN[n];
            else
                key_act[n] = ~key_s1[n];
        end
    end

    reg [15:0] press_cnt;
    reg [9:0]  key_db_d;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            press_cnt <= 16'd0;
            key_db_d  <= 10'd0;
        end else begin
            key_db_d <= key_db;
            //  任何一路 key_db 从 0 -> 1 就 +1 (多路同时只算 1, 避免噪声爆数)
            if (|(key_db & ~key_db_d)) press_cnt <= press_cnt + 16'd1;
        end
    end

    reg [9:0]   key_db;
    reg [169:0] db_cnt;  // 10 路 x 17 位 = 170 位 (原 7 路 = 119 位)
    integer     i;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            key_db <= 10'h000;
            db_cnt <= 170'd0;
        end else begin
            for (i = 0; i < 10; i = i + 1) begin
                if (key_act[i] != key_db[i]) begin
                    //      机械键   : 两个方向都是 DB_CYC (2ms 触点消抖)
                    //      光弦 上升 : IR_RISE_CYC —— **这一项就是"灵敏度"旋钮**
                    //      光弦 下降 : DB_IR_CYC (30us) —— 松手立刻停, 不拖尾
                    //    生成 7 个比较器 + 7 个多路选择器。
                    //     不同就说明正在等它跳变; 目标为 1 就是上升沿。
                    if (db_cnt[17*i +: 17] ==
                        ((i < IR_CH) ? (key_act[i] ? IR_RISE_CYC : DB_IR_CYC)
                                     : DB_CYC)) begin
                        key_db[i]          <= key_act[i];
                        db_cnt[17*i +: 17] <= 17'd0;
                    end else
                        db_cnt[17*i +: 17] <= db_cnt[17*i +: 17] + 1'b1;
                end else
                    db_cnt[17*i +: 17] <= 17'd0;
            end
        end
    end

    localparam [16:0] MIN_GATE = 17'd90000;  // 30ms @3MHz

    reg [169:0] gate_cnt;  // IR_CH 路 x 17 位 (IR_CH=10 时正好 170 位)
    reg [9:0]  key_gate;
    integer    j;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            gate_cnt <= 170'd0;
            key_gate <= 10'd0;
        end else begin
            //  默认直接跟随消抖输出; 下面几路会被"保持"逻辑按位覆盖
            //  (同一个 always 块里后写的赋值优先, 这是 Verilog 的语义)
            key_gate <= key_db;
            for (j = 0; j < IR_CH; j = j + 1) begin
                if (key_db[j] && !key_gate[j]) begin
                    //  光路刚被遮挡: 装载最小门时间
                    gate_cnt[17*j +: 17] <= MIN_GATE;
                    key_gate[j]          <= 1'b1;
                end else if (gate_cnt[17*j +: 17] != 17'd0) begin
                    //  还没到最小门时间: 即使光路已经通了也继续按住
                    gate_cnt[17*j +: 17] <= gate_cnt[17*j +: 17] - 1'b1;
                    key_gate[j]          <= 1'b1;
                end
            end
        end
    end

    wire [9:0] key_pressed = key_gate;  // 1 = 按下 (10 路光弦, 遮挡 = 高)

    wire [9:0] str_key_10 = key_pressed;  // 现在本身就是 10 位, 不用再扩展

    function [4:0] deg_semi;
        input [3:0] d;
        begin
            case (d)
                4'd0: deg_semi = 5'd0;  // do      C4
                4'd1: deg_semi = 5'd2;  // re      D4
                4'd2: deg_semi = 5'd4;  // mi      E4
                4'd3: deg_semi = 5'd5;  // fa      F4
                4'd4: deg_semi = 5'd7;  // sol     G4
                4'd5: deg_semi = 5'd9;  // la      A4
                4'd6: deg_semi = 5'd11;  // si      B4
                4'd7: deg_semi = 5'd12;  // i       高音 do  C5
                4'd8: deg_semi = 5'd14;  // ii      高音 re  D5
                4'd9: deg_semi = 5'd16;  // SW      高音 mi  E5
                default: deg_semi = 5'd0;
            endcase
        end
    endfunction

    wire [15:0] key_scan16 = {6'd0, key_pressed};

    wire [6:0] keymap_base  = {scan_i, 3'b000} - {3'b000, scan_i};
    wire [6:0] sel_key_base = ucmd_keymap[keymap_base +: 7];

    wire [5:0] kind_base = {scan_i, 1'b0} + {2'b00, scan_i};
    wire [2:0] sel_kind  = ucmd_kmap_kind[kind_base +: 3];
    //  kind == 0 才是音弦, 其余都是功能弦
    wire       sel_is_note = (sel_kind == 3'd0);

    reg  [3:0] tr_idx;  // 变调量: 0..11 个半音

    //  变调偏移, 并到音符号上 (7 位无符号, 最大 11)
    wire [6:0] tr_off = {3'd0, tr_idx};

    //     如果按住的时候变了变调/八度, 松开时现算的号就对不上,
    //     声部永远不释放 -> **卡音一直响**。
    //     现在: 按下那一拍把算好的号存进表, 松开时取表里的 —— on/off 必定一致。
    reg [6:0] knh [0:15];
    integer   kh;
    initial begin
        for (kh = 0; kh < 16; kh = kh + 1) knh[kh] = 7'd60;
    end

    reg [15:0] key_reported;
    reg [3:0] scan_i;
    reg       key_on_r, key_off_r;
    reg [6:0] key_note_r;

    wire [1:0]  oct_use = oct_idx;

    wire [2:0]  timbre_eff = wave_sel;

    wire [6:0]  oct_off = (oct_use == 2'd0) ? 7'd0  :
                          (oct_use == 2'd1) ? 7'd12 :
                          (oct_use == 2'd2) ? 7'd24 : 7'd36;

    reg  [3:0]  ges_27_d;  // 27MHz 域: 上一拍的手势号
    reg         ges_27_tog;  // 27MHz 域: 手势号一变就翻转
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ges_27_d   <= 4'd0;
            ges_27_tog <= 1'b0;
        end else if (paj_ges != ges_27_d) begin
            ges_27_d   <= paj_ges;
            ges_27_tog <= ~ges_27_tog;
        end
    end

    reg         gt_s0, gt_s1, gt_s2;
    reg  [3:0]  ges_evt;  // 3MHz 域: 本拍要执行的手势号
    reg         ges_evt_v;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            gt_s0 <= 1'b0; gt_s1 <= 1'b0; gt_s2 <= 1'b0;
            ges_evt <= 4'd0; ges_evt_v <= 1'b0;
        end else begin
            gt_s0 <= ges_27_tog;
            gt_s1 <= gt_s0;
            gt_s2 <= gt_s1;
            //     不是在采一个正在变的线 —— 见上面关于时序的说明。
            //    直接在**产生点**把这个单拍脉冲压掉,
            //    下游所有 case (ges_evt) 分支就自动全部失效,
            ges_evt_v <= (gt_s1 ^ gt_s2) & menu_gest_w;
            if (gt_s1 ^ gt_s2)
                ges_evt <= ges_27_d;
        end
    end

    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            key_reported <= 16'd0;
            scan_i       <= 4'd0;
            //    (如果在这里写, 又会退化回触发器堆)
            key_on_r     <= 1'b0;
            key_off_r    <= 1'b0;
            key_note_r   <= 7'd60;
            tr_idx       <= 4'd0;
        end else begin
            key_on_r  <= 1'b0;
            key_off_r <= 1'b0;
            str_timb_evt <= 1'b0;
            str_oct_evt  <= 1'b0;
            str_vel_evt  <= 1'b0;
            if (key_scan16[scan_i] && !key_reported[scan_i]) begin
                key_reported[scan_i] <= 1'b1;
                if (sel_is_note) begin
                    key_on_r         <= 1'b1;
                    key_note_r       <= sel_key_base + oct_off + tr_off;
                    knh[scan_i[3:0]] <= sel_key_base + oct_off + tr_off;
                end else begin
                    case (sel_kind)
                        3'd1: tr_idx       <= (tr_idx >= 4'd11) ? 4'd0 : (tr_idx + 4'd1);
                        3'd2: str_timb_evt <= 1'b1;
                        3'd3: str_oct_evt  <= 1'b1;
                        3'd4: str_vel_evt  <= 1'b1;
                        3'd5: begin str_volx <= str_volx + 2'd1; str_vol_on <= 1'b1; end
                        default: ;
                    endcase
                end
            end else if (!key_scan16[scan_i] && key_reported[scan_i]) begin
                key_reported[scan_i] <= 1'b0;
                if (sel_is_note) begin
                    key_off_r  <= 1'b1;
                    //    绝不能这里重新算 —— 中途变了变调/八度就对不上了。
                    key_note_r <= knh[scan_i[3:0]];
                end
            end
            scan_i <= scan_i + 1'b1;
        end
    end

    localparam [16:0] S_DB_CYC = 17'd60000;  // 20ms @3MHz (原 30000 @1.5MHz)

    reg s1_s0, s1_s1, s1_db, s1_db_d;
    reg [16:0] s1_cnt;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            s1_s0 <= 1'b1; s1_s1 <= 1'b1; s1_db <= 1'b1; s1_db_d <= 1'b1;
            s1_cnt <= 17'd0;
        end else begin
            s1_s0   <= s1;
            s1_s1   <= s1_s0;
            s1_db_d <= s1_db;
            if (s1_s1 != s1_db) begin
                if (s1_cnt == S_DB_CYC) begin s1_db <= s1_s1; s1_cnt <= 17'd0; end
                else s1_cnt <= s1_cnt + 1'b1;
            end else s1_cnt <= 17'd0;
        end
    end

    reg s2_s0, s2_s1, s2_db, s2_db_d;
    reg [16:0] s2_cnt;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            s2_s0 <= 1'b1; s2_s1 <= 1'b1; s2_db <= 1'b1; s2_db_d <= 1'b1;
            s2_cnt <= 17'd0;
        end else begin
            s2_s0   <= s2;
            s2_s1   <= s2_s0;
            s2_db_d <= s2_db;
            if (s2_s1 != s2_db) begin
                if (s2_cnt == S_DB_CYC) begin s2_db <= s2_s1; s2_cnt <= 17'd0; end
                else s2_cnt <= s2_cnt + 1'b1;
            end else s2_cnt <= 17'd0;
        end
    end

    // 按下沿(低电平=按下): 此时 db_d 还是 1(未按下), db 已变 0(按下)
    wire s1_press = s1_db_d & ~s1_db;
    wire s2_press = s2_db_d & ~s2_db;

    reg  [2:0]  wave_sel;  // 音色 0..7
    reg  [7:0]  vel_ges;  // 手势力度档
    reg  [2:0]  vib_ges;  // 手势颤音深度档 0..7
    reg         chorus_en;  // 手势合唱开关

    reg         host_timbre_lock;
    reg         host_on_d;
    wire        host_edge = ucmd_host_on & ~host_on_d;

    //    ucmd_cfg_valid 是 **27MHz 域的单拍脉冲 (37ns)**, 而下面那些寄存器在
    //    **3MHz 域 (333ns)**。直接采样大部分时候是采不到的 ——
    //    表现就是"点了写入音色, 板子没反应"。
    //    必须先用 toggle 把它变成一个**电平信号**过来, 再在 3MHz 域取边沿。
    reg         cfg_tog;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)              cfg_tog <= 1'b0;
        else if (ucmd_cfg_valid) cfg_tog <= ~cfg_tog;
    end
    reg [2:0]   cfg_s3;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) cfg_s3 <= 3'd0;
        else        cfg_s3 <= {cfg_s3[1:0], cfg_tog};
    end
    wire        cfg_pulse = cfg_s3[1] ^ cfg_s3[2];  // 3MHz 域的单拍脉冲

    wire        cfg_load  = ucmd_host_on & (cfg_pulse | host_edge);
    reg  [2:0]  menu_timb_d;
    reg  [1:0]  menu_oct_d;
    reg  [2:0]  menu_vib_d;
    wire        enc_tev = (menu_timb_w != menu_timb_d);
    wire        enc_oev = (menu_oct_w  != menu_oct_d);
    wire        enc_vev = (menu_vib_w  != menu_vib_d);

    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            wave_sel  <= 3'd0;
            oct_idx   <= 2'd0;
            vel_ges   <= 8'd200;
            vib_ges   <= 3'd0;
            chorus_en <= 1'b1;
            host_timbre_lock <= 1'b0;
            host_on_d        <= 1'b0;
            menu_timb_d      <= 3'd0;
            menu_oct_d       <= 2'd0;
            menu_vib_d       <= 3'd0;
        end else begin
            if (ucmd_cfg_timbre_en != host_timbre_lock)
                host_timbre_lock <= ucmd_cfg_timbre_en;
            menu_timb_d <= menu_timb_w;
            menu_oct_d  <= menu_oct_w;
            menu_vib_d  <= menu_vib_w;
            host_on_d   <= ucmd_host_on;
            if (cfg_load) begin
                oct_idx <= ucmd_cfg_octave;
                vel_ges <= ucmd_cfg_vel;
                vib_ges <= ucmd_cfg_vib;
            end

            if (cfg_load) begin
                wave_sel <= ucmd_cfg_timbre;  //  上位机写入的那一拍
            end else if (enc_tev) begin
                wave_sel <= menu_timb_w;
            end else if (str_timb_evt) begin
                wave_sel <= wave_sel + 3'd1;
            end else if (ges_evt_v) begin
                case (ges_evt)
                4'd1: wave_sel <= wave_sel + 3'd1;
                4'd2: wave_sel <= wave_sel - 3'd1;
                default: ;
                endcase
            end

            if (ges_evt_v) begin
            case (ges_evt)
            4'd1: ;  // 上   -> 音色 + (已上移)
            4'd2: ;  // 下   -> 音色 - (已上移)
            4'd3: if (oct_idx != 2'd0) oct_idx <= oct_idx - 2'd1;  // 左   -> 八度 -
            4'd4: if (oct_idx != 2'd3) oct_idx <= oct_idx + 2'd1;  // 右   -> 八度 +
            //  力度: 每档 40, 夹在 80..240。
            //  范围不是随便取的: adsr_env 里 peak = {vel, 8'h00},
            //  80 与 240 对应包络峰值 20480 / 61440, 响度差 20*log10(3) ≈ 9.5dB
            //  —— 足够听出"轻重", 又不会轻到听不见。和原超声波映射的两个端点一致。
            4'd5: if (vel_ges < 8'd240) vel_ges <= vel_ges + 8'd40;  // 前   -> 力度 +
            4'd6: if (vel_ges > 8'd80 ) vel_ges <= vel_ges - 8'd40;  // 后   -> 力度 -
            4'd7: if (vib_ges != 3'd7)  vib_ges <= vib_ges + 3'd1;  // 顺时针 -> 颤音深 +
            4'd8: if (vib_ges != 3'd0)  vib_ges <= vib_ges - 3'd1;  // 逆时针 -> 颤音深 -
            4'd9: chorus_en <= ~chorus_en;  // 挥动 -> 合唱 开/关
            default: ;
            endcase
            end
            if (enc_oev)     oct_idx <= menu_oct_w[1:0];
            if (str_oct_evt) oct_idx <= oct_idx + 2'd1;
            if (enc_vev)     vib_ges <= menu_vib_w;
            if (str_vel_evt) vel_ges <= (vel_ges >= 8'd240) ? 8'd120 : (vel_ges + 8'd40);
        end
    end

    reg s1_tog, s2_tog;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_tog <= 1'b0; s2_tog <= 1'b0;
        end else begin
            if (s1_press) s1_tog <= ~s1_tog;
            if (s2_press) s2_tog <= ~s2_tog;
        end
    end

    reg s1t0, s1t1, s1t2, s2t0, s2t1, s2t2;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            s1t0 <= 1'b0; s1t1 <= 1'b0; s1t2 <= 1'b0;
            s2t0 <= 1'b0; s2t1 <= 1'b0; s2t2 <= 1'b0;
        end else begin
            s1t0 <= s1_tog; s1t1 <= s1t0; s1t2 <= s1t1;
            s2t0 <= s2_tog; s2t1 <= s2t0; s2t2 <= s2t1;
        end
    end
    wire s1_press_a = s1t1 ^ s1t2;  // 3MHz 域的单拍脉冲
    wire s2_press_a = s2t1 ^ s2t2;

    reg  [5:0]  tst_lv27;
    reg         tst_step_27d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tst_lv27     <= 6'd0;
            tst_step_27d <= 1'b0;
        end else begin
            tst_step_27d <= menu_tst_step;  //  打一拍
            if (tst_step_27d) begin  //  用上一拍的 step + 已稳定的 dir
                if (menu_tst_dir) tst_lv27 <= (tst_lv27 >= 6'd32) ? 6'd0 : (tst_lv27 + 6'd1);
                else              tst_lv27 <= (tst_lv27 == 6'd0)  ? 6'd32 : (tst_lv27 - 6'd1);
            end
            if (!menu_tst_w) tst_lv27 <= 6'd0;
        end
    end

    //  ---- 27MHz -> 3MHz: 档位和"是否在 TEST 页"都是稳态信号, 打两拍即可 ----
    reg       mt0, mt1;
    reg [5:0] lv0, lv1;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin mt0 <= 1'b0; mt1 <= 1'b0; lv0 <= 6'd0; lv1 <= 6'd0; end
        else begin
            mt0 <= menu_tst_w;
            mt1 <= mt0;
            lv0 <= tst_lv27;
            lv1 <= lv0;
        end
    end
    wire        tst_page = mt1;  //  1 = 菜单停在 TEST 页
    wire [5:0]  tst_want = lv1;  //  编码器拨的档位 0..32

    reg  [5:0]  tst_cur;  //  已开的声部数 0..32
    reg  [5:0]  tst_want_d;  //  上一拍的档位 (用来检测变化)
    reg  [1:0]  tst_smp;  //  每 4 个采样点加一个声部
    reg         tst_on_r;
    reg  [6:0]  tst_note_r;

    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) tst_smp <= 2'd0;
        else if (tick) tst_smp <= tst_smp + 2'd1;
    end
    //  每 4 个音频采样 (约 42.7us) 加一个声部: 32 个声部 1.37ms 到位
    wire tst_step = tick && (tst_smp == 2'd3);

    //  条件汇总 (组合逻辑, 给下面两个 always 用)
    wire tst_chg  = (tst_want != tst_want_d);  //  档位变了
    wire tst_off_req = !tst_page;  //  离开页面
    wire tst_zero = (tst_want == 6'd0);  //  档位拨到 0

    //  all_off: 档位一变 / 离开页面 / 拨到 0, 只要还有声部占着就全放
    wire tst_alloff = ((tst_chg || tst_off_req || tst_zero) && (tst_cur != 6'd0))
                   || (tst_chg && tst_page && !tst_zero);  //  档位变时即使当前是 0 也要清一次

    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            tst_cur    <= 6'd0;
            tst_want_d <= 6'd0;
            tst_on_r   <= 1'b0;
            tst_note_r <= 7'd60;
        end else begin
            tst_on_r <= 1'b0;
            tst_want_d <= tst_want;
            if (tst_chg) begin
                tst_cur <= 6'd0;  //  档位变了 -> 从 0 重数
            end else if (!tst_page || tst_zero) begin
                tst_cur <= 6'd0;  //  关掉
            end else if (tst_step && (tst_cur < tst_want)) begin
                tst_on_r   <= 1'b1;
                tst_note_r <= 7'd60 + {1'b0, tst_cur[4:0]};  //  60 + i -> MIDI 60..91
                tst_cur    <= tst_cur + 6'd1;
            end
        end
    end

    wire        tst_act = (tst_cur != 6'd0) || (tst_page && (tst_want != 6'd0));

    wire       sp_on_w, sp_off_w;
    wire [6:0] sp_note_w;

    wire       ev_on      = tst_act ? tst_on_r  : (key_on_r | sp_on_w);

    reg [6:0] last_on_note;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            last_on_note  <= 7'd60;
        end else begin
            if (sp_on_w)        last_on_note  <= sp_note_w;
            else if (key_on_r)  last_on_note  <= key_note_r;
        end
    end

    wire [6:0] ev_on_note = tst_act ? tst_note_r : last_on_note;

    assign ev_valid  = key_on_r | key_off_r;  // 只记真实按键
    assign ev_deg    = key_note_r;
    assign ev_kind   = key_on_r ? 2'd1 : 2'd2;  // 1=on 2=off
    assign ev_t16    = ev_tick;  // 毫秒

    //  3MHz -> 1ms 分频, 再数毫秒 (16 位 = 65 秒)
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            ev_msdiv <= 12'd0;
            ev_tick  <= 16'd0;
        end else if (ev_msdiv >= 12'd2999) begin
            ev_msdiv <= 12'd0;
            ev_tick  <= ev_tick + 16'd1;
        end else begin
            ev_msdiv <= ev_msdiv + 12'd1;
        end
    end

    wire       ev_off      = tst_act ? 1'b0 : (key_off_r | sp_off_w);
    wire [6:0] ev_off_note = tst_act ? tst_note_r
                                     : (sp_off_w ? sp_note_w : key_note_r);
    //    引擎在 note_off 那一拍就要用 off_note 去比对 note_out,
    //    注册器会晚一拍 -> 拿到上一个音的编号 -> 释放错声部,
    //    最后一个音就永远无人释放。

    wire [2:0] ev_wave = timbre_eff;

    wire [7:0] ev_vel = tst_act ? 8'd220 : vel_ges;
    assign ev_vel_w = ev_vel;

    //---- 屏幕上"NOTE"一栏显示最后触发的音 ----
    reg [6:0] disp_note;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) disp_note <= 7'd60;
        else if (ev_on) disp_note <= ev_on_note;
    end

    wire [5:0]         active_cnt;

    localparam [2:0] GLIDE_LVL = 3'd0;
    wire [2:0] glide_use = menu_on_gl ? menu_glide_w : GLIDE_LVL;

reg [19:0] lat_cnt;
reg        lat_run;
reg [15:0] lat_meas_r;
reg        lat_valid;

always @(posedge clk_aud_w or negedge rst_n) begin
    if (!rst_n) begin
        lat_cnt     <= 20'd0;
        lat_run     <= 1'b0;
        lat_meas_r  <= 16'd0;
        lat_valid   <= 1'b0;
    end else begin
        if (ev_on && (active_cnt == 6'd0) && !lat_run) begin
            //  静音下发生了新的音符事件 -> 开始计时
            lat_run   <= 1'b1;
            lat_cnt   <= 20'd0;
        end else if (lat_run) begin
            if (audio_s != 16'sd0) begin
                //  第一个非零样本到了 -> 停止, 锁存
                lat_run    <= 1'b0;
                lat_meas_r <= (lat_cnt > 20'hFFFF0) ? 16'hFFFF : lat_cnt[15:0];
                lat_valid  <= 1'b1;
            end else if (lat_cnt != 20'hFFFFF) begin
                lat_cnt <= lat_cnt + 20'd1;
            end
        end
    end
end

    synth_engine #(.NVOICE(NVOICE)) u_synth (
        .clk       (clk_aud_w),
        .rst_n     (rst_n),
        .tick      (tick),
        .note_on   (ev_on),
        .on_note   (ev_on_note),
        .on_vel    (ev_vel),
        .on_wave   (ev_wave),
        .note_off  (ev_off),
        .all_off   (tst_alloff),
        .off_note  (ev_off_note),
        //   深度由光敏模块(手遮光 = 变暗 = 颤音变深)实时控制。
        .pm        (pm_w),
        //   0 = 关, 1..6 = 越来越慢 (八度 52 / 104 / 208 / 420 / 830 / 1700 ms)
        //     菜单没动过就用默认 2 档 (八度约 104ms)。
        .glide_lvl (glide_use),
        .atk_inc   (16'd512),
        .dec_inc   (16'd24),
        .rel_inc   (16'd8),
        .sus_shift (2'd2),
        .master    (vol_use),
        .audio     (audio_s),
        .active_cnt(active_cnt),
        .voice0_out(voice0_w),
        .voice1_out(voice1_w),
        .voice0_smp(voice0_s),
        .voice1_smp(voice1_s),
        .voice0_ph (voice0_ph),
        .voice1_ph (voice1_ph),
        .voice_led_v(voice_led_w)
    );

    assign audio_w = audio_s;

    wire [2:0] chorus_eff = menu_on_c ? menu_cho_w
                                    : (ucmd_cfg_chorus_en ? {2'b00, ucmd_cfg_chorus} : 3'd0);
    //  延迟/混响暂时没有手势和上位机控制, 默认**开**
    wire [2:0] delay_eff  = menu_on_d ? menu_dly_w  : 3'd0;
    wire [2:0] reverb_eff = menu_on_r ? menu_rvb_w  : 3'd0;

    wire signed [15:0] fx_in;  // 46875Hz 的输入样本
    wire               fx_tick;  // 46875Hz 的一拍脉冲

    fx_decim u_fxdec (
        .clk   (clk_aud_w),
        .rst_n (rst_n),
        .tick  (tick),
        .din   (audio_s),
        .dout  (fx_in),
        .ftick (fx_tick),
        .phase ()
    );

    delay_fx #(.AW(12), .DW(16)) u_delay (
        .clk    (clk_aud_w),
        .rst_n  (rst_n),
        .tick   (fx_tick),
        .enable (~tst_act & (delay_eff != 3'd0)),
        .depth  (delay_eff),
        .type   (menu_dtype_w),
        .din    (fx_in),
        .dout   (audio_dl)
    );

    reverb_fx #(.DW(16)) u_reverb (
        .clk    (clk_aud_w),
        .rst_n  (rst_n),
        .tick   (fx_tick),
        .enable (~tst_act & (reverb_eff != 3'd0)),
        .depth  (reverb_eff),
        .type   (menu_rtype_w),
        .din    (audio_dl),
        .dout   (audio_rv)
    );

    chorus u_chorus (
        .clk    (clk_aud_w),
        .rst_n  (rst_n),
        .tick   (fx_tick),
        .enable (~tst_act & (chorus_eff != 3'd0)),
        .depth  (chorus_eff),
        .type   (menu_ctype_w),
        .din    (audio_rv),
        .dout   (audio_ch)
    );

    assign PA_EN = 1'b1;

    audio_drive u_audio_drive_0 (
        .clk_1p536m (clk_aud_w),
        .rst_n      (rst_n),
        .idata      (audio_ch),
        .req        (req_w),
        .b_cnt_o    (b_cnt),
        .HP_BCK     (HP_BCK),
        .HP_WS      (HP_WS),
        .HP_DIN     (HP_DIN)
    );

    localparam UART_CLK_MHZ = 27;  // 官方模块的时钟参数单位是 MHz
    localparam UART_BAUD    = 115_200;

    //  ---- 官方 uart_rx ----
    wire [7:0] urx_data;
    wire       urx_valid;

    uart_rx_off #(.CLK_FRE(UART_CLK_MHZ), .BAUD_RATE(UART_BAUD)) u_uart_rx (
        .clk           (clk),
        .rst_n         (rst_n),
        .rx_data       (urx_data),
        .rx_data_valid (urx_valid),
        .rx_data_ready (1'b1),  // 官方例子就是常接 1 (always can receive)
        .rx_pin        (uart_rx)
    );

    reg  [24:0] hb_cnt;
    reg         hb_flag;

    //    收到 H  = tx 通, 问题在 rx/解析侧
    //    收不到 H = tx 或接线有问题
    //    (27MHz 下 24 位全 1 = 16.7M 拍 = 0.62 秒; 这里放到 25 位 ≈ 1.24 秒,
    //     免得刷屏太密干扰看命令应答。)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb_cnt  <= 25'd0;
            hb_flag <= 1'b0;
        end else begin
            hb_flag <= 1'b0;
            if (hb_cnt == 25'h1FFFFFF && HB_ENABLE) begin
                hb_cnt  <= 25'd0;
                hb_flag <= 1'b1;
            end else begin
                hb_cnt <= hb_cnt + 25'd1;
            end
        end
    end

    //  ---- 官方 uart_tx (握手式接口) ----
    wire [7:0] otx_data;
    wire       otx_ready;

    reg        echo_pend;
    reg [7:0]  echo_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            echo_pend <= 1'b0;
            echo_data <= 8'd0;
        end else begin
            if (urx_valid) begin
                echo_data <= urx_data;  // 收到就锁存
                echo_pend <= 1'b1;
            end else if (echo_pend && otx_ready) begin
                echo_pend <= 1'b0;  // 发出去了 -> 撤下
            end
        end
    end

    localparam ECHO_ON = 1'b0;

    //    帧头 A5 / 帧尾 5A", 帧本身就有校验, **不需要心跳保活**。
    //    命令应答**冲得七零八落** (上位机看到的就是一堆 K=12345678
    //    里夹着孤零零的 "V" "T" "B")。
    //    想确认串口活着: 发一帧 A5 4B 00 5A 就行。
    localparam HB_ENABLE = 1'b0;  // 默认关: 帧协议有校验, 不需要心跳

    assign otx_data  = (ECHO_ON && echo_pend) ? echo_data : ucmd_byte;
    wire   otx_valid = (ECHO_ON && echo_pend) | ucmd_txreq;

    uart_tx_off #(.CLK_FRE(UART_CLK_MHZ), .BAUD_RATE(UART_BAUD)) u_uart_tx (
        .clk           (clk),
        .rst_n         (rst_n),
        .tx_data       (otx_data),
        .tx_data_valid (otx_valid),
        .tx_data_ready (otx_ready),
        .tx_pin        (uart_tx)
    );

    wire [2:0] ucmd_timbre;

    uart_cmd #(.CLK_HZ(27_000_000)) u_uart_cmd (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_data    (urx_data),
        .rx_done    (urx_valid),
        .tx_data    (ucmd_byte),
        .tx_valid   (ucmd_txreq),
        .tx_ready   (otx_ready),
        //  ---- 只读状态量 ----
        .st_voices  (active_cnt),  // 当前活跃声部数
        .st_timbre  (timbre_eff),
        .st_oct     (oct_use),
        .st_env     (6'd0),  // (预留: 包络电平, 现在报 0)
        .st_test    (4'd0),  // 测试档位 (uart_cmd 的 st_test 是 4 位)
        .st_ges     (paj_ges1_raw),  // 手势原始字节
        .st_b0      (spec_b0),  // 8 段频谱
        .st_b1      (spec_b1),
        .st_b2      (spec_b2),
        .st_b3      (spec_b3),
        .st_b4      (spec_b4),
        .st_b5      (spec_b5),
        .st_b6      (spec_b6),
        .st_b7      (spec_b7),
        //  ---- 可写配置 ----
        .cfg_timbre (ucmd_cfg_timbre),
        .cfg_timbre_en (ucmd_cfg_timbre_en),
        .cfg_host_on   (ucmd_host_on),
        .cfg_keymap    (ucmd_keymap),
        .cfg_kmap_kind (ucmd_kmap_kind),
        .cfg_vel       (ucmd_cfg_vel),
        .cfg_vib       (ucmd_cfg_vib),
        .cfg_chorus    (ucmd_cfg_chorus),
        .cfg_fxamt     (ucmd_cfg_fxamt),
        .cfg_vel_en    (ucmd_cfg_vel_en),
        .cfg_vib_en    (ucmd_cfg_vib_en),
        .cfg_chorus_en (ucmd_cfg_chorus_en),
        //  ---- 曲谱指引控制 ----
        .score_set     (ucmd_score_set),
        .score_on      (ucmd_score_on),
        .score_rst_tg  (ucmd_score_rst_tg),
        .score_next_tg (ucmd_score_next_tg),
        .score_play_tg (ucmd_score_play_tg),
        //  ---- 曲谱状态回传 ('D' 命令) ----
        .sc_song       (sc_song_idx),
        .sc_state      (sc_state),
        //   同一信号 (屏幕显示的就是 key_s1) 会变。
        //   先确认**引脚到底有没有变** —— 这是整个链路的最前端。
        .sc_keyact     (key_act),
        .sc_keylat     (press_cnt[6:0]),
        .sc_deg        (sc_want_deg),
        .sc_pos        (sc_note_pos),
        .sc_total      (sc_note_total),
        .sc_hit        (sc_hit_cnt),
        .sc_miss       (sc_miss_cnt),
        .cfg_irrise (ucmd_cfg_irrise),
        .cfg_master (ucmd_cfg_master),
        .cfg_octave (ucmd_cfg_octave),
        .cfg_valid  (ucmd_cfg_valid),
        .hb_pulse   (hb_flag),

        .scr_waddr     (scr_waddr),
        .scr_wdata     (scr_wdata),
        .scr_we        (scr_we),
        .scr_len       (scr_len),
        .scr_valid     (scr_valid),
        .dl_wp         (),
        .dl_err        (),
        .lat_meas      (lat_meas_r),
    .ev_valid      (ev_valid),
        .ev_deg        (ev_deg),
        .ev_kind       (ev_kind),
        .ev_t16        (ev_t16),
        .ev_vel        (ev_vel_w),
        .rec_active    (),
        .rec_count     ()
        //           不受这个开关影响), 同时**加上命令解析**。
        //      这正是上一版"越改越怪"的根因 (那时回声和命令应答挤在同一条路上)。
    );

    // 12. RGB LCD 状态显示 (480x272)
    //     视频 PLL: 27MHz -> 9MHz 像素时钟 (音频用的是另一个 rPLL, 互不干扰)
    //     屏幕内容: 模式 / 音色 / 声部数 / 测试档位 / 音名 / 实时波形
    //     全部用 LUT ROM 实现, 不占 BSRAM
    wire pclk_w;  // 9MHz 像素时钟
    wire [9:0] vx, vy;  // 有效像素坐标
    wire       vhs, vvs, vde;

    video_pll u_video_pll (
        .clkin  (clk),
        .clkout (pclk_w)
    );

    vga_timing u_vga_timing (
        .clk      (pclk_w),
        .rst      (1'b0),
        .hs       (vhs),
        .vs       (vvs),
        .de       (vde),
        .active_x (vx),
        .active_y (vy)
    );

    wire [3:0] page;
    //  menu_tst_w 是 27MHz 域的信号, 而测试逻辑跑在 3MHz。
    //  它是**电平** (停在测试页时一直为 1), 两级打拍就够。
    //  test_step 是 27MHz 域的**单拍**。要跨到 3MHz 就得用 toggle
    //    PARAM 页现在有 11 项 (menu_sel = 0..10), 而这根线只有 3 位。
    //    menu_fsm 输出 4 位、osd_status 输入 4 位, 中间这根 3 位线把
    wire [3:0] menu_sel_w;
    wire [1:0] menu_lvl_w;
    wire [1:0] sc_state_w;
    wire [9:0] sc_pos_w;
    wire [9:0] sc_total_w;
    assign sc_state_w = sc_state;
    assign sc_pos_w   = sc_note_pos;
    assign sc_total_w = sc_note_total;
    wire [1:0] menu_song_w;
    wire [2:0] menu_timb_w;
    wire [1:0] menu_oct_w;
    wire [7:0] menu_vol_w;
    wire [2:0] menu_dly_w;  // 延迟深度 0..5
    wire [2:0] menu_rvb_w;  // 混响深度 0..5
    wire       menu_auto_w;
    wire [2:0] menu_vib_w;
    wire [2:0] menu_cho_w;
    wire menu_on_t, menu_on_o, menu_on_v, menu_on_vb, menu_on_c;
    wire menu_on_d, menu_on_r;
    wire        menu_on_a;

    menu_fsm #(.NSONG(3), .NPAGE(6)) u_menu (
        .clk        (clk),
        .rst_n      (rst_n),
        .step       (enc_step),
        .dir        (enc_dir),
        .sw_press   (enc_press),
        .sw_long    (enc_long),
        .page       (page),
        .menu_sel   (menu_sel_w),
        .level      (menu_lvl_w),
        .tst_act    (menu_tst_w),
        .test_step  (menu_tst_step),
        .test_dir   (menu_tst_dir),  //   方向
        .play_p     (enc_play),
        .home_p     (enc_home),
        .song_idx   (menu_song_w),
        .p_timbre   (menu_timb_w),
        .p_octave   (menu_oct_w),
        .p_volume   (menu_vol_w),
        .p_vib      (menu_vib_w),
        .p_glide    (menu_glide_w),
        .p_chorus   (menu_cho_w),
        .p_delay    (menu_dly_w),
        .p_reverb   (menu_rvb_w),
    .p_gesture  (menu_gest_w),
    .p_ctype    (menu_ctype_w),
    .p_dtype    (menu_dtype_w),
    .p_rtype    (menu_rtype_w),
    .on_ctype   (),
    .on_dtype   (),
    .on_rtype   (),
        .p_autoplay (menu_auto_w),
        .on_timbre  (menu_on_t),
        .on_octave  (menu_on_o),
        .on_volume  (menu_on_v),
        .on_vib     (menu_on_vb),
        .on_glide   (menu_on_gl),
        .on_chorus  (menu_on_c),
        .on_delay   (menu_on_d),
        .on_reverb  (menu_on_r),
    .on_gesture (),
        .on_autoplay(menu_on_a)
    );

    osd_status u_osd (
        .pclk        (pclk_w),
        .rst_n       (rst_n),
        .x           (vx),
        .y           (vy),
        .de          (vde),
        .hs          (vhs),
        .vs          (vvs),
        .test_active (tst_page),
        .test_lvl    (tst_want),
        .wave_sel    (timbre_eff),
        .active_cnt  (tst_act ? tst_cur : active_cnt),
        .cur_note    (disp_note),
        //   光敏读数已经不需要看了 —— 它的标定结论记录在下面:
        //     室内光(手不遮): light_inv 约 384   -> 档位 0, 颤音关闭
        //     手完全遮住    : light_inv 约 7936  -> 档位 7, +-38 音分
        //   7 档门限(600~6000)正好铺满这段行程, 不用再调。
        .dist_cm     (dist_show),
        .dist_tog    (dist_show_tog),
        //    而不是一串数字码 —— 演示时评委和观众一眼就知道刚才做的是哪个动作。
        //    用的是 ges_lat (锁存 + 保持 0.5 秒那份), 不是瞬时值:
        //    手势标志读走就清, 瞬时值只存在约 51ms, 屏幕根本来不及显示。
        .ges_idx     (ges_lat),
        //    没有这四个显示, 做完"前"(力度+)手势根本看不出生效没有 ——
        //    而"多维表情调控"正是赛题拓展要求的评分点。
        .oct_idx     (oct_use),
        .vel_ges     (ev_vel),
        .vib_ges     (vib_depth),
        .chorus_en   (chorus_eff != 3'd0),
        .master_vol  (vol_use),
        //    用的是 key_s1 (同步后的引脚原值), 不是 key_act ——
        //    自标定和取反都是这个工程自己写的逻辑, 要验的正是它们。
                .key_raw     ({6'd0, key_s1}),  // 10 位 -> 16 位 (屏幕要取 0..15)
        //    menu_sel / menu_level 都来自 menu_fsm (27MHz 域),
        //    osd_status 内部会再打两拍跨到 pclk。
        .menu_sel      (menu_sel_w),
        .sc_sng        (menu_song_w),
        .sc_state      (sc_state_w),
        .sc_pos        (sc_pos_w),
        .sc_total      (sc_total_w),
        .menu_level    (menu_lvl_w),
        .enc_timbre    (timbre_eff),  //  实际音色 (= wave_sel)
        .enc_octave    (oct_use),  //  实际八度 (= oct_idx)
        .enc_volume    (vol_use),  //  实际音量
        .enc_vib       (vib_depth),  //  实际颤音深度
        .enc_glide     (glide_use),  //  实际滑音档位
        .enc_chorus    (chorus_eff),  //  实际合唱深度
        .enc_delay     (delay_eff),
        .enc_reverb    (reverb_eff),
    //    端口加了、生成器也生成了, 但这里没接 -> 悬空输入恒 0
    //    -> 屏幕永远显示 OFF, 而手势实际一直开着。
    .enc_gesture   (menu_gest_w),
    .enc_ctype     (menu_ctype_w),
    .enc_dtype     (menu_dtype_w),
    .enc_rtype     (menu_rtype_w),
        .enc_mode      (menu_auto_w),
        .enc_on_timbre (menu_on_t),
        .enc_on_octave (menu_on_o),
        .enc_on_volume (menu_on_v),
        .enc_on_vib    (menu_on_vb),
        .enc_on_chorus (menu_on_c),
        .paj_phase   (paj_phase),
        .paj_rej     (paj_rej),
        .paj_ecnt    (paj_ecnt),
        .paj_fidx    (paj_fail_idx),
        .paj_g1      (paj_ges1_raw),
        .paj_g2      (paj_ges2_raw),
        .paj_wa0     (paj_wa0),
        .page        (page),
        .vbusy       (vbusy_w),
    .barval      (spec_val),
        .baridx      (spec_idx),
        .barlow      (spec_low),
        //   这 8 根线本来就已经在 (上面 u_spectrum 的输出, 只接给 UART 状态块),
        //   这里只是多接一个消费方, 不新增任何逻辑/寄存器。
        .bnd0        (spec_b0),
        .bnd1        (spec_b1),
        .bnd2        (spec_b2),
        .bnd3        (spec_b3),
        .bnd4        (spec_b4),
        .bnd5        (spec_b5),
        .bnd6        (spec_b6),
        .bnd7        (spec_b7),
        .sorow       (4'd0),
        .socol       (2'd0),
        .sonote      (7'd0),
        .soenv       (8'd0),
        .sobusy      (1'b0),
        //   一个锯齿波有几十个谐波, 两个富谐波波形做 XY 等于上千条曲线叠在一起。
        //   改用基频之后与音色无关, 永远干净, 而且图形直接反映音程。
        .aclk        (clk_aud_w),
        .atick       (tick),
        .lis_x       (voice0_ph),
    .lis_y       (lis_y_eff),
        .r           (lcd_r),
        .g           (lcd_g),
        .b           (lcd_b),
        .hs_o        (lcd_hs),
        .vs_o        (lcd_vs),
        .de_o        (lcd_de)
    );

    assign lcd_dclk = pclk_w;

    // 12. M3 多维交互: HC-SR04 超声波测距
    //     跑在 3MHz 音频时钟域 —— 复用现成时钟, 不新增时钟域、不占 PLL。
    //       先确认传感器通了、数字跟手, 下一步再映射成力度 vel。
    // (dist_cm / dist_valid / dist_tog 已在文件开头提前声明 —— 它们要在

    paj7620 u_paj (
        .clk      (clk),  // 27MHz
        .rst_n    (rst_n),
        .scl      (i2c_scl_drv),
        .sda_oe   (i2c_sda_oe_d),
        .sda_o    (i2c_sda_o_d),
        .sda_i    (i2c_sda_i),
        .ges1_raw (paj_ges1_raw),  // 0x43 原始字节
        .ges2_raw (paj_ges2_raw),  // 0x44 原始字节 (挥动在里面)
        .ges      (paj_ges),  // 解出来的九种手势号 1..9
        .wa0      (paj_wa0),
        .wa1      (paj_wa1),
        .phase    (paj_phase),
        .err_seen (paj_err),
        .err_cnt  (paj_ecnt),
        .tog      (paj_tog),
        .busy     (),
        .rej_cnt  (paj_rej),
        .fail_idx (paj_fail_idx)
    );

    assign vib_depth = menu_on_vb ? menu_vib_w : vib_ges;

    //---- 颤音 LFO ----
    wire signed [15:0] pm_o;
    lfo_vib u_vib (
        .clk     (clk_aud_w),
        .rst_n   (rst_n),
        .tick    (tick),
        .depth   (vib_depth),
        .oct_hi  (oct_idx != 2'd0),  // 只要往上移了调, pm 相应加值 (音分深度保持恒定)
        .pm      (pm_o)
    );
    assign pm_w = pm_o;

    ws2812_led #(.NLED(70), .NVOICE(NVOICE), .PCB_N(10)) u_ws2812 (
        .aclk        (clk_aud_w),
        .arst_n      (rst_n),
        .atick       (tick),
        .voice_led   (voice_led_w),
        .clk         (clk),
        .rst_n       (rst_n),
        //   灯带在"曲谱模式"和"声部显示模式"之间二选一。
        //   也不会出问题 —— 最坏是晚一颗灯生效, 肉眼看不出来。
        .score_en    (score_on),
        .score_play  (sc_state == 2'd1),
        .tr_idx      (tr_idx),
        .want_deg    (sc_want_deg),
        .note_pos    (sc_note_pos),
        .note_total  (sc_note_total),
        .hit_pulse   (sc_hit_pulse),
        .miss_pulse  (sc_miss_pulse),
        .beat_on     (sc_beat_on),
        //   10 根弦的按下状态, 每根弦旁边那颗灯用它决定亮不亮。
        .str_key     (str_key_10),
        .page        (page),
        //    指引模式下闪烁是"提醒你弹", 而自动播放时
        //    灯就是"正在发声的音", 闪烁反而像故障。
        .score_auto  (menu_auto_w),
        .dout        (ws2812_dout)
    );

    wire        sc_playing;
    wire        sc_beat_tog;
    wire        sc_song_done;

    //    (score_on 的声明已挪到提前声明区)
    reg  sc_prev_play;
    reg sc_rst_d, sc_next_d, sc_play_d;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            sc_rst_d  <= 1'b0;
            sc_next_d <= 1'b0;
            sc_play_d <= 1'b0;
        end else begin
            sc_rst_d  <= ucmd_score_rst_tg;
            sc_next_d <= ucmd_score_next_tg;
            sc_play_d <= ucmd_score_play_tg;
        end
    end
    wire sc_rst_p  = sc_rst_d  ^ ucmd_score_rst_tg;  // 边沿 = 单拍脉冲
    wire sc_next_p = sc_next_d ^ ucmd_score_next_tg;
    wire sc_play_p = sc_play_d ^ ucmd_score_play_tg;

    //  ---- 编码器的三个脉冲 (3MHz 域边沿检测) ----

    wire sc_play_press = (s2_press & ~tst_act) | sc_play_p | enc_play;

    reg sc_s2_latch;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) begin
            sc_s2_latch <= 1'b0;
        end else begin
            if (sc_play_press) sc_s2_latch <= 1'b1;  // 按过 s2 就一直算打开
        end
    end
    wire sc_force_off = ucmd_score_set & ~ucmd_score_on;
    always @(posedge clk_aud_w or negedge rst_n) begin
        if (!rst_n) score_on <= 1'b0;
        else if (sc_force_off) score_on <= 1'b0;
        else if (ucmd_score_on) score_on <= 1'b1;
        else if (sc_s2_latch && !score_on) score_on <= 1'b1;
    end

    rotary_enc #(
        .CLK_HZ   (27_000_000),  // 本模块跑在 27MHz
        .FILT_DIV (27_000),  // 1ms 采样节拍
        .STABLE_MS(1),  // 去抖窗口 (EC11 弹跳 <=1ms)
        .LONG_MS  (800)  // 长按 800ms
    ) u_enc (
        .clk      (clk),
        .rst_n    (rst_n),
        .enc_a    (enc_a),
        .enc_b    (enc_b),
        .enc_sw   (enc_sw),
        .step     (enc_step),
        .dir      (enc_dir),
        .pos      (enc_pos),
        .sw_press (enc_press),
        .sw_long  (enc_long),
        .sw_state ()
    );

    //  ---- 下载曲谱 RAM (2048 字节) ----
    //    真双口: 写口 27MHz (uart_cmd), 读口 3MHz (score_player)
    score_ram #(.AW(11), .DW(8)) u_scr (
        .wclk  (clk),
        .we    (scr_we),
        .waddr (scr_waddr),
        .wdata (scr_wdata),
        .rclk  (clk_aud_w),
        .raddr (scr_raddr[10:0]),
        .rdata (scr_rdata)
    );

    //  ---- 录音时间戳已挪到前面 (毫秒计数), 见 ev_msdiv / ev_tick ----

    score_player #(.TIMEOUT_TICKS(24'd750000)) u_score (  // 8 \u79d2\u8d85\u65f6
        .clk          (clk_aud_w),
        .rst_n        (rst_n),
        .atick        (tick),
        .btn_start    (sc_play_press),  // s2 = 播放/暂停
        .btn_reset    (sc_rst_p | enc_home),  // 上位机 或 编码器长按: 回开头
        .btn_nextsong (sc_next_p),  // 上位机换曲 (编码器现在由 menu_fsm 经 song_sel 换)
        .next_dir     (enc_dir),  // 旋转方向
        .song_sel     (menu_song_w),
        .enable       (score_on),
        //   key_act  = 引脚原始电平 (手指扫过只有 1~5ms)
        //   key_gate = 拉长到至少 30ms 的门, **和发声路径同一个信号**
        .keys         (key_gate),
        .dl_valid     (scr_valid),
        .dl_len       (scr_len),
        .dl_addr      (scr_raddr),
        .dl_rdata     (scr_rdata),
        .song_idx     (sc_song_idx),
        .playing      (sc_playing),
        .want_deg     (sc_want_deg),
        .note_pos     (sc_note_pos),
        .note_total   (sc_note_total),
        .hit_cnt      (sc_hit_cnt),
        .miss_cnt     (sc_miss_cnt),
        .beat_tog     (sc_beat_tog),
        .beat_on      (sc_beat_on),
        .hit_pulse    (sc_hit_pulse),
        .miss_pulse   (sc_miss_pulse),
        .song_done    (sc_song_done),
        .sc_state     (sc_state),
        //    auto_play 来自菜单 MUSIC 页的 MODE 项
        .auto_play    (menu_auto_w),
        //    (开关在 tr_off, 拨 SW 弦改变调号)
        .oct_off      (oct_off),
        .tr_off       (tr_off),
        .sp_on        (sp_on_w),
        .sp_off       (sp_off_w),
        .sp_note      (sp_note_w)
    );

endmodule
