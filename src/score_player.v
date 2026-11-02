// score_player.v —— 曲谱播放器 + 指法判定  (v2: 等弹模式)
module score_player #(
    //  超时: 一个音最多等多久。8 秒 @93.75kHz = 750000 个 tick。
    parameter [23:0] TIMEOUT_TICKS = 24'd750000,
    //    **这个音再也判不了"对"** —— 必须等 8 秒超时。
    //    现在: 弹错后 0.3 秒内改弹对了, 仍然算对。
    //      0.3 秒是一个很好的平衡点: 比人手改弹的反应快
    //      (不会让"弹错了还能慵惰地改"), 但又足够
    //      容纳一次手指滑过去的误触。
    parameter [23:0] REMISS_TICKS = 24'd28125
)(
    input  wire        clk,  // 音频时钟 (3MHz 域)
    input  wire        rst_n,
    input  wire        atick,  // 每输出一个采样一个脉冲 (fs)

    //---- 控制 ----
    input  wire        btn_start,  // 单拍脉冲: 播放 / 暂停
    input  wire        btn_reset,  // 单拍脉冲: 回到开头
    input  wire        btn_nextsong,
    input  wire        next_dir,  // 单拍脉冲: 下一首
    input  wire [1:0]  song_sel,
    input  wire        enable,  // 0 = 整个模块旁路

    input  wire [9:0]  keys,
    input  wire        dl_valid,
    input  wire [10:0] dl_len,  // 下载曲谱的字节数
    output wire [10:0] dl_addr,  // 读 RAM 地址 (3MHz 域)
    input  wire [7:0]  dl_rdata,  // 下载曲谱的数据 (3MHz 域同步读)

    //---- 输出 ----
    output reg  [1:0]  song_idx,
    output reg         playing,
    output reg  [3:0]  want_deg,  // 该弹的音级 0=休止 1..7 8..14=高音
    output reg  [9:0]  note_pos,
    output reg  [9:0]  note_total,
    output reg  [7:0]  hit_cnt,
    output reg  [7:0]  miss_cnt,
    output reg         beat_tog,
    //    beat_tog 只是"换了一个音就翻一下", 那不是节拍, 是音符边界。
    //    beat_on 才是**每拍一次**的信号: 一拍 = 四分音符 = 4*T16 = 500ms (120BPM),
    //    在每拍的**前 1/4** 为高。灯带拿它让"该弹"那组灯亮一下、其余时间变暗,
    //    于是既能看出"弹哪个音", 又能看出"什么时候该弹"。
    output wire        beat_on,
    output reg         hit_pulse,  // 弹对: 单拍脉冲
    output reg         miss_pulse,  // 弹错: 单拍脉冲
    output reg         song_done,
    output wire [1:0]  sc_state,  // 0=停 1=播 2=弹完

    input  wire        auto_play,
    //    (top.v 里键盘用的就是这两个量, 一定要一致)
    input  wire [6:0]  oct_off,
    input  wire [6:0]  tr_off,
    output reg         sp_on,
    output reg         sp_off,
    output reg  [6:0]  sp_note
);

    localparam [1:0] N_SONG = 2'd3;

    reg [9:0] song_start;
    reg [9:0] song_len;

    always @(*) begin
        //    其余曲子**全部靠上位机下载** (use_dl=1), 不占 LUT。
        //    数值必须和 src/score_rom.v 头部目录一致:
        //      [0] TWINKLE start=0  notes=44 (含 2 个乐句休止)
        //      [1] ODE     start=48 notes=30   (欢乐颂)
        //      [2] TIGER   start=80 notes=32   (两只老虎)
        //    再在这里加对应的 start/len 分支 (每个音约 1 个 LUT)。
        case (song_idx)
            2'd1:    begin song_start = 10'd48; song_len = 10'd30; end  // 欢乐颂
            2'd2:    begin song_start = 10'd80; song_len = 10'd32; end  // 两只老虎
            default: begin song_start = 10'd0;  song_len = 10'd44; end  // 小星星
        endcase
    end

    wire [9:0] rom_addr = song_start + note_pos;

    //      而下载的 RAM 是**同步读**(一拍延迟)。
    //      两者延迟不一样, 直接 mux 会错一拍。
    //      这里把 ROM 也接成 ScoreRom 模块的组合输出, 并用
    //      **同一个地址**取, 让两边对齐。
    wire [7:0] rom_note_int;
    score_rom u_rom (
        .addr (rom_addr),
        .note (rom_note_int)
    );

    //  ---- 曲谱来源选择 (下载的优先) ----
    wire        use_dl    = dl_valid;
    //  下载曲谱从地址 0 开始, 不需要 song_start 偏移
    assign      dl_addr   = {1'b0, note_pos};
    wire [7:0]  rom_note  = use_dl ? dl_rdata : rom_note_int;

    wire [3:0] cur_deg = rom_note[7:4];
    wire [3:0] cur_dur = rom_note[3:0];

    //  ---- 一个十六分音符 = 多少 tick ----
    //   120 BPM: 一拍 0.5s, 十六分 0.125s; 0.125 x 93750 = 11718.75 -> 11719
    localparam [23:0] T16 = 24'd11719;

    localparam [15:0] BEAT_TOT = {2'b00, T16[13:0]} << 2;  // 4*T16 = 46876 (16 位够)
    localparam [15:0] BEAT_HI  = {2'b00, T16[13:0]};  // 每拍前 1/4 为高

    reg [15:0] bt_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          bt_cnt <= 16'd0;
        else if (atick) begin
            if (!playing || !enable)              bt_cnt <= 16'd0;
            else if (bt_cnt >= BEAT_TOT - 16'd1)  bt_cnt <= 16'd0;
            else                                  bt_cnt <= bt_cnt + 16'd1;
        end
    end
    assign beat_on = (bt_cnt < BEAT_HI);

    reg [23:0] dur_tot;
    always @(*) begin
        case (cur_dur)
            4'd1 : dur_tot = T16;
            4'd2 : dur_tot = T16 << 1;
            4'd4 : dur_tot = T16 << 2;
            4'd8 : dur_tot = T16 << 3;
            default: dur_tot = T16 << 2;
        endcase
    end

    wire [24:0] dur_x15 = {1'b0, dur_tot} + {2'b00, dur_tot[23:1]};  //  dur * 1.5
    wire [23:0] dur_eff = (song_idx == 2'd3) ? dur_x15[24:1] : dur_tot;  //  猪猪侠 *0.75

    function [4:0] deg_semi;
        input [3:0] d;
        begin
            case (d)
                4'd1 : deg_semi = 5'd0;
                4'd2 : deg_semi = 5'd2;
                4'd3 : deg_semi = 5'd4;
                4'd4 : deg_semi = 5'd5;
                4'd5 : deg_semi = 5'd7;
                4'd6 : deg_semi = 5'd9;
                4'd7 : deg_semi = 5'd11;
                4'd8 : deg_semi = 5'd12;
                4'd9 : deg_semi = 5'd14;
                4'd10: deg_semi = 5'd16;
                4'd11: deg_semi = 5'd17;
                4'd12: deg_semi = 5'd19;
                4'd13: deg_semi = 5'd21;
                4'd14: deg_semi = 5'd23;
                default: deg_semi = 5'd0;
            endcase
        end
    endfunction

    wire [8:0] cur_note_raw = {2'b00, 7'd60} + {4'b0000, deg_semi(cur_deg)}
                            + {2'b00, oct_off} + {2'b00, tr_off};
    wire [6:0] cur_note_num = (cur_note_raw > 9'd127) ? 7'd127 : cur_note_raw[6:0];
    wire       last_note    = (note_pos + 10'd1 >= (use_dl ? dl_len[9:0] : song_len));

    reg [3:0] play_deg;
    always @(*) begin
        play_deg = 4'd0;
        if      (keys[0]) play_deg = 4'd1;
        else if (keys[1]) play_deg = 4'd2;
        else if (keys[2]) play_deg = 4'd3;
        else if (keys[3]) play_deg = 4'd4;
        else if (keys[4]) play_deg = 4'd5;
        else if (keys[5]) play_deg = 4'd6;
        else if (keys[6]) play_deg = 4'd7;
        else if (keys[7]) play_deg = 4'd8;
        else if (keys[8]) play_deg = 4'd9;
        else if (keys[9]) play_deg = 4'd10;
    end

    wire [3:0] want_low = (cur_deg >= 4'd15) ? 4'd0
                        : (cur_deg >= 4'd11) ? (cur_deg - 4'd7)
                        : cur_deg;

    wire hit_now  = (want_low != 4'd0) && (play_deg == want_low);
    wire miss_now = (want_low != 4'd0) && (play_deg != 4'd0) && (play_deg != want_low);

    reg  hit_prev;
    wire hit_edge = hit_now && !hit_prev;

    //  休止符: 等固定时长就过 (没有"该弹的音")
    wire is_rest = (want_low == 4'd0);

    reg [23:0] wait_cnt;
    wire       timed_out = (wait_cnt >= TIMEOUT_TICKS);

    reg        miss_armed;
    reg [23:0] miss_wait;

    reg [23:0] dcount;  //  当前音已经走了多少 tick
    reg        gate_on;  //  1 = 当前音还在发声 (尚未发 sp_off)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            song_idx   <= 2'd0;
            playing    <= 1'b0;
            want_deg   <= 4'd0;
            note_pos   <= 10'd0;
            note_total <= 10'd42;
            hit_cnt    <= 8'd0;
            miss_cnt   <= 8'd0;
            beat_tog   <= 1'b0;
            hit_pulse  <= 1'b0;
            miss_pulse <= 1'b0;
            sp_on      <= 1'b0;
            sp_off     <= 1'b0;
            song_done  <= 1'b0;
            miss_armed <= 1'b0;
            hit_prev   <= 1'b0;
            miss_wait  <= 24'd0;
            wait_cnt   <= 24'd0;
            miss_wait  <= 24'd0;
            dcount     <= 24'd0;
            gate_on    <= 1'b0;
            sp_on      <= 1'b0;
            sp_off     <= 1'b0;
            sp_note    <= 7'd60;
        end else begin
            hit_pulse  <= 1'b0;
            miss_pulse <= 1'b0;
            //   上一版把它们写进了复位分支, 于是置 1 以后一直是 1,
            //   引擎会每拍都收到一次 note_on。
            sp_on      <= 1'b0;
            sp_off     <= 1'b0;
            //      hit_edge 只在 atick 那一拍被采样, 若每时钟都更新,
            //      1 拍的脉冲会在下一个 atick 到来前就消失了 (等于永远判不到)。
            if (atick) hit_prev <= hit_now;
            note_total <= use_dl ? dl_len[9:0] : song_len;

            //  换曲
            //    不再自己 +1/-1, 避免和 rotary_menu 的计数器走散。
            //    btn_nextsong 仍作为"重新载入当前选曲"的触发 (回到开头)。
            if (btn_nextsong || (song_idx != song_sel)) begin
                song_idx <= song_sel;
                note_pos   <= 10'd0;
                wait_cnt   <= 24'd0;
                playing    <= 1'b0;
                hit_cnt    <= 8'd0;
                miss_cnt   <= 8'd0;
                song_done  <= 1'b0;
                miss_armed <= 1'b0;
                miss_wait  <= 24'd0;
                dcount     <= 24'd0;
                gate_on    <= 1'b0;
                if (gate_on) sp_off <= 1'b1;  //  切歌时把正在响的音松开
            end

            if (btn_reset) begin
                note_pos   <= 10'd0;
                wait_cnt   <= 24'd0;
                playing    <= 1'b0;
                hit_cnt    <= 8'd0;
                miss_cnt   <= 8'd0;
                song_done  <= 1'b0;
                miss_armed <= 1'b0;
                miss_wait  <= 24'd0;
                dcount     <= 24'd0;
                if (gate_on) sp_off <= 1'b1;
                gate_on    <= 1'b0;
            end

            if (btn_start) begin
                if (song_done) begin
                    note_pos  <= 10'd0;
                    wait_cnt  <= 24'd0;
                    hit_cnt   <= 8'd0;
                    miss_cnt  <= 8'd0;
                    song_done <= 1'b0;
                    playing   <= 1'b1;
                end else begin
                    playing  <= ~playing;
                    wait_cnt <= 24'd0;  // 重新开始等
                    dcount   <= 24'd0;
                    hit_prev <= 1'b0;
                    if (gate_on) sp_off <= 1'b1;
                    gate_on  <= 1'b0;
                end
            end

            if (playing && enable && atick) begin
              if (auto_play) begin
                //  流程: 进入一个音 -> dcount=0
                //          dcount 从 0 数到 dur_tot
                //          1/4 拍尾巴处发 sp_off (做出断音, 免得连着的同音粘在一起)
                //          dur_tot 到 -> 走下一个音
                if (dcount == 24'd0 && !gate_on) begin
                    //  ---- 进入新音: 发声 (休止符不发) ----
                    if (!is_rest) begin
                        sp_on   <= 1'b1;
                        sp_note <= cur_note_num;
                        gate_on <= 1'b1;
                    end
                    dcount   <= 24'd1;
                    beat_tog <= ~beat_tog;
                end else begin
                    dcount <= dcount + 24'd1;
                    //  ---- 尾巴: 按**时长百分之七十五**松开 ----
                    //     于是**长音和短音的尾音间隙一样长** ——
                    //     听起来每个音都是"一样的音 + 一样的缝"。
                    //     乐句末尾的二分音符就会自带"呼吸感"。
                    if (gate_on && ((dcount + (dur_eff >> 3)) >= dur_eff)) begin
                        sp_off  <= 1'b1;
                        gate_on <= 1'b0;
                    end
                    //  ---- 时长到: 走下一个 ----
                    if ((dcount + 24'd1) >= dur_eff) begin
                        dcount  <= 24'd0;
                        gate_on <= 1'b0;
                        if (gate_on) sp_off <= 1'b1;  // 保底: 没来得及松开的话
                        if (last_note) begin
                            playing   <= 1'b0;
                            song_done <= 1'b1;
                            note_pos  <= 10'd0;
                        end else begin
                            note_pos <= note_pos + 10'd1;
                        end
                    end
                end
              end else begin
                if (is_rest) begin
                    //  休止符: 等 0.5 秒就过 (46875 tick @93.75kHz)
                    if (wait_cnt >= 24'd46875) begin
                        wait_cnt <= 24'd0;
                        if (note_pos + 10'd1 >= (use_dl ? dl_len[9:0] : song_len)) begin
                            playing   <= 1'b0;
                            song_done <= 1'b1;
                            note_pos  <= 10'd0;
                        end else begin
                            note_pos <= note_pos + 10'd1;
                        end
                    end else begin
                        wait_cnt <= wait_cnt + 24'd1;
                    end
                end else if (hit_edge && !miss_armed) begin
                    hit_pulse  <= 1'b1;
                    hit_cnt    <= (hit_cnt == 8'd255) ? 8'd255 : (hit_cnt + 8'd1);
                    wait_cnt   <= 24'd0;
                    miss_armed <= 1'b0;
                    miss_wait  <= 24'd0;
                    beat_tog   <= ~beat_tog;
                    if (note_pos + 10'd1 >= (use_dl ? dl_len[9:0] : song_len)) begin
                        playing   <= 1'b0;
                        song_done <= 1'b1;
                        note_pos  <= 10'd0;
                    end else begin
                        note_pos <= note_pos + 10'd1;
                    end
                end else if (timed_out) begin
                    //  等太久了 -> 跳过, 算漏掉
                    miss_pulse <= 1'b1;
                    miss_cnt   <= (miss_cnt == 8'd255) ? 8'd255 : (miss_cnt + 8'd1);
                    wait_cnt   <= 24'd0;
                    miss_armed <= 1'b0;
                    miss_wait  <= 24'd0;
                    beat_tog   <= ~beat_tog;
                    if (note_pos + 10'd1 >= (use_dl ? dl_len[9:0] : song_len)) begin
                        playing   <= 1'b0;
                        song_done <= 1'b1;
                        note_pos  <= 10'd0;
                    end else begin
                        note_pos <= note_pos + 10'd1;
                    end
                end else begin
                    wait_cnt <= wait_cnt + 24'd1;
                end
              end
            end

            if (playing && enable && atick && !auto_play) begin
                if (miss_now && !miss_armed) begin
                    //  首次弹错这个音 -> 红闪 + 计数, 并开始"可改期"计时
                    miss_pulse <= 1'b1;
                    miss_cnt   <= (miss_cnt == 8'd255) ? 8'd255 : (miss_cnt + 8'd1);
                    miss_armed <= 1'b1;
                    miss_wait  <= 24'd0;
                end else if (miss_armed) begin
                    //    解锁后就能重新判"对" (不用等 8 秒超时)
                    if (miss_wait >= REMISS_TICKS) begin
                        miss_armed <= 1'b0;
                        miss_wait  <= 24'd0;
                    end else begin
                        miss_wait <= miss_wait + 24'd1;
                    end
                end
            end

            want_deg   <= cur_deg;
        end
    end

    assign sc_state = song_done ? 2'd2 : (playing ? 2'd1 : 2'd0);

endmodule
