/ analytics.q: the kdb+ lane's real-time pattern matching (DESIGN.md, "The analytics").
/ Loaded by rte.q (live), tools/calibrate.q (thresholds) and tools/fixture.q (the cross-check).
/ Everything runs in q next to the data: KDB-X's AI libraries (.ai.tss, .ai.dtw), KissFFT through
/ the KX C API (lib/kxfft.so) and the platform BLAS through it too (lib/kxblas.so). peach spreads
/ the per-drone work over secondary threads when q runs with -s N.
/ Input: the two tables of schema.q. Telemetry arrives at the analysis rate (50 Hz, each value
/ already the mean of a drone's sensor samples over 20 ms), the rotor at 100 Hz.

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
NEED:max raze {count each value x} each value TPL     / telemetry samples the longest template needs
UNIXMS:946684800000f
toMs:{`long$UNIXMS+1e-6*`long$x}                      / q timestamp -> unix ms (long: JSON keeps every digit)

zn:{s:dev x; $[s>1e-12;(x-avg x)%s;0f*x]}

/ win[T;R;W;secs;rn]: from telem-like T and rotor-like R, drones 1..W: the newest secs seconds of
/ telemetry, ending for every drone at one instant (the newest sample time all of them have
/ reached), and each drone's newest rn rotor samples.
/ Feed handler shards publish at slightly different moments; a window ending at each drone's own
/ newest sample would shift drones of different shards against each other by a sample or two,
/ which is enough to break a swarm's correlation. Samples share one time grid, so this aligns them.
/ Returns `uav`newest`n`alt`ias`imuz`nr`rpm! with one row per drone in each matrix (n telemetry
/ samples; nr rotor samples, 0 when some drone has fewer than rn).
win:{[T;R;W;secs;rn]
  t:select stime,uav,alt,ias,imuz from T where uav<=W;
  if[0=count t; :()];
  newest:min exec max stime by uav from t;
  t:select from t where stime>newest-`timespan$`long$1e9*secs, stime<=newest;
  g:0!`uav xasc select stime,alt,ias,imuz by uav from t;
  o:iasc each g`stime;
  n:min count each o;
  if[n<16; :()];
  k:{[o;n;c] `float$(neg n)#'c@'o}[o;n];
  r:0!`uav xasc select stime,rpm by uav from R where uav in g`uav;
  nr:$[(count[r]=count g) and rn<=min count each r`stime; rn; 0];
  rpm:$[nr; `float$(neg nr)#'(r`rpm)@'iasc each r`stime; ()];
  `uav`newest`n`alt`ias`imuz`nr`rpm!(g`uav;newest;n;k g`alt;k g`ias;k g`imuz;nr;rpm)}

/ signatures: per drone, the best signature (lowest mean normalized distance over its channels)
/ when it is under that signature's threshold. Distance / sqrt(template length): 0 = identical shape.
sigDist:{[mode;s;tp]
  m:count tp;
  r:$[mode~`dtw; .ai.dtw.search[zn s;zn tp;1;CFG`dtw_window;::]; .ai.tss.tss[s;tp;1;::]];
  (first[r 0]%sqrt m;first r 1)}
