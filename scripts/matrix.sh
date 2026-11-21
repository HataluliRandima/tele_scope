#!/usr/bin/env bash
# Runs the test suite against every installed Elixir/OTP pairing (asdf).
# Usage: scripts/matrix.sh [extra mix test args]
set -u
cd "$(dirname "$0")/.."
mkdir -p experiments/results
EXTRA=("$@")
COMBOS=("1.15.8-otp-26 26.1.2" "1.17.0 26.1.2" "1.17.0 27.0" "1.20.1-otp-29 29.0")
for combo in "${COMBOS[@]}"; do
  read -r ex otp <<< "$combo"
  out="experiments/results/test_matrix_elixir${ex}_otp${otp}.txt"
  echo "== Elixir $ex / OTP $otp"
  MIX_ENV=test ASDF_ELIXIR_VERSION=$ex ASDF_ERLANG_VERSION=$otp MIX_BUILD_ROOT="_build_matrix/${ex}_${otp}" \
    mix do deps.get + test --include peer "${EXTRA[@]}" > "$out" 2>&1
  echo "   exit=$? $(grep -E '[0-9]+ tests?, [0-9]+ failures?|Result: ' "$out" | tail -1)"
done
