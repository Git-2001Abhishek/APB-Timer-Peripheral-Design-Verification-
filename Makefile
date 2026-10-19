# APB timer: simulation, mutation testing, synthesis check
#
#   make sim        run the testbench (Icarus Verilog 12+)
#   make mutate     inject known bugs and confirm the testbench catches them
#   make synth      Yosys synthesis check (generic gates)
#   make lint       Verilator lint (-Wall)
#   make formal     SymbiYosys: unbounded proof (k-induction) + cover
#   make formal-mutate  confirm injected bugs break the proof
#   make wave       open the VCD in GTKWave

YOSYS  ?= yosys
SBY    ?= sby
PYTHON ?= python3

RTL = rtl/apb_timer.sv
TB  = tb/tb_apb_timer.sv

.PHONY: sim mutate synth lint formal formal-mutate wave clean

sim:
	mkdir -p results
	iverilog -g2012 -Wall -o results/sim.vvp -s tb_apb_timer $(RTL) $(TB)
	vvp -n results/sim.vvp | tee results/sim.log
	@grep -q "TEST PASSED" results/sim.log || (echo "simulation FAILED"; exit 1)

mutate:
	$(PYTHON) scripts/mutate.py > results/mutation.log; status=$$?; cat results/mutation.log; exit $$status

synth:
	$(YOSYS) -q -p "read_verilog -sv $(RTL); synth -top apb_timer; tee -q -o results/synth_stat.txt stat; check -assert"

lint:
	verilator --lint-only -Wall --top-module apb_timer $(RTL)

formal:
	cd formal && $(SBY) -f apb_timer.sby

formal-mutate:
	SBY="$(SBY)" $(PYTHON) scripts/formal_mutate.py > results/formal_mutation.log; status=$$?; cat results/formal_mutation.log; exit $$status

wave:
	gtkwave results/apb_timer.vcd &

clean:
	rm -rf build results/*.vvp results/*.vcd formal/apb_timer_*/
