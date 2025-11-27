#!/bin/bash

# Script to push n8n image to AWS ECR and setup Kubernetes authentication
# Usage: ./push-n8n-to-ecr.sh <local-image> <tag>
# Example: ./push-n8n-to-ecr.sh n8nio/n8n:latest latest
# Example: ./push-n8n-to-ecr.sh sdmdock/n8n-toolstreaming-previous:latest v1.0.0
#
# Prerequisites:
# - Docker installed and running
# - AWS CLI installed (brew install awscli)
# - kubectl installed (brew install kubectl)
# - kubectl configured to access MongoDB Kubernetes cluster
# - AWS credentials for svc-ecr-ts-tools user

set -e  # Exit on error

# Configuration
AWS_REGION="us-east-1"
ECR_ACCOUNT="795250896452"
ECR_REPO="ts-tools/n8n"
K8S_NAMESPACE="ts-tools"
K8S_SECRET_NAME="ecr-registry-secret"

# Parse arguments
if [ -z "$1" ]; then
    echo "❌ Error: Local image not specified"
    echo ""
    echo "Usage: $0 <local-image> [tag]"
    echo ""
    echo "Examples:"
    echo "  $0 n8nio/n8n:latest latest"
    echo "  $0 sdmdock/n8n-toolstreaming-previous:latest v1.0.0"
    echo "  $0 my-custom-n8n:dev staging"
    exit 1
fi

LOCAL_IMAGE="$1"
TAG="${2:-latest}"
ECR_IMAGE="${ECR_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}:${TAG}"

# Check prerequisites
echo "=========================================="
echo "Checking prerequisites..."
echo "=========================================="

# Check if Docker is installed and running
if ! command -v docker &> /dev/null; then
    echo "❌ Error: Docker is not installed"
    echo "Install Docker: https://docs.docker.com/desktop/install/mac-install/"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "❌ Error: Docker is not running"
    echo "Please start Docker Desktop"
    exit 1
fi
echo "✅ Docker is installed and running"

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI is not installed"
    echo "Install with: brew install awscli"
    exit 1
fi
echo "✅ AWS CLI is installed"

# Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "❌ Error: kubectl is not installed"
    echo "Install with: brew install kubectl"
    exit 1
fi
echo "✅ kubectl is installed"

# Check if kanopy-oidc is installed, if not offer to download it
KANOPY_OIDC_PATH="${HOME}/kanopy-oidc/bin/kanopy-oidc"
KANOPY_VERSION="v0.7.0"  # Update this to the latest version as needed

if ! [ -f "$KANOPY_OIDC_PATH" ]; then
    echo "⚠️  kanopy-oidc not found at ${KANOPY_OIDC_PATH}"
    echo ""
    read -p "Would you like to download and install kanopy-oidc ${KANOPY_VERSION}? (y/N): " -n 1 -r
    echo ""
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Downloading kanopy-oidc ${KANOPY_VERSION}..."
        
        # Detect OS and architecture
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        ARCH=$(uname -m)
        
        # Map architecture names
        if [ "$ARCH" = "x86_64" ]; then
            ARCH="amd64"
        elif [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ]; then
            ARCH="arm64"
        fi
        
        DOWNLOAD_URL="https://github.com/kanopy-platform/kanopy-oidc/releases/download/${KANOPY_VERSION}/kanopy-oidc_${OS}_${ARCH}"
        
        echo "Downloading from: ${DOWNLOAD_URL}"
        mkdir -p "${HOME}/kanopy-oidc/bin"
        
        if curl -L -o "$KANOPY_OIDC_PATH" "$DOWNLOAD_URL"; then
            chmod +x "$KANOPY_OIDC_PATH"
            echo "✅ kanopy-oidc installed successfully"
            KANOPY_AVAILABLE=true
        else
            echo "❌ Failed to download kanopy-oidc"
            echo "Please download manually from: https://github.com/kanopy-platform/kanopy-oidc/releases"
            KANOPY_AVAILABLE=false
        fi
    else
        echo "Skipping kanopy-oidc installation"
        KANOPY_AVAILABLE=false
    fi
