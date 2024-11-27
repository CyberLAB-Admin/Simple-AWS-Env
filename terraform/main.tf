# Provider configuration
provider "aws" {
  region = var.aws_region
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_prefix}-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_prefix}-igw"
  }
}

# Public Subnets (now we create two)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = "${var.aws_region}${count.index == 0 ? "a" : "b"}"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_prefix}-public-subnet-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  }
}

# Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_prefix}-public-rt"
  }
}

# Route Table Association (updated for multiple subnets)
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# S3 Bucket for DB Backups
resource "aws_s3_bucket" "db_backups" {
  bucket = "${var.project_prefix}-db-backups"
  force_destroy = true

  lifecycle {
    prevent_destroy = false
    ignore_changes = [server_side_encryption_configuration]
  }

  tags = {
    Name = "${var.project_prefix}-db-backups"
  }
}

resource "aws_s3_bucket_public_access_block" "db_backups" {
  bucket = aws_s3_bucket.db_backups.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "allow_public_read" {
  bucket = aws_s3_bucket.db_backups.id
  depends_on = [aws_s3_bucket_public_access_block.db_backups]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.db_backups.arn}/*"
      },
    ]
  })
}

# Create SSH key pair
resource "aws_key_pair" "mongodb_key" {
  key_name   = "Simple-AWS-Env"
  public_key = file("${path.module}/Simple-AWS-Env.pub")

  lifecycle {
    ignore_changes = [public_key]
  }
}

# IAM Role for EC2
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_prefix}-ec2-role"
  
  lifecycle {
    ignore_changes = [assume_role_policy]
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "ec2_policy" {
  name = "${var.project_prefix}-ec2-policy"
  role = aws_iam_role.ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "ec2:*"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_prefix}-ec2-profile"
  role = aws_iam_role.ec2_role.name
  
  lifecycle {
    ignore_changes = [tags]
  }
}

# Security Group for MongoDB
resource "aws_security_group" "mongodb" {
  name        = "${var.project_prefix}-mongodb-sg"
  description = "Security group for MongoDB server"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH access"
  }

  ingress {
    from_port   = 27017
    to_port     = 27017
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "MongoDB access from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-mongodb-sg"
  }
}

# EC2 Instance for MongoDB (update subnet reference)
resource "aws_instance" "mongodb" {
  ami           = "ami-0735c191cf914754d"
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public[0].id
  key_name      = aws_key_pair.mongodb_key.key_name
  
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  vpc_security_group_ids = [aws_security_group.mongodb.id]
  
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y mongodb awscli

              # Configure MongoDB
              echo "bindIp: 0.0.0.0" >> /etc/mongodb.conf
              echo "security:" >> /etc/mongodb.conf
              echo "  authorization: enabled" >> /etc/mongodb.conf
              
              # Create backup script
              cat <<'BACKUP' > /root/backup.sh
              #!/bin/bash
              TIMESTAMP=$(date +%Y%m%d_%H%M%S)
              mongodump --out="/tmp/backup_$TIMESTAMP"
              tar -czf "/tmp/backup_$TIMESTAMP.tar.gz" "/tmp/backup_$TIMESTAMP"
              aws s3 cp "/tmp/backup_$TIMESTAMP.tar.gz" "s3://${var.project_prefix}-db-backups/"
              rm -rf "/tmp/backup_$TIMESTAMP" "/tmp/backup_$TIMESTAMP.tar.gz"
              BACKUP
              
              chmod +x /root/backup.sh
              
              # Add to crontab for daily backup
              (crontab -l 2>/dev/null; echo "0 0 * * * /root/backup.sh") | crontab -

              service mongodb restart
              
              # Create admin user
              mongo admin --eval 'db.createUser({user: "admin", pwd: "${var.mongodb_password}", roles: [{role: "userAdminAnyDatabase", db: "admin"}]})'
              EOF

  tags = {
    Name = "${var.project_prefix}-mongodb"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "${var.project_prefix}-eks-cluster"
  cluster_version = "1.27"

  vpc_id     = aws_vpc.main.id
  subnet_ids = aws_subnet.public[*].id

  cluster_endpoint_public_access = true

  # Configuration to handle existing resources
  manage_aws_auth_configmap = true
  create_cloudwatch_log_group = false
  create_kms_key             = false
  cluster_encryption_config   = {}

  eks_managed_node_groups = {
    main = {
      min_size     = 1
      max_size     = 3
      desired_size = 2

      instance_types = ["t3.small"]
      capacity_type  = "ON_DEMAND"
    }
  }

  tags = {
    Name = "${var.project_prefix}-eks"
    Environment = "lab"
  }
}

# Outputs
output "mongodb_ip" {
  value = aws_instance.mongodb.public_ip
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "s3_bucket_url" {
  value = "https://${aws_s3_bucket.db_backups.id}.s3.${var.aws_region}.amazonaws.com"
}