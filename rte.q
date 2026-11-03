/ rte.q: the kdb+ lane's real-time engine (Stream Duel, DESIGN.md).
/ q rte.q -p 5112 -tp 5110 -rdb 5111 -s 8
/ As in kdb+tick, analytics run in their own subscriber, not in the RDB, so the RDB's ingest never
/ waits for them. The RTE subscribes to the tickerplant, keeps only the watched drones' newest
/ few seconds in memory, runs analytics.q every second, and hands each result to the RDB as ready
/ JSON, which the RDB only forwards to the page. It also lists the planted events (gen.q) for the
/ page's scoring, so the RDB's main thread does nothing but ingest and stats.
\l schema.q
\l gen.q
\l analytics.q
\P 15                                  / JSON floats keep 15 digits (q's default is 7)
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
/ planted events of the last 60 s and every watched drone's airframe class, for the page's scoring
planted60:{
  p:planted[.z.p-0D00:01;.z.p];
  W:N&WATCH; p:select from p where uav<=W;
  `type`events`classes!(`planted;flip `uav`kind`start`end!(p`uav;p`kind;toMs p`start;toMs p`end);
    `A`B`C airClass 1+til W)}

EVERY:`timespan$1000000*`long$CFG`every_ms
/ passes on a fixed schedule (every_ms apart on average, as the DuckDB lane's), not every_ms after the
/ timer tick that ran the last one, which would drift by up to a tick each pass
.z.ts:{
  now:.z.p;
  if[(null LASTA) or now>=LASTA+EVERY;
    LASTA::$[(null LASTA) or now>LASTA+2*EVERY; now; LASTA+EVERY]; prune[];
    r:@[run;::;{`type`lane`error!(`analytics;`kdb;x)}];
    @[neg RDBH;(`relay;.j.j r);{}];
    @[neg RDBH;(`relayPlanted;.j.j @[planted60;::;{`type`error!(`planted;x)}]);{}]];
 }

TPH:hopen `$"::",string TPP
RDBH:hopen `$"::",string RDBP
TPH(".u.sub";`telem;`rte);
\t 100
-1"kdb+ lane: real-time engine on ",string[system"p"],", subscribed to tickerplant ",string[TPP],", ",string[system"s"]," secondary thread(s)";
