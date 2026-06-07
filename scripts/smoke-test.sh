#!/usr/bin/env bash
# In-image smoke test (default CMD). Prints tool versions + PDK presence so
# `docker run --rm <image>` immediately shows what the image actually contains.
set -uo pipefail

echo "=== vybox-eda ==="
echo "Ubuntu: $(. /etc/os-release 2>/dev/null && echo "$VERSION" || echo unknown)"
echo "PDK_ROOT=${PDK_ROOT:-(unset)}"
echo

fail=0
check() {  # check <label> <cmd...>
  local label="$1"; shift
  printf '  %-12s ' "$label"
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 | head -1
  else
    echo "(MISSING)"; fail=1
  fi
}

echo "EDA toolchain:"
check yosys      yosys --version
check verilator  verilator --version
check openroad   openroad -version
check klayout    klayout -v
check magic      magic --version
check netgen     netgen -batch quit
check ngspice    ngspice --version

echo
echo "Vyges binaries (absent in rtl2gds-base):"
check vyges          vyges --version
check vyges-pdk-store vyges-pdk-store --version
check vyges-catalog  vyges-catalog --version
for e in char extract sta-si em-ir; do check "vyges-$e" "vyges-$e" --version; done

echo
echo "Board / mechanical CAD (full target only):"
check kicad-cli  kicad-cli version
check freecadcmd freecadcmd --version
check openscad   openscad --version

echo
echo "PDKs:"
for p in sky130A gf180mcuA gf180mcuB gf180mcuC gf180mcuD; do
  if [ -d "${PDK_ROOT:-/opt/vyges/pdks}/$p" ]; then echo "  $p  present"; else echo "  $p  -"; fi
done

echo
[ "$fail" -eq 0 ] && echo "core tools OK" || echo "NOTE: some core tools missing (expected for rtl2gds-base re: Vyges/CAD)"
exit 0
