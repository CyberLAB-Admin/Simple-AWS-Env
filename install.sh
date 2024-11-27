#!/bin/bash

# install.sh

set -e

# Update package lists
sudo apt-get update

# Install AWS CLI
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf aws awscliv2.zip
else
    echo "AWS CLI is already installed."
fi

# Configure AWS CLI (optional)
# Uncomment the following lines if you want to configure AWS CLI within the script
# echo "Configuring AWS CLI..."
# aws configure

# Install Terraform
if ! command -v terraform &> /dev/null; then
    echo "Installing Terraform..."
    sudo apt-get install -y gnupg software-properties-common curl
    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
    sudo add-apt-repository \
        "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    sudo apt-get update
    sudo apt-get install -y terraform
else
    echo "Terraform is already installed."
fi

# Install Docker
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get remove -y docker docker-engine docker.io containerd runc || true
    sudo apt-get install -y \
        apt-transport-https ca-certificates curl \
        gnupg-agent software-properties-common
    curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg | sudo apt-key add -
    sudo add-apt-repository \
        "deb [arch=amd64] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") \
        $(lsb_release -cs) stable"
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io
    # Add user to docker group
    sudo usermod -aG docker $USER
else
    echo "Docker is already installed."
fi

# Install kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s \
        https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
else
    echo "kubectl is already installed."
fi

# Install jq
if ! command -v jq &> /dev/null; then
    echo "Installing jq..."
    sudo apt-get install -y jq
else
    echo "jq is already installed."
fi

# Install git
if ! command -v git &> /dev/null; then
    echo "Installing git..."
    sudo apt-get install -y git
else
    echo "git is already installed."
fi

echo "All prerequisites have been installed."

echo "Please log out and log back in for Docker group changes to take effect."