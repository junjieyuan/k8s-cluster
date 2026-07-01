# GPU Worker 节点升级指南

> **目标：** 用运行新版本的 GPU worker 替换旧节点。
>
> **约束：** 当前宿主机只有一张物理 GPU，以 PCI 直通方式分配给 VM。无法同时运行新旧两个 GPU 节点——升级过程**必有停机时间**，GPU 工作负载在旧节点销毁到新节点就绪之间不可用。

---

## 操作顺序

```
1. 前置检查（GPU pod、节点状态、GPU 资源）
2. Cordon + Drain 旧节点（驱逐 GPU pod，停机开始）
3. 销毁旧 VM（释放 GPU PCI 设备）
4. 部署新 GPU worker VM（绑定同一 GPU）
5. 初始化并加入集群
6. 验证 GPU 就绪（停机结束）
7. 清理旧节点（kubeadm reset, delete node）
```

---

## 与普通 worker 的主要区别

- 使用 `k8s-gpu-node` 类型部署，Ignition 走 uCore 自动 rebase（3 次重启）
- `deploy_finalize` 自动配置 GPU PCI 直通、host-passthrough CPU、memfd 共享内存、virtiofs
- **必须先销毁旧 VM 释放 GPU，再部署新 VM**——无法并行替换
- 加入集群后需验证 NVIDIA GPU Operator 在新节点上正常工作
- GPU 工作负载在 Step 3 到 Step 5 之间完全不可用

---

## Step 1：前置检查

```bash
kubectl get nodes -l nvidia.com/gpu.present=true
# 确认旧 GPU 节点名称

kubectl get pods -A -o wide | grep <old-gpu-node>
# 记录旧节点上运行的 GPU pod（用于后续恢复验证）

# 确认 GPU Operator 组件正常
kubectl get pods -n gpu-operator

# 记录 GPU 型号和数量（用于新节点验证对比）
kubectl describe node <old-gpu-node> | grep nvidia.com/gpu
```

---

## Step 2：Cordon + Drain 旧节点（停机开始）

> 从这一步开始 GPU 工作负载不可用。

```bash
kubectl cordon <old-gpu-node>
kubectl drain <old-gpu-node> --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

驱逐完成后确认旧节点上不再有 GPU pod。

---

## Step 3：销毁旧 VM（释放 GPU）

SSH 到旧节点执行 kubeadm reset：

```bash
sudo kubeadm reset -f
```

在宿主机上销毁 VM：

```bash
sudo virsh destroy <old-gpu-node>   # VM 可能仍在运行，先强制关机
sudo virsh undefine --domain <old-gpu-node> \
  --managed-save --remove-all-storage \
  --snapshots-metadata --checkpoints-metadata \
  --nvram --tpm
```

> `undefine` 后 GPU PCI 设备回到宿主机，可被新 VM 绑定。

---

## Step 4：部署新 GPU worker VM

### 4a. 配置

`K8S_GPU_DEVICES` 填入与旧节点相同的 GPU PCI 地址（宿主机上 `lspci -nn | grep -i nvidia` 确认）：

```bash
cp bootstrap/k8s-gpu-node/.env.example bootstrap/k8s-gpu-node/.env
# 编辑 .env：
#   K8S_PASSWORD_HASH=<openssl passwd -6 输出>
#   K8S_SSH_PUB_KEY=<公钥>
#   K8S_HOSTNAME=<new-gpu-node-hostname>
#   K8S_GPU_DEVICES="<PCI 地址>"    # 与旧节点相同，旧 VM 已销毁故可用
#   K8S_VIRTIOFS_SOURCE="<host 模型缓存路径>"
```

### 4b. 部署 VM

```bash
bash bootstrap/vm-deploy.sh --type k8s-gpu-node \
  --name <new-gpu-node> --cpus 16 --memory 32768 --disk-size 64
