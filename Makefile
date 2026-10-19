# APB timer: simulation, mutation testing, synthesis check
#
#   make sim        run the testbench (Icarus Verilog 12+)
#   make mutate     inject known bugs and confirm the testbench catches them
#   make synth      Yosys synthesis check (generic gates)
#   make lint       Verilator lint (-Wall)
#   make wave       open the VCD in GTKWave

YOSYS  ?= yosys
PYTHON ?= python3

RTL = rtl/apb_timer.sv
TB  = tb/tb_apb_timer.sv

.PHONY: sim mutate synth lint wave clean

sim:
	mkdir -p results
	iverilog -g2012 -Wall -o results/sim.vvp -s tb_apb_timer $(RTL) $(TB)
	vvp -n results/sim.vvp | tee results/sim.log

mutate:
	$(PYTHON) scripts/mutate.py | tee results/mutation.log

synth:
	$(YOSYS) -q -p "read_verilog -sv $(RTL); synth -top apb_timer; tee -q -o results/synth_stat.txt stat; check -assert"

lint:
	verilator --lint-only -Wall --top-module apb_timer $(RTL)

wave:
	gtkwave results/apb_timer.vcd &

clean:
	rm -rf build results/*.vvp results/*.vcd
