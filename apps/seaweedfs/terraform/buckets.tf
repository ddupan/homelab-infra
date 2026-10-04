# 现有 bucket 全部纳管。prevent_destroy：从这里删掉一行不应连带删除数据。
# imported_buckets 是纳管前已存在的 bucket，只对它们做 import；新 bucket 加到
# local.buckets 由 Terraform 创建（对不存在的对象 import 会失败）。
locals {
  imported_buckets = toset(["public", "research", "research-data", "tfstate", "zot"])
  buckets          = setunion(local.imported_buckets, ["techdocs"])
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.key

  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = local.imported_buckets
  to       = aws_s3_bucket.this[each.key]
  id       = each.key
}
