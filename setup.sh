#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Log functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%dT%H:%M:%S%z')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%dT%H:%M:%S%z')] ERROR: $1${NC}" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%dT%H:%M:%S%z')] WARNING: $1${NC}"
}

# Function to collect all required inputs upfront
collect_inputs() {
    clear
    echo -e "${BLUE}=== AWS Environment Setup ===${NC}"
    echo -e "${YELLOW}Please provide the following information:${NC}\n"

    # AWS Region
    echo -n "Enter AWS Region [us-west-2]: "
    read -r AWS_REGION
    AWS_REGION=${AWS_REGION:-us-west-2}
    
    # Project Prefix
    while true; do
        echo -n "Enter project prefix [cloudsectest]: "
        read -r PROJECT_PREFIX
        PROJECT_PREFIX=${PROJECT_PREFIX:-cloudsectest}
        
        if [[ "$PROJECT_PREFIX" =~ ^[a-zA-Z0-9-]+$ ]]; then
            break
        else
            error "Prefix must contain only letters, numbers, and hyphens"
        fi
    done
    
    # MongoDB Password
    while true; do
        echo -n "Enter MongoDB password (minimum 8 characters): "
        read -s MONGODB_PASSWORD
        echo
        if [ ${#MONGODB_PASSWORD} -ge 8 ]; then
            break
        else
            error "Password must be at least 8 characters long"
        fi
    done

    echo -e "\n${GREEN}All inputs collected successfully!${NC}"
    echo -e "\nProceeding with deployment using:"
    echo -e "  Region: ${YELLOW}$AWS_REGION${NC}"
    echo -e "  Prefix: ${YELLOW}$PROJECT_PREFIX${NC}"
    echo -e "  Password: ${YELLOW}[HIDDEN]${NC}\n"
    
    echo -n "Press Enter to continue or Ctrl+C to cancel..."
    read

    # Get AWS Account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) || error "Failed to get AWS Account ID"
    
    # Export variables
    export AWS_REGION
    export PROJECT_PREFIX
    export MONGODB_PASSWORD
    export AWS_ACCOUNT_ID
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    local REQUIRED_TOOLS="aws terraform docker kubectl jq git"
    local MISSING_TOOLS=()
    local CURRENT_USER=$(whoami)

    for tool in $REQUIRED_TOOLS; do
        if ! command -v $tool &> /dev/null; then
            MISSING_TOOLS+=($tool)
        fi
    done

    if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
        error "Missing required tools: ${MISSING_TOOLS[*]}"
    fi

    # Check Docker permissions
    if ! docker info &>/dev/null; then
        error "Docker permission denied. Please ensure you have Docker installed and your user is in the docker group.
        
Run this command to fix:
    sudo usermod -aG docker ${CURRENT_USER}
    newgrp docker
        
Note: You may need to log out and log back in for changes to take effect."
    fi
}

setup_project() {
    log "Setting up project structure..."
    
    # Create necessary directories
    mkdir -p terraform app kubernetes || error "Failed to create project directories"
    
    # Generate SSH key if it doesn't exist
    if [ ! -f "terraform/Simple-AWS-Env.pub" ]; then
        log "Generating SSH key pair..."
        ssh-keygen -t rsa -b 4096 -f terraform/Simple-AWS-Env -N "" || error "Failed to generate SSH key"
    fi
    
    log "Cloning Tasky repository into a temporary directory..."
    git clone https://github.com/jeffthorne/tasky.git /tmp/tasky || error "Failed to clone Tasky repository"
    
    log "Copying contents to the app directory..."
    cp -r /tmp/tasky/* app/ || error "Failed to copy contents to app directory"
    
    log "Cleaning up temporary directory..."
    rm -rf /tmp/tasky || error "Failed to clean up temporary directory"
    
    log "Cleaning up git directory..."
    rm -rf app/.git || error "Failed to clean up git directory"
}

setup_ecr() {
    log "Setting up ECR repository..."
    
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com || error "Failed to authenticate with ECR"
    
    # Create repository if it doesn't exist
    aws ecr describe-repositories --repository-names ${PROJECT_PREFIX}-webapp --region $AWS_REGION || \
    aws ecr create-repository --repository-name ${PROJECT_PREFIX}-webapp --region $AWS_REGION || \
    error "Failed to create ECR repository"
}

build_push_container() {
    log "Building and pushing container..."
    
    cd app || error "Failed to change to app directory"
    
    docker build -t ${PROJECT_PREFIX}-webapp . || error "Docker build failed"
    docker tag ${PROJECT_PREFIX}-webapp:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/${PROJECT_PREFIX}-webapp:latest || error "Docker tag failed"
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/${PROJECT_PREFIX}-webapp:latest || error "Docker push failed"
    
    cd .. || error "Failed to return to root directory"
}

deploy_infrastructure() {
    log "Deploying infrastructure..."
    
    cd terraform || error "Failed to change to terraform directory"
    
    # Export Terraform variables
    export TF_VAR_project_prefix=$PROJECT_PREFIX
    export TF_VAR_mongodb_password=$MONGODB_PASSWORD
    export TF_VAR_aws_region=$AWS_REGION
    export TF_VAR_aws_account_id=$AWS_ACCOUNT_ID
    
    # Initialize Terraform
    terraform init || error "Terraform init failed"
    
    # Function to import a resource if it exists
    import_if_exists() {
        RESOURCE_TYPE=$1
        RESOURCE_NAME=$2
        IMPORT_ID=$3
        
        if aws $RESOURCE_TYPE describe $RESOURCE_NAME --region $AWS_REGION &>/dev/null; then
            log "Importing existing $RESOURCE_TYPE: $RESOURCE_NAME"
            terraform import $RESOURCE_TYPE.$RESOURCE_NAME $IMPORT_ID || warn "Failed to import $RESOURCE_TYPE: $RESOURCE_NAME"
        else
            log "$RESOURCE_TYPE $RESOURCE_NAME does not exist. It will be created."
        fi
    }
    
    # Import existing resources
    import_if_exists "s3api head-bucket --bucket" "aws_s3_bucket.db_backups" "${PROJECT_PREFIX}-db-backups"
    import_if_exists "ec2 describe-key-pairs --key-name" "aws_key_pair.mongodb_key" "Simple-AWS-Env"
    import_if_exists "iam get-role --role-name" "aws_iam_role.ec2_role" "${PROJECT_PREFIX}-ec2-role"
    import_if_exists "iam get-instance-profile --instance-profile-name" "aws_iam_instance_profile.ec2_profile" "${PROJECT_PREFIX}-ec2-profile"
    import_if_exists "eks describe-cluster --name" "module.eks.aws_eks_cluster.this[0]" "${PROJECT_PREFIX}-eks-cluster"
    
    # Apply Terraform configuration
    terraform apply -auto-approve || error "Terraform apply failed"
    
    # Get outputs
    MONGODB_IP=$(terraform output -raw mongodb_ip)
    S3_BUCKET_URL=$(terraform output -raw s3_bucket_url)
    export MONGODB_IP
    export S3_BUCKET_URL
    
    cd ..
}

setup_kubernetes() {
    log "Configuring Kubernetes..."
    
    aws eks update-kubeconfig --name ${PROJECT_PREFIX}-eks-cluster --region $AWS_REGION || \
    error "Failed to update kubeconfig"
    
    envsubst < kubernetes/deployment.yaml | kubectl apply -f - || \
    error "Failed to apply Kubernetes configuration"
    
    # Add debugging steps
    sleep 30  # Give pods time to start
    log "Checking pod status..."
    kubectl get pods
    kubectl describe pods -l app=tasky
    
    kubectl rollout status deployment/tasky || {
        warn "Deployment failed, checking logs..."
        kubectl logs -l app=tasky
        error "Failed to deploy Tasky application"
    }
}

print_urls() {
    log "Getting deployment URLs..."
    
    TASKY_URL=$(kubectl get service tasky-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}') || \
    error "Failed to get Tasky URL"
    
    echo -e "\n${GREEN}Deployment Complete!${NC}"
    echo -e "${YELLOW}S3 Bucket URL:${NC} $S3_BUCKET_URL"
    echo -e "${YELLOW}Tasky Web Server URL:${NC} http://$TASKY_URL"
}

main() {
    clear
    echo -e "${BLUE}AWS Security Testing Infrastructure Setup${NC}\n"

    # First verify AWS credentials
    aws sts get-caller-identity &>/dev/null || \
    error "AWS credentials not configured. Please run 'aws configure' first."

    # Run each step, checking for errors
    check_prerequisites
    collect_inputs
    setup_project
    setup_ecr
    build_push_container
    deploy_infrastructure
    setup_kubernetes
    print_urls
}

# Run main function
main