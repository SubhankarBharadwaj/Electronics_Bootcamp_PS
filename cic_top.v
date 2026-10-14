`timescale 1ns / 1ps
module cic_top #(
    parameter integer N     = 3,
    parameter integer R     = 512,
    parameter integer M     = 4,
    parameter integer IN_W  = 2,
    parameter integer OUT_W = 20
)(
    input  wire                    clk,
    input  wire                    reset,
    input  wire                    enable,
    input  wire signed [IN_W-1:0]  bits,
    output reg  signed [OUT_W-1:0] cicout,
    output reg                     outready
);

    function integer clog2_ceil;
        input integer value;
        integer temp;
        begin
            temp = value - 1;
            clog2_ceil = 0;
            while (temp > 0) begin
                temp = temp >> 1;
                clog2_ceil = clog2_ceil + 1;
            end
            if (clog2_ceil < 1)
                clog2_ceil = 1;
        end
    endfunction

    localparam integer BW      = IN_W + N*clog2_ceil(R*M);
    localparam integer CNT_W   = clog2_ceil(R);
    localparam integer OUT_SHIFT = BW - OUT_W;

   
    reg signed [IN_W-1:0] bits_q;
    always @(negedge clk) begin
        if (reset)
            bits_q <= {IN_W{1'b0}};
        else
            bits_q <= bits;
    end

    wire signed [BW-1:0] input_extended;
    assign input_extended = {{(BW-IN_W){bits_q[IN_W-1]}}, bits_q};

    // Integrator section, at the input sample rate.
    reg signed [BW-1:0] integrator [0:N-1];
    wire signed [BW-1:0] integrator_next [0:N-1];
    integer i;

    assign integrator_next[0] = integrator[0] + input_extended;

    genvar gi;
    generate
        for (gi = 1; gi < N; gi = gi + 1) begin : INTEGRATOR_NEXT
            assign integrator_next[gi] = integrator[gi] + integrator[gi-1];
        end
    endgenerate

    // Decimator: one event for every R enabled input clocks.
    reg [CNT_W-1:0] count;
    reg             dec_en;
    reg signed [BW-1:0] dec_data;

    always @(posedge clk) begin
        if (reset) begin
            for (i = 0; i < N; i = i + 1)
                integrator[i] <= {BW{1'b0}};
            count    <= {CNT_W{1'b0}};
            dec_en   <= 1'b0;
            dec_data <= {BW{1'b0}};
        end else begin
            dec_en <= 1'b0;
            if (enable) begin
                for (i = 0; i < N; i = i + 1)
                    integrator[i] <= integrator_next[i];

                if (count == R-1) begin
                    count    <= {CNT_W{1'b0}};
                    dec_data <= integrator_next[N-1];
                    dec_en   <= 1'b1;
                end else begin
                    count <= count + 1'b1;
                end
            end
        end
    end

    // Comb section, at the decimated rate. Each of the N stages has delay M.
    wire signed [BW-1:0] comb_stage [0:N];
    assign comb_stage[0] = dec_data;

    genvar gc;
    generate
        for (gc = 0; gc < N; gc = gc + 1) begin : COMB
            reg signed [BW-1:0] delay_line [0:M-1];
            integer j;

            assign comb_stage[gc+1] = comb_stage[gc] - delay_line[M-1];

            always @(posedge clk) begin
                if (reset) begin
                    for (j = 0; j < M; j = j + 1)
                        delay_line[j] <= {BW{1'b0}};
                end else if (dec_en) begin
                    delay_line[0] <= comb_stage[gc];
                    for (j = 1; j < M; j = j + 1)
                        delay_line[j] <= delay_line[j-1];
                end
            end
        end
    endgenerate

    wire signed [BW:0] comb_extended;
    wire        [BW:0] comb_magnitude;
    wire        [BW:0] comb_rounded_magnitude;
    wire signed [BW:0] comb_rounded;
    localparam [BW:0] ROUND_HALF = ({{BW{1'b0}}, 1'b1} << (OUT_SHIFT-1));

    assign comb_extended = {comb_stage[N][BW-1], comb_stage[N]};
    assign comb_magnitude = comb_extended[BW]
                          ? (~comb_extended + {{BW{1'b0}}, 1'b1})
                          : {1'b0, comb_stage[N]};
    assign comb_rounded_magnitude =
        (comb_magnitude + ROUND_HALF) >> OUT_SHIFT;
    assign comb_rounded = comb_extended[BW]
                        ? -$signed(comb_rounded_magnitude)
                        :  $signed(comb_rounded_magnitude);

    
    always @(posedge clk) begin
        if (reset) begin
            cicout   <= {OUT_W{1'b0}};
            outready <= 1'b0;
        end else begin
            outready <= 1'b0;
            if (dec_en) begin
                cicout   <= comb_rounded[OUT_W-1:0];
                outready <= 1'b1;
            end
        end
    end

endmodule
