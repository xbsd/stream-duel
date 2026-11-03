/ tools/calibrate.q: choose config.json thresholds from planted ground truth.
/ q tools/calibrate.q -s 8 [-write 1]
/ Generates SECS seconds of telemetry for drones 1..W with gen.q's sigDuel (as the feed handlers
/ do), slides the analytics window along it every second, scores every drone with analytics.q,
/ and labels each (drone, window) from planted[]. For each signature (tss and dtw modes) and for
/ the anomaly score it picks the threshold with the best F1 and prints precision and recall.
/ Swarm and rotor have fixed rules; their precision and recall are reported too.
/ With -write 1 it writes the chosen thresholds into config.json.
\l gen.q
\l analytics.q
o:.Q.opt .z.x
WRITE:$[`write in key o;1~"J"$first o`write;0b]
W:256; HZ:200; SECS:96; S0:10                               / slots S0.. of wrapped time
U0:1762000000 - 1762000000 mod 1024                          / a unix second at wrapped time 0
ids:til W; P:{h01 h2[ids;x]} each 1+til 8
uts:(SLOT*S0)+til[SECS*HZ]%HZ
ts:raze W#'uts; ix:raze (count uts)#enlist ids; uav:1+ix     / sample-major, as fh.q emits
v:sigDuel[ts;P[;ix];(count ts)#0b;uav]
tsAt:{[u] `timestamp$(`long$1e9*u)-UNIX}
tbl:([] stime:tsAt U0+ts; uav:`int$uav; alt:`real$120+38*v 1; ias:`real$18+7*v 2;
  rpm:`real$7200+1500*v 3; imuz:`real$2.4*v 0)
tbl:`stime xasc tbl
-1"generated ",string[count tbl]," rows for ",string[W]," drones over ",string[SECS]," s";
pl:planted[tsAt U0+SLOT*S0;tsAt U0+SLOT*S0+SECS]
pl:select from pl where uav<=W
ends:U0+(SLOT*S0)+CFG[`window_s]+1+til `long$SECS-CFG[`window_s]+1   / window end times (unix s)
f:HZ div CFG`ana_hz
rows:{[e] (tbl`stime) binr tsAt e}
/ one evaluation pass: per window, raw scores for every drone
evalWin:{[mode;e]
  w:win[(rows e)#tbl;W;CFG`window_s;HZ];
  st:sigTable[mode;w;f];
  m:`long$CFG[`anomaly;`window_s]*CFG`ana_hz;
  an:discord[m;] peach down[;f] each w`imuz;
  `e`uav`dist`anom!(e;w`uav;st`dist;an)}
/ labels: signature s is positive for drone u in window ending e when the window holds a planted
/ s's onset and at least the template's length of it (all of it, for events shorter than the
/ template); negative when no planted s overlaps the window; otherwise ambiguous (skipped).
TLEN:{(count first value TPL x)%CFG`ana_hz} each SIGS!SIGS    / template length per signature, s
lab:{[s;u;e]
  ev:select from pl where uav=u, kind=s, t1>e-CFG`window_s, t0<e;
  if[0=count ev; :0];
  need:TLEN[s]&ev[`t1]-ev`t0;
  have:(e&ev`t1)-ev`t0;
  $[any (ev[`t0]>=e-CFG`window_s) and have>=need-0.02;1;0N]}
best:{[sc;y]                                                  / threshold with the best F1 (low = hit)
  k:where not null y; sc:sc k; y:y k;
  if[(0=sum y) or 0=sum not y; :`th`p`r`f1`n!(0n;0n;0n;0n;count y)];
  c:asc distinct sc;
  r:{[sc;y;t] h:sc<=t; tp:sum h&y; p:tp%1|sum h; rc:tp%sum y; (t;p;rc;2*p*rc%1e-9|p+rc)}[sc;y] each c;
  b:r {x?max x} r[;3];
  `th`p`r`f1`n!(b 0;b 1;b 2;b 3;count y)}
RES:`tss`dtw!2#enlist (`$())!()                              / mode -> feature -> result
{[mode]
  t:.z.p; E:evalWin[mode] each ends;
  -1"\n",string[mode],": ",string[count ends]," windows scored in ",string[`long$1e-6*`long$.z.p-t]," ms";
  {[mode;E;s] i:SIGS?s;
    sc:raze {x[`dist] y}[;i] each E;
    y:raze {[s;x] lab[s;;x`e] each x`uav}[s] each E;
    b:best[sc;`long$y];
    RES[mode;s]:b;
    -1"  ",(-8$string s)," threshold ",(-7$string .01*`long$100*b`th),
      " precision ",(-5$string .01*`long$100*b`p)," recall ",(-5$string .01*`long$100*b`r),
      " (",string[b`n]," labelled drone-windows)";
   }[mode;E] each SIGS;
  if[mode~`tss;
    sc:raze E@\:`anom;
    y:raze {[x] {[u;e] j:select from pl where uav=u, kind=`jam, t1>e-0.5, t0<e;
      a:select from pl where uav=u, t1>e-CFG`window_s, t0<e, kind<>`laden;
      $[count j;1;count a;0N;0]}[;x`e] each x`uav} each E;
    b:best[neg sc;`long$y]; b[`th]:neg b`th;                 / anomaly: high score = hit
    RES[`tss;`anomaly]:b;
    -1"  anomaly  threshold ",(-7$string .01*`long$100*b`th)," precision ",(-5$string .01*`long$100*b`p),
      " recall ",(-5$string .01*`long$100*b`r)," (jam in the newest 0.5 s against event-free windows)"];
 } each `tss`dtw;
/ swarm and rotor, on one window inside a slot
e:U0+(SLOT*(S0+2))+8; w:win[(rows e)#tbl;W;CFG`window_s;HZ]
sw:swarms[w;f]; found:raze sw
truth:exec distinct uav from pl where kind=`swarm, t0<=e-CFG`window_s, t1>=e
-1"\nswarm: ",string[count sw]," groups found; members precision ",string[.01*`long$100*(count found inter truth)%1|count found],
  " recall ",string .01*`long$100*(count found inter truth)%1|count truth;
ro:rotor w; busy:exec distinct uav from pl where t1>e-CFG`window_s, t0<e, kind<>`swarm
ok:select from ro where not uav in busy
-1"rotor: class accuracy on drones without events ",string .01*`long$100*avg (ok`cls)=`A`B`C airClass ok`uav;
ld:exec distinct uav from pl where kind=`laden, t0<=e-2.56, t1>=e
-1"rotor: laden drones flagged ",string[sum exec laden from ro where uav in ld]," of ",string[count ld],
  "; false laden ",string sum exec laden from ro where not uav in ld;
if[WRITE;
  c:.j.k raze read0`:config.json;
  c:{[c;x] b:RES[x 0;x 1]; if[not null b`th; c[`signatures;x 1;`threshold;x 0]:b`th]; c}/[c;(`tss`dtw) cross SIGS];
  a:RES[`tss;`anomaly]; if[not null a`th; c[`anomaly;`threshold]:a`th];
  `:config.json 0: enlist .j.j c; -1"\nwrote thresholds to config.json"];
exit 0
