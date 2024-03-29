variable "ssh_public_key" {}
variable "short_sha" {}

locals {
  is_prod            = terraform.workspace == "prod" ? true : false
  release_bucket     = "${terraform.workspace}-cmd-release"
  backup_bucket      = "${terraform.workspace}-cmd-backups"
  bootstrap_fname    = "bootstrap.sh"
  serve_artifact     = "s3://${local.release_bucket}/serve"
  ro_volume_artifact = "s3://${local.release_bucket}/ro_volume.tar.gz"
  bootstrap_artifact = "s3://${local.release_bucket}/${local.bootstrap_fname}"
  backup_artifact    = "s3://${local.backup_bucket}/db.sqlite3.bak.gz"
}

data "template_file" "userdata" {
  template = file("${path.module}/userdata.tpl")
  vars = {
    bootstrap_artifact = local.bootstrap_artifact
    bootstrap_fname    = local.bootstrap_fname
    bootstrap_sha      = sha1(data.template_file.bootstrap.rendered)
    backup_artifact    = local.backup_artifact
  }
}

data "template_file" "bootstrap" {
  template = file("${path.module}/bootstrap.tpl")
  vars = {
    serve_artifact     = local.serve_artifact
    ro_volume_artifact = local.ro_volume_artifact
    backup_artifact    = local.backup_artifact
    cmd_image_tag      = local.is_prod ? "prod" : "testing"
    cmd_extra_opts     = local.is_prod ? "-rateLimit" : ""
  }
}

resource "aws_s3_bucket" "release" {
  bucket = local.release_bucket
  acl    = "private"
  # force_destroy = true
  tags = {
    Env = terraform.workspace
  }
}

resource "aws_s3_bucket_object" "bootstrap" {
  bucket  = aws_s3_bucket.release.bucket
  key     = local.bootstrap_fname
  content = data.template_file.bootstrap.rendered
}

resource "aws_s3_bucket" "backups" {
  bucket = local.backup_bucket
  acl    = "private"
  # force_destroy = true

  tags = {
    Env = terraform.workspace
  }
}

resource "aws_key_pair" "default" {
  key_name   = "${terraform.workspace}-cmd"
  public_key = file(var.ssh_public_key)
}

resource "aws_security_group" "default" {
  name        = "${terraform.workspace}-cmd"
  description = "Security group that allows ssh"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8181
    to_port     = 8181
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "default" {
  name = "${terraform.workspace}-cmd"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

  tags = {
    Env = terraform.workspace
  }
}

resource "aws_iam_instance_profile" "default" {
  name = "${terraform.workspace}-cmd"
  role = aws_iam_role.default.name
}

resource "aws_iam_role_policy" "default" {
  name = "${terraform.workspace}-cmd"
  role = aws_iam_role.default.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "s3:*"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_instance" "default" {
  user_data            = data.template_file.userdata.rendered
  iam_instance_profile = aws_iam_instance_profile.default.name
  lifecycle {
    create_before_destroy = true
  }
  ami = "ami-087c17d1fe0178315" # base AMI
  # ami             = "ami-0c6e5082cb2f30d7f" # cmd-20210918
  instance_type   = "t3.micro"
  security_groups = [aws_security_group.default.name]
  key_name        = aws_key_pair.default.key_name

  tags = {
    Env = terraform.workspace
  }
}

resource "aws_eip" "default" {
  instance = aws_instance.default.id
}

resource "aws_route53_record" "default" {
  zone_id = "Z3TFJ1MMW7EJ7R"
  name    = "${terraform.workspace}.ec2.cmdchallenge.com"
  type    = "A"
  ttl     = "60"
  records = [aws_eip.default.public_ip]
}

output "public_dns" {
  value = aws_route53_record.default.fqdn
}

output "public_ip" {
  value = aws_eip.default.public_ip
}
