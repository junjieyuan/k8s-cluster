# Bootstrap 重构实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除 bootstrap/ 下的重复代码，用统一的 type-dispatch 接口替代 3 份几乎相同的 build.sh 和 2 份空壳 deploy.sh。

**Architecture:** 创建共享的 `build-ignition.sh`（所有类型通用），迁移类型目录到 `types/` 子目录，vm-deploy.sh 在 source deploy.sh 前定义默认函数，使 k8s-node 和 storage-server 不再需要 deploy.sh。

**Tech Stack:** bash, butane, envsubst, virt-install

## Global Constraints

- **Bash only** — 不引入 Python/Node/其他语言
- 保持 CLI 兼容 — `vm-deploy.sh --type k8s-node` 行为不变
- `.env` 文件正常迁移（gitignored，含真实密码）
- 遵循 CLAUDE.md 命名和代码规范

---

### Task 1: 创建 `build-ignition.sh`

**Files:**
- Create: `bootstrap/build-ignition.sh`

**Interfaces:**
- Produces: `build-ignition.sh --template PATH [--env PATH] [--validate]` — 编译 `.bu.tmpl` → `.ign`

- [ ] **Step 1: 创建 build-ignition.sh**

```bash
#!/usr/bin/env bash
# Compile a Butane template (.bu.tmpl) into an Ignition config (.ign).
# Shared by all bootstrap types; replaces the per-type build.sh.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-ignition.sh --template PATH [OPTIONS]

Compile a Butane template into an Ignition config, substituting variables
from a .env file.

Options:
  --template PATH   Butane template file (required)
  --env PATH        .env file (default: same directory as template)
  --validate        Validate the template without generating output
  --help            Show this help
EOF
    exit "${1:-0}"
}

TEMPLATE=""
ENV_FILE=""
VALIDATE_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --template) TEMPLATE="$2";       shift 2 ;;
        --env)      ENV_FILE="$2";        shift 2 ;;
        --validate) VALIDATE_ONLY=true;   shift ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -n "$TEMPLATE" ]] || { echo "Error: --template is required" >&2; usage 1; }
[[ -f "$TEMPLATE" ]] || { echo "Error: template not found: $TEMPLATE" >&2; exit 1; }

# Default .env to template's directory
if [[ -z "$ENV_FILE" ]]; then
    ENV_FILE="$(dirname "$TEMPLATE")/.env"
fi

# Check dependencies
for bin in butane envsubst; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: $bin not found" >&2; exit 1; }
done

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found. Copy .env.example to .env and fill in the values." >&2
    exit 1
fi

# Load variables
set -a; source "$ENV_FILE"; set +a

# Auto-extract all ${VAR} references from the template and build envsubst arg.
# This avoids hard-coding variable names per type (e.g. K8S_NFS_SUBNET is
# specific to storage-server).
ENVSUBST_VARS=$(grep -o '\${[A-Z_][A-Z_0-9]*}' "$TEMPLATE" | sort -u | sed 's/^{/$/' | tr -d '}' | paste -sd ' ' -)

# Validate required vars (universal across all types)
REQUIRED_VARS=("K8S_PASSWORD_HASH" "K8S_SSH_PUB_KEY" "K8S_HOSTNAME" "K8S_PREINSTALLED_PACKAGES")
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: Required variable $var is not set in .env" >&2
        exit 1
    fi
done

# Output: node.bu.tmpl -> node.ign, gpu-worker.bu.tmpl -> gpu-worker.ign, etc.
OUTPUT="${TEMPLATE%.bu.tmpl}.ign"

if $VALIDATE_ONLY; then
    echo "Validating $TEMPLATE..." >&2
    envsubst "$ENVSUBST_VARS" < "$TEMPLATE" | butane --check
    echo "Template is valid." >&2
    exit 0
fi

# Remove stale output owned by qemu from a previous provisioning run
rm -f "$OUTPUT"
echo "Compiling $TEMPLATE -> $OUTPUT..." >&2
envsubst "$ENVSUBST_VARS" < "$TEMPLATE" | butane -o "$OUTPUT"
echo "Generated $OUTPUT" >&2
```

- [ ] **Step 2: 设为可执行**

```bash
chmod +x bootstrap/build-ignition.sh
```

- [ ] **Step 3: 验证 build-ignition.sh --validate 可用**

```bash
./bootstrap/build-ignition.sh --template bootstrap/k8s-node/node.bu.tmpl --validate
```

预期输出: `Validating ... Template is valid.`

- [ ] **Step 4: 提交**

```bash
git add bootstrap/build-ignition.sh
git commit -m "feat: add shared build-ignition.sh to replace per-type build.sh"
```

---

### Task 2: 创建 `types/` 目录并迁移文件

