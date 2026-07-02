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

# deploy_prepare_domain_xml(xml_file)
# Called by vm-deploy.sh BEFORE the VM is defined/started.
# Modifies the domain XML in-place with GPU passthrough, virtiofs,
# and memory backing (required for VFIO).
# cpu=host-passthrough is set via --cpu flag in vm-deploy.sh.
deploy_prepare_domain_xml() {
    local xml_file="$1"

    # Load .env for GPU-specific vars
    local env_file="${TYPE_DIR}/.env"
    if [[ -f "$env_file" ]]; then
        set -a; source "$env_file"; set +a
    fi

    # 1. memoryBacking: memfd + shared (required for VFIO passthrough)
    local mem_snippet
    mem_snippet="$(mktemp)"
    cat > "$mem_snippet" <<'XMLEOF'
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
XMLEOF
    sed -i "/<\/currentMemory>/r $mem_snippet" "$xml_file"
    rm -f "$mem_snippet"

    # 2. Build device snippet: hostdevs + virtiofs
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

    # Insert device snippet before </devices>
    local line_no
    line_no=$(grep -n '</devices>' "$xml_file" | head -1 | cut -d: -f1)
    {
        head -n $((line_no - 1)) "$xml_file"
        cat "$dev_snippet"
        tail -n +$line_no "$xml_file"
    } > "${xml_file}.new"
    mv "${xml_file}.new" "$xml_file"
    rm -f "$dev_snippet"

    # Summary
    echo "  [OK] memory backing configured (memfd+shared)" >&2
    [[ -n "${K8S_GPU_DEVICES:-}" ]] && echo "  [OK] GPU passthrough: ${K8S_GPU_DEVICES}" >&2
    [[ -n "${K8S_VIRTIOFS_SOURCE:-}" ]] && echo "  [OK] virtiofs: ${K8S_VIRTIOFS_SOURCE} -> ${K8S_VIRTIOFS_TARGET:-hf_hub}" >&2
}
