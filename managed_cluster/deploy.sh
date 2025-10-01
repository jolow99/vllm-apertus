#!/bin/bash

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

NAMESPACE="vllm"
RELEASE_NAME="vllm-apertus"

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

check_ingress_controller() {
    if ! kubectl get ingressclass nginx >/dev/null 2>&1; then
        print_warning "nginx-ingress controller not found. Installing..."
        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
        helm repo update >/dev/null 2>&1
        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace ingress-nginx \
            --create-namespace \
            --set controller.service.type=LoadBalancer
        print_info "Waiting for ingress controller to be ready..."
        kubectl wait --namespace ingress-nginx \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/component=controller \
            --timeout=300s
    fi
}

check_cert_manager() {
    if ! kubectl get namespace cert-manager >/dev/null 2>&1; then
        print_warning "cert-manager not found. Installing..."
        helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
        helm repo update >/dev/null 2>&1
        helm upgrade --install cert-manager jetstack/cert-manager \
            --namespace cert-manager \
            --create-namespace \
            --set installCRDs=true
        print_info "Waiting for cert-manager to be ready..."
        kubectl wait --namespace cert-manager \
            --for=condition=ready pod \
            --selector=app.kubernetes.io/name=cert-manager \
            --timeout=300s
    fi
}

deploy() {
    if [ ! -f ".env" ]; then
        print_error ".env file not found. Please copy .env.example to .env and fill in your values."
        exit 1
    fi

    source .env

    if [ -z "$VLLM_API_KEY" ] || [ -z "$HUGGING_FACE_HUB_TOKEN" ]; then
        print_error "VLLM_API_KEY and HUGGING_FACE_HUB_TOKEN must be set in .env file"
        exit 1
    fi

    if [ -n "$EXPECTED_KUBE_CONTEXT" ]; then
        CURRENT_CONTEXT=$(kubectl config current-context)
        if [ "$CURRENT_CONTEXT" != "$EXPECTED_KUBE_CONTEXT" ]; then
            print_warning "Switching to expected Kubernetes context: $EXPECTED_KUBE_CONTEXT"
            kubectl config use-context "$EXPECTED_KUBE_CONTEXT"
        fi
        print_info "Using Kubernetes context: $EXPECTED_KUBE_CONTEXT"
    fi

    print_info "Checking ingress controller..."
    check_ingress_controller

    print_info "Checking cert-manager..."
    check_cert_manager

    print_info "Updating Helm dependencies..."
    helm dependency update

    print_info "Creating namespace if it doesn't exist..."
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    print_info "Deploying vLLM Apertus..."
    helm upgrade --install "$RELEASE_NAME" . \
        --namespace="$NAMESPACE" \
        --create-namespace \
        --values values.yaml \
        --set "vllm-stack.servingEngineSpec.vllmApiKey=$VLLM_API_KEY" \
        --set "vllm-stack.servingEngineSpec.modelSpec[0].hf_token=$HUGGING_FACE_HUB_TOKEN" \
        --set-string "vllm-stack.routerSpec.extraArgs={--k8s-label-selector,environment=production\\,release=vllm-apertus\\,component=engine}"

    print_info "Deployment completed!"
    kubectl get svc "$RELEASE_NAME-router-service" -n "$NAMESPACE"
}

cleanup() {
    print_warning "Cleaning up vLLM Apertus deployment..."
    helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" || print_warning "Helm release not found"
    kubectl delete secret "${RELEASE_NAME}-secrets" -n "$NAMESPACE" || print_warning "Secret not found"
    print_info "Cleanup completed!"
}

case "$1" in
    --deploy) deploy ;;
    --cleanup) cleanup ;;
    *) echo "Usage: $0 [--deploy|--cleanup]"; exit 1 ;;
esac