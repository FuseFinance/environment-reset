#!/bin/bash

###############################################################################
# Check Deployment Status
#
# Quick diagnostic script to see which services are deployed in a namespace
#
# Usage:
#   ./check-deployment-status.sh <client> <environment>
#
# Example:
#   ./check-deployment-status.sh onb-1 sandbox
###############################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ $# -lt 2 ]; then
    echo "Usage: $0 <client> <environment>"
    echo ""
    echo "Example:"
    echo "  $0 onb-1 sandbox"
    exit 1
fi

CLIENT=$1
ENVIRONMENT=$2
NAMESPACE="${CLIENT}-${ENVIRONMENT}"

echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  Deployment Status Check${NC}"
echo -e "${BLUE}  Namespace: $NAMESPACE${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Check namespace exists
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo -e "${RED}✗ Namespace '$NAMESPACE' not found${NC}"
    echo ""
    echo "Available namespaces matching '$CLIENT':"
    kubectl get namespaces | grep -E "(NAME|$CLIENT)" || echo "  (none found)"
    exit 1
fi

echo -e "${GREEN}✓ Namespace exists${NC}"
echo ""

# Check each service
SERVICES=("data-builder-api" "los-core-api" "los-integrations" "sequence-builder-api" "ui-builder-api" "workflow-api")

echo "Service Deployment Status:"
echo ""

for service in "${SERVICES[@]}"; do
    # Try primary selector
    pod=$(kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$pod" ]; then
        # Try alternative selector
        pod=$(kubectl get pods -n "$NAMESPACE" -l "app=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [ -n "$pod" ]; then
        # Get pod status
        status=$(kubectl get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

        if [ "$status" = "Running" ]; then
            echo -e "  ${GREEN}✓${NC} $service: ${GREEN}$status${NC} ($pod)"
        else
            echo -e "  ${YELLOW}⚠${NC} $service: ${YELLOW}$status${NC} ($pod)"
        fi
    else
        echo -e "  ${RED}✗${NC} $service: ${RED}NOT DEPLOYED${NC}"
    fi
done

echo ""
echo "Full pod list:"
kubectl get pods -n "$NAMESPACE"

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
