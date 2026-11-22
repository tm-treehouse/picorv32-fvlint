#!/usr/bin/env bash
# SPDX-License-Identifier: ISC
#
# Run fvlint (https://github.com/tm-treehouse/fvlint) on PicoRV32 and two
# PicoSoC peripherals.  Usage:
#
#   fvlint/run.sh                 # every configuration
#   fvlint/run.sh default irq     # just these
#
# Results go to $FVLINT_OUT/<config>/ (default: fvlint_out/): results.json,
# junit.xml and a VCD for every counterexample.  Exits 1 if any configuration
# has an unwaived FAIL, ERROR or VACUOUS result.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
out=${FVLINT_OUT:-fvlint_out}
jobs=${FVLINT_JOBS:-$(nproc 2>/dev/null || echo 2)}

# Each configuration: the top module, its sources and parameters.
set_args() {
  case $1 in
    # PicoRV32 as shipped (no IRQ, dual-port register file, no MUL/DIV).
    default)    args=(--top picorv32 "$root/picorv32.v") ;;
    # The interrupt controller, its timer and q-registers, and the
    # single-port register file (which adds the LD_RS2 state).
    irq)        args=(--top picorv32 -P ENABLE_IRQ=1 -P ENABLE_IRQ_QREGS=1 -P ENABLE_IRQ_TIMER=1
                      -P ENABLE_REGS_DUALPORT=0 --assume "$here/assume/irq.sv" "$root/picorv32.v") ;;
    # PicoSoC's UART and SPI flash controller.
    simpleuart) args=(--top simpleuart "$root/picosoc/simpleuart.v") ;;
    spimemio)   args=(--top spimemio "$root/picosoc/spimemio.v") ;;
    *)          return 1 ;;
  esac
}

configs=("$@")
[ ${#configs[@]} -gt 0 ] || configs=(default irq simpleuart spimemio)

rc=0
for cfg in "${configs[@]}"; do
  if ! set_args "$cfg"; then
    echo "unknown configuration: $cfg" >&2
    exit 2
  fi
  echo "=== fvlint: $cfg"
  status=0
  fvlint "${args[@]}" --waivers "$here/waivers/$cfg.txt" -j "$jobs" -o "$out/$cfg" || status=$?
  case $status in
    0) ;;
    1) rc=1 ;;              # findings: keep going, report at the end
    *) exit "$status" ;;    # could not run
  esac
done
exit $rc
