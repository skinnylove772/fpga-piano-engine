// osd_overlay.v —— OSD 动态数值叠加层 (由 sim/gen_osd.py 自动生成, 请勿手改)
module osd_overlay(
    input  wire [3:0] page       ,  // 当前页号 0..5
    input  wire [3:0] trow       ,  // 文字行号 0..14
    input  wire [4:0] ccol       ,  // 列号 0..29
    input  wire test_active,  // 测试模式
    input  wire [5:0] test_lvl   ,  // 测试档位 0/4/8/16/32
    input  wire [2:0] wave_sel   ,  // 音色 0..7
    input  wire [5:0] active_cnt ,  // 活跃声部数
    input  wire [2:0] note_ltr   ,  // 音名字母码
    input  wire note_shp   ,  // 升号
    input  wire [3:0] note_oct   ,  // 音名八度数字
    input  wire [7:0] dist_cm    ,  // 距离 cm, 200=超量程
    input  wire [3:0] ges_idx    ,  // 手势号 0..9
    input  wire [1:0] oct_idx    ,  // 八度档 0..3
    input  wire [7:0] vel_ges    ,  // 力度档 80..240
    input  wire [2:0] vib_ges    ,  // 颤音深度 0..7
    input  wire chorus_en  ,  // 合唱开关
    input  wire [7:0] master_vol ,  // 主音量 0..255
    input  wire [15:0] key_raw    ,  // 10 路引脚原始电平 (高 6 位补 0)
    input  wire [3:0] paj_phase  ,  // 手势模块状态: 0=正常 1=唤醒 2=握手 3=写表 4=等稳定
    input  wire [3:0] paj_rej    ,  // 被 one-hot 过滤挡掉的次数
    input  wire [3:0] paj_ecnt   ,  // 连续读手势失败次数 (到 8 就重初始化)
    input  wire [5:0] paj_fidx   ,  // 配置表第几条写不进去 (63=没失败过)
    input  wire [7:0] paj_g1     ,  // 0x43 原始字节 (上/下/左/右/前/后/顺/逆)
    input  wire [7:0] paj_g2     ,  // 0x44 原始字节 (bit0=挥动)
    input  wire [7:0] paj_wa0    ,  // 握手寄存器 0x00 读回值 (应为 20)
    input  wire sobusy     ,  // 声部表: 该声部是否发声
    input  wire [6:0] sonote     ,  // 声部表: 音符号
    input  wire [7:0] soenv      ,  // 声部表: 包络
    input  wire [3:0] sorow      ,  // 声部表: 正在刷新的行 0..6
    input  wire [1:0] socol      ,  // 声部表: 正在刷新的组 0..3
    input  wire [7:0] barval     ,  // 频谱: 当前段的值 0..255
    input  wire [2:0] baridx     ,  // 频谱: 当前段号 0..7
    input  wire [1:0] barlow     ,  // 频谱: 正在刷新的行 0..2
    input  wire [3:0]   menu_sel   ,  // 菜单光标 0..10
    input  wire [1:0]   menu_level ,  // 层级 0=翻页 1=选择 2=改值
    input  wire [1:0]   sng_sel    ,  // 当前选中的曲目 0..3
    input  wire [1:0]   sc_state   ,  // 曲谱状态 0=停 1=播 2=完
    input  wire [9:0]   note_pos   ,  // 曲谱进度 (已走音数)
    input  wire [9:0]   note_total ,  // 曲谱总音数
    input  wire [2:0]   enc_timbre ,  // 编码器: 音色
    input  wire [1:0]   enc_octave ,  // 编码器: 八度
    input  wire [7:0]   enc_volume ,  // 编码器: 主音量
    input  wire [2:0]   enc_vib    ,  // 编码器: 颤音
    input  wire [2:0]   enc_chorus ,  // 编码器: 合唱深度 0..3
    input  wire [2:0]   enc_delay  ,  // 编码器: 延迟深度 0..3
    input  wire [2:0]   enc_reverb ,  // 编码器: 混响深度 0..3
    input  wire [1:0]   enc_gesture,  // 编码器: 手势开关
    input  wire [2:0]   enc_glide  ,  // 编码器: 滑音档位 0..6
    input  wire         enc_ctype  ,  // 编码器: 合唱类型 LIGHT/DEEP
    input  wire         enc_dtype  ,  // 编码器: 延迟类型 SHORT/LONG
    input  wire         enc_rtype  ,  // 编码器: 混响类型 ROOM/HALL
    input  wire         enc_mode   ,  // 编码器: 播放模式 GUIDE/AUTO
    input  wire         enc_on_timbre,  // 编码器改过音色
    input  wire         enc_on_octave,  // 编码器改过八度
    input  wire         enc_on_volume,  // 编码器改过音量
    input  wire         enc_on_vib ,  // 编码器改过颤音
    input  wire         enc_on_chorus  // 编码器改过合唱
    ,output reg         ovl_en
    ,output reg  [9:0]  ovl_ch
);

    //  MODE 字符串: 0=GUIDE 1=AUTO
    wire [29:0] mode_str = enc_mode ? 30'h015543C0 : 30'h07549105;
    //  CHORUS 类型: 0=LIGHT 1=DEEP
    wire [29:0] ctype_str = enc_ctype ? 30'h04145400 : 30'h0C247214;
    //  DELAY 类型: 0=SHORT 1=LONG
    wire [29:0] dtype_str = enc_dtype ? 30'h0C3CE1C0 : 30'h1320F494;
    //  REVERB 类型: 0=ROOM 1=HALL
    wire [29:0] rtype_str = enc_rtype ? 30'h0804C300 : 30'h123CF340;
    //---- 声部数 0..32 拆成十位/个位 ----
    wire [3:0] vt = (active_cnt >= 6'd30) ? 4'd3 :
                    (active_cnt >= 6'd20) ? 4'd2 :
                    (active_cnt >= 6'd10) ? 4'd1 : 4'd0;
    wire [5:0] vt10 = (vt == 4'd3) ? 6'd30 :
                      (vt == 4'd2) ? 6'd20 :
                      (vt == 4'd1) ? 6'd10 : 6'd0;
    wire [5:0] vo6 = active_cnt - vt10;
    wire [3:0] vo  = vo6[3:0];  // 取低 4 位, 避免 EX3791

    //---- 距离 0..200cm 拆两位 (超过 99 钳到 99) ----
    wire [6:0] dd  = (dist_cm > 8'd99) ? 7'd99 : dist_cm[6:0];
    wire [3:0] dt  = (dd >= 7'd90) ? 4'd9 : (dd >= 7'd80) ? 4'd8 :
                     (dd >= 7'd70) ? 4'd7 : (dd >= 7'd60) ? 4'd6 :
                     (dd >= 7'd50) ? 4'd5 : (dd >= 7'd40) ? 4'd4 :
                     (dd >= 7'd30) ? 4'd3 : (dd >= 7'd20) ? 4'd2 :
                     (dd >= 7'd10) ? 4'd1 : 4'd0;
    wire [6:0] dt10 = {3'b000, dt} * 7'd10;
    wire [6:0] du7  = dd - dt10;
    wire [3:0] dist10 = dt;
    wire [3:0] dist1  = du7[3:0];  // 取低 4 位, 避免 EX3791

    //---- 声部包络 0..255 -> 两位 (取 0..99, 只要够看强弱) ----
    wire [6:0] ee   = (soenv > 8'd99) ? 7'd99 : soenv[6:0];
    wire [3:0] et   = (ee >= 7'd90) ? 4'd9 : (ee >= 7'd80) ? 4'd8 :
                      (ee >= 7'd70) ? 4'd7 : (ee >= 7'd60) ? 4'd6 :
                      (ee >= 7'd50) ? 4'd5 : (ee >= 7'd40) ? 4'd4 :
                      (ee >= 7'd30) ? 4'd3 : (ee >= 7'd20) ? 4'd2 :
                      (ee >= 7'd10) ? 4'd1 : 4'd0;
    wire [6:0] et10 = {3'b000, et} * 7'd10;
    wire [6:0] eu7  = ee - et10;
    wire [3:0] so_d10 = et;
    wire [3:0] so_d1  = eu7[3:0];

    //---- 测试档位 3 字符串 ----
    reg [11:0] tst_str;
    always @* begin
        case (test_lvl)
            6'd0 : tst_str = 12'h3C6;  // "OFF"
            6'd1 : tst_str = 12'h01C;  // " 1"
            6'd2 : tst_str = 12'h01D;  // " 2"
            6'd3 : tst_str = 12'h01E;  // " 3"
            6'd4 : tst_str = 12'h01F;  // " 4"
            6'd5 : tst_str = 12'h020;  // " 5"
            6'd6 : tst_str = 12'h021;  // " 6"
            6'd7 : tst_str = 12'h022;  // " 7"
            6'd8 : tst_str = 12'h023;  // " 8"
            6'd9 : tst_str = 12'h024;  // " 9"
            6'd10: tst_str = 12'h71B;  // "10"
            6'd11: tst_str = 12'h71C;  // "11"
            6'd12: tst_str = 12'h71D;  // "12"
            6'd13: tst_str = 12'h71E;  // "13"
            6'd14: tst_str = 12'h71F;  // "14"
            6'd15: tst_str = 12'h720;  // "15"
            6'd16: tst_str = 12'h721;  // "16"
            6'd17: tst_str = 12'h722;  // "17"
            6'd18: tst_str = 12'h723;  // "18"
            6'd19: tst_str = 12'h724;  // "19"
            6'd20: tst_str = 12'h75B;  // "20"
            6'd21: tst_str = 12'h75C;  // "21"
            6'd22: tst_str = 12'h75D;  // "22"
            6'd23: tst_str = 12'h75E;  // "23"
            6'd24: tst_str = 12'h75F;  // "24"
            6'd25: tst_str = 12'h760;  // "25"
            6'd26: tst_str = 12'h761;  // "26"
            6'd27: tst_str = 12'h762;  // "27"
            6'd28: tst_str = 12'h763;  // "28"
            6'd29: tst_str = 12'h764;  // "29"
            6'd30: tst_str = 12'h79B;  // "30"
            6'd31: tst_str = 12'h79C;  // "31"
            6'd32: tst_str = 12'h79D;  // "32"
            default: tst_str = 12'h9E7;  // "--"
        endcase
    end

    wire [31:0] s_mode = test_active ? 32'h005054D4 : 32'h0040C059;  // TEST / PLAY
    wire [47:0] s_timb0 = 48'h0004C9385000;  // "SINE  "
    wire [47:0] s_timb1 = 48'h000512240000;  // "TRI   "
    wire [47:0] s_timb2 = 48'h0004C15C0000;  // "SAW   "
    wire [47:0] s_timb3 = 48'h0004D1480000;  // "SQR   "
    wire [47:0] s_timb4 = 48'h00040C4DD800;  // "PLS25 "
    wire [47:0] s_timb5 = 48'h00040C4DC740;  // "PLS12 "
    wire [47:0] s_timb6 = 48'h000349600000;  // "MIX   "
    wire [47:0] s_timb7 = 48'h000485144000;  // "REED  "
    wire [47:0] s_timb = (wave_sel == 3'd0) ? s_timb0 :
                         (wave_sel == 3'd1) ? s_timb1 :
                         (wave_sel == 3'd2) ? s_timb2 :
                         (wave_sel == 3'd3) ? s_timb3 :
                         (wave_sel == 3'd4) ? s_timb4 :
                         (wave_sel == 3'd5) ? s_timb5 :
                         (wave_sel == 3'd6) ? s_timb6 : s_timb7;

    wire [17:0] t3_0 = 18'h1324E;  // "SIN"
    wire [17:0] t3_1 = 18'h14489;  // "TRI"
    wire [17:0] t3_2 = 18'h13057;  // "SAW"
    wire [17:0] t3_3 = 18'h13452;  // "SQR"
    wire [17:0] t3_4 = 18'h10760;  // "P25"
    wire [17:0] t3_5 = 18'h1071D;  // "P12"
    wire [17:0] t3_6 = 18'h0D258;  // "MIX"
    wire [17:0] t3_7 = 18'h12145;  // "REE"
    wire [17:0] t3_str = (wave_sel == 3'd0) ? t3_0 :
                        (wave_sel == 3'd1) ? t3_1 :
                        (wave_sel == 3'd2) ? t3_2 :
                        (wave_sel == 3'd3) ? t3_3 :
                        (wave_sel == 3'd4) ? t3_4 :
                        (wave_sel == 3'd5) ? t3_5 :
                        (wave_sel == 3'd6) ? t3_6 : t3_7;

    reg [63:0] ges_str;
    always @* begin
        case (ges_idx)
            4'd0 : ges_str = 64'h000038F385000000;  // "NONE    "
            4'd1 : ges_str = 64'h0000550000000000;  // "UP      "
            4'd2 : ges_str = 64'h000010F5CE000000;  // "DOWN    "
            4'd3 : ges_str = 64'h0000305194000000;  // "LEFT    "
            4'd4 : ges_str = 64'h00004891C8500000;  // "RIGHT   "
            4'd5 : ges_str = 64'h000018F497052100;  // "FORWARD "
            4'd6 : ges_str = 64'h00000810CB5C1484;  // "BACKWARD"
            4'd7 : ges_str = 64'h00000D7000000000;  // "CW      "
            4'd8 : ges_str = 64'h00000C35C0000000;  // "CCW     "
            4'd9 : ges_str = 64'h00005C1585000000;  // "WAVE    "
            default: ges_str = 64'h0000000000000000;
        endcase
    end

    //---- 力度三位: 只有 5 个档, 直接查表, 不做除法 ----
    reg [3:0] vel_h, vel_t;
    always @* begin
        case (vel_ges)
            8'd80  : begin vel_h = 4'd0; vel_t = 4'd8; end
            8'd120 : begin vel_h = 4'd1; vel_t = 4'd2; end
            8'd160 : begin vel_h = 4'd1; vel_t = 4'd6; end
            8'd200 : begin vel_h = 4'd2; vel_t = 4'd0; end
            8'd240 : begin vel_h = 4'd2; vel_t = 4'd4; end
            default: begin vel_h = 4'd2; vel_t = 4'd0; end
        endcase
    end

    //---- 主音量 88..248 -> 3 位数字 (查表, 无乘法器) ----
    reg [17:0] vol3;
    always @* begin
        case (enc_volume)
            8'd88  : vol3 = 18'h008E3;  // " 88"
            8'd96  : vol3 = 18'h00921;  // " 96"
            8'd104 : vol3 = 18'h1C6DF;  // "104"
            8'd112 : vol3 = 18'h1C71D;  // "112"
            8'd120 : vol3 = 18'h1C75B;  // "120"
            8'd128 : vol3 = 18'h1C763;  // "128"
            8'd136 : vol3 = 18'h1C7A1;  // "136"
            8'd144 : vol3 = 18'h1C7DF;  // "144"
            8'd152 : vol3 = 18'h1C81D;  // "152"
            8'd160 : vol3 = 18'h1C85B;  // "160"
            8'd168 : vol3 = 18'h1C863;  // "168"
            8'd176 : vol3 = 18'h1C8A1;  // "176"
            8'd184 : vol3 = 18'h1C8DF;  // "184"
            8'd192 : vol3 = 18'h1C91D;  // "192"
            8'd200 : vol3 = 18'h1D6DB;  // "200"
            8'd208 : vol3 = 18'h1D6E3;  // "208"
            8'd216 : vol3 = 18'h1D721;  // "216"
            8'd224 : vol3 = 18'h1D75F;  // "224"
            8'd232 : vol3 = 18'h1D79D;  // "232"
            8'd240 : vol3 = 18'h1D7DB;  // "240"
            8'd248 : vol3 = 18'h1D7E3;  // "248"
            default: vol3 = 18'h279E7;  // "---"
        endcase
    end

    //---- 声部表音名: 音符号 -> 音级 -> 字母 ----
    function [3:0] pclass;
        input [6:0] n;
        reg [6:0] rr;
        begin
            if      (n >= 7'd120) rr = n - 7'd120;
            else if (n >= 7'd108) rr = n - 7'd108;
            else if (n >= 7'd96 ) rr = n - 7'd96;
            else if (n >= 7'd84 ) rr = n - 7'd84;
            else if (n >= 7'd72 ) rr = n - 7'd72;
            else if (n >= 7'd60 ) rr = n - 7'd60;
            else if (n >= 7'd48 ) rr = n - 7'd48;
            else if (n >= 7'd36 ) rr = n - 7'd36;
            else if (n >= 7'd24 ) rr = n - 7'd24;
            else if (n >= 7'd12 ) rr = n - 7'd12;
            else                  rr = n;
            pclass = rr[3:0];
        end
    endfunction
    wire [3:0] spc = pclass(sonote);
    reg [5:0] spl;  reg sps;
    always @* begin
        case (spc)
            4'd0 : begin spl = 6'd3; sps = 1'b0; end
            4'd1 : begin spl = 6'd3; sps = 1'b1; end
            4'd2 : begin spl = 6'd4; sps = 1'b0; end
            4'd3 : begin spl = 6'd4; sps = 1'b1; end
            4'd4 : begin spl = 6'd5; sps = 1'b0; end
            4'd5 : begin spl = 6'd6; sps = 1'b0; end
            4'd6 : begin spl = 6'd6; sps = 1'b1; end
            4'd7 : begin spl = 6'd7; sps = 1'b0; end
            4'd8 : begin spl = 6'd7; sps = 1'b1; end
            4'd9 : begin spl = 6'd1; sps = 1'b0; end
            4'd10: begin spl = 6'd1; sps = 1'b1; end
            4'd11: begin spl = 6'd2; sps = 1'b0; end
            default: begin spl = 6'd3; sps = 1'b0; end
        endcase
    end

    //---- 频谱柱: 3 行 x 3 格 = 9 级, 自下而上 ----
    wire [3:0] blv = (barval >= 8'd226) ? 4'd9 :
                     (barval >= 8'd198) ? 4'd8 :
                     (barval >= 8'd170) ? 4'd7 :
                     (barval >= 8'd142) ? 4'd6 :
                     (barval >= 8'd114) ? 4'd5 :
                     (barval >= 8'd86 ) ? 4'd4 :
                     (barval >= 8'd58 ) ? 4'd3 :
                     (barval >= 8'd30 ) ? 4'd2 :
                     (barval >= 8'd8  ) ? 4'd1 : 4'd0;
    //  barlow: 0=最下面一行 -> 需要格数 = blv - barlow*3
    wire [3:0] bneed = (blv > {barlow, 2'b00}) ? (blv - {barlow, 2'b00}) : 4'd0;
    wire [3:0] bgive = (bneed >= 4'd3) ? 4'd3 : bneed;

    //---- 按 (page, trow, ccol) 选字符 ----
    always @* begin
        ovl_en = 1'b1;
        ovl_ch = 10'd0;
        case ({page[2:0], trow, ccol})
            12'd68   : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd2, 6'd13} : {4'd12, 6'd13};
            12'd69   : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd2, 6'd1} : {4'd12, 6'd1};
            12'd70   : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd2, 6'd9} : {4'd12, 6'd9};
            12'd71   : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd2, 6'd14} : {4'd12, 6'd14};
            12'd72   : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd2, 6'd0} : {4'd12, 6'd0};
            12'd73   : ovl_ch = {4'd8, 6'd0};
            12'd74   : ovl_ch = {4'd8, 6'd0};
            12'd75   : ovl_ch = {4'd8, 6'd0};
            12'd76   : ovl_ch = {4'd8, 6'd0};
            12'd77   : ovl_ch = {4'd8, 6'd0};
            12'd78   : ovl_ch = {4'd8, 6'd0};
            12'd79   : ovl_ch = {4'd8, 6'd0};
            12'd89   : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd164  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd2, 6'd7} : {4'd12, 6'd7};
            12'd165  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd2, 6'd18} : {4'd12, 6'd18};
            12'd166  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd2, 6'd1} : {4'd12, 6'd1};
            12'd167  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd2, 6'd16} : {4'd12, 6'd16};
            12'd168  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd2, 6'd8} : {4'd12, 6'd8};
            12'd169  : ovl_ch = {4'd8, 6'd0};
            12'd170  : ovl_ch = {4'd8, 6'd0};
            12'd171  : ovl_ch = {4'd8, 6'd0};
            12'd172  : ovl_ch = {4'd8, 6'd0};
            12'd173  : ovl_ch = {4'd8, 6'd0};
            12'd174  : ovl_ch = {4'd8, 6'd0};
            12'd175  : ovl_ch = {4'd8, 6'd0};
            12'd185  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd260  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd2, 6'd16} : {4'd12, 6'd16};
            12'd261  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd2, 6'd1} : {4'd12, 6'd1};
            12'd262  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd2, 6'd18} : {4'd12, 6'd18};
            12'd263  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd2, 6'd1} : {4'd12, 6'd1};
            12'd264  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd2, 6'd13} : {4'd12, 6'd13};
            12'd265  : ovl_ch = {4'd8, 6'd0};
            12'd266  : ovl_ch = {4'd8, 6'd0};
            12'd267  : ovl_ch = {4'd8, 6'd0};
            12'd268  : ovl_ch = {4'd8, 6'd0};
            12'd269  : ovl_ch = {4'd8, 6'd0};
            12'd270  : ovl_ch = {4'd8, 6'd0};
            12'd271  : ovl_ch = {4'd8, 6'd0};
            12'd281  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd356  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd2, 6'd13} : {4'd12, 6'd13};
            12'd357  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd2, 6'd21} : {4'd12, 6'd21};
            12'd358  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd2, 6'd19} : {4'd12, 6'd19};
            12'd359  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd2, 6'd9} : {4'd12, 6'd9};
            12'd360  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd2, 6'd3} : {4'd12, 6'd3};
            12'd361  : ovl_ch = {4'd8, 6'd0};
            12'd362  : ovl_ch = {4'd8, 6'd0};
            12'd363  : ovl_ch = {4'd8, 6'd0};
            12'd364  : ovl_ch = {4'd8, 6'd0};
            12'd365  : ovl_ch = {4'd8, 6'd0};
            12'd366  : ovl_ch = {4'd8, 6'd0};
            12'd367  : ovl_ch = {4'd8, 6'd0};
            12'd377  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd452  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd4)) ? {4'd2, 6'd20} : {4'd12, 6'd20};
            12'd453  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd4)) ? {4'd2, 6'd5} : {4'd12, 6'd5};
            12'd454  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd4)) ? {4'd2, 6'd19} : {4'd12, 6'd19};
            12'd455  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd4)) ? {4'd2, 6'd20} : {4'd12, 6'd20};
            12'd456  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd4)) ? {4'd2, 6'd0} : {4'd12, 6'd0};
            12'd457  : ovl_ch = {4'd8, 6'd0};
            12'd458  : ovl_ch = {4'd8, 6'd0};
            12'd459  : ovl_ch = {4'd8, 6'd0};
            12'd460  : ovl_ch = {4'd8, 6'd0};
            12'd461  : ovl_ch = {4'd8, 6'd0};
            12'd462  : ovl_ch = {4'd8, 6'd0};
            12'd463  : ovl_ch = {4'd8, 6'd0};
            12'd473  : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd4)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd532  : ovl_ch = {4'd3, ges_str[42 +: 6]};
            12'd533  : ovl_ch = {4'd3, ges_str[36 +: 6]};
            12'd534  : ovl_ch = {4'd3, ges_str[30 +: 6]};
            12'd535  : ovl_ch = {4'd3, ges_str[24 +: 6]};
            12'd536  : ovl_ch = {4'd3, ges_str[18 +: 6]};
            12'd537  : ovl_ch = {4'd3, ges_str[12 +: 6]};
            12'd538  : ovl_ch = {4'd3, ges_str[6 +: 6]};
            12'd539  : ovl_ch = {4'd3, ges_str[0 +: 6]};
            12'd591  : ovl_ch = {4'd3, s_timb[30 +: 6]};
            12'd592  : ovl_ch = {4'd3, s_timb[24 +: 6]};
            12'd593  : ovl_ch = {4'd3, s_timb[18 +: 6]};
            12'd594  : ovl_ch = {4'd3, s_timb[12 +: 6]};
            12'd595  : ovl_ch = {4'd3, s_timb[6 +: 6]};
            12'd596  : ovl_ch = {4'd3, s_timb[0 +: 6]};
            12'd656  : ovl_ch = {4'd3, {3'b000, note_ltr}};
            12'd657  : ovl_ch = (note_shp ? {4'd3, 6'd41} : {4'd3, (6'd27 + {2'b00, note_oct})});
            12'd658  : ovl_ch = (note_shp ? {4'd3, (6'd27 + {2'b00, note_oct})} : {4'd3, 6'd0});
            12'd720  : ovl_ch = {4'd3, (6'd27 + {4'b0000, oct_idx})};
            12'd784  : ovl_ch = {4'd3, (6'd27 + {2'b00, vt})};
            12'd785  : ovl_ch = {4'd3, (6'd27 + {2'b00, vo})};
            12'd786  : ovl_ch = {4'd3, 6'd38};
            12'd787  : ovl_ch = {4'd3, 6'd30};
            12'd788  : ovl_ch = {4'd3, 6'd29};
            12'd842  : ovl_ch = {4'd3, (vol3[17:12] == 6'd27) ? 6'd0 : vol3[17:12]};
            12'd843  : ovl_ch = {4'd3, ((vol3[17:12] == 6'd27) && (vol3[11:6] == 6'd27)) ? 6'd0 : vol3[11:6]};
            12'd844  : ovl_ch = {4'd3, vol3[5:0]};
            12'd912  : ovl_ch = {4'd3, (6'd27 + {2'b00, vel_h})};
            12'd913  : ovl_ch = {4'd3, (6'd27 + {2'b00, vel_t})};
            12'd914  : ovl_ch = {4'd3, 6'd27};
            12'd970  : ovl_ch = {4'd3, (6'd27 + {4'b0000, vib_ges})};
            12'd978  : ovl_ch = {4'd4, 6'd15};
            12'd979  : ovl_ch = (chorus_en ? {4'd4, 6'd14} : {4'd5, 6'd6});
            12'd980  : ovl_ch = (chorus_en ? {4'd4, 6'd0} : {4'd5, 6'd6});
            12'd1066 : ovl_ch = (active_cnt != 6'd0) ? {4'd3, {3'b000, note_ltr}} : {4'd9, 6'd27};
            12'd1067 : ovl_ch = (active_cnt != 6'd0) ? (note_shp ? {4'd3, 6'd41} : {4'd3, (6'd27 + {2'b00, note_oct})}) : {4'd9, 6'd27};
            12'd1068 : ovl_ch = (active_cnt != 6'd0) ? (note_shp ? {4'd3, (6'd27 + {2'b00, note_oct})} : {4'd3, 6'd0}) : {4'd9, 6'd0};
            12'd1098 : ovl_ch = {4'd3, (6'd27 + {2'b00, vt})};
            12'd1099 : ovl_ch = {4'd3, (6'd27 + {2'b00, vo})};
            12'd1100 : ovl_ch = {4'd3, 6'd38};
            12'd1101 : ovl_ch = {4'd3, 6'd30};
            12'd1102 : ovl_ch = {4'd3, 6'd29};
            12'd1561 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd5} : {4'd0, 6'd5};
            12'd1562 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd4} : {4'd0, 6'd4};
            12'd1563 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd9} : {4'd0, 6'd9};
            12'd1564 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd20} : {4'd0, 6'd20};
            12'd1616 : ovl_ch = {4'd6, t3_str[12 +: 6]};
            12'd1617 : ovl_ch = {4'd6, t3_str[6 +: 6]};
            12'd1618 : ovl_ch = {4'd6, t3_str[0 +: 6]};
            12'd1625 : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd0)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1648 : ovl_ch = {4'd6, (6'd27 + {2'b00, enc_octave})};
            12'd1657 : ovl_ch = (menu_sel == 4'd1) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1680 : ovl_ch = {4'd6, vol3[17:12]};
            12'd1681 : ovl_ch = {4'd6, vol3[11:6]};
            12'd1682 : ovl_ch = {4'd6, vol3[5:0]};
            12'd1689 : ovl_ch = (menu_sel == 4'd2) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1712 : ovl_ch = {4'd6, (6'd27 + {2'b00, enc_vib})};
            12'd1721 : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd1)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1744 : ovl_ch = (enc_chorus == 3'd0) ? {4'd5, 6'd15} : {4'd6, 6'd0};
            12'd1745 : ovl_ch = (enc_chorus == 3'd0) ? {4'd5, 6'd6}  : {4'd6, 6'd0};
            12'd1746 : ovl_ch = (enc_chorus == 3'd0) ? {4'd5, 6'd6}  : {4'd6, (6'd27 + {3'd0, enc_chorus})};
            12'd1753 : ovl_ch = (menu_sel == 4'd4) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1776 : ovl_ch = {4'd3, ctype_str[24 +: 6]};
            12'd1777 : ovl_ch = {4'd3, ctype_str[18 +: 6]};
            12'd1778 : ovl_ch = {4'd3, ctype_str[12 +: 6]};
            12'd1779 : ovl_ch = {4'd3, ctype_str[6 +: 6]};
            12'd1780 : ovl_ch = {4'd3, ctype_str[0 +: 6]};
            12'd1785 : ovl_ch = (menu_sel == 4'd5) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1808 : ovl_ch = (enc_delay == 3'd0) ? {4'd5, 6'd15} : {4'd6, 6'd0};
            12'd1809 : ovl_ch = (enc_delay == 3'd0) ? {4'd5, 6'd6}  : {4'd6, 6'd0};
            12'd1810 : ovl_ch = (enc_delay == 3'd0) ? {4'd5, 6'd6}  : {4'd6, (6'd27 + {3'd0, enc_delay})};
            12'd1817 : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd2)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1840 : ovl_ch = {4'd3, dtype_str[24 +: 6]};
            12'd1841 : ovl_ch = {4'd3, dtype_str[18 +: 6]};
            12'd1842 : ovl_ch = {4'd3, dtype_str[12 +: 6]};
            12'd1843 : ovl_ch = {4'd3, dtype_str[6 +: 6]};
            12'd1844 : ovl_ch = {4'd3, dtype_str[0 +: 6]};
            12'd1849 : ovl_ch = (menu_sel == 4'd7) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1872 : ovl_ch = (enc_reverb == 3'd0) ? {4'd5, 6'd15} : {4'd6, 6'd0};
            12'd1873 : ovl_ch = (enc_reverb == 3'd0) ? {4'd5, 6'd6}  : {4'd6, 6'd0};
            12'd1874 : ovl_ch = (enc_reverb == 3'd0) ? {4'd5, 6'd6}  : {4'd6, (6'd27 + {3'd0, enc_reverb})};
            12'd1881 : ovl_ch = (menu_sel == 4'd8) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1904 : ovl_ch = {4'd3, rtype_str[24 +: 6]};
            12'd1905 : ovl_ch = {4'd3, rtype_str[18 +: 6]};
            12'd1906 : ovl_ch = {4'd3, rtype_str[12 +: 6]};
            12'd1907 : ovl_ch = {4'd3, rtype_str[6 +: 6]};
            12'd1908 : ovl_ch = {4'd3, rtype_str[0 +: 6]};
            12'd1913 : ovl_ch = ((menu_level == 2'd0) && (menu_sel == 4'd3)) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1936 : ovl_ch = (enc_gesture ? {4'd4, 6'd15} : {4'd5, 6'd15});
            12'd1937 : ovl_ch = (enc_gesture ? {4'd4, 6'd14} : {4'd5, 6'd6});
            12'd1938 : ovl_ch = (enc_gesture ? {4'd4, 6'd0} : {4'd5, 6'd6});
            12'd1945 : ovl_ch = (menu_sel == 4'd10) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd1968 : ovl_ch = {4'd6, (6'd27 + {2'b00, enc_glide})};
            12'd1977 : ovl_ch = (menu_sel == 4'd11) ? {4'd10, 6'd47} : {4'd9, 6'd0};
            12'd2017 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd3};
            12'd2018 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd12};
            12'd2019 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd9};
            12'd2020 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd3};
            12'd2021 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd11};
            12'd2022 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd37};
            12'd2023 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2024 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd12};
            12'd2025 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd15};
            12'd2026 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd3};
            12'd2027 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd11};
            12'd2028 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2029 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2030 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd8};
            12'd2031 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd15};
            12'd2032 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd12};
            12'd2033 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd4};
            12'd2034 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd37};
            12'd2035 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2036 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd8};
            12'd2037 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd15};
            12'd2038 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd13};
            12'd2039 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd5};
            12'd2073 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd5} : {4'd0, 6'd5};
            12'd2074 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd4} : {4'd0, 6'd4};
            12'd2075 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd9} : {4'd0, 6'd9};
            12'd2076 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd20} : {4'd0, 6'd20};
            12'd2128 : ovl_ch = (sng_sel == 2'd0) ? {4'd3, 6'd28} : (sng_sel == 2'd1) ? {4'd3, 6'd29} : (sng_sel == 2'd2) ? {4'd3, 6'd30} : (sng_sel == 2'd3) ? {4'd3, 6'd31} : {4'd3, 6'd31};
            12'd2192 : ovl_ch = {4'd3, mode_str[24 +: 6]};
            12'd2193 : ovl_ch = {4'd3, mode_str[18 +: 6]};
            12'd2194 : ovl_ch = {4'd3, mode_str[12 +: 6]};
            12'd2195 : ovl_ch = {4'd3, mode_str[6 +: 6]};
            12'd2196 : ovl_ch = {4'd3, mode_str[0 +: 6]};
            12'd2256 : ovl_ch = (sc_state == 2'd0) ? {4'd9, 6'd19} : (sc_state == 2'd1) ? {4'd4, 6'd16} : (sc_state == 2'd2) ? {4'd3, 6'd4} : {4'd9, 6'd19};
            12'd2257 : ovl_ch = (sc_state == 2'd0) ? {4'd9, 6'd20} : (sc_state == 2'd1) ? {4'd4, 6'd12} : (sc_state == 2'd2) ? {4'd3, 6'd15} : {4'd9, 6'd20};
            12'd2258 : ovl_ch = (sc_state == 2'd0) ? {4'd9, 6'd15} : (sc_state == 2'd1) ? {4'd4, 6'd1} : (sc_state == 2'd2) ? {4'd3, 6'd14} : {4'd9, 6'd15};
            12'd2259 : ovl_ch = (sc_state == 2'd0) ? {4'd9, 6'd16} : (sc_state == 2'd1) ? {4'd4, 6'd25} : (sc_state == 2'd2) ? {4'd3, 6'd5} : {4'd9, 6'd16};
            12'd2260 : ovl_ch = (sc_state == 2'd0) ? {4'd9, 6'd0} : (sc_state == 2'd1) ? {4'd4, 6'd0} : (sc_state == 2'd2) ? {4'd3, 6'd0} : {4'd9, 6'd0};
            12'd2320 : ovl_ch = {4'd3, {3'b000, note_ltr}};
            12'd2321 : ovl_ch = (note_shp ? {4'd3, 6'd41} : {4'd3, (6'd27 + {2'b00, note_oct})});
            12'd2322 : ovl_ch = (note_shp ? {4'd3, (6'd27 + {2'b00, note_oct})} : {4'd3, 6'd0});
            12'd2380 : ovl_ch = {4'd3, ((note_pos >= 10'd100) ? 6'd28 : 6'd27)};
            12'd2381 : ovl_ch = {4'd3, ((((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27))};
            12'd2382 : ovl_ch = {4'd3, ((((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd9) ? 6'd36 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd8) ? 6'd35 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd7) ? 6'd34 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd6) ? 6'd33 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd5) ? 6'd32 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd4) ? 6'd31 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd3) ? 6'd30 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd2) ? 6'd29 : ((((note_pos)) - ({4'b0000, (((note_pos) >= 7'd90) ? 6'd36 : ((note_pos) >= 7'd80) ? 6'd35 : ((note_pos) >= 7'd70) ? 6'd34 : ((note_pos) >= 7'd60) ? 6'd33 : ((note_pos) >= 7'd50) ? 6'd32 : ((note_pos) >= 7'd40) ? 6'd31 : ((note_pos) >= 7'd30) ? 6'd30 : ((note_pos) >= 7'd20) ? 6'd29 : ((note_pos) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd1) ? 6'd28 : 6'd27))};
            12'd2383 : ovl_ch = {4'd3, 6'd38};
            12'd2384 : ovl_ch = {4'd3, ((note_total >= 10'd100) ? 6'd28 : 6'd27)};
            12'd2385 : ovl_ch = {4'd3, ((((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27))};
            12'd2386 : ovl_ch = {4'd3, ((((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd9) ? 6'd36 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd8) ? 6'd35 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd7) ? 6'd34 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd6) ? 6'd33 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd5) ? 6'd32 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd4) ? 6'd31 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd3) ? 6'd30 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd2) ? 6'd29 : ((((note_total)) - ({4'b0000, (((note_total) >= 7'd90) ? 6'd36 : ((note_total) >= 7'd80) ? 6'd35 : ((note_total) >= 7'd70) ? 6'd34 : ((note_total) >= 7'd60) ? 6'd33 : ((note_total) >= 7'd50) ? 6'd32 : ((note_total) >= 7'd40) ? 6'd31 : ((note_total) >= 7'd30) ? 6'd30 : ((note_total) >= 7'd20) ? 6'd29 : ((note_total) >= 7'd10) ? 6'd28 : 6'd27)} * 7'd10)) == 8'd1) ? 6'd28 : 6'd27))};
            12'd2529 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd3};
            12'd2530 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd12};
            12'd2531 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd9};
            12'd2532 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd3};
            12'd2533 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd11};
            12'd2534 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd37};
            12'd2535 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2536 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd12};
            12'd2537 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd15};
            12'd2538 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd3};
            12'd2539 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd11};
            12'd2540 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2541 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2542 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd8};
            12'd2543 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd15};
            12'd2544 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd12};
            12'd2545 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd4};
            12'd2546 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd37};
            12'd2547 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd0};
            12'd2548 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd8};
            12'd2549 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd15};
            12'd2550 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd13};
            12'd2551 : ovl_ch = (menu_sel == 4'd4) ? {4'd9, 6'd0} : {4'd9, 6'd5};
            12'd2585 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd5} : {4'd0, 6'd5};
            12'd2586 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd4} : {4'd0, 6'd4};
            12'd2587 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd9} : {4'd0, 6'd9};
            12'd2588 : ovl_ch = (menu_level == 2'd2) ? {4'd7, 6'd20} : {4'd0, 6'd20};
            12'd2640 : ovl_ch = {4'd6, tst_str[6 +: 6]};
            12'd2641 : ovl_ch = {4'd6, tst_str[0 +: 6]};
            12'd2704 : ovl_ch = {4'd3, (6'd27 + {2'b00, vt})};
            12'd2705 : ovl_ch = {4'd3, (6'd27 + {2'b00, vo})};
            12'd2706 : ovl_ch = {4'd3, 6'd38};
            12'd2707 : ovl_ch = {4'd3, 6'd30};
            12'd2708 : ovl_ch = {4'd3, 6'd29};
            12'd2832 : ovl_ch = (wave_sel == 3'd0) ? {4'd3, 6'd19} : (wave_sel == 3'd1) ? {4'd3, 6'd20} : (wave_sel == 3'd2) ? {4'd3, 6'd19} : (wave_sel == 3'd3) ? {4'd3, 6'd19} : (wave_sel == 3'd4) ? {4'd3, 6'd16} : (wave_sel == 3'd5) ? {4'd3, 6'd16} : (wave_sel == 3'd6) ? {4'd3, 6'd13} : (wave_sel == 3'd7) ? {4'd3, 6'd18} : {4'd3, 6'd19};
            12'd2833 : ovl_ch = (wave_sel == 3'd0) ? {4'd3, 6'd9} : (wave_sel == 3'd1) ? {4'd3, 6'd18} : (wave_sel == 3'd2) ? {4'd3, 6'd1} : (wave_sel == 3'd3) ? {4'd3, 6'd17} : (wave_sel == 3'd4) ? {4'd3, 6'd12} : (wave_sel == 3'd5) ? {4'd3, 6'd12} : (wave_sel == 3'd6) ? {4'd3, 6'd9} : (wave_sel == 3'd7) ? {4'd3, 6'd5} : {4'd3, 6'd9};
            12'd2834 : ovl_ch = (wave_sel == 3'd0) ? {4'd3, 6'd14} : (wave_sel == 3'd1) ? {4'd3, 6'd9} : (wave_sel == 3'd2) ? {4'd3, 6'd23} : (wave_sel == 3'd3) ? {4'd3, 6'd18} : (wave_sel == 3'd4) ? {4'd3, 6'd19} : (wave_sel == 3'd5) ? {4'd3, 6'd19} : (wave_sel == 3'd6) ? {4'd3, 6'd24} : (wave_sel == 3'd7) ? {4'd3, 6'd5} : {4'd3, 6'd14};
            12'd2835 : ovl_ch = (wave_sel == 3'd0) ? {4'd3, 6'd5} : (wave_sel == 3'd1) ? {4'd3, 6'd0} : (wave_sel == 3'd2) ? {4'd3, 6'd0} : (wave_sel == 3'd3) ? {4'd3, 6'd0} : (wave_sel == 3'd4) ? {4'd3, 6'd29} : (wave_sel == 3'd5) ? {4'd3, 6'd28} : (wave_sel == 3'd6) ? {4'd3, 6'd0} : (wave_sel == 3'd7) ? {4'd3, 6'd4} : {4'd3, 6'd5};
            12'd2836 : ovl_ch = (wave_sel == 3'd0) ? {4'd3, 6'd0} : (wave_sel == 3'd1) ? {4'd3, 6'd0} : (wave_sel == 3'd2) ? {4'd3, 6'd0} : (wave_sel == 3'd3) ? {4'd3, 6'd0} : (wave_sel == 3'd4) ? {4'd3, 6'd32} : (wave_sel == 3'd5) ? {4'd3, 6'd29} : (wave_sel == 3'd6) ? {4'd3, 6'd0} : (wave_sel == 3'd7) ? {4'd3, 6'd0} : {4'd3, 6'd0};
            12'd2837 : ovl_ch = (wave_sel == 3'd0) ? {4'd3, 6'd0} : (wave_sel == 3'd1) ? {4'd3, 6'd0} : (wave_sel == 3'd2) ? {4'd3, 6'd0} : (wave_sel == 3'd3) ? {4'd3, 6'd0} : (wave_sel == 3'd4) ? {4'd3, 6'd0} : (wave_sel == 3'd5) ? {4'd3, 6'd0} : (wave_sel == 3'd6) ? {4'd3, 6'd0} : (wave_sel == 3'd7) ? {4'd3, 6'd0} : {4'd3, 6'd0};
            12'd3041 : ovl_ch = {4'd9, 6'd18};
            12'd3042 : ovl_ch = {4'd9, 6'd15};
            12'd3043 : ovl_ch = {4'd9, 6'd20};
            12'd3044 : ovl_ch = {4'd9, 6'd1};
            12'd3045 : ovl_ch = {4'd9, 6'd20};
            12'd3046 : ovl_ch = {4'd9, 6'd5};
            12'd3047 : ovl_ch = {4'd9, 6'd37};
            12'd3048 : ovl_ch = {4'd9, 6'd0};
            12'd3049 : ovl_ch = {4'd9, 6'd28};
            12'd3050 : ovl_ch = {4'd9, 6'd40};
            12'd3051 : ovl_ch = {4'd9, 6'd40};
            12'd3052 : ovl_ch = {4'd9, 6'd30};
            12'd3053 : ovl_ch = {4'd9, 6'd29};
            12'd3054 : ovl_ch = {4'd9, 6'd0};
            12'd3055 : ovl_ch = {4'd9, 6'd0};
            12'd3056 : ovl_ch = {4'd9, 6'd0};
            12'd3057 : ovl_ch = {4'd9, 6'd8};
            12'd3058 : ovl_ch = {4'd9, 6'd15};
            12'd3059 : ovl_ch = {4'd9, 6'd12};
            12'd3060 : ovl_ch = {4'd9, 6'd4};
            12'd3061 : ovl_ch = {4'd9, 6'd37};
            12'd3062 : ovl_ch = {4'd9, 6'd0};
            12'd3063 : ovl_ch = {4'd9, 6'd8};
            12'd3064 : ovl_ch = {4'd9, 6'd15};
            12'd3065 : ovl_ch = {4'd9, 6'd13};
            12'd3066 : ovl_ch = {4'd9, 6'd5};
            default: begin ovl_en = 1'b0; ovl_ch = 10'd0; end
        endcase
    end

endmodule
