// chorus.v —— 硬件合唱效果器 (拓展要求 2 里的"数字音频效果器")
module chorus(
    input  wire        clk,  // 3MHz 音频时钟
    input  wire        rst_n,
    input  wire        tick,  // 每采样一个脉冲 (93750Hz)
    input  wire        enable,
    input  wire [2:0]  depth,
    input  wire        type,
    input  wire signed [15:0] din,
    output reg  signed [15:0] dout
);

    localparam [11:0] BASE   = 12'd797;
    //    0.5Hz 太慢: 一个持续音的 250ms 里 LFO 只走 45°,
    //    置一直卡在 comb 的抵消点上, 于是合唱听起来是"变薄变小"而不是"加厚"。
    //    2Hz @46875Hz = 2^24*2/46875 = 716
    localparam [23:0] LFO_STEP = 24'd716;

    // ---- 延迟线: 1024 x 16 = 16384 bit -> 1 块 BSRAM ----
    //    BASE(797) + swing(<=190) = 987 < 1024 ✓
    reg signed [15:0] mem [0:1023];
    reg [9:0] wr;  // 写指针 (10 位 = 模 1024, 和缓存深度一致)
    //    这里 mix14 用的是显式位拼接符号延伸, 本身没错,
    //    但加上 signed 可以让后续任何 >>> 都安全。
    reg signed [15:0] wet_d;  // 同步读出的湿信号 (BSRAM 读延迟 1 拍)

    // ---- 摆动 LFO: 0.5Hz 三角波, 折成 0..127 ----
    reg [23:0] lfo_ph;
    wire [6:0] lfo_t = lfo_ph[23] ? ~lfo_ph[22:16] : lfo_ph[22:16];

    wire [9:0] sw_base = type ? {2'b00, lfo_t, 1'b0} : {3'b000, lfo_t};
    wire [9:0] sw1 = {2'b00, sw_base[9:2]};  // /4
    wire [9:0] sw2 = {1'b0,  sw_base[9:1]};  // /2
    wire [9:0] sw4 = {sw_base[8:0], 1'b0};  // x2
    wire [9:0] sw5 = sw_base + {sw_base[8:0], 1'b0};  // x3
    wire [9:0] swing = (depth == 3'd1) ? sw1
                     : (depth == 3'd2) ? sw2
                     : (depth == 3'd3) ? sw_base
                     : (depth == 3'd4) ? sw4
                     :                   sw5;

    wire [9:0] B2S = type ? 10'd900 : BASE[9:0];
    wire [9:0] delay = B2S + swing;
    wire [9:0] rd    = wr - delay;  // 10 位自然回绕 = 模 1024

    wire signed [16:0] dry34 = {{1{din[15]}}, din};  // x1.0 干声
    //  湿 = 0.375 (= 1/2 - 1/8)
    wire signed [16:0] wet14 = {{2{wet_d[15]}}, wet_d[15:1]}
                             - {{4{wet_d[15]}}, wet_d[15:3]};
    wire signed [16:0] w1 = wet14 >>> 3;
    wire signed [16:0] w2 = wet14 >>> 2;
    wire signed [16:0] w3 = wet14 >>> 1;
    wire signed [16:0] w4 = wet14 - (wet14 >>> 2);
    wire signed [16:0] wet_sc = (depth == 3'd1) ? w1
                             : (depth == 3'd2) ? w2
                             : (depth == 3'd3) ? w3
                             : (depth == 3'd4) ? w4
                             :                   wet14;
    wire signed [17:0] mixv  = {{1{dry34[16]}}, dry34} + {{1{wet_sc[16]}}, wet_sc};
    wire signed [17:0] mx_abs = mixv[17] ? -mixv : mixv;
    wire signed [17:0] mx_lim = (mx_abs < 18'sd32767) ? mx_abs : 18'sd32767;
    wire signed [15:0] SAT    = mixv[17] ? -mx_lim[15:0] : mx_lim[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr      <= 10'd0;
            lfo_ph  <= 24'd0;
            wet_d   <= 16'sd0;
            dout    <= 16'sd0;
        end else begin
            // BSRAM: 一个口写, 一个口同步读
            mem[wr] <= din;
            wet_d   <= mem[rd];

            if (tick) begin
                wr     <= wr + 10'd1;
                lfo_ph <= lfo_ph + LFO_STEP;
            end

            if (!enable)
                dout <= din;
            else
                dout <= SAT;  //  软限幅后的干+湿
        end

    end
endmodule