**Files:**
- Create: `bootstrap/types/k8s-node/.env.example`, `bootstrap/types/k8s-node/node.bu.tmpl`
- Create: `bootstrap/types/k8s-gpu-node/.env.example`, `bootstrap/types/k8s-gpu-node/gpu-worker.bu.tmpl`
- Create: `bootstrap/types/storage-server/.env.example`, `bootstrap/types/storage-server/storage.bu.tmpl`

**Interfaces:**
- Produces: `types/` 目录供 vm-deploy.sh 自动发现

- [ ] **Step 1: 创建目录并复制文件**

```bash
mkdir -p bootstrap/types/k8s-node
mkdir -p bootstrap/types/k8s-gpu-node
mkdir -p bootstrap/types/storage-server

cp bootstrap/k8s-node/.env.example bootstrap/types/k8s-node/
cp bootstrap/k8s-node/node.bu.tmpl bootstrap/types/k8s-node/
cp bootstrap/k8s-gpu-node/.env.example bootstrap/types/k8s-gpu-node/
cp bootstrap/k8s-gpu-node/gpu-worker.bu.tmpl bootstrap/types/k8s-gpu-node/
cp bootstrap/storage-server/.env.example bootstrap/types/storage-server/
cp bootstrap/storage-server/storage.bu.tmpl bootstrap/types/storage-server/
```

- [ ] **Step 2: 迁移 .env 文件（如存在）**

```bash
[[ -f bootstrap/k8s-node/.env ]]       && cp bootstrap/k8s-node/.env bootstrap/types/k8s-node/
[[ -f bootstrap/k8s-gpu-node/.env ]]    && cp bootstrap/k8s-gpu-node/.env bootstrap/types/k8s-gpu-node/
[[ -f bootstrap/storage-server/.env ]]  && cp bootstrap/storage-server/.env bootstrap/types/storage-server/
```

- [ ] **Step 3: 提交**

```bash
git add bootstrap/types/
git commit -m "feat: migrate type templates to bootstrap/types/"
```

---

### Task 3: 修改 `vm-deploy.sh`

**Files:**
- Modify: `bootstrap/vm-deploy.sh`

**Interfaces:**
- Consumes: `build-ignition.sh`, `types/` 目录结构
- Produces: 类型自动发现、默认 deploy 函数、可选 deploy.sh 覆盖

需要修改 3 处：

- [ ] **Step 1: 改 type 解析逻辑（替换 `# --- Resolve type ---` 段落）**

**旧代码 (line 68-74):**
```bash
# --- Resolve type ---
if [[ -z "$NODE_TYPE" ]]; then
    fail "--type is required (one of: k8s-node, k8s-gpu-node, storage-server)"
fi

TYPE_DIR="${SCRIPT_DIR}/${NODE_TYPE}"
[[ -d "$TYPE_DIR" ]] || fail "Type directory not found: $TYPE_DIR"
```

替换为:

```bash
# --- Resolve type ---
TYPES_DIR="${SCRIPT_DIR}/types"

if [[ -z "$NODE_TYPE" ]]; then
    echo -n "Error: --type is required. Available types:" >&2
    for d in "${TYPES_DIR}"/*/; do
        [[ -d "$d" ]] && echo -n " $(basename "$d")" >&2
    done
    echo >&2
    exit 1
fi

TYPE_DIR="${TYPES_DIR}/${NODE_TYPE}"
if [[ ! -d "$TYPE_DIR" ]]; then
    echo -n "Error: Unknown type '$NODE_TYPE'. Available:" >&2
    for d in "${TYPES_DIR}"/*/; do
        [[ -d "$d" ]] && echo -n " $(basename "$d")" >&2
    done
    echo >&2
    exit 1
fi
```

- [ ] **Step 2: 用默认函数 + 可选 source 替换 deploy.sh 加载逻辑（替换 `DEPLOY_SCRIPT=...` 到 `source "$DEPLOY_SCRIPT"` 段落）**

**旧代码 (line 87-93):**
```bash
DEPLOY_SCRIPT="${TYPE_DIR}/deploy.sh"
[[ -f "$DEPLOY_SCRIPT" ]] || fail "deploy.sh not found in $TYPE_DIR"

# Source type-specific deploy functions
# shellcheck disable=SC1090
source "$DEPLOY_SCRIPT"
```

替换为:

```bash
# --- Default deploy functions (type-specific deploy.sh can override) ---
deploy_build() {
    local template
    template=$(echo "${TYPE_DIR}"/*.bu.tmpl | head -1)
    if [[ ! -f "$template" ]]; then
        fail "No .bu.tmpl found in $TYPE_DIR"
    fi
    bash "${SCRIPT_DIR}/build-ignition.sh" --template "$template"
    IGNITION_FILE="${template%.bu.tmpl}.ign"
}

deploy_extra_args() { true; }
deploy_prepare_domain_xml() { :; }

# Source type-specific overrides (optional — only needed by types like k8s-gpu-node)
DEPLOY_SCRIPT="${TYPE_DIR}/deploy.sh"
if [[ -f "$DEPLOY_SCRIPT" ]]; then
    # shellcheck disable=SC1090
    source "$DEPLOY_SCRIPT"
fi
```

