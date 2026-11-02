// vga_timing.v —— 480x272 RGB LCD 时序发生器 (来自官方 rgb_lcd 例程, 未改动)
//   像素时钟 9MHz (由 video_pll 从 27MHz 产生)
//   H: 480 有效 + 2 前肩 + 41 同步 + 2 后肩 = 525
//   V: 272 有效 + 2 前肩 + 10 同步 + 2 后肩 = 286
//   active_x / active_y 在 de=1 期间是 0..479 / 0..271 的有效像素坐标
module vga_timing(
	input                 clk,  //pixel clock
	input                 rst,  //reset signal high active
	output                hs,  //horizontal synchronization
	output                vs,  //vertical synchronization
	output                de,  //video valid

	output reg [9:0] active_x,  //video x position
	output reg [9:0] active_y  //video y position

	);

//480x272 9Mhz
parameter H_ACTIVE = 16'd480;
parameter H_FP = 16'd2;
parameter H_SYNC = 16'd41;
parameter H_BP = 16'd2;
parameter V_ACTIVE = 16'd272;
parameter V_FP  = 16'd2;
parameter V_SYNC  = 16'd10;
parameter V_BP  = 16'd2;
parameter HS_POL = 1'b0;
parameter VS_POL = 1'b0;

parameter H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;  //horizontal total time (pixels)
parameter V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;  //vertical total time (lines)

reg hs_reg;  //horizontal sync register
reg vs_reg;  //vertical sync register
reg[11:0] h_cnt;  //horizontal counter
reg[11:0] v_cnt;  //vertical counter

reg h_active;  //horizontal video active
reg v_active;  //vertical video active
assign hs = hs_reg;
assign vs = vs_reg;
assign de = h_active & v_active;

//列计数
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		h_cnt <= 12'd0;
	else if(h_cnt == H_TOTAL - 1)  //horizontal counter maximum value
		h_cnt <= 12'd0;
	else
		h_cnt <= h_cnt + 12'd1;
end
localparam [9:0] H_ACT_BEG = H_FP[9:0] + H_SYNC[9:0] + H_BP[9:0];
localparam [9:0] V_ACT_BEG = V_FP[9:0] + V_SYNC[9:0] + V_BP[9:0];
always@(posedge clk)
begin
	if(h_cnt >= H_FP + H_SYNC + H_BP)  //horizontal video active
		active_x <= h_cnt[9:0] - H_ACT_BEG;
	else
		active_x <= active_x;
end
always@(posedge clk)
begin
	if(v_cnt >= V_FP + V_SYNC + V_BP)  //vertical video active
		active_y <= v_cnt[9:0] - V_ACT_BEG;
	else
		active_y <= active_y;
end
//行计数
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		v_cnt <= 12'd0;
	else if(h_cnt == H_FP  - 1)  //horizontal sync time
		if(v_cnt == V_TOTAL - 1)  //vertical counter maximum value
			v_cnt <= 12'd0;
		else
			v_cnt <= v_cnt + 12'd1;
	else
		v_cnt <= v_cnt;
end
//HS生成
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		hs_reg <= 1'b0;
	else if(h_cnt == H_FP - 1)  //horizontal sync begin
		hs_reg <= HS_POL;
	else if(h_cnt == H_FP + H_SYNC - 1)  //horizontal sync end
		hs_reg <= ~hs_reg;
	else
		hs_reg <= hs_reg;
end
//列有效
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		h_active <= 1'b0;
	else if(h_cnt == H_FP + H_SYNC + H_BP - 1)  //horizontal active begin
		h_active <= 1'b1;
	else if(h_cnt == H_TOTAL - 1)  //horizontal active end
		h_active <= 1'b0;
	else
		h_active <= h_active;
end
//VS生成
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		vs_reg <= 1'd0;
	else if((v_cnt == V_FP - 1) && (h_cnt == H_FP - 1))  //vertical sync begin
		vs_reg <= HS_POL;
	else if((v_cnt == V_FP + V_SYNC - 1) && (h_cnt == H_FP - 1))  //vertical sync end
		vs_reg <= ~vs_reg;
	else
		vs_reg <= vs_reg;
end
//行有效
always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
		v_active <= 1'd0;
	else if((v_cnt == V_FP + V_SYNC + V_BP - 1) && (h_cnt == H_FP - 1))  //vertical active begin
		v_active <= 1'b1;
	else if((v_cnt == V_TOTAL - 1) && (h_cnt == H_FP - 1))  //vertical active end
		v_active <= 1'b0;
	else
		v_active <= v_active;
end

endmodule
