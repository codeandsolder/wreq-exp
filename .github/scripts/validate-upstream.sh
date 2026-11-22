#!/usr/bin/env bash
set -euo pipefail
cargo +nightly fmt -p wreq -- --check
cargo +1.99.0 check --locked -p wreq --all-targets --all-features
cargo +1.99.0 check --locked -p wreq --all-targets --no-default-features --features tokio-rt,webpki-roots
cargo +1.99.0 clippy --locked -p wreq --all-targets --all-features -- -D warnings
cargo +1.99.0 test --locked -p wreq --lib
