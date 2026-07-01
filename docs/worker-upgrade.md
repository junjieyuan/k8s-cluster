# Worker 节点升级指南

> **目标：** 用运行新版本的节点替换旧 worker 节点，不中断集群服务。

---

## 操作顺序

```
1. 前置检查（集群状态、旧节点 pod）
2. 配置新节点并加入集群
3. 验证新节点就绪
4. 摘除旧节点（cordon → drain → delete）
5. 清理
```

---

## Step 1：前置检查

```bash
kubectl get nodes
kubectl get pods -n kube-system -o wide | grep <old-node>
```

记录旧节点上正在运行的 pod，后续 drain 时对照。

---

## Step 2：配置并加入新节点

### 2a. 获取 join 凭据

在任一 control-plane 节点上执行：

```bash
sudo kubeadm token create --print-join-command
# 记录 TOKEN 和 CA_HASH
```

### 2b. 配置新节点 Ignition

在宿主机上：

```bash
# 复制并编辑 .env
cp bootstrap/k8s-node/.env.example bootstrap/k8s-node/.env
# 填写 K8S_PASSWORD_HASH、K8S_SSH_PUB_KEY
# 设置 K8S_HOSTNAME=<new-node-hostname>
```

### 2c. 部署新 VM

```bash
bash bootstrap/vm-deploy.sh --type k8s-node \
  --name <new-node> --cpus 2 --memory 4096 --disk-size 64
```

等待 VM 启动并完成 rpm-ostree 安装（约 2-3 分钟，会自动重启一次）。

### 2d. 初始化并加入集群

SSH 到新节点。需要 `bootstrap/kubeadm/` 脚本——scp 到 VM 或直接 clone：

```bash
# 初始化内核模块、sysctl、启动 CRI-O 和 kubelet
sudo bash bootstrap/kubeadm/init-node.sh

# 加入集群
sudo bash bootstrap/kubeadm/join-worker.sh \
  --token "${TOKEN}" \
  --hash "${CA_HASH}" \
  --endpoint "control-plane.k8s.junjie.pro:6443"
```

---

## Step 3：验证新节点

```bash
kubectl get nodes
# 新节点应显示 Ready

# 确认系统 pod 正常调度到新节点
kubectl get pods -n kube-system -o wide | grep <new-node>

# 确认 Cilium pod 部署到新节点
kubectl get pods -n kube-system -l "app.kubernetes.io/name=cilium" -o wide | grep <new-node>
```

---

## Step 4：摘除旧节点

### 4a. Cordon + Drain

```bash
kubectl cordon <old-node>
kubectl drain <old-node> --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

如果 drain 超时：

```bash
kubectl describe pod <stuck-pod> -n <namespace>
# 排查卡住的 pod，必要时 uncordon 后重试
kubectl uncordon <old-node>
```

### 4b. 删除旧节点

```bash
kubectl delete node <old-node>
kubectl get nodes    # 确认已移除
```

---

## Step 5：清理

SSH 到旧节点：

```bash
sudo kubeadm reset -f
```

旧 VM 不再使用后，在宿主机上彻底销毁：

```bash
sudo virsh destroy <old-node>
sudo virsh undefine --domain <old-node> \
  --managed-save --remove-all-storage \
  --snapshots-metadata --checkpoints-metadata \
  --nvram --tpm
```

---

## 故障恢复

### join 失败

```bash
sudo kubeadm reset -f    # 在新节点上清理
# 回到 Step 2d 重试
```

### drain 卡住

```bash
kubectl uncordon <old-node>
# 排查后重新 cordon + drain
```
