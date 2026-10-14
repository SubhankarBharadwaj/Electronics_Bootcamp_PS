
`timescale 1ns / 1ps

module fir_comp #(
    parameter integer TAPS       = 81,
    parameter integer IN_W       = 20,
    parameter integer COEFF_W    = 24,
    parameter integer COEFF_FRAC = 20,
    parameter integer OUT_W      = 20,
    parameter integer ACC_W      = 51,
    parameter COEFF_FILE         = "fir_coeffs.mem"
)(
    input  wire                         clk,
    input  wire                         reset,
    input  wire                         in_valid,
    input  wire signed [IN_W-1:0]       in_data,

    output reg  signed [OUT_W-1:0]      firout,
    output reg                          fir_valid,
    output reg                          fir_overflow,
    output reg                          input_overrun,
    output wire                         busy
);

    // Calculate the number of bits needed for the tap index.
    function integer clog2;
        input integer value;
        integer temp;
        begin
            temp = value - 1;
            clog2 = 0;

            while (temp > 0) begin
                temp = temp >> 1;
                clog2 = clog2 + 1;
            end

            if (clog2 < 1)
                clog2 = 1;
        end
    endfunction

    localparam integer INDEX_W   = clog2(TAPS);
    localparam integer PRODUCT_W = IN_W + COEFF_W;

    localparam [1:0] IDLE = 2'd0;
    localparam [1:0] MAC  = 2'd1;

    // State and storage.
    reg [1:0] state;
    reg [INDEX_W-1:0] tap_index;

    reg signed [IN_W-1:0] sample_mem [0:TAPS-1];
    reg signed [COEFF_W-1:0] coeff_mem [0:TAPS-1];

    reg signed [ACC_W-1:0] accumulator;

    integer i;

    // Load the signed 24-bit Q3.20 coefficients.
    initial begin
        $readmemh(COEFF_FILE, coeff_mem);
    end

    // --------------------------------------------------
    // Signed multiplication and accumulation
    // --------------------------------------------------

    wire signed [PRODUCT_W-1:0] sample_for_mult;
    wire signed [PRODUCT_W-1:0] coeff_for_mult;
    wire signed [PRODUCT_W-1:0] product;

    wire signed [ACC_W-1:0] product_extended;
    wire signed [ACC_W-1:0] acc_with_product;

    // Extend both operands to the required product width.
    assign sample_for_mult =
        {{COEFF_W{sample_mem[tap_index][IN_W-1]}},
          sample_mem[tap_index]};

    assign coeff_for_mult =
        {{IN_W{coeff_mem[tap_index][COEFF_W-1]}},
          coeff_mem[tap_index]};

    // The exact signed product requires IN_W + COEFF_W bits.
    assign product =
        $signed(sample_for_mult) * $signed(coeff_for_mult);

    // Extend the product to accumulator width.
    assign product_extended =
        {{(ACC_W-PRODUCT_W){product[PRODUCT_W-1]}}, product};

    assign acc_with_product = accumulator + product_extended;

    // --------------------------------------------------
    // Q20 rounding and output scaling
    // --------------------------------------------------

    wire signed [ACC_W:0] acc_extended;
    wire        [ACC_W:0] acc_magnitude;
    wire        [ACC_W:0] rounded_magnitude;
    wire signed [ACC_W:0] scaled_value;

    localparam [ACC_W:0] ROUND_HALF =
        ({{ACC_W{1'b0}}, 1'b1} << (COEFF_FRAC-1));

    // Convert the accumulator to a positive magnitude.
    assign acc_extended =
        {acc_with_product[ACC_W-1], acc_with_product};

    assign acc_magnitude =
        acc_extended[ACC_W]
        ? (~acc_extended + {{ACC_W{1'b0}}, 1'b1})
        : {1'b0, acc_with_product};

    // Round to nearest, with halfway cases away from zero.
    assign rounded_magnitude =
        (acc_magnitude + ROUND_HALF) >> COEFF_FRAC;

    // Restore the original sign.
    assign scaled_value =
        acc_extended[ACC_W]
        ? -$signed(rounded_magnitude)
        :  $signed(rounded_magnitude);

    // --------------------------------------------------
    // Overflow detection and saturation
    // --------------------------------------------------

    wire overflow_now;

    assign overflow_now =
        (scaled_value[ACC_W:OUT_W] !=
         {(ACC_W+1-OUT_W){scaled_value[OUT_W-1]}});

    // --------------------------------------------------
    // FIR controller
    // --------------------------------------------------

    assign busy = (state == MAC);

    always @(posedge clk) begin

        if (reset) begin

            state         <= IDLE;
            tap_index     <= {INDEX_W{1'b0}};
            accumulator   <= {ACC_W{1'b0}};

            firout        <= {OUT_W{1'b0}};
            fir_valid     <= 1'b0;
            fir_overflow  <= 1'b0;
            input_overrun <= 1'b0;

            for (i = 0; i < TAPS; i = i + 1)
                sample_mem[i] <= {IN_W{1'b0}};

        end else begin

            fir_valid    <= 1'b0;
            fir_overflow <= 1'b0;

            case (state)

                // Wait for a new valid input sample.
                IDLE: begin

                    if (in_valid) begin

                        // Shift the previous samples.
                        for (i = TAPS-1; i > 0; i = i - 1)
                            sample_mem[i] <= sample_mem[i-1];

                        // Store the newest sample.
                        sample_mem[0] <= in_data;

                        accumulator <= {ACC_W{1'b0}};
                        tap_index   <= {INDEX_W{1'b0}};

                        state <= MAC;
                    end

                end

                // Multiply and accumulate all 81 taps.
                MAC: begin

                    // A new input during MAC is an overrun.
                    if (in_valid)
                        input_overrun <= 1'b1;

                    if (tap_index == TAPS-1) begin

                        // Include the final tap product.
                        if (overflow_now) begin

                            fir_overflow <= 1'b1;

                            // Saturate instead of wrapping.
                            if (scaled_value[ACC_W])
                                firout <= {1'b1, {(OUT_W-1){1'b0}}};
                            else
                                firout <= {1'b0, {(OUT_W-1){1'b1}}};

                        end else begin

                            firout <= scaled_value[OUT_W-1:0];

                        end

                        fir_valid   <= 1'b1;
                        accumulator <= {ACC_W{1'b0}};
                        tap_index   <= {INDEX_W{1'b0}};
                        state       <= IDLE;

                    end else begin

                        accumulator <= acc_with_product;
                        tap_index   <= tap_index + 1'b1;

                    end

                end

                default: begin

                    state       <= IDLE;
                    accumulator <= {ACC_W{1'b0}};
                    tap_index   <= {INDEX_W{1'b0}};

                end

            endcase

        end
    end

endmodule