else
    echo "✅ kanopy-oidc is installed"
    KANOPY_AVAILABLE=true
fi

# Check if kubectl is configured
if ! kubectl cluster-info &> /dev/null; then
    echo "⚠️  kubectl is not configured to access a cluster"
    
    if [ "$KANOPY_AVAILABLE" = true ]; then
        echo ""
        echo "Would you like to configure kubectl now using kanopy-oidc?"
        read -p "Select environment - (s)taging or (p)roduction: " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Ss]$ ]]; then
            CLUSTER="staging"
        elif [[ $REPLY =~ ^[Pp]$ ]]; then
            CLUSTER="prod"
        else
            echo "Invalid selection. Skipping kubectl configuration."
            KUBECTL_CONFIGURED=false
        fi
        
        if [ ! -z "$CLUSTER" ]; then
            echo "Configuring kubectl for ${CLUSTER} environment..."
            KOLD=$KUBECONFIG
            export KUBECONFIG=~/.kube/config.$CLUSTER
            mkdir -p $(dirname $KUBECONFIG)
            
            echo "Running kanopy-oidc kube setup..."
            $KANOPY_OIDC_PATH kube setup $CLUSTER > $KUBECONFIG
            
            echo "Running kanopy-oidc kube login..."
            $KANOPY_OIDC_PATH kube login
            
            echo "Setting namespace to ${K8S_NAMESPACE}..."
            kubectl config set-context $(kubectl config current-context) --namespace=${K8S_NAMESPACE}
            
            # Verify configuration worked
            if kubectl cluster-info &> /dev/null; then
                echo "✅ kubectl configured successfully for ${CLUSTER}"
                KUBECTL_CONFIGURED=true
            else
                echo "❌ kubectl configuration failed"
                export KUBECONFIG=$KOLD
                KUBECTL_CONFIGURED=false
            fi
        fi
    else
        echo ""
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted. Please install kanopy-oidc or configure kubectl manually"
            exit 1
        fi
        KUBECTL_CONFIGURED=false
    fi
else
    echo "✅ kubectl is configured"
    KUBECTL_CONFIGURED=true
fi
echo ""

echo "=========================================="
echo "n8n ECR Push Script"
echo "=========================================="
echo "AWS Region: ${AWS_REGION}"
echo "ECR Account: ${ECR_ACCOUNT}"
echo "ECR Repository: ${ECR_REPO}"
echo "Local Image: ${LOCAL_IMAGE}"
echo "ECR Image: ${ECR_IMAGE}"
echo "Tag: ${TAG}"
echo "Kubernetes Namespace: ${K8S_NAMESPACE}"
echo "Kubernetes Secret: ${K8S_SECRET_NAME}"
echo "=========================================="
echo ""

# Step 1: Configure AWS credentials
echo "Step 1: Configuring AWS credentials..."
echo ""
echo "You need AWS credentials for the svc-ecr-ts-tools IAM user."
echo "These credentials should be provided by your team lead or found in 1Password/Secrets Manager."
echo ""
echo "You will need:"
echo "  - AWS Access Key ID (e.g., AKIA...)"
echo "  - AWS Secret Access Key"
echo "  - Default region: us-east-1"
echo ""

# Check if credentials are already configured
if aws sts get-caller-identity > /dev/null 2>&1; then
    CURRENT_USER=$(aws sts get-caller-identity --query 'Arn' --output text)
    echo "Found existing AWS credentials: ${CURRENT_USER}"
    read -p "Do you want to reconfigure? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "✅ Using existing credentials"
    else
        echo ""
        echo "Running aws configure..."
        echo "Enter the following when prompted:"
        echo "  - AWS Access Key ID: [your access key]"
        echo "  - AWS Secret Access Key: [your secret key]"
        echo "  - Default region name: us-east-1"
        echo "  - Default output format: json"
        echo ""
        aws configure
    fi
