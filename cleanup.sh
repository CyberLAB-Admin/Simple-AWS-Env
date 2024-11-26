#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Log functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%dT%H:%M:%S%z')] WARNING: $1${NC}"
}

# Confirm cleanup
echo -e "${YELLOW}This will destroy all resources created by this project.${NC}"
echo -n "Are you sure you want to continue? (y/N) "
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

# Get project prefix
echo -n -e "${YELLOW}Enter your project prefix: ${NC}"
read -r PROJECT_PREFIX

if [ -z "$PROJECT_PREFIX" ]; then
    error "Project prefix is required"
    exit 1
fi

# Get AWS region
echo -n -e "${YELLOW}Enter your AWS region [us-west-2]: ${NC}"
read -r AWS_REGION
AWS_REGION=${AWS_REGION:-us-west-2}

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ $? -ne 0 ]; then
    error "Failed to get AWS Account ID. Please ensure AWS credentials are configured."
    exit 1
fi

# Clean up Kubernetes resources
log "Cleaning up Kubernetes resources..."
aws eks update-kubeconfig --name ${PROJECT_PREFIX}-eks-cluster --region $AWS_REGION 2>/dev/null
if [ $? -eq 0 ]; then
    kubectl delete -f kubernetes/deployment.yaml 2>/dev/null || true
fi

# Clean up ECR repository
log "Cleaning up ECR repository..."
aws ecr delete-repository \
    --repository-name ${PROJECT_PREFIX}-webapp \
    --force \
    --region $AWS_REGION || true

# Clean up Terraform resources
log "Cleaning up infrastructure..."
cd terraform
terraform init
terraform destroy -auto-approve \
    -var="project_prefix=${PROJECT_PREFIX}" \
    -var="aws_region=${AWS_REGION}" \
    -var="aws_account_id=${AWS_ACCOUNT_ID}" \
    -var="mongodb_password=dummy"

log "Cleanup complete!"
