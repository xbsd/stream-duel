/ tests/test_gen.q: planted events, classes and groups in gen.q, against DESIGN.md.
/ q tests/test_gen.q   (exits 0 when every check passes)
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
/ rotor: dominant 5..40 Hz frequency is the class frequency (drones that are not laden in the slot)
ok:(1+til n) except busy                                        / rotor untouched by events
win:raze {[d] 512#(v[3] row d)} each ok
pk:fftpeak[win;512;`float$HZ;5f;40f]
check["rotor peak = airframe class frequency (11/17/23 Hz) within 0.3 Hz"; all 0.3>abs pk-CLASSHZ airClass ok]
check["all three airframe classes occur"; 3=count distinct airClass ok]
check["planted lists only watched drones and known kinds"; all (pl[`uav]<=WATCH),pl[`kind] in EVT,`swarm`laden]
-1 $[fails;string[fails]," check(s) failed";"all generator checks passed"];
exit 0<fails
