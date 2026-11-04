/ tools/fixture.q: writes tests/fixtures/crosscheck.json, the rows and kdb+ results that
/ tests/test_crosscheck.py replays through the DuckDB lane's code (bridge/analytics.py).
/ q tools/fixture.q -s 4
\l schema.q
\l gen.q
\l analytics.q
\P 17                                 / full float precision in the JSON
W:48; S0:21; SECS:5
U0:1762000000 - 1762000000 mod 1024
ids:til W; P:{h01 h2[ids;x]} each 1+til 8
r:blockRows[(`long$TELEHZ*U0+SLOT*S0)+til SECS*TELEHZ;ids;P;{[ts;ix] (count ts)#0b}]
T:`stime xasc flip `stime`uav`alt`ias`imuz!r 0
R:`stime xasc flip `stime`uav`rpm!r 1
/ as live, where feed handler shards publish at slightly different moments: some drones' newest
/ rows have not arrived yet (2 blocks behind for uav mod 8 = 3, 1 behind for uav mod 8 = 5)
late:{[t] select from t where stime<=max[stime]-`timespan$BLOCKNS*0 0 0 2 0 1 0 0 uav mod 8}
T:late T; R:late R
w:win[T;R;W;CFG`window_s;`long$CFG[`rotor;`n]]
m:`long$CFG[`anomaly;`window_s]*CFG`ana_hz
ms:{`long$x`stime}
out:`telem`rotor`kdb!(
  flip `stime`uav`alt`ias`imuz!(ms T;T`uav;`float$T`alt;`float$T`ias;`float$T`imuz);
  flip `stime`uav`rpm!(ms R;R`uav;`float$R`rpm);
  `uav`n`nr`newest`tss`dtw`discord`corr_alt`corr_ias`swarms`rotor!(
    w`uav; w`n; w`nr; toMs w`newest;
    `dist`idx!value[sigTable[`tss;w]] 0 1;
    `dist`idx!value[sigTable[`dtw;w]] 0 1;
    discord[m;] each w`imuz;
    corr[w;`alt]; corr[w;`ias];
    swarms w;
    rotorFind w))
`:tests/fixtures/crosscheck.json 0: enlist .j.j out;
-1"wrote tests/fixtures/crosscheck.json: ",string[count T]," telem and ",string[count R]," rotor rows, ",string[W]," drones";
exit 0
