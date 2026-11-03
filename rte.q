/ rte.q: the kdb+ lane's real-time engine (Stream Duel, DESIGN.md).
/ q rte.q -p 5112 -tp 5110 -rdb 5111 -s 8
/ As in kdb+tick, analytics run in their own subscriber, not in the RDB, so the RDB's ingest never
/ waits for them. The RTE subscribes to the tickerplant, keeps only the watched drones' newest
/ few seconds in memory, runs analytics.q every second, and hands each result to the RDB, which
/ relays it to the page.
\l schema.q
\l analytics.q
o:.Q.opt .z.x
arg:{[k;d] $[k in key o;first o k;d]}
TPP:"J"$arg[`tp;"5110"]
RDBP:"J"$arg[`rdb;"5111"]
WATCH:1024
N:1024; HZ:200
KEEPS:1+CFG`window_s                    / seconds of rows kept (window plus a margin)
buf:telem
LASTA:0Np

upd:{[t;x] w:where (x 2)<=N&WATCH; if[count w; `buf insert x@\:w];}

prune:{
  if[0=count buf; :()];
  t0:last[buf`time]-`timespan$`long$1e9*KEEPS+0.5;
  buf::((buf`time) binr t0) _ buf}

setFleet:{[n;hz] N::n; HZ::hz;}
setMode:{[m] if[m in `tss`dtw; MODE::m]; MODE}

run:{
  r:analyse[buf;N&WATCH;MODE;HZ];
  r[`watch]:N&WATCH; r[`engine]:`rte; r}

.z.ts:{
  now:.z.p;
  if[(null LASTA) or CFG[`every_ms]<=1e-6*`long$now-LASTA;
    LASTA::now; prune[];
    r:@[run;::;{`type`lane`error!(`analytics;`kdb;x)}];
    @[neg RDBH;(`relay;r);{}]];
 }

TPH:hopen `$"::",string TPP
RDBH:hopen `$"::",string RDBP
TPH(".u.sub";`telem;`rte);
\t 100
-1"kdb+ lane: real-time engine on ",string[system"p"],", subscribed to tickerplant ",string[TPP],", ",string[system"s"]," secondary thread(s)";
