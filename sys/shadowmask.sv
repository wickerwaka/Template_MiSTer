module shadowmask
(
    input             clk,
    input             clk_sys,
	 
    input             cmd_wr,
    input      [15:0] cmd_in,

    input      [23:0] din,
    input             hs_in,vs_in,
    input             de_in,
    input             enable,

    output reg [23:0] dout,
    output reg        hs_out,vs_out,
    output reg        de_out
);


reg [3:0] hcount;
reg [3:0] vcount;

reg [3:0] hmax;
reg [3:0] vmax;
reg [3:0] hmax2;
reg [3:0] vmax2;

reg [2:0] hindex;
reg [2:0] vindex;
reg [2:0] hindex2;
reg [2:0] vindex2;

reg mask_2x;
reg mask_rotate;
reg mask_enable;
reg [1:0][2:0] on_intensity;
reg [1:0][3:0] off_intensity;
reg [3:0] mask_lut[64];

always @(posedge clk) begin
    reg old_hs, old_vs;
    old_hs <= hs_in;
    old_vs <= vs_in;
    hcount <= hcount + 4'b1;

    // hcount and vcount counts pixel rows and columns
    // hindex and vindex half the value of the counters for double size patterns
    // hindex2, vindex2 swap the h and v counters for drawing rotated masks
    hindex <= mask_2x ? hcount[3:1] : hcount[2:0];
    vindex <= mask_2x ? vcount[3:1] : vcount[2:0];
    hindex2 <= mask_rotate ? vindex : hindex;
    vindex2 <= mask_rotate ? hindex : vindex;

    // hmax and vmax store these sizes
    // hmax2 and vmax2 swap the values to handle rotation
    hmax2 <= mask_rotate ? ( vmax << mask_2x ) : ( hmax << mask_2x );
    vmax2 <= mask_rotate ? ( hmax << mask_2x ) : ( vmax << mask_2x );

    if((old_vs && ~vs_in)) vcount <= 4'b0;
    if(old_hs && ~hs_in) begin
        vcount <= vcount + 4'b1;
        hcount <= 4'b0;
        if (vcount == (vmax2 + mask_2x)) vcount <= 4'b0;
        end

    if (hcount == (hmax2 + mask_2x)) hcount <= 4'b0;
end

wire [7:0] r,g,b;
assign {r,g,b} = din;

reg m_enable;
always @(posedge clk) m_enable <= mask_enable & enable;

always @(posedge clk) begin
    reg [3:0] lut;
    reg [2:0] vid1, vid2, vid3, vid4;

    // 00001 = 6.25%, 00010 = 12.5%, 00100 = 25%, 01000 = 50%, 10000 = 100%
    // 50% and 100% are mutually exclusive, 100% takes priority
    reg [4:0] r_ops, g_ops, b_ops;

    reg [7:0] r1, g1, b1;
    reg [7:0] r2, g2, b2;
    reg [8:0] r4, g4, b4; // 9 bits to handle overflow when we add to bright colors.
    reg [7:0] r3_x, g3_x, b3_x; // only 8 bits needed
    reg [8:0] r3_y, g3_y, b3_y; // 9 bits since this can be > 100%

    // C1 - load LUT and color data
    lut <= mask_lut[{vindex2[2:0],hindex2[2:0]}];
    {r1,g1,b1} <= {r,g,b};
    vid1 <= {vs_in, hs_in, de_in};

    // C2 - convert lut info into addition selector
    if (m_enable) begin
        r_ops <= lut[2] ? {2'b10,on_intensity[lut[3]]} : {1'b0,off_intensity[lut[3]]};
        g_ops <= lut[1] ? {2'b10,on_intensity[lut[3]]} : {1'b0,off_intensity[lut[3]]};
        b_ops <= lut[0] ? {2'b10,on_intensity[lut[3]]} : {1'b0,off_intensity[lut[3]]};
    end else begin
        r_ops <= 5'b10000; g_ops <= 5'b10000; b_ops <= 5'b10000; // just apply 100% to all channels
    end

    vid2 <= vid1;
    {r2,g2,b2} <= {r1,g1,b1};

    // C3 - perform first level of additions based on ops registers
    r3_x <= ( r_ops[0] ? 8'(r2[7:4]) : 8'b0 ) + ( r_ops[1] ? 8'(r2[7:3]) : 8'b0 ); // 6.25% + 12.5%
    r3_y <= ( r_ops[2] ? 9'(r2[7:2]) : 9'b0 ) + ( r_ops[4] ? 9'(r2) : ( r_ops[3] ? 9'(r2[7:1]) : 9'b0 ) ); // 25% + ( 50% OR 100% )

    g3_x <= ( g_ops[0] ? 8'(g2[7:4]) : 8'b0 ) + ( g_ops[1] ? 8'(g2[7:3]) : 8'b0 );
    g3_y <= ( g_ops[2] ? 9'(g2[7:2]) : 9'b0 ) + ( g_ops[4] ? 9'(g2) : ( g_ops[3] ? 9'(g2[7:1]) : 9'b0 ) );

    b3_x <= ( b_ops[0] ? 8'(b2[7:4]) : 8'b0 ) + ( b_ops[1] ? 8'(b2[7:3]) : 8'b0 );
    b3_y <= ( b_ops[2] ? 9'(b2[7:2]) : 9'b0 ) + ( b_ops[4] ? 9'(b2) : ( b_ops[3] ? 9'(b2[7:1]) : 9'b0 ) );

    vid3 <= vid2;

    // C4 - combine results
    r4 <= 9'(r3_x) + 9'(r3_y);
    g4 <= 9'(g3_x) + 9'(g3_y);
    b4 <= 9'(b3_x) + 9'(b3_y);

    vid4 <= vid3;

    // C5 - clamp and pack
    dout <= {{8{r4[8]}} | r4[7:0], {8{g4[8]}} | g4[7:0], {8{b4[8]}} | b4[7:0]};
    {vs_out,hs_out,de_out} <= vid4;
end

// clock in mask commands
always @(posedge clk_sys) begin
    if (cmd_wr) begin
        case(cmd_in[15:13])
        3'b000: {mask_rotate, mask_2x, mask_enable} <= cmd_in[2:0];
        3'b001: vmax <= cmd_in[3:0];
        3'b010: hmax <= cmd_in[3:0];
        3'b011: mask_lut[cmd_in[9:4]] <= cmd_in[3:0];
        3'b100: on_intensity[cmd_in[4]] <= cmd_in[2:0];
        3'b101: off_intensity[cmd_in[4]] <= cmd_in[3:0];
        endcase
    end
end

endmodule
