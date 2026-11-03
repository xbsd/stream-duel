/ tp.q: minimal tickerplant
/ q tp.q -p 5010 [-log 1]
/ Stamps each batch with time of day, publishes to subscribers,
/ and with -log 1 appends every batch to telem_<date>.log (replay with -11!).
\l schema.q
o:.Q.opt .z.x
LOG:$[`log in key o;"1"~first o`log;0b]
subs:`int$()
TOTAL:0
.u.sub:{[t;s] subs::distinct subs,.z.w; (t;value t)}
.z.pc:{subs::subs except x}
if[LOG; LF:`$":telem_",string[.z.D],".log"; if[not ()~key LF; hdel LF]; .[LF;();:;()]; L:hopen LF]
.u.upd:{[t;x]
  x:(enlist(count first x)#"n"$.z.P),x;
  if[count subs; -25!(subs;(`upd;t;x))];
  if[LOG; L enlist(`upd;t;x)];
  TOTAL::TOTAL+count first x;
 }
-1"tickerplant on ",string[system"p"],$[LOG;", logging to ",string LF;", no log"];
