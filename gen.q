/ gen.q: deterministic drone telemetry
/ The hash and signal functions are bit-for-bit the same as the GPU shader
/ in telemetry-wall.html, so the browser draws exactly what q records.
/ q has no unsigned 32-bit ints or xor, so the hash uses only multiply,
/ rotate and add mod 2^32, with the multiply split into 16-bit halves.

M32:4294967296
p2:prds 1,32#2
mul32:{[x;k] lo:k mod 65536; hi:k div 65536; ((x*lo)+65536*(x*hi) mod 65536) mod M32}
rotl:{[x;r] ((x*p2 r) mod M32)+x div p2 32-r}
hu:{x:mul32[x;2654435761]; x:(x+rotl[x;15]) mod M32; x:mul32[x;2246822519]; x:(x+rotl[x;13]) mod M32; x:mul32[x;3266489917]; (x+rotl[x;16]) mod M32}
h01:{(hu[x] div 256)%16777216}
h2:{[a;b] hu (hu[(a+374761393) mod M32]+mul32[b;668265263]) mod M32}

TAU:2*acos -1
frac:{x-floor x}
gs:{[x;m;w] exp neg z*z:(x-m)%w}
sw:{[ts;f;ph] sin TAU*frac(ts*f)+ph}

/ ts: sample time in seconds, wrapped to [0,1024)
/ p: 8 per-drone parameter vectors, al: alert flag per row
/ split into one function per channel to stay well under q's constants limit
sigImu:{[ts;p;al]
  ph:frac(ts*0.9+0.9*p 0)+p 1;
  v:(0.10*gs[ph;0.12;0.025])+(-0.12*gs[ph;0.21;0.008])+(0.95*gs[ph;0.23;0.009])+(-0.28*gs[ph;0.255;0.010])+0.22*gs[ph;0.42;0.05];
  v+:(0.05*sw[ts;23+7*p 2;0])+(0.04*sw[ts;41+9*p 3;p 4])+0.03*sw[ts;0.3;p 2];
  if[count w:where al; v[w]+:(0.30*sw[ts w;17+5*p[5] w;p[6] w])+0.20*sw[ts w;7;0]];
  v-0.08}
sigAlt:{[ts;p] (0.55*sw[ts;1%18+14*p 0;p 1])+(0.20*sw[ts;0.13+0.1*p 2;p 3])+(0.12*sw[ts;0.71+0.3*p 4;p 5])+0.05*sw[ts;3.1+p 6;p 7]}
sigIas:{[ts;p] (0.45*sw[ts;1%6+6*p 2;p 3])+(0.22*sw[ts;0.37+0.2*p 5;p 6])+(0.12*sw[ts;1.9+0.8*p 7;p 0])+0.06*sw[ts;7.3+2*p 1;p 4]}
sigRpm:{[ts;p] (0.35*sw[ts;0.6+0.5*p 1;0])+(0.25*sw[ts;1.7+0.6*p 6;p 2])+(0.18*sw[ts;9+4*p 3;0])+0.06*sw[ts;31+6*p 5;p 7]}
/ returns normalized (imu;alt;ias;rpm)
sig:{[ts;p;al] (sigImu[ts;p;al];sigAlt[ts;p];sigIas[ts;p];sigRpm[ts;p])}

/ ---------------------------------------------------------------------------------------------
/ Stream Duel additions (DESIGN.md): airframe classes, planted events and coordinated groups.
/ Everything is a deterministic hash of (drone, slot), so the feed handlers that inject the events
/ and planted[], which lists them for the page's scoring, always agree.

WATCH:1024                      / drones 1..WATCH carry planted events and are analysed
SLOT:16f                        / seconds per slot; 1024 s of wrapped time = 64 slots
EVT:`dive`payload`hover`jink`jam
DUR:3 1 5 3 2f                  / seconds each event lasts (payload: from release)
PEVT:0.25                       / chance a watched drone has an event in a slot
PGRP:0.2                        / chance a group of six flies coordinated in a slot
CLASSHZ:11 17 23f               / rotor frequency of airframe classes A, B, C
LADEN:0.92                      / rotor frequency factor while carrying a payload

airClass:{[uav] (hu `long$uav) mod 3}                          / 0 1 2 = A B C
slotOf:{[ts] `long$floor ts%SLOT}
/ per (drone; slot): event flag, type index, start offset in the slot (2..12 s)
evOn:{[uav;s] PEVT>h01 h2[(uav+7919) mod M32;s]}
evType:{[uav;s] (`long$floor 5*h01 h2[(uav+101) mod M32;s]) mod 5}
evStart:{[uav;s] 2+10*h01 h2[(uav+202) mod M32;s]}
grpOf:{[uav] (uav-1) div 6}
grpOn:{[g;s] PGRP>h01 h2[(g+404) mod M32;s]}
/ the group's 8 shared parameters: keyed apart from every drone's own (h2[id;1..8] in fh.q), so no
/ drone flies a group's waveform by accident (g+500 once collided with drone id g+500)
grpP:{[g] {h01 h2[(x+1000003) mod M32;64+y]}[g] each 1+til 8}

