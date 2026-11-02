// wave_rom.v —— 共享带限波表 (BSRAM)
module wave_rom(
    input  wire        clk,
    input  wire [14:0] addr,
    output reg  [15:0] dout
);

    // 32768 x 16 —— 综合器会推断成 BSRAM (32 块)
    //    结论: 想从波表腾 BSRAM, 必须让字数是 2 的幂 (例如相位 512->256,
    //    8x8x256=16384 -> 16 块, 但那会让波表分辨率减半)。这条路不划算。
    reg [15:0] mem [0:32767];
    initial $readmemh("tbl/wave_tbl.mi", mem);
    //   波表是 sim/gen_wavetable.py **生成的数据**, 不是手写源码, 本来就该和源码分开放。
    //   (另一个现实原因: 这台机器上 src/ 的 NTFS 权限不允许脚本写入, 192KB 的表
    //    不可能靠手动改; 放到 tbl/ 之后, 重新生成只是一条命令。)

    always @(posedge clk) begin
        dout <= mem[addr];  // BSRAM 同步读, 延迟 1 拍
    end

endmodule
