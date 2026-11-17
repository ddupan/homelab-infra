# ci-cache bucket 已退役：Actions cache 改由 platform/dynamic-runner/cache-server.yaml 存本地盘。
# bucket 在 buckets.tf 的 for_each 里且 prevent_destroy，removed 不能指向实例，先 moved 出来再删。
# bucket 已清空；lifecycle、IAM user/policy/access key 随之删除。
moved {
  from = aws_s3_bucket.this["ci-cache"]
  to   = aws_s3_bucket.ci_cache
}

removed {
  from = aws_s3_bucket.ci_cache
}

# kv/k8s/gitea-runner-cache-s3 还在用：里面的 external_secret 是 cache-server 与 runner 的共享密钥
# （手工写入）。只放弃管理，不删；access_key/secret_key 随 IAM key 删除后失效。
removed {
  from = vault_kv_secret_v2.ci_cache
  lifecycle {
    destroy = false
  }
}
