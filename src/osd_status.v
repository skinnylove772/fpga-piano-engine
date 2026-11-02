// osd_status.v —— RGB LCD 上的实时状态显示 (屏幕叠加)
module osd_status(
    input  wire        pclk,  // 9MHz 像素时钟
    input  wire        rst_n,
    //---- 视频时序 (来自 vga_timing) ----
    input  wire [9:0]  x,  // 有效像素坐标 0..479
    input  wire [9:0]  y,  // 0..271
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    //---- 系统状态 ----
    input  wire        test_active,  // 测试模式是否激活
    input  wire [5:0]  test_lvl,  // 测试档位 0/4/8/16/32
    input  wire [2:0]  wave_sel,  // 音色 0..7
    input  wire [5:0]  active_cnt,  // 活跃声部数
    input  wire [6:0]  cur_note,  // 最后触发的音符号
    input  wire [7:0]  dist_cm,
    input  wire        dist_tog,
    input  wire [3:0]  ges_idx,
    input  wire [1:0]  oct_idx,  //   八度档 0..3
    input  wire [7:0]  vel_ges,  //   力度档 80..240
    input  wire [2:0]  vib_ges,  //   颤音深度档 0..7
    input  wire        chorus_en,  //   合唱 开/关
    input  wire [7:0]  master_vol,
    input  wire [15:0] key_raw,
    //    这几个在 OSD 里还要打拍跨到 pclk 域。
    input  wire [3:0]  menu_sel,
    input  wire [1:0]  sc_sng,  // 当前选中的曲目
    input  wire [1:0]  sc_state,  // 0=停 1=播 2=完
    input  wire [9:0]  sc_pos,  // 进度
    input  wire [9:0]  sc_total,  // 总音数
    input  wire [1:0]  menu_level,  // 层级: 0=主菜单 1=选中(未锁定) 2=锁定(旋转=改值)
    input  wire [2:0]  enc_timbre,
    input  wire [1:0]  enc_octave,
    input  wire [7:0]  enc_volume,
    input  wire [2:0]  enc_vib,
    input  wire [2:0]  enc_chorus,
    input  wire [2:0]  enc_delay,
    input  wire [2:0]  enc_reverb,
    input  wire        enc_gesture,
    input  wire [2:0]  enc_glide,
    input  wire        enc_ctype,
    input  wire        enc_dtype,
    input  wire        enc_rtype,
    input  wire        enc_mode,
    input  wire        enc_on_timbre,
    input  wire        enc_on_octave,
    input  wire        enc_on_volume,
    input  wire        enc_on_vib,
    input  wire        enc_on_chorus,
    //   按优先级轮播, 一次只看得到一个, 查"手势不灵敏"时不够用 ——
    //   现在各占一个独立字段同屏显示。它们都是**慢变量** (初始化阶段标志 /
    //   累积计数 / 每次读手势才更新的原始字节), 打两拍跨域足够。
    input  wire [3:0]  paj_phase,  // 0=正常 1=唤醒 2=握手 3=写表 4=等稳定
    input  wire [3:0]  paj_rej,  // 被 one-hot 过滤挡掉的次数
    input  wire [3:0]  paj_ecnt,  // 连续读手势失败次数
    input  wire [5:0]  paj_fidx,  // 配置表失败序号 (63 = 没失败过)
    input  wire [7:0]  paj_g1,  // 0x43 原始字节
    input  wire [7:0]  paj_g2,  // 0x44 原始字节
    input  wire [7:0]  paj_wa0,  // 握手寄存器 0x00 读回值
    input  wire [3:0]  page,
    input  wire [31:0] vbusy,
    input  wire [7:0]  barval,  // 频谱: 当前段的值 (0..255)
    input  wire [2:0]  baridx,  // 频谱: 当前段号 0..7
    input  wire [1:0]  barlow,  // 频谱: 正在刷新的行 0..2
    input  wire [7:0]  bnd0,  // 频谱第 1 段保持值
    input  wire [7:0]  bnd1,  // 频谱第 2 段保持值
    input  wire [7:0]  bnd2,  // 频谱第 3 段保持值
    input  wire [7:0]  bnd3,  // 频谱第 4 段保持值
    input  wire [7:0]  bnd4,  // 频谱第 5 段保持值
    input  wire [7:0]  bnd5,  // 频谱第 6 段保持值
    input  wire [7:0]  bnd6,  // 频谱第 7 段保持值
    input  wire [7:0]  bnd7,  // 频谱第 8 段保持值
    input  wire [3:0]  sorow,  // 声部表: 正在刷新的行 0..6
    input  wire [1:0]  socol,  // 声部表: 正在刷新的组 0..3
    input  wire [6:0]  sonote,  // 声部表: 该声部音符号
    input  wire [7:0]  soenv,  // 声部表: 该声部包络
    input  wire        sobusy,  // 声部表: 该声部是否发声
    input  wire        aclk,  // 1.5MHz 音频时钟 (给李萨如的写口用)
    input  wire        atick,  // 每采样一个脉冲
    input  wire [7:0]  lis_x,  // X = 0 号声部相位高 8 位
    input  wire [7:0]  lis_y,  // Y = 1 号声部相位高 8 位 (单音时由 top.v 给正交副本)
    //---- 输出 ----
    output reg  [4:0]  r,
    output reg  [5:0]  g,
    output reg  [4:0]  b,
    output reg         hs_o,
    output reg         vs_o,
    output reg         de_o
);

    localparam [15:0] C_BG     = {5'h00, 6'h00, 5'h00};
    localparam [15:0] C_TITLE  = {5'h1C, 6'h38, 5'h1C};
    localparam [15:0] C_LABEL  = {5'h16, 6'h2C, 5'h16};
    //    必须和 gen_osd.py 的 COLORS[3] ('value') 完全一致 —— ROM 里 21 个
    //    字段共用色号 3, 这里改一个数就是全屏数值一起换色。
    localparam [15:0] C_VALUE  = {5'h1F, 6'h28, 5'h00};
    localparam [15:0] C_ACC    = {5'h00, 6'h2B, 5'h1F};
    localparam [15:0] C_ACC_D  = {5'h00, 6'h10, 5'h0C};
    localparam [15:0] C_TRACE  = {5'h00, 6'h3F, 5'h1F};
    localparam [15:0] C_FRAME  = {5'h0A, 6'h14, 5'h0A};
    localparam [15:0] C_DIM    = {5'h07, 6'h0E, 5'h07};
    localparam [15:0] C_ITEM   = {5'h14, 6'h28, 5'h14};
    localparam [15:0] C_FOCUS  = {5'h1F, 6'h3F, 5'h1F};
    //      在预览图上第一眼就指出来了。色号 13/14 在 gen_osd.py 的 COLORS 里,
    //      没有任何文字字段引用它们。
    localparam [15:0] C_TRACK  = {5'h00, 6'h06, 5'h05};
    localparam [15:0] C_ATRACK = {5'h08, 6'h05, 5'h00};

    localparam [15:0] C_RED    = {5'h1F, 6'h08, 5'h06};
    localparam [15:0] C_ORANGE = {5'h1F, 6'h12, 5'h00};
    localparam [15:0] C_CYAN   = {5'h00, 6'h38, 5'h1F};

    wire [4:0] ccol = x[8:4];  // 0..29  (30 列)
    wire [4:0] crow = y[8:4];  // 0..16  (17 行)
    wire [2:0] grow = y[3:1];  // 0..7
    wire [2:0] gcol = x[3:1];  // 0..7

    wire [3:0] trow = crow[3:0];
    wire       trow_ok = (crow < 5'd16);

    reg [3:0] trow_r;
    reg       trow_ok_r;
    reg [4:0] ccol_r;
    reg [2:0] grow_r, gcol_r;
    reg [9:0] x_r, y_r;
    reg       de_r, hs_r, vs_r;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            trow_r <= 4'd0; trow_ok_r <= 1'b0; ccol_r <= 5'd0;
            grow_r <= 3'd0; gcol_r <= 3'd0; x_r <= 10'd0; y_r <= 10'd0;
            de_r <= 1'b0; hs_r <= 1'b0; vs_r <= 1'b0;
        end else begin
            trow_r    <= trow;
            trow_ok_r <= trow_ok;
            ccol_r    <= ccol;
            grow_r    <= grow;
            gcol_r    <= gcol;
            x_r       <= x;
            y_r       <= y;
            de_r      <= de;
            hs_r      <= hs;
            vs_r      <= vs;
        end
    end

    wire [9:0] lbl_chd;
    osd_labels u_lbl (
        .addr ({page[2:0], trow_r, ccol_r}),
        .chd  (lbl_chd)
    );

    wire [2:0] note_ltr;
    wire       note_shp;
    wire [3:0] note_oct;
    note_name u_nn (
        .note (cur_note),
        .ltr  (note_ltr),
        .shp  (note_shp),
        .oct  (note_oct)
    );

    wire       ovl_en;
    wire [9:0] ovl_ch;

    reg        tog_s0, tog_s1, tog_s2;
    reg [7:0]  dist_sync;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            tog_s0    <= 1'b0;
            tog_s1    <= 1'b0;
            tog_s2    <= 1'b0;
            dist_sync <= 8'd200;
        end else begin
            tog_s0 <= dist_tog;
            tog_s1 <= tog_s0;
            tog_s2 <= tog_s1;
            if (tog_s1 != tog_s2)  // 检测到边沿 = 音频域刚更新完
                dist_sync <= dist_cm;  // 此刻 dist_cm 已经稳定
        end
    end

    reg [3:0] ges_s0, ges_s1;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            ges_s0 <= 4'd0;
            ges_s1 <= 4'd0;
        end else begin
            ges_s0 <= ges_idx;
            ges_s1 <= ges_s0;
        end
    end

    //==== 演奏参数面板的跨时钟域同步 ====
    //   这四个值由 top.v 在 **3MHz 音频域** 里产生 (手势改的就是它们),
    //   而本模块跑在 pclk (9MHz)。和 ges_idx 同一个道理, 也同一个做法:
    //   它们是"人做一次手势才变一次"的量 (稳定 100ms 以上), 打两拍足够,
    //   既不会亚稳态, 也不可能采到半新半旧的组合。
    reg [1:0] oct_s0, oct_s1;
    reg [7:0] vel_s0, vel_s1;
    reg [2:0] vib_s0, vib_s1;
    reg       cho_s0, cho_s1;
    reg [2:0] mch_s0, mch_s1;  // enc_chorus 的两拍同步 (3 位)
    reg [2:0] mdl_s0, mdl_s1;  // enc_delay
    reg [2:0] mrv_s0, mrv_s1;  // enc_reverb
    reg       mgc_s0, mgc_s1;
    reg [2:0] mgl_s0, mgl_s1;
    reg       mct_s0, mct_s1;
    reg       mdt_s0, mdt_s1;
    reg       mrt_s0, mrt_s1;
    reg       mmd_s0, mmd_s1;
    reg [7:0] mvol_s0, mvol_s1;
    reg [15:0] krw_s0, krw_s1;
    reg [3:0] pph_s0, pph_s1;
    reg [3:0] prj_s0, prj_s1;
    reg [3:0] pec_s0, pec_s1;
    reg [5:0] pfi_s0, pfi_s1;
    reg [7:0] pg1_s0, pg1_s1;
    reg [7:0] pg2_s0, pg2_s1;
    reg [7:0] pwa_s0, pwa_s1;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            oct_s0 <= 2'd0;           oct_s1 <= 2'd0;
            vel_s0 <= 8'd200;         vel_s1 <= 8'd200;
            vib_s0 <= 3'd0;           vib_s1 <= 3'd0;
            cho_s0 <= 1'b1;           cho_s1 <= 1'b1;
            mvol_s0 <= 8'd216;        mvol_s1 <= 8'd216;
            krw_s0 <= 16'd0;          krw_s1 <= 16'd0;
            pph_s0 <= 4'd0;           pph_s1 <= 4'd0;
            prj_s0 <= 4'd0;           prj_s1 <= 4'd0;
            pec_s0 <= 4'd0;           pec_s1 <= 4'd0;
            pfi_s0 <= 6'd63;          pfi_s1 <= 6'd63;
            pg1_s0 <= 8'd0;           pg1_s1 <= 8'd0;
            pg2_s0 <= 8'd0;           pg2_s1 <= 8'd0;
            pwa_s0 <= 8'd0;           pwa_s1 <= 8'd0;
        end else begin
            oct_s0 <= oct_idx;        oct_s1 <= oct_s0;
            vel_s0 <= vel_ges;        vel_s1 <= vel_s0;
            vib_s0 <= vib_ges;        vib_s1 <= vib_s0;
            cho_s0 <= chorus_en;      cho_s1 <= cho_s0;
        mvol_s0 <= master_vol;    mvol_s1 <= mvol_s0;
            krw_s0 <= key_raw;        krw_s1 <= krw_s0;
            pph_s0 <= paj_phase;      pph_s1 <= pph_s0;
            prj_s0 <= paj_rej;        prj_s1 <= prj_s0;
            pec_s0 <= paj_ecnt;       pec_s1 <= pec_s0;
            pfi_s0 <= paj_fidx;       pfi_s1 <= pfi_s0;
            pg1_s0 <= paj_g1;         pg1_s1 <= pg1_s0;
            pg2_s0 <= paj_g2;         pg2_s1 <= pg2_s0;
            pwa_s0 <= paj_wa0;        pwa_s1 <= pwa_s0;
        end
    end

    reg [3:0]  mse_s0, mse_s1;
    reg [1:0]  mlv_s0, mlv_s1;
    reg [3:0]  pge_s0, pge_s1;
    reg [1:0]  sng_s0, sng_s1;
    reg [1:0]  sst_s0, sst_s1;
    reg [9:0]  spo_s0, spo_s1;
    reg [9:0]  stt_s0, stt_s1;
    reg [2:0]  mti_s0, mti_s1;
    reg [1:0]  moc_s0, moc_s1;
    reg [7:0]  mvo_s0, mvo_s1;
    reg [2:0]  mvi_s0, mvi_s1;
    reg        mot_s0, mot_s1, moo_s0, moo_s1, mov_s0, mov_s1, movb_s0, movb_s1, mocb_s0, mocb_s1;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            mse_s0 <= 4'd0; mse_s1 <= 4'd0;
            mlv_s0 <= 2'd0; mlv_s1 <= 2'd0;
            pge_s0 <= 4'd0; pge_s1 <= 4'd0;
            sng_s0 <= 2'd0; sng_s1 <= 2'd0;
            sst_s0 <= 2'd0; sst_s1 <= 2'd0;
            spo_s0 <= 10'd0; spo_s1 <= 10'd0;
            stt_s0 <= 10'd0; stt_s1 <= 10'd0;
            mti_s0 <= 3'd0; mti_s1 <= 3'd0;
            moc_s0 <= 2'd0; moc_s1 <= 2'd0;
            mvo_s0 <= 8'd216; mvo_s1 <= 8'd216;
            mvi_s0 <= 3'd0; mvi_s1 <= 3'd0;
            mch_s0 <= 1'b0; mch_s1 <= 1'b0;
            mot_s0 <= 1'b0; mot_s1 <= 1'b0;
            moo_s0 <= 1'b0; moo_s1 <= 1'b0;
            mov_s0 <= 1'b0; mov_s1 <= 1'b0;
            movb_s0 <= 1'b0; movb_s1 <= 1'b0;
            mocb_s0 <= 1'b0; mocb_s1 <= 1'b0;

            mdl_s0 <= 1'b1;           mdl_s1 <= 1'b1;
            mrv_s0 <= 1'b1;           mrv_s1 <= 1'b1;
            mgc_s0 <= 1'b1;           mgc_s1 <= 1'b1;
            mmd_s0 <= 1'b0;           mmd_s1 <= 1'b0;
        end else begin
            mse_s0 <= menu_sel;       mse_s1 <= mse_s0;
            mlv_s0 <= menu_level;     mlv_s1 <= mlv_s0;
            pge_s0 <= page;           pge_s1 <= pge_s0;
            sng_s0 <= sc_sng;         sng_s1 <= sng_s0;
            sst_s0 <= sc_state;       sst_s1 <= sst_s0;
            spo_s0 <= sc_pos;         spo_s1 <= spo_s0;
            stt_s0 <= sc_total;       stt_s1 <= stt_s0;
            mti_s0 <= enc_timbre;     mti_s1 <= mti_s0;
            moc_s0 <= enc_octave;     moc_s1 <= moc_s0;
            mvo_s0 <= enc_volume;     mvo_s1 <= mvo_s0;
            mvi_s0 <= enc_vib;        mvi_s1 <= mvi_s0;
            mch_s0 <= enc_chorus;     mch_s1 <= mch_s0;
            mdl_s0 <= enc_delay;      mdl_s1 <= mdl_s0;
            mrv_s0 <= enc_reverb;     mrv_s1 <= mrv_s0;
            mgc_s0 <= enc_gesture;    mgc_s1 <= mgc_s0;
            mgl_s0 <= enc_glide;      mgl_s1 <= mgl_s0;
            mct_s0 <= enc_ctype;      mct_s1 <= mct_s0;
            mdt_s0 <= enc_dtype;      mdt_s1 <= mdt_s0;
            mrt_s0 <= enc_rtype;      mrt_s1 <= mrt_s0;
            mmd_s0 <= enc_mode;       mmd_s1 <= mmd_s0;
            mot_s0 <= enc_on_timbre;  mot_s1 <= mot_s0;
            moo_s0 <= enc_on_octave;  moo_s1 <= moo_s0;
            mov_s0 <= enc_on_volume;  mov_s1 <= mov_s0;
            movb_s0 <= enc_on_vib;    movb_s1 <= movb_s0;
            mocb_s0 <= enc_on_chorus; mocb_s1 <= mocb_s0;
        end
    end

    osd_overlay u_ovl (
        .page        (page),
        .trow        (trow_r),
        .ccol        (ccol_r),
        .test_active (test_active),
        .test_lvl    (test_lvl),
        .wave_sel    (wave_sel),
        .active_cnt  (active_cnt),
        .note_ltr    (note_ltr),
        .note_shp    (note_shp),
        .note_oct    (note_oct),
        .dist_cm     (dist_sync),
        .ges_idx     (ges_s1),
        .oct_idx     (oct_s1),
        .vel_ges     (vel_s1),
        .vib_ges     (vib_s1),
        .chorus_en   (cho_s1),
        .master_vol  (mvol_s1),
        .key_raw     (krw_s1),
        .menu_sel      (mse_s1),
        .menu_level    (mlv_s1),
        .sng_sel       (sng_s1),
        .sc_state      (sst_s1),
        .note_pos      (spo_s1),
        .note_total    (stt_s1),
        .enc_timbre    (mti_s1),
        .enc_octave    (moc_s1),
        .enc_volume    (mvo_s1),
        .enc_vib       (mvi_s1),
        .enc_chorus    (mch_s1),
        .enc_delay     (mdl_s1),
        .enc_reverb    (mrv_s1),
    .enc_gesture   (mgc_s1),
    .enc_glide     (mgl_s1),
    .enc_ctype     (mct_s1),
    .enc_dtype     (mdt_s1),
    .enc_rtype     (mrt_s1),
        .enc_mode      (mmd_s1),
        .enc_on_timbre (mot_s1),
        .enc_on_octave (moo_s1),
        .enc_on_volume (mov_s1),
        .enc_on_vib    (movb_s1),
        .enc_on_chorus (mocb_s1),
        .paj_phase   (pph_s1),
        .paj_rej     (prj_s1),
        .paj_ecnt    (pec_s1),
        .paj_fidx    (pfi_s1),
        .paj_g1      (pg1_s1),
        .paj_g2      (pg2_s1),
        .paj_wa0     (pwa_s1),
        .sobusy      (sobusy),
        .sonote      (sonote),
        .soenv       (soenv),
        .sorow       (sorow),
        .socol       (socol),
        .barval      (barval),
        .baridx      (baridx),
        .barlow      (barlow),
        .ovl_en      (ovl_en),
        .ovl_ch      (ovl_ch)
    );

    //  叠加层优先; 页面外 (trow_ok_r=0) 全黑
    wire [9:0] chd_w = (trow_ok_r && ovl_en) ? ovl_ch :
                       (trow_ok_r           ) ? lbl_chd : 10'd0;
    wire       chr_on = trow_ok_r && (chd_w[5:0] != 6'd0);
    wire [5:0] ch_w   = chd_w[5:0];
    wire [3:0] col_w  = chd_w[9:6];

    reg [5:0] ch_r;
    reg [3:0] col_r;
    reg [2:0] grow_r2, gcol_r2;
    reg [9:0] x_r2, y_r2;
    reg       de_r2, hs_r2, vs_r2;
    reg [3:0] trow_r2;
    reg [4:0] ccol_r2;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            ch_r <= 6'd0; col_r <= 4'd0; grow_r2 <= 3'd0; gcol_r2 <= 3'd0;
            x_r2 <= 10'd0; y_r2 <= 10'd0;
            de_r2 <= 1'b0; hs_r2 <= 1'b0; vs_r2 <= 1'b0;
            trow_r2 <= 4'd0; ccol_r2 <= 5'd0;
        end else begin
            ch_r    <= ch_w;
            col_r   <= col_w;
            grow_r2 <= grow_r;
            gcol_r2 <= gcol_r;
            x_r2    <= x_r;
            y_r2    <= y_r;
            de_r2   <= de_r;
            hs_r2   <= hs_r;
            vs_r2   <= vs_r;
            trow_r2 <= trow_r;
            ccol_r2 <= ccol_r;
        end
    end

    wire [2:0] frow = grow_r2;
    wire [4:0] fbits;
    font5x7 u_font (
        .addr    ({ch_r, frow}),
        .rowbits (fbits)
    );

    reg [4:0] fbits_r;
    reg [2:0] gcol_r3;
    reg [9:0] x_r3, y_r3;
    reg       de_r3, hs_r3, vs_r3;
    reg [3:0] trow_r3;
    reg [4:0] ccol_r3;
    reg [3:0] col_r3;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            fbits_r <= 5'd0; gcol_r3 <= 3'd0; x_r3 <= 10'd0; y_r3 <= 10'd0;
            de_r3 <= 1'b0; hs_r3 <= 1'b0; vs_r3 <= 1'b0;
            trow_r3 <= 4'd0; ccol_r3 <= 5'd0; col_r3 <= 4'd0;
        end else begin
            fbits_r <= fbits;
            gcol_r3 <= gcol_r2;
            x_r3    <= x_r2;
            y_r3    <= y_r2;
            de_r3   <= de_r2;
            hs_r3   <= hs_r2;
            vs_r3   <= vs_r2;
            trow_r3 <= trow_r2;
            ccol_r3 <= ccol_r2;
            col_r3  <= col_r;
        end
    end

    //---- 字模取像素 ----
    //    字模列 cc 占 gcol = 1..5 (gcol=0/6/7 是空白边距), 位序 bit4 在最左。
    //    取像素 = fbits[5 - gcol]: gcol=1 -> bit4 (最左列), gcol=5 -> bit0 (最右列)。
    wire chpix = (gcol_r3 >= 3'd1) && (gcol_r3 <= 3'd5)
               ? fbits_r[3'd5 - gcol_r3] : 1'b0;
    //---- 文字颜色 ----
    //    一加分页就完全不适用了 —— 每页的第 0 行都该是标题色, 第 4 行在有些页
    //    是数值、有些页是标签, 没法用行号判断。颜色跟着字符走才是对的做法。
    reg [15:0] c_text;
    always @* begin
        case (col_r3)
            4'd1:    c_text = C_TITLE;  //  1 title  : 亮白 88%
            4'd2:    c_text = C_LABEL;  //  2 label  : 柔白 68%
            4'd3:    c_text = C_VALUE;  //  3 value  : 琥珀 (数值/读数)
            4'd4:    c_text = C_ACC;  //  4 green  : 青 (状态/填充)
            4'd5:    c_text = C_RED;
            4'd6:    c_text = C_ORANGE;
            4'd7:    c_text = C_CYAN;
            4'd8:    c_text = C_DIM;  //  8 gray   : 暗灰
            4'd9:    c_text = C_DIM;  //  9 dim    : 暗灰 22% (提示/面包屑)
            4'd10:   c_text = C_FOCUS;  // 10 hi     : 纯白 (焦点/箭头)
            4'd12:   c_text = C_ITEM;  // 12 item   : 柔白 63% (未选中菜单项)
            //    落到 default。以后加字段要什么色, 在这里加一行就行。
            default: c_text = C_LABEL;
        endcase
    end

    //---- 底部 30 格声部数条 ----
    wire [9:0] bmul      = active_cnt * 6'd15 + 6'd8;
    wire [4:0] bar_cells = bmul[8:4];
    wire [4:0] bar_cell  = x_r3[8:4];
    wire       in_bar    = (y_r3 >= 10'd256);
    wire       bar_gap   = (x_r3[3:0] == 4'd0) || (x_r3[3:0] == 4'd15);

    wire       in_vdot = (y_r3 >= 10'd208) && (y_r3 <= 10'd239) &&
                         (x_r3 >= 10'd16 ) && (x_r3 <= 10'd271);
    wire [3:0] vcol    = x_r3[7:4] - 4'd1;  // 16..271 -> 0..15
    wire [4:0] vidx    = {y_r3[4], vcol};  // 0..31
    wire       vdot_on = vbusy[vidx];
    //  格内 12x12 画小方块, 留 4px 隔缝
    wire       vdot_px = in_vdot && (x_r3[3:0] < 4'd12) && (y_r3[3:0] < 4'd12) && vdot_on;

    wire        lis_on_raw;
    wire [9:0]  lx10 = x_r3 - 10'd342;
    wire [9:0]  ly10 = y_r3 - 10'd96;
    wire        in_lis = (x_r3 >= 10'd342) && (x_r3 < 10'd470) &&
                         (y_r3 >= 10'd96)  && (y_r3 < 10'd224);

    lissajous u_lis (
        .aclk  (aclk),
        .arst_n(rst_n),
        .tick  (atick),
        .phx   (lis_x),
        .phy   (lis_y),
        .vclk  (pclk),
        .vrst_n(rst_n),
        .px    (lx10[6:0]),  // 显存 128x128, 直接对应窗口坐标
        .py    (ly10[6:0]),
        .on    (lis_on_raw)
    );
    reg in_lis_r;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) in_lis_r <= 1'b0;
        else        in_lis_r <= in_lis;
    end

    //---- 李萨如窗口的背景网格 + 中心十字 ----
    //   光秃秃的背景上一根细线很难判断形状, 加上网格和十字之后
    //   一眼就能看出"这是个椭圆还是个 8 字、张开多大"。
    //   网格按 16 像素一格, 十字在窗口正中。
    //   (网格直接用 x_r3/y_r3 算, 和轨迹差 1 拍 —— 网格是规则图案, 差一像素看不出来)
    wire lis_grid = (lx10[3:0] == 4'd0) || (ly10[3:0] == 4'd0);
    wire lis_cross = (lx10 == 10'd64) || (ly10 == 10'd64);

    wire [4:0] sel_x2   = {2'b00, mse_s1} + {2'b00, mse_s1};  // menu_sel*2, <=12
    wire [4:0] sel_x3   = {2'b00, mse_s1} + {1'b0, mse_s1, 1'b0};  // menu_sel*3 (HOME 用)
    wire [4:0] sel_x1   = {2'b00, mse_s1};
    wire [4:0] sel_use  = (pge_s1 == 4'd0) ? sel_x3
                        : (pge_s1 == 4'd4) ? sel_x2
                        :                    sel_x1;
    wire [3:0] tgt_row  = sel_use[3:0] + 4'd2;
    //    (参数 3 / 曲谱 4 / 测试 5)。曲谱页的可调项只有 SONG (行 2)、
    //    测试页只有 LEVEL (行 2), 两页的 menu_sel 恒为 0 -> tgt_row 恒为 2,
    wire       show_focus = (pge_s1 == 4'd0) || (pge_s1 == 4'd3) ||
                            (pge_s1 == 4'd4) || (pge_s1 == 4'd5);

    //  行号 -> 像素 y (行*16), 焦点条顶 = 行*16 - 8 (条高 32, 行距 48)
    //      条 y = 行*16-8 .. 行*16+23, 上下各留 16 像素给相邻行 —— 不打架。
    wire [9:0] foc_row_px = {6'd0, tgt_row} << 4;  // 行*16, 10 位
    wire       is_param   = (pge_s1 == 4'd3);
    wire [9:0] foc_top    = is_param ? (foc_row_px - 10'd1)  // 14px 居中: 8-7 = +1 ≈ -1
                                  : (foc_row_px - 10'd8);  // 32px 居中
    wire [9:0] foc_h      = is_param ? 10'd14 : 10'd32;

    function [3:0] corner_dx;
        input [3:0] r;
        input [3:0] dy;
        begin
            case ({r, dy})
            //  r=2, rm1=1
            8'h21: corner_dx = 4'd0;
            //  r=4, rm1=3
            8'h41: corner_dx = 4'd2;
            8'h42: corner_dx = 4'd2;
            8'h43: corner_dx = 4'd0;
            //  r=5, rm1=4
            8'h51: corner_dx = 4'd3;
            8'h52: corner_dx = 4'd3;
            8'h53: corner_dx = 4'd2;
            8'h54: corner_dx = 4'd0;
            //  r=6, rm1=5
            8'h61: corner_dx = 4'd4;
            8'h62: corner_dx = 4'd4;
            8'h63: corner_dx = 4'd4;
            8'h64: corner_dx = 4'd3;
            8'h65: corner_dx = 4'd0;
            //  r=8, rm1=7
            8'h81: corner_dx = 4'd6;
            8'h82: corner_dx = 4'd6;
            8'h83: corner_dx = 4'd6;
            8'h84: corner_dx = 4'd5;
            8'h85: corner_dx = 4'd4;
            8'h86: corner_dx = 4'd3;
            8'h87: corner_dx = 4'd0;
            //  其他 (角区外或未用半径): 不限制
            default: corner_dx = 4'd15;
            endcase
        end
    endfunction

    function rbox;
        input [9:0] x, y, x0, y0;
        input [9:0] w;
        input [9:0] h;
        input [3:0] r;
        begin
            rbox = (x >= x0) && (x <= x0 + w - 10'd1) &&
                   (y >= y0) && (y <= y0 + h - 10'd1);
        end
    endfunction

    //---- 页面门控 (用两级同步副本 pge_s1, 与文字一致) ----
    wire show_scope = (pge_s1 == 4'd2);  // GRAPH 页

    //---- 页眉分隔线: 每页标题行下 y=16 (x 4..475) ----
    wire sep_on = (y_r3 == 10'd16) && (x_r3 >= 10'd4) && (x_r3 <= 10'd475);

    //---- 标题强调线: y=18, x 4..99, 青色 ----
    //     它把"标题行"和"内容区"在视觉上钉在一起 —— 这是 kk_ui 的排版锚点。
    wire tacc_on = (y_r3 == 10'd18) && (x_r3 >= 10'd4) && (x_r3 <= 10'd99);

    wire in_card_o = rbox(x_r3, y_r3, 10'd4, 10'd24, 10'd472, 10'd216, 4'd6);
    wire in_card_i = rbox(x_r3, y_r3, 10'd5, 10'd25, 10'd470, 10'd214, 4'd5);
    wire card_edge = in_card_o && !in_card_i;

    //---- 四角刻度: 从卡片四个角沿边内缩 1..8 像素的青色短线 ----
    //   kk_ui 的"角标"—— 圆角把角落挖空了 6 像素, 这两小段青线正好补在
    //   缺口附近, 让框看起来是"钉在四个角上"的。
    wire tick_on = (((y_r3 == 10'd24) || (y_r3 == 10'd239)) &&
                    (((x_r3 >= 10'd5) && (x_r3 <= 10'd12)) ||
                     ((x_r3 >= 10'd467) && (x_r3 <= 10'd474)))) ||
                   (((x_r3 == 10'd4) || (x_r3 == 10'd475)) &&
                    (((y_r3 >= 10'd25) && (y_r3 <= 10'd32)) ||
                     ((y_r3 >= 10'd231) && (y_r3 <= 10'd238))));

    wire       foc_edit = (mlv_s1 == 2'd2);
    wire       in_focus = show_focus &&
                          rbox(x_r3, y_r3, 10'd4, foc_top, 10'd472, foc_h, 4'd6);

    //---- GRAPH 页: 李萨如窗口外圈面板框 (r=8, 2px 厚) ----
    //     声部数条 (y>=256) 留重叠 —— 框线一旦压进条区, 会从
    //     条间黑缝里漏出碎虚线。
    wire in_pnl_o = rbox(x_r3, y_r3, 10'd336, 10'd90, 10'd140, 10'd140, 4'd8);
    wire in_pnl_i = rbox(x_r3, y_r3, 10'd338, 10'd92, 10'd136, 10'd136, 4'd6);
    wire lis_panel = show_scope && in_pnl_o && !in_pnl_i;

    //---- MAIN 页音量条 (行 10: y 164..171, x 224..463) ----
    //   kk_ui 式: 圆角描边 + 内缩 2px 填充。填充像素数查表 (21 档),
    //   不做除法/乘法 (DSP 纪律)。行 10 的文字 (VOLUME + 数字, x16..191)
    //   在条区之外, 不重叠。
    wire volbar_on = (pge_s1 == 4'd1);
    wire in_vol_o  = rbox(x_r3, y_r3, 10'd224, 10'd164, 10'd240, 10'd8, 4'd4);
    wire in_vol_i  = rbox(x_r3, y_r3, 10'd226, 10'd166, 10'd236, 10'd4, 4'd2);
    wire [4:0] vol_lvl = (mvo_s1 < 8'd88 ) ? 5'd0  :
                         (mvo_s1 > 8'd248) ? 5'd20 :
                         ((mvo_s1 - 8'd88) >> 3);  // 88..248 -> 0..20
    reg  [8:0] vol_fill;
    always @* begin
        case (vol_lvl)
            5'd0:  vol_fill = 9'd0;
            5'd1:  vol_fill = 9'd12;
            5'd2:  vol_fill = 9'd24;
            5'd3:  vol_fill = 9'd35;
            5'd4:  vol_fill = 9'd47;
            5'd5:  vol_fill = 9'd59;
            5'd6:  vol_fill = 9'd71;
            5'd7:  vol_fill = 9'd83;
            5'd8:  vol_fill = 9'd94;
            5'd9:  vol_fill = 9'd106;
            5'd10: vol_fill = 9'd118;
            5'd11: vol_fill = 9'd130;
            5'd12: vol_fill = 9'd142;
            5'd13: vol_fill = 9'd153;
            5'd14: vol_fill = 9'd165;
            5'd15: vol_fill = 9'd177;
            5'd16: vol_fill = 9'd189;
            5'd17: vol_fill = 9'd201;
            5'd18: vol_fill = 9'd212;
            5'd19: vol_fill = 9'd224;
            default: vol_fill = 9'd236;
        endcase
    end
    //    宽 = vol_fill (0..236), r=2, 与内框同几何 —— 角像素露出描边色。
    wire vol_fill_on = (pge_s1 == 4'd1) &&
                       rbox(x_r3, y_r3, 10'd226, 10'd166,
                            {1'b0, vol_fill}, 10'd4, 4'd2);

    //---- TEST 页声部数条 (行 6: y 100..107, x 224..463) ----
    //   填充随 active_cnt 0..32, 33 项查表 (公式 (236*v+16)/32)。
    wire tstbar_on = (pge_s1 == 4'd5);
    wire in_tst_o  = rbox(x_r3, y_r3, 10'd224, 10'd100, 10'd240, 10'd8, 4'd4);
    wire in_tst_i  = rbox(x_r3, y_r3, 10'd226, 10'd102, 10'd236, 10'd4, 4'd2);
    reg  [8:0] tst_fill;
    always @* begin
        case (active_cnt)
            6'd0:  tst_fill = 9'd0;
            6'd1:  tst_fill = 9'd7;
            6'd2:  tst_fill = 9'd15;
            6'd3:  tst_fill = 9'd22;
            6'd4:  tst_fill = 9'd30;
            6'd5:  tst_fill = 9'd37;
            6'd6:  tst_fill = 9'd44;
            6'd7:  tst_fill = 9'd52;
            6'd8:  tst_fill = 9'd59;
            6'd9:  tst_fill = 9'd66;
            6'd10: tst_fill = 9'd74;
            6'd11: tst_fill = 9'd81;
            6'd12: tst_fill = 9'd89;
            6'd13: tst_fill = 9'd96;
            6'd14: tst_fill = 9'd103;
            6'd15: tst_fill = 9'd111;
            6'd16: tst_fill = 9'd118;
            6'd17: tst_fill = 9'd125;
            6'd18: tst_fill = 9'd133;
            6'd19: tst_fill = 9'd140;
            6'd20: tst_fill = 9'd148;
            6'd21: tst_fill = 9'd155;
            6'd22: tst_fill = 9'd162;
            6'd23: tst_fill = 9'd170;
            6'd24: tst_fill = 9'd177;
            6'd25: tst_fill = 9'd184;
            6'd26: tst_fill = 9'd192;
            6'd27: tst_fill = 9'd199;
            6'd28: tst_fill = 9'd207;
            6'd29: tst_fill = 9'd214;
            6'd30: tst_fill = 9'd221;
            6'd31: tst_fill = 9'd229;
            default: tst_fill = 9'd236;
        endcase
    end
    wire tst_fill_on = (pge_s1 == 4'd5) &&
                       rbox(x_r3, y_r3, 10'd226, 10'd102,
                            {1'b0, tst_fill}, 10'd4, 4'd2);

    //---- 通用圆角条判定 (x 344..463, w=120, h=8, r=4, 内缩 2 -> 内宽 116) ----
    //  返回: 0=条外  1=描边  2=空槽  3=填充
    function [1:0] ibar;
        input [9:0] x, y, y0;
        input [7:0] fill;
        reg in_o, in_i, in_f;
        begin
            in_o = rbox(x, y, 10'd344, y0, 10'd120, 10'd8, 4'd4);
            in_i = rbox(x, y, 10'd346, y0 + 10'd2, 10'd116, 10'd4, 4'd2);
            in_f = (fill != 8'd0) &&
                   rbox(x, y, 10'd346, y0 + 10'd2, {2'b00, fill}, 10'd4, 4'd2);
            ibar = (!in_o) ? 2'd0 : (in_i ? (in_f ? 2'd3 : 2'd2) : 2'd1);
        end
    endfunction

    function lamp_on;
        input [9:0] x, y, cx, cy;
        reg [3:0] dx, dy;
        reg [5:0] mask;
        reg inb;
        begin
            inb = (x >= cx - 10'd5) && (x <= cx + 10'd5) &&
                  (y >= cy - 10'd5) && (y <= cy + 10'd5);
            dx  = (x < cx) ? (cx - x) : (x - cx);  // 框内 -> dx,dy 必 <= 5
            dy  = (y < cy) ? (cy - y) : (y - cy);
            case (dy)
                4'd0:                mask = 6'b111111;
                4'd1, 4'd2, 4'd3:    mask = 6'b011111;
                4'd4:                mask = 6'b001111;
                4'd5:                mask = 6'b000001;
                default:             mask = 6'b000000;
            endcase
            lamp_on = inb && mask[dx];
        end
    endfunction

    //---- 仪表条的行号: 由 y 反推行 (行距 32, 条高 8) ----
    //  ib_y = 36 + 32*idx  ->  行 2/4/6/8/10/12/14
    wire [2:0] ib_ridx = (y_r3 < 10'd68 ) ? 3'd0 :
                         (y_r3 < 10'd100) ? 3'd1 :
                         (y_r3 < 10'd132) ? 3'd2 :
                         (y_r3 < 10'd164) ? 3'd3 :
                         (y_r3 < 10'd196) ? 3'd4 :
                         (y_r3 < 10'd228) ? 3'd5 : 3'd6;
    wire [9:0] ib_y    = 10'd36 + {2'b00, ib_ridx, 5'b00000};  // 36 + 32*idx

    reg  [6:0]  nt_s0, nt_s1;  // cur_note 两拍同步
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin nt_s0 <= 7'd60; nt_s1 <= 7'd60; end
        else        begin nt_s0 <= cur_note; nt_s1 <= nt_s0; end
    end
    wire [14:0] nt15 = {8'd0, nt_s1};
    wire [14:0] pit_n = (nt15 << 7) - (nt15 << 3) - (nt15 << 2);
    wire [7:0]  pit_fill = pit_n[14:7];  // 0..115

    wire [11:0] ac12 = {6'd0, active_cnt};
    wire [11:0] voi_n = (ac12 << 7) - (ac12 << 3) - (ac12 << 2);
    wire [7:0]  voi_fill = voi_n[11:5];  // 0..116

    wire [15:0] ve16 = {8'd0, vel_s1};
    wire [15:0] vel_n = (ve16 << 7) - (ve16 << 3) - (ve16 << 2);
    wire [7:0]  vel_fill = vel_n[15:8];  // 0..115

    wire [11:0] vb12 = {8'd0, vib_s1} + 12'd1;  // 1..8
    wire [11:0] vib_n = (vb12 << 7) - (vb12 << 3) - (vb12 << 2);
    wire [7:0]  vib_fill = vib_n[10:3];  // 14..116

    wire [9:0]  dv_p   = spo_s1;  // note_pos
    wire [9:0]  dv_t   = (stt_s1 == 10'd0) ? 10'd1 : stt_s1;  // 防除零
    wire [17:0] dv_num = ({8'd0, dv_p} << 7) - ({8'd0, dv_p} << 3) -
                         ({8'd0, dv_p} << 2);
    wire [19:0] dv_key = {dv_p, dv_t};  // 变化检测

    reg  [19:0] dv_key_r;
    reg  [4:0]  dv_cnt;
    reg  [17:0] dv_n;
    reg  [10:0] dv_rem;
    reg  [17:0] dv_quo;
    reg         dv_run;
    reg  [7:0]  prg_fill;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            dv_key_r <= 20'd0; dv_cnt <= 5'd0; dv_n <= 18'd0;
            dv_rem <= 11'd0; dv_quo <= 18'd0; dv_run <= 1'b0;
            prg_fill <= 8'd0;
        end else if (!dv_run) begin
            if (dv_key != dv_key_r) begin  // 值变了 -> 重算一遍
                dv_key_r <= dv_key;
                dv_n     <= dv_num;
                dv_rem   <= 11'd0;
                dv_quo   <= 18'd0;
                dv_cnt   <= 5'd18;
                dv_run   <= 1'b1;
            end
        end else begin
            if ({dv_rem[9:0], dv_n[17]} >= {1'b0, dv_t}) begin
                dv_rem <= {dv_rem[9:0], dv_n[17]} - {1'b0, dv_t};
                dv_quo <= {dv_quo[16:0], 1'b1};
            end else begin
                dv_rem <= {dv_rem[9:0], dv_n[17]};
                dv_quo <= {dv_quo[16:0], 1'b0};
            end
            dv_n  <= {dv_n[16:0], 1'b0};
            dv_cnt <= dv_cnt - 5'd1;
            if (dv_cnt == 5'd1) begin  // 这一步是最后一步
                dv_run <= 1'b0;
                //    但 pos 万一超过 total 商可能很大, 夹一下免得条画到屏外。
                prg_fill <= (dv_quo > 18'd116) ? 8'd116 : dv_quo[7:0];
            end
        end
    end

    //---- 哪一行用哪个填充值 (按页选) ----
    //  行: 1=行4(y68) 2=行6(y100) 3=行8(y132) 5=行12(y196)
    reg [7:0] ib_fill;
    always @* begin
        case (pge_s1)
            4'd1: case (ib_ridx)  // MAIN
                      3'd1:    ib_fill = pit_fill;
                      3'd3:    ib_fill = voi_fill;
                      3'd5:    ib_fill = vel_fill;
                      3'd6:    ib_fill = vib_fill;
                      default: ib_fill = 8'd0;
                  endcase
            4'd4: case (ib_ridx)  // MUSIC
                      3'd2:    ib_fill = pit_fill;
                      3'd3:    ib_fill = prg_fill;
                      default: ib_fill = 8'd0;
                  endcase
            4'd5: case (ib_ridx)  // TEST
                      3'd1:    ib_fill = voi_fill;
                      default: ib_fill = 8'd0;
                  endcase
            default: ib_fill = 8'd0;
        endcase
    end

    //    ibar 只看 y 落在哪个行带里 —— 不判页的话, 它的描边/空槽会在
    //    **没排仪表的行**上冒出来 (MAIN 的行 2/6/10/14 上会突然多出 5 个
    //    空条, 其中行 10 还会盖在音量条上, 行 14 会切到 CHORUS 的数字)。
    //    空槽色是深琥珀, 在纯黑底上很显眼 —— 这是那种"预览图里没有、
    wire ib_on = ((pge_s1 == 4'd1) &&
                  ((ib_ridx == 3'd1) || (ib_ridx == 3'd3) ||
                   (ib_ridx == 3'd5) || (ib_ridx == 3'd6))) ||
                 ((pge_s1 == 4'd4) &&
                  ((ib_ridx == 3'd2) || (ib_ridx == 3'd3))) ||
                 ((pge_s1 == 4'd5) && (ib_ridx == 3'd1));
    wire [1:0] ib_st = ib_on ? ibar(x_r3, y_r3, ib_y, ib_fill) : 2'd0;

    //---- 方点阵 (档位): 8x8 的点, 间距 14, 从 x344 起, **8 个槽** ----
    //  点 i 占 x ∈ [344+14i, 351+14i], i=7 时到 450 —— 右界 463 内。
    //  14i = (i<<4)-(i<<1), 无乘法。
    wire [2:0] dot_i  = (x_r3 < 10'd358) ? 3'd0 :
                        (x_r3 < 10'd372) ? 3'd1 :
                        (x_r3 < 10'd386) ? 3'd2 :
                        (x_r3 < 10'd400) ? 3'd3 :
                        (x_r3 < 10'd414) ? 3'd4 :
                        (x_r3 < 10'd428) ? 3'd5 :
                        (x_r3 < 10'd442) ? 3'd6 : 3'd7;
    wire [9:0] dot_x0 = 10'd344 + {3'b000, dot_i, 4'b0000} - {6'b000000, dot_i, 1'b0};
    wire       dot_ix = (x_r3 >= dot_x0) && (x_r3 < dot_x0 + 10'd8);
    //  点阵的三处落点 (行内 y = 行*16+4 .. +11):
    //    MAIN 行2 音色 (8 槽) / MAIN 行6 八度 (4 槽) / MUSIC 行2 曲目 (4 槽)
    //    音色 wave_sel 0..7 -> 8 槽 (1..8 颗); 八度 0..3 -> 4 槽; 曲目 0..3 -> 4 槽。
    //      看着像"这一行没有仪表"; 而且"最右那颗亮着"本身就是个读数。
    wire mdot_y2 = (y_r3 >= 10'd36) && (y_r3 <= 10'd43);
    wire mdot_y6 = (y_r3 >= 10'd100) && (y_r3 <= 10'd107);
    wire dot_m2  = (pge_s1 == 4'd1) && mdot_y2;  // MAIN 音色
    wire dot_m6  = (pge_s1 == 4'd1) && mdot_y6;  // MAIN 八度
    wire dot_u2  = (pge_s1 == 4'd4) && mdot_y2;  // MUSIC 曲目
    wire dot_gate = dot_m2 || dot_m6 || dot_u2;
    wire [3:0] dot_n   = dot_m2 ? 4'd8 : 4'd4;
    wire [3:0] dot_sel = dot_m2 ? ({1'b0, wave_sel} + 4'd1) :
                         dot_m6 ? ({2'b00, oct_s1} + 4'd1) :
                         (dot_u2 ? ({2'b00, sng_s1} + 4'd1) : 4'd0);
    wire       dot_in  = dot_gate && dot_ix && ({1'b0, dot_i} < dot_n);
    wire       dot_on  = dot_in && ({1'b0, dot_i} < dot_sel);
    wire       dot_any = dot_in;

    wire mus_lamp = (pge_s1 == 4'd4) &&
                    lamp_on(x_r3, y_r3, 10'd360, 10'd72);  // 行4 中心 y=72
    wire tst_lamp = (pge_s1 == 4'd5) &&
                    lamp_on(x_r3, y_r3, 10'd360, 10'd8);  // 标题行 中心 y=8

    reg [7:0] sb0_s0, sb0_s1, sb1_s0, sb1_s1, sb2_s0, sb2_s1, sb3_s0, sb3_s1;
    reg [7:0] sb4_s0, sb4_s1, sb5_s0, sb5_s1, sb6_s0, sb6_s1, sb7_s0, sb7_s1;
    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            sb0_s0 <= 8'd0; sb0_s1 <= 8'd0; sb1_s0 <= 8'd0; sb1_s1 <= 8'd0;
            sb2_s0 <= 8'd0; sb2_s1 <= 8'd0; sb3_s0 <= 8'd0; sb3_s1 <= 8'd0;
            sb4_s0 <= 8'd0; sb4_s1 <= 8'd0; sb5_s0 <= 8'd0; sb5_s1 <= 8'd0;
            sb6_s0 <= 8'd0; sb6_s1 <= 8'd0; sb7_s0 <= 8'd0; sb7_s1 <= 8'd0;
        end else begin
            sb0_s0 <= bnd0; sb0_s1 <= sb0_s0;  sb1_s0 <= bnd1; sb1_s1 <= sb1_s0;
            sb2_s0 <= bnd2; sb2_s1 <= sb2_s0;  sb3_s0 <= bnd3; sb3_s1 <= sb3_s0;
            sb4_s0 <= bnd4; sb4_s1 <= sb4_s0;  sb5_s0 <= bnd5; sb5_s1 <= sb5_s0;
            sb6_s0 <= bnd6; sb6_s1 <= sb6_s0;  sb7_s0 <= bnd7; sb7_s1 <= sb7_s0;
        end
    end

    //  段号: 7 个比较 (不做 /36)
    wire [2:0] spec_b = (x_r3 < 10'd52)  ? 3'd0 :
                        (x_r3 < 10'd88)  ? 3'd1 :
                        (x_r3 < 10'd124) ? 3'd2 :
                        (x_r3 < 10'd160) ? 3'd3 :
                        (x_r3 < 10'd196) ? 3'd4 :
                        (x_r3 < 10'd232) ? 3'd5 :
                        (x_r3 < 10'd268) ? 3'd6 : 3'd7;
    //  段起点 = 16 + 36*段号 = 16 + (b<<5) + (b<<2)
    wire [9:0] spec_x0 = 10'd16 + {2'b00, spec_b, 5'b00000} +
                         {5'b00000, spec_b, 2'b00};
    wire [9:0] spec_x1 = spec_x0 + 10'd30;
    reg  [7:0] spec_v;
    always @* begin
        case (spec_b)
            3'd0: spec_v = sb0_s1;  3'd1: spec_v = sb1_s1;
            3'd2: spec_v = sb2_s1;  3'd3: spec_v = sb3_s1;
            3'd4: spec_v = sb4_s1;  3'd5: spec_v = sb5_s1;
            3'd6: spec_v = sb6_s1;  default: spec_v = sb7_s1;
        endcase
    end
    //  柱高 = 值*160/256 = ((v<<7)+(v<<5)) >> 8   (v<=255 -> 0..159)
    wire [15:0] sv16   = {8'd0, spec_v};
    wire [15:0] sh16   = (sv16 << 7) + (sv16 << 5);
    wire [9:0]  spec_h = {2'b00, sh16[15:8]};
    wire [9:0]  spec_top = 10'd200 - spec_h;
    wire spec_fill = (pge_s1 == 4'd2) &&
                     (x_r3 >= spec_x0) && (x_r3 < spec_x1) &&
                     (y_r3 >= spec_top) && (y_r3 < 10'd200);
    //  基线 (一条暗灰横线, 把柱子和下面的段标签分开)
    wire spec_base = (pge_s1 == 4'd2) && (y_r3 == 10'd200) &&
                     (x_r3 >= 10'd16) && (x_r3 < 10'd298);

    //---- 音量条的刻度线 (第 3 层"强调"): 3 条黑线把填充切成 4 段 ----
    wire vol_tick = (pge_s1 == 4'd1) && (y_r3 >= 10'd166) && (y_r3 <= 10'd169) &&
                    ((x_r3 == 10'd284) || (x_r3 == 10'd344) || (x_r3 == 10'd404));

    wire       ic_gate = (pge_s1 == 4'd0);
    wire       ic_band = ic_gate && (y_r3 >= 10'd24) && (y_r3 <= 10'd247);
    wire [2:0] ic_bidx = (y_r3 < 10'd72 ) ? 3'd0 :
                         (y_r3 < 10'd120) ? 3'd1 :
                         (y_r3 < 10'd168) ? 3'd2 :
                         (y_r3 < 10'd216) ? 3'd3 : 3'd4;
    wire [9:0] ic_i48  = {2'b00, ic_bidx, 5'b00000} +
                         {3'b000, ic_bidx, 4'b0000};  // idx*32 + idx*16 = 48*idx
    wire [9:0] ic_top  = 10'd24 + ic_i48;
    wire       ic_in_x = (x_r3 >= 10'd24) && (x_r3 <= 10'd55);
    wire [9:0] ic_y5w  = y_r3 - ic_top;  // 0..31 (图标盒内时)
    wire [9:0] ic_x5w  = x_r3 - 10'd24;  // 0..31 (在带内时)
    //     图标盒只有 32 行高, 盒下面还有 16 行空隙 (间距 48) —— 不卡的话
    //     空隙里的 ic_y5w = 32..47 被截成 0..15, 于是每个图标会在下方
    wire       ic_in_y = (ic_y5w <= 10'd31);
    wire       ic_in   = ic_band && ic_in_x && ic_in_y;
    wire ic_pix_w = 1'b0;  //  图标像素恒 0 = 不画图标

    wire ic_row_sel = ic_gate && (mse_s1 == ic_bidx);
    wire icon_pix   = ic_in && ic_pix_w;

    wire [4:0] ric_row = y_r3[8:4];
    //  x 16..31: bit4 == 1 且高 4 位为 0 (x_r3 最大 479, 9 位够)
    wire       ric_ix  = (x_r3[8:5] == 4'd0) && x_r3[4];
    //  该页有图标的行: 全是偶行 (2,4,6,...), 页内最后一行 MAN=14 / MUS=TES=8
    wire ric_row_ok = (ric_row[0] == 1'b0) && (ric_row != 5'd0) &&
                      ((pge_s1 == 4'd1)                            ? (ric_row <= 5'd14) :
                       ((pge_s1 == 4'd4) || (pge_s1 == 4'd5))      ? (ric_row <= 5'd8)  : 1'b0);
    wire ric_gate = (pge_s1 == 4'd1) || (pge_s1 == 4'd4) || (pge_s1 == 4'd5);
    wire ric_in   = ric_gate && ric_row_ok && ric_ix;

    //  图标号: 逐行照抄 gen_osd.py 的 G_ROW_ICON (顺序 = ROW_ICON_ORDER)
    //   0 timbre  1 note  2 octave  3 voices  4 volume  5 velocity  6 vibrato
    //   7 song    8 state 9 level  10 keys
    //    比"逐行比较"少一半比较器。
    reg [3:0] ric_id;
    always @* begin
        case ({pge_s1, ric_row[3:1]})
            //---- MAIN (页1) ----
            {4'd1, 3'd1}: ric_id = 4'd0;  // 行2  TIMBRE
            {4'd1, 3'd2}: ric_id = 4'd1;  // 行4  NOTE
            {4'd1, 3'd3}: ric_id = 4'd2;  // 行6  OCTAVE
            {4'd1, 3'd4}: ric_id = 4'd3;  // 行8  VOICES
            {4'd1, 3'd5}: ric_id = 4'd4;  // 行10 VOLUME
            {4'd1, 3'd6}: ric_id = 4'd5;  // 行12 VELOCITY
            {4'd1, 3'd7}: ric_id = 4'd6;  // 行14 VIBRATO
            //---- MUSIC (页4) ----
            {4'd4, 3'd1}: ric_id = 4'd7;  // 行2  SONG
            {4'd4, 3'd2}: ric_id = 4'd8;  // 行4  STATE
            {4'd4, 3'd3}: ric_id = 4'd1;  // 行6  NOTE
            {4'd4, 3'd4}: ric_id = 4'd9;  // 行8  LEVEL (进度条行)
            //---- TEST (页5) ----
            {4'd5, 3'd1}: ric_id = 4'd9;  // 行2  LEVEL (档位灯行)
            {4'd5, 3'd2}: ric_id = 4'd3;  // 行4  VOICES
            {4'd5, 3'd3}: ric_id = 4'd10;  // 行6  KEYS
            {4'd5, 3'd4}: ric_id = 4'd0;  // 行8  TIMBRE
            default:      ric_id = 4'd0;
        endcase
    end
    wire ric_pix_w = 1'b0;  //  行图标同样停用 (理由见上面 ic_pix_w 那段)
    //  osd_rowicons u_ricons (
    //      .ic  (ric_id),
    //      .y4  (y_r3[3:0]),
    //      .x4  (x_r3[3:0]),
    //      .pix (ric_pix_w)
    //  );
    wire ricon_pix = ric_in && ric_pix_w;

    //---- 指示灯的颜色 (开关语义) ----
    //  TEST 档位灯:  测试运行中=青 / 没开=深槽
    wire [15:0] mus_lamp_c = (sst_s1 == 2'd1) ? C_ACC    :
                             (sst_s1 == 2'd2) ? C_VALUE  : C_TRACK;
    wire [15:0] tst_lamp_c = test_active ? C_ACC : C_TRACK;

    //     焦点条里**只剩 MUSIC 行2 的曲目点阵**一处 (焦点条只有页 0/3/4/5
    //     画, 仪器只在页 1/2/4/5 画, 交集是页 4 行 2 和页 5 行 2;
    //     页 5 行 2 现在没有仪表了)。
    //    条里的空槽也得压成黑的, 不然白底上留一圈暗色的空点很难看。
    //    (曲目号本身在行 2 有文字 "SONG 1", 点阵压黑不丢信息。)
    wire foc_ins_hit = (dot_u2 && dot_any);

    wire [15:0] color =
        (lis_panel)                              ? C_FRAME :  // 面板框 (最上: 轨迹压不到框)
        (in_lis_r && lis_on_raw && show_scope)   ? C_TRACE :  // 李萨如轨迹
        (in_lis && lis_cross && show_scope)      ? C_ACC :  // 中心十字
        (in_lis && lis_grid && show_scope)       ? C_ACC_D :  // 背景网格
        (in_bar && show_scope)                   ? (bar_gap ? C_BG :
                                                   (bar_cell < bar_cells ? C_ACC : C_ACC_D)) :
        (in_focus && foc_ins_hit)                ? C_BG :  // 焦点条内仪表反相
        (ib_st == 2'd1)                          ? C_FRAME :  // 仪表条: 描边
        (ib_st == 2'd2)                          ? C_ATRACK :  // 仪表条: 空槽 (深琥珀)
        (ib_st == 2'd3)                          ? C_VALUE :  // 仪表条: 填充 (琥珀)
        (dot_any)                                ? (dot_on ? C_ACC : C_TRACK) :  // 档位点阵
        (mus_lamp)                               ? mus_lamp_c :  // MUSIC 状态灯
        (tst_lamp)                               ? tst_lamp_c :  // TEST 档位灯
        (spec_base)                              ? C_FRAME :  // 频谱基线
        (spec_fill)                              ? C_ACC :  // 频谱柱 (青)
        //---- 结构层 + 既有的两条宽条 ----
        (volbar_on && in_vol_o && !in_vol_i)     ? C_FRAME :  // 音量条框
        (volbar_on && vol_tick)                  ? C_BG :
        (volbar_on && in_vol_i && !vol_fill_on)  ? C_ATRACK :  // 音量条空槽
        (volbar_on && vol_fill_on)               ? C_VALUE :  // 音量条填充(琥珀)
        (tstbar_on && in_tst_o && !in_tst_i)     ? C_FRAME :  // 声部条框
        (tstbar_on && in_tst_i && !tst_fill_on)  ? C_ATRACK :  // 声部条空槽
        (tstbar_on && tst_fill_on)               ? C_VALUE :  // 声部条填充(琥珀)
        (sep_on)                                 ? C_FRAME :  // 页眉分隔线
        //    角刻度和卡片框在四个角附近有 24 个像素重叠 (y24/y239 上 x9..12 与
        //    在前, 那 24 个像素就是**框线色**; 而预览图是先画框、后画刻度,
        //    那里是**青色** —— 两边对不上, 但每边单独看都"对"。
        //    青头, 被框线切掉一半就没意义了; 而且预览图不用改。
        (tick_on)                                ? C_ACC :
        (tacc_on)                                ? C_ACC :
        (card_edge)                              ? C_FRAME :
        (in_focus && de_r3 && chpix && chr_on)   ? C_BG :  // 焦点框内文字反相
        (in_focus && icon_pix)                   ? C_BG :  // 焦点框内图标反相
        (in_focus && ricon_pix)                  ? C_BG :
        (vdot_px)                                ? C_ACC :
(ricon_pix)                              ? C_ITEM :
        (de_r3 && chpix && chr_on)               ? c_text :  // 普通文字
        (icon_pix)                               ? (ic_row_sel ? C_FOCUS : C_ITEM) :
        (in_focus)                               ? (foc_edit ? C_ACC : C_FOCUS) :  // 焦点框填充 (锁定=青)
                                                   C_BG;

    always @(posedge pclk or negedge rst_n) begin
        if (!rst_n) begin
            r <= 5'd0; g <= 6'd0; b <= 5'd0;
            hs_o <= 1'b0; vs_o <= 1'b0; de_o <= 1'b0;
        end else begin
            {r, g, b} <= de_r3 ? color : C_BG;
            hs_o <= hs_r3;
            vs_o <= vs_r3;
            de_o <= de_r3;
        end
    end

endmodule
