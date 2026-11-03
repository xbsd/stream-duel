/ tools/fixture.q: writes tests/fixtures/crosscheck.json, the rows and kdb+ results that
/ tests/test_crosscheck.py replays through the DuckDB lane's code (bridge/analytics.py).
/ q tools/fixture.q -s 4
\l gen.q
\l analytics.q
\P 17                                 / full float precision in the JSON
W:48; HZ:200; S0:21; SECS:5
U0:1762000000 - 1762000000 mod 1024
ids:til W; P:{h01 h2[ids;x]} each 1+til 8
uts:(SLOT*S0)+til[SECS*HZ]%HZ
ts:raze W#'uts; ix:raze (count uts)#enlist ids; uav:1+ix
v:sigDuel[ts;P[;ix];(count ts)#0b;uav]
tsAt:{[u] `timestamp$(`long$1e9*u)-UNIX}
tbl:`stime xasc ([] stime:tsAt U0+ts; uav:`int$uav; alt:`real$120+38*v 1; ias:`real$18+7*v 2;
  rpm:`real$7200+1500*v 3; imuz:`real$2.4*v 0)
/ as live, where feed handler shards publish at slightly different moments: some drones' newest
/ samples have not arrived yet (2 behind for uav mod 8 = 3, 1 behind for uav mod 8 = 5)
tbl:select from tbl where stime<=max[stime]-`timespan$(`long$1e9%HZ)*0 0 0 2 0 1 0 0 uav mod 8
w:win[tbl;W;CFG`window_s;HZ]; f:HZ div CFG`ana_hz
m:`long$CFG[`anomaly;`window_s]*CFG`ana_hz
out:`rows`hz`kdb!(
  flip `stime`uav`alt`ias`rpm`imuz!(`long$tbl`stime;tbl`uav;`float$tbl`alt;`float$tbl`ias;`float$tbl`rpm;`float$tbl`imuz);
  HZ;
  `uav`n`newest`tss`dtw`discord`corr_alt`corr_ias`swarms`rotor!(
    w`uav; w`n; toMs w`newest;
    `dist`idx!value[sigTable[`tss;w;f]] 0 1;
    `dist`idx!value[sigTable[`dtw;w;f]] 0 1;
    discord[m;] each downM[w`imuz;f];
    corr[w;f;`alt]; corr[w;f;`ias];
    swarms[w;f];
    rotor w))
`:tests/fixtures/crosscheck.json 0: enlist .j.j out;
-1"wrote tests/fixtures/crosscheck.json: ",string[count tbl]," rows, ",string[W]," drones";
exit 0
