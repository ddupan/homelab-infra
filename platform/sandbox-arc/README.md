# ARC（GitHub Actions 自托管 runner）

GitHub 上 `ddupan` org 的自托管 runner，跑在 sandbox 集群。官方 actions-runner-controller
（gha-runner-scale-set 模式），只写配置不改代码：

- `arc-systems`：controller（HelmRelease `arc`）。
- `arc-runners`：runner scale set `homelab`，workflow 写 `runs-on: homelab`。每个 job 一个一次性
  Pod，dind 模式（runner 旁边一个 privileged `docker:dind` sidecar，用于 `docker build`）。

## 谁能用

org 的 runner group `homelab` 决定哪些仓库能用这个 scale set；公开仓库必须在 group 设置里显式放行。
org 设置要求外部贡献者的 workflow 经批准才运行。runner Pod 的网络不做出站白名单：chef、Ansible
这类 job 需要访问整个 LAN，与 Gitea 的 dynamic-runner executor 相同。

## 镜像

runner 用 [ddupan/arc-runner-image](https://github.com/ddupan/arc-runner-image)：官方 actions-runner 加
Python 3、Node 24、zip、make，按 digest 固定。官方镜像不带工具链，每个 job 现装要经 WAN；节点本地的
tool cache 没有人清理，镜像则由 kubelet 的镜像 GC 回收。特定版本仍由 job 自己 `actions/setup-*`。

## 凭据

GitHub App（org `ddupan`，只有 Organization → Self-hosted runners 读写），Bao `kv/k8s/arc-github-app`：
`app_id`、`installation_id`、`private_key`，经 ESO 进 `arc-runners/arc-github-app`。它只用于管理
scale set 和签发 JIT runner 配置，不能读写仓库。

job 的身份不来自这里：homelab 服务要的 SPIFFE 身份由 spire-identity-exchange 用 runner Pod 的
PSAT + GitHub OIDC token 换取（后续接入）。

## 固定版本

chart 把 dind sidecar 写死为 `docker:dind`，values 改不了，HelmRelease 用 post-render patch 换成
`docker:29-dind@sha256:…`：大版本固定、digest 由 Renovate 自动合并（同 Docker Hub 浮动 tag 的规则），
29.x 的补丁自动跟上且有记录，换大版本才需要人看。不写死成无版本 tag：IfNotPresent 下各节点停在
各自第一次拉到的版本，并会无声跨大版本。`# renovate: image` 让 Renovate 跟踪它和 runner 镜像。
