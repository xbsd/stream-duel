/ fh.q: synthetic drone feed handler
/ q fh.q -p 5020 -shard 0 -of 1 -tp 5010
/ Owns the drones where id mod <of> = <shard>. Every 10 ms it generates every
/ sample due since the last tick and publishes them to the tickerplant.
\l gen.q
o:.Q.opt .z.x
arg:{[k;d] $[k in key o;first o k;d]}
SHARD:"J"$arg[`shard;"0"]
OF:"J"$arg[`of;"1"]
TPH:hopen `$"::",arg[`tp;"5010"]
ALERTP:0.006
N:0; HZ:200; STEP:5000000; ids:`long$(); P:(); KLAST:0; CH:1000000
ALC:(`long$())!()
nowNs:{946684800000000000+`long$.z.p}

setFleet:{[n;hz]
  ids::i where SHARD=(i:til n) mod OF;
  P::{h01 h2[ids;x]} each 1+til 8;
  N::n; HZ::hz; STEP::1000000000 div hz;
  ALC::(`long$())!();
  CH::max 1,1000000 div max 1,count ids;
  KLAST::nowNs[] div STEP;
  -1"fleet ",string[n]," drones at ",string[hz]," Hz, this shard owns ",string count ids;
 }

alertVec:{[e]
  if[not e in key ALC; @[`ALC;e;:;ALERTP>h01 h2[(ids+1540483477) mod M32;e]]];
  if[4<count ALC; ALC::(-2)#ALC];
  ALC e}

alertRows:{[ts;ix]
  ep:`long$floor ts%8; r:(count ix)#0b; u:distinct ep; i:0;
  do[count u; w:where ep=u i; r[w]:(alertVec u i) ix w; i+:1];
  r}

emit:{[ks]
  m:count ks; n:count ids;
  ix:(m*n)#til n;
  kk:ks where m#n;
  ts:1e-9*(kk*STEP) mod 1024000000000;
  p:P[;ix];
  v:sig[ts;p;alertRows[ts;ix]];
  st:`timestamp$(kk*STEP)-946684800000000000;
  neg[TPH](".u.upd";`telem;(st;`int$1+ids ix;`real$120+38*v 1;`real$18+7*v 2;`real$7200+1500*v 3;`real$2.4*v 0));
 }

onTimer:{
  if[0=count ids; :()];
  k1:nowNs[] div STEP;
  if[k1<=KLAST; :()];
  k0:max(KLAST+1;k1-HZ div 2);
  KLAST::k1;
  ks:k0+til 1+k1-k0;
  emit each (CH*til ceiling (count ks)%CH)_ks;
  TPH"1";
 }

.z.ts:{onTimer[]}
\t 10
-1"feed handler shard ",string[SHARD]," of ",string[OF],", waiting for a fleet size";
