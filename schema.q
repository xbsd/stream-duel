/ schema.q: one row per telemetry frame, 8+8+4+4x4 = 36 bytes
/ time is stamped by the tickerplant, stime is the drone's sample time (UTC)
/ only the four channels the wall shows are recorded
telem:([] time:`timespan$(); stime:`timestamp$(); uav:`int$();
  alt:`real$(); ias:`real$(); rpm:`real$(); imuz:`real$())
