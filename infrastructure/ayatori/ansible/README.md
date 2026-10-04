# Ayatori 控制面部署

部署逻辑是 Ayatori 仓库的 role `panxiao81.ayatori.control_plane`，按 release tag 安装；
本目录只声明环境：主机、`ayatori_environment`、该环境的 PostgreSQL 实例，以及 Flux 同步的
GitOps 目录 `clusters/ayatori-<env>`（`ayatori_gitops`，需 role ≥ v0.1.1）。role 的行为、
组件与已知限制见 Ayatori 仓库 `deploy/README.md`。

```sh
./deploy.sh dev            # 安装 requirements-dev.yml 的 release 并部署 ayatori-dev
./deploy.sh prod --check   # 其余参数原样传给 ansible-playbook
```

执行机需要 Ansible 与 `ayatori-dev`/`ayatori-prod` 的 SSH 访问（`panxiao81`，免密 sudo）；
部署过程不读取 OpenBao 或任何凭据。

## Promotion

Dev 以 `requirements-dev.yml` 的 tag 部署并验收后，PR 把 `requirements-prod.yml` 改为同一
tag，合并后执行 `./deploy.sh prod`。

## 前置

- LXC `security.nesting=true`（`infrastructure/incus/terraform`，修改后重启实例）。
- zot `panxiao81/ayatori-manager` 仓库授权 Ayatori Release CI 身份（`apps/zot/values.yaml`）。
- OpenBao：首次部署后以 `/var/lib/k0s/pki/ca.crt` 配置 `kubernetes-ayatori-<env>` auth mount
  与 manager/ESO role（`infrastructure/openbao/terraform`）。
