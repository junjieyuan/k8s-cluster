#!/usr/bin/env bash
# k8s-gpu-node type-specific deploy functions.
set -euo pipefail
# Sourced by vm-deploy.sh. Do not run directly.
# Expected globals from vm-deploy.sh: TYPE_DIR
#
# Expected .env vars (in addition to build.sh vars):
#   K8S_GPU_DEVICES        Space-separated PCI addresses, e.g. "0000:01:00.0 0000:01:00.1"
#   K8S_VIRTIOFS_SOURCE    Host directory for virtiofs passthrough (optional)
#   K8S_VIRTIOFS_TARGET    Guest mount tag (default: hf_hub)

deploy_build() {
    bash "${TYPE_DIR}/build.sh"
    IGNITION_FILE="${TYPE_DIR}/gpu-worker.ign"
}

deploy_extra_args() {
    true
}

# Convert PCI address "01:00.0" or "0000:01:00.0" to hostdev XML
_pci_to_hostdev_xml() {
    local pci="$1"
    local domain bus slot fn
    # Normalize: accept both BB:SS.F and DDDD:BB:SS.F
    local parts
    IFS=':' read -ra parts <<< "$pci"
    if [[ ${#parts[@]} -eq 2 ]]; then
        # BB:SS.F  →  domain=0000
        domain="0000"
        bus="${parts[0]}"
        slot="${parts[1]%%.*}"
        fn="${parts[1]##*.}"
    else
        # DDDD:BB:SS.F
        domain="${parts[0]}"
        bus="${parts[1]}"
        slot="${parts[2]%%.*}"
        fn="${parts[2]##*.}"
    fi
    printf '<hostdev mode="subsystem" type="pci" managed="yes">
      <driver name="vfio"/>
      <source>
        <address domain="0x%04x" bus="0x%02x" slot="0x%02x" function="0x%x"/>
      </source>
      <rom bar="off"/>
    </hostdev>' "$((16#$domain))" "$((16#$bus))" "$((16#$slot))" "$((16#$fn))"
}

deploy_finalize() {
    local vm_name="$1"
    local need_destroy=false

    # Load .env for GPU-specific vars
    local env_file="${TYPE_DIR}/.env"
    if [[ -f "$env_file" ]]; then
        set -a; source "$env_file"; set +a
    fi

    local state
    state="$(virsh domstate "$vm_name" 2>/dev/null || echo "not found")"

    if [[ "$state" != "running" ]] && [[ "$state" != "shut off" ]]; then
        echo "Warning: unexpected VM state '$state', skipping GPU configuration" >&2
        return 0
    fi

    if [[ "$state" == "running" ]]; then
        need_destroy=true
        echo "Stopping $vm_name to apply GPU configuration..." >&2
        virsh destroy "$vm_name"
    fi

    # On failure, try to restart the VM in its current state
    _gpu_cleanup() {
        if $need_destroy; then
            echo "GPU config failed, restarting $vm_name in original state..." >&2
            virsh start "$vm_name" >/dev/null 2>&1 || true
        fi
    }
    trap _gpu_cleanup ERR

    # --- Build complete domain XML in one pass ---
    local tmp_xml
    tmp_xml="$(mktemp)"
    virsh dumpxml "$vm_name" > "$tmp_xml"

    # 1. cpu: host-passthrough (required for NVIDIA driver to see host features)
    # Handle both self-closing <cpu .../> and multi-line <cpu>...</cpu>
    sed -i 's|<cpu [^>]*/>|<cpu mode="host-passthrough" check="none" migratable="on"/>|' "$tmp_xml"
    if grep -q '<cpu ' "$tmp_xml"; then
        sed -i '/<cpu /,/<\/cpu>/c\  <cpu mode="host-passthrough" check="none" migratable="on"/>' "$tmp_xml"
    fi

    # 2. memoryBacking: memfd + shared (required for VFIO passthrough)
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

    # 3. Build device snippet: hostdevs + virtiofs + watchdog
    local dev_snippet
    dev_snippet="$(mktemp)"

    if [[ -n "${K8S_GPU_DEVICES:-}" ]]; then
        for dev in $K8S_GPU_DEVICES; do
            _pci_to_hostdev_xml "$dev" >> "$dev_snippet"
        done
    fi

    if [[ -n "${K8S_VIRTIOFS_SOURCE:-}" ]]; then
        local vtag="${K8S_VIRTIOFS_TARGET:-hf_hub}"
        cat >> "$dev_snippet" <<XMLEOF
    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <binary path='/usr/libexec/virtiofsd'/>
      <source dir='${K8S_VIRTIOFS_SOURCE}'/>
      <target dir='${vtag}'/>
      <readonly/>
    </filesystem>
XMLEOF
    fi

    cat >> "$dev_snippet" <<'XMLEOF'
    <watchdog model='itco' action='reset'/>
XMLEOF

    # Insert device snippet before </devices>
    local line_no
    line_no=$(grep -n '</devices>' "$tmp_xml" | head -1 | cut -d: -f1)
    {
        head -n $((line_no - 1)) "$tmp_xml"
        cat "$dev_snippet"
        tail -n +$line_no "$tmp_xml"
    } > "${tmp_xml}.new"
    mv "${tmp_xml}.new" "$tmp_xml"

    # 4. Apply the modified XML
    virsh define "$tmp_xml" >/dev/null
    rm -f "$tmp_xml" "$dev_snippet"
    trap - ERR

    # --- Summary ---
    echo "[OK] memory backing configured (memfd+shared)" >&2
    echo "[OK] cpu set to host-passthrough" >&2
    [[ -n "${K8S_GPU_DEVICES:-}" ]] && echo "[OK] GPU passthrough: ${K8S_GPU_DEVICES}" >&2
    [[ -n "${K8S_VIRTIOFS_SOURCE:-}" ]] && echo "[OK] virtiofs: ${K8S_VIRTIOFS_SOURCE} -> ${K8S_VIRTIOFS_TARGET:-hf_hub}" >&2

    # --- Restart if we stopped it ---
    if $need_destroy; then
        echo "Starting $vm_name with GPU configuration..." >&2
        virsh start "$vm_name" >/dev/null
    fi
}
