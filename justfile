# Run all repo checks on the conversion material.
check-conversion:
    bash scripts/check-conversion.sh

# Build the static x86_64 musl tp-basic into build/tp-basic and check it is static.
musl:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release --target x86_64-unknown-linux-musl --bin tp-basic
    mkdir -p build
    cp target/x86_64-unknown-linux-musl/release/tp-basic build/tp-basic
    info=$(file -b build/tp-basic)
    echo "file: $info"
    case "$info" in
        *"statically linked"*|*"static-pie linked"*) echo "static: yes" ;;
        *) echo "static: NO" >&2; exit 1 ;;
    esac
    build/tp-basic list

# Docker equivalence oracle: build <container>'s chain with Ansible and with
# tp-basic from one pinned base image, diff the resulting image state.
# `just test-container ubuntu2404 dev_base`
test-container distro container:
    bash scripts/test-container.sh {{distro}} {{container}}

# Self-test of the oracle's diff/exit logic (no docker needed).
test-container-selftest:
    bash scripts/test-container.sh --self-test
