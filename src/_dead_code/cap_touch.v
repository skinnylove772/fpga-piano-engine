// cap_touch.v —— 7 路自电容触摸采集 (零外部元件版)
module cap_touch #(
    parameter NPAD = 7
)(
    input  wire            clk,  // 27MHz 晶振 (不能用 3MHz 音频时钟)
    input  wire            rst_n,
    inout  wire [NPAD-1:0] pad,
    output reg  [NPAD-1:0] touch,  // 1 = 触摸中 (或机械按键按下)

    output reg  [11:0]     dbg_raw,  // 偏离基线最大的那一路的原始读数
    output reg  [2:0]      dbg_ch,  // 是第几路
    output reg             dbg_tog  // 每扫完一轮翻转一次 (跨时钟域握手)
);

    // ---- 时间常数 (27MHz, 一拍 37.04ns) ----
    localparam [7:0]  T_DISCH = 8'd54;  // 2us 放电
    localparam [11:0] T_MAX   = 12'd2047;  // 75.8us 超时 -> 计数值上限
    localparam [8:0]  T_GAP   = 9'd199;  // 7.4us 测量间隔
    localparam [11:0] TH      = 12'd4;  // 触摸门限 (比基线高这么多才算)

    localparam S_DISCH  = 2'd0,
               S_FLOAT  = 2'd1,
               S_COMMIT = 2'd2,
               S_GAP    = 2'd3;

    reg [1:0]  st;
    reg [2:0]  ch;  // 当前扫到第几路
    reg [7:0]  dcnt;
    reg [11:0] mcnt;
    reg [8:0]  gcnt;
    reg [11:0] raw_now;
    reg [11:0] raw_r  [0:NPAD-1];  // 各通道原始读数
    reg [11:0] base_r [0:NPAD-1];  // 各通道基线

    // ---- 三态驱动: 只在放电阶段驱动为低, 其余时间全部高阻 ----
    wire drv = (st == S_DISCH);
    assign pad = drv ? {NPAD{1'b0}} : {NPAD{1'bz}};

    // 当前通道的电平 (高阻时读到的就是外部/上拉决定的电平)
    wire pad_in = pad[ch];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_DISCH;
            ch      <= 3'd0;
            dcnt    <= 8'd0;
            mcnt    <= 12'd0;
            gcnt    <= 9'd0;
            raw_now <= 12'd0;
            touch   <= {NPAD{1'b0}};
            dbg_raw <= 12'd0;
            dbg_ch  <= 3'd0;
            dbg_tog <= 1'b0;
            for (i = 0; i < NPAD; i = i + 1) begin
                raw_r[i]  <= 12'd0;
                base_r[i] <= 12'd0;
            end
        end else begin
            case (st)
            S_DISCH: begin
                if (dcnt == T_DISCH) begin
                    dcnt <= 8'd0;
                    mcnt <= 12'd0;
                    st   <= S_FLOAT;
                end else begin
                    dcnt <= dcnt + 8'd1;
                end
            end

            S_FLOAT: begin
                if (pad_in) begin
                    raw_now <= mcnt;  // 正常: 数到了
                    st      <= S_COMMIT;
                end else if (mcnt == T_MAX) begin
                    raw_now <= T_MAX;  // 超时: 引脚被短到地(机械按键按下)
                    st      <= S_COMMIT;
                end else begin
                    mcnt <= mcnt + 12'd1;
                end
            end

            S_COMMIT: begin
                raw_r[ch] <= raw_now;
                if (!touch[ch]) begin
                    if (raw_now > base_r[ch])
                        base_r[ch] <= base_r[ch] + 12'd1;
                    else if (base_r[ch] != 12'd0)
                        base_r[ch] <= base_r[ch] - 12'd1;
                end
                touch[ch] <= (raw_now > (base_r[ch] + TH));
                gcnt      <= 9'd0;
                st        <= S_GAP;
            end

            //---------- 间隔, 换下一路 ----------
            S_GAP: begin
                if (gcnt == T_GAP) begin
                    gcnt <= 9'd0;
                    if (ch == NPAD[2:0] - 3'd1) begin
                        ch      <= 3'd0;
                        dbg_tog <= ~dbg_tog;  // 一轮扫完, 通知视频域
                        dbg_raw <= best_raw;  // 把"偏离最大"的那一路读数送出去
                        dbg_ch  <= best_ch;
                    end else begin
                        ch <= ch + 3'd1;
                    end
                    st <= S_DISCH;
                end else begin
                    gcnt <= gcnt + 9'd1;
                end
            end

            default: st <= S_DISCH;
            endcase
        end
    end

    reg [11:0] best_dev;
    reg [11:0] best_raw;
    reg [2:0]  best_ch;
    integer k;
    always @* begin
        best_dev = 12'd0;
        best_raw = 12'd0;
        best_ch  = 3'd0;
        for (k = 0; k < NPAD; k = k + 1) begin
            if ((raw_r[k] > base_r[k]) &&
                ((raw_r[k] - base_r[k]) >= best_dev)) begin
                best_dev = raw_r[k] - base_r[k];
                best_raw = raw_r[k];
                best_ch  = k[2:0];
            end
        end
    end

endmodule
