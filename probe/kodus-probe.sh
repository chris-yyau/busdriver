#!/usr/bin/env bash
# Kodus rollout probe (ADR 0058). Throwaway: lives only on probe/kodus-replay2, never merged.
# Prints the number of lines in the file named by $1.
#
# Usage: kodus-probe.sh FILE
# Exit status is awk's.
count_lines() {
  command awk 'END { print NR }' < "$1"
}
count_lines "$1"
