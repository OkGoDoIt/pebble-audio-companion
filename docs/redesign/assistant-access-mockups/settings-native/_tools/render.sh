#!/bin/zsh
# Renders the job list with a 90 s guard (a stale Chrome on the port hangs the driver).
cd "${0:A:h}/.."
pkill -f chrome-prof-sn 2>/dev/null; sleep 0.5
node _tools/cdp.mjs "${1:-_tools/jobs.json}" > /private/tmp/claude-501/-Users-roger-Repos-pebble/3f0bcf37-33b5-4c68-a555-aafa12580a5f/scratchpad/sn-out.json & PID=$!
for i in $(seq 1 90); do kill -0 $PID 2>/dev/null || break; sleep 1; done
kill -0 $PID 2>/dev/null && { echo "TIMEOUT"; kill $PID; pkill -f chrome-prof-sn; }
python3 -c "
import json;r=json.load(open('/private/tmp/claude-501/-Users-roger-Repos-pebble/3f0bcf37-33b5-4c68-a555-aafa12580a5f/scratchpad/sn-out.json'))
for j in r: print(j['name'], 'docH',j['docH'],'ovx',j['overflowX'],'small',j['smallTargets'],'logs',j['logs'],'net',j['net'])"
