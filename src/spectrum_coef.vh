// spectrum_coef.vh —— 8 段频谱的带通系数 (由 sim/gen_spectrum_coef.py 生成, 请勿手改)
//
// ★★★ 这个文件只应该被 `include 进 spectrum.v, **不要**加进 .gprj!
//   加进工程会被当成独立源文件编译, 里面的 localparam 就落在**文件作用域**,
//   Verilog-2001 不允许根作用域声明, Gowin 会对每一行报一条
//   EX3209 Root scope declaration is not allowed in Verilog 2001 mode
//   (实测 24 条)。而且系数进不了模块作用域, 滤波器拿到的是错值 -> 屏幕乱码。
//   (2026-10-10 踩过, 记在这里。)
//   include 保护: 万一被重复包含, 只生效一次。
`ifndef SPECTRUM_COEF_VH
`define SPECTRUM_COEF_VH

//   fs = 93750.0 Hz,  极点半径 r = 0.90,  系数定点 Q12
//   每段: a1 = 2r·cos(w),  a2 = -r²,  w = 2*pi*f/fs
//   中心频率(Hz): 125, 250, 500, 1000, 2000, 4000, 8000, 16000
//
//   ★★ 系数必须 **14 位**有符号: 低频段的 a1 = 2r·cos(w) 接近 2r = 1.8,
//      乘上 2^12 之后是 7373, 超过 13 位有符号的上限 4095。
//      一开始按 13 位写, 会被静默截断 -> 低频段滤波器系数全错。
//   ★★ 另有一张**输入归一化表** CN: 各段中心增益本来差 16.1 dB
//      (125Hz 增益 1.65, 16kHz 增益 10.52), 不归一化柱子高矮没法互相比较。
//      纠正系数乘在**输入**上, 所以各段状态变量保持干净。

    localparam signed [13:0] COEF_A1_0 = 14'sd7373;
    localparam signed [13:0] COEF_A1_1 = 14'sd7372;
    localparam signed [13:0] COEF_A1_2 = 14'sd7369;
    localparam signed [13:0] COEF_A1_3 = 14'sd7356;
    localparam signed [13:0] COEF_A1_4 = 14'sd7307;
    localparam signed [13:0] COEF_A1_5 = 14'sd7109;
    localparam signed [13:0] COEF_A1_6 = 14'sd6338;
    localparam signed [13:0] COEF_A1_7 = 14'sd3525;

    localparam signed [13:0] COEF_A2_0 = -14'sd3318;
    localparam signed [13:0] COEF_A2_1 = -14'sd3318;
    localparam signed [13:0] COEF_A2_2 = -14'sd3318;
    localparam signed [13:0] COEF_A2_3 = -14'sd3318;
    localparam signed [13:0] COEF_A2_4 = -14'sd3318;
    localparam signed [13:0] COEF_A2_5 = -14'sd3318;
    localparam signed [13:0] COEF_A2_6 = -14'sd3318;
    localparam signed [13:0] COEF_A2_7 = -14'sd3318;

    localparam signed [17:0] COEF_CN_0 = 18'sd104182;
    localparam signed [17:0] COEF_CN_1 = 18'sd53984;
    localparam signed [17:0] COEF_CN_2 = 18'sd30485;
    localparam signed [17:0] COEF_CN_3 = 18'sd20812;
    localparam signed [17:0] COEF_CN_4 = 18'sd17580;
    localparam signed [17:0] COEF_CN_5 = 18'sd16675;
    localparam signed [17:0] COEF_CN_6 = 18'sd16441;
    localparam signed [17:0] COEF_CN_7 = 18'sd16384;

`endif  // SPECTRUM_COEF_VH