/ sigDuel: like sig, plus classes, events and groups. ts: wrapped seconds; p: 8 parameter vectors;
/ al: telemetry-kit's alert flags; uav: drone ids (1-based). Returns normalized (imu;alt;ias;rpm).
sigDuel:{[ts;p;al;uav]
  imu:sigImu[ts;p;al]; alt:sigAlt[ts;p]; ias:sigIas[ts;p];
  s:slotOf ts; o:ts-SLOT*s;
  w:where uav<=WATCH;
  ev:(count ts)#0b; ty:(count ts)#0; tau:(count ts)#0f;
  if[count w;
    u:uav w; sw0:s w;
    on:evOn[u;sw0]; t0:evStart[u;sw0]; ty[w]:evType[u;sw0];
    tau[w]:o[w]-t0; ev[w]:on;
    / coordinated groups: alt and ias follow the group's waveform for the whole slot
    g:grpOf u; gi:where grpOn[g;sw0];
    if[count gi; pg:grpP g gi; alt[w gi]:sigAlt[ts w gi;pg]; ias[w gi]:sigIas[ts w gi;pg]]];
  / rotor: the class frequency dominates the 5..40 Hz band; laden (payload before release) is 8% low
  laden:ev and (ty=1) and tau<0;
  fr:CLASSHZ[airClass uav]*1-(1-LADEN)*laden;
  rpm:(0.35*sw[ts;0.6+0.5*p 1;0])+(0.25*sw[ts;1.7+0.6*p 6;p 2])+(0.40*sw[ts;fr;0])+0.06*sw[ts;31+6*p 5;p 7];
  act:ev and (tau>=0) and tau<DUR ty;
  if[count i:where act and ty=0;                               / dive and pull up
    r:sin (acos -1)*tau[i]%3; alt[i]-:1.2*r; ias[i]+:1.15*r];
  if[count i:where act and ty=1;                               / payload release: jolt and ring-down, rotor spins up
    imu[i]+:(1.6*exp neg (tau[i]%0.06) xexp 2)+0.9*(exp neg tau[i]%0.35)*sin TAU*2.5*tau i;
    rpm[i]+:0.25*1-exp neg tau[i]%0.2];
  if[count i:where act and ty=2;                               / hover and stare
    m:1&2*min(tau[i];5-tau[i]); ias[i]:(ias[i]*1-m)+m*-2.4; alt[i]:alt[i]*1-m];
  if[count i:where act and ty=3;                               / evasive jinking
    e:sin (acos -1)*tau[i]%3; imu[i]+:0.9*e*sin TAU*3*tau i; ias[i]+:0.3*e*sin TAU*1.5*tau i];
  if[count i:where act and ty=4;                               / jamming: broadband noise everywhere
    k:`long$floor 1000*ts i; ui:uav i;
    nz:{[ui;k;c] -0.5+h01 h2[(ui+303+97*c) mod M32;k mod M32]};
    imu[i]+:1.6*nz[ui;k;0]; alt[i]+:0.8*nz[ui;k;1]; ias[i]+:1.6*nz[ui;k;2]; rpm[i]+:1.6*nz[ui;k;3]];
  (imu;alt;ias;rpm)}

/ planted[t0;t1]: events overlapping [t0;t1] (timestamps), for scoring only.
/ Returns a table: uav, kind (dive payload hover jink jam swarm laden), start, end (timestamps).
UNIX:946684800000000000
planted:{[w0;w1]                                             / (not t0;t1: those are columns below)
  a:floor 1e-9*UNIX+`long$w0; b:floor 1e-9*UNIX+`long$w1;     / unix seconds
  S:distinct (`long$floor a%SLOT)+til 1+`long$floor[b%SLOT]-floor a%SLOT;
  u:1+til WATCH;
  tsOf:{[x] `timestamp$(`long$1e9*x)-UNIX};
  ev:raze {[u;S]
    s:S mod 64; on:evOn[u;s]; uu:u where on; if[0=count uu; :()];
    st:(SLOT*S)+evStart[uu;s]; ty:evType[uu;s];
    e:([] uav:`int$uu; kind:EVT ty; t0:st; t1:st+DUR ty);
    p:select from e where kind=`payload;
    e,([] uav:p`uav; kind:(count p)#`laden; t0:SLOT*S; t1:p`t0)}[u] each S;
  grp:raze {[S]
    s:S mod 64; g:til ceiling WATCH%6; gg:g where grpOn[g;s]; if[0=count gg; :()];
    m:raze 1+(6*gg)+\:til 6; m:m where m<=WATCH;
    ([] uav:`int$m; kind:`swarm; t0:SLOT*S; t1:SLOT*S+1)} each S;
  r:$[count ev;ev;([] uav:`int$();kind:`$();t0:`float$();t1:`float$())],$[count grp;grp;()];
  r:select from r where t1>=a, t0<=b+1;
  update start:tsOf t0, end:tsOf t1 from r}
