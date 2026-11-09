# artifact-keeper 的制品存储（Go/PyPI/Galaxy 等 remote 仓库的缓存与托管制品）。
# 凭据由此处生成并写入 Bao，是唯一来源；artifact-keeper 的 ExternalSecret 按路径读取。
# secret key 会进入 tfstate（tfstate bucket 仅 terraform 与只读的 tfstate-backup 身份可访问）。
resource "aws_iam_user" "artifact_keeper" {
  name = "artifact-keeper"
}

resource "aws_iam_user_policy" "artifact_keeper" {
  name = "artifact-keeper"
  user = aws_iam_user.artifact_keeper.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      # SeaweedFS 4.48 rejects "s3:Delete*" (MalformedPolicyDocument); see techdocs.tf.
      Action = ["s3:Get*", "s3:Put*", "s3:List*", "s3:DeleteObject", "s3:AbortMultipartUpload"]
      Resource = [
        aws_s3_bucket.this["artifact-keeper"].arn,
        "${aws_s3_bucket.this["artifact-keeper"].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_access_key" "artifact_keeper" {
  user = aws_iam_user.artifact_keeper.name
}

resource "vault_kv_secret_v2" "artifact_keeper" {
  mount = "kv"
  name  = "k8s/artifact-keeper-s3"
  data_json = jsonencode({
    access_key = aws_iam_access_key.artifact_keeper.id
    secret_key = aws_iam_access_key.artifact_keeper.secret
  })
}
