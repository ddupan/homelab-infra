# tfstate 异地备份（../tfstate-backup.yaml）读 state 用的身份。只读且只限 tfstate bucket。
# 这个身份等于能读全部 root 的 state，所以密钥进 Bao 后只同步到 seaweedfs 命名空间。
locals {
  tfstate_backup_user = "tfstate-backup"
}

resource "aws_iam_user" "tfstate_backup" {
  name = local.tfstate_backup_user
}

resource "aws_iam_user_policy" "tfstate_backup" {
  name = local.tfstate_backup_user
  user = aws_iam_user.tfstate_backup.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:Get*", "s3:List*"]
      Resource = [
        aws_s3_bucket.this["tfstate"].arn,
        "${aws_s3_bucket.this["tfstate"].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_access_key" "tfstate_backup" {
  user = aws_iam_user.tfstate_backup.name
}

resource "vault_kv_secret_v2" "tfstate_backup_source" {
  mount = "kv"
  name  = "k8s/tfstate-backup-source"
  data_json = jsonencode({
    access_key = aws_iam_access_key.tfstate_backup.id
    secret_key = aws_iam_access_key.tfstate_backup.secret
  })
}
