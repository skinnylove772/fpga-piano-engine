// lfo_vib.v —— 颤音用的低频振荡器 (LFO) + 深度控制
module lfo_vib(
    input  wire        clk,  // 1.5MHz 音频时钟
    input  wire        rst_n,
    input  wire        tick,  // 每采样一个脉冲 (46875Hz)
    input  wire [2:0]  depth,  // 深度 0..7, 0=关闭
    input  wire        oct_hi,  // 当前是否在高八度 (pm 相应加倍)
    output reg  signed [15:0] pm  // -> synth_engine 的 pm
);

    // 5Hz, 采样率 93750Hz, 24 位相位:
    //   每采样相位步进 = 2^24 * 5 / 93750 = 894
    //   它是"每采样"的相位步进, 采样率翻倍后同样步进的真实频率也翻倍 ——
    //   不改的话颤音会变成 10Hz (从"揉弦"变成"抖"), 听感完全不同。
    localparam [23:0] LFO_STEP = 24'd894;

    reg [23:0] ph;

    // 三角波: 取相位高 8 位里的低 7 位当斜坡, 用最高位决定方向。
    //   但当成**有符号数**读出来其实是锯齿波:
    //       前半 0,1,...,127,-128,...,-1   冲到 +127 后突然跳到 -128
    //       后半 -1,-2,...,-128,127,...,0  又跳一次
    //   音高变成"斜坡上去啪一下掉回来", 听感是抖动而不是揉弦,
    //   正确做法: 先用 7 位折成 0..127 的三角, 再减去中点 64 居中。
    wire [6:0] t7 = ph[23] ? ~ph[22:16] : ph[22:16];  // 0..127..0 的三角
    wire signed [7:0] tri8 = {1'b0, t7} - 8'sd64;  // 居中到 -64..+63

    // 再按 depth 衰减 (变长右移, 不用乘法器)
    wire signed [15:0] amp = {{8{tri8[7]}}, tri8} <<< 5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= 24'd0;
            pm <= 16'sd0;
        end else if (tick) begin
            ph <= ph + LFO_STEP;
            if (depth == 3'd0) begin
                pm <= 16'sd0;  // 关闭: 一点抖动都不加
            end else begin
                // 衰减到 depth 档: depth=7 时不衰减, 越小的档衰减越多
                pm <= oct_hi ? (amp >>> (3'd7 - depth)) <<< 1
                             : (amp >>> (3'd7 - depth));
            end
        end
    end

endmodule
