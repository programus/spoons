#!/bin/zsh
# Every offline suite, in the order they get progressively less isolated.
# Usage: test/run.sh            (needs luajit; mutate.sh additionally needs perl)
set -u
HERE=${0:a:h}
rc=0
for spec in pure_spec static_spec panel_spec; do
  print "\n────── $spec ──────"
  luajit "$HERE/$spec.lua" || rc=1
done
exit $rc
