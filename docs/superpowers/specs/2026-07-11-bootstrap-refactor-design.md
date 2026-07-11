# Bootstrap 重构设计

## 目标

消除 bootstrap/ 下重复代码，用 `vm-deploy.sh` 已有的 type-dispatch 模式
统一 `build.sh` 和 `deploy.sh`，减少手动维护负担。

## 目录结构变更

```
bootstrap/
├── vm-image-upload.sh          # 不改
├── vm-deploy.sh                # 改：类型发现、默认函数、可选 deploy.sh 覆盖
├── build-ignition.sh           # 新：共享编译逻辑（取代 3 个 build.sh）
├── kubeadm/                    # 不改（后续单独处理）
└── types/                      # 新：每个子目录是一个可部署类型
    ├── k8s-node/
    │   ├── .env.example
    │   ├── .env                # gitignored
    │   └── node.bu.tmpl
    ├── k8s-gpu-node/
    │   ├── .env.example
    │   ├── .env                # gitignored
    │   ├── deploy.sh           # 只保留 deploy_prepare_domain_xml
    │   └── gpu-worker.bu.tmpl
    └── storage-server/
        ├── .env.example
        ├── .env                # gitignored
        └── storage.bu.tmpl
```

## 删除的文件

- `bootstrap/k8s-node/build.sh`      → `build-ignition.sh`
- `bootstrap/k8s-node/deploy.sh`     → 默认行为，不再需要
- `bootstrap/k8s-gpu-node/build.sh`   → `build-ignition.sh`
- `bootstrap/storage-server/build.sh`→ `build-ignition.sh`
- `bootstrap/storage-server/deploy.sh`→ 默认行为，不再需要

## 接口约定

每个类型目录必须提供 `.env.example` + 至少一个 `.bu.tmpl`。
`deploy.sh` 是可选的，只在需要覆盖默认行为时存在。

### 默认实现

| 函数 | 默认行为 |
|---|---|
| `deploy_build` | `build-ignition.sh --template <第一个 .bu.tmpl>` → `IGNITION_FILE` |
| `deploy_extra_args` | 空 |
| `deploy_prepare_domain_xml` | 空操作 |

vm-deploy.sh 先定义默认函数，然后 `source deploy.sh`（如果存在）来覆盖。

## build-ignition.sh

共享脚本，参数化：

```
build-ignition.sh --template PATH [--env PATH] [--validate]
```

- 自动从模板 `grep` 出所有 `${VAR}` 引用，生成 envsubst 变量列表
- 验证通用必需变量（K8S_PASSWORD_HASH K8S_SSH_PUB_KEY K8S_HOSTNAME K8S_PREINSTALLED_PACKAGES）
- .env 文件默认从模板同目录查找
- 输出 `.ign` 文件放在模板同目录

## vm-deploy.sh 改动

1. 类型目录从 `SCRIPT_DIR/TYPE` 改为 `SCRIPT_DIR/types/TYPE`
2. --type 参数用 `ls types/*/` 发现可用类型，不存在时列出所有类型
3. 默认函数在 source deploy.sh 之前定义
4. `deploy_build` 的默认实现用 `build-ignition.sh`
5. `deploy_extra_args` 的默认实现是 true（不输出额外参数）
6. `deploy_prepare_domain_xml` 的默认实现是 no-op
7. 其余逻辑不变：参数解析、.env 加载、pre-flight、virt-install、fwcfg 清理、blockpull

## 用户可见变更

- 类型目录路径变更：`bootstrap/k8s-node` → `bootstrap/types/k8s-node`
- CLI 不变：`vm-deploy.sh --type k8s-node` 和之前一样
- .env.example 和 .bu.tmpl 内容不变
- Ignition 输出路径从 `k8s-node/node.ign` → `types/k8s-node/node.ign`
