`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_apb_timer
//
// Verification environment for apb_timer:
//   * APB3 master BFM (apb_write / apb_read tasks)
//   * cycle-accurate reference model of the register map and counter,
//     compared against the DUT on every clock cycle (scoreboard)
//   * APB protocol checks
//   * directed tests with hand-computed expectations
//   * constrained-random register traffic checked by the model
//   * functional coverage counters reported at the end
// -----------------------------------------------------------------------------
module tb_apb_timer;

    parameter int N_RANDOM = 4000;   // random APB transactions

    localparam logic [11:0] A_CTRL  = 12'h000;
    localparam logic [11:0] A_LOAD  = 12'h004;
    localparam logic [11:0] A_VALUE = 12'h008;
    localparam logic [11:0] A_PRESC = 12'h00C;
    localparam logic [11:0] A_RIS   = 12'h010;
    localparam logic [11:0] A_MIS   = 12'h014;
    localparam logic [11:0] A_ID    = 12'h018;
    localparam logic [31:0] ID_VAL  = 32'h4150_5431;

    localparam logic [31:0] EN   = 32'h1;
    localparam logic [31:0] MODE = 32'h2;   // one-shot
    localparam logic [31:0] IE   = 32'h4;

    logic        pclk = 1'b0;
    logic        presetn;
    logic        psel, penable, pwrite;
    logic [11:0] paddr;
    logic [31:0] pwdata, prdata;
    logic        pready, pslverr;
    logic        irq;

    always #5 pclk = ~pclk;   // 100 MHz

    apb_timer #(.ADDR_WIDTH(12)) dut (
        .pclk, .presetn, .psel, .penable, .pwrite, .paddr, .pwdata,
        .prdata, .pready, .pslverr, .irq
    );

    int errors = 0;
    int cycle  = 0;

    always @(posedge pclk) cycle++;

    task automatic fail(input string msg);
        $error("[%0t] %s", $time, msg);
        errors++;
    endtask

    // =================================================================
    // Reference model (updated with non-blocking assignments, so anything
    // sampling it at a rising edge sees the pre-edge state, like the DUT)
    // =================================================================
    logic        m_en, m_mode, m_ie, m_ris;
    logic [31:0] m_load, m_value;
    logic [15:0] m_presc, m_pcnt;

    // coverage
    int cov_timeout_periodic = 0, cov_timeout_oneshot = 0;
    int cov_rd_err = 0, cov_wr_err = 0, cov_w1c = 0;
    int cov_w1c_collision = 0, cov_load_preempt = 0, cov_ctrl_vs_oneshot = 0;
    int cov_reads[7] = '{0, 0, 0, 0, 0, 0, 0};
    int holes;
    int cov_writes[7] = '{0, 0, 0, 0, 0, 0, 0};

    function automatic bit model_readable(input logic [11:0] a);
        return (a == A_CTRL) || (a == A_LOAD) || (a == A_VALUE) || (a == A_PRESC) ||
               (a == A_RIS) || (a == A_MIS) || (a == A_ID);
    endfunction

    function automatic bit model_writable(input logic [11:0] a);
        return (a == A_CTRL) || (a == A_LOAD) || (a == A_PRESC) || (a == A_RIS);
    endfunction

    function automatic logic [31:0] model_read(input logic [11:0] a);
        case (a)
            A_CTRL:  return {29'd0, m_ie, m_mode, m_en};
            A_LOAD:  return m_load;
            A_VALUE: return m_value;
            A_PRESC: return {16'd0, m_presc};
            A_RIS:   return {31'd0, m_ris};
            A_MIS:   return {31'd0, m_ris & m_ie};
            A_ID:    return ID_VAL;
            default: return 32'd0;
        endcase
    endfunction

    always @(posedge pclk or negedge presetn) begin
        logic [11:0] a;
        bit acc, w_ok, wctrl, wload, wpresc, wris, stp, tmo;
        if (!presetn) begin
            m_en <= 0; m_mode <= 0; m_ie <= 0; m_ris <= 0;
            m_load <= 0; m_value <= 0; m_presc <= 0; m_pcnt <= 0;
        end else begin
            a      = {paddr[11:2], 2'b00};
            acc    = psel && penable;
            w_ok   = acc && pwrite && model_writable(a);
            wctrl  = w_ok && a == A_CTRL;
            wload  = w_ok && a == A_LOAD;
            wpresc = w_ok && a == A_PRESC;
            wris   = w_ok && a == A_RIS;
            stp    = m_en && (m_pcnt == m_presc);
            tmo    = stp && (m_value == 0) && !wload;

            // counter
            if (wload) begin
                m_value <= pwdata;
                m_pcnt  <= 0;
                if (stp && m_value == 0) cov_load_preempt++;
            end else if (!m_en) begin
                m_pcnt <= 0;
            end else if (stp) begin
                m_pcnt  <= 0;
                m_value <= (m_value != 0) ? m_value - 1 : (m_mode ? 32'd0 : m_load);
            end else begin
                m_pcnt <= m_pcnt + 1;
            end

            // registers
            if (wctrl) begin
                {m_ie, m_mode, m_en} <= pwdata[2:0];
                if (tmo && m_mode) cov_ctrl_vs_oneshot++;
            end else if (tmo && m_mode) begin
                m_en <= 0;
            end
            if (wload)  m_load  <= pwdata;
            if (wpresc) m_presc <= pwdata[15:0];
            if (tmo) begin
                m_ris <= 1;
                if (m_mode) cov_timeout_oneshot++; else cov_timeout_periodic++;
                if (wris && pwdata[0]) cov_w1c_collision++;
            end else if (wris && pwdata[0]) begin
                m_ris <= 0;
                cov_w1c++;
            end

            // coverage of accesses
            if (acc) begin
                if (pwrite && !model_writable(a)) cov_wr_err++;
                if (!pwrite && !model_readable(a)) cov_rd_err++;
                if (a <= A_ID) begin
                    if (pwrite) cov_writes[a >> 2]++;
                    else        cov_reads[a >> 2]++;
                end
            end
        end
    end

    // =================================================================
    // Scoreboard: compare DUT state and outputs with the model every cycle
    // =================================================================
    always @(negedge pclk) begin
        if (presetn) begin
            if (irq !== (m_ris & m_ie))
                fail($sformatf("irq=%b, model expects %b", irq, m_ris & m_ie));
            if (dut.value_q !== m_value)
                fail($sformatf("VALUE=%0d, model expects %0d", dut.value_q, m_value));
            if (dut.presc_cnt !== m_pcnt)
                fail($sformatf("prescaler count=%0d, model expects %0d", dut.presc_cnt, m_pcnt));
            if ({dut.ctrl_ie, dut.ctrl_mode, dut.ctrl_en} !== {m_ie, m_mode, m_en})
                fail("CTRL register differs from model");
            if (dut.ris !== m_ris)
                fail("RIS differs from model");
        end
    end

    // =================================================================
    // APB protocol checks
    // =================================================================
    logic psel_d, penable_d;
    always @(posedge pclk) begin
        if (presetn) begin
            if (penable && !psel)
                fail("protocol: PENABLE without PSEL");
            if (psel && penable && !(psel_d && !penable_d))
                fail("protocol: ACCESS phase not preceded by SETUP phase");
            if (pready !== 1'b1)
                fail("pready must be tied high (zero-wait-state slave)");
            if (!(psel && penable) && (pslverr !== 1'b0))
                fail("protocol: PSLVERR asserted outside ACCESS phase");
        end
        psel_d    <= psel;
        penable_d <= penable;
    end

    // =================================================================
    // APB master BFM
    // =================================================================
    task automatic apb_idle();
        psel    = 1'b0;
        penable = 1'b0;
        pwrite  = 1'b0;
        paddr   = '0;
        pwdata  = '0;
    endtask

    task automatic apb_xfer(input bit write, input logic [11:0] addr, input logic [31:0] wdata,
                            output logic [31:0] rdata, output logic err);
        logic [31:0] exp;
        bit          exp_err;
        // SETUP phase
        @(negedge pclk);
        psel    = 1'b1;
        penable = 1'b0;
        pwrite  = write;
        paddr   = addr;
        pwdata  = wdata;
        // ACCESS phase
        @(negedge pclk);
        penable = 1'b1;
        @(posedge pclk);
        while (!pready) @(posedge pclk);
        rdata   = prdata;
        err     = pslverr;
        // check against the model (sampled at the same edge, pre-update)
        exp_err = write ? !model_writable({addr[11:2], 2'b00}) : !model_readable({addr[11:2], 2'b00});
        if (err !== exp_err)
            fail($sformatf("%s 0x%03h: PSLVERR=%b expected %b", write ? "write" : "read", addr, err, exp_err));
        if (!write && !exp_err) begin
            exp = model_read({addr[11:2], 2'b00});
            if (rdata !== exp)
                fail($sformatf("read 0x%03h: got 0x%08h, model expects 0x%08h", addr, rdata, exp));
        end
        @(negedge pclk);
        apb_idle();
    endtask

    task automatic apb_write(input logic [11:0] addr, input logic [31:0] data);
        logic [31:0] rd;
        logic        e;
        apb_xfer(1'b1, addr, data, rd, e);
    endtask

    task automatic apb_read(input logic [11:0] addr, output logic [31:0] data);
        logic e;
        apb_xfer(1'b0, addr, '0, data, e);
    endtask

    // read and compare with a hand-computed value (independent of the model)
    task automatic expect_read(input logic [11:0] addr, input logic [31:0] exp, input string what);
        logic [31:0] d;
        apb_read(addr, d);
        if (d !== exp) fail($sformatf("%s: read 0x%08h expected 0x%08h", what, d, exp));
    endtask

    task automatic expect_err(input bit write, input logic [11:0] addr, input string what);
        logic [31:0] d;
        logic        e;
        apb_xfer(write, addr, 32'hFFFF_FFFF, d, e);
        if (e !== 1'b1) fail({what, ": expected PSLVERR"});
    endtask

    task automatic do_reset();
        apb_idle();
        presetn = 1'b0;
        repeat (3) @(posedge pclk);
        @(negedge pclk) presetn = 1'b1;
    endtask

    task automatic wait_irq(input int max_cycles, output int waited);
        waited = 0;
        while (!irq && waited < max_cycles) begin
            @(posedge pclk);
            waited++;
        end
        if (!irq) fail($sformatf("no interrupt within %0d cycles", max_cycles));
    endtask

    // =================================================================
    // Directed tests
    // =================================================================
    task automatic test_reset_values();
        $display("[%0t] TEST 1: reset values", $time);
        do_reset();
        expect_read(A_CTRL,  0, "CTRL reset");
        expect_read(A_LOAD,  0, "LOAD reset");
        expect_read(A_VALUE, 0, "VALUE reset");
        expect_read(A_PRESC, 0, "PRESC reset");
        expect_read(A_RIS,   0, "RIS reset");
        expect_read(A_MIS,   0, "MIS reset");
        expect_read(A_ID,    ID_VAL, "ID");
        if (irq !== 1'b0) fail("irq high after reset");
    endtask

    task automatic test_register_access();
        $display("[%0t] TEST 2: register read/write", $time);
        apb_write(A_CTRL, MODE | IE);                 // EN=0
        expect_read(A_CTRL, 32'h6, "CTRL readback");
        apb_write(A_CTRL, 32'hFFFF_FFF8);             // reserved bits only
        expect_read(A_CTRL, 32'h0, "CTRL reserved bits read as 0");
        apb_write(A_LOAD, 32'hDEAD_BEEF);
        expect_read(A_LOAD, 32'hDEAD_BEEF, "LOAD readback");
        expect_read(A_VALUE, 32'hDEAD_BEEF, "LOAD write also loads VALUE");
        apb_write(A_PRESC, 32'h1234_5678);
        expect_read(A_PRESC, 32'h0000_5678, "PRESC is 16 bits");
        apb_write(12'h005, 32'h0000_00AA);            // unaligned -> LOAD
        expect_read(A_LOAD, 32'hAA, "PADDR[1:0] ignored");
        apb_write(A_PRESC, 0);
        apb_write(A_LOAD, 0);
    endtask

    task automatic test_errors();
        $display("[%0t] TEST 3: PSLVERR on unmapped / read-only accesses", $time);
        apb_write(A_LOAD, 32'd77);
        expect_err(1'b0, 12'h01C, "read unmapped 0x01C");
        expect_err(1'b0, 12'h800, "read unmapped 0x800");
        expect_err(1'b0, 12'hFFC, "read unmapped 0xFFC");
        expect_err(1'b1, 12'h020, "write unmapped 0x020");
        expect_err(1'b1, A_VALUE, "write VALUE (RO)");
        expect_err(1'b1, A_MIS,   "write MIS (RO)");
        expect_err(1'b1, A_ID,    "write ID (RO)");
        expect_read(A_VALUE, 32'd77, "VALUE unchanged by rejected write");
        expect_read(A_ID, ID_VAL, "ID unchanged by rejected write");
    endtask

    // Measure the cycles between consecutive timeouts in periodic mode.
    task automatic check_period(input int load, input int presc);
        int expect_p, t_prev, n, waited;
        expect_p = (load + 1) * (presc + 1);
        apb_write(A_CTRL, 0);
        apb_write(A_RIS, 1);
        apb_write(A_PRESC, presc);
        apb_write(A_LOAD, load);
        apb_write(A_CTRL, EN | IE);
        t_prev = -1;
        for (n = 0; n < 4; n++) begin
            wait_irq(expect_p + 20, waited);
            if (t_prev >= 0 && (cycle - t_prev) != expect_p)
                fail($sformatf("LOAD=%0d PRESC=%0d: period %0d cycles, expected %0d",
                               load, presc, cycle - t_prev, expect_p));
            t_prev = cycle;
            apb_write(A_RIS, 1);                       // W1C, takes 3 cycles
        end
        apb_write(A_CTRL, 0);
        apb_write(A_RIS, 1);
        $display("        LOAD=%0d PRESC=%0d -> period %0d cycles: ok", load, presc, expect_p);
    endtask

    task automatic test_periodic();
        $display("[%0t] TEST 4: periodic mode / prescaler timing", $time);
        check_period(9, 0);       // 10 cycles
        check_period(4, 3);       // 20 cycles
        check_period(19, 1);      // 40 cycles
        check_period(2, 15);      // 48 cycles
    endtask

    task automatic test_oneshot();
        int waited, fires;
        logic [31:0] d;
        $display("[%0t] TEST 5: one-shot mode", $time);
        apb_write(A_PRESC, 1);
        apb_write(A_LOAD, 5);
        apb_write(A_CTRL, EN | MODE | IE);
        wait_irq(100, waited);
        expect_read(A_CTRL, MODE | IE, "EN cleared after one-shot timeout");
        expect_read(A_VALUE, 0, "VALUE stays 0 after one-shot");
        apb_write(A_RIS, 1);
        fires = 0;
        repeat (100) begin
            @(posedge pclk);
            if (irq) fires++;
        end
        if (fires != 0) fail("one-shot timer fired again");
        // re-arm by writing EN again
        apb_write(A_LOAD, 3);
        apb_write(A_CTRL, EN | MODE | IE);
        wait_irq(100, waited);
        apb_write(A_RIS, 1);
        apb_write(A_CTRL, 0);
    endtask

    task automatic test_interrupt_mask();
        int waited;
        $display("[%0t] TEST 6: interrupt enable / masking / W1C", $time);
        apb_write(A_PRESC, 0);
        apb_write(A_LOAD, 6);
        apb_write(A_CTRL, EN | MODE);                  // IE = 0
        repeat (20) @(posedge pclk);
        expect_read(A_RIS, 1, "RIS set with IE=0");
        expect_read(A_MIS, 0, "MIS masked with IE=0");
        if (irq !== 1'b0) fail("irq must stay low with IE=0");
        apb_write(A_CTRL, MODE | IE);                  // enable interrupt only
        @(negedge pclk);
        if (irq !== 1'b1) fail("irq must rise when IE is set with RIS pending");
        expect_read(A_MIS, 1, "MIS with IE=1");
        apb_write(A_RIS, 0);                           // writing 0 does nothing
        expect_read(A_RIS, 1, "RIS not cleared by writing 0");
        apb_write(A_RIS, 1);
        expect_read(A_RIS, 0, "RIS cleared by W1C");
        if (irq !== 1'b0) fail("irq must drop after W1C");
        apb_write(A_CTRL, 0);
    endtask

    task automatic test_timeout_beats_clear();
        $display("[%0t] TEST 7: timeout every cycle - W1C cannot clear RIS", $time);
        apb_write(A_PRESC, 0);
        apb_write(A_LOAD, 0);                          // timeout every cycle
        apb_write(A_CTRL, EN | IE);
        apb_write(A_RIS, 1);
        expect_read(A_RIS, 1, "RIS stays set when timeout coincides with W1C");
        apb_write(A_CTRL, 0);
        apb_write(A_RIS, 1);
        expect_read(A_RIS, 0, "RIS clears once the timer is stopped");
    endtask

    task automatic test_disable_freezes();
        logic [31:0] v1, v2, v3;
        $display("[%0t] TEST 8: EN=0 freezes the counter", $time);
        apb_write(A_PRESC, 0);
        apb_write(A_LOAD, 1000);
        apb_write(A_CTRL, EN);
        repeat (50) @(posedge pclk);
        apb_write(A_CTRL, 0);
        apb_read(A_VALUE, v1);
        repeat (30) @(posedge pclk);
        apb_read(A_VALUE, v2);
        if (v1 !== v2) fail("VALUE changed while disabled");
        if (v1 >= 1000 || v1 < 900) fail($sformatf("VALUE %0d not in expected range", v1));
        apb_write(A_CTRL, EN);
        repeat (10) @(posedge pclk);
        apb_read(A_VALUE, v3);
        if (!(v3 < v2)) fail("VALUE did not resume counting");
        apb_write(A_CTRL, 0);
    endtask

    task automatic test_reset_midrun();
        $display("[%0t] TEST 9: reset while running", $time);
        apb_write(A_PRESC, 2);
        apb_write(A_LOAD, 3);
        apb_write(A_CTRL, EN | IE);
        repeat (40) @(posedge pclk);
        do_reset();
        expect_read(A_CTRL, 0, "CTRL after reset");
        expect_read(A_VALUE, 0, "VALUE after reset");
        expect_read(A_RIS, 0, "RIS after reset");
        if (irq !== 1'b0) fail("irq after reset");
    endtask

    // =================================================================
    // Constrained-random traffic (checked by the model / scoreboard)
    // =================================================================
    task automatic test_random(input int n);
        logic [11:0] a;
        logic [31:0] d, rd;
        logic        e;
        int          r;
        $display("[%0t] TEST 10: %0d random APB transactions", $time, n);
        repeat (n) begin
            r = $urandom_range(99);
            if (r < 6)       a = 12'h01C + 4 * $urandom_range(0, 1000);  // unmapped
            else if (r < 8)  a = 12'h0 | $urandom_range(0, 3);           // unaligned CTRL
            else             a = 4 * $urandom_range(0, 6);               // mapped
            case ({a[11:2], 2'b00})
                A_LOAD:  d = $urandom_range(0, 12);
                A_PRESC: d = $urandom_range(0, 3) | ($urandom << 16);    // junk upper bits
                A_CTRL:  d = $urandom;                                   // random EN/MODE/IE
                default: d = $urandom;
            endcase
            apb_xfer($urandom_range(1), a, d, rd, e);
            repeat ($urandom_range(0, 6)) @(posedge pclk);
        end
        apb_write(A_CTRL, 0);
    endtask

    // =================================================================
    initial begin
        $dumpfile("results/apb_timer.vcd");
        $dumpvars(0, tb_apb_timer);
        apb_idle();
        psel_d = 0;
        penable_d = 0;

        test_reset_values();
        test_register_access();
        test_errors();
        test_periodic();
        test_oneshot();
        test_interrupt_mask();
        test_timeout_beats_clear();
        test_disable_freezes();
        test_reset_midrun();
        test_random(N_RANDOM);

        repeat (5) @(posedge pclk);
        $display("--------------------------------------------------");
        $display("Functional coverage");
        $display("  periodic timeouts           : %0d", cov_timeout_periodic);
        $display("  one-shot timeouts           : %0d", cov_timeout_oneshot);
        $display("  RIS W1C clears              : %0d", cov_w1c);
        $display("  timeout vs W1C collisions   : %0d", cov_w1c_collision);
        $display("  LOAD write pre-empting tmo  : %0d", cov_load_preempt);
        $display("  CTRL write vs one-shot stop : %0d", cov_ctrl_vs_oneshot);
        $display("  read errors / write errors  : %0d / %0d", cov_rd_err, cov_wr_err);
        $display("  reads  CTRL LOAD VALUE PRESC RIS MIS ID : %0d %0d %0d %0d %0d %0d %0d",
                 cov_reads[0], cov_reads[1], cov_reads[2], cov_reads[3], cov_reads[4], cov_reads[5], cov_reads[6]);
        $display("  writes CTRL LOAD VALUE PRESC RIS MIS ID : %0d %0d %0d %0d %0d %0d %0d",
                 cov_writes[0], cov_writes[1], cov_writes[2], cov_writes[3], cov_writes[4], cov_writes[5], cov_writes[6]);
        begin : coverage_check
            holes = 0;
            if (cov_timeout_periodic == 0) holes++;
            if (cov_timeout_oneshot == 0) holes++;
            if (cov_w1c == 0) holes++;
            if (cov_w1c_collision == 0) holes++;
            if (cov_load_preempt == 0) holes++;
            if (cov_ctrl_vs_oneshot == 0) holes++;
            if (cov_rd_err == 0 || cov_wr_err == 0) holes++;
            for (int i = 0; i < 7; i++) if (cov_reads[i] == 0 || cov_writes[i] == 0) holes++;
            $display("  coverage holes              : %0d", holes);
            if (holes != 0) fail("functional coverage incomplete");
        end
        $display("--------------------------------------------------");
        $display("cycles simulated: %0d", cycle);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d error(s)", errors);
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "timeout");
    end

endmodule
