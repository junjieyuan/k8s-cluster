# GPU Worker 节点升级指南

> **目标：** 用运行新版本的 GPU worker 替换旧节点，保持 GPU 工作负载连续可用。

---

## 操作顺序

```
1. 前置检查（GPU pod、节点状态）
2. 部署新 GPU worker VM
3. GPU 配置（PCI 直通、virtiofs）
4. 初始化并加入集群
5. 验证 GPU 就绪
6. 迁移 GPU 工作负载
7. 摘除旧节点（cordon → drain → delete）
8. 清理
```

---

## 与普通 worker 的主要区别

- 使用 `k8s-gpu-node` 类型部署，Ignition 走 uCore 自动 rebase（3 次重启）
- `deploy_finalize` 自动配置 GPU PCI 直通、host-passthrough CPU、memfd 共享内存、virtiofs
- 加入集群后需验证 NVIDIA GPU Operator 在新节点上正常工作
- drain 前需确认 GPU pod 已迁移

---

## Step 1：前置检查

```bash
kubectl get nodes -l nvidia.com/gpu.present=true
# 确认旧 GPU 节点列表

kubectl get pods -A -o wide | grep <old-gpu-node>
# 记录旧节点上运行的 GPU pod

# 确认 GPU Operator 组件正常
kubectl get pods -n gpu-operator
```

---

## Step 2：部署新 GPU worker VM

### 2a. 配置

```bash
cp bootstrap/k8s-gpu-node/.env.example bootstrap/k8s-gpu-node/.env
# 编辑 .env：
#   K8S_PASSWORD_HASH=<openssl passwd -6 输出>
#   K8S_SSH_PUB_KEY=<公钥>
#   K8S_HOSTNAME=<new-gpu-node-hostname>
#   K8S_GPU_DEVICES="<PCI 地址>"    # lspci -nn | grep -i nvidia
#   K8S_VIRTIOFS_SOURCE="<host 模型缓存路径>"
```

### 2b. 部署 VM

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

## Step 3：初始化并加入集群

### 3a. 获取 join 凭据

在任一 control-plane 节点上：

```bash
sudo kubeadm token create --print-join-command
# 记录 TOKEN 和 CA_HASH
```

### 3b. 初始化并加入

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

## Step 4：验证 GPU 就绪

```bash
# 节点加入并 Ready
kubectl get nodes -l nvidia.com/gpu.present=true

# GPU Operator 组件部署到新节点
kubectl get pods -n gpu-operator -o wide | grep <new-gpu-node>

# GPU 资源可分配
kubectl describe node <new-gpu-node> | grep nvidia.com/gpu

# 运行 GPU 测试 pod
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.6.3-base-ubi9 \
  --overrides='{"spec":{"nodeName":"<new-gpu-node>"}}' \
  -- nvidia-smi
```

---

## Step 5：迁移 GPU 工作负载

确认新 GPU 节点可用后，逐步将 GPU pod 从旧节点迁移到新节点。

对于有状态 pod（如推理服务），逐个重新调度：

```bash
# 驱逐旧节点上的 GPU pod
kubectl delete pod <gpu-pod> -n <namespace>
# Deployment/StatefulSet 会自动重建，调度到新节点
```

确认重建的 pod 在新节点上正常运行后再继续。

---

## Step 6：摘除旧节点

### 6a. Cordon + Drain

```bash
kubectl cordon <old-gpu-node>
kubectl drain <old-gpu-node> --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

### 6b. 删除节点

```bash
kubectl delete node <old-gpu-node>
kubectl get nodes    # 确认已移除
```

---

## Step 7：清理

SSH 到旧节点：

```bash
sudo kubeadm reset -f
```

在宿主机上销毁旧 VM：

```bash
sudo virsh destroy <old-gpu-node>
sudo virsh undefine <old-gpu-node>
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
# 宿主机关联 IOMMU
sudo dmesg | grep -i iommu
# 确认 vfio-pci 驱动已绑定
ls /sys/bus/pci/drivers/vfio-pci/
```

### 旧节点 GPU pod 不释放

```bash
# 强制删除卡住的 pod
kubectl delete pod <stuck-pod> -n <namespace> --force --grace-period=0
```
