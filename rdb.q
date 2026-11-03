/ rdb.q: real-time database plus the websocket the browser talks to
/ q rdb.q -p 5011 -tp 5010 -fh 5020 -shards 1 -maxrows 60000000 -drones 1000 -hz 200
/ Records everything the tickerplant publishes. Keeps the newest -maxrows rows
/ in memory (trims to two thirds when it passes that) and counts every row.
\l schema.q
o:.Q.opt .z.x
arg:{[k;d] $[k in key o;first o k;d]}
TPP:"J"$arg[`tp;"5010"]
FH0:"J"$arg[`fh;"5020"]
SHARDS:"J"$arg[`shards;"1"]
MAXROWS:"J"$arg[`maxrows;"60000000"]
KEEP:(2*MAXROWS) div 3
N:"J"$arg[`drones;"1000"]  / not -n: q reserves that flag
HZ:"J"$arg[`hz;"200"]
TOTAL:0; LASTT:0; LAST:.z.p; RATE:0f; WS:`int$()

upd:{[t;x] t insert x; TOTAL::TOTAL+count first x;}

FHS:{hopen `$"::",string x} each FH0+til SHARDS
setFleet:{[n;hz] N::n; HZ::hz; (neg FHS)@\:(`setFleet;n;hz); RATE::0f;}

tap:{select time:string time,uav,alt,ias,rpm,imuz from (neg min 8,count telem)#telem}
stats:{`type`n`hz`shards`demand`rate`total`held`mem`ncols`maxrows`tap!(`stats;N;HZ;SHARDS;N*HZ;RATE;TOTAL;count telem;(.Q.w[])`used;count cols telem;MAXROWS;tap[])}

/ newest n rows (at most 500), newest first, for the live table page
lastRows:{[n] r:reverse (neg (500&n)&count telem)#telem;
  `type`total`held`rows!(`last;TOTAL;count telem;update time:string time,stime:string stime from r)}

/ change the row limit at runtime (the page's "Keep newest" menu); trims straight away if already past it
setKeep:{[n] MAXROWS::n; KEEP::(2*n) div 3; if[MAXROWS<count telem; telem::(neg KEEP)#telem; .Q.gc[]];}

hover:{[id]
  n:count telem; s:max 0,n-3*max N,1000;
  j:s+where id=telem[`uav] s+til n-s;
  if[0=count j; :`type`id`row!(`hover;id;::)];
  r:telem last j; r[`time]:string r`time; r[`stime]:string r`stime;
  `type`id`row!(`hover;id;r)}

saveHdb:{
  t0:.z.p; n:count telem;
  .Q.dpft[`:hdb;.z.D;`uav;`telem];
  `type`rows`path`ms!(`saved;n;"hdb/",string[.z.D],"/telem";`long$1e-6*`long$.z.p-t0)}

/ empty the RDB and restart the rows-recorded counter; .Q.gc hands the memory back to the OS
clearRdb:{
  t0:.z.p; n:count telem;
  delete from `telem;
  TOTAL::0; LASTT::0;
  .Q.gc[];
  `type`rows`ms!(`cleared;n;`long$1e-6*`long$.z.p-t0)}

/ stop the whole kit (the page's "Shut down q" button): tell the open pages, stop the feed handlers
/ and the tickerplant, remove logs/pids so a later stop.sh can't hit reused process ids, then exit.
/ The calls to the other processes are sync, so each one gets "exit 0" before this RDB goes.
/ The RDB itself exits 200 ms later, once the note to the pages has gone out.
shutdown:{
  (neg WS)@\:.j.j enlist[`type]!enlist`shutdown;
  {@[x;"exit 0";{}]} each FHS,TPH;
  @[hdel;`:logs/pids;{}];
  -1"shut down from the page";
  .z.ts:{exit 0}; system"t 200";}

.z.wo:{WS::distinct WS,x}
.z.wc:{WS::WS except x}
.z.ws:{
  d:.j.k x; c:`$d`cmd;
  $[c~`fleet; setFleet[`long$d`n;`long$d`hz];
    c~`hover; neg[.z.w] .j.j hover `long$d`id;
    c~`save; neg[.z.w] .j.j saveHdb[];
    c~`clear; (neg WS)@\:.j.j clearRdb[];  / tell every open page, so all their charts reset
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
  if[count WS; m:.j.j stats[]; (neg WS)@\:m];
 }

TPH:hopen `$"::",string TPP
TPH(".u.sub";`telem;`);
setFleet[N;HZ];
\t 250
-1"rdb on ",string[system"p"],", subscribed to tickerplant ",string[TPP],", ",string[SHARDS]," feed handler(s)";
