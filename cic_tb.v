`timescale 1ns / 1ps

module cic_tb;

    reg data [0:4096025];

    reg clk, clk2, clk3, clk4, reset, enable;
    reg signed [1:0] bits;

    wire signed [19:0] cicout;
    wire outready;

    wire signed [19:0] firout;
    wire fir_valid;
    wire fir_overflow;
    wire fir_input_overrun;
    wire fir_busy;

    integer i;
    integer cic_sample_count;
    integer fd1, fd2, fd3, fd4;

    initial begin
        $readmemh("hz500.mem", data);
    end

    initial begin
        clk = 0;
        clk2 = 0;
        clk3 = 0;
        clk4 = 0;

        bits = 0;
        enable = 0;
        reset = 1;

        i = 0;
        cic_sample_count = 0;

        fd1 = $fopen("bits.txt", "w");
        fd2 = $fopen("cic2048_500.txt", "w");
        fd3 = $fopen("fircomp.txt", "w");
        fd4 = $fopen("cic2048_500_by4.txt", "w");

        #51 reset = 0;
        enable = 1;
    end

    // Original workshop clocks
    always #50     clk  = ~clk;
    always #25600  clk2 = ~clk2;
    always #102400 clk3 = ~clk3;

    // Input data generation
    always @(posedge clk) begin
        if (i < 4096026) begin
            if ((i % 2) == 0)
                bits = {1'b0, data[i]};
            else
                bits = {2{data[i]}};

            i <= i + 1;
        end
        else begin
            #200;
            $fclose(fd1);
            $fclose(fd2);
            $fclose(fd3);
            $fclose(fd4);
            $finish;
        end
    end

    // Save input bits
    always @(posedge clk) begin
        $fwrite(fd1, "%d\n", bits);
    end

    // Save CIC output and every fourth CIC sample
    always @(posedge clk) begin
        if (outready) begin
            $fwrite(fd2, "%d\n", $signed(cicout));

            if ((cic_sample_count % 4) == 3)
                $fwrite(fd4, "%d\n", $signed(cicout));

            cic_sample_count = cic_sample_count + 1;
        end
    end

    // Save FIR output only when valid
    always @(posedge clk) begin
        if (fir_valid)
            $fwrite(fd3, "%d\n", $signed(firout));
    end

    // Task 1: CIC filter
    cic_top #(
        .N(3),
        .R(512),
        .M(4),
        .IN_W(2),
        .OUT_W(20)
    ) cic (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .bits     (bits),
        .cicout   (cicout),
        .outready (outready)
    );

    // Task 2: FIR compensation filter
    fir_comp #(
        .TAPS       (81),
        .IN_W       (20),
        .COEFF_W    (24),
        .COEFF_FRAC (20),
        .OUT_W      (20),
        .ACC_W      (51),
        .COEFF_FILE ("fir_coeffs.mem")
    ) fir1 (
        .clk           (clk),
        .reset         (reset),
        .in_valid      (outready),
        .in_data       (cicout),
        .firout        (firout),
        .fir_valid     (fir_valid),
        .fir_overflow  (fir_overflow),
        .input_overrun (fir_input_overrun),
        .busy          (fir_busy)
    );

endmodule