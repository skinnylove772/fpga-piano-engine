// apds9930.v —— APDS-9930 环境光 + 接近传感器驱动
module apds9930 #(
    parameter [6:0] DEV = 7'h39,  // I2C 从机地址
    parameter [7:0] ID_EXPECT = 8'h39  // 读 0x12 应该得到的值
)(
    input  wire        clk,  // 27MHz
    input  wire        rst_n,

    //---- I2C 引脚 (SDA 的三态由上层接) ----
    output wire        scl,
    output wire        sda_oe,
    output wire        sda_o,
    input  wire        sda_i,

    output reg  [15:0] ch0,  // 环境光: 可见光 + 红外
    output reg  [15:0] ch1,  // 环境光: 纯红外
    output reg  [15:0] prox,  // 接近值: 越大越近
    output reg         ok,  // 1 = 读到过正确 ID
    //   id_seen  : 最近一次读 0x12 拿到的值 (对了应该是 0x39)
    //   err_seen : 至少发生过一次"从机没应答"
    //   有了这两个, 屏幕上就能区分"总线不通"和"器件不对",
    //   不用反复烧不同版本来猜。
    output reg  [7:0]  id_seen,
    output reg         err_seen,
    output reg         tog,  // 接近值更新时翻转 (给 OSD 跨时钟域用)
    output reg         busy  // 事务进行中
);

    localparam [19:0] T_POWER = 20'd270000;  // 10ms  上电等待
    localparam [19:0] T_AFTER = 20'd405000;  // 15ms  配置完等第一次转换
    localparam [19:0] T_GAP   = 20'd5400;  // 0.2ms 两次事务之间的间隙
    localparam [19:0] T_CYCLE = 20'd27000;  // 1ms   一轮读的周期

    localparam S_POWER  = 4'd0,
               S_ISSUE  = 4'd1,  // 发出一个事务
               S_WAIT   = 4'd2,  // 等 i2c 做完
               S_GAP    = 4'd3,  // 事务间小间隙
               S_AFTER  = 4'd4,  // 配置完等待
               S_CHKID  = 4'd5,  // 校验 ID
               S_CYCLE  = 4'd6,  // 一轮读完的周期等待
               S_ERR    = 4'd7;  // I2C 出错, 重试

    reg [3:0]  step;
    reg [7:0]  seq_reg;  // 命令字节
    reg [7:0]  seq_dat;  // 写的数据
    reg        seq_rd;  // 1 = 读
    reg        seq_go;  // 发给 i2c_master 的启动脉冲

    always @* begin
        seq_reg = 8'h00;
        seq_dat = 8'h00;
        seq_rd  = 1'b1;
        case (step)
            //---- 初始化: 全部是写 ----
            4'd0: begin seq_rd = 1'b0; seq_reg = 8'h80 | 8'h00; seq_dat = 8'h00; end  // ENABLE 全关
            4'd1: begin seq_rd = 1'b0; seq_reg = 8'h80 | 8'h01; seq_dat = 8'hDB; end  // ATIME 101ms
            4'd2: begin seq_rd = 1'b0; seq_reg = 8'h80 | 8'h02; seq_dat = 8'hFF; end  // PTIME
            4'd3: begin seq_rd = 1'b0; seq_reg = 8'h80 | 8'h0E; seq_dat = 8'h08; end  // PPULSE
            4'd4: begin seq_rd = 1'b0; seq_reg = 8'h80 | 8'h0F; seq_dat = 8'h20; end  // CONTROL
            4'd5: begin seq_rd = 1'b0; seq_reg = 8'h80 | 8'h00; seq_dat = 8'h07; end  // ENABLE 开三个
            //---- 校验 ID ----
            4'd6: begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h12; end  // ID
            //---- 循环读 ----
            4'd7:  begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h13; end  // STATUS
            4'd8:  begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h14; end  // CH0 低
            4'd9:  begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h15; end  // CH0 高
            4'd10: begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h16; end  // CH1 低
            4'd11: begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h17; end  // CH1 高
            4'd12: begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h18; end  // PDATA 低
            default: begin seq_rd = 1'b1; seq_reg = 8'hA0 | 8'h19; end  // PDATA 高
        endcase
    end

    localparam [15:0] I2C_DIV = 16'd68;

    wire [7:0]  rd_data;
    wire        i2c_busy, i2c_done, i2c_ackerr;

    i2c_master #() u_i2c (
        .clk      (clk),
        .rst_n    (rst_n),
        .div_i    (I2C_DIV),
        .go       (seq_go),
        .dev      (DEV),
        .reg_addr (seq_reg),
        .rd       (seq_rd),
        .wr_data  (seq_dat),
        //     APDS-9930 不需要它, 显式接 0 —— 接 0 时行为和不接时完全一样,
        //     写出来就不会让人误以为这里漏接了一个端口。
        .wake     (1'b0),
        //     (i2c_master 新增的多字节读只给 PAJ7620 的 0x43/0x44 用。)
        .rd_len   (2'd1),
        .rd_data  (rd_data),
        .rd_data2 (),
        .busy     (i2c_busy),
        .done     (i2c_done),
        .ack_err  (i2c_ackerr),
        //     APDS-9930 这边不做字节级定位, 显式留空 —— 比不写更清楚:
        //     写出来就不会让人误以为"漏接了一个端口"。
        .step_dbg (),
        .scl      (scl),
        .sda_oe   (sda_oe),
        .sda_o    (sda_o),
        .sda_i    (sda_i)
    );

    reg [3:0]  st;
    reg [19:0] dly;
    reg [7:0]  low_byte;  // 16 位寄存器的低字节暂存
    reg [7:0]  id_read;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_POWER;
            step     <= 4'd0;
            dly      <= 20'd0;
            seq_go   <= 1'b0;
            low_byte <= 8'd0;
            id_read  <= 8'd0;
            ch0      <= 16'd0;
            ch1      <= 16'd0;
            prox     <= 16'd0;
            ok       <= 1'b0;
            id_seen  <= 8'd0;
            err_seen <= 1'b0;
            tog      <= 1'b0;
            busy     <= 1'b1;
        end else begin
            seq_go <= 1'b0;

            case (st)
            S_POWER: begin
                busy <= 1'b1;
                if (dly == T_POWER) begin
                    dly  <= 20'd0;
                    step <= 4'd0;
                    st   <= S_ISSUE;
                end else begin
                    dly <= dly + 20'd1;
                end
            end

            S_ISSUE: begin
                seq_go <= 1'b1;
                st     <= S_WAIT;
            end

            S_WAIT: begin
                if (i2c_done) begin
                    if (i2c_ackerr) begin
                        ok       <= 1'b0;
                        err_seen <= 1'b1;  // 记下来, 屏幕上看得到
                        st <= S_ERR;  // 从机没应答: 记录并重试
                    end else begin
                        case (step)
                            4'd6: begin id_read <= rd_data; id_seen <= rd_data; end
                            // CH0 / CH1 / PDATA 都是"低字节在前", 先存低字节
                            4'd8:  low_byte <= rd_data;
                            4'd9:  ch0  <= {rd_data, low_byte};
                            4'd10: low_byte <= rd_data;
                            4'd11: ch1  <= {rd_data, low_byte};
                            4'd12: low_byte <= rd_data;
                            default: begin
                                if (step == 4'd13) begin
                                    prox <= {rd_data, low_byte};
                                    tog  <= ~tog;  // 接近值更新, 翻转握手
                                end
                            end
                        endcase

                        // 下一步
                        if (step == 4'd5) begin
                            step <= 4'd6;
                            dly  <= 20'd0;
                            st   <= S_AFTER;  // 配置完等第一次转换
                        end else if (step == 4'd6) begin
                            step <= 4'd7;  // 进循环读
                            st   <= S_CHKID;
                        end else if (step >= 4'd13) begin
                            step <= 4'd7;  // 一轮读完, 回到开头
                            dly  <= 20'd0;
                            st   <= S_CYCLE;
                        end else begin
                            step <= step + 4'd1;
                            dly  <= 20'd0;
                            st   <= S_GAP;
                        end
                    end
                end
            end

            S_GAP: begin
                if (dly == T_GAP) begin
                    dly <= 20'd0;
                    st  <= S_ISSUE;
                end else begin
                    dly <= dly + 20'd1;
                end
            end

            S_AFTER: begin
                if (dly == T_AFTER) begin
                    dly <= 20'd0;
                    st  <= S_ISSUE;
                end else begin
                    dly <= dly + 20'd1;
                end
            end

            S_CHKID: begin
                ok  <= (id_read == ID_EXPECT);
                busy <= 1'b0;
                dly  <= 20'd0;
                st   <= S_CYCLE;
            end

            S_CYCLE: begin
                if (dly == T_CYCLE) begin
                    dly <= 20'd0;
                    st  <= S_ISSUE;
                end else begin
                    dly <= dly + 20'd1;
                end
            end

            S_ERR: begin
                ok <= 1'b0;
                if (dly == T_AFTER) begin
                    dly  <= 20'd0;
                    step <= 4'd0;
                    st   <= S_ISSUE;
                end else begin
                    dly <= dly + 20'd1;
                end
            end

            default: st <= S_POWER;
            endcase
        end
    end

endmodule
