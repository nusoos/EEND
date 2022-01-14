#!/usr/bin/env bash
# Start run_eval2000.sh with pre-defined arguements.

. ./cmd.sh
. ./path.sh
set -euo pipefail

#./run_eval2000.sh --stages "1 2 7"
./run_eval2000.sh --from_stage 0