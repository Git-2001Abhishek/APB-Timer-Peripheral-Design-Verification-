#!/usr/bin/env python3
"""
Mutation testing for the APB timer testbench.

Each mutation injects one realistic bug into rtl/apb_timer.sv, runs the
testbench against the mutated copy and checks that it FAILS. A mutation that
still passes means the testbench has a blind spot.

Usage (from the repository root):  python scripts/mutate.py
Needs iverilog / vvp on PATH (or set IVERILOG / VVP).
"""
import os
import subprocess
import sys

RTL = "rtl/apb_timer.sv"
TB = "tb/tb_apb_timer.sv"

MUTATIONS = [
    ("W1C clear beats timeout",
     "            if (timeout)\n                ris <= 1'b1;\n            else if (wr_ris && pwdata[0])\n                ris <= 1'b0;",
     "            if (wr_ris && pwdata[0])\n                ris <= 1'b0;\n            else if (timeout)\n                ris <= 1'b1;"),
    ("periodic reload off by one",
     "value_q <= ctrl_mode ? '0 : load_q;",
     "value_q <= ctrl_mode ? '0 : load_q - 1'b1;"),
    ("no PSLVERR on read-only write",
     "A_VALUE, A_MIS, A_ID:           begin rd_ok = 1'b1; wr_ok = 1'b0; end",
     "A_VALUE, A_MIS, A_ID:           begin rd_ok = 1'b1; wr_ok = 1'b1; end"),
    ("prescaler not cleared when disabled",
     "        end else if (!ctrl_en) begin\n            presc_cnt <= '0;",
     "        end else if (!ctrl_en) begin\n            presc_cnt <= presc_cnt;"),
    ("one-shot never stops",
     "ctrl_en   <= 1'b0;             // one-shot",
     "ctrl_en   <= 1'b1;             // one-shot"),
    ("irq ignores IE",
     "assign irq = ris & ctrl_ie;",
     "assign irq = ris;"),
    ("LOAD write does not restart prescaler",
     "            value_q   <= pwdata;\n            presc_cnt <= '0;",
     "            value_q   <= pwdata;"),
    ("PRESC register only 8 bits",
     "if (wr_presc) presc_q <= pwdata[15:0];",
     "if (wr_presc) presc_q <= {8'd0, pwdata[7:0]};"),
    ("PADDR[1:0] not ignored",
     "assign addr   = {paddr[ADDR_WIDTH-1:2], 2'b00};",
     "assign addr   = paddr;"),
    ("prescaler compare '==' instead of '>='",
     "assign step    = ctrl_en & (presc_cnt >= presc_q);",
     "assign step    = ctrl_en & (presc_cnt == presc_q);"),
    ("one-shot stop beats CTRL write",
     "            end else if (timeout && ctrl_mode) begin",
     "            end if (timeout && ctrl_mode) begin"),
    ("MIS reads raw status",
     "A_MIS:   prdata = {31'd0, ris & ctrl_ie};",
     "A_MIS:   prdata = {31'd0, ris};"),
]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    iverilog = os.environ.get("IVERILOG", "iverilog")
    vvp = os.environ.get("VVP", "vvp")
    os.makedirs("build", exist_ok=True)
    src = open(RTL).read()
    survivors = 0
    for name, old, new in MUTATIONS:
        if old not in src:
            sys.exit("mutation '%s' does not apply - RTL changed?" % name)
        with open("build/mutant.sv", "w") as f:
            f.write(src.replace(old, new, 1))
        subprocess.run([iverilog, "-g2012", "-o", "build/mutant.vvp", "-s", "tb_apb_timer",
                        "build/mutant.sv", TB], check=True)
        out = subprocess.run([vvp, "-n", "build/mutant.vvp"], stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True).stdout
        verdict = [l for l in out.splitlines() if l.startswith("TEST ")]
        killed = not verdict or not verdict[-1].startswith("TEST PASSED")
        survivors += not killed
        print("%-40s %-8s %s" % (name, "killed" if killed else "SURVIVED",
                                 verdict[-1] if verdict else "(no verdict)"))
    print("-" * 70)
    print("%d / %d mutants killed" % (len(MUTATIONS) - survivors, len(MUTATIONS)))
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
