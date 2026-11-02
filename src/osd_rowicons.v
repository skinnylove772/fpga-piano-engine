// osd_rowicons.v —— 内容页行首 16x16 像素图标 (由 sim/gen_osd.py 自动生成, 请勿手改)
module osd_rowicons(
    input  wire [3:0] ic,  // 图标号 0..11
    input  wire [3:0] y4,  // 图标内行 0..15
    input  wire [3:0] x4,  // 图标内列 0..15
    output wire       pix  // 1 = 该点亮
);
    //  0 timbre
    localparam [255:0] IC_TIMBRE = 256'h00000F0030C02020401020081004080404080210012000C00000000000000000;
    //  1 note
    localparam [255:0] IC_NOTE = 256'h000007C01FF03FF83FF83FF047C02200220022002200220022001C0000000000;
    //  2 octave
    localparam [255:0] IC_OCTAVE = 256'h000000000000000000000C3007E003C0018000000C3007E003C0018000000000;
    //  3 voices
    localparam [255:0] IC_VOICES = 256'h0000000000001E7E1E7E1E3C1C3C1C3C1C181C181C181C181C18001800000000;
    //  4 volume
    localparam [255:0] IC_VOLUME = 256'h0000000000000700878047C6A7E6AFF6AFF6AFF6A7E647C68780070000000000;
    //  5 velocity
    localparam [255:0] IC_VELOCITY = 256'h0000000003C003C003C003C003C000003FFC1FF80FF007E003C0018000000000;
    //  6 vibrato
    localparam [255:0] IC_VIBRATO = 256'h0000000040404040A0A0A0A0111111110A0A0A0A040404040000000000000000;
    //  7 song
    localparam [255:0] IC_SONG = 256'h000000000000FFFE800280020000FFFE800280020000FFFE8002800200000000;
    //  8 state
    localparam [255:0] IC_STATE = 256'h000000100030007000F001F003F007F003F001F000F000700030001000000000;
    //  9 level
    localparam [255:0] IC_LEVEL = 256'h0000000000000000000003C007E007E007E003C000003FF03FF0000000000000;
    //  10 keys
    localparam [255:0] IC_KEYS = 256'h0000000000007FF89248924892487FF892487FF89248924892487FF800000000;
    wire [255:0] rsel =
        (ic == 4'd0) ? IC_TIMBRE     :
        (ic == 4'd1) ? IC_NOTE       :
        (ic == 4'd2) ? IC_OCTAVE     :
        (ic == 4'd3) ? IC_VOICES     :
        (ic == 4'd4) ? IC_VOLUME     :
        (ic == 4'd5) ? IC_VELOCITY   :
        (ic == 4'd6) ? IC_VIBRATO    :
        (ic == 4'd7) ? IC_SONG       :
        (ic == 4'd8) ? IC_STATE      :
        (ic == 4'd9) ? IC_LEVEL      :
        (ic == 4'd10) ? IC_KEYS       : 256'h0;
    assign pix = rsel[{y4, x4}];
endmodule
