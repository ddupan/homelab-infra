# Chef cookbook registry served as static files: https://s3.lab.ddupan.top/chef-supermarket.
# Policyfile `default_source :supermarket` only reads `<url>/universe` (the dependency graph with a
# download_url per version) and then downloads those tarballs, so a bucket is a complete supermarket.
# Artifact Keeper's Chef format was tried first and cannot serve this: it has no /universe route.
# Written by homelab-cookbooks publish.yml (OpenBao role ci-chef-supermarket-publisher).
#
# No HTTPRoute of its own, unlike terraform-registry: provider addresses embed a hostname, policies
# just take a URL. Reads are anonymous and GetObject only; cookbooks are public source anyway.
resource "aws_s3_bucket_policy" "chef_supermarket" {
  bucket = aws_s3_bucket.this["chef-supermarket"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AnonymousRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.this["chef-supermarket"].arn}/*"
    }]
  })
}

resource "aws_iam_user" "chef_supermarket_publisher" {
  name = "chef-supermarket-publisher"
}

resource "aws_iam_user_policy" "chef_supermarket_publisher" {
  name = "chef-supermarket-publisher"
  user = aws_iam_user.chef_supermarket_publisher.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      # Read-modify-write of universe needs Get; versions are immutable, so no Delete.
      Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.this["chef-supermarket"].arn,
        "${aws_s3_bucket.this["chef-supermarket"].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_access_key" "chef_supermarket_publisher" {
  user = aws_iam_user.chef_supermarket_publisher.name
}

resource "vault_kv_secret_v2" "chef_supermarket_publisher" {
  mount = "kv"
  name  = "k8s/chef-supermarket-s3-publisher"
  data_json = jsonencode({
    access_key = aws_iam_access_key.chef_supermarket_publisher.id
    secret_key = aws_iam_access_key.chef_supermarket_publisher.secret
  })
}