- [ ] **Step 3: 验证 --dry-run**

```bash
./bootstrap/vm-deploy.sh --type k8s-node --dry-run
```

预期: 输出 DRY-RUN 信息（会失败因为 types/k8s-node/.env 可能还没填 —— 但 dry-run 逻辑在 load .env 之后、check .env vars 之前执行）

- [ ] **Step 4: 提交**

```bash
git add bootstrap/vm-deploy.sh
git commit -m "refactor: type discovery and default deploy functions in vm-deploy.sh"
```

---

### Task 4: 瘦身 `k8s-gpu-node/deploy.sh`

**Files:**
- Create: `bootstrap/types/k8s-gpu-node/deploy.sh`

**Interfaces:**
- Consumes: 继承 `vm-deploy.sh` 中定义的默认 `deploy_build` 和 `deploy_extra_args`
- Produces: 覆盖 `deploy_prepare_domain_xml`

- [ ] **Step 1: 创建精简版 deploy.sh（只写 GPU 特有逻辑）**

```bash
#!/usr/bin/env bash
# k8s-gpu-node type-specific deploy overrides.
set -euo pipefail
# Sourced by vm-deploy.sh. Do not run directly.
# deploy_build and deploy_extra_args use defaults — only GPU-specific
# domain XML setup is here.
#
# Expected globals from vm-deploy.sh: TYPE_DIR
# Expected .env vars (in addition to build-ignition.sh vars):
#   K8S_GPU_DEVICES        Space-separated PCI addresses, e.g. "0000:01:00.0 0000:01:00.1"
#   K8S_VIRTIOFS_SOURCE    Host directory for virtiofs passthrough (optional)
#   K8S_VIRTIOFS_TARGET    Guest mount tag (default: hf_hub)

# Convert PCI address "01:00.0" or "0000:01:00.0" to hostdev XML
_pci_to_hostdev_xml() {
    local pci="$1"
    local domain bus slot fn
    local parts
    IFS=':' read -ra parts <<< "$pci"
    if [[ ${#parts[@]} -eq 2 ]]; then
        domain="0000"
        bus="${parts[0]}"
        slot="${parts[1]%%.*}"
        fn="${parts[1]##*.}"
    else
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

    echo "  [OK] memory backing configured (memfd+shared)" >&2
    [[ -n "${K8S_GPU_DEVICES:-}" ]] && echo "  [OK] GPU passthrough: ${K8S_GPU_DEVICES}" >&2
    [[ -n "${K8S_VIRTIOFS_SOURCE:-}" ]] && echo "  [OK] virtiofs: ${K8S_VIRTIOFS_SOURCE} -> ${K8S_VIRTIOFS_TARGET:-hf_hub}" >&2
}
```

- [ ] **Step 2: 提交**

```bash
git add bootstrap/types/k8s-gpu-node/deploy.sh
git commit -m "refactor: slim k8s-gpu-node deploy.sh to GPU-specific overrides only"
```

---

### Task 5: 验证和清理

**Files:**
- Delete: `bootstrap/k8s-node/`, `bootstrap/k8s-gpu-node/`, `bootstrap/storage-server/` 旧目录

- [ ] **Step 1: 验证 k8s-node build**

```bash
# 先确保 types/k8s-node/.env 存在
cp bootstrap/types/k8s-node/.env.example bootstrap/types/k8s-node/.env
# 填假值验证编译流程
./bootstrap/build-ignition.sh --template bootstrap/types/k8s-node/node.bu.tmpl --validate
```

预期的失败: `Error: Required variable K8S_PASSWORD_HASH is not set in .env`（因为 .env 还是 example 的 `<PASTE_...>` 占位符）。

验证 envsubst 变量提取:

```bash
grep -o '\${[A-Z_][A-Z_0-9]*}' bootstrap/types/k8s-node/node.bu.tmpl | sort -u
```

预期输出:
```
${K8S_HOSTNAME}
${K8S_PASSWORD_HASH}
${K8S_PREINSTALLED_PACKAGES}
${K8S_SSH_PUB_KEY}
```

- [ ] **Step 2: 验证 storage-server 变量提取（确认 K8S_NFS_SUBNET 被自动发现）**

```bash
grep -o '\${[A-Z_][A-Z_0-9]*}' bootstrap/types/storage-server/storage.bu.tmpl | sort -u
```

预期输出包含 `${K8S_NFS_SUBNET}`。

- [ ] **Step 3: 删除旧目录**

```bash
rm -rf bootstrap/k8s-node bootstrap/k8s-gpu-node bootstrap/storage-server
```

- [ ] **Step 4: 提交**

```bash
git add -A
git commit -m "chore: remove old type directories, now migrated to bootstrap/types/"
```
