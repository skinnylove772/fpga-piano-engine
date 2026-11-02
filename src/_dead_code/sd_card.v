// sd_card.v —— TF/SD 卡 SPI 模式控制器 (初始化 / 读块 / 写块)
module sd_card #(
    parameter [7:0]  DIV_INIT  = 8'd68,
    parameter [7:0]  DIV_DATA  = 8'd16,
                                        //    0xFE 一直不来 (err=7)。降速先确认读通路。
    parameter [19:0] PWR_BYTES = 20'd16  // 上电先送 16 个 0xFF = 128 时钟 (>74)
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,  // 单拍启动
    input  wire [1:0]  op,  // 0=INIT 1=READ 2=WRITE
    input  wire [31:0] lba,  // 起始扇区
    input  wire [1:0]  nblk,  // 块数-1 (2KB -> 3)
    output reg         busy,
    output reg         done,  // 单拍
    output reg         err_o,

    output reg  [10:0] ram_addr,
    output reg  [7:0]  ram_dout,
    output reg         ram_we,
    input  wire [7:0]  ram_din,

    output wire [4:0]  state_o,
    output wire [3:0]  err_code,
    output reg  [31:0] ocr_o,

    output reg         sd_cs_n,
    output reg         sd_clk,
    output reg         sd_mosi,
    input  wire        sd_miso
);

    localparam [1:0] OP_INIT = 2'd0, OP_READ = 2'd1, OP_WRITE = 2'd2;

    localparam [4:0] S_IDLE    = 5'd0,
                     S_POWER   = 5'd1,
                     S_ISS     = 5'd2,
                     S_C0      = 5'd3,   S_C0_CHK  = 5'd4,
                     S_C8      = 5'd5,   S_C8_CHK  = 5'd6,   S_C8_R7  = 5'd7,
                     S_A55     = 5'd8,   S_A55_CHK = 5'd9,
                     S_A41     = 5'd10,  S_A41_CHK = 5'd11,
                     S_C58     = 5'd12,  S_C58_CHK = 5'd13,  S_OCR    = 5'd14,
                     S_OK      = 5'd15,
                     S_FAIL    = 5'd16,
                     S_RD      = 5'd17,  S_RD_CHK  = 5'd18,  S_RD_TOK = 5'd19,
                     S_RD_DAT  = 5'd20,  S_RD_CRC  = 5'd21,  S_RD_NEXT= 5'd22,

                     S_FIN     = 5'd31;

    localparam [3:0] EC_NONE = 4'd0,
                     EC_CMD0 = 4'd1,
                     EC_CMD8 = 4'd2,
                     EC_A41  = 4'd3,
                     EC_READ = 4'd4,
                     EC_WRITE= 4'd5;

    reg  [7:0] s_tx;
    reg  [7:0] s_rx;
    reg  [2:0] s_bit;
    reg  [7:0] s_div;
    reg        s_ph;
    reg        s_busy;
    reg        s_done;
    reg        s_seen;
    reg  [7:0] s_div_use;

    reg        tx_start;
    reg  [7:0] txb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_tx      <= 8'hFF;
            s_rx      <= 8'hFF;
            s_bit     <= 3'd0;
            s_div     <= 8'd0;
            s_ph      <= 1'b0;
            s_busy    <= 1'b0;
            s_done    <= 1'b0;
            s_seen    <= 1'b0;
            sd_clk    <= 1'b0;
            sd_mosi   <= 1'b1;
        end else begin
            s_done <= 1'b0;
            if (!tx_start) s_seen <= 1'b0;

            if (tx_start && !s_busy && !s_seen) begin
                s_seen  <= 1'b1;
                s_busy  <= 1'b1;
                s_bit   <= 3'd7;
                s_div   <= 8'd0;
                s_ph    <= 1'b0;
                s_tx    <= txb;
                sd_clk  <= 1'b0;
                sd_mosi <= txb[7];
            end else if (s_busy) begin
                if (s_div >= s_div_use) begin
                    s_div <= 8'd0;
                    if (!s_ph) begin
                        s_ph   <= 1'b1;
                        sd_clk <= 1'b1;
                        s_rx   <= {s_rx[6:0], sd_miso};
                    end else begin
                        s_ph   <= 1'b0;
                        sd_clk <= 1'b0;
                        if (s_bit == 3'd0) begin
                            s_busy <= 1'b0;
                            s_done <= 1'b1;
                        end else begin
                            s_bit   <= s_bit - 3'd1;
                            sd_mosi <= s_tx[s_bit - 3'd1];
                        end
                    end
                end else s_div <= s_div + 8'd1;
            end else begin
                sd_mosi <= 1'b1;
            end
        end
    end

    reg  [4:0]  st;
    reg  [4:0]  ret_st;
    reg  [3:0]  err_c;
    reg  [31:0] ocr_sr;
    reg  [5:0]  i_cmd;
    reg  [31:0] i_arg;
    reg  [7:0]  i_crc;
    reg  [2:0]  iph;
    reg  [7:0]  r1;
    reg  [7:0]  nff;
    reg  [9:0]  dcnt;
    reg  [1:0]  blk;
    reg  [1:0]  nblk_r;
    reg  [31:0] lba_cur;
    reg  [7:0]  atry;
    reg  [19:0] pw;

    assign state_o  = st;
    assign err_code = err_c;

    wire bdone = s_done;
    wire bidle = !tx_start;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            ret_st   <= S_IDLE;
            err_c    <= EC_NONE;
            ocr_sr   <= 32'd0;
            ocr_o    <= 32'd0;
            i_cmd    <= 6'd0;
            i_arg    <= 32'd0;
            i_crc    <= 8'hFF;
            iph      <= 3'd0;
            r1       <= 8'hFF;
            nff      <= 8'd0;
            dcnt     <= 10'd0;
            blk      <= 2'd0;
            nblk_r   <= 2'd0;
            lba_cur  <= 32'd0;
            atry     <= 8'd0;
            pw       <= 20'd0;
            busy     <= 1'b0;
            done     <= 1'b0;
            err_o    <= 1'b0;
            tx_start <= 1'b0;
            txb      <= 8'hFF;
            ram_addr <= 11'd0;
            ram_dout <= 8'd0;
            ram_we   <= 1'b0;
            sd_cs_n  <= 1'b1;
            s_div_use<= DIV_INIT;
        end else begin
            ram_we <= 1'b0;

            case (st)

            S_IDLE: begin
                busy     <= 1'b0;
                done     <= 1'b0;
                tx_start <= 1'b0;
                if (start) begin
                    busy    <= 1'b1;
                    err_o   <= 1'b0;
                    err_c   <= EC_NONE;
                    lba_cur <= lba;
                    nblk_r  <= nblk;
                    blk     <= 2'd0;
                    dcnt    <= 10'd0;
                    atry    <= 8'd0;
                    pw      <= 20'd0;
                    nff     <= 8'd0;
                    iph     <= 3'd0;
                    if (op == OP_INIT) begin
                        s_div_use <= DIV_INIT;
                        st        <= S_POWER;
                    end else begin
                        s_div_use <= DIV_DATA;
                        sd_cs_n   <= 1'b0;
                        i_cmd  <= 6'd17;
                        i_arg  <= lba;
                        i_crc  <= 8'hFF;
                        ret_st <= S_RD_CHK;
                        st     <= S_ISS;
                    end
                end
            end

            S_POWER: begin
                if (bidle) begin
                    if (pw >= PWR_BYTES) begin
                        pw <= 20'd0;
                        st <= S_C0;
                    end else begin
                        txb      <= 8'hFF;
                        tx_start <= 1'b1;
                    end
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    pw       <= pw + 20'd1;
                end
            end

            S_ISS: begin
                if (bidle) begin
                    if (iph == 3'd0) begin
                        txb <= {2'b01, i_cmd};  tx_start <= 1'b1;
                    end else if (iph == 3'd1) begin
                        txb <= i_arg[31:24];    tx_start <= 1'b1;
                    end else if (iph == 3'd2) begin
                        txb <= i_arg[23:16];    tx_start <= 1'b1;
                    end else if (iph == 3'd3) begin
                        txb <= i_arg[15:8];     tx_start <= 1'b1;
                    end else if (iph == 3'd4) begin
                        txb <= i_arg[7:0];      tx_start <= 1'b1;
                    end else if (iph == 3'd5) begin
                        txb <= i_crc;           tx_start <= 1'b1;
                    end else begin
                        txb <= 8'hFF;           tx_start <= 1'b1;
                    end
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    if (iph < 3'd6) begin
                        iph <= iph + 3'd1;
                    end else begin
                        if (!s_rx[7]) begin
                            r1  <= s_rx;
                            iph <= 3'd0;
                            nff <= 8'd0;
                            st  <= ret_st;
                        end else if (nff >= 8'd7) begin
                            r1  <= 8'hFF;
                            iph <= 3'd0;
                            nff <= 8'd0;
                            st  <= ret_st;
                        end else begin
                            nff <= nff + 8'd1;
                        end
                    end
                end
            end

            S_C0: begin
                sd_cs_n  <= 1'b0;
                i_cmd    <= 6'd0;
                i_arg    <= 32'd0;
                i_crc    <= 8'h95;
                iph      <= 3'd0;
                nff      <= 8'd0;
                ret_st   <= S_C0_CHK;
                tx_start <= 1'b0;
                st       <= S_ISS;
            end
            S_C0_CHK: begin
                if (r1 != 8'h01) begin
                    err_c <= EC_CMD0;
                    st    <= S_FIN;
                end else st <= S_C8;
            end

            S_C8: begin
                i_cmd    <= 6'd8;
                i_arg    <= 32'h0000_01AA;
                i_crc    <= 8'h87;
                iph      <= 3'd0;
                nff      <= 8'd0;
                ret_st   <= S_C8_CHK;
                tx_start <= 1'b0;
                st       <= S_ISS;
            end
            S_C8_CHK: begin
                if (r1 != 8'h01) begin
                    err_c <= EC_CMD8;
                    st    <= S_FIN;
                end else begin
                    nff <= 8'd0;
                    st  <= S_C8_R7;
                end
            end
            S_C8_R7: begin
                if (bidle) begin
                    txb <= 8'hFF;  tx_start <= 1'b1;
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    if (nff >= 8'd3) st <= S_A55;
                    else             nff <= nff + 8'd1;
                end
            end

            S_A55: begin
                i_cmd    <= 6'd55;
                i_arg    <= 32'd0;
                i_crc    <= 8'hFF;
                iph      <= 3'd0;
                nff      <= 8'd0;
                ret_st   <= S_A55_CHK;
                tx_start <= 1'b0;
                st       <= S_ISS;
            end
            S_A55_CHK: begin
                nff <= 8'd0;
                st  <= S_A41;
            end

            S_A41: begin
                i_cmd    <= 6'd41;
                i_arg    <= 32'h4000_0000;  //  HCS=1 (支持 SDHC 扇区寻址)
                i_crc    <= 8'hFF;
                iph      <= 3'd0;
                nff      <= 8'd0;
                ret_st   <= S_A41_CHK;
                tx_start <= 1'b0;
                st       <= S_ISS;
            end
            S_A41_CHK: begin
                if (r1 == 8'h00) begin
                    st <= S_C58;
                end else if (atry >= 8'd250) begin
                    err_c <= EC_A41;
                    st    <= S_FIN;
                end else begin
                    atry <= atry + 8'd1;
                    st   <= S_A55;
                end
            end

            S_C58: begin
                i_cmd    <= 6'd58;
                i_arg    <= 32'd0;
                i_crc    <= 8'hFF;
                iph      <= 3'd0;
                nff      <= 8'd0;
                ret_st   <= S_C58_CHK;
                tx_start <= 1'b0;
                st       <= S_ISS;
            end
            S_C58_CHK: begin
                if (r1 != 8'h00) begin
                    err_c <= EC_A41;
                    st    <= S_FIN;
                end else begin
                    nff    <= 8'd0;
                    ocr_sr <= 32'd0;
                    st     <= S_OCR;
                end
            end
            S_OCR: begin
                if (bidle) begin
                    txb <= 8'hFF;  tx_start <= 1'b1;
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    ocr_sr   <= {ocr_sr[23:0], s_rx};
                    if (nff >= 8'd3) begin
                        ocr_o <= {ocr_sr[23:0], s_rx};
                        st    <= S_OK;
                    end else nff <= nff + 8'd1;
                end
            end

            S_OK: begin
                busy     <= 1'b0;
                done     <= 1'b1;
                err_o    <= 1'b0;
                sd_cs_n  <= 1'b1;
                tx_start <= 1'b0;
                st       <= S_IDLE;
            end
            S_FIN: begin
                busy     <= 1'b0;
                done     <= 1'b1;
                err_o    <= 1'b1;
                sd_cs_n  <= 1'b1;
                tx_start <= 1'b0;
                st       <= S_IDLE;
            end

            S_RD: begin
                sd_cs_n  <= 1'b0;
                i_cmd    <= 6'd17;
                i_arg    <= lba_cur;
                i_crc    <= 8'hFF;
                iph      <= 3'd0;
                nff      <= 8'd0;
                ret_st   <= S_RD_CHK;
                tx_start <= 1'b0;
                st       <= S_ISS;
            end
            S_RD_CHK: begin
                if (r1 == 8'hFF) begin
                    err_c <= 4'd6;  //  CMD17 完全没有响应
                    st    <= S_FIN;
                end else if (r1 != 8'h00) begin
                    err_c <= {4'd0, r1[3:0]} + 4'd8;  //  响应非 0, 把低 4 位编进码里
                    st    <= S_FIN;
                end else begin
                    nff <= 8'd0;
                    st  <= S_RD_TOK;
                end
            end
            S_RD_TOK: begin
                if (bidle) begin
                    txb <= 8'hFF;  tx_start <= 1'b1;
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    if (s_rx == 8'hFE) begin
                        dcnt <= 10'd0;
                        st   <= S_RD_DAT;
                    end else if (nff >= 8'd250) begin
                        err_c <= 4'd7;  //  等数据令牌 0xFE 超时
                        st    <= S_FIN;
                    end else nff <= nff + 8'd1;
                end
            end
            S_RD_DAT: begin
                if (bidle) begin
                    txb <= 8'hFF;  tx_start <= 1'b1;
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    ram_addr <= {blk, dcnt[8:0]};
                    ram_dout <= s_rx;
                    ram_we   <= 1'b1;
                    if (dcnt >= 10'd511) begin
                        nff <= 8'd0;
                        st  <= S_RD_CRC;
                    end else dcnt <= dcnt + 10'd1;
                end
            end
            S_RD_CRC: begin
                if (bidle) begin
                    txb <= 8'hFF;  tx_start <= 1'b1;
                end else if (bdone) begin
                    tx_start <= 1'b0;
                    if (nff >= 8'd1) st <= S_RD_NEXT;
                    else             nff <= nff + 8'd1;
                end
            end
            S_RD_NEXT: begin
                if (blk >= nblk_r) begin
                    st <= S_OK;
                end else begin
                    blk     <= blk + 2'd1;
                    lba_cur <= lba_cur + 32'd1;
                    st      <= S_RD;
                end
            end

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
