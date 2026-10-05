# Terraform provider registry served as static files (https://terraform.lab.ddupan.top, see
# ../httproute-terraform-registry.yaml): discovery document, versions index, per-platform download
# documents, zips, SHA256SUMS and its GPG signature, uploaded by the provider repositories' release
# jobs (OpenBao role ci-terraform-registry-publisher).
#
# Reads are anonymous by bucket policy and limited to GetObject: no listing, no writes. Everything in
# the bucket is public by design (it is what `terraform init` downloads), so nothing else may go here.
resource "aws_s3_bucket_policy" "terraform_registry" {
  bucket = aws_s3_bucket.this["terraform-registry"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AnonymousRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.this["terraform-registry"].arn}/*"
    }]
  })
}

resource "aws_iam_user" "terraform_registry_publisher" {
  name = "terraform-registry-publisher"
}

resource "aws_iam_user_policy" "terraform_registry_publisher" {
  name = "terraform-registry-publisher"
  user = aws_iam_user.terraform_registry_publisher.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      # Read-modify-write of the versions index needs Get; releases are never deleted.
      Action = ["s3:Get*", "s3:Put*", "s3:List*"]
      Resource = [
        aws_s3_bucket.this["terraform-registry"].arn,
        "${aws_s3_bucket.this["terraform-registry"].arn}/*",
      ]
    }]
  })
}

resource "aws_iam_access_key" "terraform_registry_publisher" {
  user = aws_iam_user.terraform_registry_publisher.name
}

resource "vault_kv_secret_v2" "terraform_registry_publisher" {
  mount = "kv"
  name  = "k8s/terraform-registry-s3-publisher"
  data_json = jsonencode({
    access_key = aws_iam_access_key.terraform_registry_publisher.id
    secret_key = aws_iam_access_key.terraform_registry_publisher.secret
  })
}
