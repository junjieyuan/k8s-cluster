# 控制平面升级指南

> **目标：** 将运行新版本的 control-plane 节点加入集群，替换运行旧版本的节点。
>
> **架构：** 单 control-plane + N worker。API Endpoint 通过 DNS 指向 control-plane。

---

## 操作顺序

```
1. 部署新 VM 并初始化节点
2. 集群状态 + DNS 检查
3. etcd 备份 + 生成 join 凭据
4. 新节点加入集群
5. 验证双控制平面
6. DNS 切换到新节点
7. 摘除旧节点（cordon → drain → 移除 etcd → delete）
8. 清理与验证
```

---

## Step 1：部署新 VM 并初始化

### 1a. 部署

在宿主机上执行。确保 `.env` 中 `K8S_HOSTNAME` 设置为新节点的主机名：

```bash
bash bootstrap/vm-deploy.sh --type k8s-node \
  --name <new-node> --cpus 2 --memory 4096 --disk-size 64
```

等待 VM 启动并完成 rpm-ostree 安装（约 2-3 分钟，会自动重启一次）。

### 1b. 初始化节点

SSH 到新节点，先把脚本复制过去——scp `bootstrap/kubeadm/` 目录，或在 VM 上 clone 仓库：

```bash
sudo bash bootstrap/kubeadm/init-node.sh
```

验证环境：

```bash
hostname                                    # 应与目标一致
kubeadm version --short                       # 应输出目标版本
kubelet --version                             # 应与 kubeadm 版本一致
systemctl is-active crio                     # 应输出 active
```

## Step 2：前置检查

### 2a. 集群状态

```bash
kubectl get nodes                        # 旧节点 Ready
kubectl get pods -n kube-system          # 所有系统 pod 正常
```

### 2b. DNS 解析

```bash
host control-plane.k8s.junjie.pro
# 应返回旧节点 IP
```

---

## Step 3：生成 join 凭据

在旧 control-plane 节点上执行。

### 3a. etcd 健康检查与备份

```bash
# 健康检查
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl endpoint health

# 快照备份（etcd 容器内 hostPath 挂载 /var/lib/etcd）
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl snapshot save /var/lib/etcd/pre-upgrade.db
sudo mkdir -p /var/lib/etcd/backup
sudo cp /var/lib/etcd/pre-upgrade.db /var/lib/etcd/backup/

# 验证
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl snapshot status /var/lib/etcd/pre-upgrade.db -w table
```

> ⚠️ 备份是安全网。确认文件存在且大小 > 0 再继续。

### 3b. 获取 token 和 certificate key

```bash
# 创建 token（已有 token 也可以新建）
sudo kubeadm token create --print-join-command
# 记录 TOKEN 和 CA_HASH（输出中已含 sha256: 前缀）

# 上传 control-plane 证书
sudo kubeadm init phase upload-certs --upload-certs
# 记录 CERTIFICATE_KEY
```

收集以下三个值：

| 变量 | 来源 |
|---|---|
| `TOKEN` | `kubeadm token create --print-join-command` |
| `CA_HASH` | 同上，含 `sha256:` 前缀 |
| `CERT_KEY` | `kubeadm init phase upload-certs --upload-certs` |

---

## Step 4：新节点加入集群

在新节点上执行。DNS 仍指向旧节点，join 通过旧节点完成。需要本仓库的 `bootstrap/kubeadm/` 目录——scp 到 VM 或直接 clone：

```bash
sudo bash bootstrap/kubeadm/join-control-plane.sh \
  --token "${TOKEN}" \
  --hash "${CA_HASH}" \
  --endpoint "control-plane.k8s.junjie.pro:6443" \
  --certificate-key "${CERT_KEY}"
```

等待几分钟，新节点拉取证书并启动 etcd、apiserver、controller-manager、scheduler 静态 pod。

---

## Step 5：验证双控制平面

```bash
# 节点状态
kubectl get nodes
# 应看到两个 control-plane 节点 Ready

# 如果新节点缺少 role label
kubectl label node <new-node> node-role.kubernetes.io/control-plane= --overwrite

# etcd 成员（任一 control-plane 上执行）
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl member list
# 应列出两个成员

# apiserver 实例
kubectl get pods -n kube-system -l component=kube-apiserver
# 应看到两个 pod
```

---

## Step 6：DNS 切换

### 6a. 加入新 IP（双写）

为 `control-plane.k8s.junjie.pro` 添加新节点的 A 记录。此时两个 IP 同时解析，无论命中哪个都能正常工作。

验证新节点 API server 可达：

```bash
curl -sk https://<new-node-ip>:6443 > /dev/null && echo "OK" || echo "FAIL"
```

### 6b. 移除旧 IP

确认新节点稳定后（建议观察数小时），删除旧节点的 A 记录。

```bash
host control-plane.k8s.junjie.pro
# 应只返回新节点 IP
```

---

## Step 7：摘除旧节点

> **前提：** DNS 只解析到新节点，且新节点 Ready。

### 7a. Cordon + Drain

```bash
kubectl cordon <old-node>
kubectl drain <old-node> --ignore-daemonsets --delete-emptydir-data --timeout=600s
```

> `--ignore-daemonsets` 跳过 Cilium 等 DaemonSet。静态 pod（etcd、apiserver 等）不受 drain 影响。

如果 drain 超时：

```bash
kubectl describe pod <stuck-pod> -n kube-system
kubectl uncordon <old-node>    # 恢复调度，排查后重试
```

### 7b. 移除 etcd 成员

> **必须先移除 etcd 成员，再停止 kubelet。**

```bash
# 列出成员，找到旧节点对应的 ID
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl member list

# 移除
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl member remove <member-id>

# 确认只剩新节点
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl member list
```

### 7c. 停止旧节点 kubelet 并删除

```bash
# SSH 到旧节点
sudo systemctl stop kubelet crio

# 在可执行 kubectl 的机器上
kubectl delete node <old-node>
kubectl get nodes    # 确认只剩新节点 + workers
```

---

## Step 8：清理与验证

### 8a. 旧节点

```bash
sudo kubeadm reset -f
```

VM 可销毁或重新部署为 worker。

### 8b. 集群验证

```bash
kubectl get nodes
kubectl get pods -n kube-system | grep -E "apiserver|controller-manager|scheduler|etcd|coredns"
kubectl get pods -n kube-system -l "app.kubernetes.io/name=cilium" -o wide
```

### 8c. kube-proxy 清理（可选）

仅在 Cilium `kubeProxyReplacement=true` 时执行：

```bash
kubectl delete daemonset kube-proxy -n kube-system --ignore-not-found
```

---

## 故障恢复

### join 失败

```bash
sudo kubeadm reset -f    # 在新节点上清理
# 回到 Step 4 重试
```

### 从快照恢复 etcd

```bash
# 停掉所有 control-plane 静态 pod（移走 /etc/kubernetes/manifests），然后：
sudo crictl exec $(sudo crictl ps --name etcd -q) etcdctl snapshot restore \
  /var/lib/etcd/pre-upgrade.db --data-dir=/var/lib/etcd-backup
```
