//---------------------------------------------------------------------------
// menu_fsm.v —— 菜单状态机 (6 个页面 / 参数项锁定与调值)
//---------------------------------------------------------------------------
//     HOME 菜单 (page=0)                    level = 0 (LV_HOME)
//         旋转 = 在 5 个兄弟项间移动 (环回)
//         单击 = 进入选中项 (进页后光标归 0, 且一定是"未锁定")
//         长按 = 曲谱回开头 (home_p)
module menu_fsm #(
    parameter NSONG = 3,
    parameter NPAGE = 6  // OSD 页面总数
)(
    input  wire       clk,
    input  wire       rst_n,

    //---- 来自 rotary_enc (已消抖) ----
    input  wire       step,
    input  wire       dir,
    input  wire       sw_press,
    input  wire       sw_long,

    //---- 页面/菜单 ----
    output reg  [3:0] page,
    output reg  [3:0] menu_sel,
    output reg  [1:0] level,  // 0=HOME菜单  1=选中未锁定  2=锁定(旋转改值)
    output reg        tst_act,

    //---- 内容页按键旁路 ----
    output reg        play_p,
    output reg        home_p,
    //  测试页切档位的单拍 (给 top.v)
    output reg        test_step,
    output reg        test_dir,

    //---- 曲目 ----
    output reg  [1:0] song_idx,

    //---- 参数 ----
    output reg  [2:0] p_timbre,
    output reg  [1:0] p_octave,
    output reg  [7:0] p_volume,
    output reg  [2:0] p_vib,
    output reg  [2:0] p_glide,
    //    真琴的效果器都是深度可调的, 只有开关是不够的。
    //    0 = 关 (直通), 1/2/3 = 湿声 1/4, 1/2, 满档
    output reg  [2:0] p_chorus,
    output reg        p_ctype,  // 0=LIGHT  1=DEEP
    output reg        p_dtype,  // 0=SHORT  1=LONG
    output reg        p_rtype,  // 0=ROOM   1=HALL
    output reg        on_ctype, on_dtype, on_rtype,
    output reg  [2:0] p_delay,  // 延迟深度 0..5
    output reg  [2:0] p_reverb,  // 混响深度 0..5
    //    0 = GUIDE 指引 (亮灯等你弹)
    //    1 = AUTO  自动播放 (FPGA 自己弹)
    output reg        p_autoplay,

    //---- "编码器改过" 标志 ----
    output reg        on_timbre,
    output reg        on_octave,
    output reg        on_volume,
    output reg        on_vib,
    output reg        on_glide,
    output reg        on_chorus,
    output reg        on_delay,
    output reg        on_reverb,
    output reg        p_gesture,
    output reg        on_gesture,
    output reg        on_autoplay
);

    localparam [3:0] PG_HOME    = 4'd0,
                     PG_OVERVIEW= 4'd1,
                     PG_SCOPE   = 4'd2,
                     PG_PARAM   = 4'd3,
                     PG_SCORE   = 4'd4,
                     PG_TEST    = 4'd5;

    localparam [2:0] HOME_LAST = 3'd4;  // 5 项: 0..4

    //    在一页里就有两种解释 (第八版就是在这里栽的)。
    localparam [1:0] LV_HOME = 2'd0,  // 主菜单
                     LV_PAGE = 2'd1,  // 选行 (未锁定)
                     LV_EDIT = 2'd2;  // 锁定 (旋转 = 改值)

    localparam [1:0] NMAX = NSONG[1:0] - 2'd1;

    //  HOME 第 i 项 -> 目标页
    //    0 主界面 -> page1   1 图形 -> page2   2 参数 -> page3
    //    3 曲谱   -> page4   4 测试 -> page5
    function [3:0] home_page_of;
        input [2:0] i;
        begin
            case (i)
                4'd0: home_page_of = PG_OVERVIEW;
                4'd1: home_page_of = PG_SCOPE;
                4'd2: home_page_of = PG_PARAM;
                4'd3: home_page_of = PG_SCORE;
                default: home_page_of = PG_TEST;
            endcase
        end
    endfunction

    function [3:0] page_items;
        input [3:0] p;
        begin
            case (p)
                PG_PARAM: page_items = 4'd12;
                PG_SCORE: page_items = 4'd2;
                PG_TEST : page_items = 4'd1;
                default : page_items = 4'd0;  // 概览/图形: 纯显示
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            page      <= PG_HOME;
            menu_sel  <= 3'd0;
            level     <= LV_HOME;
            tst_act   <= 1'b0;
            play_p    <= 1'b0;
            home_p    <= 1'b0;
            test_step <= 1'b0;
            test_dir  <= 1'b1;
            song_idx  <= 2'd0;
            p_timbre  <= 3'd0;
            p_octave  <= 2'd0;
            //    88/96/.../208/216/224/.../248 (步长 8), 220 不在表里,
            //    上电后会显示 "---"。216 和 220 听不出差别 (都是 -1.4dB左右)。
            p_volume  <= 8'd128;
            p_vib     <= 3'd0;
            //    0 档是关。默认给一个听得见的量, 但不像 4~6 档那样拖。
            p_glide   <= 3'd0;
    //    不然一开机三个效果器全开着, 听不出干净的原声。
    p_chorus  <= 3'd0;
            //    开机就能听到效果;想关的话进菜单关。
            //    三个效果器串联会把旋律搓碎, 先确认自动播放本身对不对。
            //    菜单里仍然可以手动打开。
            p_delay   <= 3'd0;
            p_reverb  <= 3'd0;
    p_ctype   <= 1'b0;
    p_dtype   <= 1'b0;
    p_rtype   <= 1'b0;
    on_ctype  <= 1'b0;
    on_dtype  <= 1'b0;
    on_rtype  <= 1'b0;
            //    开机即使误识别也不会乱改参数; 要用进菜单打开。
            p_gesture <= 1'b0;
            on_gesture<= 1'b0;
            //    想听自动演奏再进菜单切 AUTO。
            p_autoplay  <= 1'b0;
            on_timbre <= 1'b0;
            on_octave <= 1'b0;
            on_volume <= 1'b0;
            on_vib    <= 1'b0;
            on_glide  <= 1'b0;
            on_chorus <= 1'b0;
            on_delay  <= 1'b0;
            on_reverb <= 1'b0;
        end else begin
            play_p    <= 1'b0;
            home_p    <= 1'b0;
            test_step <= 1'b0;

            if (step) begin
                if (level == LV_HOME) begin
                    //  ---- HOME: 在 5 个兄弟间移动 (环回) ----
                    if (dir) menu_sel <= (menu_sel >= HOME_LAST) ? 3'd0 : (menu_sel + 3'd1);
                    else     menu_sel <= (menu_sel == 3'd0)      ? HOME_LAST : (menu_sel - 3'd1);
                end
                else if (level == LV_PAGE) begin
                    //  ---- 未锁定: 旋转 = **只换行, 绝不动值** ----
                    //      (曲谱/测试) 转了都不动。0 项时更不能进这个分支:
                    //      `page_items-1` 在 3 位下会**下溢成 7**, 光标反而乱跳。
                    if (page == PG_TEST) begin
                        //    这一页只有 1 个可调项, 没有别的行可转,
                        //    直接把它当调值 -> 进页即可调, 交互少一步。
                        test_step <= 1'b1;
                        test_dir  <= dir;
                    end else if (page_items(page) > 4'd1) begin
                        if (dir) menu_sel <= (menu_sel >= (page_items(page) - 4'd1))
                                            ? 3'd0 : (menu_sel + 3'd1);
                        else     menu_sel <= (menu_sel == 3'd0)
                                            ? (page_items(page) - 4'd1) : (menu_sel - 3'd1);
                    end
                end
                else begin
                    //  ---- 锁定中: 旋转 = **只改值, 绝不换行** ----
                    //     也是 tb_menu_fsm.v 里 T4/T5 回归要盯死的东西。
                    case (page)
                        PG_PARAM: begin
                            case (menu_sel)
                                4'd0: begin
                                    p_timbre  <= dir ? ((p_timbre >= 3'd7) ? 3'd0 : (p_timbre + 3'd1))
                                                     : ((p_timbre == 3'd0) ? 3'd7 : (p_timbre - 3'd1));
                                    on_timbre <= 1'b1;
                                end
                                4'd1: begin
                                    p_octave  <= dir ? ((p_octave >= 2'd3) ? 2'd0 : (p_octave + 2'd1))
                                                     : ((p_octave == 2'd0) ? 2'd3 : (p_octave - 2'd1));
                                    on_octave <= 1'b1;
                                end
                                4'd2: begin
                                    p_volume  <= dir ? ((p_volume >= 8'd241) ? 8'd248 : (p_volume + 8'd8))
                                                     : ((p_volume <= 8'd95)  ? 8'd88  : (p_volume - 8'd8));
                                    on_volume <= 1'b1;
                                end
                                4'd3: begin
                                    p_vib  <= dir ? ((p_vib >= 3'd7) ? 3'd0 : (p_vib + 3'd1))
                                                  : ((p_vib == 3'd0) ? 3'd7 : (p_vib - 3'd1));
                                    on_vib <= 1'b1;
                                end
                                4'd11: begin
                                    p_glide   <= (p_glide >= 3'd6) ? 3'd0 : (p_glide + 3'd1);
                                    on_glide  <= 1'b1;
                                end
                                4'd4: begin
                                    p_chorus  <= (p_chorus >= 3'd5) ? 3'd0 : (p_chorus + 3'd1);
                                    on_chorus <= 1'b1;
                                end
                                4'd5: begin
                                    p_ctype   <= ~p_ctype;
                                    on_ctype  <= 1'b1;
                                end
                                //  第 7 项 = 延迟深度
                                4'd6: begin
                                    p_delay   <= (p_delay >= 3'd5) ? 3'd0 : (p_delay + 3'd1);
                                    on_delay  <= 1'b1;
                                end
                                //  第 8 项 = 延迟类型
                                4'd7: begin
                                    p_dtype   <= ~p_dtype;
                                    on_dtype  <= 1'b1;
                                end
                                //  第 9 项 = 混响深度
                                4'd8: begin
                                    p_reverb  <= (p_reverb >= 3'd5) ? 3'd0 : (p_reverb + 3'd1);
                                    on_reverb <= 1'b1;
                                end
                                //  第 10 项 = 混响类型
                                4'd9: begin
                                    p_rtype   <= ~p_rtype;
                                    on_rtype  <= 1'b1;
                                end
                                //  第 11 项 = 手势开关
                                4'd10: begin
                                    p_gesture  <= ~p_gesture;
                                    on_gesture <= 1'b1;
                                end
                                default: begin
                                    //  超出 7 项的 menu_sel 不做任何事
                                    //  (选中项数由 page_items 限制, 这里只是保底)
                                end
                            endcase
                        end
                        PG_SCORE: begin
                            //  ---- 曲谱页: 两个可调项 ----
                            case (menu_sel)
                                4'd0: begin
                                    //  行 2 = SONG: 换曲目
                                    if (dir) song_idx <= (song_idx >= NMAX) ? 2'd0 : (song_idx + 2'd1);
                                    else     song_idx <= (song_idx == 2'd0) ? NMAX : (song_idx - 2'd1);
                                end
                                4'd1: begin
                                    p_autoplay  <= ~p_autoplay;
                                    on_autoplay <= 1'b1;
                                end
                                default: ;
                            endcase
                        end
                        PG_TEST : begin
                            //  ---- 测试页: 锁定后旋转 = 切档位 (top.v 接这个单拍) ----
                            test_step <= 1'b1;
                            test_dir  <= dir;
                        end
                        default: ;  // 概览/图形 进不了 LV_EDIT, 空着只为综合不报 latch
                    endcase
                end
            end

            if (sw_press) begin
                if (level == LV_HOME) begin
                    //  ---- 从 HOME 进入选中项 (进去一定是未锁定) ----
                    page     <= home_page_of(menu_sel);
                    level    <= LV_PAGE;
                    menu_sel <= 3'd0;
                end
                else if (level == LV_PAGE) begin
                    if (page_items(page) > 4'd0) begin
                        //  ---- 有可调项: 锁定这一行 (焦点条变青 + EDIT) ----
                        level <= LV_EDIT;
                    end else begin
                        page     <= PG_HOME;
                        level    <= LV_HOME;
                        menu_sel <= 3'd0;
                    end
                end
                else begin
                    //  ---- 锁定中: 再次单击 = 解锁 (光标留在原行) ----
                    level <= LV_PAGE;
                end
            end

            if (sw_long) begin
                home_p <= 1'b1;
                if (level != LV_HOME) begin
                    page     <= PG_HOME;
                    level    <= LV_HOME;
                    menu_sel <= 3'd0;
                end
            end

            tst_act <= (page == PG_TEST);
        end
    end

endmodule
