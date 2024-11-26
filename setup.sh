#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
            echo -e "${RED}Error: Prefix must contain only letters, numbers, and hyphens${NC}"
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
            echo -e "${RED}Error: Password must be at least 8 characters long${NC}"
        fi
    done

    echo -e "\n${GREEN}All inputs collected successfully!${NC}"
    echo -e "\nProceeding with deployment using:"
    echo -e "  Region: ${YELLOW}$AWS_REGION${NC}"
    echo -e "  Prefix: ${YELLOW}$PROJECT_PREFIX${NC}"
    echo -e "  Password: ${YELLOW}[HIDDEN]${NC}\n"
    
    echo -n "Press Enter to continue or Ctrl+C to cancel..."
    read

    # Export variables
    export AWS_REGION
    export PROJECT_PREFIX
    export MONGODB_PASSWORD

    # Get AWS Account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ $? -ne 0 ]; then
        error "Failed to get AWS Account ID. Please ensure AWS credentials are configured."
        exit 1
    fi
    export AWS_ACCOUNT_ID
}

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
        error "Please install required tools and try again"
        exit 1
    fi
}

setup_project() {
    log "Setting up project structure..."
    
    # Create directories
    mkdir -p kubernetes
    mkdir -p app

    # Clone Tasky repository
    log "Cloning Tasky repository..."
    git clone https://github.com/jeffthorne/tasky.git app/
    
    # Cleanup git directory
    rm -rf app/.git
}

setup_ecr() {
    log "Setting up ECR repository..."
    
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
    
    # Create repository if it doesn't exist
    aws ecr describe-repositories --repository-names ${PROJECT_PREFIX}-webapp --region $AWS_REGION || \
    aws ecr create-repository --repository-name ${PROJECT_PREFIX}-webapp --region $AWS_REGION
}

build_push_container() {
    log "Building and pushing container..."
    
    cd app
    docker build -t ${PROJECT_PREFIX}-webapp .
    docker tag ${PROJECT_PREFIX}-webapp:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/${PROJECT_PREFIX}-webapp:latest
    docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/${PROJECT_PREFIX}-webapp:latest
    cd ..
}

deploy_infrastructure() {
    log "Deploying infrastructure..."
    
    # Export Terraform variables
    export TF_VAR_project_prefix=$PROJECT_PREFIX
    export TF_VAR_mongodb_password=$MONGODB_PASSWORD
    export TF_VAR_aws_region=$AWS_REGION
    export TF_VAR_aws_account_id=$AWS_ACCOUNT_ID
    
    # Initialize and apply Terraform
    cd terraform
    terraform init
    terraform apply -auto-approve
    
    # Get outputs
    MONGODB_IP=$(terraform output -raw mongodb_ip)
    S3_BUCKET_URL=$(terraform output -raw s3_bucket_url)
    export MONGODB_IP
    export S3_BUCKET_URL
    cd ..
}

setup_kubernetes() {
    log "Configuring Kubernetes..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --name ${PROJECT_PREFIX}-eks-cluster --region $AWS_REGION
    
    # Replace variables in Kubernetes config
    envsubst < kubernetes/deployment.yaml | kubectl apply -f -
    
    # Wait for deployment
    kubectl rollout status deployment/tasky
}

print_urls() {
    log "Getting deployment URLs..."
    
    TASKY_URL=$(kubectl get service tasky-service -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    echo -e "\n${GREEN}Deployment Complete!${NC}"
    echo -e "${YELLOW}S3 Bucket URL:${NC} $S3_BUCKET_URL"
    echo -e "${YELLOW}Tasky Web Server URL:${NC} http://$TASKY_URL"
}

main() {
    clear
    echo -e "${BLUE}AWS Security Testing Infrastructure Setup${NC}\n"

    # First verify AWS credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        error "AWS credentials not configured. Please run 'aws configure' first."
        exit 1
    fi

    # Collect all inputs first
    collect_inputs

    # Now start the actual deployment with logging
    log "Starting deployment..."
    check_prerequisites
    setup_project
    setup_ecr
    build_push_container
    deploy_infrastructure
    setup_kubernetes
    print_urls
}

# Run main function
main