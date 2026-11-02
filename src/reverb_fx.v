// reverb_fx.v —— FPGA 内实现的小房间混响 v4（串联 2 梳状 + 2 全通）
module reverb_fx #(
    parameter DW = 16
) (
    input  wire                 clk,  // 3MHz 音频域
    input  wire                 rst_n,
    input  wire                 tick,  // 每采样一个脉冲 (46875Hz)
    input  wire                 enable,
    input  wire [2:0]           depth,
    input  wire                 type,
    input  wire signed [DW-1:0] din,
    output reg  signed [DW-1:0] dout
);

    localparam [9:0] D0 = 10'd1013;  // 1013 / 46875 = 21.61ms  梳状1
    localparam [9:0] D1 = 10'd877;  //  877 / 46875 = 18.71ms  梳状2
    localparam [8:0] E0 = 9'd469;  //  469 / 46875 = 10.01ms  全通1
    localparam [8:0] E1 = 9'd337;  //  337 / 46875 =  7.19ms  全通2

    reg signed [DW-1:0] ca [0:1023];
    reg signed [DW-1:0] cb [0:1023];
    reg signed [DW-1:0] pa [0:511];
    reg signed [DW-1:0] pb [0:511];

    reg [9:0] wp;  // 梳状写指针 (10 位回绕 = 模 1024)
    reg [8:0] pp;  // 全通写指针 ( 9 位回绕 = 模 512)

    reg signed [DW-1:0] ra, rb;  // 两条梳状的输出(延迟后的值)
    reg signed [DW-1:0] qa, qb;  // 两条全通的输出
    reg signed [DW-1:0] din_d;

    wire [9:0] a0 = wp - D0;
    wire [9:0] a1 = wp - D1;
    wire [8:0] b0 = pp - E0;
    wire [8:0] b1 = pp - E1;

    wire signed [DW-1:0] omg_a = type ? (din_d >>> 3)
                                      : ((din_d >>> 3) + (din_d >>> 4));
    wire signed [DW-1:0] c1_in = omg_a >>> 1;  // x(1-g)/2
    wire signed [DW-1:0] g_a = type ? (ra - (ra >>> 3))
                                    : (ra - (ra >>> 3) - (ra >>> 4));
    wire signed [DW-1:0] g_b = type ? (rb - (rb >>> 3))
                                    : (rb - (rb >>> 3) - (rb >>> 4));
    wire signed [DW-1:0] wa    = c1_in + g_a;

    wire signed [DW-1:0] h1     = ra >>> 1;  // x/2
    wire signed [DW-1:0] qa_h   = qa >>> 1;
    wire signed [DW-1:0] ap1_wr = h1 + qa_h;

    wire signed [16:0] ap1_y17 = {{1{qa[15]}}, qa} - {{1{h1[15]}}, h1};
    wire signed [15:0] ap1_y   = (ap1_y17 > 17'sd32767)  ? 16'sd32767 :
                                 (ap1_y17 < -17'sd32768) ? 16'sd32768 :
                                                           ap1_y17[15:0];

    wire signed [DW-1:0] omg_b = type ? (ap1_y >>> 3)
                                      : ((ap1_y >>> 3) + (ap1_y >>> 4));
    wire signed [DW-1:0] c2_in = omg_b >>> 1;
    wire signed [DW-1:0] wb    = c2_in + g_b;

    wire signed [DW-1:0] h2     = rb >>> 1;
    wire signed [DW-1:0] qb_h   = qb >>> 1;
    wire signed [DW-1:0] ap2_wr = h2 + qb_h;

    wire signed [16:0] ap2_y17 = {{1{qb[15]}}, qb} - {{1{h2[15]}}, h2};
    wire signed [15:0] wet     = (ap2_y17 > 17'sd32767)  ? 16'sd32767 :
                                 (ap2_y17 < -17'sd32768) ? 16'sd32768 :
                                                           ap2_y17[15:0];

    wire signed [16:0] dry17 = {{1{din[15]}}, din};  // x1.0 干声
    //  混响量: 规范化后湿声基量 0.25 din, 干声 1.0 din (见上);
    //  最深档 1.25x 湿声约 0.31 din, 峰值由软限幅兜住。
    wire signed [16:0] wet17  = {{1{wet[15]}}, wet};  // x1
    wire signed [16:0] w1 = wet17 >>> 2;  // 1/4
    wire signed [16:0] w2 = wet17 >>> 1;  // 1/2
    wire signed [16:0] w3 = wet17 - (wet17 >>> 2);  // 3/4
    wire signed [16:0] w5 = wet17 + (wet17 >>> 2);  // 1.25
    wire signed [16:0] ws = (depth == 3'd1) ? w1
                         : (depth == 3'd2) ? w2
                         : (depth == 3'd3) ? w3
                         : (depth == 3'd4) ? wet17
                         :                   w5;
    wire signed [17:0] mixv  = {{1{dry17[16]}}, dry17} + {{1{ws[16]}}, ws};

    wire signed [17:0] mx_abs = mixv[17] ? -mixv : mixv;
    wire signed [17:0] mx_lim = (mx_abs < 18'sd32767) ? mx_abs : 18'sd32767;
    wire signed [15:0] SAT    = mixv[17] ? -mx_lim[15:0] : mx_lim[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp    <= 10'd0;
            pp    <= 9'd0;
            ra    <= {DW{1'b0}};
            rb    <= {DW{1'b0}};
            qa    <= {DW{1'b0}};
            qb    <= {DW{1'b0}};
            din_d <= {DW{1'b0}};
            dout  <= {DW{1'b0}};
        end else begin
            // 四条 BSRAM: 每拍写, 同步读
            ca[wp] <= wa;
            cb[wp] <= wb;
            pa[pp] <= ap1_wr;
            pb[pp] <= ap2_wr;

            ra <= ca[a0];
            rb <= cb[a1];
            qa <= pa[b0];
            qb <= pb[b1];

            din_d <= din;

            if (tick) begin
                wp <= wp + 10'd1;  // 10 位自然回绕 = 模 1024
                pp <= pp + 9'd1;  //  9 位自然回绕 = 模 512
            end

            // 关掉时完全直通
            if (!enable)
                dout <= din;
            else
                dout <= SAT;
        end
    end

endmodule
