// ws2812_drv.v —— WS2812 / WS2812B 灯带串行驱动 (纯协议层)
module ws2812_drv #(
    parameter NLED = 60  // 灯数
)(
    input  wire        clk,  // 27MHz
    input  wire        rst_n,
    input  wire        start,  // 一拍脉冲: 请求刷新一帧
    input  wire [23:0] color_in,  // 当前灯的颜色 {G,R,B} (外部组合给出)
    output reg  [7:0]  led_idx,  // 当前正在发第几颗灯 (给外部取色用)
    output reg         dout,
    output reg         busy
);

    // ---- 位时序 (单位: 27MHz 时钟拍) ----
    localparam [5:0]  T0H = 6'd9;
    localparam [5:0]  T0L = 6'd25;
    localparam [5:0]  T1H = 6'd21;
    localparam [5:0]  T1L = 6'd13;
    localparam [13:0] T_RESET = 14'd8100;  // 300us

    localparam S_IDLE  = 3'd0,
               S_LOAD  = 3'd1,  // 装填当前位 (索引此时已稳定)
               S_HIGH  = 3'd2,
               S_LOW   = 3'd3,
               S_RESET = 3'd4;

    reg [2:0]  st;
    reg [13:0] cnt;
    reg [4:0]  bit_i;  // 23 -> 0
    reg        curbit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st      <= S_IDLE;
            dout    <= 1'b0;
            busy    <= 1'b0;
            cnt     <= 14'd0;
            led_idx <= 8'd0;
            bit_i   <= 5'd0;
            curbit  <= 1'b0;
        end else begin
            case (st)
            //---------- 等刷新请求 ----------
            S_IDLE: begin
                dout <= 1'b0;
                busy <= 1'b0;
                if (start) begin
                    led_idx <= 8'd0;
                    bit_i   <= 5'd23;
                    busy    <= 1'b1;
                    st      <= S_LOAD;
                end
            end

            //---------- 装填当前位 (led_idx / bit_i 在这一拍稳定, color_in 有效) ----------
            S_LOAD: begin
                curbit <= color_in[bit_i];
                dout   <= 1'b1;
                cnt    <= (color_in[bit_i] ? T1H : T0H) - 6'd1;
                st     <= S_HIGH;
            end

            //---------- 高电平段 ----------
            S_HIGH: begin
                if (cnt == 14'd0) begin
                    dout <= 1'b0;
                    cnt  <= (curbit ? T1L : T0L) - 6'd1;
                    st   <= S_LOW;
                end else begin
                    cnt <= cnt - 14'd1;
                end
            end

            //---------- 低电平段 ----------
            S_LOW: begin
                if (cnt == 14'd0) begin
                    if (bit_i != 5'd0) begin
                        bit_i <= bit_i - 5'd1;  // 同一颗灯的下一位
                        st    <= S_LOAD;
                    end else if (led_idx != NLED[7:0] - 8'd1) begin
                        led_idx <= led_idx + 8'd1;  // 下一颗灯
                        bit_i   <= 5'd23;
                        st      <= S_LOAD;
                    end else begin
                        dout <= 1'b0;  // 整帧发完
                        cnt  <= T_RESET;
                        st   <= S_RESET;
                    end
                end else begin
                    cnt <= cnt - 14'd1;
                end
            end

            //---------- 复位 ----------
            S_RESET: begin
                dout <= 1'b0;
                if (cnt == 14'd0) begin
                    busy <= 1'b0;
                    st   <= S_IDLE;
                end else begin
                    cnt <= cnt - 14'd1;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
