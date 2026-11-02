// note_step.v —— 音符号(MIDI 0~127) → 24bit 相位步长 (共享单实例)
module note_step(
    input      [6:0]  note,  // 音符号
    output reg [23:0] step,  // 相位步长 (对应 24 位相位累加器)
    output reg [2:0]  mip  // 波表 mip 级别 = 音高所在八度(0..7)
);

    reg [3:0]  oct;  // 八度 0..10
    reg [3:0]  semi;  // 半音 0..11
    reg [6:0]  semi7;  // 减法先用 7 位算, 再取低 4 位给 semi (避免 EX3791 位宽截断警告)
    reg [31:0] base_w;

    //---- 分解 note = 12*oct + semi (比较链, 不用除法) ----
    always @* begin
        if      (note >= 7'd120) begin oct = 4'd10; semi7 = note - 7'd120; end
        else if (note >= 7'd108) begin oct = 4'd9;  semi7 = note - 7'd108; end
        else if (note >= 7'd96 ) begin oct = 4'd8;  semi7 = note - 7'd96 ; end
        else if (note >= 7'd84 ) begin oct = 4'd7;  semi7 = note - 7'd84 ; end
        else if (note >= 7'd72 ) begin oct = 4'd6;  semi7 = note - 7'd72 ; end
        else if (note >= 7'd60 ) begin oct = 4'd5;  semi7 = note - 7'd60 ; end
        else if (note >= 7'd48 ) begin oct = 4'd4;  semi7 = note - 7'd48 ; end
        else if (note >= 7'd36 ) begin oct = 4'd3;  semi7 = note - 7'd36 ; end
        else if (note >= 7'd24 ) begin oct = 4'd2;  semi7 = note - 7'd24 ; end
        else if (note >= 7'd12 ) begin oct = 4'd1;  semi7 = note - 7'd12 ; end
        else                     begin oct = 4'd0;  semi7 = note;          end
        semi = semi7[3:0];
    end

    //---- 12 音基表 (MIDI 0..11 的相位步长, fs = 46875Hz) ----
    always @* begin
        case (semi)
            4'd0 : base_w = 32'd374558 ;  // C
            4'd1 : base_w = 32'd396830 ;  // C#
            4'd2 : base_w = 32'd420427 ;  // D
            4'd3 : base_w = 32'd445427 ;  // D#
            4'd4 : base_w = 32'd471913 ;  // E
            4'd5 : base_w = 32'd499975 ;  // F
            4'd6 : base_w = 32'd529705 ;  // F#
            4'd7 : base_w = 32'd561203 ;  // G
            4'd8 : base_w = 32'd594573 ;  // G#
            4'd9 : base_w = 32'd629929 ;  // A
            4'd10: base_w = 32'd667386 ;  // A#
            4'd11: base_w = 32'd707071 ;  // B
            default: base_w = 32'd0;
        endcase
    end

    always @* mip = (oct > 4'd7) ? 3'd7 : oct[2:0];

    //   等价于 step24 = f*2^24/fs —— 正好配 24 位相位累加器。
    //   (最高音 MIDI127 的 32 位值是 1.149e9, 左移后仍在 32 位内, 不会溢出)
    always @* step = (base_w << oct) >> 8;

endmodule
