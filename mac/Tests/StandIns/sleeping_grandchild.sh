#!/bin/sh
# Starts a sleeping child, writes its process id to the file named by $1,
# then sleeps itself (SubprocessTests: a time limit or a stop must end both).
sleep 600 &
echo $! > "$1.tmp" && mv "$1.tmp" "$1"
sleep 600
