#!/usr/bin/env bash
# Builds the kdb+ lane's C libraries, loaded in q through the KX C API:
#   lib/kxfft.so   KissFFT (c/kx_fft.c)
#   lib/kxblas.so  the Gram matrix through the platform BLAS (c/kx_blas.c): Apple Accelerate on
#                  macOS; OpenBLAS or another CBLAS on Linux. Without one, q falls back to mmu.
#   ./c/build.sh        (needs a C compiler: Xcode command-line tools on macOS, gcc on Linux)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p lib
CC=${CC:-cc}
SRC="c/kx_fft.c c/vendor/kissfft/kiss_fft.c"
INC="-Ic/vendor -Ic/vendor/kissfft"
OPT="-O2 -DKXVER=3 -Dkiss_fft_scalar=double"
case "$(uname -s)" in
  Darwin)
    $CC $OPT $INC -bundle -undefined dynamic_lookup $SRC -o lib/kxfft.so
    $CC $OPT -Ic/vendor -bundle -undefined dynamic_lookup c/kx_blas.c -framework Accelerate -o lib/kxblas.so ;;
  *)
    $CC $OPT $INC -shared -fPIC $SRC -lm -o lib/kxfft.so
    built=
    for blas in -lopenblas -lcblas -lblas; do
      if $CC $OPT -Ic/vendor -shared -fPIC c/kx_blas.c $blas -o lib/kxblas.so 2>/dev/null; then built=1; break; fi
    done
    [ -n "$built" ] || echo "no CBLAS library found: the kdb+ lane will multiply matrices with q's mmu" ;;
esac
echo "built $(ls lib/*.so | tr '\n' ' ')"
