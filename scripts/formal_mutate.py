#!/usr/bin/env python3
"""
Check that the formal proof (formal/apb_timer.sby, task `prove`) is not
vacuous: inject bugs one at a time and confirm the proof no longer passes.

Usage (from the repository root):  python scripts/formal_mutate.py
Tool names can be overridden with SBY, YOSYS, SMTBMC environment variables.
"""
import io
import os
import re
import shutil
import subprocess
import sys

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
    ("one-shot never stops",
     "ctrl_en   <= 1'b0;             // one-shot",
     "ctrl_en   <= 1'b1;             // one-shot"),
    ("irq ignores IE",
     "assign irq = ris & ctrl_ie;",
     "assign irq = ris;"),
    ("prescaler compare '==' instead of '>='",
     "assign step    = ctrl_en & (presc_cnt >= presc_q);",
     "assign step    = ctrl_en & (presc_cnt == presc_q);"),
    ("prdata driven outside read access",
     "        if (rd) begin\n            case (addr)",
     "        if (psel) begin\n            case (addr)"),
]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    os.chdir(root)
    sby = os.environ.get("SBY", "sby").split()
    tools = []
    if "YOSYS" in os.environ:
        tools += ["--yosys", os.environ["YOSYS"]]
    if "SMTBMC" in os.environ:
        tools += ["--smtbmc", os.environ["SMTBMC"]]
    src = io.open("rtl/apb_timer.sv", encoding="utf-8").read()
    sby_text = io.open("formal/apb_timer.sby", encoding="utf-8").read()
    work = os.path.join("build", "formal_mut")
    survivors = 0
    for name, old, new in MUTATIONS:
        if old not in src:
            sys.exit("mutation '%s' does not apply - RTL changed?" % name)
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work)
        io.open(os.path.join(work, "apb_timer.sv"), "w", encoding="utf-8", newline="\n").write(
            src.replace(old, new, 1))
        io.open(os.path.join(work, "m.sby"), "w", encoding="utf-8", newline="\n").write(
            sby_text.replace("../rtl/apb_timer.sv", "apb_timer.sv"))
        out = subprocess.run(sby + tools + ["-f", "m.sby", "prove"], cwd=work,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
        m = re.findall(r"DONE \((\w+), rc=\d+\)", out)
        status = m[-1] if m else "ERROR"
        killed = status != "PASS"
        survivors += not killed
        print("%-42s %-8s proof status: %s" % (name, "killed" if killed else "SURVIVED", status))
    shutil.rmtree(work, ignore_errors=True)
    print("-" * 70)
    print("%d / %d mutants break the proof" % (len(MUTATIONS) - survivors, len(MUTATIONS)))
    print("(FAIL = counterexample found; UNKNOWN = induction can no longer prove it)")
    sys.exit(1 if survivors else 0)


if __name__ == "__main__":
    main()
