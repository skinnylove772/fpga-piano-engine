// score_rom.v —— 曲谱表 (由 sim/gen_score.py 自动生成, 请勿手改)
module score_rom(
    input  wire [9:0]  addr,  // 音符索引 0..115
    output reg  [7:0]  note  // 音符字节 (0xFF = 曲终)
);

    //  ---- 曲子目录 (由生成器自动列出) ----
    //    每首: 名称 / 起始索引 / 音符数
    //    [0] TWINKLE  start=0  notes=44
    //    [1] ODE  start=48  notes=30
    //    [2] TIGER  start=80  notes=32

    localparam N_SONG = 3;
    localparam [9:0] SONG0_START = 10'd0;
    localparam [9:0] SONG0_LEN   = 10'd44;
    localparam [9:0] SONG1_START = 10'd48;
    localparam [9:0] SONG1_LEN   = 10'd30;
    localparam [9:0] SONG2_START = 10'd80;
    localparam [9:0] SONG2_LEN   = 10'd32;

    //  ---- 音符表 ----
    always @(*) begin
        case (addr)
            10'd0    : note = 8'h14;
            10'd1    : note = 8'h14;
            10'd2    : note = 8'h54;
            10'd3    : note = 8'h54;
            10'd4    : note = 8'h64;
            10'd5    : note = 8'h64;
            10'd6    : note = 8'h58;
            10'd7    : note = 8'h44;
            10'd8    : note = 8'h44;
            10'd9    : note = 8'h34;
            10'd10   : note = 8'h34;
            10'd11   : note = 8'h24;
            10'd12   : note = 8'h24;
            10'd13   : note = 8'h18;
            10'd14   : note = 8'h04;
            10'd15   : note = 8'h54;
            10'd16   : note = 8'h54;
            10'd17   : note = 8'h44;
            10'd18   : note = 8'h44;
            10'd19   : note = 8'h34;
            10'd20   : note = 8'h34;
            10'd21   : note = 8'h28;
            10'd22   : note = 8'h54;
            10'd23   : note = 8'h54;
            10'd24   : note = 8'h44;
            10'd25   : note = 8'h44;
            10'd26   : note = 8'h34;
            10'd27   : note = 8'h34;
            10'd28   : note = 8'h28;
            10'd29   : note = 8'h04;
            10'd30   : note = 8'h14;
            10'd31   : note = 8'h14;
            10'd32   : note = 8'h54;
            10'd33   : note = 8'h54;
            10'd34   : note = 8'h64;
            10'd35   : note = 8'h64;
            10'd36   : note = 8'h58;
            10'd37   : note = 8'h44;
            10'd38   : note = 8'h44;
            10'd39   : note = 8'h34;
            10'd40   : note = 8'h34;
            10'd41   : note = 8'h24;
            10'd42   : note = 8'h24;
            10'd43   : note = 8'h18;
            10'd48   : note = 8'h34;
            10'd49   : note = 8'h34;
            10'd50   : note = 8'h44;
            10'd51   : note = 8'h54;
            10'd52   : note = 8'h54;
            10'd53   : note = 8'h44;
            10'd54   : note = 8'h34;
            10'd55   : note = 8'h24;
            10'd56   : note = 8'h14;
            10'd57   : note = 8'h14;
            10'd58   : note = 8'h24;
            10'd59   : note = 8'h34;
            10'd60   : note = 8'h38;
            10'd61   : note = 8'h28;
            10'd62   : note = 8'h24;
            10'd63   : note = 8'h34;
            10'd64   : note = 8'h34;
            10'd65   : note = 8'h44;
            10'd66   : note = 8'h54;
            10'd67   : note = 8'h54;
            10'd68   : note = 8'h44;
            10'd69   : note = 8'h34;
            10'd70   : note = 8'h24;
            10'd71   : note = 8'h14;
            10'd72   : note = 8'h14;
            10'd73   : note = 8'h24;
            10'd74   : note = 8'h34;
            10'd75   : note = 8'h28;
            10'd76   : note = 8'h18;
            10'd77   : note = 8'h14;
            10'd80   : note = 8'h14;
            10'd81   : note = 8'h24;
            10'd82   : note = 8'h34;
            10'd83   : note = 8'h14;
            10'd84   : note = 8'h14;
            10'd85   : note = 8'h24;
            10'd86   : note = 8'h34;
            10'd87   : note = 8'h14;
            10'd88   : note = 8'h34;
            10'd89   : note = 8'h44;
            10'd90   : note = 8'h58;
            10'd91   : note = 8'h34;
            10'd92   : note = 8'h44;
            10'd93   : note = 8'h58;
            10'd94   : note = 8'h58;
            10'd95   : note = 8'h68;
            10'd96   : note = 8'h58;
            10'd97   : note = 8'h48;
            10'd98   : note = 8'h34;
            10'd99   : note = 8'h14;
            10'd100  : note = 8'h58;
            10'd101  : note = 8'h68;
            10'd102  : note = 8'h58;
            10'd103  : note = 8'h48;
            10'd104  : note = 8'h34;
            10'd105  : note = 8'h14;
            10'd106  : note = 8'h18;
            10'd107  : note = 8'h58;
            10'd108  : note = 8'h14;
            10'd109  : note = 8'h18;
            10'd110  : note = 8'h58;
            10'd111  : note = 8'h14;
            default: note = 8'hFF;  // 曲终 / 越界
        endcase
    end

endmodule