/ sigTable: nsig x W distances and match start indexes (50 Hz samples), before thresholds.
sigTable:{[mode;w]
  per:{[mode;w;s]                                     / per signature: (W distances; W start indexes)
    tp:TPL s; cs:key tp;
    r:{[mode;w;tp;c] sigDist[mode;;`float$tp c] peach w c}[mode;w;tp] each cs;
    (avg {x[;0]} each r;(first r)[;1])}[mode;w] each SIGS;
  `dist`idx`n!(per[;0];per[;1];w`n)}
signatures:{[mode;w]
  st:sigTable[mode;w]; dist:st`dist; idx:st`idx;
  b:{x?min x} each flip dist;                         / best signature per drone
  bd:{x[y;z]}[dist]'[b;til count b];
  th:{CFG[`signatures;x;`threshold;y]}[;mode] each SIGS;
  hit:where bd<th b;
  t0:toMs[w`newest]-1000*st[`n]%CFG`ana_hz;          / ms of the window's first sample
  bi:{x[y;z]}[idx]'[b hit;hit];
  flip `uav`sig`dist`at!(w[`uav] hit;SIGS b hit;bd hit;`long$t0+1000*bi%CFG`ana_hz)}

/ anomaly: the newest window's z-normalized distance to its nearest match earlier in the series
/ (the left matrix-profile value a discord detector computes), with .ai.tss.tssdist.
discord:{[m;x] k:count[x]-m; min .ai.tss.tssdist[k#x;x k+til m;::]}
anomalies:{[w]
  m:`long$CFG[`anomaly;`window_s]*CFG`ana_hz;
  s:discord[m;] peach w`imuz;
  hit:where s>CFG[`anomaly;`threshold];
  flip `uav`score!(w[`uav] hit;s hit)}

/ swarm: drones whose altitude and airspeed both move together (pairwise correlation over the
/ window, the lower of the two), grouped into connected components of min_size or more.
/ A coordinated group flies one waveform, so its members correlate at ~1.0; min_r is set just below
/ that (config.json), which drones that merely fly the same manoeuvre at the same time do not reach.
/ Requiring both channels keeps chance correlations among a thousand drones from forming groups.
corr:{[w;c] X:{zn 1_ deltas x} peach w c; gram[X]%count first X}
swarms:{[w]
  C:corr[w;`alt]&corr[w;`ias];
  adj:C>CFG[`swarm;`min_r];
  nb:where each adj; lab:til count adj;                / neighbour lists once, then propagate labels
  while[not lab~l2:min each lab nb; lab:l2];
  gs:value group lab;
  gs:gs where (count each gs)>=CFG[`swarm;`min_size];
  {x y}[w`uav] each gs}

/ rotorFind: dominant rpm frequency (KissFFT via the C API, one call per thread's share of the drones),
/ nearest class frequency, laden or not.
rotorFind:{[w]
  c:CFG`rotor; n:`long$c`n;
  if[n>w`nr; :flip `uav`hz`cls`laden!(();();();())];
  pk:raze {[c;n;R] fftpeak[raze R;n;`float$c`hz;`float$c`lo;`float$c`hi]}[c;n] peach chunks w`rpm;
  cand:(`float$c`classes),(c`laden)*`float$c`classes;
  j:{x?min x} each abs pk-\:cand;
  flip `uav`hz`cls`laden!(w`uav;pk;`A`B`C j mod 3;j>=3)}

/ analyse[T;R;W;mode]: one pass of every feature over telem-like T and rotor-like R, timed.
/ A window shorter than the longest template (the feed skipped samples) gives `short instead.
analyse:{[T;R;W;mode]
  t0:.z.p; w:win[T;R;W;CFG`window_s;`long$CFG[`rotor;`n]];
  if[()~w; :`type`lane`empty!(`analytics;`kdb;1b)];
  if[w[`n]<NEED; :`type`lane`short`have_s`need_s`newest!(`analytics;`kdb;1b;w[`n]%CFG`ana_hz;NEED%CFG`ana_hz;toMs w`newest)];
  r:();
  ts:{[t] `long$1e-6*`long$.z.p-t};
  a:.z.p; sg:signatures[mode;w]; r,:ts a;
  a:.z.p; an:anomalies w; r,:ts a;
  a:.z.p; sw:swarms w; r,:ts a;
  a:.z.p; ro:rotorFind w; r,:ts a;
  `type`lane`mode`took`newest`rows`signatures`anomalies`swarms`rotor!(
    `analytics;`kdb;mode;`window`signatures`anomaly`swarm`rotor!(ts[t0]-sum r),r;
    toMs w`newest;(count w`uav)*w[`n]+w`nr;sg;an;sw;ro)}
