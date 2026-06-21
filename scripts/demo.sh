#!/usr/bin/env bash
# =============================================================================
# demo.sh — RAD-HARD-AI radiation-hardening demo (judge-facing).
#
# Compiles the real SystemVerilog accelerator, runs a chip-level fault-injection
# simulation (tb_chip_ecc_fault), and narrates the radiation-hardening story.
# EVERY number below is parsed from the live RTL run — nothing is hardcoded.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."          # repo root

RTL=(rtl/chip.sv rtl/ctrl_seq.sv rtl/conv1_stage.sv rtl/conv2_stage.sv \
     rtl/fc1_stage.sv rtl/fc2_stage.sv rtl/telemetry_regs.sv \
     rtl/ecc_secded.sv rtl/weight_mem_ecc.sv rtl/weight_mem.sv)
TB=tb/tb_chip_ecc_fault.sv
VVP=/tmp/rad_demo.vvp
OUT=/tmp/rad_demo.out

command -v iverilog >/dev/null || { echo "ERROR: iverilog not found (brew install icarus-verilog)"; exit 1; }

echo
echo "  Building radiation-hardened INT8 CNN accelerator (SystemVerilog)..."
iverilog -g2012 -o "$VVP" "$TB" "${RTL[@]}" 2>/dev/null
echo "  Running fault-injection simulation on the real RTL..."
vvp "$VVP" 2>/dev/null > "$OUT"

# --- parse helpers (all values come straight from the RTL run) --------------
field() { grep "^RESULT $1 " "$OUT" | grep -oE "$2=[0-9]+" | cut -d= -f2; }

cl_class=$(field clean class);   cl_scrub=$(field clean scrub);   cl_ecc=$(field clean ecc2)
c1s_class=$(field c1w_single class); c1s_scrub=$(field c1w_single scrub)
c1d_class=$(field c1w_double class); c1d_ecc=$(field c1w_double ecc2)
c2s_class=$(field c2w_single class); c2s_scrub=$(field c2w_single scrub)
c2d_class=$(field c2w_double class); c2d_ecc=$(field c2w_double ecc2)
f2s_class=$(field f2w_single class); f2s_scrub=$(field f2w_single scrub)
f2d_class=$(field f2w_double class); f2d_ecc=$(field f2w_double ecc2)
pass=$(field verdict pass)

# qualitative words derived from the numbers, not asserted
say_unchanged() { [ "$1" = "$cl_class" ] && echo "UNCHANGED" || echo "CHANGED"; }

B=$'\033[1m'; R=$'\033[0m'; Y=$'\033[33m'; G=$'\033[32m'; RED=$'\033[31m'

cat <<EOF

${B}============================================================${R}
${B}   RAD-HARD-AI  —  surviving cosmic rays in silicon${R}
${B}============================================================${R}

  An INT8 CNN inference accelerator running in orbit. High-energy
  particles flip bits inside its weight memory. Watch what happens.

  ${B}--- Normal operation (no radiation) ---${R}
    Inference output ............ digit ${G}${cl_class}${R}
    ECC corrections logged ...... ${cl_scrub}
    Double-bit errors logged .... ${cl_ecc}

  ${Y}--- ${B}☄  COSMIC RAY HITS A conv1 WEIGHT${R}${Y}  (single-bit upset) ---${R}
    One bit of a stored SECDED weight codeword just flipped.
    Re-running inference on the corrupted memory...
      Prediction .............. digit ${G}${c1s_class}${R}  ($(say_unchanged "$c1s_class"))
      ECC corrections ......... ${cl_scrub} -> ${G}${c1s_scrub}${R}   <- hardware caught & corrected it
    The Hamming decoder repaired the weight before the MAC ever saw it.

  ${Y}--- ${B}☄ ☄  DOUBLE STRIKE, same word${R}${Y}  (two-bit upset) ---${R}
    Two bits flipped — past what single-error-correct can fix.
      Prediction .............. digit ${RED}${c1d_class}${R}  ($(say_unchanged "$c1d_class"))
      Double-bit errors ....... ${cl_ecc} -> ${RED}${c1d_ecc}${R}   <- detected & flagged uncorrectable
    SECDED can't fix a double error — but it never silently lies: it
    raises the alarm so the system knows the output is untrustworthy.

  ${B}--- Same protection across the weight memory ---${R}
    array   single-bit upset        double-bit upset
    conv1   digit ${c1s_class}, scrub->${c1s_scrub}        digit ${c1d_class}, ecc2->${c1d_ecc}
    conv2   digit ${c2s_class}, scrub->${c2s_scrub}        digit ${c2d_class}, ecc2->${c2d_ecc}
    fc2     digit ${f2s_class}, scrub->${f2s_scrub}        digit ${f2d_class}, ecc2->${f2d_ecc}

${B}============================================================${R}
EOF

if [ "${pass}" = "1" ]; then
    echo "  ${G}${B}RESULT: ECC is LIVE — single-bit upsets corrected, double-bit"
    echo "  upsets detected, on real RTL. The chip keeps computing.${R}"
    echo "${B}============================================================${R}"
    echo
    exit 0
else
    echo "  ${RED}${B}RESULT: FAIL — see $OUT${R}"
    echo "${B}============================================================${R}"
    exit 1
fi
