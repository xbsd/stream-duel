/ schema.q: what each drone sends, in two tables at two rates (DESIGN.md, gen.q's blockRows)
/ time is stamped by the tickerplant, stime is the drone's sample time (UTC)
/ telem: 50 rows a second per drone; each value is the mean of the drone's 200 Hz samples over the
/ row's 20 ms. 8+8+4+3x4 = 32 bytes
telem:([] time:`timespan$(); stime:`timestamp$(); uav:`int$(); alt:`real$(); ias:`real$(); imuz:`real$())
/ rotor: 100 rows a second per drone; rotor speed, sampled (its 5..40 Hz band needs more than 80 Hz).
/ 8+8+4+4 = 24 bytes
rotor:([] time:`timespan$(); stime:`timestamp$(); uav:`int$(); rpm:`real$())
METRICS:`telem`rotor!(`alt`ias`imuz;enlist`rpm)   / the measured columns of each table
