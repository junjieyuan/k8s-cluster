#!/usr/bin/env bash
# storage-server type-specific deploy functions.
set -euo pipefail
# Sourced by vm-deploy.sh. Do not run directly.
# Expected globals from vm-deploy.sh: TYPE_DIR
#
# Expected .env vars (in addition to build.sh vars):
#   K8S_HFHUB_SOURCE    Host directory for virtiofs passthrough (optional)

deploy_build() {
    bash "${TYPE_DIR}/build.sh"
    IGNITION_FILE="${TYPE_DIR}/storage.ign"
}

deploy_extra_args() {
    true
}

# Generate virtiofs filesystem XML element
_virtiofs_xml() {
    local source="$1"
    cat <<XMLEOF
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <binary path='/usr/libexec/virtiofsd'/>
      <source dir='${source}'/>
      <target dir='hfhub'/>
      <readonly/>
    </filesystem>
XMLEOF
}

deploy_finalize() {
    local vm_name="$1"

    # Load .env for storage-specific vars
    local env_file="${TYPE_DIR}/.env"
    if [[ -f "$env_file" ]]; then
        set -a; source "$env_file"; set +a
    fi

    [[ -z "${K8S_HFHUB_SOURCE:-}" ]] && return 0

    if [[ ! -d "$K8S_HFHUB_SOURCE" ]]; then
        echo "Warning: K8S_HFHUB_SOURCE '$K8S_HFHUB_SOURCE' does not exist, skipping virtiofs" >&2
        return 0
    fi

    local state
    state="$(virsh domstate "$vm_name" 2>/dev/null || echo "not found")"

    if [[ "$state" != "running" ]] && [[ "$state" != "shut off" ]]; then
        echo "Warning: unexpected VM state '$state', skipping virtiofs configuration" >&2
        return 0
    fi

    local need_start=false
    if [[ "$state" == "running" ]]; then
        need_start=true
        echo "Stopping $vm_name to apply virtiofs configuration..." >&2
        virsh destroy "$vm_name"
    fi

    _hfhub_cleanup() {
        if $need_start; then
            echo "virtiofs config failed, restarting $vm_name in original state..." >&2
            virsh start "$vm_name" >/dev/null 2>&1 || true
        fi
    }
    trap _hfhub_cleanup ERR

    local tmp_xml
    tmp_xml="$(mktemp)"
    virsh dumpxml "$vm_name" > "$tmp_xml"

    # 1. memoryBacking: memfd + shared (required for virtiofs)
    local mem_snippet
    mem_snippet="$(mktemp)"
    cat > "$mem_snippet" <<'XMLEOF'
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
XMLEOF
    sed -i "/<\/currentMemory>/r $mem_snippet" "$tmp_xml"
    rm -f "$mem_snippet"

    # 2. Build device snippet: virtiofs
    local dev_snippet
    dev_snippet="$(mktemp)"
    _virtiofs_xml "$K8S_HFHUB_SOURCE" >> "$dev_snippet"

    # Insert device snippet before </devices>
    local line_no
    line_no=$(grep -n '</devices>' "$tmp_xml" | head -1 | cut -d: -f1)
    {
        head -n $((line_no - 1)) "$tmp_xml"
        cat "$dev_snippet"
        tail -n +$line_no "$tmp_xml"
    } > "${tmp_xml}.new"
    mv "${tmp_xml}.new" "$tmp_xml"

    virsh define "$tmp_xml" >/dev/null
    rm -f "$tmp_xml" "$dev_snippet"
    trap - ERR

    echo "[OK] virtiofs: ${K8S_HFHUB_SOURCE} -> /var/nfs/models/huggingface" >&2

    if $need_start; then
        echo "Starting $vm_name with virtiofs configuration..." >&2
        virsh start "$vm_name" >/dev/null
    fi
}
