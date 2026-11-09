# Backstage TechDocs：各仓库 CI 经 OpenBao role ci-techdocs-publisher 取 publisher
# 凭据上传，Backstage 用 reader 只读。凭据由此处生成并写入 Bao，是唯一来源；
# Backstage ExternalSecret 与 ci-actions/publish-techdocs 按路径读取。
# secret key 会进入 tfstate（tfstate bucket 仅 terraform 与只读的 tfstate-backup 身份可访问）。
locals {
  techdocs_users = {
    # SeaweedFS 4.48 rejects "s3:Delete*" (MalformedPolicyDocument); Get*/Put*/List*
    # wildcards are accepted.
    publisher = ["s3:Get*", "s3:Put*", "s3:DeleteObject", "s3:List*"]
    reader    = ["s3:Get*", "s3:List*"]
  }
}

resource "aws_iam_user" "techdocs" {
  for_each = local.techdocs_users
  name     = "techdocs-${each.key}"
}

resource "aws_iam_user_policy" "techdocs" {
  for_each = local.techdocs_users
  name     = "techdocs-${each.key}"
  user     = aws_iam_user.techdocs[each.key].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = each.value
      Resource = [
        aws_s3_bucket.this["techdocs"].arn,
        "${aws_s3_bucket.this["techdocs"].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_access_key" "techdocs" {
  for_each = local.techdocs_users
  user     = aws_iam_user.techdocs[each.key].name
}

resource "vault_kv_secret_v2" "techdocs" {
  for_each = local.techdocs_users
  mount    = "kv"
  name     = "k8s/techdocs-s3-${each.key}"
  data_json = jsonencode({
    access_key = aws_iam_access_key.techdocs[each.key].id
    secret_key = aws_iam_access_key.techdocs[each.key].secret
  })
}
