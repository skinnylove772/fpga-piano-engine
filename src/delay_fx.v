// delay_fx.v —— 回声/延迟效果器（2096~4096 样本环形缓冲）
module delay_fx #(
    //    为了给重做的混响 (4 梳状 + 2 全通, 多要 2~3 块 BSRAM) 腾地方。
    //    4096 -> 2048 样本, 延迟 43.68ms -> 21.84ms, **释放 2 块 BSRAM**。
    //    真琴延迟 0.1~900ms (Yamaha REV7), 钢琴主律常用 100~300ms。
    //    AW=12 -> 4096 样本 / 46875Hz = **87.4ms** ← 落在"短回声,听得出独立重复"区间。
    parameter AW = 12,  // 4096 样本 = 87.4ms @46875Hz
    parameter DW = 16
)(
    input  wire                 clk,  // 3MHz 音频域
    input  wire                 rst_n,
    input  wire                 tick,  // 每采样一个脉冲 (93750Hz)
    input  wire                 enable,
    input  wire [2:0]           depth,
    input  wire                 type,
    input  wire signed [DW-1:0] din,
    output reg  signed [DW-1:0] dout
);

    //  ---- 延迟缓冲: 4096 x 16 = 65536 bit -> 4 块 BSRAM ----
    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [AW-1:0] wp;  // 写指针
    //    Verilog 规则: `>>>` 对**无符号**操作数**等于** `>>`。
    //        -7874 >>> 2  应该是 -1969, 实际算出 +14456
    //    (下面 L79 写着"不能写 >>" —— 想法对了, 但声明漏了字。)
    reg signed [DW-1:0] rd_d;  // 同步读出的"旧样本"（1 拍延迟）
    reg signed [DW-1:0] din_d;  // 输入打一拍，和 rd_d 对齐

    wire [AW-1:0] ra_short = wp - 12'd2048;  // AW=12, 2048 需 12 位(原写 11 位被截成 0)
    wire [AW-1:0] ra_long  = wp + 1'b1;
    wire [AW-1:0] ra       = type ? ra_long : ra_short;

    //  ---- 反馈写入值: (din>>>1) + (rd>>>1) ----
    //     写成 >> 就变成逻辑右移，负半周会被当成大正数 —— 出爆音。
    //    旧写法 w = din/2 + fb*rd, 稳态增益 = (1/2)/(1-fb):
    //      fb=1/4 -> 0.67x, fb=1/2 -> 1.00x, **fb=3/4 -> 2.00x 溢出**
    //      -> 16 位回绕 -> 正负翻转 -> **爆音** (只有最深档触发)
    //    新写法 w = din*(1-g) + g*rd -> 稳态增益恒为 1.0, 任何档位都不溢出。
    wire signed [DW-1:0] in_s = (depth == 3'd1) ? (din_d - (din_d >>> 4))  // 15/16
                              : (depth == 3'd2) ? (din_d - (din_d >>> 3))  //  7/8
                              : (depth == 3'd3) ? (din_d - (din_d >>> 2))  //  3/4
                              : (depth == 3'd4) ? (din_d >>> 1)  //  1/2
                              :                   (din_d >>> 2);  //  1/4
    wire signed [DW-1:0] fb0 = rd_d >>> 4;  // 1/16
    wire signed [DW-1:0] fb1 = rd_d >>> 3;  // 1/8
    wire signed [DW-1:0] fb2 = rd_d >>> 2;  // 1/4
    wire signed [DW-1:0] fb3 = rd_d >>> 1;  // 1/2
    wire signed [DW-1:0] fb4 = rd_d - (rd_d >>> 2);  // 3/4
    wire signed [DW-1:0] fb_sel = (depth == 3'd1) ? fb0
                               : (depth == 3'd2) ? fb1
                               : (depth == 3'd3) ? fb2
                               : (depth == 3'd4) ? fb3
                               :                   fb4;
    wire signed [DW-1:0] quarter_rd = fb_sel;
    wire signed [DW-1:0] wsum    = in_s + quarter_rd;

    wire signed [16:0] dry34 = {{1{din_d[15]}}, din_d};  // x1.0 干声
    wire signed [16:0] wet14  = {{2{rd_d[15]}}, rd_d[15:1]};
    //    1/8, 1/4, 1/2, 3/4, 1   (depth = 1..5)
    wire signed [16:0] w1 = wet14 >>> 3;
    wire signed [16:0] w2 = wet14 >>> 2;
    wire signed [16:0] w3 = wet14 >>> 1;
    wire signed [16:0] w4 = wet14 - (wet14 >>> 2);
    wire signed [16:0] wet_sc = (depth == 3'd1) ? w1
                             : (depth == 3'd2) ? w2
                             : (depth == 3'd3) ? w3
                             : (depth == 3'd4) ? w4
                             :                   wet14;
    wire signed [17:0] mix17 = {{1{dry34[16]}}, dry34} + {{1{wet_sc[16]}}, wet_sc};

    wire signed [17:0] mx_abs = mix17[17] ? -mix17 : mix17;
    wire signed [17:0] mx_lim = (mx_abs < 18'sd32767) ? mx_abs : 18'sd32767;
    wire signed [15:0] SAT   = mix17[17] ? -mx_lim[15:0] : mx_lim[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp    <= {AW{1'b0}};
            rd_d  <= {DW{1'b0}};
            din_d <= {DW{1'b0}};
            dout  <= {DW{1'b0}};
        end else begin
            // ---- BSRAM: 一个口写, 一个口同步读 ----
            mem[wp] <= wsum;
            rd_d    <= mem[ra];
            din_d   <= din;

            if (tick)
                wp <= wp + 1'b1;  // 12 位自然回绕 = 模 4096

            // ---- 输出: 关掉时完全直通（一个采样都不改）----
            if (!enable)
                //    旁路必须原样直通。
                dout <= din;
            else
                dout <= SAT;
        end
    end

endmodule
