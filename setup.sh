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

    for tool in $REQUIRED_TOOLS; do
        if ! command -v $tool &> /dev/null; then
            MISSING_TOOLS+=($tool)
        fi
    done

    if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
        error "Missing required tools: ${MISSING_TOOLS[*]}"
    fi
}

setup_project() {
    log "Setting up project structure..."
    
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
    
    # Export Terraform variables
    export TF_VAR_project_prefix=$PROJECT_PREFIX
    export TF_VAR_mongodb_password=$MONGODB_PASSWORD
    export TF_VAR_aws_region=$AWS_REGION
    export TF_VAR_aws_account_id=$AWS_ACCOUNT_ID
    
    cd terraform || error "Failed to change to terraform directory"
    
    terraform init || error "Terraform init failed"
    terraform apply -auto-approve || error "Terraform apply failed"
    
    # Get outputs
    MONGODB_IP=$(terraform output -raw mongodb_ip) || error "Failed to get MongoDB IP"
    S3_BUCKET_URL=$(terraform output -raw s3_bucket_url) || error "Failed to get S3 bucket URL"
    export MONGODB_IP
    export S3_BUCKET_URL
    
    cd .. || error "Failed to return to root directory"
}

setup_kubernetes() {
    log "Configuring Kubernetes..."
    
    aws eks update-kubeconfig --name ${PROJECT_PREFIX}-eks-cluster --region $AWS_REGION || \
    error "Failed to update kubeconfig"
    
    envsubst < kubernetes/deployment.yaml | kubectl apply -f - || \
    error "Failed to apply Kubernetes configuration"
    
    kubectl rollout status deployment/tasky || \
    error "Failed to deploy Tasky application"
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