else
    echo "No AWS credentials found. Running aws configure..."
    echo ""
    echo "Enter the following when prompted:"
    echo "  - AWS Access Key ID: [your access key]"
    echo "  - AWS Secret Access Key: [your secret key]"
    echo "  - Default region name: us-east-1"
    echo "  - Default output format: json"
    echo ""
    aws configure
fi

# Verify credentials
echo ""
echo "Verifying AWS credentials..."
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo "❌ Error: AWS credentials are invalid"
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity)
echo "✅ Authenticated as:"
echo "${CALLER_IDENTITY}"
echo ""

# Step 2: Login to ECR
echo "Step 2: Logging into AWS ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
echo "✅ Successfully logged into ECR"
echo ""

# Step 3: Create ECR repository if it doesn't exist
echo "Step 3: Checking if ECR repository exists..."
if aws ecr describe-repositories --repository-names ${ECR_REPO} --region ${AWS_REGION} > /dev/null 2>&1; then
    echo "✅ ECR repository '${ECR_REPO}' already exists"
else
    echo "Creating ECR repository '${ECR_REPO}'..."
    aws ecr create-repository --repository-name ${ECR_REPO} --region ${AWS_REGION}
    echo "✅ ECR repository created successfully"
fi
echo ""

# Step 4: Pull local image (if needed)
echo "Step 4: Checking for local n8n image..."
if docker image inspect ${LOCAL_IMAGE} > /dev/null 2>&1; then
    echo "✅ Local image '${LOCAL_IMAGE}' found"
else
    echo "Local image not found. Pulling from Docker Hub..."
    docker pull ${LOCAL_IMAGE}
    echo "✅ Image pulled successfully"
fi
echo ""

# Step 5: Tag image for ECR
echo "Step 5: Tagging image for ECR..."
docker tag ${LOCAL_IMAGE} ${ECR_IMAGE}
echo "✅ Image tagged as '${ECR_IMAGE}'"
echo ""

# Step 6: Push image to ECR
echo "Step 6: Pushing image to ECR..."
docker push ${ECR_IMAGE}
echo "✅ Image pushed successfully to ECR"
echo ""

# Step 7: Create Kubernetes secret for ECR authentication
if [ "$KUBECTL_CONFIGURED" = true ]; then
    echo "Step 7: Creating Kubernetes secret for ECR authentication..."
    echo "Getting ECR authorization token..."
    ECR_TOKEN=$(aws ecr get-login-password --region ${AWS_REGION})

    # Check if secret already exists and delete it
    if kubectl get secret ${K8S_SECRET_NAME} -n ${K8S_NAMESPACE} > /dev/null 2>&1; then
        echo "Deleting existing secret..."
        kubectl delete secret ${K8S_SECRET_NAME} -n ${K8S_NAMESPACE}
    fi

    # Create the secret
    kubectl create secret docker-registry ${K8S_SECRET_NAME} \
      --docker-server=${ECR_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com \
      --docker-username=AWS \
      --docker-password="${ECR_TOKEN}" \
      --namespace=${K8S_NAMESPACE}

    echo "✅ Kubernetes secret '${K8S_SECRET_NAME}' created in namespace '${K8S_NAMESPACE}'"
    echo ""
else
    echo "Step 7: Skipping Kubernetes secret creation (kubectl not configured)"
    echo ""
    echo "⚠️  To create the secret later, configure kubectl and re-run:"
    echo "  ./push-n8n-to-ecr.sh ${LOCAL_IMAGE} ${TAG}"
    echo ""
fi

echo "=========================================="
echo "✅ All steps completed successfully!"
echo "=========================================="
echo ""
echo "Image URI: ${ECR_IMAGE}"
echo ""
if [ "$KUBECTL_CONFIGURED" = true ]; then
    echo "⚠️  IMPORTANT: The Kubernetes secret expires in 12 hours"
    echo "Please deploy n8n with Helm within this time window."
    echo "After 12 hours, you'll need to recreate the secret by running:"
    echo "  ./push-n8n-to-ecr.sh ${LOCAL_IMAGE} ${TAG}"
fi
