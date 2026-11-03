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
