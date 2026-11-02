// fx_decim.v —— 效果器链的**降采样入口**（93750 Hz -> 46875 Hz）
module fx_decim (
    input  wire                clk,  // 3MHz 音频域
    input  wire                rst_n,
    input  wire                tick,  // 93750 Hz, 每采样一个脉冲
    input  wire signed [15:0]  din,

    output reg  signed [15:0]  dout,  // 半速样本 (保持到下一个 ftick)
    output reg                 ftick,  // 46875 Hz, 每 2 个采样一个脉冲
    output reg                 phase  // 0/1 交替, 给输出侧对齐用
);

    reg signed [15:0] x0, x1, x2, x3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x0 <= 16'sd0; x1 <= 16'sd0; x2 <= 16'sd0; x3 <= 16'sd0;
        end else if (tick) begin
            x0 <= din;
            x1 <= x0;
            x2 <= x1;
            x3 <= x2;
        end
    end

    //  四个 17 位有符号相加, 不会溢出 (4 x 32768 = 131072 < 2^18)
    wire signed [17:0] sum4 = {{2{x0[15]}}, x0}
                            + {{2{x1[15]}}, x1}
                            + {{2{x2[15]}}, x2}
                            + {{2{x3[15]}}, x3};
    wire signed [15:0] lp = sum4[17:2];  // >>2 = /4

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 1'b0;
            ftick <= 1'b0;
            dout  <= 16'sd0;
        end else begin
            ftick <= 1'b0;  // 默认低, 只在下面那一拍拉高
            if (tick) begin
                phase <= ~phase;
                if (!phase) begin
                    //  这一拍出一个新的半速样本
                    ftick <= 1'b1;
                    dout  <= lp;
                end
            end
        end
    end

endmodule
