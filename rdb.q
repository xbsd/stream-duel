/ rdb.q: the kdb+ lane of Stream Duel (DESIGN.md).
/ q rdb.q -p 5111 -tp 5110 -fh 5120 -shards 1 -maxrows 60000000 -drones 1024 -hz 200 -s 8
/ Records everything the tickerplant publishes into telem, measures each batch's lag (tickerplant
/ stamp to stored), and serves the page over a websocket: stats every 250 ms, planted events every
/ second, and the analytics results of the real-time engine (rte.q), which runs analytics.q in its
/ own process as in kdb+tick, so ingest here never waits for it. analytics[] still works on demand.
\l schema.q
\l gen.q                               / planted[] and airClass for the page's scoring only
\l analytics.q
o:.Q.opt .z.x
arg:{[k;d] $[k in key o;first o k;d]}
TPP:"J"$arg[`tp;"5110"]
FH0:"J"$arg[`fh;"5120"]
SHARDS:"J"$arg[`shards;"1"]
MAXROWS:"J"$arg[`maxrows;"60000000"]
KEEP:(2*MAXROWS) div 3
N:"J"$arg[`drones;"1024"]              / not -n: q reserves that flag
HZ:"J"$arg[`hz;"200"]
TOTAL:0; LASTT:0; LAST:.z.p; RATE:0f; WS:`int$()
LAGT:`long$(); LAGV:`float$(); LAGN:`long$()   / batch arrival (ms), lag (ms), rows: last 5 s
LASTA:0Np; LASTP:0Np; BUSY:0b

nowMs:{`long$1e-6*`long$.z.p}
upd:{[t;x]
  t insert x; n:count first x; TOTAL::TOTAL+n;
  LAGT,:nowMs[]; LAGV,:1e-6*`long$("n"$.z.P)-first x 0; LAGN,:n;
 }

FHS:{hopen `$"::",string x} each FH0+til SHARDS
RTE:0Ni                                 / the real-time engine's handle, set by its first relay
toRte:{[m] if[not null RTE; @[neg RTE;m;{RTE::0Ni}]]}
setFleet:{[n;hz] N::n; HZ::hz; (neg FHS)@\:(`setFleet;n;hz); toRte (`setFleet;n;hz); RATE::0f;}
relay:{[r] RTE::.z.w; send r}            / analytics from the real-time engine, to the page

/ row-weighted lag percentiles over the last 5 s of batches
lagStats:{
  k:where LAGT>nowMs[]-5000; LAGT::LAGT k; LAGV::LAGV k; LAGN::LAGN k;
  if[0=count k; :`p50`p99!0n 0n];
  s:iasc LAGV; c:sums LAGN s; tot:last c;
  `p50`p99!{[v;c;tot;q] v first where c>=q*tot}[LAGV s;c;tot] each 0.5 0.99}
tap:{select time:string time,uav,alt,ias,rpm,imuz from (neg min 8,count telem)#telem}
dropped:{d:@[TPH;".u.drops[]";{()!()}]; $[`kdb in key d;d`kdb;0]}
stats:{`type`lane`n`hz`demand`rate`total`held`mem`lag`dropped`maxrows`tap!(
  `stats;`kdb;N;HZ;N*HZ;RATE;TOTAL;count telem;(.Q.w[])`used;lagStats[];dropped[];MAXROWS;tap[])}

/ the newest window's rows (by tickerplant stamp, which only grows), then the analytics
tailRows:{[secs]
  if[0=count telem; :0#telem];
  t0:last[telem`time]-`timespan$`long$1e9*secs;
  i0:(telem`time) binr t0;
  (i0;count[telem]-i0) sublist telem}
analytics:{
  W:N&WATCH;
  r:analyse[tailRows CFG[`window_s]+0.5;W;MODE;HZ];
  r[`watch]:W; r}

/ planted events of the last 60 s and every watched drone's airframe class, for the page's scoring
planted60:{
  p:planted[.z.p-0D00:01;.z.p];
  W:N&WATCH; p:select from p where uav<=W;
  `type`events`classes!(`planted;flip `uav`kind`start`end!(p`uav;p`kind;toMs p`start;toMs p`end);
    `A`B`C airClass 1+til W)}

lastRows:{[n] r:reverse (neg (500&n)&count telem)#telem;
  `type`lane`total`held`rows!(`last;`kdb;TOTAL;count telem;update time:string time,stime:string stime from r)}
setKeep:{[n] MAXROWS::n; KEEP::(2*n) div 3; if[MAXROWS<count telem; telem::(neg KEEP)#telem; .Q.gc[]];}
clearRdb:{
  t0:.z.p; n:count telem; delete from `telem; TOTAL::0; LASTT::0; .Q.gc[];
  `type`lane`rows`ms!(`cleared;`kdb;n;`long$1e-6*`long$.z.p-t0)}
setMode:{[m] if[m in `tss`dtw; MODE::m; toRte (`setMode;m)]; `type`lane`mode!(`mode;`kdb;MODE)}

/ stop the kdb+ side (the page's "Shut down" button; the bridge stops itself on the same click)
shutdown:{
  (neg WS)@\:.j.j `type`lane!(`shutdown;`kdb);
  {@[x;"exit 0";{}]} each FHS,TPH; if[not null RTE; @[neg RTE;"exit 0";{}]];
  @[hdel;`:logs/pids;{}];
  -1"shut down from the page";
  .z.ts:{exit 0}; system"t 200";}

send:{[m] if[count WS; (neg WS)@\:.j.j m]}
.z.wo:{WS::distinct WS,x; neg[x] .j.j planted60[]}
.z.wc:{WS::WS except x}
.z.ws:{
  d:.j.k x; c:`$d`cmd;
  $[c~`fleet; setFleet[`long$d`n;`long$d`hz];
    c~`mode; send setMode `$d`mode;
    c~`clear; send clearRdb[];
    c~`keep; setKeep `long$d`n;
    c~`last; neg[.z.w] .j.j lastRows `long$d`n;
    c~`shutdown; shutdown[];
    ::];
 }

.z.ts:{
  now:.z.p; dt:1e-9*`long$now-LAST; LAST::now;
  r:(TOTAL-LASTT)%dt|1e-3; LASTT::TOTAL;
  RATE::(0.6*RATE)+0.4*r;
  if[MAXROWS<count telem; telem::(neg KEEP)#telem];
  send stats[];
  if[(null LASTP) or 1000<=1e-6*`long$now-LASTP; LASTP::now; send planted60[]];
 }

TPH:hopen `$"::",string TPP
TPH(".u.sub";`telem;`kdb);
setFleet[N;HZ];
\t 250
-1"kdb+ lane: rdb on ",string[system"p"],", subscribed to tickerplant ",string[TPP],", ",string[SHARDS]," feed handler(s), ",string[system"s"]," secondary thread(s)";
