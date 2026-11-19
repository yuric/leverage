#!/bin/sh
# Writes 1 MiB (1048576 bytes of "a") to standard output and as much to
# standard error, then exits 0 (SubprocessTests).
head -c 1048576 /dev/zero | tr '\0' 'a'
head -c 1048576 /dev/zero | tr '\0' 'b' >&2
exit 0
