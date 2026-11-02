//---------------------------------------------------------------------------
// adsr_env.v —— ADSR 包络发生器 (每个声部一份)
//---------------------------------------------------------------------------
// 状态机: IDLE -> ATTACK -> DECAY -> SUSTAIN -> (松键) RELEASE -> IDLE
module adsr_env(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        tick,  // 每采样帧一个脉冲
    input  wire        trigger,  // 触发(按下新音): 从 0 重新起包络
    input  wire        gate,  // 1=按住 0=松开(进入 RELEASE)
    input  wire [7:0]  vel,  // 力度 0..255
    input  wire [15:0] atk_inc,
    input  wire [15:0] dec_inc,
    input  wire [15:0] rel_inc,
    input  wire [1:0]  sus_shift,
    output reg  [15:0] env,
    output wire        busy  // 1=该声部正在发声(非 IDLE)
);

    localparam [2:0] S_IDLE = 3'd0,
                     S_ATK  = 3'd1,
                     S_DEC  = 3'd2,
                     S_SUS  = 3'd3,
                     S_REL  = 3'd4;

    reg [2:0]  st;
    reg [7:0]  vel_r;  // 力度锁存; peak = {vel_r, 8'h00} 由它免费得到
    reg [15:0] sus_r;  // 延音电平 (触发时锁存)

    wire [16:0] peak17 = {1'b0, vel_r, 8'h00};

    wire [15:0] inc_sel = (st == S_ATK) ? atk_inc
                        : (st == S_DEC) ? dec_inc : rel_inc;
    wire        env_up  = (st == S_ATK);  // 1=加 0=减
    wire [16:0] env_nxt = env_up ? ({1'b0, env} + {1'b0, inc_sel})
                                 : ({1'b0, env} - {1'b0, inc_sel});

    wire atk_done = (atk_inc == 16'd0) || env_nxt[16] ||
                    (env_nxt[15:0] >= peak17[15:0]);
    wire dec_done = (dec_inc == 16'd0) || env_nxt[16] ||
                    (env_nxt[15:0] <= sus_r);
    wire rel_done = (rel_inc == 16'd0) || env_nxt[16];

    assign busy = (st != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            env   <= 16'd0;
            vel_r <= 8'd0;
            sus_r <= 16'd0;
        end else if (trigger) begin
            vel_r <= vel;
            sus_r <= {vel, 8'h00} >> sus_shift;
            env   <= 16'd0;
            st    <= S_ATK;
        end else if (tick) begin
            if (st == S_REL) begin
                //---------------- 释放段 ----------------
                if (rel_done) begin
                    env <= 16'd0;
                    st  <= S_IDLE;
                end else begin
                    env <= env_nxt[15:0];
                end
            end else if (!gate && st != S_IDLE) begin
                //---------------- 松键 -> 进入释放段 ----------------
                st <= S_REL;
            end else begin
                case (st)
                    //---------------- 起音段 ----------------
                    S_ATK: begin
                        if (atk_done) begin
                            env <= peak17[15:0];
                            st  <= S_DEC;
                        end else begin
                            env <= env_nxt[15:0];
                        end
                    end
                    //---------------- 衰减段 ----------------
                    S_DEC: begin
                        if (dec_done) begin
                            env <= sus_r;
                            st  <= S_SUS;
                        end else begin
                            env <= env_nxt[15:0];
                        end
                    end
                    //---------------- 延音段: 保持不变 ----------------
                    default: begin
                        env <= env;
                    end
                endcase
            end
        end
    end

endmodule
