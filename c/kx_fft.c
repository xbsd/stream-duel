/* kx_fft.c: KissFFT (BSD-3, c/vendor/kissfft) exposed to q through the KX C API (k.h).
 *
 * Built into lib/kxfft.so by c/build.sh and loaded in q with 2:
 *   fftmag :`:lib/kxfft 2:(`fftmag;2)    / fftmag[x;n]: magnitude spectra
 *   fftpeak:`:lib/kxfft 2:(`fftpeak;5)   / fftpeak[x;n;fs;lo;hi]: dominant frequency per window
 *
 * x is a float list holding R windows of n samples each, back to back (R*n values).
 * Every function checks its argument types and lengths and returns a q error ('type, 'length,
 * 'domain, 'wsfull) instead of crashing the q process.
 */
#define KXVER 3
#include <math.h>
#include <stdlib.h>
#include "k.h"
#include "kiss_fft.h"

/* Mean-removed window i of x, transformed in place into out[0..n-1]. */
static void transform(kiss_fft_cfg cfg, const F *x, J n, kiss_fft_cpx *in, kiss_fft_cpx *out) {
  double mean = 0;
  for (J j = 0; j < n; j++) mean += x[j];
  mean /= (double)n;
  for (J j = 0; j < n; j++) { in[j].r = (kiss_fft_scalar)(x[j] - mean); in[j].i = 0; }
  kiss_fft(cfg, in, out);
}

/* Checks the window arguments. Returns 0 when they are valid, else the q error to raise.
 * (krr() returns a null K, so callers must raise the error themselves: return krr(err).) */
static const char *checkArgs(K x, K n, J *rows) {
  if (x->t != KF) return "type";
  if (n->t != -KJ && n->t != -KI) return "type";
  J w = n->t == -KJ ? n->j : n->i;
  if (w < 8 || w > (1 << 20)) return "domain";
  if (x->n % w) return "length";
  *rows = x->n / w;
  return 0;
}

/* fftmag[x;n]: for each window, |X_k|/n for k = 0..n/2. Returns R*(n/2+1) floats. */
K fftmag(K x, K n) {
  J rows; const char *e = checkArgs(x, n, &rows); if (e) return krr((S)e);
  J w = n->t == -KJ ? n->j : n->i, half = w / 2 + 1;
  kiss_fft_cfg cfg = kiss_fft_alloc((int)w, 0, NULL, NULL);
  kiss_fft_cpx *in = malloc(sizeof(kiss_fft_cpx) * w), *out = malloc(sizeof(kiss_fft_cpx) * w);
  if (!cfg || !in || !out) { free(cfg); free(in); free(out); return krr("wsfull"); }
  K r = ktn(KF, rows * half);
  for (J i = 0; i < rows; i++) {
    transform(cfg, kF(x) + i * w, w, in, out);
    for (J k = 0; k < half; k++)
      kF(r)[i * half + k] = hypot(out[k].r, out[k].i) / (double)w;
  }
  free(cfg); free(in); free(out);
  return r;
}

/* fftpeak[x;n;fs;lo;hi]: for each window sampled at fs Hz, the frequency (Hz) of the largest
 * spectral peak between lo and hi Hz, refined by parabolic interpolation on the log magnitude.
 * Returns R floats (0n when the band holds no bin). */
K fftpeak(K x, K n, K fs, K lo, K hi) {
  J rows; const char *e = checkArgs(x, n, &rows); if (e) return krr((S)e);
  if (fs->t != -KF || lo->t != -KF || hi->t != -KF) return krr("type");
  J w = n->t == -KJ ? n->j : n->i;
  double hz = fs->f, df = hz / (double)w;
  if (hz <= 0 || lo->f < 0 || hi->f <= lo->f) return krr("domain");
  J k0 = (J)ceil(lo->f / df), k1 = (J)floor(hi->f / df);
  if (k0 < 1) k0 = 1;
  if (k1 > w / 2 - 1) k1 = w / 2 - 1;
  kiss_fft_cfg cfg = kiss_fft_alloc((int)w, 0, NULL, NULL);
  kiss_fft_cpx *in = malloc(sizeof(kiss_fft_cpx) * w), *out = malloc(sizeof(kiss_fft_cpx) * w);
  if (!cfg || !in || !out) { free(cfg); free(in); free(out); return krr("wsfull"); }
  K r = ktn(KF, rows);
  for (J i = 0; i < rows; i++) {
    if (k1 < k0) { kF(r)[i] = nf; continue; }
    transform(cfg, kF(x) + i * w, w, in, out);
    J best = k0; double bm = -1;
    for (J k = k0; k <= k1; k++) {
      double m = hypot(out[k].r, out[k].i);
      if (m > bm) { bm = m; best = k; }
    }
    double a = log(hypot(out[best - 1].r, out[best - 1].i) + 1e-12);
    double b = log(bm + 1e-12);
    double c = log(hypot(out[best + 1].r, out[best + 1].i) + 1e-12);
    double den = a - 2 * b + c, shift = den != 0 ? 0.5 * (a - c) / den : 0;
    if (shift > 0.5) shift = 0.5;
    if (shift < -0.5) shift = -0.5;
    kF(r)[i] = ((double)best + shift) * df;
  }
  free(cfg); free(in); free(out);
  return r;
}
