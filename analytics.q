/ analytics.q: the kdb+ lane's real-time pattern matching (DESIGN.md, "The analytics").
/ Loaded by rdb.q (live) and tools/calibrate.q (thresholds). Everything runs in q next to the
/ data: KDB-X's AI libraries (.ai.tss, .ai.dtw), KissFFT through the KX C API (lib/kxfft.so) and the
/ platform BLAS through it too (lib/kxblas.so). peach spreads the per-drone work over secondary
/ threads when q runs with -s N.

.ai:use`kx.ai
fftpeak:`:lib/kxfft 2:(`fftpeak;5)
/ the rows of a matrix in one chunk per secondary thread, for peach (one chunk without threads)
chunks:{(1|ceiling count[x]%1|system"s") cut x}
/ gram[X]: X mmu flip X through the platform BLAS (lib/kxblas.so: Apple Accelerate on macOS, the
/ library NumPy multiplies with there). Where it isn't built, q's mmu with the rows spread over threads.
gram:@[`:lib/kxblas 2:;(`gram;1);{[e] {raze mmu[;flip x] peach chunks x}}]
CFG:.j.k raze read0`:config.json
TPL:.j.k raze read0`:templates.json                  / sig -> channel -> template (floats)
SIGS:key TPL
MODE:`$CFG`mode                                       / `tss or `dtw, switchable from the page
UNIXMS:946684800000f
toMs:{`long$UNIXMS+1e-6*`long$x}                      / q timestamp -> unix ms (long: JSON keeps every digit)

zn:{s:dev x; $[s>1e-12;(x-avg x)%s;0f*x]}
down:{[x;f] avg each f cut x}                          / block means: hz -> ana_hz (one series)
downM:{[M;f] raze {[f;M] flip avg each f cut flip M}[f] peach chunks M}  / every row of a matrix

/ win[tbl;W;secs;hz]: the newest secs seconds of drones 1..W from a telem-like table sampled at
/ hz, ending for every drone at one instant: the newest sample time all of them have reached.
/ Feed handler shards publish at slightly different moments; a window ending at each drone's own
/ newest sample would shift drones of different shards against each other by a sample or two,
/ which is enough to break a swarm's correlation. Samples share one time grid, so this aligns them.
/ Returns `uav`newest`hz`n`alt`ias`rpm`imuz! with one row per drone in each W' x n matrix.
win:{[tbl;W;secs;hz]
  t:select stime,uav,alt,ias,rpm,imuz from tbl where uav<=W;
  if[0=count t; :()];
  newest:min exec max stime by uav from t;
  t:select from t where stime>newest-`timespan$`long$1e9*secs, stime<=newest;
  g:0!`uav xasc select stime,alt,ias,rpm,imuz by uav from t;
  o:iasc each g`stime;
  n:min count each o;
  if[n<16; :()];
  k:{[o;n;c] `float$(neg n)#'c@'o}[o;n];
  `uav`newest`hz`n`alt`ias`rpm`imuz!(g`uav;newest;hz;n;k g`alt;k g`ias;k g`rpm;k g`imuz)}

/ signatures: per drone, the best signature (lowest mean normalized distance over its channels)
/ when it is under that signature's threshold. Distance / sqrt(template length): 0 = identical shape.
sigDist:{[mode;s;tp]
  m:count tp;
  r:$[mode~`dtw; .ai.dtw.search[zn s;zn tp;1;CFG`dtw_window;::]; .ai.tss.tss[s;tp;1;::]];
  (first[r 0]%sqrt m;first r 1)}
/ sigTable: nsig x W distances and match start indexes (downsampled samples), before thresholds.
sigTable:{[mode;w;f]
  D:`alt`ias`imuz!{[w;f;c] downM[w c;f]}[w;f] each `alt`ias`imuz;
  per:{[mode;D;s]                                     / per signature: (W distances; W start indexes)
    tp:TPL s; cs:key tp;
    r:{[mode;D;tp;c] sigDist[mode;;`float$tp c] peach D c}[mode;D;tp] each cs;
    (avg {x[;0]} each r;(first r)[;1])}[mode;D] each SIGS;
  `dist`idx`n!(per[;0];per[;1];count first D`alt)}
