@echo off
setlocal enabledelayedexpansion
rem Windows: starts the tickerplant, the feed handlers (one CPU core each) and the RDB in their own windows.
rem Feed handlers: CPU cores minus 4, between 1 and 12. To choose: run "set SHARDS=6" first, then start.bat
cd /d %~dp0
if not defined SHARDS (
  set /a SHARDS=%NUMBER_OF_PROCESSORS%-4
  if !SHARDS! LSS 1 set SHARDS=1
  if !SHARDS! GTR 12 set SHARDS=12
)
set /a LAST=SHARDS-1
start "tickerplant" q tp.q -p 5010 -log 0
timeout /t 1 >nul
for /L %%i in (0,1,%LAST%) do (
  set /a P=5020+%%i
  start "feed handler %%i" q fh.q -p !P! -shard %%i -of %SHARDS% -tp 5010
)
timeout /t 1 >nul
start "rdb" q rdb.q -p 5011 -tp 5010 -fh 5020 -shards %SHARDS%
echo Running %SHARDS% feed handler(s). Open telemetry-wall.html in your browser. Close the q windows to stop.
