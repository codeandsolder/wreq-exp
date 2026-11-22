#!/usr/bin/env bash
set -euo pipefail
cargo fmt -p wreq -- --check
cargo check --locked -p wreq --all-targets --all-features
cargo check --locked -p wreq --all-targets --no-default-features --features tokio-rt,webpki-roots
cargo clippy --locked -p wreq --all-targets --all-features -- -D warnings
cargo test --locked -p wreq --lib