signatures:{[mode;w;f]
  st:sigTable[mode;w;f]; dist:st`dist; idx:st`idx;
  b:{x?min x} each flip dist;                         / best signature per drone
  bd:{x[y;z]}[dist]'[b;til count b];
  th:{CFG[`signatures;x;`threshold;y]}[;mode] each SIGS;
  hit:where bd<th b;
  t0:toMs[w`newest]-1000*st[`n]%CFG`ana_hz;          / ms of the first downsampled sample
  bi:{x[y;z]}[idx]'[b hit;hit];
  flip `uav`sig`dist`at!(w[`uav] hit;SIGS b hit;bd hit;`long$t0+1000*bi%CFG`ana_hz)}

/ anomaly: the newest window's z-normalized distance to its nearest match earlier in the series
/ (the left matrix-profile value a discord detector computes), with .ai.tss.tssdist.
discord:{[m;x] k:count[x]-m; min .ai.tss.tssdist[k#x;x k+til m;::]}
anomalies:{[w;f]
  m:`long$CFG[`anomaly;`window_s]*CFG`ana_hz;
  s:discord[m;] peach downM[w`imuz;f];
  hit:where s>CFG[`anomaly;`threshold];
  flip `uav`score!(w[`uav] hit;s hit)}

/ swarm: drones whose altitude and airspeed both move together (pairwise correlation over the
/ window, the lower of the two), grouped into connected components of min_size or more.
/ A coordinated group flies one waveform, so its members correlate at ~1.0; min_r is set just below
/ that (config.json), which drones that merely fly the same manoeuvre at the same time do not reach.
/ Requiring both channels keeps chance correlations among a thousand drones from forming groups.
corr:{[w;f;c] X:{zn 1_ deltas x} peach downM[w c;f]; gram[X]%count first X}
swarms:{[w;f]
  C:corr[w;f;`alt]&corr[w;f;`ias];
  adj:C>CFG[`swarm;`min_r];
  nb:where each adj; lab:til count adj;                / neighbour lists once, then propagate labels
  while[not lab~l2:min each lab nb; lab:l2];
  gs:value group lab;
  gs:gs where (count each gs)>=CFG[`swarm;`min_size];
  {x y}[w`uav] each gs}

/ rotor: dominant rpm frequency (KissFFT via the C API, one call per thread's share of the drones),
/ nearest class frequency, laden or not.
rotor:{[w]
  c:CFG`rotor; n:`long$c`n;
  if[n>w`n; :flip `uav`hz`cls`laden!(();();();())];
  pk:raze {[c;n;hz;R] fftpeak[raze (neg n)#'R;n;hz;`float$c`lo;`float$c`hi]}[c;n;`float$w`hz] peach chunks w`rpm;
  cand:(`float$c`classes),(c`laden)*`float$c`classes;
  j:{x?min x} each abs pk-\:cand;
  flip `uav`hz`cls`laden!(w`uav;pk;`A`B`C j mod 3;j>=3)}

/ analyse[tbl;W;mode]: one pass of every feature over a telem-like table, timed.
analyse:{[tbl;W;mode;hz]
  t0:.z.p; w:win[tbl;W;CFG`window_s;hz];
  if[()~w; :`type`lane`empty!(`analytics;`kdb;1b)];
  f:`long$1|w[`hz] div CFG`ana_hz;
  r:();
  ts:{[t] `long$1e-6*`long$.z.p-t};
  a:.z.p; sg:signatures[mode;w;f]; r,:ts a;
  a:.z.p; an:anomalies[w;f]; r,:ts a;
  a:.z.p; sw:swarms[w;f]; r,:ts a;
  a:.z.p; ro:rotor w; r,:ts a;
  `type`lane`mode`took`newest`rows`signatures`anomalies`swarms`rotor!(
    `analytics;`kdb;mode;`window`signatures`anomaly`swarm`rotor!(ts[t0]-sum r),r;
    toMs w`newest;(count w`uav)*w`n;sg;an;sw;ro)}
