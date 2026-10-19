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
    input  logic [ADDR_WIDTH-1:0] paddr,
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
    logic [ADDR_WIDTH-1:0] addr;
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

    assign step    = ctrl_en & (presc_cnt == presc_q);
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

endmodule
