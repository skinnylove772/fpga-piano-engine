// voice.v —— 单个完整振荡器声部 (独立相位累加器 + 频率调控 + 包络控制)
module voice(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,  // 采样帧脉冲

    // 触发(带参数) / 门
    input  wire        trigger,
    input  wire [6:0]  note_in,
    input  wire [7:0]  vel_in,
    input  wire [2:0]  wave_in,
    input  wire [2:0]  mip_in,  // 本音符的 mip 级别 (来自 note_step 的八度)
    input  wire [23:0] step_in,
    input  wire        gate,

    // 全局包络参数
    input  wire [15:0] atk_inc,
    input  wire [15:0] dec_inc,
    input  wire [15:0] rel_inc,
    input  wire [1:0]  sus_shift,
    input  wire signed [15:0] pm,
    //   pm  和 pmg 是**同一路相位偏置的两个版本**, 由本声部自己二选一:
    //     pm24  : 只有颤音 (pm 符号扩展到 24 位)
    //     pmg   : 颤音 + 滑音偏置 (synth_engine 全局算一次, 广播过来)
    //   glide_r = 1 表示"本声部正在滑音" —— 只有**换音那一刻被触发**的声部才会
    //   代价: 每声部一个 24 位 2:1 多路器 = 24 LUT, 32 声部 = 768 LUT = 384 CLS。
    input  wire signed [23:0] pmg,
    input  wire        glide_go,  // 1 = 触发时进入滑音
    input  wire        glide_run,  // 1 = 全局滑音偏置还没衰减完
    //    全局只有一个 gofs。如果上一个音还在滑的过程中又按了新音, gofs 会被
    //    覆盖成新的一对音程 —— 而旧声部的 glide_r 还是 1, 它会被新的 gofs
    //    拖着跑, 两个声音互相拉扯, 听起来就是"怪怪的"。
    //    只有**这一拍被触发**的声部还能把它置 1。
    input  wire        glide_clr,

    // 波表接口
    output wire [14:0] wt_addr,  // 组合地址: {音色, mip, 相位索引}
    input  wire signed [15:0] smp_in,  // 本声部这一帧的波表采样 (由 synth_engine 分时读好后送来)

    output reg  signed [15:0] out,  // 声部输出 (波形 x 包络)
    output wire signed [15:0] smp_out,
    output wire [7:0]  ph_out,
    //   {note[6:0], busy, env[7:0]}  —— 灯带靠这三个量决定颜色和亮度:
    //       note -> 色相(哪一个音)     busy -> 没发声时全灭
    //       env  -> 亮度(弹得多响、包络在哪个阶段)
    output wire [15:0] led_out,
    output wire        busy,  // 1=正在发声
    output wire [6:0]  note_out  // 当前音符号(用于松键匹配)
);

    reg [23:0] phase;
    reg [23:0] step_r;
    reg [6:0]  note_r;
    reg [2:0]  wave_r;
    reg [2:0]  mip_r;
    reg [7:0]  vel_r;

    // 颤音/弯音的相位调制量: pm 是 16 位有符号数, 符号扩展到 24 位
    wire signed [23:0] pm24 = {{8{pm[15]}}, pm};

    //   优先级: 本声部被触发 > 有新按键(停滑) > 全局滑完了(停滑)
    //     而本声部的 trigger 是**下一拍**才来, 两者不会撞在同一拍;
    //     排前面是为了万一撞拍时以"本声部要滑"为准。
    reg glide_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                       glide_r <= 1'b0;
        else if (trigger)                 glide_r <= glide_go;  // 新音: 决定要不要滑
        else if (glide_clr || !glide_run) glide_r <= 1'b0;  // 旧声部: 立刻停滑
    end

    // 相位偏置二选一 (颤音 或 颤音+滑音)
    //    滑音偏置在 synth_engine 里已经量化到 256 个单位 (低 8 位恒为 0),
    //    于是 24 位多路器 -> 16 位, 省 8 LUT/声部 = **256 LUT**。
    //    代价: 滑音偏置的量化步长 256 个相位单位 = 1.43Hz,
    //    只影响滑音最后 0.5% 的路程, 听不出来。
    wire signed [23:0] pm_use = { (glide_r ? pmg[23:8] : pm24[23:8]), pm24[7:0] };

    //   每声部一个 32 位加法器 = 32 个 ALU/进位链, 32 个声部就吃掉 1024 个 ALU。
    //   = 46875/2^24 = 0.0028 Hz, 音高表四舍五入后的误差约 0.24 音分,
    //   而人耳能分辨的最小音高差约 5 音分 —— 完全听不出(已用 golden_model 逐音验证)。
    wire [23:0] phase_nxt = phase + step_r + pm_use;

    //---- 波表地址: {音色, mip, 相位索引} ----
    //   相位索引取相位最高 9 位 = 一周期 512 点, 与波表点数一致
    wire [14:0] wt_addr_c = {wave_r, mip_r, phase_nxt[23:15]};

    wire [15:0] env;
    wire        env_busy;

    adsr_env u_env(
        .clk       (clk),
        .rst_n     (rst_n),
        .tick      (tick),
        .trigger   (trigger),
        .gate      (gate),
        .vel       (vel_in),
        .atk_inc   (atk_inc),
        .dec_inc   (dec_inc),
        .rel_inc   (rel_inc),
        .sus_shift (sus_shift),
        .env       (env),
        .busy      (env_busy)
    );

    wire signed [24:0] vprod = smp_in * $signed({1'b0, env[15:8]});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase  <= 24'd0;
            step_r <= 24'd0;
            note_r <= 7'd0;
            wave_r <= 3'd0;
            mip_r  <= 3'd0;
            vel_r  <= 8'd0;
            out    <= 16'sd0;
        end else if (trigger) begin
            // 新音符: 相位归零, 参数锁存, 输出清零(包络从 0 起, 不会爆音)
            phase  <= 24'd0;
            step_r <= step_in;
            note_r <= note_in;
            wave_r <= wave_in;
            mip_r  <= mip_in;
            vel_r  <= vel_in;
            out    <= 16'sd0;
        end else if (tick) begin
            phase <= phase_nxt;
            out   <= vprod[23:8];
        end
    end

    assign wt_addr  = wt_addr_c;
    assign ph_out   = env_busy ? phase[23:16] : 8'd0;
    // 灯带用的打包数据。注意 note 用 busy 门控 —— 空闲声部的 note_r 还留着
    // 上一次按过的音, 不门控的话"松手后灯还亮着不灭"。
    assign led_out  = { (env_busy ? note_r : 7'd0), env_busy, env[15:8] };
    assign smp_out  = env_busy ? smp_in : 16'sd0;
    assign busy     = env_busy;
    assign note_out = note_r;

endmodule
