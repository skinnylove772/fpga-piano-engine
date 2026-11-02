// lissajous.v —— 李萨如图形 (拓展要求 3 的"视听反馈")
module lissajous(
    //---- 音频域: 只负责产生"有新采样"的握手脉冲 ----
    input  wire        aclk,  // 1.5MHz
    input  wire        arst_n,
    input  wire        tick,  // 每采样一个脉冲
    input  wire [7:0]  phx,  // X 信号: 0 号声部的相位高 8 位
    input  wire [7:0]  phy,  // Y 信号: 1 号声部的相位高 8 位

    //---- 视频域: 画点 + 读点, 全部在这个时钟域 ----
    input  wire        vclk,  // 9MHz 像素时钟
    input  wire        vrst_n,
    input  wire [6:0]  px,  // 区域内坐标 0..127
    input  wire [6:0]  py,
    output wire        on  // 该像素是否点亮
);

    reg tog_a;
    always @(posedge aclk or negedge arst_n) begin
        if (!arst_n)            tog_a <= 1'b0;
        else if (tick)          tog_a <= ~tog_a;
    end

    // 二、视频域: 同步 tog_a 并检边沿
    //     (锁存相位由下面的插值状态机做, 这里只负责把边沿检出来)
    reg tog_s0, tog_s1, tog_s2;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            tog_s0 <= 1'b0;
            tog_s1 <= 1'b0;
            tog_s2 <= 1'b0;
        end else begin
            tog_s0 <= tog_a;
            tog_s1 <= tog_s0;
            tog_s2 <= tog_s1;
        end
    end

    wire new_smp = (tog_s1 != tog_s2);  // 音频域刚送来一组新相位

    reg [7:0] prev_x, prev_y, cur_x, cur_y;
    reg [1:0] ip;  // 插值序号 0..3
    localparam PL_IDLE = 2'd0, PL_WAIT = 2'd1, PL_DRAW = 2'd2;
    reg [1:0] pst;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            pst    <= PL_IDLE;
            ip     <= 2'd0;
            prev_x <= 8'd0; prev_y <= 8'd0;
            cur_x  <= 8'd0; cur_y  <= 8'd0;
        end else begin
            case (pst)
            PL_IDLE: if (new_smp) begin
                         cur_x <= phx;  // 锁存这一组新相位
                         cur_y <= phy;
                         ip    <= 2'd0;
                         pst   <= PL_WAIT;
                     end
            PL_WAIT: pst <= PL_DRAW;  // 等一拍, 让 cur 稳定下来
            PL_DRAW: begin
                if (ip == 2'd3) begin
                    prev_x <= cur_x;  // 本段画完, 当前点成为下一段起点
                    prev_y <= cur_y;
                    pst    <= PL_IDLE;
                end else begin
                    ip <= ip + 2'd1;
                end
            end
            default: pst <= PL_IDLE;
            endcase
        end
    end

    wire plot_en = (pst == PL_DRAW);

    wire [7:0] dx = cur_x - prev_x;
    wire [7:0] dy = cur_y - prev_y;

    // 第 ip 个插值点相对 prev 的偏移 (0/4, 1/4, 2/4, 3/4)
    reg [7:0] ox, oy;
    always @* begin
        case (ip)
            2'd0: begin ox = 8'd0;                     oy = 8'd0;                     end
            2'd1: begin ox = dx >> 2;                  oy = dy >> 2;                  end
            2'd2: begin ox = dx >> 1;                  oy = dy >> 1;                  end
            default: begin ox = (dx >> 1) + (dx >> 2); oy = (dy >> 1) + (dy >> 2); end
        endcase
    end

    // 这一拍要画的点的相位
    wire [7:0] phx_i = prev_x + ox;
    wire [7:0] phy_i = prev_y + oy;

    reg signed [7:0] sinq [0:64];
    initial begin
        sinq[ 0]=8'sd0; sinq[ 1]=8'sd3; sinq[ 2]=8'sd6; sinq[ 3]=8'sd9;
        sinq[ 4]=8'sd12; sinq[ 5]=8'sd16; sinq[ 6]=8'sd19; sinq[ 7]=8'sd22;
        sinq[ 8]=8'sd25; sinq[ 9]=8'sd28; sinq[10]=8'sd31; sinq[11]=8'sd34;
        sinq[12]=8'sd37; sinq[13]=8'sd40; sinq[14]=8'sd43; sinq[15]=8'sd46;
        sinq[16]=8'sd49; sinq[17]=8'sd51; sinq[18]=8'sd54; sinq[19]=8'sd57;
        sinq[20]=8'sd60; sinq[21]=8'sd63; sinq[22]=8'sd65; sinq[23]=8'sd68;
        sinq[24]=8'sd71; sinq[25]=8'sd73; sinq[26]=8'sd76; sinq[27]=8'sd78;
        sinq[28]=8'sd81; sinq[29]=8'sd83; sinq[30]=8'sd85; sinq[31]=8'sd88;
        sinq[32]=8'sd90; sinq[33]=8'sd92; sinq[34]=8'sd94; sinq[35]=8'sd96;
        sinq[36]=8'sd98; sinq[37]=8'sd100; sinq[38]=8'sd102; sinq[39]=8'sd104;
        sinq[40]=8'sd106; sinq[41]=8'sd107; sinq[42]=8'sd109; sinq[43]=8'sd111;
        sinq[44]=8'sd112; sinq[45]=8'sd113; sinq[46]=8'sd115; sinq[47]=8'sd116;
        sinq[48]=8'sd117; sinq[49]=8'sd118; sinq[50]=8'sd120; sinq[51]=8'sd121;
        sinq[52]=8'sd122; sinq[53]=8'sd122; sinq[54]=8'sd123; sinq[55]=8'sd124;
        sinq[56]=8'sd125; sinq[57]=8'sd125; sinq[58]=8'sd126; sinq[59]=8'sd126;
        sinq[60]=8'sd126; sinq[61]=8'sd127; sinq[62]=8'sd127; sinq[63]=8'sd127;
        sinq[64]=8'sd127;
    end

    // 256 项全表: 用四分之一波镜像拼出来
    reg signed [7:0] sin_tab [0:255];
    integer si;
    initial begin
        for (si = 0; si < 256; si = si + 1) begin
            case (si[7:6])
                2'd0:    sin_tab[si] =  sinq[si[5:0]];  //   0.. 63  0°..90°
                2'd1:    sin_tab[si] =  sinq[64 - si[5:0]];  //  64..127  90°..180°
                2'd2:    sin_tab[si] = -sinq[si[5:0]];  // 128..191 180°..270°
                default: sin_tab[si] = -sinq[64 - si[5:0]];  // 192..255 270°..360°
            endcase
        end
    end

    // 用**插值后**的相位查表 (每拍推进 1/4 个采样间隔)
    wire signed [7:0] sxn = sin_tab[phx_i];
    wire signed [7:0] syn = sin_tab[phy_i];

    // 缩放: 用 >>> 而不是除法
    wire signed [7:0] qx = sxn >>> 1;  // ±63
    wire signed [7:0] qy = syn >>> 1;  // ±63

    wire signed [8:0] xc = {qx[7], qx} + 9'sd64;  // X 中心 64
    wire signed [8:0] yc = {qy[7], qy} + 9'sd64;  // Y 中心 64
    wire [6:0] xpix = (xc < 9'sd0)   ? 7'd0   :
                      (xc > 9'sd127) ? 7'd127 : xc[6:0];
    wire [6:0] ypix = (yc < 9'sd0)   ? 7'd0   :
                      (yc > 9'sd127) ? 7'd127 : yc[6:0];

    // (xp1/yp1 是当年画 2x2 粗线时留下的钳位, 现在线宽回到 1 像素, 已经用不到了,

    // 四、显存: 128 x 128 x 1bit = 16384 bit -> 1 块 BSRAM
    //     读写都在 vclk 上 -> 标准 SDP, 必定推断正确
    reg fb [0:16383];

    // 余辉: 每 41 个时钟清一个地址, 扫完 16384 个约 74 毫秒。
    //     和弦变化、声部重新分配时, 过去 0.3 秒内画过的**所有**图形都还留在
    //     屏幕上, 一层叠一层, 看起来就是"一坨乱麻"。
    //   74ms 足够让轨迹连续(每个像素每秒被重画约 156 次, 而这里每 74ms 才擦一次,
    //   想再短一点就调小 CLEAR_DIV: 30 -> 54ms, 20 -> 36ms。
    localparam [7:0] CLEAR_DIV = 8'd8;
    reg [7:0]  clr_div;
    reg [13:0] clr_addr;

    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) begin
            clr_div  <= 8'd0;
            clr_addr <= 14'd0;
        end else if (plot_en) begin
            // 画一个点 (1 像素)。线宽靠"表细 + 段内插值"来保证连续, 不靠加粗。
            fb[{ypix, xpix}] <= 1'b1;
        end else if (clr_div == CLEAR_DIV) begin
            clr_div  <= 8'd0;
            fb[clr_addr] <= 1'b0;
            clr_addr <= (clr_addr == 14'd16383) ? 14'd0 : (clr_addr + 14'd1);
        end else begin
            clr_div <= clr_div + 8'd1;
        end
    end

    // 读口: 同一个时钟, 1 拍延迟
    //     正好延迟一拍, 两者要对齐。多打一拍图形就会整体错位一个像素。
    reg rd_r;
    always @(posedge vclk or negedge vrst_n) begin
        if (!vrst_n) rd_r <= 1'b0;
        else         rd_r <= fb[{py, px}];
    end

    assign on = rd_r;

endmodule
