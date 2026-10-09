# Actions cache shared by every member of the gitea-dynamic-runner pod pool
# (runner v4+ `cache.s3`): each runner serves its jobs' cache requests and keeps
# the blobs here, so a job hits the same cache whichever member runs it.
#
# The credentials reach host-mode jobs, so every pod-pool repository can read
# and write the whole bucket; that trust domain already applied to the
# cache-servers this replaces. The user is limited to this bucket.
resource "aws_s3_bucket_lifecycle_configuration" "ci_cache" {
  bucket = aws_s3_bucket.this["ci-cache"].id

  # The runner does not evict S3 caches itself; expiry replaces the old
  # cache-server's 168h retention.
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_iam_user" "ci_cache" {
  name = "gitea-runner-cache"
}

resource "aws_iam_user_policy" "ci_cache" {
  name = "gitea-runner-cache"
  user = aws_iam_user.ci_cache.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:Get*", "s3:Put*", "s3:List*", "s3:DeleteObject", "s3:AbortMultipartUpload"]
      Resource = [
        aws_s3_bucket.this["ci-cache"].arn,
        "${aws_s3_bucket.this["ci-cache"].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_access_key" "ci_cache" {
  user = aws_iam_user.ci_cache.name
}

resource "vault_kv_secret_v2" "ci_cache" {
  mount = "kv"
  name  = "k8s/gitea-runner-cache-s3"
  data_json = jsonencode({
    access_key = aws_iam_access_key.ci_cache.id
    secret_key = aws_iam_access_key.ci_cache.secret
  })
}
