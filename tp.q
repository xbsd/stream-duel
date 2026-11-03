/ tp.q: minimal tickerplant (Stream Duel)
/ q tp.q -p 5110 [-log 1] [-maxq 256]
/ Stamps each batch with time of day, publishes it to every subscriber (the kdb+ RDB and the DuckDB
/ bridge), and with -log 1 appends every batch to telem_<date>.log (replay with -11!).
/ A subscriber that has more than -maxq MB waiting in its outbound queue is skipped for that batch,
/ and its dropped rows are counted: a slow subscriber can never exhaust the tickerplant's memory or
/ slow down the others. Subscribers name their lane: .u.sub[`telem;`kdb] or .u.sub[`telem;`duckdb].
/ .u.subw[`telem;`rte;w] subscribes to drones 1..w only (as kdb+tick's subscription to a sym list):
/ the real-time engine watches 1,024 drones, so it no longer costs the tickerplant a full copy.
\l schema.q
o:.Q.opt .z.x
LOG:$[`log in key o;1~"J"$first o`log;0b]
MAXQ:1048576*$[`maxq in key o;"J"$first o`maxq;256]
subs:`int$()
LANE:(`int$())!`symbol$()
WMAX:(`int$())!`long$()                 / per subscriber: highest drone id it receives (null: all)
DROPS:(`symbol$())!`long$()
TOTAL:0
.u.sub:{[t;s] subs::distinct subs,.z.w; LANE[.z.w]:$[null s;`subscriber;s]; if[not LANE[.z.w] in key DROPS; DROPS[LANE .z.w]:0]; (t;value t)}
.u.subw:{[t;s;w] r:.u.sub[t;s]; WMAX[.z.w]:w; r}
/ d _ h removes key h (h _ d would drop the first h entries: every lane name, so drops went uncounted)
.z.pc:{subs::subs except x; LANE::LANE _ x; WMAX::WMAX _ x}
.u.drops:{DROPS}
queued:{[h] w:.z.W; sum each w h}
if[LOG; LF:`$":telem_",string[.z.D],".log"; if[not ()~key LF; hdel LF]; .[LF;();:;()]; L:hopen LF]
.u.upd:{[t;x]
  x:(enlist(count first x)#"n"$.z.P),x;
  if[count subs;
    ok:subs where MAXQ>queued subs;
    if[count late:subs except ok; DROPS[LANE late]+:count first x];
    full:ok where null WMAX ok; part:ok except full;
    if[count full; -25!(full;(`upd;t;x))];
    {[t;x;h;w] if[count i:where (x 2)<=w; neg[h](`upd;t;x@\:i)]}[t;x]'[part;WMAX part]];
  if[LOG; L enlist(`upd;t;x)];
  TOTAL::TOTAL+count first x;
 }
-1"tickerplant on ",string[system"p"],$[LOG;", logging to ",string LF;", no log"],", subscriber queue limit ",string[MAXQ div 1048576]," MB";
