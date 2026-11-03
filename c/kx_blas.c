/* kx_blas.c: the Gram matrix X·Xᵀ through the platform BLAS, exposed to q with the KX C API (k.h).
 *
 * Built into lib/kxblas.so by c/build.sh and loaded in q with 2:
 *   gram:`:lib/kxblas 2:(`gram;1)   / gram[X]: X mmu flip X, for R float rows of equal length
 *
 * It calls cblas_dsyrk, the routine NumPy uses for X @ X.T. On macOS that is Apple Accelerate,
 * the BLAS NumPy links there, so both lanes of Stream Duel multiply with the same library.
 * Wrong argument types or lengths return a q error ('type, 'length, 'wsfull), never a crash.
 */
#define KXVER 3
#include <stdlib.h>
#include <string.h>
#include "k.h"

/* The standard CBLAS routine and constants, declared here: the platform headers (Accelerate's on
 * macOS) pull in names that clash with k.h's short ones (I, KU, ymd, ...). */
enum { CblasRowMajor = 101, CblasNoTrans = 111, CblasUpper = 121 };
extern void cblas_dsyrk(int order, int uplo, int trans, int n, int k, double alpha, const double *a,
                        int lda, double beta, double *c, int ldc);

/* gram[X]: for a list of R float vectors of length m, the R x R matrix of their dot products. */
K gram(K x) {
  if (x->t != 0) return krr("type");
  J r = x->n;
  if (r == 0) return ktn(0, 0);
  J m = kK(x)[0]->n;
  for (J i = 0; i < r; i++) {
    K v = kK(x)[i];
    if (v->t != KF) return krr("type");
    if (v->n != m) return krr("length");
  }
  double *a = malloc(sizeof(double) * r * (m ? m : 1)), *c = malloc(sizeof(double) * r * r);
  if (!a || !c) { free(a); free(c); return krr("wsfull"); }
  for (J i = 0; i < r; i++) memcpy(a + i * m, kF(kK(x)[i]), sizeof(double) * m);
  /* upper triangle of a·aᵀ (row-major), mirrored below */
  cblas_dsyrk(CblasRowMajor, CblasUpper, CblasNoTrans, (int)r, (int)m, 1.0, a, (int)(m ? m : 1),
              0.0, c, (int)r);
  K res = ktn(0, r);
  for (J i = 0; i < r; i++) {
    K row = ktn(KF, r);
    F *o = kF(row);
    for (J j = 0; j < i; j++) o[j] = c[j * r + i];
    memcpy(o + i, c + i * r + i, sizeof(double) * (r - i));
    kK(res)[i] = row;
  }
  free(a); free(c);
  return res;
}
