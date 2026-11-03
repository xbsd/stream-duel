/ tests/test_blas.q: the Gram matrix through the platform BLAS (lib/kxblas.so) against q's mmu.
/ q tests/test_blas.q   (exits 0 when every check passes, 1 otherwise)
fails:0
check:{[name;ok] -1 (("FAIL ";"pass ") ok),name; if[not ok; fails+:1]}
gram:`:lib/kxblas 2:(`gram;1)
system"S 7"
X:{x?1f} each 300#199
G:gram X
check["gram matches X mmu flip X"; 1e-12>max max abs G-X mmu flip X]
check["gram is exactly symmetric"; G~flip G]
check["gram of one row is its dot product with itself"; (enlist enlist v$v)~gram enlist v:5?1f]
check["no rows gives no rows"; ()~gram ()]
err:{@[gram;x;{x}]}
check["a float vector is a 'type error"; "type"~err 1 2f]
check["long rows are a 'type error"; "type"~err (1 2;3 4)]
check["ragged rows are a 'length error"; "length"~err (1 2f;1 2 3f)]
-1 $[fails;string[fails]," check(s) failed";"all blas checks passed"];
exit 0<fails
