/ tools/templates.q: writes templates.json, the signature templates both lanes search for.
/ q tools/templates.q   Templates come from the same formulas gen.q uses to plant the events,
/ sampled at the analytics rate (config.json ana_hz). Each lane z-normalizes them before matching.
\l gen.q
CFG:.j.k raze read0`:config.json
f:CFG`ana_hz
t:{[secs] til[`long$secs*f]%f}
PI:acos -1
r:t[3]%3; x1:t 1; x3:t 3
dive:`alt`ias!(neg sin PI*r;sin PI*r)                               / dive and pull up
d1:0|x1-0.2                                                           / time since release
payload:enlist[`imuz]!enlist (exp neg ((x1-0.2)%0.06) xexp 2)+(x1>=0.2)*0.9*(exp neg d1%0.35)*sin TAU*2.5*d1   / jolt, ring-down
hover:enlist[`ias]!enlist neg 1&2*x3                                  / airspeed falls, holds
jink:enlist[`imuz]!enlist (sin PI*x3%3)*sin TAU*3*x3                  / 3 Hz jinking
tpl:`dive`payload`hover`jink!(dive;payload;hover;jink)
`:templates.json 0: enlist .j.j tpl;
-1"wrote templates.json: ",", " sv {string[x]," (",(", " sv string key tpl x),")"} each key tpl;
exit 0
