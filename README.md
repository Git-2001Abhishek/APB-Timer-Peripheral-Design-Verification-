# APB Timer Peripheral: Design & Verification

A 32-bit programmable down-counting timer with a 16-bit prescaler,
periodic and one-shot modes, and a maskable interrupt, accessed through an
AMBA **APB3** slave interface. Written in SystemVerilog and verified with a
self-checking testbench: reference model, scoreboard, protocol checks,
directed and constrained-random tests, functional coverage and mutation
testing.

## Features

- AMBA APB3 slave: zero wait states, `PSLVERR` on illegal accesses
- 32-bit down counter with auto-reload (periodic) or one-shot mode
- 16-bit prescaler: the counter steps every `PRESC + 1` clock cycles
- Raw / masked interrupt status, write-1-to-clear, level `irq` output
- Read-only ID register for software discovery
- Fully synchronous design with an active-low asynchronous reset; synthesizes
  to 100 flip-flops and no latches

## Interface

| Signal | Dir | Width | Description |
| --- | --- | --- | --- |
| `pclk` | in | 1 | APB clock (also the timer clock) |
| `presetn` | in | 1 | Active-low asynchronous reset |
| `psel`, `penable`, `pwrite` | in | 1 | APB control |
| `paddr` | in | `ADDR_WIDTH` (12) | Byte address, `PADDR[1:0]` ignored |
| `pwdata` / `prdata` | in / out | 32 | Write / read data |
| `pready` | out | 1 | Always 1 (zero wait states) |
| `pslverr` | out | 1 | Error response |
| `irq` | out | 1 | Interrupt, `RIS & IE` |

## Register map

| Offset | Name | Access | Reset | Description |
| --- | --- | --- | --- | --- |
| 0x00 | `CTRL` | RW | 0 | `[0]` EN: count enable, `[1]` MODE: 0 = periodic, 1 = one-shot, `[2]` IE: interrupt enable |
| 0x04 | `LOAD` | RW | 0 | Reload value. Writing it also loads `VALUE` and restarts the prescaler |
| 0x08 | `VALUE` | RO | 0 | Current count |
| 0x0C | `PRESC` | RW | 0 | `[15:0]` prescaler divide value |
| 0x10 | `RIS` | RW1C | 0 | `[0]` raw interrupt status, set on timeout, write 1 to clear |
| 0x14 | `MIS` | RO | 0 | `[0]` masked interrupt status = `RIS & IE` |
| 0x18 | `ID` | RO | `0x41505431` | "APT1" |

Any other address, and any write to `VALUE`, `MIS` or `ID`, gets
`PSLVERR = 1` and leaves all state unchanged. Reserved bits read as 0.

## Operation

```text
           PRESC+1 cycles          PRESC+1 cycles
 prescaler |0 1 .. PRESC|0 1 .. PRESC| ...
 VALUE      LOAD  LOAD-1  ...  1   0   -> timeout: RIS=1
                                         periodic: VALUE <- LOAD
                                         one-shot: EN <- 0, VALUE stays 0
```

- While `EN = 1` the prescaler counts `0 .. PRESC`. Each wrap is one step of
  the counter. A step with `VALUE = 0` is a **timeout**.