```

部署流程：

1. VM 启动，Ignition 注入
2. uCore 自动 rebase（unsigned → signed），两次重启
3. 安装 k8s 包（cri-o + kubernetes），一次重启
4. `deploy_finalize`：停止 VM → 绑定 GPU PCI 设备、virtiofs、CPU host-passthrough、memfd 共享内存 → 重启 VM

全程约 6-7 分钟，无需手动干预。

---

## Step 5：初始化并加入集群

### 5a. 获取 join 凭据

在任一 control-plane 节点上：

```bash
sudo kubeadm token create --print-join-command
# 记录 TOKEN 和 CA_HASH
```

### 5b. 初始化并加入

SSH 到新节点（等所有 rebase 完成后）。需要 `bootstrap/kubeadm/` 脚本——scp 或 clone：

```bash
sudo bash bootstrap/kubeadm/init-node.sh
sudo bash bootstrap/kubeadm/join-worker.sh \
  --token "${TOKEN}" \
  --hash "${CA_HASH}" \
  --endpoint "control-plane.k8s.junjie.pro:6443"
```

> `init-node.sh` 对 GPU 节点禁用 zram swap、配置 firewalld 端口。

---

## Step 6：验证 GPU 就绪（停机结束）

```bash
# 节点加入并 Ready
kubectl get nodes -l nvidia.com/gpu.present=true

# GPU Operator 组件部署到新节点
kubectl get pods -n gpu-operator -o wide | grep <new-gpu-node>

# GPU 资源可分配（数量、型号应与 Step 1 记录的旧节点一致）
kubectl describe node <new-gpu-node> | grep nvidia.com/gpu

# 运行 GPU 测试 pod
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.6.3-base-ubi9 \
  --overrides='{"spec":{"nodeName":"<new-gpu-node>"}}' \
  -- nvidia-smi
```

GPU 测试通过后，GPU 工作负载可以恢复。之前被驱逐的 pod（Deployment/StatefulSet 管理的）会自动调度到新节点。

---

## Step 7：清理

```bash
# 从集群移除旧节点记录
kubectl delete node <old-gpu-node>
kubectl get nodes    # 确认已移除

# 旧 VM 已在 Step 3 销毁，确认 virsh list --all 中已不存在
sudo virsh list --all | grep <old-gpu-node> || echo "[OK] 已清理"
```

---

## 故障恢复

### GPU 设备不可见

```bash
# 在 GPU 节点上检查
lspci -nn | grep -i nvidia
nvidia-smi

# 检查 GPU Operator pod 日志
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset
```

### PCI 直通配置失败

```bash
# 宿主机确认 IOMMU
sudo dmesg | grep -i iommu

# 确认 vfio-pci 驱动已绑定（旧 VM 销毁后 GPU 应回到宿主机）
ls /sys/bus/pci/drivers/vfio-pci/

# 如果旧 VM 未完全销毁，强制停止并清理
sudo virsh destroy <old-gpu-node>
sudo virsh undefine --domain <old-gpu-node> \
  --managed-save --remove-all-storage \
  --snapshots-metadata --checkpoints-metadata \
  --nvram --tpm
```

### 旧节点 GPU pod 不释放

```bash
# 强制删除卡住的 pod
kubectl delete pod <stuck-pod> -n <namespace> --force --grace-period=0
```

### 新 VM GPU 绑定失败：设备被占用

如果 `deploy_finalize` 报 GPU PCI 设备已被占用：

```bash
# 确认旧 VM 已完全销毁
sudo virsh list --all | grep <old-gpu-node>

# 检查 vfio-pci 是否仍绑定在旧 VM 驱动的设备上
ls /sys/bus/pci/drivers/vfio-pci/ | while read addr; do
  echo -n "$addr: "
  cat /sys/bus/pci/drivers/vfio-pci/$addr/iommu_group/devices 2>/dev/null
done

# 必要时手动解绑
echo 0000:41:00.0 | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
```
