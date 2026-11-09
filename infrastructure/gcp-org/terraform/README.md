# GCP 组织级配置

组织 `panxiao81-pp-org` 的授权。本地运行，不进 CI：CI 的 `terraform-ci` 只有项目权限。
需要 `gcloud auth application-default login`，经 `.gitea/scripts/tf.py` 运行，步骤同 `../../gcp-ci/terraform/README.md`。
