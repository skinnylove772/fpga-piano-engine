// rotary_enc.v —— EC11 旋转编码器解码 (带按键)
module rotary_enc #(
    //    27_000_000 / 27_000 = 1000Hz (1ms 一次, 给状态机用)
    parameter CLK_HZ     = 27_000_000,
    parameter FILT_DIV   = 27_000,
    //  -- 输入稳定窗口 (ms): 电平变化后必须保持这么久才认 --
    //     下限: 要大于触点弹跳时间 (EC11 典型 0.5~2ms)
    //     上限: 要小于**真实转动时每个相的电平保持时间**
    //             (手转快的时候每相约 3~5ms; 慢时几十 ms)
    //     取 1ms: 实际窗口 = (STABLE_MS+1) ms = 2ms
    //       会偶然丢格。宁可窗口小一点。
    parameter STABLE_MS  = 1,
    parameter LONG_MS    = 800
)(
    input  wire clk,
    input  wire rst_n,

    //---- 编码器 A / B 相 (引脚直连, 模块内部同步 + 去抖) ----
    input  wire enc_a,
    input  wire enc_b,
    //---- 编码器按键 (低有效, EC11 自带) ----
    input  wire enc_sw,

    //---- 旋转输出 ----
    output reg        step,  // 转过一格: 单拍脉冲
    output reg        dir,  // 1 = 顺时针(加), 0 = 逆时针(减)
    output reg  [7:0] pos,  // 累计位置 (自由增长; 选曲这类环形用途自行取模)

    //---- 按键输出 ----
    output reg        sw_press,  // 按下: 单拍脉冲 (松手时发, 与长按互斥)
    output reg        sw_long,  // 长按: 单拍脉冲 (到达阈值时触发一次)
    output reg        sw_state  // 当前按住状态 (1 = 按住)
);

    reg [15:0] div_cnt;
    wire       tick = (div_cnt == (FILT_DIV - 1));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) div_cnt <= 16'd0;
        else        div_cnt <= tick ? 16'd0 : (div_cnt + 16'd1);
    end

    reg a_s0, a_s1, b_s0, b_s1, w_s0, w_s1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_s0 <= 1'b1; a_s1 <= 1'b1;
            b_s0 <= 1'b1; b_s1 <= 1'b1;
            w_s0 <= 1'b1; w_s1 <= 1'b1;
        end else begin
            a_s0 <= enc_a;  a_s1 <= a_s0;
            b_s0 <= enc_b;  b_s1 <= b_s0;
            w_s0 <= enc_sw; w_s1 <= w_s0;
        end
    end

    wire ms_tick = tick;

    //  3) 稳定窗口去抖 (每个时钟都在计时, 不依赖采样节拍)
    //     stable_cnt 记录"当前电平已经保持了多久 (单位 ms)"。
    //     一旦输入电平与上次"确认值"不同, 计数从 0 开始;
    //     连续保持到 STABLE_MS 才把确认值更新过去。
    //     任何短于 STABLE_MS 的脉冲都通不过 -> 抖动被挡住。
    localparam [15:0] STABLE = STABLE_MS;

    reg        a_f, b_f, w_f;
    reg [15:0] a_tc, b_tc, w_tc;

    //  ---- A ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_f <= 1'b1; a_tc <= 16'd0;
        end else if (a_s1 != a_f) begin
            if (ms_tick) begin
                if (a_tc >= STABLE) begin a_f <= a_s1; a_tc <= 16'd0; end
                else                a_tc <= a_tc + 16'd1;
            end
        end else begin
            a_tc <= 16'd0;
        end
    end

    //  ---- B ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_f <= 1'b1; b_tc <= 16'd0;
        end else if (b_s1 != b_f) begin
            if (ms_tick) begin
                if (b_tc >= STABLE) begin b_f <= b_s1; b_tc <= 16'd0; end
                else                b_tc <= b_tc + 16'd1;
            end
        end else begin
            b_tc <= 16'd0;
        end
    end

    //  ---- 按键 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            w_f <= 1'b1; w_tc <= 16'd0;
        end else if (w_s1 != w_f) begin
            if (ms_tick) begin
                if (w_tc >= STABLE) begin w_f <= w_s1; w_tc <= 16'd0; end
                else                w_tc <= w_tc + 16'd1;
            end
        end else begin
            w_tc <= 16'd0;
        end
    end

    reg [1:0] st_cur, st_prv;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_cur <= 2'b00;
            st_prv <= 2'b00;
        end else if (tick) begin
            st_prv <= st_cur;
            st_cur <= {a_f, b_f};
        end
    end

    reg signed [1:0] inc;
    always @(*) begin
        case ({st_prv, st_cur})
            4'b00_10, 4'b10_11, 4'b11_01, 4'b01_00: inc = 2'sd1;  // 顺时针
            4'b00_01, 4'b01_11, 4'b11_10, 4'b10_00: inc = -2'sd1;  // 逆时针
            default: inc = 2'sd0;  // 没动/抖动
        endcase
    end

    reg signed [3:0] acc;
    wire signed [3:0] acc_n = acc + {{2{inc[1]}}, inc};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc  <= 4'sd0;
            step <= 1'b0;
            dir  <= 1'b0;
            pos  <= 8'd0;
        end else begin
            step <= 1'b0;
            if (tick) begin
                if (acc_n >= 4'sd4 || acc_n <= -4'sd4) begin
                    //  走满一圈 -> 一格
                    step <= 1'b1;
                    dir  <= (acc_n > 4'sd0);
                    pos  <= (acc_n > 4'sd0) ? (pos + 8'd1) : (pos - 8'd1);
                    acc  <= 4'sd0;
                end else begin
                    acc <= acc_n;
                end
            end
        end
    end

    localparam [15:0] LONG_CNT = LONG_MS;
    reg [15:0] hold_cnt;
    reg        long_fired;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hold_cnt    <= 16'd0;
            long_fired  <= 1'b0;
            sw_press <= 1'b0;
            sw_long  <= 1'b0;
            sw_state <= 1'b0;
        end else begin
            sw_press <= 1'b0;
            sw_long  <= 1'b0;

            if (ms_tick) begin
                if (!w_f) begin
                    //  ---- 按住 ----
                    if (!sw_state) begin
                        sw_state    <= 1'b1;
                        hold_cnt    <= 16'd0;
                        long_fired  <= 1'b0;  // 新的一次按压
                    end else if (hold_cnt < LONG_CNT) begin
                        hold_cnt <= hold_cnt + 16'd1;
                        if (hold_cnt + 16'd1 == LONG_CNT) begin
                            sw_long    <= 1'b1;  // 到阈值 -> 长按
                            long_fired <= 1'b1;
                        end
                    end
                end else begin
                    //  ---- 松手 ----
                    if (sw_state && !long_fired) sw_press <= 1'b1;
                    sw_state   <= 1'b0;
                    hold_cnt   <= 16'd0;
                    long_fired <= 1'b0;
                end
            end
        end
    end

endmodule
