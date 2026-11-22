<!-- SPDX-License-Identifier: ISC -->

# Formal lint with fvlint

This fork of PicoRV32 shows how [fvlint](https://github.com/tm-treehouse/fvlint)
fits into an existing RTL project. fvlint finds counters, `case` statements,
part-selects, memories and state machines in the RTL and proves a small, local
property about each one: a counter never wraps, the items of a
`parallel_case` never overlap, an address stays inside its memory, every
state of an FSM is reachable. Every check runs on its own slice of the design,
so all 74 checks on PicoRV32 take about four minutes on two cores.

It complements the [riscv-formal](https://github.com/YosysHQ/riscv-formal)
job in `.github/workflows/ci.yml` rather than replacing it. riscv-formal
proves that the core implements the RISC-V ISA. fvlint knows nothing about
the ISA. It checks the structures the RTL is built from and points at the
line where something can go wrong.

Everything for it is in this directory, plus one workflow:

| File | What it is |
|---|---|
| `run.sh` | runs fvlint on each configuration below |
| `waivers/<config>.txt` | reviewed findings, one line each, with the reason |
| `assume/irq.sv` | the environment for the `irq` configuration |
| `summary.py` | turns `results.json` into the table in the CI job summary |
| `../.github/workflows/fvlint.yml` | CI: one job per configuration |

## Running it

fvlint needs Python 3.11+, Yosys, SymbiYosys and a solver. The
[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) has them
all. Without it, the `yowasp` extra installs a pip-only toolchain (slower):

```sh
pip install "fvlint @ git+https://github.com/tm-treehouse/fvlint@v0.3.2"
# or, with no OSS CAD Suite:
pip install "fvlint[yowasp] @ git+https://github.com/tm-treehouse/fvlint@v0.3.2"

fvlint/run.sh                  # every configuration
fvlint/run.sh default spimemio # just these
```

Results land in `fvlint_out/<config>/`: `results.json`, `junit.xml`, and a
VCD for every counterexample. The script exits 1 if any configuration has a
`FAIL`, `ERROR` or `VACUOUS` result that no waiver covers. `FVLINT_OUT` and
`FVLINT_JOBS` change the output directory and the number of parallel proofs.

## Configurations

PicoRV32 is configured through parameters, and logic a parameter switches off
can't be checked. So the core runs twice, and two PicoSoC peripherals run on
their own:

| Config | Top | What it covers | Checks | Waived | Time (2 cores) |
|---|---|---|---|---|---|
| `default` | `picorv32` | the core as shipped | 74 | 15 | 1.5 min |
| `irq` | `picorv32` | `ENABLE_IRQ`, q registers, the IRQ timer, and the single-port register file (`ENABLE_REGS_DUALPORT=0`, which adds the LD_RS2 state) | 71 | 7 | 2 min |
| `simpleuart` | `simpleuart` | PicoSoC's UART | 6 | 4 | seconds |
| `spimemio` | `spimemio` | PicoSoC's SPI flash controller | 3 | 1 | seconds |

Waived checks are skipped rather than proved, which is why the times are
short. To see whether a waiver is still needed, run fvlint on that
configuration without `--waivers`.

## What fvlint found

Every finding below was traced back to the RTL before it got a waiver.
The waiver files hold the one-line version.

### A real one: q registers past the end of the register file

With `ENABLE_IRQ_QREGS`, the register file has 36 entries: x0 to x31, then
q0 to q3. The README gives the encodings of `getq rd, qs` and `setq qd, rs`
with the q register in a 5-bit field whose upper three bits are zero
(`000XX`). The decoder doesn't check those bits. Without an assumption, the
`irq` configuration reports `mem_addr:cpuregs.wr0` and `mem_addr:cpuregs.rd0`
as `FAIL`. The counterexample fetches `0x0200080b`, which is `setq q16, x0`,
and writes `cpuregs[48]`. Simulation drops that write. What a synthesized
register file does with it depends on how the memory is mapped.

The fix would be to treat those encodings as illegal instructions. This fork
leaves the RTL as it is, and `assume/irq.sv` instead states the contract that
software uses only the documented encodings. With that assumption fvlint
proves both address checks. The assumption is on `mem_rdata`, which carries
load data too, so it also rules out loading a word that looks like such an
instruction. That makes no difference to these checks.

### Logic the default parameters switch off

With the default `ENABLE_REGS_DUALPORT=1`, nothing ever enters the LD_RS2
state (`fsm_unreachable:cpu_state=8'b00010000`), so the four checks of the
`case` inside it are `VACUOUS`. With `ENABLE_IRQ=0`, the IRQ timer never
counts down (`counter_underflow:timer`, `timer#1`). All of these are waived
in `default` and checked in `irq`, where they are proven.

### `full_case` on signals already set to `'x`

PicoRV32 marks several `case` statements `(* parallel_case, full_case *)`.
fvlint's `full_case` check fails when a cycle arrives in which no item that
assigns the signal matches, because synthesis may then produce any value
while simulation keeps the value from before the `case`. Here every such
signal is first set to `'x` (`alu_out_0 = 'bx;`, `reg_out <= 'bx;`,
`reg_sh <= 'bx;`, and `next_irq_pending` when `ENABLE_IRQ=0`). Simulation
and synthesis agree that the value is a don't-care, so these are waived.

### An overlap nobody sees

`parallel_case:alu_out_0` fails: in the first cycle after an instruction is
decoded (LD_RS1), the `instr_*` flags already describe the new instruction
while the registered `is_*` flags still describe the previous one, so after
a `bltu`, a `bgeu` matches two items. `alu_out_0` isn't used until EXEC, one
cycle later, when the flags agree.

### Design intent

* `fsm_trap:cpu_state={8'b10000000}`: TRAP sets `trap` and stays there until
  reset. That's the intended behaviour.
* `counter_overflow:count_instr` ends `UNKNOWN`. It is a 64-bit counter.
* `counter_overflow:rd_addr` in `spimemio`: the sequential prefetch address
  wraps from `24'hfffffc` to 0. A flash's continuous read wraps the same way,
  and a request is served only when its address equals `rd_addr`.
* The four `simpleuart` divider counters end `UNKNOWN`. They are 32-bit
  counts compared against a divider software can set to anything. With a
  divider of `32'hffffffff` the receive count never reaches
  `> cfg_divider` and does wrap, but only after 2^32 cycles, and such a
  divider (43 s per bit at 100 MHz) isn't usable anyway. The transmit count
  also runs while the UART is idle and is cleared before every byte.

### Informational results

fvlint also reports `INFO` lines: `count_cycle` is free-running (its wrap
looks intentional, so it isn't checked), and FSM summaries such as
"8 reachable states from reset 8'b01000000" for `cpu_state` in `irq`.
In `irq`, Yosys' FSM extraction trips an internal assertion on `irq_state`.
fvlint prints a warning and checks the other FSMs without it.

## In CI

`.github/workflows/fvlint.yml` runs one job per configuration on every push
and pull request. Each job installs the OSS CAD Suite (pinned to a build
from just after Yosys 0.71) and fvlint (pinned to a release tag), runs
`run.sh`, writes the results that aren't `PROVEN` into the job summary, and
uploads `fvlint_out/<config>` with the counterexample traces as an artifact.

A new `FAIL`, `ERROR` or `VACUOUS` result fails the job. To accept it, add a
line to that configuration's waiver file with the check id and the reason, or
put `(* fvlint_waive = "kind" *)` on the register in the RTL. Check ids name the
register or memory port, not the line, so they survive edits elsewhere in
the file. Where fvlint can't name a destination, the id falls back to the
line (`full_case:picorv32.v:1757`), and that waiver needs updating if the
line moves.

To update fvlint, change the tag in the workflow and in the commands above,
then run `fvlint/run.sh` and review what changed.
