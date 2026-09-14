#!/bin/zsh
# Start this, then open Launchpad on the target display and leave it visible.
# The delayed capture avoids measuring the hidden agent after returning to Terminal.
set -eu
delay_seconds=${1:-8}
if [[ "$delay_seconds" != <-> ]]; then
  print -u2 'Usage: zsh Tests/Runtime/SampleAgentMemory.zsh [delay-seconds] [output-file]'
  exit 2
fi
output_path=${2:-"$PWD/Builds/agent-memory-$(date +%Y%m%d-%H%M%S).txt"}
print "Open Launchpad on the target display; leave it visible. Capturing in ${delay_seconds}s."
sleep "$delay_seconds"
if ! agent_pid=$(pgrep -x OpenLaunchpadAgent); then
  print -u2 'No OpenLaunchpadAgent process is running.'
  exit 1
fi
if [[ "$agent_pid" == *$'\n'* ]]; then
  print -u2 'More than one agent is running; quit the extra instance before sampling.'
  exit 1
fi
mkdir -p "$(dirname "$output_path")"
vmmap -summary "$agent_pid" > "$output_path"
rg 'Physical footprint|CoreAnimation|CoreImage|IOSurface|MALLOC_LARGE' "$output_path"
print "Full report: $output_path"
