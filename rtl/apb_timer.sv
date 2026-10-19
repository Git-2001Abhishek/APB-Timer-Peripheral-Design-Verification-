`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// apb_timer
// 32-bit down-counting timer with a 16-bit prescaler and an AMBA APB3 slave
// interface (zero wait states).
//
// Register map (word aligned, PADDR[1:0] ignored)
//   0x00 CTRL    RW   [0] EN    - count enable
//                     [1] MODE  - 0: periodic (auto-reload), 1: one-shot
//                     [2] IE    - interrupt enable
//   0x04 LOAD    RW   reload value; writing it also loads VALUE and
//                     restarts the prescaler
//   0x08 VALUE   RO   current count
//   0x0C PRESC   RW   [15:0] prescaler: the counter steps every PRESC+1 cycles
//   0x10 RIS     RW1C [0] raw interrupt status (set on timeout, write 1 to clear)
//   0x14 MIS     RO   [0] masked interrupt status = RIS & IE
//   0x18 ID      RO   0x4150_5431 ("APT1")
//
// Behaviour
//   While EN=1 the prescaler counts 0..PRESC. Each time it wraps, VALUE
//   decrements. When VALUE is 0 at a step, a timeout happens instead:
//   RIS is set and VALUE reloads from LOAD (periodic) or the timer stops by
//   clearing EN (one-shot). In periodic mode the timeout period is therefore
//   (LOAD + 1) * (PRESC + 1) clock cycles.
//   While EN=0 VALUE holds and the prescaler is cleared.
//
// Error responses (PSLVERR=1, register state unchanged)
//   - any access to an unmapped address
//   - a write to a read-only register (VALUE, MIS, ID)
//
// Priorities within one cycle
//   - a LOAD write wins over counting (and suppresses a timeout that cycle)
//   - a timeout setting RIS wins over a W1C clear of RIS
//   - a software CTRL write wins over the one-shot clearing EN
// -----------------------------------------------------------------------------
module apb_timer #(
    parameter int ADDR_WIDTH = 12
) (
    input  logic                  pclk,
    input  logic                  presetn,
    // APB3 slave
    input  logic                  psel,
    input  logic                  penable,
    input  logic                  pwrite,
    /* verilator lint_off UNUSEDSIGNAL */  // PADDR[1:0] intentionally ignored
    input  logic [ADDR_WIDTH-1:0] paddr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0]           pwdata,
    output logic [31:0]           prdata,
    output logic                  pready,
    output logic                  pslverr,
    // interrupt
    output logic                  irq
);

    // ------------------------------------------------------------------
    // Register offsets
    // ------------------------------------------------------------------
    localparam logic [ADDR_WIDTH-1:0] A_CTRL  = 'h00;
    localparam logic [ADDR_WIDTH-1:0] A_LOAD  = 'h04;
    localparam logic [ADDR_WIDTH-1:0] A_VALUE = 'h08;
    localparam logic [ADDR_WIDTH-1:0] A_PRESC = 'h0C;
    localparam logic [ADDR_WIDTH-1:0] A_RIS   = 'h10;
    localparam logic [ADDR_WIDTH-1:0] A_MIS   = 'h14;
    localparam logic [ADDR_WIDTH-1:0] A_ID    = 'h18;

    localparam logic [31:0] TIMER_ID = 32'h4150_5431;   // "APT1"

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    logic        ctrl_en, ctrl_mode, ctrl_ie;
    logic [31:0] load_q;
    logic [31:0] value_q;
    logic [15:0] presc_q;
    logic [15:0] presc_cnt;
    logic        ris;

    // ------------------------------------------------------------------
    // APB decode (PREADY is always high: every access completes in the
    // ACCESS phase, so psel & penable marks the completing cycle)
    // ------------------------------------------------------------------
    logic [ADDR_WIDTH-1:0] addr;   // word address (PADDR[1:0] ignored)
    logic access, wr, rd;
    logic rd_ok, wr_ok;

    assign addr   = {paddr[ADDR_WIDTH-1:2], 2'b00};
    assign access = psel & penable;
    assign wr     = access &  pwrite;
    assign rd     = access & ~pwrite;

    always_comb begin
        rd_ok = 1'b0;
        wr_ok = 1'b0;
        case (addr)
            A_CTRL, A_LOAD, A_PRESC, A_RIS: begin rd_ok = 1'b1; wr_ok = 1'b1; end
            A_VALUE, A_MIS, A_ID:           begin rd_ok = 1'b1; wr_ok = 1'b0; end
            default:                        begin rd_ok = 1'b0; wr_ok = 1'b0; end
        endcase
    end

    logic wr_ctrl, wr_load, wr_presc, wr_ris;

    assign wr_ctrl  = wr & wr_ok & (addr == A_CTRL);
    assign wr_load  = wr & wr_ok & (addr == A_LOAD);
    assign wr_presc = wr & wr_ok & (addr == A_PRESC);
    assign wr_ris   = wr & wr_ok & (addr == A_RIS);

    assign pready  = 1'b1;
    assign pslverr = access & (pwrite ? ~wr_ok : ~rd_ok);

    always_comb begin
        prdata = '0;
        if (rd) begin
            case (addr)
                A_CTRL:  prdata = {29'd0, ctrl_ie, ctrl_mode, ctrl_en};
                A_LOAD:  prdata = load_q;
                A_VALUE: prdata = value_q;
                A_PRESC: prdata = {16'd0, presc_q};
                A_RIS:   prdata = {31'd0, ris};
                A_MIS:   prdata = {31'd0, ris & ctrl_ie};
                A_ID:    prdata = TIMER_ID;
                default: prdata = '0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Counter
    // ------------------------------------------------------------------
    logic step;      // prescaler wraps this cycle
    logic timeout;   // counter expires this cycle

    // '>=' rather than '==': if PRESC is lowered below the current count
    // while running, the prescaler wraps on the next cycle instead of
    // counting on to 2**16.
    assign step    = ctrl_en & (presc_cnt >= presc_q);
    assign timeout = step & (value_q == '0) & ~wr_load;

    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            presc_cnt <= '0;
            value_q   <= '0;
        end else if (wr_load) begin
            value_q   <= pwdata;
            presc_cnt <= '0;
        end else if (!ctrl_en) begin
            presc_cnt <= '0;
        end else if (step) begin
            presc_cnt <= '0;
            if (value_q == '0)
                value_q <= ctrl_mode ? '0 : load_q;
            else
                value_q <= value_q - 1'b1;
        end else begin
            presc_cnt <= presc_cnt + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Registers
    // ------------------------------------------------------------------
    always_ff @(posedge pclk or negedge presetn) begin
        if (!presetn) begin
            ctrl_en   <= 1'b0;
            ctrl_mode <= 1'b0;
            ctrl_ie   <= 1'b0;
            load_q    <= '0;
            presc_q   <= '0;
            ris       <= 1'b0;
        end else begin
            if (wr_ctrl) begin
                ctrl_en   <= pwdata[0];
                ctrl_mode <= pwdata[1];
                ctrl_ie   <= pwdata[2];
            end else if (timeout && ctrl_mode) begin
                ctrl_en   <= 1'b0;             // one-shot: stop after firing
            end

            if (wr_load)  load_q  <= pwdata;
            if (wr_presc) presc_q <= pwdata[15:0];

            if (timeout)
                ris <= 1'b1;
            else if (wr_ris && pwdata[0])
                ris <= 1'b0;
        end
    end

    assign irq = ris & ctrl_ie;

    // ------------------------------------------------------------------
    // Formal properties (SymbiYosys, see formal/apb_timer.sby).
    // Assumptions describe a legal APB3 master; assertions describe the
    // timer. Proven unbounded with k-induction.
    // ------------------------------------------------------------------
`ifdef FORMAL
    logic f_past_valid = 1'b0;
    always @(posedge pclk) f_past_valid <= 1'b1;

    // every trace starts in reset
    always @(*) if (!f_past_valid) assume (!presetn);

    // ---- legal APB3 master (zero-wait-state slave) ----
    always @(*) if (penable) assume (psel);
    always @(posedge pclk) if (f_past_valid && $past(presetn) && presetn) begin
        // ACCESS follows SETUP, with stable address / control / data
        if (penable) assume ($past(psel && !penable));
        if ($past(psel && !penable)) begin
            assume (psel && penable);
            assume (paddr  == $past(paddr));
            assume (pwrite == $past(pwrite));
            assume (pwdata == $past(pwdata));
        end
        // PREADY is always 1, so a transfer ends after one ACCESS cycle
        if ($past(psel && penable)) assume (!penable);
    end

    // ---- interface assertions ----
    // independent decode of the register map for the PSLVERR check
    logic [ADDR_WIDTH-1:0] f_word;
    logic f_readable, f_writable;
    assign f_word     = paddr & ~{{(ADDR_WIDTH-2){1'b0}}, 2'b11};
    assign f_writable = (f_word == 'h00) || (f_word == 'h04) || (f_word == 'h0C) || (f_word == 'h10);
    assign f_readable = f_writable || (f_word == 'h08) || (f_word == 'h14) || (f_word == 'h18);

    always @(*) begin
        assert (pready);
        if (psel && penable) assert (pslverr == (pwrite ? !f_writable : !f_readable));
        if (!(psel && penable))           assert (!pslverr);
        if (!(psel && penable && !pwrite)) assert (prdata == '0);
        assert (irq == (ris && ctrl_ie));
        assert (presc_q <= 16'hFFFF);
    end

    // ---- behaviour assertions ----
    always @(posedge pclk) if (f_past_valid && $past(presetn) && presetn) begin
        // RIS is set only by a timeout and cleared only by a W1C write
        if (!$past(ris) && ris) assert ($past(timeout));
        if ($past(ris) && !ris) assert ($past(wr_ris && pwdata[0]));
        // ... and a timeout always wins over a simultaneous W1C clear
        if ($past(timeout)) assert (ris);

        // rejected writes (PSLVERR) change no register
        if ($past(wr && !wr_ok)) begin
            assert ({ctrl_en, ctrl_mode, ctrl_ie} == $past({ctrl_en, ctrl_mode, ctrl_ie})
                    || $past(timeout && ctrl_mode));
            assert (load_q  == $past(load_q));
            assert (presc_q == $past(presc_q));
        end

        // a LOAD write loads VALUE and restarts the prescaler
        if ($past(wr_load)) assert (value_q == $past(pwdata) && presc_cnt == '0);

        // disabled: VALUE holds, prescaler cleared
        if ($past(!ctrl_en && !wr_load)) assert (value_q == $past(value_q) && presc_cnt == '0);

        // a counting step decrements VALUE by exactly one
        if ($past(step && !wr_load && value_q != '0)) assert (value_q == $past(value_q) - 1'b1);

        // no step: VALUE holds
        if ($past(ctrl_en && !step && !wr_load)) assert (value_q == $past(value_q));

        // timeout: periodic reloads, one-shot stops (unless software rewrote CTRL)
        if ($past(timeout && !ctrl_mode)) assert (value_q == $past(load_q));
        if ($past(timeout &&  ctrl_mode && !wr_ctrl)) assert (!ctrl_en && value_q == '0);

        // the prescaler never runs past PRESC, except for the single cycle
        // right after PRESC is lowered (it then wraps immediately)
        if (!$past(wr_presc)) assert (presc_cnt <= presc_q);
    end

    // ---- reachability ----
    always @(posedge pclk) if (presetn) begin
        cover (timeout && !ctrl_mode);
        cover (timeout &&  ctrl_mode);
        cover (pslverr);
        cover (irq);
        cover (timeout && wr_ris && pwdata[0]);   // set/clear collision
    end
`endif

endmodule
