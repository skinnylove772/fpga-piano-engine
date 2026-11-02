// uart_cmd.v —— 上位机命令解析 + 状态回传 + **可写寄存器**
module uart_cmd #(
    parameter CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        rst_n,

    //---- 来自 uart_rx ----
    input  wire [7:0]  rx_data,
    input  wire        rx_done,  // 单拍脉冲: 收到一字节

    //---- 送去 uart_tx ----
    output wire [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,

    //---- 只读状态量 ----
    input  wire [5:0]  st_voices,  // RID 0
    input  wire [2:0]  st_timbre,  // RID 1 (没写过时用它)
    input  wire [1:0]  st_oct,
    input  wire [5:0]  st_env,  // RID 2
    input  wire [3:0]  st_test,  // RID 3
    input  wire [7:0]  st_ges,  // RID 4
    input  wire [7:0]  st_b0, st_b1, st_b2, st_b3,
    input  wire [7:0]  st_b4, st_b5, st_b6, st_b7,

    //---- 可写配置 (输出给 top.v) ----
    //    每槽 = 该根弦的**结对音高** (MIDI 0..127)
    output wire [69:0] cfg_keymap,
    //    0=音弦 1=变调 2=音色 3=八度 4=力度 5=音量
    output wire [29:0] cfg_kmap_kind,
    output reg  [2:0]  cfg_timbre,  // RID 1: 音色
    output wire        cfg_timbre_en,
    output wire        cfg_host_on,
    output wire        cfg_vel_en,
    output wire        cfg_vib_en,
    output wire        cfg_chorus_en,
    //      (s1=测试模式, s2=播放/暂停), "换曲/重置"
    //      只能给上位机。而且这本来就是拓展 4 讲的
    //      "上位机联动", 用串口反而是加分项。
    output reg         score_set,
    output reg         score_on,
    output reg         score_rst_tg,
    output reg         score_next_tg,
    output reg         score_play_tg,
    output reg  [16:0] cfg_irrise,  // RID 5: 光弦灵敏度 (上升沿消抖拍数)
    output reg  [7:0]  cfg_master,  // RID 6: 主音量
    output reg  [1:0]  cfg_octave,  // RID 7: 八度
    //  ---- 扩展 8 位参数 (由 'W' 的低 4 位选择) ----
    output reg  [7:0]  cfg_vel,  // XRID 0: 力度 80..240
    output reg  [2:0]  cfg_vib,  // XRID 1: 颤音深度 0..7
    output reg         cfg_chorus,  // XRID 2: 合唱开关
    output reg  [7:0]  cfg_fxamt,  // XRID 3: 效果器深度 (预留)
    output reg         cfg_valid,  // 有新配置时给一拍脉冲

    input  wire [1:0]  sc_song,
    input  wire [1:0]  sc_state,  // 0=停 1=播 2=弹完
    input  wire [3:0]  sc_deg,  // 该弹的音级
    input  wire [11:0] sc_pos,
    input  wire [11:0] sc_total,
    input  wire [7:0]  sc_hit,
    input  wire [7:0]  sc_miss,
    input  wire [9:0]  sc_keyact,
    input  wire [6:0]  sc_keylat,

    //    命令 'c' (0x63), 应答 16 字节: "SD=" + state(2) + err(1) + ocr(8) + CRLF
    //      state: 8 = SD_OK (初始化成功) ; 9/10/11 = 各步失败
    //      err  : 0=无 1=CMD0无响应(卡没插/接线错) 2=CMD8失败 3=ACMD41超时
    //      ocr  : CMD58 读到的 OCR, bit30(CCS)=1 表示 SDHC (按扇区寻址)

    //---- 心跳 ----
    input  wire        hb_pulse,
    output reg  [10:0]     scr_waddr,
    output reg  [7:0]      scr_wdata,
    output reg             scr_we,
    //  ---- 曲谱长度与生效 ----
    output reg  [10:0]     scr_len,
    output reg             scr_valid,
    //  ---- 下载进度 (供回传查询) ----
    output reg  [11:0]     dl_wp,  // 已收字节数 (也是写指针)
    output reg             dl_err,
    //  ---- 录音: 接收 top.v 推来的事件 ----
    //     top 在 3MHz 域产生 ev_valid/ev_deg/ev_kind/ev_t16 单拍脉冲,
    //     本模块在 27MHz 域采样 (事件间隔远大于时钟周期, 不会丢)
    input  wire            ev_valid,
    input  wire [15:0]     lat_meas,
    input  wire [6:0]      ev_deg,
    input  wire [1:0]      ev_kind,  // 1=note on  2=note off
    input  wire [15:0]     ev_t16,  // 时间戳 (毫秒)
    input  wire [7:0]      ev_vel,
    output reg             rec_active,  // 1 = 正在录制
    output reg  [7:0]      rec_count  // 已记录条数

);

    localparam FRAME_N = 4;
    reg [7:0]  dstr [0:FRAME_N-1];
    reg        r_rx_done;
    wire       frame_ok = (dstr[0] == 8'hA5) && (dstr[3] == 8'h5A);
    wire [7:0] f_cmd    = dstr[1];
    wire [3:0] f_rid4   = dstr[2][7:4];
    wire [3:0] f_val4   = dstr[2][3:0];
    localparam DL_IDLE = 2'd0, DL_ARM = 2'd1, DL_CHUNK = 2'd2;
    reg [1:0]  dl_st;
    reg [11:0] dl_total;  // 声明下来的总字节数
    reg [3:0]  dl_hi;  // 长度的高 4 位 (先收到, 等低 8 位拼起来)
    reg        dl_hi_ok;  // 高 4 位已声明

    localparam [11:0] DL_CAP = 12'd2048;

    reg  ev_s0, ev_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ev_s0 <= 1'b0; ev_s1 <= 1'b0; end
        else begin ev_s0 <= ev_valid; ev_s1 <= ev_s0; end
    end
    wire ev_pulse = ev_s0 & ~ev_s1;  //  3MHz 脉冲在 27MHz 域里的上升沿

    //  ---- 录音事件写入用的小状态机信号 (先声明, 下面 always 里用) ----
    reg [7:0]  rec_mem [0:1023];
    reg [9:0]  rec_wp;
    reg [7:0]  rec_wr_byte;
    reg [2:0]  rec_wr_sub;
    reg        rec_wr_busy;
    //  每事件 5 字节:
    //      [0] MIDI 音符号   [1] 1=on 2=off   [2] 力度
    //      [3] 时间戳高 8 位 [4] 时间戳低 8 位
    always @(*) begin
        case (rec_wr_sub)
            3'd0: rec_wr_byte = {1'b0, ev_deg};
            3'd1: rec_wr_byte = {6'd0, ev_kind};
            3'd2: rec_wr_byte = ev_vel;
            3'd3: rec_wr_byte = ev_t16[15:8];
            default: rec_wr_byte = ev_t16[7:0];
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dl_st      <= DL_IDLE;
            scr_we     <= 1'b0;
            scr_waddr  <= 11'd0;
            scr_wdata  <= 8'd0;
            scr_len    <= 11'd0;
            scr_valid  <= 1'b0;
            dl_total   <= 12'd0;
            dl_hi      <= 4'd0;
            dl_wp      <= 12'd0;
            dl_hi_ok   <= 1'b0;
            dl_err     <= 1'b0;
            rec_wp     <= 10'd0;
            rec_count  <= 8'd0;
            rec_wr_busy <= 1'b0;
            rec_wr_sub  <= 3'd0;
        end else begin
            scr_we <= 1'b0;

            if (r_rx_done && frame_ok) begin
                case (f_cmd)
                    8'h5B: begin
                        dl_hi  <= dstr[2][3:0];
                        dl_wp  <= 12'd0;
                        dl_err <= 1'b0;
                        dl_st  <= DL_ARM;
                    end
                    8'h64: begin
                        dl_total <= {dl_hi, dstr[2]};
                        dl_wp    <= 12'd0;
                        dl_err   <= 1'b0;
                        dl_st    <= DL_ARM;
                    end
                    8'h5C: begin
                        if (dl_total != 12'd0) dl_st <= DL_CHUNK;
                    end
                    8'h5D: begin
                        if (dl_err || dl_wp == 12'd0) scr_valid <= 1'b0;
                        else begin
                            scr_len   <= dl_wp[10:0];
                            scr_valid <= 1'b1;
                        end
                        dl_st <= DL_IDLE;
                    end
                    8'h5E: begin
                        scr_valid <= 1'b0;
                        scr_len   <= 11'd0;
                        dl_wp     <= 12'd0;
                        dl_st     <= DL_IDLE;
                    end
                    8'h5F: begin rec_active <= 1'b1; rec_count <= 8'd0; rec_wp <= 10'd0; end
                    8'h60: begin rec_active <= 1'b0; end
                    default: ;
                endcase
            end

            //  ---- 数据字节收集: 只按计数, 不看内容 ----
            if (dl_st == DL_CHUNK && rx_done) begin
                scr_we    <= 1'b1;
                scr_waddr <= dl_wp[10:0];
                scr_wdata <= rx_data;
                if (dl_wp + 12'd1 >= DL_CAP) begin
                    dl_err <= 1'b1;
                    dl_st  <= DL_IDLE;
                end else begin
                    dl_wp <= dl_wp + 12'd1;
                    if (dl_wp + 12'd1 >= dl_total) dl_st <= DL_IDLE;  // 收满
                end
            end

            //  ---- 录音事件写入 ----
            if (rec_wr_busy) begin
                rec_mem[rec_wp] <= rec_wr_byte;
                rec_wp          <= rec_wp + 10'd1;
                if (rec_wr_sub == 3'd4) begin
                    rec_wr_busy <= 1'b0;
                    rec_count   <= rec_count + 8'd1;
                end else begin
                    rec_wr_sub <= rec_wr_sub + 3'd1;
                end
            end else if (rec_active && ev_pulse && rec_wp < 10'd1015) begin
                rec_wr_busy <= 1'b1;
                rec_wr_sub  <= 3'd0;
            end
        end
    end

    //    被两处驱动 -> "constantly driven from multiple places" (EX2000)。
    //    一个 reg 只能在一个 always 块里赋值。
    //    (rec_mem / rec_wp 的声明在上面"录音缓冲"小节, 这里不要重复声明)

    //  取回用的读指针 (单独一个 always, 只它自己用)
    reg [9:0]  rec_rdp;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rec_rdp <= 10'd0;
        else if (r_rx_done && frame_ok && f_cmd == 8'h62)
            rec_rdp <= rec_rdp + 10'd1;
        else if (r_rx_done && frame_ok && f_cmd == 8'h61)
            rec_rdp <= 10'd0;
    end

    reg [7:0] rec_byte_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rec_byte_r <= 8'd0;
        else        rec_byte_r <= rec_mem[rec_rdp[9:0]];
    end
    wire [7:0] rec_byte = rec_byte_r;

    integer    k;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < FRAME_N; k = k + 1) dstr[k] <= 8'd0;
        end else if (rx_done) begin
            //  新的进最高位, 老的往低位推 —— dstr[3] 永远是最新的
            dstr[3] <= rx_data;
            dstr[2] <= dstr[3];
            dstr[1] <= dstr[2];
            dstr[0] <= dstr[1];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) r_rx_done <= 1'b0;
        else        r_rx_done <= rx_done;
    end

    //  帧头 0xA5 在最老位置, 帧尾 0x5A 在最新位置

    //  帧里的字段 (回到 4 字节帧)
    wire [7:0]  f_rid = dstr[2];

    reg [6:0]  kmap_arr [0:9];
    reg [2:0]  kmap_kind[0:9];
    reg [3:0]  kmap_idx;
    reg        wr_timbre_ok;
    reg [2:0]  wr_timbre;
    reg        wr_irrise_ok;
    reg [16:0] wr_irrise;
    reg        wr_master_ok;
    reg [7:0]  wr_master;
    reg        wr_oct_ok;
    reg [1:0]  wr_oct;

    //    **值只有 4 位 (0~15)** —— 但音量要 0~255, 根本放不下。
    //    不想把帧扩到 6 字节 (上次那么做崩过)。
    //  解法: 用命令字节的**下 4 位**做"扩展寄存器号" —— 帧长不变, 多出 16 个 8 位参数。
    //    格式:  A5 5W XRID 5A      (W 的低 4 位 = 扩展号, 第3字节 = 完整 8 位值)
    reg [7:0]  wr_vel;      reg wr_vel_ok;  // XRID 0: 手势力度 80..240 (步进 40)
    reg [2:0]  wr_vib;      reg wr_vib_ok;  // XRID 1: 颤音深度 0..7
    reg        wr_chorus;   reg wr_chorus_ok;  // XRID 2: 合唱开关
    reg [7:0]  wr_fxamt;    reg wr_fxamt_ok;  // XRID 3: 效果器深度 0..255 (预留)

    reg        host_on;  // 0 = 硬件自主 (默认), 1 = 上位机接管

    reg [1:0]  ucmd_oct_dbg;
    reg [2:0]  irr_lvl_dbg;

    //    用**电平**而不是单拍脉冲 —— top.v 里要把它跨到 clk_aud_w 域使用,
    //    单拍脉冲跨时钟域会漏采 (两个时钟不同源), 那样锁就锁不上。
    assign cfg_timbre_en = host_on && wr_timbre_ok;
    assign cfg_host_on   = host_on;

    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : g_kmap
            assign cfg_keymap[gi*7 +: 7]      = kmap_arr[gi];
            assign cfg_kmap_kind[gi*3 +: 3]   = kmap_kind[gi];
        end
    endgenerate

    always @(*) begin
        cfg_timbre = wr_timbre;
        cfg_irrise = wr_irrise_ok ? wr_irrise : 17'd90;  // 默认 30us (最灵敏)
        cfg_master = (host_on && wr_master_ok) ? wr_master : 8'd220;
        cfg_octave = (host_on && wr_oct_ok)    ? wr_oct    : 2'd0;
        cfg_vel    = (host_on && wr_vel_ok)    ? wr_vel    : 8'd200;
        cfg_vib    = (host_on && wr_vib_ok)    ? wr_vib    : 3'd0;
        cfg_chorus = (host_on && wr_chorus_ok) ? wr_chorus : 1'b1;  // 合唱默认开
        cfg_fxamt  = (host_on && wr_fxamt_ok)  ? wr_fxamt  : 8'd128;
    end

    //  供 top.v 做"接管中"判断 (电平)
    assign cfg_vel_en    = host_on && wr_vel_ok;
    assign cfg_vib_en    = host_on && wr_vib_ok;
    assign cfg_chorus_en = host_on && wr_chorus_ok;

    reg [15:0] rd_val;
    always @(*) begin
        case (f_rid)
            8'd0: rd_val = {10'd0, st_voices};
            //    不能直接写 st_timbre: top.v 会拿 cfg_timbre 去驱动 wave_sel,
            //    而 st_timbre 又来自 wave_sel -> 又会成环。
            8'd1: rd_val = {13'd0, cfg_timbre_en ? wr_timbre : st_timbre};
            8'd8: rd_val = {13'd0, wr_timbre};  // 读上位写入的音色寄存器
            8'd9: rd_val = {15'd0, host_on};
            8'd10: rd_val = {15'd0, wr_timbre_ok};
            8'd11: rd_val = {15'd0, cfg_timbre_en};
            //  ---- 扩展 8 位参数的读回 ----
            8'd12: rd_val = {8'd0, cfg_master};  // 主音量 0..255
            8'd13: rd_val = {8'd0, cfg_vel};  // 力度 80..240
            8'd14: rd_val = {13'd0, cfg_vib};  // 颤音深度 0..7
            8'd15: rd_val = {15'd0, cfg_chorus};  // 合唱 0/1
            8'd20: rd_val = {15'd0, score_on};  // 板子上的曲谱模式开关
            8'd2: rd_val = {10'd0, st_env};
            8'd3: rd_val = {12'd0, st_test};
            8'd4: rd_val = {8'd0,  st_ges};
            //  返回**档位** (0..4) 而不是拍数 —— 和写入的形式对称, 上位机好理解
            //    被顶成 1500 -> 永远读回 2, **界面显示和实际不符**,
            //    现在: 没写过就报默认档 2; 写过就报实际写进去的那档。
            8'd27: rd_val = {6'd0, sc_keyact};  // 10 位 -> 补 6 个 0 = 16 位
            8'd28: rd_val = {9'd0, sc_keylat};
            8'd30: rd_val = lat_meas;
            8'd5: rd_val = wr_irrise_ok ? (
                              (wr_irrise <= 17'd90)   ? 16'd0 :
                              (wr_irrise <= 17'd450)  ? 16'd1 :
                              (wr_irrise <= 17'd1500) ? 16'd2 :
                              (wr_irrise <= 17'd6000) ? 16'd3 : 16'd4
                          ) : 16'd0;  // 默认档 = 0 (最灵敏)
            8'd6: rd_val = {8'd0,  cfg_master};
            8'd7: rd_val = {14'd0, cfg_octave};
            default: rd_val = 16'hFFFF;
        endcase
    end

    localparam RC_NONE = 4'd0, RC_V = 4'd1, RC_T = 4'd2, RC_E = 4'd3,
               RC_S = 4'd4, RC_G = 4'd5, RC_B = 4'd6, RC_SUM = 4'd7,
               RC_K = 4'd8, RC_BAD = 4'd9, RC_RD = 4'd10, RC_WR = 4'd11, RC_ALL = 4'd12,
               RC_MSC = 4'd13, RC_SST = 4'd14, RC_DL = 4'd15;
    reg [3:0]  resp_kind;
    reg [4:0]  resp_len;
    reg [4:0]  resp_idx;
    reg        resp_busy;
    reg [15:0] resp_val;
    //  曲谱下载应答的锁存字段 (收到 0x4E 帧时算好, 发的时候直接用)
    reg [3:0]  dl_sub_r;  // 子命令
    reg [7:0]  dl_p0_r;  // 参数高字节
    reg [7:0]  dl_p1_r;  // 参数低字节

    //  灵敏度档位查表: 档位 -> 上升沿消抖拍数 (@3MHz)
    //    0=30us  1=150us  2=500us(默认)  3=2ms  4=10ms
    reg [16:0] irr_tab;
    always @(*) begin
        case (f_val4)
            4'd0: irr_tab = 17'd90;
            4'd1: irr_tab = 17'd450;
            4'd2: irr_tab = 17'd1500;
            4'd3: irr_tab = 17'd6000;
            default: irr_tab = 17'd30000;
        endcase
    end

    function [7:0] hexc;
        input [3:0] v;
        begin
            if (v < 4'd10) hexc = 8'd48 + {4'd0, v};
            else           hexc = 8'd55 + {4'd0, v};
        end
    endfunction

    function [3:0] bhi;
        input [2:0] g;
        begin
            case (g)
                3'd0: bhi = st_b0[7:4];  3'd1: bhi = st_b1[7:4];
                3'd2: bhi = st_b2[7:4];  3'd3: bhi = st_b3[7:4];
                3'd4: bhi = st_b4[7:4];  3'd5: bhi = st_b5[7:4];
                3'd6: bhi = st_b6[7:4];  default: bhi = st_b7[7:4];
            endcase
        end
    endfunction
    function [3:0] blo;
        input [2:0] g;
        begin
            case (g)
                3'd0: blo = st_b0[3:0];  3'd1: blo = st_b1[3:0];
                3'd2: blo = st_b2[3:0];  3'd3: blo = st_b3[3:0];
                3'd4: blo = st_b4[3:0];  3'd5: blo = st_b5[3:0];
                3'd6: blo = st_b6[3:0];  default: blo = st_b7[3:0];
            endcase
        end
    endfunction

    reg [7:0]  rbyte;
    reg [2:0]  bgrp;
    reg [1:0]  bpos;

    always @(*) begin
        rbyte = 8'h00;
        case (resp_idx)
            5'd2, 5'd5, 5'd8, 5'd11, 5'd14, 5'd17, 5'd20, 5'd23: bpos = 2'd0;
            5'd3, 5'd6, 5'd9, 5'd12, 5'd15, 5'd18, 5'd21, 5'd24: bpos = 2'd1;
            default: bpos = 2'd2;
        endcase
        case (resp_idx)
            5'd2, 5'd3, 5'd4:    bgrp = 3'd0;
            5'd5, 5'd6, 5'd7:    bgrp = 3'd1;
            5'd8, 5'd9, 5'd10:   bgrp = 3'd2;
            5'd11, 5'd12, 5'd13: bgrp = 3'd3;
            5'd14, 5'd15, 5'd16: bgrp = 3'd4;
            5'd17, 5'd18, 5'd19: bgrp = 3'd5;
            5'd20, 5'd21, 5'd22: bgrp = 3'd6;
            default:             bgrp = 3'd7;
        endcase

        case (resp_kind)
            RC_V: case (resp_idx)
                5'd0: rbyte = 8'h56;   5'd1: rbyte = 8'h3D;
                5'd2: rbyte = hexc({2'b00, st_voices[5:4]});
                5'd3: rbyte = hexc(st_voices[3:0]);
                5'd4: rbyte = 8'h0D;   5'd5: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_T: case (resp_idx)
                5'd0: rbyte = 8'h54;   5'd1: rbyte = 8'h3D;
                5'd2: rbyte = hexc({1'b0, cfg_timbre_en ? wr_timbre : st_timbre});
                5'd3: rbyte = 8'h0D;   5'd4: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_E: case (resp_idx)
                5'd0: rbyte = 8'h45;   5'd1: rbyte = 8'h3D;
                5'd2: rbyte = hexc({2'b00, st_env[5:4]});
                5'd3: rbyte = hexc(st_env[3:0]);
                5'd4: rbyte = 8'h0D;   5'd5: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_S: case (resp_idx)
                5'd0: rbyte = 8'h53;   5'd1: rbyte = 8'h3D;
                5'd2: rbyte = hexc(st_test[3:0]);
                5'd3: rbyte = 8'h0D;   5'd4: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_G: case (resp_idx)
                5'd0: rbyte = 8'h47;   5'd1: rbyte = 8'h3D;
                5'd2: rbyte = hexc(st_ges[7:4]);
                5'd3: rbyte = hexc(st_ges[3:0]);
                5'd4: rbyte = 8'h0D;   5'd5: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_B: begin
                if (resp_idx == 5'd0)       rbyte = 8'h42;  // B
                else if (resp_idx == 5'd1)  rbyte = 8'h3D;  // =
                //  idx 2..22  = 组0..组6, 每组 3 位 (高/低/逗号)
                //  idx 23,24  = 组7 的高/低 (最后一组不带逗号)
                //  idx 25 = CR, 26 = LF  -> 共 27 字节
                else if (resp_idx >= 5'd2 && resp_idx <= 5'd22) begin
                    if (bpos == 2'd0)      rbyte = hexc(bhi(bgrp));
                    else if (bpos == 2'd1) rbyte = hexc(blo(bgrp));
                    else                   rbyte = 8'h2C;  // ,
                end
                else if (resp_idx == 5'd23) rbyte = hexc(bhi(3'd7));
                else if (resp_idx == 5'd24) rbyte = hexc(blo(3'd7));
                else if (resp_idx == 5'd25) rbyte = 8'h0D;
                else if (resp_idx == 5'd26) rbyte = 8'h0A;
                else                        rbyte = 8'h00;
            end
            RC_SUM: case (resp_idx)
                5'd0:  rbyte = 8'h56;   5'd1:  rbyte = 8'h3D;
                5'd2:  rbyte = hexc({2'b00, st_voices[5:4]});
                5'd3:  rbyte = hexc(st_voices[3:0]);
                5'd4:  rbyte = 8'h20;
                5'd5:  rbyte = 8'h54;   5'd6:  rbyte = 8'h3D;
                5'd7:  rbyte = hexc({1'b0, cfg_timbre});
                5'd8:  rbyte = 8'h20;
                5'd9:  rbyte = 8'h45;   5'd10: rbyte = 8'h3D;
                5'd11: rbyte = hexc({2'b00, st_env[5:4]});
                5'd12: rbyte = hexc(st_env[3:0]);
                5'd13: rbyte = 8'h20;
                5'd14: rbyte = 8'h53;   5'd15: rbyte = 8'h3D;
                5'd16: rbyte = hexc(st_test[3:0]);
                5'd17: rbyte = 8'h0D;   5'd18: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_K: case (resp_idx)
                5'd0:  rbyte = 8'h5A;  // 'Z'
                5'd1:  rbyte = 8'h39;  // '9'
                5'd2:  rbyte = 8'h0D;
                5'd3:  rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            //  读寄存器应答: "R=" + 4 位十六进制 + CRLF = 8 字节
            RC_RD: case (resp_idx)
                5'd0: rbyte = 8'h52;  // R
                5'd1: rbyte = 8'h3D;  // =
                5'd2: rbyte = hexc(resp_val[15:12]);
                5'd3: rbyte = hexc(resp_val[11:8]);
                5'd4: rbyte = hexc(resp_val[7:4]);
                5'd5: rbyte = hexc(resp_val[3:0]);
                5'd6: rbyte = 8'h0D;
                5'd7: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            //  写寄存器应答: "W=OK" + CRLF = 6 字节
            RC_WR: case (resp_idx)
                5'd0: rbyte = 8'h57;   5'd1: rbyte = 8'h3D;  // W=
                5'd2: rbyte = 8'h4F;   5'd3: rbyte = 8'h4B;  // OK
                5'd4: rbyte = 8'h0D;   5'd5: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            //    顺序: 音色 八度 灵敏度 音量 力度 颤音 合唱
            //    现在 4 个 (约 150ms) —— 界面不卡了。
            RC_ALL: case (resp_idx)
                5'd0:  rbyte = 8'h59;  // 'Y'
                5'd1:  rbyte = 8'h3D;  // '='
                5'd2:  rbyte = hexc({1'b0, cfg_timbre_en ? wr_timbre : st_timbre});
                5'd3:  rbyte = hexc({2'b00, st_oct});
                5'd4:  rbyte = 8'h30;  // 灵敏度档 (下一字节)
                5'd5:  rbyte = hexc(irr_lvl_dbg);
                5'd6:  rbyte = hexc(cfg_master[7:4]);
                5'd7:  rbyte = hexc(cfg_master[3:0]);
                5'd8:  rbyte = hexc(cfg_vel[7:4]);
                5'd9:  rbyte = hexc(cfg_vel[3:0]);
                5'd10: rbyte = 8'h30;
                5'd11: rbyte = hexc({1'b0, cfg_vib});
                5'd12: rbyte = 8'h30;
                5'd13: rbyte = hexc({3'b000, cfg_chorus});
                default: rbyte = 8'h00;
            endcase
            RC_SST: case (resp_idx)
                5'd0:  rbyte = 8'h53;  // 'S'
                5'd1:  rbyte = 8'h3D;  // '='
                5'd2:  rbyte = hexc({2'b00, sc_song});  // 曲目
                5'd3:  rbyte = hexc({2'b00, sc_state});  // 状态
                5'd4:  rbyte = hexc(sc_deg);  // 该弹音级
                5'd5:  rbyte = hexc(sc_pos[11:8]);  // 位置 高四位 (最大 2047, 实际只用到 0..7)
                5'd6:  rbyte = hexc(sc_pos[7:4]);
                5'd7:  rbyte = hexc(sc_pos[3:0]);
                5'd8:  rbyte = hexc(sc_total[11:8]);  // 总音数 高四位
                5'd9:  rbyte = hexc(sc_total[7:4]);
                5'd10: rbyte = hexc(sc_total[3:0]);
                5'd11: rbyte = hexc(sc_hit[7:4]);  // 弹对
                5'd12: rbyte = hexc(sc_hit[3:0]);
                5'd13: rbyte = hexc(sc_miss[7:4]);  // 弹错
                5'd14: rbyte = hexc(sc_miss[3:0]);
                5'd15: rbyte = 8'h0D;
                5'd16: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase

            //  ---- 曲谱下载 / 录音 应答 ----
            //  格式 D= 开头, 后面按子命令不同:
            //    D=4,OK,nnnn        块头确认 (预留)
            //    D=8,REC,cccc       录音条数
            //    D=9,xx             一条事件字节 (十六进制)
            //    D=0,OK             声明确认
            //    D=10,OK            清空确认
            RC_DL: case (resp_idx)
                5'd0:  rbyte = 8'h44;  // 'D'
                5'd1:  rbyte = 8'h3D;  // '='
                5'd2:  rbyte = hexc({4'd0, dl_sub_r});  // 子命令
                5'd3:  rbyte = 8'h2C;  // ','
                5'd4:  rbyte = hexc(dl_p0_r[7:4]);
                5'd5:  rbyte = hexc(dl_p0_r[3:0]);
                5'd6:  rbyte = hexc(dl_p1_r[7:4]);
                5'd7:  rbyte = hexc(dl_p1_r[3:0]);
                5'd8:  rbyte = 8'h0D;
                5'd9:  rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            //  曲谱命令应答: "M=OK" + CRLF
            RC_MSC: case (resp_idx)
                5'd0: rbyte = 8'h4D;   5'd1: rbyte = 8'h3D;  // M=
                5'd2: rbyte = 8'h4F;   5'd3: rbyte = 8'h4B;  // OK
                5'd4: rbyte = 8'h0D;   5'd5: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            RC_BAD: case (resp_idx)
                5'd0: rbyte = 8'h3F;   5'd1: rbyte = 8'h0D;
                5'd2: rbyte = 8'h0A;
                default: rbyte = 8'h00;
            endcase
            default: rbyte = 8'h00;
        endcase
    end

    assign tx_data = rbyte;

    localparam TS_IDLE = 2'd0, TS_LOAD = 2'd1, TS_BUSY = 2'd2, TS_WAIT = 2'd3;
    reg [1:0] ts;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            resp_kind     <= RC_NONE;
            resp_len      <= 5'd0;
            resp_idx      <= 5'd0;
            resp_busy     <= 1'b0;
            resp_val      <= 16'd0;
            ts            <= TS_IDLE;
            tx_valid      <= 1'b0;
            cfg_valid     <= 1'b0;
    //    (和 knh 同一个道理: 写在复位里会阻止 RAM 推断)
    kmap_idx  <= 4'd0;
    wr_timbre_ok  <= 1'b0;  wr_timbre <= 3'd0;
            wr_irrise_ok  <= 1'b0;  wr_irrise <= 17'd90;  // 默认 = 最灵敏档
            wr_master_ok  <= 1'b0;  wr_master <= 8'd220;
            wr_oct_ok     <= 1'b0;  wr_oct    <= 2'd0;
            wr_vel_ok     <= 1'b0;  wr_vel    <= 8'd200;
            wr_vib_ok     <= 1'b0;  wr_vib    <= 3'd0;
            wr_chorus_ok  <= 1'b0;  wr_chorus <= 1'b1;
            wr_fxamt_ok   <= 1'b0;  wr_fxamt  <= 8'd128;
            host_on       <= 1'b0;  // 默认: 硬件自主
            score_set     <= 1'b0;
            score_on      <= 1'b0;
            ucmd_oct_dbg  <= 2'd0;
            irr_lvl_dbg   <= 3'd2;  // 默认档位 2 (500us)
        end else begin
            cfg_valid <= 1'b0;
            score_set <= 1'b0;  // 这三个是单拍脉冲

            if (r_rx_done && frame_ok && !resp_busy) begin
                resp_idx  <= 5'd0;
                resp_busy <= 1'b1;

                case (f_cmd)
                    //  ---- 读寄存器 ----
                    8'h52: begin
                        resp_kind <= RC_RD;
                        resp_len  <= 5'd8;
                        resp_val  <= rd_val;
                    end
                    //  ---- 写寄存器 (4 字节帧版本) ----
                    //  A5 57 {RID[3:0],VAL[3:0]} 5A
                    8'h57: begin
                        resp_kind <= RC_WR;
                        resp_len  <= 5'd6;
                        cfg_valid <= host_on;
                        case (f_rid4)
                            4'd1: begin wr_timbre <= f_val4[2:0];         wr_timbre_ok <= 1'b1; end
                            4'd6: begin wr_master <= {4'd0, f_val4};      wr_master_ok <= 1'b1; end
                            4'd7: begin wr_oct    <= f_val4[1:0];         wr_oct_ok    <= 1'b1;
                                        ucmd_oct_dbg <= f_val4[1:0]; end
                            //    (它必须不受 host_on 门控, 放在这里就白改了)
                            default: ;  // 只读寄存器, 忽略
                        endcase
                    end
                    //  ---- '接管'命令: 开/关上位机控制 ----
                    //  A5 43 00 5A = 开接管 ; A5 43 01 5A = 关接管
                    8'h43: begin
                        host_on   <= dstr[2][0];
                        resp_kind <= RC_WR;  // 回 "W=OK"
                        resp_len  <= 5'd6;
                    end
                    8'h50: begin  // ---- 主音量 0..255 ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        wr_master <= dstr[2];  wr_master_ok <= 1'b1;
                        cfg_valid <= host_on;
                    end
                    8'h51: begin  // ---- 力度 (夹 80..240) ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        //  夹在 80..240: adsr 峰值能承受的范围,
                        //  超出会削顶或轻到听不见 (和手势那两档同一个范围)。
                        wr_vel <= (dstr[2] < 8'd80) ? 8'd80 :
                                  (dstr[2] > 8'd240) ? 8'd240 : dstr[2];
                        wr_vel_ok <= 1'b1;
                        cfg_valid <= host_on;
                    end
                    8'h55: begin  // ---- 颤音深度 (夹 0..7) ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        wr_vib <= (dstr[2] > 8'd7) ? 3'd7 : dstr[2][2:0];
                        wr_vib_ok <= 1'b1;
                        cfg_valid <= host_on;
                    end
                    8'h4E: begin  // ---- 选择要写的槽位 (II = 0..9) ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        kmap_idx  <= (dstr[2] > 8'd9) ? 4'd9 : dstr[2][3:0];
                    end
                    8'h48: begin  // ---- 写入当前槽的**类型** (KK = 0..5) ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        if (kmap_idx <= 4'd9 && dstr[2] <= 8'd5)
                            kmap_kind[kmap_idx[3:0]] <= dstr[2][2:0];
                    end
                    8'h4F: begin  // ---- 写入当前槽的音高 (VV = 0..127) ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        if (kmap_idx <= 4'd9)
                            kmap_arr[kmap_idx[3:0]] <= dstr[2][6:0];
                    end
                    //    固件里存一份默认表反而多一份要同步的数据。
                    8'h58: begin  // ---- 合唱开关 ----
                        resp_kind <= RC_WR;  resp_len <= 5'd6;
                        wr_chorus    <= dstr[2][0];
                        wr_chorus_ok <= 1'b1;
                        cfg_valid    <= host_on;
                    end
                    8'h4C: begin
                        resp_kind <= RC_MSC;  resp_len <= 5'd6;
                        score_on   <= dstr[2][0];
                        score_set  <= 1'b1;
                        if (dstr[2][1]) score_rst_tg  <= ~score_rst_tg;
                        if (dstr[2][2]) score_next_tg <= ~score_next_tg;
                        if (dstr[2][3]) score_play_tg <= ~score_play_tg;
                    end
                    8'h44: begin resp_kind <= RC_SST; resp_len <= 5'd17; end  // 'D' 曲谱状态 (17 字节: S= + 13 hex + CRLF)
                    8'h56: begin resp_kind <= RC_V;   resp_len <= 5'd6;  end
                    8'h54: begin resp_kind <= RC_T;   resp_len <= 5'd5;  end
                    8'h45: begin resp_kind <= RC_E;   resp_len <= 5'd6;  end
                    8'h53: begin resp_kind <= RC_S;   resp_len <= 5'd5;  end
                    8'h47: begin resp_kind <= RC_G;   resp_len <= 5'd6;  end
                    8'h42: begin resp_kind <= RC_B;   resp_len <= 5'd27; end
                    8'h3F: begin resp_kind <= RC_SUM; resp_len <= 5'd19; end
                    8'h59: begin resp_kind <= RC_ALL; resp_len <= 5'd14; end  // 'Y' 读全部参数 (14 字节: Y= + 12 hex)
                    8'h4B: begin resp_kind <= RC_K;   resp_len <= 5'd4;  end
                    8'h5B, 8'h5C, 8'h5D, 8'h5E, 8'h5F, 8'h60, 8'h61, 8'h62, 8'h64: begin
                        resp_kind <= RC_DL;
                        resp_len  <= 5'd10;
                        dl_sub_r  <= f_cmd[3:0];
                        dl_p0_r   <= 8'h00;
                        dl_p1_r   <= 8'h00;
                        if (f_cmd == 8'h5D) begin
                            dl_p0_r <= {4'd0, dl_wp[11:8]};  // 12 位长度的高 4 位
                            dl_p1_r <= dl_wp[7:0];
                        end else if (f_cmd == 8'h61) begin
                            dl_p1_r <= rec_count;
                        end else if (f_cmd == 8'h62) begin
                            dl_p1_r <= rec_byte;
                        end
                    end
                    default: begin resp_kind <= RC_BAD; resp_len <= 5'd3; end
                endcase

                if (f_cmd == 8'h57 && f_rid4 == 4'd5) begin
                    wr_irrise    <= irr_tab;
                    wr_irrise_ok <= 1'b1;
                    irr_lvl_dbg  <= f_val4[2:0];
                end
            end

            if (hb_pulse && !resp_busy) begin
                resp_kind <= RC_K;
                resp_len  <= 5'd4;
                resp_idx  <= 5'd0;
                resp_busy <= 1'b1;
            end

            case (ts)
                TS_IDLE: begin
                    tx_valid <= 1'b0;
                    if (resp_busy) ts <= TS_LOAD;
                end
                TS_LOAD: begin
                    tx_valid <= 1'b1;
                    ts       <= TS_BUSY;
                end
                TS_BUSY: begin
                    if (!tx_ready) begin
                        tx_valid <= 1'b0;
                        ts       <= TS_WAIT;
                    end
                end
                default: begin  // TS_WAIT
                    tx_valid <= 1'b0;
                    if (tx_ready) begin
                        if (resp_idx + 5'd1 >= resp_len) begin
                            resp_busy <= 1'b0;
                            resp_kind <= RC_NONE;
                            ts        <= TS_IDLE;
                        end else begin
                            resp_idx <= resp_idx + 5'd1;
                            ts       <= TS_LOAD;
                        end
                    end
                end
            endcase
        end
    end

    initial begin
        kmap_kind[0] = 3'd0; kmap_kind[1] = 3'd0; kmap_kind[2] = 3'd0;
        kmap_kind[3] = 3'd0; kmap_kind[4] = 3'd0; kmap_kind[5] = 3'd0;
        kmap_kind[6] = 3'd0; kmap_kind[7] = 3'd0; kmap_kind[8] = 3'd0;
        kmap_kind[9] = 3'd1;  // SW = 变调

        kmap_arr[0] = 7'd60;  // do   C4
        kmap_arr[1] = 7'd62;  // re   D4
        kmap_arr[2] = 7'd64;  // mi   E4
        kmap_arr[3] = 7'd65;  // fa   F4
        kmap_arr[4] = 7'd67;  // sol  G4
        kmap_arr[5] = 7'd69;  // la   A4
        kmap_arr[6] = 7'd71;  // si   B4
        kmap_arr[7] = 7'd72;  // i    C5
        kmap_arr[8] = 7'd74;  // ii   D5
        kmap_arr[9] = 7'd76;  // SW   E5
    end

endmodule
