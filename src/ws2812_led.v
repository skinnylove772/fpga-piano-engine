// ws2812_led.v —— WS2812 灯带(60 灯): 按键打出亮点, 亮点向右流动
module ws2812_led #(
    parameter NLED   = 70,
    parameter NVOICE = 32,  // 声部数 (只用来解释 voice_led 的打包格式)
    parameter NDOT   = 24,  // 同时存在的亮点槽数 (必须是偶数)
    parameter PCB_N  = 10
)(
    //---- 音频域侧 ----
    input  wire        aclk,  // 3MHz 音频时钟
    input  wire        arst_n,
    input  wire        atick,  // 每采样一个脉冲
    input  wire [16*NVOICE-1:0] voice_led,  // 各声部 {note[6:0],busy,env[7:0]}

    //---- 27MHz 域侧 ----
    input  wire        clk,
    input  wire        rst_n,
    input  wire        score_en,  // 1 = 曲谱模式开关打开(模式选择, 不代表在放歌)
    //    1 = 指引模式 (亮灯告诉你该弹哪个)
    //    0 = 按键回显 (你按下哪个就亮哪个)
    input  wire        score_play,
    //    1 = 自动播放 (FPGA 自己弹), PCB 对应的灯**常亮**
    //    0 = 指引模式, 灯闪烁提醒你弹
    input  wire        score_auto,
    //    跨时钟域: tr_idx 在 3MHz 域, 这里在 27MHz 域用。
    //    它只在拨弦时才变 (人手速度), 做不同步也没关系 ——
    //    最坏情况是颜色晚一帧变, 肉眼看不出来。
    input  wire [3:0]  tr_idx,
    input  wire [3:0]  want_deg,  // 该弹的音级 0=休止 1..7 8..14=高音
    input  wire [9:0]  note_pos,  // 当前第几个音
    input  wire [9:0]  note_total,  // 本曲共几个音
    input  wire        hit_pulse,  // 弹对: 单拍脉冲 (保持约 0.3 秒)
    input  wire        miss_pulse,  // 弹错: 单拍脉冲
    input  wire        beat_on,
    //   每一根红外光弦旁边一颗 WS2812 (PCB 上共 10 颗), 占链路最前面 10 位。
    //   用按下键的原始电平直接驱动颜色 —— 每个音自己的色相, 和灯带一致。
    input  wire [9:0]  str_key,  // 10 根弦的按下状态 (1 = 按下/遮挡)
    input  wire [3:0]  page,  // 0=HOME 1=MAIN 2=GRAPH 3=PARAM 4=MUSIC 5=TEST
    output wire        dout
);

    wire [NVOICE-1:0] busy_now;
    genvar gi;
    generate
        for (gi = 0; gi < NVOICE; gi = gi + 1) begin : g_busy
            assign busy_now[gi] = voice_led[16*gi + 8];
        end
    endgenerate

    reg  [NVOICE-1:0] busy_d;
    wire [NVOICE-1:0] rising = busy_now & ~busy_d;

    reg  [5:0] vidx;
    reg        vfound;
    integer    vi;
    always @* begin
        vidx   = 6'd0;
        vfound = 1'b0;
        for (vi = NVOICE-1; vi >= 0; vi = vi - 1) begin
            if (rising[vi]) begin
                vidx   = vi[5:0];
                vfound = 1'b1;
            end
        end
    end

    reg [5:0] vidx_r;
    reg       vfound_r;

    reg       note_seen_a;

    always @(posedge aclk or negedge arst_n) begin
        if (!arst_n) begin
            vidx_r    <= 6'd0;
            vfound_r  <= 1'b0;
            note_seen_a <= 1'b0;
        end else if (atick) begin
            vidx_r   <= vidx;
            vfound_r <= vfound;
            if (vfound) note_seen_a <= 1'b1;
        end
    end

    //  用锁存下来的编号去取音名 —— 此时总线上这一个声部的 note 已经稳定
    wire [6:0] vn = voice_led[16*vidx_r + 15 -: 7];

    function [3:0] mod12;  // 不用 function 名同关键字
        input [6:0] n;
        reg [6:0] r;
        begin
            if      (n >= 7'd120) r = n - 7'd120;
            else if (n >= 7'd108) r = n - 7'd108;
            else if (n >= 7'd96 ) r = n - 7'd96;
            else if (n >= 7'd84 ) r = n - 7'd84;
            else if (n >= 7'd72 ) r = n - 7'd72;
            else if (n >= 7'd60 ) r = n - 7'd60;
            else if (n >= 7'd48 ) r = n - 7'd48;
            else if (n >= 7'd36 ) r = n - 7'd36;
            else if (n >= 7'd24 ) r = n - 7'd24;
            else if (n >= 7'd12 ) r = n - 7'd12;
            else                  r = n;
            mod12 = r[3:0];  // 显式取低 4 位 (值域 0..11)
        end
    endfunction

    wire [3:0] vpc = mod12(vn);  // 音级 0..11
    wire [5:0] vpos  = 6'd10;  // 固定起点 = 灯带第 1 颗
    reg [2:0] vhue;
    always @* begin
        case (vpc)
            4'd0:  vhue = 3'd0;  // do   (C)
            4'd2:  vhue = 3'd1;  // re   (D)
            4'd4:  vhue = 3'd2;  // mi   (E)
            4'd5:  vhue = 3'd3;  // fa   (F)
            4'd7:  vhue = 3'd4;  // sol  (G)
            4'd9:  vhue = 3'd5;  // la   (A)
            4'd11: vhue = 3'd6;  // si   (B)
            default: vhue = 3'd0;  // 非七声音阶内的音 (测试模式等) -> 给 do 的颜色
        endcase
    end

    reg  [10:0] evt_a;
    reg         evt_tog_a;
    always @(posedge aclk or negedge arst_n) begin
        if (!arst_n) begin
            busy_d    <= {NVOICE{1'b0}};
            evt_a     <= 11'd0;
            evt_tog_a <= 1'b0;
        end else if (atick) begin
            busy_d <= busy_now;
            if (vfound_r) begin
                evt_a     <= {vpos, 1'b0, vhue};
                evt_tog_a <= ~evt_tog_a;
            end
        end
    end

    localparam [19:0] T_FRAME = 20'd540000;
    reg [19:0] fcnt;
    reg        frame_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fcnt       <= 20'd0;
            frame_tick <= 1'b0;
        end else begin
            frame_tick <= 1'b0;
            if (fcnt == T_FRAME) begin
                fcnt       <= 20'd0;
                frame_tick <= 1'b1;
            end else begin
                fcnt <= fcnt + 20'd1;
            end
        end
    end

    reg [1:0]  evt_s;
    reg [10:0] evt;
    reg        evt_pend;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            evt_s    <= 2'b00;
            evt      <= 11'd0;
            evt_pend <= 1'b0;
        end else begin
            evt_s <= {evt_s[0], evt_tog_a};
            if (evt_s[1] ^ evt_s[0]) begin
                evt      <= evt_a;  // 此刻 evt_a 早已稳定
                evt_pend <= 1'b1;
            end else if (frame_tick) begin
                evt_pend <= 1'b0;  // 已被这一帧消费
            end
        end
    end

    reg [7:0] dot_off [0:NDOT-1];
    reg [2:0] dot_hue [0:NDOT-1];
    reg       dot_act [0:NDOT-1];
    reg [4:0] dot_wr;

    reg [7:0] cnt;  // 帧号 (每帧 +1, 8 位)

    wire [5:0] tpos  = evt[9:4];  // 编码是 {vpos[5:0],1'b0,vhue[2:0]}, 位置在 [9:4]
    wire [5:0] tpos1 = (tpos >= NLED[5:0] - 6'd1) ? tpos : (tpos + 6'd1);
    wire [3:0] thue  = evt[3:0];

    wire [7:0] tpos8 = {2'b0, tpos};
    wire [7:0] tpo18 = {2'b0, tpos1};
    wire [7:0] cnt1  = cnt + 8'd1;

    // 各槽的当前位置 (组合, 与灯号无关, 全局算一次)
    wire [7:0] dot_pos [0:NDOT-1];
    genvar gk;
    generate
        for (gk = 0; gk < NDOT; gk = gk + 1) begin : g_pos
            assign dot_pos[gk] = dot_off[gk] + cnt;  // 两边都是 8 位, 回绕自洽
        end
    endgenerate

    integer dk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= 8'd0;
            dot_wr  <= 3'd0;
            for (dk = 0; dk < NDOT; dk = dk + 1) begin
                dot_off[dk] <= 8'd0;
                dot_hue[dk] <= 3'd0;
                dot_act[dk] <= 1'b0;
            end
        end else if (frame_tick) begin
            cnt <= cnt + 8'd1;

            for (dk = 0; dk < NDOT; dk = dk + 1) begin
                if (dot_act[dk] && (dot_pos[dk] > NLED[7:0] - 8'd1))
                    dot_act[dk] <= 1'b0;
            end

            if (evt_pend) begin
                dot_off[dot_wr] <= tpos8 - cnt1;
                dot_hue[dot_wr] <= thue[2:0];
                dot_act[dot_wr] <= 1'b1;
                if (NDOT >= 2) begin
                    dot_off[dot_wr + 5'd1] <= tpo18 - cnt1;
                    dot_hue[dot_wr + 5'd1] <= thue[2:0];
                    dot_act[dot_wr + 5'd1] <= 1'b1;
                end
                //    用常量比较: 下一组要越界就回 0
                dot_wr <= (dot_wr >= (NDOT - 2)) ? 5'd0 : (dot_wr + 5'd2);
            end
        end
    end

    wire [7:0] led_idx;

    reg       hit;
    reg [2:0] hit_hue;
    integer   hk;
    always @* begin
        hit     = 1'b0;
        hit_hue = 3'd0;
        for (hk = 0; hk < NDOT; hk = hk + 1) begin
            // 不判 dot_act 也能对: 未启用的槽 off=0, pos=cnt, 只会在 cnt 恰好
            // 等于 led_idx 时误命中; 加上 act 判断最稳妥, 代价是一个 AND。
            if (dot_act[hk] && (dot_pos[hk] == led_idx))
                begin hit = 1'b1; hit_hue = dot_hue[hk]; end
        end
    end

    wire [2:0] use_hue = hit_hue;

    localparam [3:0] BRIGHT = 4'd15;

    // hit 为 0 时 lvl=0, 三个通道全乘 0 -> 全黑, 不用额外的门控
    wire [3:0] lvl = hit ? BRIGHT : 4'd0;

    reg [23:0] base;
    always @* begin
        case (use_hue)
            3'd0:    base = {8'd0,   8'd255, 8'd0  };  //   0°  红
            3'd1:    base = {8'd219, 8'd255, 8'd0  };  //  51°  橙黄
            3'd2:    base = {8'd255, 8'd73,  8'd0  };  // 103°  黄绿
            3'd3:    base = {8'd255, 8'd0,   8'd146};  // 154°  绿青
            3'd4:    base = {8'd146, 8'd0,   8'd255};  // 206°  青蓝
            3'd5:    base = {8'd0,   8'd73,  8'd255};  // 257°  蓝紫
            default: base = {8'd0,   8'd255, 8'd219};  // 309°  品红
        endcase
    end

    wire [11:0] gm = base[23:16] * {4'd0, lvl};
    wire [11:0] rm = base[15:8]  * {4'd0, lvl};
    wire [11:0] bm = base[7:0]   * {4'd0, lvl};
    wire [23:0] color_synth = {gm[11:4], rm[11:4], bm[11:4]};

    //    PCB 灯用 pcb_i (弦号) 直接索引颜色表。

    //    0.3s @27MHz = 8_100_000
    reg [23:0] hold_cnt;
    reg        hit_lat, miss_lat;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_cnt <= 24'd0;
            hit_lat  <= 1'b0;
            miss_lat <= 1'b0;
        end else begin
            if (hit_pulse) begin
                hit_lat  <= 1'b1;  miss_lat <= 1'b0;  hold_cnt <= 24'd0;
            end else if (miss_pulse) begin
                miss_lat <= 1'b1;  hit_lat  <= 1'b0;  hold_cnt <= 24'd0;
            end else if (hit_lat || miss_lat) begin
                if (hold_cnt >= 24'd8100000) begin
                    hit_lat  <= 1'b0;
                    miss_lat <= 1'b0;
                end else begin
                    hold_cnt <= hold_cnt + 24'd1;
                end
            end
        end
    end

    wire [7:0] pcb_n8  = 8'd10;  // = PCB_N, 显式 8 位
    wire [7:0] str_i   = led_idx - pcb_n8;  // 灯带内序号 (0..59)

    //  指法区颜色
    //    不闪的话静止一片青色不容易注意到。
    reg [15:0] blink_cnt;
    reg        blink;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blink_cnt <= 16'd0;
            blink     <= 1'b0;
        end else if (blink_cnt == 16'd20000) begin  // 0.74ms @27MHz -> 约 675Hz/2, 肉眼是快闪
            blink_cnt <= 16'd0;
            blink     <= ~blink;
        end else begin
            blink_cnt <= blink_cnt + 16'd1;
        end
    end

    wire [2:0] want_hue = (want_deg >= 4'd8) ? (want_deg[2:0] - 3'd1)
                                            : (want_deg[2:0] - 3'd1);
    reg [23:0] hue_col;
    always @(*) begin
        case (want_hue)
            3'd0:    hue_col = {8'd0,   8'd255, 8'd0  };  // do   红
            3'd1:    hue_col = {8'd219, 8'd255, 8'd0  };  // re   橙黄
            3'd2:    hue_col = {8'd255, 8'd73,  8'd0  };  // mi   黄绿
            3'd3:    hue_col = {8'd255, 8'd0,   8'd146};  // fa   绿青
            3'd4:    hue_col = {8'd146, 8'd0,   8'd255};  // sol  青蓝
            3'd5:    hue_col = {8'd0,   8'd73,  8'd255};  // la   蓝紫
            3'd6:    hue_col = {8'd0,   8'd255, 8'd219};  // si   品红
            default: hue_col = {8'd0,   8'd0,   8'd0  };
        endcase
    end

    //    曲谱指引的配色现在在 PCB 灯那段 (color_pcb) 里, 用的是同一套色环。
    //      第一次用正则删这 30 行时只匹配到内层的 `end`, 把外层 always 的
    //      收尾留下了, 报 EX2656/EX3863。教训同 gen_osd.py 那次:
    //      **跨多层的 begin/end 块不要用正则删, 要按行号或加唯一锚点。**

    //  这颗灯属于哪根弦 (0..9); led_idx >= PCB_N 时无意义 (灯带区)
    wire [3:0] pcb_i = led_idx[3:0];
    wire       led_in_pcb = (led_idx < pcb_n8);

    //  ---- 弦号 -> 该弦当前是否按下/该弹 ----
    //  普通模式: 看 str_key (10 根弦的按下电平)
    //  指引模式: 看 want_deg (该弹的音级), 弹对了由 hit_lat 压灭
    wire [3:0] want_str = (want_deg == 4'd0) ? 4'd15  // 15 = 休止, 不亮
                        : (want_deg - 4'd1);  // 音级 1..10 -> 弦 0..9

    //  这根弦"按下"了吗 (普通模式用)
    wire pcb_pressed;
    //  这根弦"该弹"吗 (指引模式用)
    wire pcb_wanted = (want_str != 4'd15) && (pcb_i == want_str);

    //    Verilog-2001 不允许对**表达式**做位选, 但允许变量下标 (str_key[pcb_i])。
    assign pcb_pressed = led_in_pcb ? str_key[pcb_i[3:0]] : 1'b0;

    //  ---- 弦号 -> 色环颜色 (PCB 灯与灯带**共用这一张表**) ----
    //    灯带侧多一个调用点, 综合器会做资源共享, 代价很小。
    function [23:0] hue_of_str;
        input [3:0] st;
        begin
            case (st)
                4'd0: hue_of_str = {8'd0,   8'd255, 8'd0  };  //  1 do     红
                4'd1: hue_of_str = {8'd219, 8'd255, 8'd0  };  //  2 re     橙黄
                4'd2: hue_of_str = {8'd255, 8'd73,  8'd0  };  //  3 mi     黄绿
                4'd3: hue_of_str = {8'd255, 8'd0,   8'd146};  //  4 fa     绿青
                4'd4: hue_of_str = {8'd146, 8'd0,   8'd255};  //  5 sol    青蓝
                4'd5: hue_of_str = {8'd0,   8'd73,  8'd255};  //  6 la     蓝紫
                4'd6: hue_of_str = {8'd0,   8'd255, 8'd219};  //  7 si     品红
                //  高八度的三根: 用 do/re/mi 的**提亮版** (各通道加约 1/4)
                4'd7: hue_of_str = {8'd80,  8'd255, 8'd80 };  //  8 高 do  亮红
                4'd8: hue_of_str = {8'd245, 8'd255, 8'd90 };  //  9 高 re  亮橙黄
                4'd9: hue_of_str = {8'd255, 8'd160, 8'd90 };  // 10 高 mi  亮黄绿
                default: hue_of_str = 24'd0;
            endcase
        end
    endfunction

    wire [23:0] pcb_col_base = hue_of_str(pcb_i);

    reg [23:0] color_tr;
    always @(*) begin
        case (tr_idx)
            //  格式 {G, R, B} —— WS2812 是绿在前!
            4'd0 : color_tr = {8'd0,   8'd255, 8'd0  };  //  0 半音  红
            4'd1 : color_tr = {8'd128, 8'd255, 8'd0  };  //  1 半音  橙
            4'd2 : color_tr = {8'd255, 8'd255, 8'd0  };  //  2 半音  黄
            4'd3 : color_tr = {8'd255, 8'd128, 8'd0  };  //  3 半音  黄绿
            4'd4 : color_tr = {8'd255, 8'd0,   8'd0  };  //  4 半音  绿
            4'd5 : color_tr = {8'd255, 8'd0,   8'd128};  //  5 半音  翠绿
            4'd6 : color_tr = {8'd255, 8'd0,   8'd255};  //  6 半音  青
            4'd7 : color_tr = {8'd128, 8'd0,   8'd255};  //  7 半音  天蓝
            4'd8 : color_tr = {8'd0,   8'd0,   8'd255};  //  8 半音  蓝
            4'd9 : color_tr = {8'd0,   8'd128, 8'd255};  //  9 半音  紫
            4'd10: color_tr = {8'd0,   8'd255, 8'd255};  // 10 半音  品红
            4'd11: color_tr = {8'd0,   8'd255, 8'd128};  // 11 半音  玫红
            default: color_tr = 24'd0;
        endcase
    end

    //  ---- PCB 灯最终颜色 ----
    reg [23:0] color_pcb;
    always @(*) begin
        color_pcb = 24'd0;
        if (led_in_pcb) begin
            if (pcb_i == 4'd9) begin
                color_pcb = pcb_pressed ? color_tr : 24'd0;
            end else if (score_play) begin
                //  ---- 乐曲指引模式 (只有真正放歌时走这里) ----
                //   亮灯告诉你该弹这个音。
                //    指引模式: 闪烁 = "该你弹了", 这是提醒信号
                //    弹错/弹对在自动播放下不会发生 (没有判定)。
                if (score_auto) begin
                    color_pcb = pcb_wanted ? pcb_col_base : 24'd0;  // 该响的音: 常亮本色
                end else if (pcb_wanted && miss_lat) begin
                    color_pcb = blink ? {8'd0, 8'd255, 8'd0}  // 弹错: 纯红闪
                                      : {8'd0, 8'd90,  8'd0};
                end else if (pcb_wanted && hit_lat) begin
                    color_pcb = 24'd0;  // 弹对: 灭
                end else if (pcb_wanted) begin
                    //    完全没有节拍信息。现在 beat_on 在每拍前 1/4 为高:
                    //      拍点到了 -> 本色全亮 (亮点 = "该弹了")
                    //      拍内其余 -> 约半亮 (暗着 = "还在这个拍里")
                    //    于是灯光同时告诉你**弹哪个音**和**什么时候弹**。
                    color_pcb = beat_on ? pcb_col_base  // 该弹: 拍点亮
                                        : {1'b0, pcb_col_base[23:17],
                                           1'b0, pcb_col_base[15:9],
                                           1'b0, pcb_col_base[7:1]};  // 拍内: 半亮
                end
            end else if (pcb_pressed) begin
                //  ---- 按键回显 (不在放歌时) ----
                //   按下哪根弦, 它旁边那颗灯就亮本色, 松开就灭。
                color_pcb = pcb_col_base;
            end
        end
    end

    localparam        LED_TEST_ALL = 1'b0;

    localparam [7:0]  LED_TEST_G = 8'd40;
    localparam [7:0]  LED_TEST_R = 8'd55;
    localparam [7:0]  LED_TEST_B = 8'd30;

    wire [23:0] color_test = {LED_TEST_G, LED_TEST_R, LED_TEST_B};

    localparam [28:0] B15S = 29'd405_000_000;

    //  ---- page 是 3MHz 域, 这里是 27MHz 域 -> 2 级同步 ----
    reg [3:0] pg0, pg1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin pg0 <= 4'd0; pg1 <= 4'd0; end
        else        begin pg0 <= page;  pg1 <= pg0;  end
    end
    wire in_main = (pg1 == 4'd1);  // MAIN 页

    reg  main_d;
    wire main_rise = in_main & ~main_d;  // 进入 MAIN 的上升沿
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) main_d <= 1'b0;
        else        main_d <= in_main;
    end

    //  ---- 把"已经弹过音"同步到 27MHz 域 ----
    reg ns0, ns1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ns0 <= 1'b0; ns1 <= 1'b0; end
        else        begin ns0 <= note_seen_a; ns1 <= ns0; end
    end

    reg  note_seen_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          note_seen_r <= 1'b0;
        else if (main_rise)  note_seen_r <= 1'b0;  // 重新进入 MAIN -> 允许再亮
        else if (ns1)        note_seen_r <= 1'b1;
    end

    reg [28:0] bw_cnt;
    wire boot_win = (bw_cnt != 29'd0);  // 彩带窗口
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                bw_cnt <= 29'd0;
        else if (main_rise)        bw_cnt <= B15S;  // 进入 MAIN -> 亮 15 秒
        else if (note_seen_r)      bw_cnt <= 29'd0;  // 一弹就立刻结束, 让位给音符颜色
        else if (bw_cnt != 29'd0)  bw_cnt <= bw_cnt - 29'd1;
    end

    //  10 色环 (24 位打包 = {G, R, B}; WS2812 是**绿在前**)
    //  亮度取 40~56: 80 颗全白 255 要 4.8A, 会拉垮弱电源
    function [23:0] boot_pal;
        input [3:0] i;
        begin
            case (i)
                4'd0: boot_pal = {8'd0,  8'd56, 8'd0 };  // 1  红   (R56 G0  B0 )
                4'd1: boot_pal = {8'd16, 8'd56, 8'd0 };  // 2  橙   (R56 G16 B0 )
                4'd2: boot_pal = {8'd52, 8'd58, 8'd0 };  // 3  黄   (R58 G52 B0 )
                4'd3: boot_pal = {8'd52, 8'd0,  8'd8 };  // 4  绿   (R0  G52 B8 )
                4'd4: boot_pal = {8'd48, 8'd0,  8'd48};  // 5  青   (R0  G48 B48)
                4'd5: boot_pal = {8'd6,  8'd0,  8'd56};  // 6  蓝   (R0  G6  B56)
                4'd6: boot_pal = {8'd0,  8'd32, 8'd56};  // 7  紫   (R32 G0  B56)
                4'd7: boot_pal = {8'd18, 8'd56, 8'd34};  // 8  粉   (R56 G18 B34)
                4'd8: boot_pal = {8'd50, 8'd50, 8'd50};  // 9  白   (R50 G50 B50)
                default: boot_pal = {8'd38, 8'd54, 8'd4};  // 10 金   (R54 G38 B4 )
            endcase
        end
    endfunction

    wire [6:0] bs = led_idx[6:0] - 7'd10;  // 灯带内编号 0..59
    //    本文件 506 行已经有一个 `wire [11:0] bm` (正常逻辑里的
    //    **蓝色通道** base*lvl)。我又声明了一个 `wire [6:0] bm`,
    //    `bm[3:0]` 读到的是**蓝色通道的低 4 位** (静音时为 0),
    //    索引恒为 0 -> 全串都是第 0 色 = **全红**。
    wire [6:0] boot_mod = (bs >= 7'd50) ? (bs - 7'd50) :
                          (bs >= 7'd40) ? (bs - 7'd40) :
                          (bs >= 7'd30) ? (bs - 7'd30) :
                          (bs >= 7'd20) ? (bs - 7'd20) :
                          (bs >= 7'd10) ? (bs - 7'd10) : bs;  // bs % 10

    wire [3:0]  boot_i     = led_in_pcb ? pcb_i : boot_mod[3:0];
    wire [23:0] color_boot = boot_pal(boot_i);  // 全亮, 不流动

    //  最终颜色: 测试开关 > 开机彩带 > 正常逻辑
    wire [23:0] color = LED_TEST_ALL ? color_test
                                     : boot_win ? color_boot
                                     : (led_in_pcb ? color_pcb : color_synth);

    wire drv_busy;
    wire start_req = frame_tick & ~drv_busy;

    ws2812_drv #(.NLED(NLED)) u_drv (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (start_req),
        .color_in (color),
        .led_idx  (led_idx),
        .dout     (dout),
        .busy     (drv_busy)
    );

endmodule
