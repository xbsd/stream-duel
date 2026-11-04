/ tests/test_gen.q: planted events, classes and groups in gen.q, against DESIGN.md.
/ q tests/test_gen.q   (exits 0 when every check passes)
\l schema.q
\l gen.q
fails:0
check:{[name;ok] -1 (("FAIL ";"pass ") ok),name; if[not ok; fails+:1]}
fftpeak:`:lib/kxfft 2:(`fftpeak;5)
HZ:200; n:120                                   / drones 1..120, one 16 s slot at 200 Hz
U0:1762000000 - 1762000000 mod 1024             / a unix second where wrapped time is 0
S0:37                                           / the slot under test
uts:(SLOT*S0)+til[`long$SLOT*HZ]%HZ             / wrapped seconds of each sample
ids:til n; P:{h01 h2[ids;x]} each 1+til 8
/ build rows drone by drone so each drone's samples are contiguous
ts:raze n#enlist uts; ix:raze (count uts)#'ids; uav:1+ix
v:sigDuel[ts;P[;ix];(count ts)#0b;uav]
v2:sigDuel[ts;P[;ix];(count ts)#0b;uav]
check["sigDuel is deterministic"; v~v2]
L:count uts
row:{[d] ((d-1)*L)+til L}                         / rows of drone d (1-based)
tsAt:{[u] `timestamp$(`long$1e9*u)-UNIX}            / unix seconds -> q timestamp (long ns)
pl:planted[tsAt U0+SLOT*S0;tsAt U0+SLOT*(S0+1)-1e-9]
pl:select from pl where uav<=n, t0<U0+SLOT*S0+1, t1>U0+SLOT*S0   / events of slot S0 itself
busy:exec distinct uav from pl where kind in (EVT,`laden)         / drones with any event in the slot
-1"planted in the slot for drones 1..",string[n],": ",.Q.s1 exec count i by kind from pl;
/ dive: compare with the drone's own altitude without events (sigAlt, group waveform aside)
dv:select from pl where kind=`dive, not uav in exec uav from pl where kind=`swarm
if[count dv;
  d:first dv; mid:`long$HZ*((d[`t0]-SLOT*S0) mod SLOT)+1.5;
  r:row d`uav; base:sigAlt[ts r;P[;ix r]];
  check["a dive is 1.2 (normalized) lower at mid-event"; 0.02>abs -1.2-(v[1] r mid)-base mid]];
check["at least one dive was planted in the slot"; 0<count dv]
/ coordinated group: all six members share their altitude
sg:select from pl where kind=`swarm
if[count sg;
  g:(exec uav from sg) except busy; g:g where 1<count each group grpOf g; g:g where (grpOf g)=first grpOf g;
  a:{v[1] row x} each g;
  check["a coordinated group flies one altitude waveform"; (1<count g) and all 1e-12>max each abs a-\:first a]];
/ jamming: noise shows in the sample-to-sample differences of vertical acceleration
jm:select from pl where kind=`jam
if[count jm;
  j:first jm; r:row j`uav; st:`long$HZ*(j[`t0]-SLOT*S0) mod SLOT;
  dj:dev 1_deltas (v[0] r) st+til 2*HZ; dq:dev 1_deltas (v[0] r) til HZ;
  check["jamming makes vertical acceleration noisy"; dj>5*dq]];
/ what the drones send (blockRows): telem at 50 Hz = mean of 4 sensor samples, rotor at 100 Hz
CFG:.j.k raze read0`:config.json
check["config.json's rates are the generator's"; (CFG[`ana_hz]=TELEHZ) and CFG[`rotor;`hz]=ROTORHZ]
b0:`long$TELEHZ*U0+SLOT*S0
r:blockRows[b0+til `long$SLOT*TELEHZ;ids;P;{[ts;ix] (count ts)#0b}]
T:flip `stime`uav`alt`ias`imuz!r 0; R:flip `stime`uav`rpm!r 1
check["one telem row per drone per 20 ms, two rotor rows"; (count[T]=n*SLOT*TELEHZ) and count[R]=n*SLOT*ROTORHZ]
t1:select from T where uav=1; r1:select from R where uav=1
check["telem altitude is the mean of the drone's 4 sensor samples"; 1e-4>max abs t1[`alt]-`real$120+38*avg each 4 cut v[1] row 1]
check["rotor is every second sensor sample"; 1e-3>max abs r1[`rpm]-`real$7200+1500*(v[3] row 1) 2*til count r1]
check["rows are in sample-time order"; (T[`stime]~asc T`stime) and R[`stime]~asc R`stime]
/ rotor: dominant 5..40 Hz frequency over 256 samples at 100 Hz is the class frequency (drones not
/ laden in the slot)
ok:(1+til n) except busy                                        / rotor untouched by events
win:raze {[d] 256#exec rpm from R where uav=d} each ok
pk:fftpeak[`float$win;256;`float$ROTORHZ;5f;40f]
check["rotor peak = airframe class frequency (11/17/23 Hz) within 0.3 Hz"; all 0.3>abs pk-CLASSHZ airClass ok]
check["all three airframe classes occur"; 3=count distinct airClass ok]
/ no drone's own parameters equal a group's (that made drone g+501 fly group g's waveform)
own:{h01 h2[til WATCH;x]} each 1+til 8; gp:grpP til ceiling WATCH%6
check["no drone shares a coordinated group's parameters"; not any (flip own) in flip gp]
check["planted lists only watched drones and known kinds"; all (pl[`uav]<=WATCH),pl[`kind] in EVT,`swarm`laden]
-1 $[fails;string[fails]," check(s) failed";"all generator checks passed"];
exit 0<fails
