// note_name.v —— MIDI 音符号 -> 音名(字母/升号/八度)
module note_name(
    input  wire [6:0] note,
    output reg  [2:0] ltr,  // 字母码
    output reg        shp,  // 升号
    output reg  [3:0] oct  // 八度数字 0..9
);

    reg [3:0] oct12;  // note / 12
    reg [3:0] semi;  // note % 12
    reg [6:0] semi7;  // 减法先用 7 位算, 再取低 4 位 (避免 EX3791 位宽截断警告)

    always @* begin
        if      (note >= 7'd120) begin oct12 = 4'd10; semi7 = note - 7'd120; end
        else if (note >= 7'd108) begin oct12 = 4'd9;  semi7 = note - 7'd108; end
        else if (note >= 7'd96 ) begin oct12 = 4'd8;  semi7 = note - 7'd96 ; end
        else if (note >= 7'd84 ) begin oct12 = 4'd7;  semi7 = note - 7'd84 ; end
        else if (note >= 7'd72 ) begin oct12 = 4'd6;  semi7 = note - 7'd72 ; end
        else if (note >= 7'd60 ) begin oct12 = 4'd5;  semi7 = note - 7'd60 ; end
        else if (note >= 7'd48 ) begin oct12 = 4'd4;  semi7 = note - 7'd48 ; end
        else if (note >= 7'd36 ) begin oct12 = 4'd3;  semi7 = note - 7'd36 ; end
        else if (note >= 7'd24 ) begin oct12 = 4'd2;  semi7 = note - 7'd24 ; end
        else if (note >= 7'd12 ) begin oct12 = 4'd1;  semi7 = note - 7'd12 ; end
        else                     begin oct12 = 4'd0;  semi7 = note;          end
        // 每个分支的差值都在 0..11, 取低 4 位与真值一致
        semi = semi7[3:0];
    end

    always @* begin
        case (semi)
            4'd0, 4'd1 : ltr = 3'd3;  // C
            4'd2, 4'd3 : ltr = 3'd4;  // D
            4'd4       : ltr = 3'd5;  // E
            4'd5, 4'd6 : ltr = 3'd6;  // F
            4'd7, 4'd8 : ltr = 3'd7;  // G
            4'd9, 4'd10: ltr = 3'd1;  // A
            default    : ltr = 3'd2;  // B
        endcase
    end

    always @* begin
        case (semi)
            4'd1, 4'd3, 4'd6, 4'd8, 4'd10: shp = 1'b1;
            default                       : shp = 1'b0;
        endcase
    end

    always @* begin
        if      (oct12 == 4'd0)  oct = 4'd0;  // 极低音时夹到 0
        else if (oct12 > 4'd10)  oct = 4'd9;
        else                     oct = oct12 - 4'd1;
    end

endmodule
