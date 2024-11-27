# AWS Security Testing Infrastructure

This repository sets up an intentionally misconfigured AWS infrastructure for security testing and learning purposes. It deploys a MongoDB database on EC2 and the Tasky application on EKS with several security misconfigurations.

⚠️ **WARNING**: This infrastructure contains intentional security misconfigurations. DO NOT use in production.

## Prerequisites

- Linux-based operating system
- AWS CLI configured with administrative permissions
- Terraform
- Docker
- kubectl
- jq
- git

## Quick Start

1. Clone the repository:
```bash
git clone https://github.com/CyberLAB-Admin/Simple-AWS-Env.git
cd Simple-AWS-Env
```

2. Make the scripts executable:
```bash
chmod +x setup.sh cleanup.sh
```

3. Generate an SSH key pair:
```bash
ssh-keygen -t rsa -b 4096 -f terraform/Simple-AWS-Env -N ""
```

4. Add the user to the docker group:
```bash
#You must log out and log back in again after running this command.
sudo usermod -aG docker $USER
```
5. Run the setup script:
```bash
./setup.sh
```

The script will prompt you for:
- AWS Region (default: us-west-2)
- Project prefix (used to name all AWS resources)
- MongoDB password (minimum 8 characters)

## Infrastructure Components

- VPC with public subnet
- MongoDB on EC2 with public SSH access
- EKS cluster running Tasky application
- Public S3 bucket for MongoDB backups
- AWS Config enabled

## Security Notes

This infrastructure includes several intentional security misconfigurations:
- Public S3 bucket access
- Public SSH access to MongoDB
- Excessive EC2 instance permissions
- Cluster-admin privileges for application
- Plain text credentials

## Cleanup

To remove all created resources:
```bash
./cleanup.sh
```

Enter your project prefix and AWS region when prompted.

## Project Structure
```
.
├── app/                    # Tasky application files
│   └── Dockerfile         # Container configuration
├── kubernetes/            # Kubernetes configurations
│   └── deployment.yaml    # Deployment manifests
├── terraform/             # Infrastructure as Code
│   └── main.tf           # Terraform configurations
├── setup.sh              # Deployment script
├── cleanup.sh            # Resource cleanup script
└── README.md             # This file
```

## Outputs

After deployment, the script will display:
1. S3 Bucket URL - Direct URL to access the public S3 bucket
2. Tasky Web Server URL - URL to access the Tasky application
