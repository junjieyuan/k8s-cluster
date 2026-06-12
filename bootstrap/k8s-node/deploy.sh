#!/usr/bin/env bash
# k8s-node type-specific deploy functions.
set -euo pipefail
# Sourced by vm-deploy.sh. Do not run directly.
# Expected globals from vm-deploy.sh: TYPE_DIR

deploy_build() {
    bash "${TYPE_DIR}/build.sh"
    IGNITION_FILE="${TYPE_DIR}/node.ign"
}

deploy_extra_args() {
    true
}

deploy_finalize() {
    :
}
