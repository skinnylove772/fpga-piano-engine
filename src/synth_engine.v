// synth_engine.v —— 多声部并行实时合成引擎
module synth_engine #(
    parameter NVOICE = 32
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,  // 每采样帧一个脉冲

    //---- 演奏事件 (两者不能同拍同时有效; 每拍处理一个) ----
    input  wire        note_on,
    input  wire [6:0]  on_note,
    input  wire [7:0]  on_vel,
    input  wire [2:0]  on_wave,
    input  wire        note_off,
    input  wire [6:0]  off_note,
    input  wire        all_off,

    //---- 全局表情 / 音色参数 ----
    input  wire signed [15:0] pm,  // 颤音/弯音相位调制量
    input  wire [2:0]  glide_lvl,
    input  wire [15:0] atk_inc,
    input  wire [15:0] dec_inc,
    input  wire [15:0] rel_inc,
    input  wire [1:0]  sus_shift,
    input  wire [7:0]  master,  // 主音量

    output wire signed [15:0] audio,
    output wire [5:0]  active_cnt,  // 当前活跃声部数 (给 LED / 归一化用)
    //     延迟副本的相位随延迟量一直变, 屏幕上会同时留下一大片不同相位的
    //     椭圆, 余辉一叠就糊成一团, 根本看不出图形。
    //   李萨如图要求 X 和 Y 是**两个频率稳定、相位关系固定**的信号。
    //   单个声部的输出正好满足: 按一个键时 X 与 Y 重合(一条干净的直线),
    //   按两个不同音高时就画出真正的 8 字 / 花瓣。
    output wire signed [15:0] voice0_out,  // 0 号声部原始输出(带包络)
    output wire signed [15:0] voice1_out,  // 1 号声部原始输出(带包络)
    output wire signed [15:0] voice0_smp,
    output wire signed [15:0] voice1_smp,
    output wire [7:0] voice0_ph,  // 0 号声部相位高 8 位
    output wire [7:0] voice1_ph,  // 1 号声部相位高 8 位
    //   每声部 16 位 {note[6:0], busy, env[7:0]}, 第 0 声部在最低 16 位。
    //   灯带那边按 LED 序号取出对应声部, 决定颜色(音名)和亮度(包络)。
    output wire [16*NVOICE-1:0] voice_led_v
);

    wire [23:0] step_sel;
    wire [2:0]  mip_sel;
    note_step u_note_step(
        .note (on_note),
        .step (step_sel),
        .mip  (mip_sel)
    );

    reg  [NVOICE-1:0] trig_vec;  // 每声部的触发脉冲
    reg  [NVOICE-1:0] gate_vec;  // 每声部的门(1=按住)
    wire [NVOICE-1:0] busy_vec;
    wire [7*NVOICE-1:0] note_out_v;
    wire signed [16*NVOICE-1:0] voice_out_v;
    wire signed [16*NVOICE-1:0] voice_smp_v;  // 各声部包络前的波形
    wire        [8*NVOICE-1:0]  voice_ph_v;  // 各声部相位高 8 位
    wire        [16*NVOICE-1:0] voice_led_v_i;  // 各声部打包给灯带的数据

    // busy_eff 额外把"本拍刚分配出去"的声部也算忙:
    // 声部的 busy 要等包络状态机走一拍才置位, 若不加这一项,
    // 连续两拍各来一个 note_on 会重复占用同一个声部。
    wire [NVOICE-1:0] busy_eff = busy_vec | trig_vec;
    wire [NVOICE-1:0] free_vec = ~busy_eff;

    // 空闲声部优先编码(取编号最小的空闲声部)
    reg  [4:0] free_idx;
    reg        have_free;
    integer    k;
    always @* begin
        free_idx  = 5'd0;
        have_free = 1'b0;
        for (k = NVOICE-1; k >= 0; k = k - 1) begin
            if (free_vec[k]) begin
                free_idx  = k[4:0];
                have_free = 1'b1;
            end
        end
    end

    reg [4:0] steal_ptr;  // 无空闲时的抢占指针(轮转, 保证公平)
    // NVOICE 是 2 的幂(16/32), 用掩码让指针始终落在合法范围内
    wire [4:0] steal_idx = steal_ptr & (NVOICE - 1);

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            trig_vec  <= {NVOICE{1'b0}};
            gate_vec  <= {NVOICE{1'b0}};
            steal_ptr <= 5'd0;
        end else begin
            trig_vec <= {NVOICE{1'b0}};  // 触发是单拍脉冲

            //---- 松键: 释放所有同音声部 ----
            if (note_off) begin
                for (j = 0; j < NVOICE; j = j + 1) begin
                    if (busy_vec[j] && (note_out_v[7*j +: 7] == off_note))
                        gate_vec[j] <= 1'b0;
                end
            end

            //---- 按键(放在后面, 同拍重触发时以新音为准) ----
            if (note_on) begin
                if (have_free) begin
                    trig_vec[free_idx] <= 1'b1;
                    gate_vec[free_idx] <= 1'b1;
                end else begin
                    trig_vec[steal_idx] <= 1'b1;
                    gate_vec[steal_idx] <= 1'b1;
                    steal_ptr <= steal_ptr + 1'b1;
                end
            end

            //    (只清 gate, 不动 trig 和音高 -- 声部会正常走完释放包络)
            if (all_off) gate_vec <= {NVOICE{1'b0}};
        end
    end

    wire legato_w   = |(gate_vec & busy_vec);
    wire glide_go_w = legato_w && (glide_lvl != 3'd0);

    reg  [23:0]        step_prev;  // 上一次按键的音高步长
    reg  signed [23:0] gofs;  // 滑音偏置 (旧步长 - 新步长), 衰减到 0
    reg                glide_run;  // 1 = 偏置还没衰减完
    reg                glide_go_r;  // 打一拍, 给本拍被触发的声部采样

    reg  [5:0] gcnt;  // 时间档分频计数器 (必须按 tick 自增!)
    wire [5:0] gmask = (glide_lvl <= 3'd1) ? 6'd0  :
                       (glide_lvl == 3'd2) ? 6'd1  :
                       (glide_lvl == 3'd3) ? 6'd3  :
                       (glide_lvl == 3'd4) ? 6'd7  :
                       (glide_lvl == 3'd5) ? 6'd15 :
                       (glide_lvl == 3'd6) ? 6'd31 : 6'd63;
    wire gadv = (gcnt & gmask) == 6'd0;  // 该不该在这一拍走一步

    // 指数步长 (K 固定 10), 正数时兜底为 1
    wire signed [23:0] gsh  = gofs >>> 10;
    wire signed [23:0] gst  = (gofs[23] || (gsh != 24'sd0)) ? gsh : 24'sd1;
    wire signed [23:0] gnxt = gofs - gst;
    // 已经很接近 0 了 -> 直接落地收尾
    //    不会体现在音高上, 留着只会白等时间。
    wire               gdone = gofs[23] ? (gofs >= -24'sd256) : (gofs <= 24'sd256);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            step_prev  <= 24'd0;
            gofs       <= 24'sd0;
            glide_run  <= 1'b0;
            glide_go_r <= 1'b0;
            gcnt       <= 6'd0;
        end else begin
            //   tick 每 32 拍出现且相位固定, 若 gcnt 跑在 3MHz 上,
            //   `tick && (gcnt & mask)==0` 会因相位锁死而**恒真或恒假** ——
            //   恒假时滑音一步都不走。
            if (tick) gcnt <= gcnt + 6'd1;
            if (note_on) begin
                glide_go_r <= glide_go_w;
                //   上一个音如果还在滑, 它的实际音高是 (step_prev + gofs)。
                //   新音的偏置 = 实际音高 - 新音高 = step_prev + gofs - step_sel。
                //   少了这个 +gofs, 连奏快的时候音高会**往回跳一下**再把新音滑过去,
                //   听起来就是"怪怪的"。
                gofs       <= glide_go_w ? (step_prev - step_sel + gofs) : 24'sd0;
                step_prev  <= step_sel;
                glide_run  <= glide_go_w;
                gcnt       <= 6'd0;
            end else if (!glide_run) begin
                glide_go_r <= 1'b0;
            end else if (tick && gadv) begin
                if (gdone) begin
                    gofs      <= 24'sd0;
                    glide_run <= 1'b0;
                end else begin
                    gofs <= gnxt;
                end
            end
        end
    end

    // 两版相位偏置, 全局算一次, 广播给全部声部 (声部里用 glide_r 二选一)
    wire signed [23:0] pm24_g = {{8{pm[15]}}, pm};  // 只有颤音
    wire signed [23:0] gofs_q = {gofs[23:8], 8'h00};
    wire signed [23:0] pmg_g  = pm24_g + gofs_q;  // 颤音 + 滑音

    reg  [4:0] rd_k;  // 当前读第几个声部
    reg  [4:0] rd_k_d1;  // 延迟一拍, 配合 ROM 的读延迟
    reg  signed [16*NVOICE-1:0] smp_w;  // 本帧正在写入的采样
    reg  signed [16*NVOICE-1:0] smp_rd;  // 上一帧读好的采样(供各声部使用)
    wire [15*NVOICE-1:0] wt_addr_v;  // 32 个声部各自的波表地址
    wire [14:0] wt_addr_sel = wt_addr_v[15*rd_k +: 15];
    wire [15:0] rom_dout;

    wave_rom u_wave_rom(
        .clk  (clk),
        .addr (wt_addr_sel),
        .dout (rom_dout)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_k    <= 5'd0;
            rd_k_d1 <= 5'd0;
            smp_w   <= {(16*NVOICE){1'b0}};
            smp_rd  <= {(16*NVOICE){1'b0}};
        end else begin
            if (tick) begin
                rd_k    <= 5'd0;
                rd_k_d1 <= 5'd31;  // 接住上一帧最后一次读的下标
            end else begin
                rd_k    <= rd_k + 5'd1;
                rd_k_d1 <= rd_k;
            end

            // ROM 数据在地址发出后的下一拍到达, 用它填第 rd_k_d1 个槽
            smp_w[16*rd_k_d1 +: 16] <= rom_dout;

            // 一帧里 rd_k==1 对应"帧的第 2 拍": 此时上一帧的 32 个槽已全部写完
            if (rd_k == 5'd1)
                smp_rd <= smp_w;
        end
    end

    genvar gi;
    generate
    for (gi = 0; gi < NVOICE; gi = gi + 1) begin : g_voice
        voice u_voice(
            .clk       (clk),
            .rst_n     (rst_n),
            .tick      (tick),
            .trigger   (trig_vec[gi]),
            .note_in   (on_note),
            .vel_in    (on_vel),
            .wave_in   (on_wave),
            .mip_in    (mip_sel),
            .step_in   (step_sel),
            .gate      (gate_vec[gi]),
            .atk_inc   (atk_inc),
            .dec_inc   (dec_inc),
            .rel_inc   (rel_inc),
            .sus_shift (sus_shift),
            .pm        (pm),
            .pmg       (pmg_g),
            .glide_go  (glide_go_r),
            .glide_run (glide_run),
            .glide_clr (note_on),
            .wt_addr   (wt_addr_v[15*gi +: 15]),
            .smp_in    (smp_rd[16*gi +: 16]),
            .out       (voice_out_v[16*gi +: 16]),
            .smp_out   (voice_smp_v[16*gi +: 16]),
            .ph_out    (voice_ph_v[8*gi +: 8]),
            .led_out   (voice_led_v_i[16*gi +: 16]),
            .busy      (busy_vec[gi]),
            .note_out  (note_out_v[7*gi +: 7])
        );
    end
    endgenerate

    reg [5:0] act_c;
    integer   q;
    always @* begin
        act_c = 6'd0;
        for (q = 0; q < NVOICE; q = q + 1)
            act_c = act_c + {5'd0, busy_vec[q]};
    end
    //   直接连到 9MHz 视频域的屏幕模块属于**未同步的跨时钟域**,
    //   组合毛刺会被采到 => 屏幕上的 VOICES 偶尔闪出错误数字。
    //   打一拍后它变成一个干净的寄存器输出, 跨域只可能"晚一拍", 不会出错。
    //   (音频本身不受影响, 但这属于该修的时序规范问题)
    reg [5:0] active_cnt_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) active_cnt_r <= 6'd0;
        else        active_cnt_r <= act_c;
    end
    assign active_cnt = active_cnt_r;

    reg [5:0] nrm_g;
    always @* begin
        if      (act_c <= 6'd1 ) nrm_g = 6'd32;  // 32/1
        else if (act_c <= 6'd2 ) nrm_g = 6'd16;  // 32/2
        else if (act_c <= 6'd3 ) nrm_g = 6'd11;  // 32/3
        else if (act_c <= 6'd4 ) nrm_g = 6'd8;  // 32/4
        else if (act_c <= 6'd5 ) nrm_g = 6'd6;
        else if (act_c <= 6'd6 ) nrm_g = 6'd5;
        else if (act_c <= 6'd7 ) nrm_g = 6'd5;
        else if (act_c <= 6'd8 ) nrm_g = 6'd4;
        else if (act_c <= 6'd10) nrm_g = 6'd3;
        else if (act_c <= 6'd16) nrm_g = 6'd2;
        else                     nrm_g = 6'd1;  // 32/32
    end

    reg signed [21:0] sum_acc;
    wire signed [15:0] mix_sel = voice_out_v[16*rd_k +: 16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            sum_acc <= 22'sd0;
        else if (rd_k == 5'd0) sum_acc <= $signed(mix_sel);
        else                   sum_acc <= sum_acc + $signed(mix_sel);
    end

    reg  tick_d1, tick_d2;
    reg  signed [21:0] sum_r;
    reg  [5:0]  nrm_g_r;  // 与 sum_r 同拍锁存, 保证两者对应同一时刻
    reg  signed [15:0] audio_r;

    // 归一化: sum x g / 32。sum(22位) x g(6位) 的乘法全是移位相加, 不占 DSP。
    //       sum_r 实际范围 = +-NVOICE*32767 = +-1048544   (21 位)
    //       再乘 g(最大 32)  = +-33553408                 (26 位, 2^25=33554432 刚好装下)
    //     取 26 位后, nrm_p>>>5 得到 21 位, 赋给 22 位的 norm 就不再截断。
    //     (EX3791) —— 值虽然装得下, 但位宽声明不一致会留下一条没必要的警告。
    wire signed [25:0] nrm_p  = sum_r * $signed({1'b0, nrm_g_r});
    wire signed [21:0] norm   = nrm_p >>> 5;
    wire signed [30:0] vol    = norm * $signed({1'b0, master});
    wire signed [22:0] vol_s  = vol >>> 8;

    wire        [22:0] av      = vol_s[22] ? (~vol_s + 23'd1) : vol_s;
    wire        [22:0] lim_mag = (av <= 23'd29491) ? av
                               : (av <= 23'd36044) ? (23'd29491 + ((av - 23'd29491) >>> 1))
                               :                     23'd32767;
    wire signed [15:0] limited = vol_s[22] ? -$signed({1'b0, lim_mag[14:0]})
                                           :  $signed({1'b0, lim_mag[14:0]});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_d1 <= 1'b0;
            tick_d2 <= 1'b0;
            sum_r   <= 22'sd0;
            nrm_g_r <= 6'd32;
            audio_r <= 16'sd0;
        end else begin
            tick_d1 <= tick;
            tick_d2 <= tick_d1;
            if (tick_d1) begin
                sum_r    <= sum_acc;
                nrm_g_r  <= nrm_g;
            end
            if (tick_d2) audio_r <= limited;
        end
    end

    assign audio = audio_r;

    // 0 号 / 1 号声部的原始输出, 给李萨如图形当 X / Y。
    // 频率关系最干净, 画出来的图形最稳定。
    assign voice0_out = voice_out_v[15:0];
    assign voice1_out = voice_out_v[31:16];
    assign voice0_smp = voice_smp_v[15:0];
    assign voice1_smp = voice_smp_v[31:16];
    assign voice0_ph  = voice_ph_v[7:0];
    assign voice1_ph  = voice_ph_v[15:8];
    assign voice_led_v = voice_led_v_i;

endmodule
