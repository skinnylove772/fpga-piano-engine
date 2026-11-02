// osc_wave.v —— 相位 → 波形采样 (纯组合逻辑, 无查找表, 无 BSRAM)
module osc_wave(
    input  wire [23:0] phase,
    input  wire [2:0]  wave,
    output reg  signed [15:0] smp
);

    localparam [13:0] SINE_E = 14'd11433;  // 形状常数 (由 sim/sine_fit.py 求得)
    localparam [3:0]  SINE_S = 4'd4;  // 右移位数

    wire [7:0]  ph   = phase[23:16];
    wire [5:0]  p    = ph[6] ? (6'd63 - ph[5:0]) : ph[5:0];
    wire [11:0] p2   = p * p;  // 0..3969
    wire [13:0] num  = SINE_E - {2'b00, p2};  // 7464..11433, 恒为正
    wire [19:0] prod = p * num;
    wire [14:0] mag  = prod[18:4];  // 0..29407, 留 10% 满幅余量

    wire signed [15:0] sine_w = phase[23] ? -$signed({1'b0, mag})
                                          :  $signed({1'b0, mag});

    // 锯齿: 取相位高 16 位, 翻 MSB 变成以 0 为中心的有符号斜坡 (不变)
    wire signed [15:0] saw_w  = phase[23:8] ^ 16'h8000;

    wire [15:0]        tramp  = phase[22:7];
    wire signed [16:0] tri_a  = {1'b0, tramp} - 17'sd32768;  // 前半: -32768..+32767
    wire signed [16:0] tri_b  = 17'sd32767 - {1'b0, tramp};  // 后半: +32767..-32768
    wire signed [15:0] tri_w  = phase[23] ? tri_b[15:0] : tri_a[15:0];

    //       压到 +-20000 后 RMS 正好 20000, 与正弦(20713)基本齐平。
    wire signed [15:0] sqr_w  = phase[23] ? 16'sd20000 : -16'sd20000;

    // 脉冲: 高低电平满足 "高占空比*A + 低占空比*B = 0"(直流为零), 峰值取满幅。
    //   25%  : 0.25*A + 0.75*B = 0  =>  B = -A/3  => A=32767, B=-10922
    //   12.5%: 0.125*A + 0.875*B = 0 =>  B = -A/7  => A=32767, B=-4681
    wire signed [15:0] pu25_w = (phase[23:22] == 2'b00) ? 16'sd32767 : -16'sd10922;
    wire signed [15:0] pu12_w = (phase[23:21] == 3'b000) ? 16'sd32767 : -16'sd4681;

    wire signed [16:0] mix17 = {sine_w[15], sine_w} + {tri_w[15], tri_w};
    wire signed [16:0] mix34 = (mix17 >>> 1) + (mix17 >>> 2);  // x0.75
    wire signed [15:0] mix_w = mix34[15:0];

    // 整流正弦: |sine| 去直流(|sine| 的均值约 18539) -> 簧管感。
    //   (x>>>1)+(x>>>2)+x, 峰值 -18539*1.75 = -32444, 仍不溢出。
    //   (不能先放大 |sine| 再减: 3*29407 就超 16bit 了)
    wire signed [15:0] abs_s    = sine_w[15] ? -sine_w : sine_w;
    wire signed [15:0] reed_raw = abs_s - 16'sd18539;
    wire signed [15:0] reed_w   = (reed_raw >>> 1) + (reed_raw >>> 2) + reed_raw;

    always @* begin
        case (wave)
            3'd0:    smp = sine_w;
            3'd1:    smp = tri_w;
            3'd2:    smp = saw_w;
            3'd3:    smp = sqr_w;
            3'd4:    smp = pu25_w;
            3'd5:    smp = pu12_w;
            3'd6:    smp = mix_w;
            default: smp = reed_w;
        endcase
    end

endmodule
