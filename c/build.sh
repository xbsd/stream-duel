#!/usr/bin/env bash
# Builds lib/kxfft.so: KissFFT exposed to q through the KX C API (see c/kx_fft.c).
#   ./c/build.sh        (needs a C compiler: Xcode command-line tools on macOS, gcc on Linux)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p lib
CC=${CC:-cc}
SRC="c/kx_fft.c c/vendor/kissfft/kiss_fft.c"
INC="-Ic/vendor -Ic/vendor/kissfft"
OPT="-O2 -DKXVER=3 -Dkiss_fft_scalar=double"
case "$(uname -s)" in
  Darwin) $CC $OPT $INC -bundle -undefined dynamic_lookup $SRC -o lib/kxfft.so ;;
  *)      $CC $OPT $INC -shared -fPIC $SRC -lm -o lib/kxfft.so ;;
esac
echo "built lib/kxfft.so"