- Periodic timeout period: **`(LOAD + 1) × (PRESC + 1)` clock cycles**.
- While `EN = 0`, `VALUE` holds its value and the prescaler is cleared.
- Same-cycle priorities: a `LOAD` write beats counting (and suppresses that
  cycle's timeout), a timeout setting `RIS` beats a W1C clear, and a software
  `CTRL` write beats the one-shot auto-clear of `EN`.

Typical use:

```c
TIMER->PRESC = 99;              // 100 MHz / 100 = 1 MHz tick
TIMER->LOAD  = 999;             // 1000 ticks -> 1 ms period
TIMER->CTRL  = EN | IE;         // periodic, interrupt enabled
...
void timer_isr(void) { TIMER->RIS = 1; /* ... */ }
```

## Verification

[`tb/tb_apb_timer.sv`](tb/tb_apb_timer.sv)

```text
 directed + random tests ──► APB master BFM ──► apb_timer (DUT)
                                   │                  │
                                   ▼                  ▼
                           reference model ──► scoreboard (every cycle)
                                   │           protocol checker
                                   ▼
                           coverage counters
```

- **APB master BFM**: `apb_write` / `apb_read` tasks drive proper
  SETUP → ACCESS phases. Every read is compared against the model, and
  every `PSLVERR` against the expected error.
- **Reference model**: an independent cycle-accurate model of the register
  map and counter. The scoreboard compares `irq`, `VALUE`, the prescaler,
  `CTRL` and `RIS` with the DUT **on every clock cycle**.
- **Protocol checks**: `PENABLE` only after a SETUP phase, `PSLVERR` only
  in the ACCESS phase, `PREADY` high.

| # | Test | Checks (hand-computed, independent of the model) |
| --- | --- | --- |
| 1 | Reset values | all registers, `ID`, `irq` low |
| 2 | Register access | readback, reserved bits, 16-bit `PRESC`, `LOAD` also loads `VALUE`, `PADDR[1:0]` ignored |
| 3 | Error responses | unmapped reads/writes and writes to RO registers → `PSLVERR`, no state change |
| 4 | Periodic timing | measured `irq` period equals `(LOAD+1)(PRESC+1)` for 10, 20, 40 and 48 cycles |
| 5 | One-shot | fires once, `EN` clears, `VALUE` stays 0, no further interrupts, re-arm works |
| 6 | Interrupt masking | `RIS` vs `MIS` vs `irq` with `IE` = 0/1, writing 0 to `RIS` has no effect, W1C clears |
| 7 | Timeout vs W1C | with a timeout every cycle a W1C cannot clear `RIS` |
| 8 | Disable | `EN = 0` freezes `VALUE`, re-enabling resumes counting |
| 9 | Reset while running | everything returns to reset values |
| 10 | Constrained random | 4000 APB transactions: random registers and data, small `LOAD` / `PRESC` so timeouts happen often, 8 % illegal / unaligned addresses, random idle gaps |

### Results

[`results/sim.log`](results/sim.log): **TEST PASSED**, 21,536 cycles,
zero scoreboard mismatches. Functional coverage, with no holes:

```text
periodic timeouts           : 650
one-shot timeouts           : 53
RIS W1C clears              : 167
timeout vs W1C collisions   : 6
LOAD write pre-empting tmo  : 7
CTRL write vs one-shot stop : 1
read errors / write errors  : 115 / 893
reads  CTRL LOAD VALUE PRESC RIS MIS ID : 280 269 255 265 275 289 274
writes CTRL LOAD VALUE PRESC RIS MIS ID : 340 268 269 281 316 261 244
coverage holes              : 0
```

**Mutation testing** ([`scripts/mutate.py`](scripts/mutate.py),
[`results/mutation.log`](results/mutation.log)). To show the testbench
actually finds bugs, ten realistic bugs are injected into the RTL one at a
time. **All 10 are detected**:

| Injected bug | Errors reported |
| --- | --- |
| W1C clear beats timeout | 41 |
| Periodic reload off by one | 7335 |
| No `PSLVERR` on read-only write | 777 |
| Prescaler not cleared when disabled | 1347 |
| One-shot never stops | 12963 |
| `irq` ignores `IE` | 5732 |
| `LOAD` write does not restart prescaler | 5767 |
| `PRESC` register only 8 bits | 2 |
| `PADDR[1:0]` not ignored | 4660 |
| `MIS` reads raw status | 84 |

Waveform: programming the timer over APB (`LOAD = 9`, `CTRL = EN|IE`),
`VALUE` counting 9 → 0, a timeout every 10 cycles, and the interrupt
cleared by a W1C write to `RIS` (0x010):

![APB timer waveform](results/wave_periodic.png)

Synthesis (Yosys, generic gates) - [`results/synth_stat.txt`](results/synth_stat.txt):
679 cells and 100 flip-flops (3 `CTRL` + 32 `LOAD` + 32 `VALUE` + 16 `PRESC`
+ 16 prescaler count + 1 `RIS`), no latches.

## How to run

Requires Icarus Verilog 12+ and Python 3; Yosys is optional.

```bash
make sim        # testbench -> results/sim.log, results/apb_timer.vcd
make mutate     # mutation testing -> results/mutation.log
make synth      # Yosys synthesis check
make wave       # GTKWave
```

Without `make`:

```bash
iverilog -g2012 -o sim.vvp -s tb_apb_timer rtl/apb_timer.sv tb/tb_apb_timer.sv
vvp -n sim.vvp
```

## Tools

- SystemVerilog
- Icarus Verilog
- Yosys
- GTKWave / Python + matplotlib (waveform figure)

## Repository Structure

```text
rtl/        - apb_timer.sv
tb/         - Testbench (BFM, reference model, scoreboard, coverage)
scripts/    - Mutation testing, waveform plotting
results/    - Simulation log, mutation log, synthesis stats, waveform
```
