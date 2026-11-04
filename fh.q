/ fh.q: synthetic drone feed handler
/ q fh.q -p 5120 -shard 0 -of 1 -tp 5110   (Stream Duel ports, DESIGN.md)
/ Owns the drones where id mod <of> = <shard>. Every 10 ms it sends every 20 ms block that has
/ ended since the last tick: per drone, one telem row (50 Hz) and two rotor rows (100 Hz), built
/ by gen.q's blockRows from the drone's 200 Hz sensor samples.
\l schema.q
\l gen.q
o:.Q.opt .z.x
arg:{[k;d] $[k in key o;first o k;d]}
SHARD:"J"$arg[`shard;"0"]
OF:"J"$arg[`of;"1"]
TPH:hopen `$"::",arg[`tp;"5110"]
ALERTP:0.006
N:0; ids:`long$(); P:(); KLAST:0; CH:1000000
ALC:(`long$())!()
nowNs:{946684800000000000+`long$.z.p}

setFleet:{[n]
  ids::i where SHARD=(i:til n) mod OF;
  P::{h01 h2[ids;x]} each 1+til 8;
  N::n;
  ALC::(`long$())!();
  CH::max 1,1000000 div max 1,(1+TB div RB)*count ids;    / blocks per message: about 1M rows
  KLAST::(nowNs[] div BLOCKNS)-1;
  -1"fleet ",string[n]," drones (telemetry ",string[TELEHZ]," Hz, rotor ",string[ROTORHZ]," Hz), this shard owns ",string count ids;
 }

alertVec:{[e]
  if[not e in key ALC; @[`ALC;e;:;ALERTP>h01 h2[(ids+1540483477) mod M32;e]]];
  if[4<count ALC; ALC::(-2)#ALC];
  ALC e}

alertRows:{[ts;ix]
  ep:`long$floor ts%8; r:(count ix)#0b; u:distinct ep; i:0;
  do[count u; w:where ep=u i; r[w]:(alertVec u i) ix w; i+:1];
  r}

emit:{[bs]
  r:blockRows[bs;ids;P;alertRows];
  neg[TPH](".u.upd";`telem;r 0);
  neg[TPH](".u.upd";`rotor;r 1);
 }

onTimer:{
  if[0=count ids; :()];
  b1:(nowNs[] div BLOCKNS)-1;                    / the newest block that has ended
  if[b1<=KLAST; :()];
  b0:max(KLAST+1;b1-TELEHZ div 2);               / more than 0.5 s behind: skip the oldest blocks
  KLAST::b1;
  bs:b0+til 1+b1-b0;
  emit each (CH*til ceiling (count bs)%CH)_bs;
  TPH"1";
 }

.z.ts:{onTimer[]}
\t 10
-1"feed handler shard ",string[SHARD]," of ",string[OF],", waiting for a fleet size";
