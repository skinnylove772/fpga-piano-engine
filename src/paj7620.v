// paj7620.v —— PAJ7620U2 手势识别驱动
module paj7620 #(
    parameter [6:0]  DEV       = 7'h73,  // PAJ7620U2 的 I2C 地址 (7 位)

    //   DIV 的含义是"每个相位多少个 27MHz 时钟", 一个位有 4 个相位:
    //       SCL = 27MHz / (DIV * 4)
    //   DIV=2700 -> 2.5kHz, 位宽 400us, 一次读事务约 15ms
    parameter [15:0] DIV_FIXED = 16'd340,

    //---- 时序参数 (27MHz) ----
    parameter [20:0] T_POWER   = 21'd270000,  // 10ms   上电等待 (文章 1000us, 更保守)
    parameter [20:0] T_WAKE    = 21'd27000,  // 1ms    唤醒事务之后的等待 (文章 1000us)
    parameter [20:0] T_GAP     = 21'd2700,  // 0.1ms  两条配置之间的间隙
    parameter [20:0] T_AFTER   = 21'd1350000,  // 50ms   配置表写完后等引擎稳定
    parameter [20:0] T_CYCLE   = 21'd540000,  // 20ms   两轮读手势之间的间隔
    parameter [20:0] T_RETRY   = 21'd270000,  // 10ms   初始化失败后的重试间隔

    //---- 连续读手势失败几次才整颗重初始化 ----
    //   4 位最大 15; 取 8 是为了屏幕显示 70+8 = 78, 不会溢出成乱码。
    parameter [3:0]  ERR_MAX   = 4'd8,

    parameter [3:0]  RETRY_MAX = 4'd4,

    parameter        RD_MERGE  = 1'b0,

    parameter        GES_STRICT = 1'b1,

    parameter [23:0] T_BLANK  = 24'd8100000
)(
    input  wire        clk,  // 27MHz
    input  wire        rst_n,

    //---- I2C 引脚 (开漏三态由顶层接) ----
    output wire        scl,
    output wire        sda_oe,  // 1 = 本模块驱动 SDA
    output wire        sda_o,
    input  wire        sda_i,

    output reg  [7:0]  ges1_raw,  // 0x43 原始字节 (上/下/左/右/前/后/顺/逆)
    output reg  [7:0]  ges2_raw,  // 0x44 原始字节 (bit0 = 挥动)
    output wire [3:0]  ges,  // 0=无手势, 1..9 = 九种手势 (见下面的解码)
    output reg  [3:0]  rej_cnt,

    //---- 诊断 ----
    output reg  [7:0]  wa0,  // §4.4 读 0x00 的实际值 (应为 0x20)
    output reg  [7:0]  wa1,
    output reg  [3:0]  phase,  // 0=正常 1=唤醒 2=Bank0+握手 3=写表 4=等稳定
    output reg         err_seen,  // 1 = 最近一笔事务从机没应答
    output reg  [3:0]  err_cnt,  // 连续读手势失败计数 (到 ERR_MAX 就重初始化)
    output reg         tog,  // 手势数据更新握手 (跨时钟域用)
    output wire        busy,  // 1 = 还在初始化
    //   "52/53 来回跳"就只是一个现象, 分不出是**偶发不应答**(重发就好)
    //   还是**某一条寄存器根本不允许写**(得改表)。这两种病修法完全不同。
    output reg  [5:0]  fail_idx
);

    localparam S_POWER = 4'd0,
               S_WAKE  = 4'd1,  // §4.1 发唤醒事务 (只含从机地址)
               S_WAKE2 = 4'd2,  // §4.1 唤醒之后的等待
               S_BANK0 = 4'd3,  // §4.2 激活 BANK0
               S_CFG0  = 4'd4,  // §4.3 配置 0x00 寄存器
               S_RD0   = 4'd5,  // §4.4 读 0x00 (必须 0x20)
               S_RD1   = 4'd6,  //      读 0x01 (纯诊断, 不判断)
               S_INIT  = 4'd7,  // §4.5 写配置表
               S_AFTER = 4'd8,  //      写完之后等引擎稳定
               S_READ  = 4'd9,  // §4.6 读 0x43
               S_WAIT  = 4'd10,  //      等一笔 I2C 事务结束
               S_GAP   = 4'd11,  //      事务间隙
               S_CYCLE = 4'd12,  //      两轮读之间的间隔
               S_RETRY = 4'd13;  //      初始化失败后从头来

    localparam P_WAKE  = 4'd0,
               P_BANK0 = 4'd1,
               P_CFG0  = 4'd2,
               P_RD0   = 4'd3,
               P_RD1   = 4'd4,
               P_INIT  = 4'd5,
               P_READ  = 4'd6;

    reg  [3:0]  st;
    reg  [3:0]  st_prev;
    reg  [20:0] dly;
    reg  [3:0]  tretry;
    //     只在 RD_MERGE=0 (两个寄存器分开读) 时用得上。
    reg         rstep;

    reg  [23:0] blank_cnt;
    reg         blank_ld;
    reg  [3:0]  ges_hold;

    wire [7:0]  nx_ges1 = RD_MERGE ? rd_data  : ((rstep == 1'b0) ? rd_data  : ges1_raw);
    wire [7:0]  nx_ges2 = RD_MERGE ? rd_data2 : ((rstep == 1'b0) ? ges2_raw : rd_data);
    wire [8:0]  nx_gbit = {nx_ges2[0], nx_ges1};
    wire        nx_none = (nx_gbit == 9'd0);
    wire        nx_one  = ((nx_gbit & (nx_gbit - 9'd1)) == 9'd0);
    wire        nx_rej  = GES_STRICT && !nx_none && !nx_one;
    //   这一笔读完是不是"一轮结束"了
    wire        rd_round_end = RD_MERGE || (rstep == 1'b1);

    localparam [5:0] FIDX_NONE = 6'd63;

    //---- §4.4 唤醒握手: 0x00 寄存器应该读出的值 ----
    //     文章 / STM32 / ALIENTEK 三份都**不查**它 (见文件头)。
    localparam [7:0] WAKE0 = 8'h20;

    // 二、这一拍要发的事务
    //     i2c_master 在 go 当拍锁存 dev/reg/wr/rd/wake (见 i2c_master.v 的输入锁存)。
    //     如果 go 用寄存器打一拍, 它到达主机时 st 已经跳到 S_WAIT, seq_reg 已经
    //     塌回默认值 0x00 —— go 和数据错开一拍, 主机锁到的永远是 0x00。
    reg  [7:0]  seq_reg;
    reg  [7:0]  seq_dat;
    reg         seq_rd;
    reg         seq_wake;
    reg  [1:0]  seq_len;

    wire [7:0]  rd_data;
    wire [7:0]  rd_data2;
    wire        i2c_busy, i2c_done, i2c_ackerr;

    //---- 配置表定序器 (文章里的 prj7620_cfg 模块) ----
    wire        cfg_start;  // 定序器: "这一条请发出去"
    wire        cfg_fin;  // 定序器: "整张表写完了"
    wire [5:0]  cfg_num;  // 当前写到第几条 (诊断/扩展用)
    wire [15:0] cfg_word;  // 当前这一条的 {寄存器号, 数据}
    reg         cfg_done;  // 顶层 -> 定序器: 这一条已经写完 (单拍)
    reg         cfg_clr;  // 顶层 -> 定序器: 清回第 0 条     (单拍)

    wire in_txn = (st == S_WAKE) || (st == S_BANK0) || (st == S_CFG0) ||
                  (st == S_RD0)  || (st == S_RD1)   || (st == S_READ);
    wire seq_go = (in_txn || ((st == S_INIT) && cfg_start)) && !i2c_busy;

    always @* begin
        seq_reg  = 8'h00;
        seq_dat  = 8'h00;
        seq_rd   = 1'b0;
        seq_wake = 1'b0;
        seq_len  = 2'd1;  // 默认只读一个字节 (写事务不看它)
        case (st)
            //---- §4.1 唤醒: **只发从机地址**, 不发寄存器号也不发数据 ----
            S_WAKE : seq_wake = 1'b1;
            //---- §4.2 激活 BANK0: 往 0xEF 写 0x00 ----
            S_BANK0: begin seq_reg = 8'hEF; seq_dat = 8'h00; end
            //---- §4.3 配置 0x00 寄存器: 往 0x00 写 0x00 ----
            S_CFG0 : begin seq_reg = 8'h00; seq_dat = 8'h00; end
            //---- §4.4 读 0x00 (唤醒握手) ----
            S_RD0  : begin seq_rd  = 1'b1; seq_reg = 8'h00; end
            //---- 诊断: 读 0x01 ----
            S_RD1  : begin seq_rd  = 1'b1; seq_reg = 8'h01; end
            //---- §4.5 写配置表: 高字节 = 寄存器号, 低字节 = 数据 ----
            S_INIT : begin seq_reg = cfg_word[15:8]; seq_dat = cfg_word[7:0]; end
            //---- §4.6 循环读手势标志 ----
            //         0x43 -> 上/下/左/右/前/后/顺时针/逆时针
            //         0x44 -> 挥动
            //      文章 §4.6 说"0x44 不用", 照它做就只剩 4 种手势。
            S_READ : begin
                seq_rd  = 1'b1;
                seq_reg = RD_MERGE ? 8'h43 : ((rstep == 1'b0) ? 8'h43 : 8'h44);
                seq_len = RD_MERGE ? 2'd2  : 2'd1;
            end
            default: ;
        endcase
    end

    function [3:0] ges_of;
        input [8:0] gb;  // {0x44 的 bit0, 0x43 的 8 位}
        begin
            ges_of = gb[8] ? 4'd9  // 挥动     (0x44 bit0)
                   : gb[7] ? 4'd8  // 逆时针
                   : gb[6] ? 4'd7  // 顺时针
                   : gb[5] ? 4'd6  // 向后
                   : gb[4] ? 4'd5  // 向前
                   : gb[3] ? 4'd4  // 向右
                   : gb[2] ? 4'd3  // 向左
                   : gb[1] ? 4'd2  // 向下
                   : gb[0] ? 4'd1  // 向上
                   :         4'd0;
        end
    endfunction

    wire [8:0]  gbits  = {ges2_raw[0], ges1_raw};
    wire        onehot = (gbits != 9'd0) && ((gbits & (gbits - 9'd1)) == 9'd0);

    assign ges  = ges_hold;
    assign busy = (phase != 4'd0);

    i2c_master #(.DIV_DEFAULT(DIV_FIXED)) u_i2c (
        .clk      (clk),
        .rst_n    (rst_n),
        .div_i    (DIV_FIXED),
        .go       (seq_go),
        .dev      (DEV),
        .reg_addr (seq_reg),
        .rd       (seq_rd),
        .wr_data  (seq_dat),
        .wake     (seq_wake),
        .rd_len   (seq_len),
        .rd_data  (rd_data),
        .rd_data2 (rd_data2),
        .busy     (i2c_busy),
        .done     (i2c_done),
        .ack_err  (i2c_ackerr),
        .step_dbg (),  // 诊断旁路未用
        .scl      (scl),
        .sda_oe   (sda_oe),
        .sda_o    (sda_o),
        .sda_i    (sda_i)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) blank_cnt <= 24'd0;
        else if (blank_ld)            blank_cnt <= T_BLANK;
        else if (blank_cnt != 24'd0)  blank_cnt <= blank_cnt - 24'd1;
    end

    paj7620_cfg u_cfg (
        .clk       (clk),
        .rst_n     (rst_n),
        .clr       (cfg_clr),
        .done      (cfg_done),
        .i2c_start (cfg_start),
        .fin       (cfg_fin),
        .reg_num   (cfg_num),
        .cfg_word  (cfg_word)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_POWER;
            dly      <= 21'd0;
            ges1_raw <= 8'd0;
            ges2_raw <= 8'd0;
            wa0      <= 8'd0;
            wa1      <= 8'd0;
            phase    <= 4'd1;  // 上电就算"正在初始化"
            err_seen <= 1'b0;
            err_cnt  <= 4'd0;
            tretry   <= 4'd0;
            rstep    <= 1'b0;
            //     两个 always 块写同一个 reg 会被综合器判成
            //     EX2000 "constantly driven from multiple places"。
            blank_ld  <= 1'b0;
            ges_hold  <= 4'd0;
            rej_cnt   <= 4'd0;
            fail_idx <= FIDX_NONE;  // 还没失败过
            tog      <= 1'b0;
            cfg_done <= 1'b0;
            cfg_clr  <= 1'b0;
        end else begin
            //   (Verilog 里同一执行路径上的后一次赋值生效)。
            cfg_done <= 1'b0;
            cfg_clr  <= 1'b0;
            blank_ld <= 1'b0;
            case (st)
            S_POWER: begin
                phase <= 4'd1;
                if (dly == T_POWER) begin
                    dly <= 21'd0;
                    st  <= S_WAKE;
                end else begin
                    dly <= dly + 21'd1;
                end
            end

            S_WAKE: begin
                if (!i2c_busy) st <= S_WAIT;
            end
            S_WAKE2: begin
                if (dly == T_WAKE) begin
                    dly   <= 21'd0;
                    phase <= 4'd2;
                    st    <= S_BANK0;
                end else begin
                    dly <= dly + 21'd1;
                end
            end

            // 发一笔事务就去等 (切 Bank / 配置 0x00 / 握手读 / 循环读都从这里进)
            //   本拍 go 已经和寄存器号/数据一起送到主机了, 这里只管转状态。
            S_BANK0, S_CFG0, S_RD0, S_RD1, S_READ: begin
                if (!i2c_busy) st <= S_WAIT;
            end

            S_INIT: begin
                if (cfg_fin) begin
                    fail_idx <= FIDX_NONE;
                    tretry   <= 4'd0;
                    phase    <= 4'd4;
                    dly      <= 21'd0;
                    st       <= S_AFTER;
                end else if (!i2c_busy && cfg_start) begin
                    st <= S_WAIT;
                end
            end

            S_WAIT: begin
                if (i2c_done) begin
                    if (i2c_ackerr) begin
                        // 从机没应答 —— 地址不对 / 没接好 / 没供电 / 总线被拉死
                        err_seen <= 1'b1;
                        if (st_prev == P_READ) begin
                            if (err_cnt >= ERR_MAX) begin
                                err_cnt <= 4'd0;
                                dly     <= 21'd0;
                                st      <= S_RETRY;
                            end else begin
                                err_cnt <= err_cnt + 4'd1;
                                dly     <= 21'd0;
                                st      <= S_GAP;
                            end
                        end else if (st_prev == P_INIT) begin
                            if (tretry < RETRY_MAX) begin
                                tretry <= tretry + 4'd1;
                                dly    <= 21'd0;
                                st     <= S_GAP;  // 同一个 reg_num 再发一次
                            end else begin
                                fail_idx <= cfg_num;
                                tretry   <= 4'd0;
                                err_cnt  <= 4'd0;
                                dly      <= 21'd0;
                                st       <= S_RETRY;
                            end
                        end else begin
                            err_cnt <= 4'd0;
                            dly     <= 21'd0;
                            st      <= S_RETRY;
                        end
                    end else begin
                        err_seen <= 1'b0;
                        case (st_prev)
                        //---- §4.1 唤醒事务成功 -> 去等 1ms ----
                        P_WAKE : begin
                            dly <= 21'd0;
                            st  <= S_WAKE2;
                        end
                        //---- §4.2 / §4.3 写完 -> 下一笔 ----
                        P_BANK0: begin dly <= 21'd0; st <= S_GAP; end
                        P_CFG0 : begin dly <= 21'd0; st <= S_GAP; end
                        //---- §4.4 读 0x00: 必须是 0x20 ----
                        P_RD0  : begin
                            wa0 <= rd_data;
                            if (rd_data == WAKE0) begin
                                dly <= 21'd0;
                                st  <= S_GAP;  // 对了 -> 下一笔 (诊断读 0x01)
                            end else begin
                                // 没读到 0x20 = 芯片还没醒, 这时写配置表是没用的,
                                // 等一会儿从唤醒开始重来。屏幕会直接显示这个值。
                                dly <= 21'd0;
                                st  <= S_RETRY;
                            end
                        end
                        P_RD1  : begin
                            wa1     <= rd_data;
                            phase   <= 4'd3;  // 进入"写配置表"阶段
                            cfg_clr <= 1'b1;  // 清定序器, 准备从第 0 条开始写
                            dly     <= 21'd0;
                            st      <= S_GAP;
                        end
                        //---- §4.5 写完一条 -> 通知定序器, 进下一条 ----
                        P_INIT : begin
                            cfg_done <= 1'b1;
                            tretry   <= 4'd0;  // 这一条成功了 -> 重发计数清零
                            dly      <= 21'd0;
                            st       <= S_GAP;
                        end
                        //---- §4.6 / §4.7 读到手势数据 ----
                        default: begin
                            //     事务同时给回两个字节。
                            if (RD_MERGE) begin
                                ges1_raw <= rd_data;
                                ges2_raw <= rd_data2;
                            end else if (rstep == 1'b0) begin
                                ges1_raw <= rd_data;
                            end else begin
                                ges2_raw <= rd_data;
                            end
                            if (nx_ges1 != ges1_raw || nx_ges2 != ges2_raw) tog <= ~tog;

                            if (rd_round_end) begin
                                if (nx_rej) begin
                                    // 有手势位、但不是"恰好一位" -> 乱码, 挡掉并计数。
                                    // 屏幕上会出现 8x, 那就是"读回来的是垃圾"的铁证。
                                    if (rej_cnt != 4'hF) rej_cnt <= rej_cnt + 4'd1;
                                    ges_hold <= 4'd0;
                                end else if (nx_none) begin
                                    ges_hold <= 4'd0;  // 这一轮没有手势
                                end else if (blank_cnt != 24'd0) begin
                                    //   重新计时会让不应期自己续期, 一次挥动就再也出不来。
                                    //   (这里不动 blank_cnt, 让它照常数完。)
                                    ges_hold <= 4'd0;
                                end else begin
                                    ges_hold <= ges_of(nx_gbit);
                                    rej_cnt  <= 4'd0;
                                    blank_ld <= 1'b1;
                                end
                            end

                            //   只有持续失败才会单调涨到 ERR_MAX。
                            if (err_cnt != 4'd0) err_cnt <= err_cnt - 4'd1;
                            dly <= 21'd0;
                            //       S_WAIT 的失败分支把状态送去 S_CYCLE, 而 S_CYCLE
                            //       之后是 S_READ, 于是自动重读**刚才失败的那一笔**。
                            if (RD_MERGE) begin
                                st <= S_CYCLE;
                            end else if (rstep == 1'b0) begin
                                rstep <= 1'b1;  // 0x43 读完 -> 接着读 0x44
                                st    <= S_GAP;
                            end else begin
                                rstep <= 1'b0;  // 0x44 也读完 -> 这一轮结束
                                st    <= S_CYCLE;
                            end
                        end
                        endcase
                    end
                end
            end

            S_GAP: begin
                if (dly == T_GAP) begin
                    dly <= 21'd0;
                    case (st_prev)
                    P_BANK0: st <= S_CFG0;  // §4.2 -> §4.3
                    P_CFG0 : st <= S_RD0;  // §4.3 -> §4.4
                    P_RD0  : st <= S_RD1;  // §4.4 -> 诊断读 0x01
                    P_RD1  : st <= S_INIT;  // 诊断完 -> §4.5 写表
                    P_INIT : st <= S_INIT;  // 表还没写完 -> 继续下一条
                    default: st <= S_READ;  // §4.6 循环读手势
                    endcase
                end else begin
                    dly <= dly + 21'd1;
                end
            end

            S_AFTER: begin
                if (dly == T_AFTER) begin
                    dly   <= 21'd0;
                    phase <= 4'd0;  // 0 = 正常工作
                    st    <= S_READ;
                end else begin
                    dly <= dly + 21'd1;
                end
            end

            S_CYCLE: begin
                if (dly == T_CYCLE) begin
                    dly <= 21'd0;
                    st  <= S_READ;
                end else begin
                    dly <= dly + 21'd1;
                end
            end

            S_RETRY: begin
                if (dly == T_RETRY) begin
                    dly <= 21'd0;
                    st  <= S_WAKE;
                end else begin
                    dly <= dly + 21'd1;
                end
            end

            default: st <= S_POWER;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) st_prev <= P_WAKE;
        else if (st == S_WAKE)  st_prev <= P_WAKE;
        else if (st == S_BANK0) st_prev <= P_BANK0;
        else if (st == S_CFG0)  st_prev <= P_CFG0;
        else if (st == S_RD0)   st_prev <= P_RD0;
        else if (st == S_RD1)   st_prev <= P_RD1;
        else if (st == S_INIT)  st_prev <= P_INIT;
        else if (st == S_READ || st == S_CYCLE) st_prev <= P_READ;
    end

endmodule

module paj7620_cfg #(
    parameter [5:0] CFG_LEN = 6'd52
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,
    input  wire        done,
    output reg         i2c_start,
    output reg         fin,
    output reg  [5:0]  reg_num,
    output reg  [15:0] cfg_word
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_num   <= 6'd0;
            i2c_start <= 1'b0;
            fin       <= 1'b0;
        end else if (clr) begin
            reg_num   <= 6'd0;
            i2c_start <= 1'b0;
            fin       <= 1'b0;
        end else if (fin) begin
            i2c_start <= 1'b0;
        end else if (!i2c_start) begin
            //   那几个周期它一直都有效, 顶层一回到 S_INIT 就能立刻接上。
            //   如果做成单拍脉冲, 那一拍顶层很可能不在 S_INIT, 脉冲就丢了。
            i2c_start <= 1'b1;
        end else if (done) begin
            i2c_start <= 1'b0;
            if (reg_num == CFG_LEN - 6'd1) fin <= 1'b1;
            else                           reg_num <= reg_num + 6'd1;
        end
    end

    always @* begin
        case (reg_num)
        6'd0 : cfg_word = 16'hEF00;
        6'd1 : cfg_word = 16'h3707;
        6'd2 : cfg_word = 16'h3817;
        6'd3 : cfg_word = 16'h3906;
        6'd4 : cfg_word = 16'h41FF;
        6'd5 : cfg_word = 16'h4201;  // 开"挥动"
        6'd6 : cfg_word = 16'h462D;
        6'd7 : cfg_word = 16'h470F;
        6'd8 : cfg_word = 16'h483C;
        6'd9 : cfg_word = 16'h4900;
        6'd10: cfg_word = 16'h4A1E;
        6'd11: cfg_word = 16'h4C20;
        6'd12: cfg_word = 16'h5110;
        6'd13: cfg_word = 16'h5E10;
        6'd14: cfg_word = 16'h6027;
        6'd15: cfg_word = 16'h8042;
        6'd16: cfg_word = 16'h8144;
        6'd17: cfg_word = 16'h8204;
        6'd18: cfg_word = 16'h8B01;
        6'd19: cfg_word = 16'h9006;
        6'd20: cfg_word = 16'h950A;
        6'd21: cfg_word = 16'h960C;
        6'd22: cfg_word = 16'h9705;
        6'd23: cfg_word = 16'h9A14;
        6'd24: cfg_word = 16'h9C3F;
        6'd25: cfg_word = 16'hA519;
        6'd26: cfg_word = 16'hCC19;
        6'd27: cfg_word = 16'hCD0B;
        6'd28: cfg_word = 16'hCE13;
        6'd29: cfg_word = 16'hCF64;
        6'd30: cfg_word = 16'hD021;
        6'd31: cfg_word = 16'hEF01;  // 切 Bank1
        6'd32: cfg_word = 16'h020F;
        6'd33: cfg_word = 16'h0310;
        6'd34: cfg_word = 16'h0402;
        6'd35: cfg_word = 16'h2501;
        6'd36: cfg_word = 16'h2739;
        6'd37: cfg_word = 16'h287F;
        6'd38: cfg_word = 16'h2908;
        6'd39: cfg_word = 16'h3EFF;
        6'd40: cfg_word = 16'h5E3D;
        6'd41: cfg_word = 16'h6596;
        6'd42: cfg_word = 16'h6797;
        6'd43: cfg_word = 16'h69CD;
        6'd44: cfg_word = 16'h6A01;
        6'd45: cfg_word = 16'h6D2C;
        6'd46: cfg_word = 16'h6E01;
        6'd47: cfg_word = 16'h7201;
        6'd48: cfg_word = 16'h7335;
        6'd49: cfg_word = 16'h7400;
        6'd50: cfg_word = 16'h7701;
        6'd51: cfg_word = 16'hEF00;  // 切回 Bank0 (手势标志在 Bank0)
        default: cfg_word = 16'hEF00;
        endcase
    end

endmodule
