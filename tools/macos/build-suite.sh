#!/bin/bash
# build-suite.sh - build the whole VMA suite as native arm64 (Apple Silicon)
# from a clean checkout of this branch. Produces the 8 program binaries plus the
# two helper C libraries (libplan404, libcspice) that atlun and calclun need.
#
# Prereq: FPC 3.2.2 + Lazarus 3.6 with the Cocoa widgetset, via fpcupdeluxe
#   (https://github.com/LongDirtyAnimAlf/fpcupdeluxe), installed into
#   <workspace>/fpcupdeluxe (see the prompt below). Override the toolchain
#   paths with FPC= LB= PCP= env vars.
#
# Usage:
#   tools/macos/build-suite.sh                 # prompts for the workspace dir
#   VMA_BUILD=~/vma-build tools/macos/build-suite.sh   # non-interactive
#
# Run from anywhere - it locates the repo as the grandparent of this script.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

# --- build workspace ------------------------------------------------------
# Everything that is not the source checkout - the fpcupdeluxe toolchain (which
# unpacks a lot of files), the extracted base data, and the packaging output -
# lives here, out of your home dir and out of the git checkout.
default_workdir="$HOME/vma-build"
if   [ -n "${VMA_BUILD:-}" ]; then WORKDIR="$VMA_BUILD"
elif [ -t 0 ]; then
  read -r -p "Build workspace [$default_workdir]: " WORKDIR
  WORKDIR="${WORKDIR:-$default_workdir}"
else
  WORKDIR="$default_workdir"
  echo "==> build workspace: $WORKDIR  (set VMA_BUILD to change)"
fi
WORKDIR="${WORKDIR/#\~/$HOME}"
mkdir -p "$WORKDIR"
WORKDIR="$(cd "$WORKDIR" && pwd)"

FPC="${FPC:-$WORKDIR/fpcupdeluxe/fpc/bin/aarch64-darwin/fpc}"
LB="${LB:-$WORKDIR/fpcupdeluxe/lazarus/lazbuild}"
PCP="${PCP:-$WORKDIR/fpcupdeluxe/config_lazarus}"

for t in "$FPC" "$LB"; do
  [ -x "$t" ] || { echo "not found / not executable: $t" >&2
    echo "install FPC 3.2.2 + Lazarus 3.6 via fpcupdeluxe into $WORKDIR/fpcupdeluxe," >&2
    echo "or set FPC= LB= PCP= to an existing toolchain." >&2
    exit 1; }
done
[ -d "$PCP" ] || { echo "Lazarus primary config dir not found: $PCP" >&2; exit 1; }

echo "==> FPC       $("$FPC" -iV 2>/dev/null || echo '?')   ($FPC)"
echo "==> lazbuild  $LB"
echo "==> repo      $REPO"
echo "==> workspace $WORKDIR"

# --- vendored Lazarus packages ----------------------------------------------
echo "==> registering vendored packages"
LPKS=(
  virtualmoon/component/synapse/laz_synapse.lpk
  virtualmoon/component/bgrabitmap/bgrabitmappack.lpk
  virtualmoon/component/downloaddialog/downldialog.lpk
  virtualmoon/component/uniqueinstance/uniqueinstance_package.lpk
  virtualmoon/component/enhedits/enhedit.lpk
  virtualmoon/component/indiclient/indiclient.lpk
  virtualmoon/component/libsql/libsql.lpk
  virtualmoon/component/glscene/Packages/GLScene_RunTime.lpk
  virtualmoon/component/glscene/Packages/GLScene_DesignTime.lpk
  virtualmoon/component/vmacomponents.lpk
)
for lpk in "${LPKS[@]}"; do
  "$LB" --pcp="$PCP" --add-package-link "$lpk" >/dev/null
done

# --- libplan404 (atlun) ---------------------------------------------------
echo "==> libplan404.dylib"
( cd virtualmoon/library/plan404
  mkdir -p obj
  make CFLAGS="-O3 -fPIC -std=gnu89 -Wno-implicit-function-declaration -Wno-deprecated-non-prototype" )

# --- CSPICE + getcell (calclun) ----------------------------------------
echo "==> libcspice.dylib + getcell.o  (~2200 C files - give it a few minutes)"
( cd calclun/cspice
  make -f Makefile.cspice all
  install_name_tool -id @executable_path/libcspice.dylib libcspice.dylib )
( cd calclun
  clang -c -O3 -w -fPIC -I./cspice getcell.c -o getcell.o )

# --- the 8 programs ----------------------------------------------------------
LB_COMMON=( --pcp="$PCP" --compiler="$FPC"
           --cpu=aarch64 --operating-system=darwin --ws=cocoa --recursive )

build() {  # <lpi> [extra lazbuild args...]
  local lpi="$1"; shift
  echo "==> lazbuild $lpi ${*:+($*)}"
  "$LB" "${LB_COMMON[@]}" "$@" "$lpi"
}

build virtualmoon/atlun.lpi
build calclun/calclun.lpi
build datlun/datlun.lpi
build notelun/notelun.lpi
build photlun/photlun.lpi
build weblun/weblun.lpi
build cclun/cclun.lpi
build catlun/catlun.lpi --build-mode=default

# --- report ----------------------------------------------------------------
echo
echo "==> results"
ok=1
check() { if [ -f "$REPO/$1" ]; then echo "    OK   $1"; else echo "    MISS $1"; ok=0; fi; }
check virtualmoon/units/aarch64-darwin-cocoa/atlun
check calclun/calclun
check datlun/units/aarch64-darwin-cocoa/datlun
check notelun/notelun
check photlun/photlun
check weblun/weblun
check cclun/cclun
check catlun/units/aarch64-darwin-cocoa/catlun
check virtualmoon/library/plan404/libplan404.dylib
check calclun/cspice/libcspice.dylib
echo
if [ "$ok" = 1 ]; then
  echo "    all present."
  echo "    next: put base data under $WORKDIR/basedata (README step 3), then"
  echo "          VMA_BUILD=$WORKDIR tools/macos/package-app.sh"
else
  echo "    some targets missing - see the lazbuild output above" >&2
  exit 1
fi
