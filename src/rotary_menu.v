//---------------------------------------------------------------------------
// rotary_menu.v —— 参数菜单 (旧版, 保留)
//---------------------------------------------------------------------------
//         旋转 = 翻页 (0->1->2->3->0, 双向)
//         单击 = 进入**选择模式**
//         长按 = 曲谱回开头
module rotary_menu #(
    parameter NSONG   = 4,  // 曲目总数
    parameter NPAGE   = 4,  // 页面总数
    parameter CLK_HZ  = 27_000_000
)(
    input  wire       clk,
    input  wire       rst_n,

    //---- 来自 rotary_enc ----
    input  wire       step,  // 转过一格 (单拍)
    input  wire       dir,  // 1 = 顺时针
    input  wire       sw_press,  // 短按: 松手时发 (单拍)
    input  wire       sw_long,  // 长按 (单拍)

    //---- 输出 ----
    output reg  [1:0] song_idx,  // 曲目序号
    output reg        play_p,  // 播放/暂停 (单拍)
    output reg        home_p,  // 回到开头 (单拍)
    output reg        page_tog,  // 翻页请求: **每需要翻一次就翻转一下** (电平)
    output reg        page_dir,  // 翻页方向: 1 = 下一页

    //---- 层级 (给 OSD): 0=翻页 1=选择 2=改值 ----
    output reg  [1:0] level,

    //---- 菜单光标 (0..5, 5 = EXIT) ----
    output reg  [2:0] menu_sel,

    //---- 参数值 ----
    output reg  [2:0] p_timbre,
    output reg  [1:0] p_octave,
    output reg  [7:0] p_volume,
    output reg  [2:0] p_vib,
    output reg        p_chorus,

    //---- "编码器改过这个参数" 标志 ----
    output reg        on_timbre,
    output reg        on_octave,
    output reg        on_volume,
    output reg        on_vib,
    output reg        on_chorus
);

    localparam [1:0] NMAX = NSONG[1:0] - 2'd1;

    //  层级
    localparam [1:0] LV_FLIP   = 2'd0,
                     LV_SELECT = 2'd1,
                     LV_EDIT   = 2'd2;

    //  设置页的项编号 (必须和 gen_osd.py 的 _menu_rows 顺序一致!)
    localparam [2:0] MI_TIMBRE = 3'd0,
                     MI_OCTAVE = 3'd1,
                     MI_VOLUME = 3'd2,
                     MI_VIB    = 3'd3,
                     MI_CHORUS = 3'd4,
                     MI_EXIT   = 3'd5;
    localparam [2:0] NITEM_L  = 3'd5;  // 最后一项的编号

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            song_idx  <= 2'd0;
            play_p    <= 1'b0;
            home_p    <= 1'b0;
            page_tog  <= 1'b0;
            page_dir  <= 1'b1;
            level     <= LV_FLIP;
            menu_sel  <= 3'd0;
            p_timbre  <= 3'd0;
            p_octave  <= 2'd0;
            p_volume  <= 8'd128;
            p_vib     <= 3'd0;
            p_chorus  <= 1'b0;
            on_timbre <= 1'b0;
            on_octave <= 1'b0;
            on_volume <= 1'b0;
            on_vib    <= 1'b0;
            on_chorus <= 1'b0;
        end else begin
            play_p <= 1'b0;
            home_p <= 1'b0;

            if (step) begin
                case (level)
                    //  ---- 翻页模式: 换曲目 + 翻页 ----
                    LV_FLIP: begin
                        if (dir) song_idx <= (song_idx >= NMAX) ? 2'd0 : (song_idx + 2'd1);
                        else     song_idx <= (song_idx == 2'd0) ? NMAX : (song_idx - 2'd1);
                        page_tog  <= ~page_tog;
                        page_dir  <= dir;
                    end

                    //  ---- 选择模式: 只移光标, 绝不改值 ----
                    LV_SELECT: begin
                        if (dir) menu_sel <= (menu_sel >= NITEM_L) ? 3'd0 : (menu_sel + 3'd1);
                        else     menu_sel <= (menu_sel == 3'd0)    ? NITEM_L : (menu_sel - 3'd1);
                    end

                    //  ---- 改值模式: 只改当前项的值, 绝不换项 ----
                    LV_EDIT: begin
                        case (menu_sel)
                            MI_TIMBRE: begin
                                p_timbre  <= dir ? ((p_timbre >= 3'd7) ? 3'd0 : (p_timbre + 3'd1))
                                                 : ((p_timbre == 3'd0) ? 3'd7 : (p_timbre - 3'd1));
                                on_timbre <= 1'b1;
                            end
                            MI_OCTAVE: begin
                                p_octave  <= dir ? ((p_octave >= 2'd3) ? 2'd0 : (p_octave + 2'd1))
                                                 : ((p_octave == 2'd0) ? 2'd3 : (p_octave - 2'd1));
                                on_octave <= 1'b1;
                            end
                            MI_VOLUME: begin
                                //  步进 8, 限幅 88..248 (留余量防爆音)
                                p_volume  <= dir ? ((p_volume >= 8'd241) ? 8'd248 : (p_volume + 8'd8))
                                                 : ((p_volume <= 8'd95)  ? 8'd88  : (p_volume - 8'd8));
                                on_volume <= 1'b1;
                            end
                            MI_VIB: begin
                                p_vib  <= dir ? ((p_vib >= 3'd7) ? 3'd0 : (p_vib + 3'd1))
                                              : ((p_vib == 3'd0) ? 3'd7 : (p_vib - 3'd1));
                                on_vib <= 1'b1;
                            end
                            MI_CHORUS: begin
                                p_chorus  <= ~p_chorus;
                                on_chorus <= 1'b1;
                            end
                            //  MI_EXIT 在改值模式里不该出现 (选择模式已拦住), 兜底不改
                            default: ;
                        endcase
                    end

                    default: ;
                endcase
            end

            if (sw_press) begin
                case (level)
                    LV_FLIP: begin
                        //  ---- 进选择模式, 光标回到第一项 ----
                        level    <= LV_SELECT;
                        menu_sel <= 3'd0;
                    end
                    LV_SELECT: begin
                        if (menu_sel == MI_EXIT) begin
                            //  ---- 选中 EXIT -> 回翻页模式 ----
                            level <= LV_FLIP;
                        end else begin
                            level <= LV_EDIT;
                        end
                    end
                    LV_EDIT: begin
                        //  ---- 退回选择模式 (只退一级) ----
                        level <= LV_SELECT;
                    end
                    default: level <= LV_FLIP;
                endcase
            end

            if (sw_long) home_p <= 1'b1;
        end
    end

endmodule
