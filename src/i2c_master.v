// i2c_master.v —— 精简 I2C 主机 (只做"读/写一个寄存器"这一种事务)
module i2c_master #(
    parameter [15:0] DIV_DEFAULT = 16'd340  // 仅供参考, 实际由 div_i 决定
)(
    input  wire       clk,  // 27MHz
    input  wire       rst_n,

    //---- 运行时波特率选择 (每个相位的时钟数) ----
    input  wire [15:0] div_i,

    //---- 命令接口 ----
    input  wire       go,  // 单拍脉冲: 开始一次事务
    input  wire [6:0] dev,  // 7 位从机地址
    input  wire [7:0] reg_addr,  // 寄存器地址 (两个事务都要先发它)
    input  wire       rd,  // 0 = 写寄存器, 1 = 读寄存器
    input  wire [7:0] wr_data,  // 写模式下要写的数据
    //   wake=1 时这一笔事务变成"只发从机地址, 不发寄存器号、不发数据":
    //       S, dev+W, ACK, P
    //   这就是 PAJ7620U2 数据手册要求的唤醒命令 (dummy write of the slave address),
    //   也是 STM32 驱动里 GS_WakeUp() 干的事 (GS_IIC_Start(); 发 PAJ7620_ID; GS_IIC_Stop();)。
    input  wire       wake,
    //   1 = 老行为 (只读一个字节就 NACK + STOP), 别的器件照旧。
    //   2 = 连续读两个字节 (PAJ7620 的 0x43/0x44 一笔读完, 见下面 S_RECV)。
    //   3 = 最大; 内部计数 rx_cnt 是 2 位, 收到第 3 个字节就满了,
    //       写 0 或 >3 的都会出问题 —— 调用方保证 1..3。
    input  wire [1:0] rd_len,

    output reg  [7:0] rd_data,  // 读模式读回的第 1 个字节
    output reg  [7:0] rd_data2,  // 读模式读回的第 2 个字节 (rd_len>=2 时有效)
    output reg        busy,
    output reg        done,  // 单拍脉冲
    output reg        ack_err,  // 1 = 从机没有应答 (器件没接好 / 地址不对)

    //---- 引脚 ----
    output reg        scl,
    output reg        sda_oe,  // 1 = 本模块驱动 SDA
    output reg        sda_o,
    input  wire       sda_i,

    //   只读的旁路输出, 不参与任何逻辑, 纯给上层做故障定位用。
    //   上层在 ack_err 出现的那一拍采它, 就知道是 3 个字节里的哪一个没被应答。
    //     打一拍的话上层读到的是下一个字节的号, 正好错开一位。
    output wire [1:0] step_dbg
);

    // 相位发生器: 每个相位 div_i 拍, 4 个相位一个位周期
    //     div_i=0 时 div_i-1 会回绕成 0xFFFF, ph_end 几乎不成立 -> 主线卡死,

    reg sda_m1, sda_m2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sda_m1 <= 1'b1;
            sda_m2 <= 1'b1;
        end else begin
            sda_m1 <= sda_i;
            sda_m2 <= sda_m1;
        end
    end
    wire sda_s = sda_m2;  // 同步后的 SDA, 后面一律用它, 不再直接用 sda_i

    reg [15:0] cnt;
    reg [1:0] ph;
    wire      ph_end = (cnt == div_i - 16'd1);
    wire      ph0    = ph_end && (ph == 2'd0);
    wire      ph1    = ph_end && (ph == 2'd1);
    wire      ph2    = ph_end && (ph == 2'd2);
    wire      ph3    = ph_end && (ph == 2'd3);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 16'd0;
            ph  <= 2'd0;
        end else if (ph_end) begin
            cnt <= 16'd0;
            ph  <= ph + 2'd1;
        end else begin
            cnt <= cnt + 16'd1;
        end
    end

    localparam S_IDLE   = 3'd0,
               S_START  = 3'd1,  // 产生 START
               S_SEND   = 3'd2,  // 发一个字节 (8 位 + 1 位 ACK)
               S_RSTART = 3'd3,  // 产生重复 START
               S_RECV   = 3'd4,  // 收一个字节 + 回 NACK
               S_STOP   = 3'd5,  // 产生 STOP
               S_DONE   = 3'd6;

    reg [2:0]  st;
    reg [1:0]  step;  // 发到第几个字节了
    reg [1:0]  rx_cnt;  // 读到第几个字节了 (多字节读)
    reg [1:0]  rlen_q;  // go 当拍锁存下来的"要读几个字节"
    reg [7:0]  shreg;  // 发送移位寄存器 (读的时候用来接数据)
    reg [3:0]  bitn;  // 0..7 = 数据位, 8 = ACK 位

    //     组合而不是打拍 —— ack_err 和 step 是同一拍产生的, 打拍会错开一位。
    assign step_dbg = step;

    // 这一拍要驱动到 SDA 上的值
    reg        sda_nxt;
    reg        sda_oe_nxt;

    reg [6:0] dev_q;
    reg [7:0] reg_q;
    reg [7:0] wr_q;
    reg       rd_q;
    reg       wake_q;
    reg  [7:0] txbyte;
    always @* begin
        case (step)
            2'd0: txbyte = {dev_q, 1'b0};  // 永远是 dev+W
            2'd1: txbyte = reg_q;
            2'd2: txbyte = rd_q ? {dev_q, 1'b1}  // 读模式的第二段: dev+R
                              : wr_q;  // 写模式: 数据
            default: txbyte = 8'h00;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st        <= S_IDLE;
            step      <= 2'd0;
            shreg     <= 8'd0;
            bitn      <= 4'd0;
            scl       <= 1'b1;
            sda_oe    <= 1'b0;
            sda_o     <= 1'b1;
            sda_nxt   <= 1'b1;
            sda_oe_nxt<= 1'b0;
            busy      <= 1'b0;
            done      <= 1'b0;
            ack_err   <= 1'b0;
            rd_data   <= 8'd0;
            rd_data2  <= 8'd0;
            rx_cnt    <= 2'd0;
            rlen_q    <= 2'd1;
            wake_q    <= 1'b0;
        end else begin
            done <= 1'b0;

            case (st)
            S_IDLE: begin
                scl    <= 1'b1;
                sda_oe <= 1'b0;  // 释放 SDA (靠上拉保持高)
                busy   <= 1'b0;
                if (go) begin
                    busy    <= 1'b1;
                    ack_err <= 1'b0;
                    step    <= 2'd0;
                    bitn    <= 4'd0;
                    rx_cnt  <= 2'd0;
                    rlen_q  <= rd_len;
                    dev_q   <= dev;
                    reg_q   <= reg_addr;
                    wr_q    <= wr_data;
                    rd_q    <= rd;
                    wake_q  <= wake;
                    st      <= S_START;
                end
            end

            S_START, S_RSTART: begin
                if (ph0) begin
                    scl    <= 1'b0;
                    sda_oe <= 1'b0;  // 释放 SDA, 让从机放开 ACK
                end else if (ph1) begin
                    sda_oe <= 1'b1;  // SCL 还低: 推挽把 SDA 充到高
                    sda_o  <= 1'b1;
                end else if (ph2) begin
                    scl <= 1'b1;
                end else if (ph3) begin
                    sda_oe <= 1'b1;
                    sda_o  <= 1'b0;  // SCL 已经高, 此刻拉低 = START
                    st   <= S_SEND;
                    bitn <= 4'd0;
                    shreg <= (st == S_RSTART) ? {dev_q, 1'b1} : txbyte;
                end
            end

            S_SEND: begin
                if (ph0) begin
                    scl <= 1'b0;
                    if (bitn <= 4'd7) begin
                        sda_oe <= 1'b1;
                        sda_o  <= shreg[7];  // 先发最高位
                    end else begin
                        sda_oe <= 1'b0;  // ACK 位: 释放 SDA, 让从机拉
                    end
                end else if (ph2) begin
                    scl <= 1'b1;
                end else if (ph3) begin
                    if (bitn <= 4'd7) begin
                        shreg <= {shreg[6:0], 1'b0};
                        bitn  <= bitn + 4'd1;
                    end else begin
                        if (sda_s) ack_err <= 1'b1;
                        //   发完 (第 0 个字节) 立刻 STOP, 不发寄存器号也不发数据。
                        //   线序: S, dev+W, ACK, P —— 正是 PAJ7620U2 的唤醒命令。
                        //     step 永远是 0, 不先拦下来就会掉进 "step<=step+1" 那条路,
                        //     接着又发一个字节 (寄存器号 0x00), 那就不是唤醒事务了。
                        if (wake_q) begin
                            st   <= S_STOP;
                            step <= 2'd0;
                        end else if (step == 2'd2) begin
                            if (rd_q) begin
                                st    <= S_RECV;
                                bitn  <= 4'd0;
                                shreg <= 8'd0;
                            end else begin
                                st    <= S_STOP;
                            end
                            step <= 2'd0;
                        end else if ((step == 2'd1) && rd_q) begin
                            st   <= S_RSTART;  // 读模式: 发完寄存器地址要重复 START
                            step <= 2'd2;
                        end else begin
                            step <= step + 2'd1;
                            st   <= S_SEND;
                            bitn <= 4'd0;
                            //     刚发完字节 0 -> 下一个必须是寄存器地址;
                            //     刚发完字节 1 -> 只能是写模式走到这 (读模式在上面
                            //     已经拐去 S_RSTART) -> 下一个是数据。
                            //   把 dev+W/dev+R 当成字节 1 发出去: 从机照样 ACK,
                            //   但主机实际上在读/写一个错寄存器 —— 波形完全合法,
                            shreg <= (step == 2'd0) ? reg_q : wr_q;
                        end
                    end
                end
            end

            S_RECV: begin
                if (ph0) begin
                    scl <= 1'b0;
                    if (bitn <= 4'd7) begin
                        sda_oe <= 1'b0;  // 数据位: 释放, 让从机驱动
                    end else begin
                        // 第 9 拍: 主机回 ACK / NACK
                        sda_oe <= 1'b1;
                        sda_o  <= (rx_cnt == rlen_q - 2'd1) ? 1'b1 : 1'b0;
                    end
                end else if (ph2) begin
                    scl <= 1'b1;
                end else if (ph3) begin
                    if (bitn <= 4'd7) begin
                        shreg <= {shreg[6:0], sda_s};  // 采样取高电平最后一拍, 同 S_SEND
                        bitn  <= bitn + 4'd1;
                    end else begin
                        // 这一字节收完了
                        if (rx_cnt == 2'd0) rd_data  <= shreg;
                        else                rd_data2 <= shreg;
                        if (rx_cnt == rlen_q - 2'd1) begin
                            st <= S_STOP;  // 最后一个字节 -> 收工
                        end else begin
                            // 还有下一个: 回到数据位, 但**留在 S_RECV**,
                            // 下一拍的 ph0 会把 SCL 拉低, 从机据此送出下一个字节。
                            rx_cnt <= rx_cnt + 2'd1;
                            bitn   <= 4'd0;
                            shreg  <= 8'd0;
                        end
                    end
                end
            end

            S_STOP: begin
                if (ph0) begin
                    scl    <= 1'b0;
                    sda_oe <= 1'b1;
                    sda_o  <= 1'b0;
                end else if (ph1) begin
                    scl <= 1'b1;
                end else if (ph2) begin
                    sda_oe <= 1'b1;  // SCL 高时推挽拉高 SDA -> 上升沿 = STOP
                    sda_o  <= 1'b1;
                end else if (ph3) begin
                    sda_oe <= 1'b0;  // 线已经是高, 换回释放(靠上拉保持)
                    st     <= S_DONE;
                end
            end

            S_DONE: begin
                scl    <= 1'b1;
                sda_oe <= 1'b0;
                busy   <= 1'b0;
                done   <= 1'b1;
                st     <= S_IDLE;
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
