/ rdb.q: the kdb+ lane's RDB, and the websocket every page talks to (DESIGN.md).
/ q rdb.q -p 5111 -tp 5110 -fh 5120 -shards 1 -maxrows 60000000 -drones 1024
/ Records everything the tickerplant publishes into telem and rotor (schema.q), measures each
/ batch's lag (tickerplant stamp to stored), and serves the pages: stats every 250 ms, the newest
/ rows, a drone's latest rows, and the analytics results and planted events of the real-time engine
/ (rte.q), which runs analytics.q in its own process as in kdb+tick, so ingest here never waits.
\l schema.q
\l gen.q                               / the two rates (TELEHZ, ROTORHZ)
\P 15                                  / JSON floats keep 15 digits (q's default is 7)
o:.Q.opt .z.x
arg:{[k;d] $[k in key o;first o k;d]}
TPP:"J"$arg[`tp;"5110"]
FH0:"J"$arg[`fh;"5120"]
SHARDS:"J"$arg[`shards;"1"]
MAXROWS:"J"$arg[`maxrows;"60000000"]
N:"J"$arg[`drones;"1024"]              / not -n: q reserves that flag
MODE:`$(.j.k raze read0`:config.json)`mode
TABS:`telem`rotor
MC:count each METRICS                  / measured values per row: telem 3, rotor 1
VPD:sum MC*TELEHZ,ROTORHZ              / measured values per drone per second (250)
TOTAL:0; VTOTAL:0; LASTT:0; LASTV:0; LAST:.z.p; RATE:0f; VRATE:0f; WS:`int$()
LAGT:`long$(); LAGV:`float$(); LAGN:`long$()   / batch arrival (ms), lag (ms), rows: last 5 s

nowMs:{`long$1e-6*`long$.z.p}
held:{sum count each value each TABS}
upd:{[t;x]
  t insert x; n:count first x; TOTAL+:n; VTOTAL+:n*MC t;
  LAGT,:nowMs[]; LAGV,:1e-6*`long$("n"$.z.P)-first x 0; LAGN,:n;
 }

FHS:{hopen `$"::",string x} each FH0+til SHARDS
RTE:0Ni                                 / the real-time engine's handle, set by its first relay
toRte:{[m] if[not null RTE; @[neg RTE;m;{RTE::0Ni}]]}
setFleet:{[n] N::n; (neg FHS)@\:(`setFleet;n); toRte (`setFleet;n); RATE::0f; VRATE::0f;}
PLANTED:""                             / the latest planted-events JSON, for new pages
relay:{[s] RTE::.z.w; if[count WS; (neg WS)@\:s]}             / RTE analytics (JSON), to the pages
relayPlanted:{[s] RTE::.z.w; PLANTED::s; if[count WS; (neg WS)@\:s]}

/ row-weighted lag percentiles over the last 5 s of batches
lagStats:{
  k:where LAGT>nowMs[]-5000; LAGT::LAGT k; LAGV::LAGV k; LAGN::LAGN k;
  if[0=count k; :`p50`p99!0n 0n];
  s:iasc LAGV; c:sums LAGN s; tot:last c;
  `p50`p99!{[v;c;tot;q] v first where c>=q*tot}[LAGV s;c;tot] each 0.5 0.99}
/ the newest rows of both tables, oldest first: a value a table doesn't carry is null
tap:{
  a:select time,uav,alt,ias,imuz,rpm:0Ne from (neg 4&count telem)#telem;
  b:select time,uav,alt:0Ne,ias:0Ne,imuz:0Ne,rpm from (neg 4&count rotor)#rotor;
  update time:string time from `time xasc a,b}
dropped:{d:@[TPH;".u.drops[]";{()!()}]; $[`kdb in key d;d`kdb;0]}
stats:{`type`lane`n`mode`shards`telem_hz`rotor_hz`demand`vdemand`rate`vrate`total`vtotal`held`tables`mem`lag`dropped`maxrows`tap!(
  `stats;`kdb;N;MODE;SHARDS;TELEHZ;ROTORHZ;N*TELEHZ+ROTORHZ;N*VPD;RATE;VRATE;TOTAL;VTOTAL;held[];
  TABS!count each value each TABS;(.Q.w[])`used;lagStats[];dropped[];MAXROWS;tap[])}

strs:{update time:string time,stime:string stime from x}
/ the newest n rows (at most 500) of each table, newest first, for the live data page
lastRows:{[n] f:{[n;t] strs reverse (neg (500&n)&count v)#v:value t}[n];
  `type`lane`total`held`telem`rotor!(`last;`kdb;TOTAL;held[];f`telem;f`rotor)}
/ a drone's latest row in each table, for the wall's hover readout
hover:{[id]
  f:{[id;t] n:count v:value t; s:max 0,n-6*max N,1000; j:s+where id=v[`uav] s+til n-s;
    $[count j; first strs enlist v last j; ::]}[`int$id];
  `type`id`telem`rotor!(`hover;id;f`telem;f`rotor)}
/ save both tables to hdb/<date>/, sorted and `p# on uav (the wall's Save button)
saveHdb:{
  t0:.z.p; n:held[];
  .Q.dpft[`:hdb;.z.D;`uav;] each TABS;
  `type`rows`path`ms!(`saved;n;"hdb/",string .z.D;`long$1e-6*`long$.z.p-t0)}
/ past MAXROWS, each table keeps its newest two thirds
trimRows:{{[t] t set (neg (2*count v) div 3)#v:value t} each TABS; .Q.gc[];}
setKeep:{[n] MAXROWS::n; if[MAXROWS<held[]; trimRows[]];}
clearRdb:{
  t0:.z.p; n:held[]; {delete from x} each TABS; TOTAL::0; VTOTAL::0; LASTT::0; LASTV::0; .Q.gc[];
  `type`lane`rows`ms!(`cleared;`kdb;n;`long$1e-6*`long$.z.p-t0)}
setMode:{[m] if[m in `tss`dtw; MODE::m; toRte (`setMode;m)]; `type`lane`mode!(`mode;`kdb;MODE)}

/ stop the kdb+ side (the pages' "Shut down" without the launcher; the bridge stops itself)
/ Sync calls, so each process has exited before this one does: an async "exit 0" to the real-time
/ engine was lost when the RDB exited right after, leaving the engine running.
shutdown:{
  (neg WS)@\:.j.j `type`lane!(`shutdown;`kdb);
  {@[x;"exit 0";{}]} each FHS,TPH; if[not null RTE; @[RTE;"exit 0";{}]];
  @[hdel;`:logs/pids;{}];
  -1"shut down from the page";
  .z.ts:{exit 0}; system"t 200";}

send:{[m] if[count WS; (neg WS)@\:.j.j m]}
.z.wo:{WS::distinct WS,x; if[count PLANTED; neg[x] PLANTED]}
.z.wc:{WS::WS except x}
.z.ws:{
  d:.j.k x; c:`$d`cmd;
  $[c~`fleet; setFleet `long$d`n;
    c~`mode; send setMode `$d`mode;
    c~`clear; send clearRdb[];
    c~`keep; setKeep `long$d`n;
    c~`last; neg[.z.w] .j.j lastRows `long$d`n;
    c~`hover; neg[.z.w] .j.j hover `long$d`id;
    c~`save; neg[.z.w] .j.j saveHdb[];
    c~`shutdown; shutdown[];
    ::];
 }

.z.ts:{
  now:.z.p; dt:1e-9*`long$now-LAST; LAST::now;
  RATE::(0.6*RATE)+0.4*(TOTAL-LASTT)%dt|1e-3; LASTT::TOTAL;
  VRATE::(0.6*VRATE)+0.4*(VTOTAL-LASTV)%dt|1e-3; LASTV::VTOTAL;
  if[MAXROWS<held[]; trimRows[]];
  send stats[];
 }

TPH:hopen `$"::",string TPP
TPH(".u.sub";`telem;`kdb);
setFleet N;
\t 250
-1"kdb+ lane: rdb on ",string[system"p"],", subscribed to tickerplant ",string[TPP],", ",string[SHARDS]," feed handler(s), ",string[system"s"]," secondary thread(s)";
