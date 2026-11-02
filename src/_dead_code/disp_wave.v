// disp_wave.v —— 屏幕示波器用的显示波形发生器 (由 sim/gen_osd.py 自动生成, 请勿手改)
module disp_wave(
    input  wire [7:0]  phase,
    input  wire [2:0]  wave,
    output reg  signed [7:0] smp
);
    localparam [255:0] QSIN = 256'h7F7F7E7E7C7B797775726F6C6864605C57534E49433E38322C26201A130D0600;
    wire [4:0]  q    = phase[6] ? (5'd31 - phase[5:1]) : phase[5:1];
    wire [7:0]  qmag = QSIN[{q, 3'b000} +: 8];
    wire signed [7:0] sine_w = phase[7] ? -$signed(qmag) : $signed(qmag);
    wire [7:0]        tramp8 = {phase[6:0], 1'b0};
    wire signed [8:0] tri_a8 = {1'b0, tramp8} - 9'sd128;
    wire signed [8:0] tri_b8 = 9'sd127 - {1'b0, tramp8};
    wire signed [7:0] tri_w  = phase[7] ? tri_b8[7:0] : tri_a8[7:0];
    wire signed [7:0] saw_w  = phase ^ 8'h80;
    wire signed [7:0] sqr_w  = phase[7] ? 8'sd78 : -8'sd78;
    wire signed [7:0] pu25_w = (phase[7:6] == 2'b00) ? 8'sd127 : -8'sd42;
    wire signed [7:0] pu12_w = (phase[7:5] == 3'b000) ? 8'sd127 : -8'sd18;
    wire signed [8:0] mix9  = {sine_w[7], sine_w} + {tri_w[7], tri_w};
    wire signed [8:0] mix34 = (mix9 >>> 1) + (mix9 >>> 2);
    wire signed [7:0] mix_w = mix34[7:0];
    wire signed [7:0] abs_s    = sine_w[7] ? -sine_w : sine_w;
    wire signed [7:0] reed_raw = abs_s - 8'sd72;
    wire signed [7:0] reed_w   = (reed_raw >>> 1) + (reed_raw >>> 2) + reed_raw;
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
