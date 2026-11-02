// spectrum.v —— 8 段频谱显示 (v3: **音符驱动**)
module spectrum #(
    parameter NVOICE = 32
)(
    input  wire        clk,  // 3MHz 音频时钟
    input  wire        rst_n,
    input  wire        tst_mode,
    input  wire [16*NVOICE-1:0] vbus,

    output reg  [7:0]  barval,  // 当前段的柱子值 (给 disp_wave)
    output reg  [2:0]  baridx,
    output reg  [1:0]  barlow,
    output reg  [7:0]  bnd0, bnd1, bnd2, bnd3,  // 8 段各自的值 (OSD 直接用)
    output reg  [7:0]  bnd4, bnd5, bnd6, bnd7
);

    localparam [15:0] F_TICK = 16'd30000;  // 10ms @3MHz 一帧
    localparam [7:0]  DECAY  = 8'd4;  // 每帧下落量 (满量程 64 帧 = 640ms 拖尾)

    reg  [4:0] vi;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) vi <= 5'd0;
        else        vi <= vi + 5'd1;
    end

    wire [6:0] vnote = vbus[16*vi + 9 +: 7];
    wire       vbusy = vbus[16*vi + 8];
    wire [7:0] venv  = vbus[16*vi + 0 +: 8];

    //    note < 36 的归第 0 段; note > 99 的归第 7 段
    //    8 段 x **4 个半音**, 覆盖 MIDI 60..91 (262~1568 Hz) —— 正好是测试音的全部范围。
    //    两套都是 8 段 x 4 个半音, 都能铺满八段。
    wire [6:0] base_n = tst_mode ? 7'd72 : 7'd60;
    wire [6:0] nb = (vnote < base_n) ? 7'd0 : (vnote - base_n);
    //  先右移再限幅: 直接取 nb[4:2] 在 nb>=32 时会丢掉高位的段号(应为 clamp 到 7)
    wire [6:0] nb2  = nb >> 2;
    wire [3:0] nidx = (nb2 > 7'd7) ? 4'd7 : nb2[3:0];
    wire [2:0]  vband = (nidx > 4'd7) ? 3'd7 : nidx[2:0];

    reg  [7:0]  pk0, pk1, pk2, pk3, pk4, pk5, pk6, pk7;
    reg  [15:0] fcnt;
    reg  [5:0]  oi;  // 给 barval/baridx 用的慢速循环

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pk0 <= 8'd0; pk1 <= 8'd0; pk2 <= 8'd0; pk3 <= 8'd0;
            pk4 <= 8'd0; pk5 <= 8'd0; pk6 <= 8'd0; pk7 <= 8'd0;
            bnd0 <= 8'd0; bnd1 <= 8'd0; bnd2 <= 8'd0; bnd3 <= 8'd0;
            bnd4 <= 8'd0; bnd5 <= 8'd0; bnd6 <= 8'd0; bnd7 <= 8'd0;
            fcnt <= 16'd0;
            oi   <= 6'd0;
        end else begin
            oi <= oi + 6'd1;

            //  ---- 本拍命中的声部, 把它所在段的峰值顶上去 ----
            if (vbusy) begin
                case (vband)
                    3'd0: if (venv   > pk0) pk0 <= venv;
                    3'd1: if (venv   > pk1) pk1 <= venv;
                    3'd2: if (venv   > pk2) pk2 <= venv;
                    3'd3: if (venv   > pk3) pk3 <= venv;
                    3'd4: if (venv   > pk4) pk4 <= venv;
                    3'd5: if (venv   > pk5) pk5 <= venv;
                    3'd6: if (venv   > pk6) pk6 <= venv;
                    default: if (venv > pk7) pk7 <= venv;
                endcase

            end

            //  ---- 帧节拍: 取峰值 -> 下落 -> 清峰值 ----
            if (fcnt == F_TICK) begin
                fcnt <= 16'd0;
                bnd0 <= (pk0 >= bnd0) ? pk0 : ((bnd0 > DECAY) ? (bnd0 - DECAY) : 8'd0);
                bnd1 <= (pk1 >= bnd1) ? pk1 : ((bnd1 > DECAY) ? (bnd1 - DECAY) : 8'd0);
                bnd2 <= (pk2 >= bnd2) ? pk2 : ((bnd2 > DECAY) ? (bnd2 - DECAY) : 8'd0);
                bnd3 <= (pk3 >= bnd3) ? pk3 : ((bnd3 > DECAY) ? (bnd3 - DECAY) : 8'd0);
                bnd4 <= (pk4 >= bnd4) ? pk4 : ((bnd4 > DECAY) ? (bnd4 - DECAY) : 8'd0);
                bnd5 <= (pk5 >= bnd5) ? pk5 : ((bnd5 > DECAY) ? (bnd5 - DECAY) : 8'd0);
                bnd6 <= (pk6 >= bnd6) ? pk6 : ((bnd6 > DECAY) ? (bnd6 - DECAY) : 8'd0);
                bnd7 <= (pk7 >= bnd7) ? pk7 : ((bnd7 > DECAY) ? (bnd7 - DECAY) : 8'd0);
                pk0 <= 8'd0; pk1 <= 8'd0; pk2 <= 8'd0; pk3 <= 8'd0;
                pk4 <= 8'd0; pk5 <= 8'd0; pk6 <= 8'd0; pk7 <= 8'd0;
            end else begin
                fcnt <= fcnt + 16'd1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            barval <= 8'd0; baridx <= 3'd0; barlow <= 2'd0;
        end else begin
            baridx <= oi[5:3];  // 每 8 拍换一段
            case (oi[5:3])
                3'd0:    barval <= bnd0;
                3'd1:    barval <= bnd1;
                3'd2:    barval <= bnd2;
                3'd3:    barval <= bnd3;
                3'd4:    barval <= bnd4;
                3'd5:    barval <= bnd5;
                3'd6:    barval <= bnd6;
                default: barval <= bnd7;
            endcase
            barlow <= (oi[5:3] == 3'd7) ? 2'd2 : ((oi[5:3] == 3'd5) ? 2'd1 : 2'd0);
        end
    end

endmodule
