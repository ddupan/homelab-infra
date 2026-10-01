# kata-lab

`kata-lab` 是位于 Proxmox `pve2` 的可销毁验证环境，用来验证 nested KVM、k3s、
Kata Containers，以及后续一 job 一 Kata Pod 的 Gitea Runner。它不是 dev/stg
长期服务，也不承载持久数据。

> 状态：VMID 147 已于 2026-09-14 销毁，Terraform state 为空。目录保留首次验证结果
> 与可复现配置；后续验证转向跨 PVE 节点的轻量 LXC worker 方案。

## Terraform bootstrap

1. 将 Proxmox API token 写入被 Git 忽略且权限为 `0600` 的
   `terraform/credentials.auto.tfvars`。
2. 取得内部 CA，并仅为当前 Terraform 进程设置 Go TLS trust：

   ```bash
   curl -fsSL https://bao.ad.ddupan.top:8200/v1/pki/ca/pem \
     -o /tmp/kata-lab-ddupan-ca.pem
   export SSL_CERT_FILE=/tmp/kata-lab-ddupan-ca.pem
   ```

3. 初始化并审阅 plan：

   ```bash
   cd infrastructure/kata-lab/terraform
   terraform init
   terraform plan
   ```

Terraform 使用 `laptop:import/noble-server-cloudimg-amd64.qcow2`（40 GiB
virtual size），在
`pve-rg-hdd` 创建 VM root disk，并把 cloud-init snippet 放到 `laptop`
datastore。VM root disk 设为 41 GiB，以容纳 PVE import 的块对齐增量。VM 使用
DHCP、`cpu.type = host`、4 vCPU 和 4 GiB 内存；cloud-init
安装 `qemu-guest-agent`、单节点 k3s，并记录 `/dev/kvm` 检查结果。

## Kata Containers

Ansible 使用 Kata Containers 4.1.0 官方 `kata-deploy` chart。配置明确选择 k3s，
只安装 `qemu-runtime-rs`，不安装额外 snapshotter，并采用 `job` 模式，安装结束后
不保留 privileged DaemonSet。默认 `RuntimeClass` 名为 `kata`。

Terraform 输出的 DHCP 地址变化时，先更新 `ansible/inventory/hosts.yml`，然后运行：

```bash
cd infrastructure/kata-lab/ansible
ansible-playbook kata.yml
ansible-playbook verify.yml
```

`verify.yml` 首先创建一个 `runtimeClassName: kata` 的短生命周期 Pod，并确认 Pod 内
看到的 Kata guest kernel 与 k3s node 的宿主 kernel 不同。随后它在另一个 Kata Pod
内启动 privileged `dockerd` sidecar，让普通 Docker client 容器通过共享网络命名空间
的 `127.0.0.1:2375` 运行一个嵌套容器。这对应后续 Gitea Runner 的目标形态：runner
直接执行 job，只在需要 Docker API 时连接同 Pod 的 daemon，而不把 Docker executor
作为 job 的外层。Kata 下共享 volume 中的 Unix socket 文件虽然双方可见，但不能跨
容器连接，因此不能在这里沿用普通 Pod 常见的 `/var/run/docker.sock` 方案；loopback
端口没有通过 Service 暴露到 Pod 外。
验证 Pod 会保留以供排查；再次运行时会先替换它们。

2026-09-13 的首次验证结果：Kata guest kernel 为 `6.18.35`，node host kernel 为
`6.8.0-90-generic`；sidecar daemon 成功运行 `busybox:1.37` 嵌套容器。Docker 27.5.1
在当前 Kata guest 中无法挂载 overlay2，自动回退到 `vfs`；功能验证通过，但正式用于
CI 前需要解决或接受其镜像层复制与磁盘性能开销。

不要提交 `credentials.auto.tfvars`、Terraform state 或 saved plan。销毁前确认目标
仍然是 VMID 147 / `kata-lab`：

```bash
terraform plan -destroy
terraform destroy
```
