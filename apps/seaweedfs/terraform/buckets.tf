# 现有 bucket 全部纳管。prevent_destroy：从这里删掉一行不应连带删除数据。
locals {
  buckets = toset(["public", "research", "research-data", "tfstate", "zot"])
}

resource "aws_s3_bucket" "this" {
  for_each = local.buckets
  bucket   = each.key

  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = local.buckets
  to       = aws_s3_bucket.this[each.key]
  id       = each.key
}
