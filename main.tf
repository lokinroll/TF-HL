terraform {
  backend "s3" {
    bucket  = "itea-lesson-7"
    key     = "tf-hl/terraform.tfstate"
    profile = "itea"
    region  = "us-east-2"
  }
}

provider "aws" {
  profile = "itea"
  region  = "us-east-2"
}

data "aws_subnet_ids" "public_subnets" {
  vpc_id = module.vpc.vpc_id
}

data "aws_security_group" "http_sg" {
  name   = "http_sg"
  vpc_id = module.vpc.vpc_id
}

data "aws_ami" "amazon_linux" {
  most_recent = true

  owners = ["amazon"]

  filter {
    name = "name"

    values = [
      "amzn-ami-hvm-*-x86_64-gp2",
    ]
  }

  filter {
    name = "owner-alias"

    values = [
      "amazon",
    ]
  }
}

module "vpc" {
  source = "./modules/terraform-aws-vpc"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-2a", "us-east-2b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true


  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}

module "http_sg" {
  source = "./modules/terraform-aws-security-group/modules/http-80"

  name        = "http-sg"
  description = "Security group with HTTP ports open for everybody (IPv4 CIDR), egress ports are all world open"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["http-80-tcp", "all-icmp"]
  egress_rules        = ["all-all"]
}


resource "aws_eip" "this" {
  vpc      = true
  instance = module.ec2.id[0]
}

locals {
  user_data = <<EOF
#!/bin/bash
yum update -y
yum install -y httpd
usermod -a -G apache ec2-user
chown -R ec2-user:apache /var/www
chmod 2775 /var/www
find /var/www -type d -exec chmod 2775 {} \;
find /var/www -type f -exec chmod 0664 {} \;
systemctl start httpd
systemctl enable httpd
INSTANCE_ID=$(curl -Ss http://169.254.169.254/latest/meta-data/instance-id)
INTERFACE=$(curl -Ss http://169.254.169.254/latest/meta-data/network/interfaces/macs/)
SUBNET_ID=$(curl -Ss http://169.254.169.254/latest/meta-data/network/interfaces/macs/$INTERFACE/subnet-id)
echo "Hello from instance $INSTANCE_ID, running in subnet $SUBNET_ID" > /var/www/html/index.html
EOF
}

module "ec2" {
  source = "./modules/terraform-aws-ec2-instance"

  instance_count = 1

  name          = "itea-terraform"
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t2."
  subnet_id     = tolist(data.aws_subnet_ids.public_subnets.ids)[0]
  #  private_ips                 = ["172.31.32.5", "172.31.46.20"]
  vpc_security_group_ids      = [module.http_sg.this_security_group_id]
  associate_public_ip_address = true

  user_data = local.user_data

  root_block_device = [
    {
      volume_type = "gp2"
      volume_size = 10
    },
  ]

  tags = {
    "Env"      = "Private"
    "Location" = "Secret"
  }
}