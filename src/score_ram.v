// score_ram.v —— 下载曲谱存储 (真双口 BRAM)
module score_ram #(
    parameter AW = 11,  // 地址位宽 -> 2^11 = 2048 字节
    parameter DW = 8
)(
    //  ---- 写口 (27MHz) ----
    input  wire            wclk,
    input  wire            we,
    input  wire [AW-1:0]   waddr,
    input  wire [DW-1:0]   wdata,
    //  ---- 读口 (3MHz) ----
    input  wire            rclk,
    input  wire [AW-1:0]   raddr,
    output reg  [DW-1:0]   rdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge wclk) begin
        if (we) mem[waddr] <= wdata;
    end

    always @(posedge rclk) begin
        rdata <= mem[raddr];
    end
endmodule
