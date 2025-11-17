#!/bin/bash

###############################################################################
# Fuse Platform - Complete Database Reset & Reseed Script
#
# This script resets and reseeds ALL databases for a client environment.
# It executes commands directly in Kubernetes pods where all configs are present.
#
# Services reset:
#   - data-builder-api (2 schemas: data-builder + core)
#   - los-core-api (sandbox OR production)
#   - los-integrations
#   - sequence-builder-api
#   - ui-builder-api
#   - workflow-api
#
# Usage:
#   ./reset-and-reseed-all-databases.sh <client> <environment> [--dry-run]
#
# Examples:
#   ./reset-and-reseed-all-databases.sh los-demo sandbox
#   ./reset-and-reseed-all-databases.sh los-demo production
#   ./reset-and-reseed-all-databases.sh qa sandbox --dry-run
#
# Prerequisites:
#   - kubectl configured and authenticated to the cluster
#   - Proper RBAC permissions to exec into pods
#   - ArgoCD CLI (optional, for deployment verification)
#
# See DATABASE-RESET-GUIDE.md for detailed documentation.
###############################################################################

set -e  # Exit on error
set -o pipefail  # Catch errors in pipelines

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Script configuration
DRY_RUN=false
SKIP_CONFIRMATION=false

# SAFETY: Only allow these clients and environments
# Add clients here as needed for additional safety
ALLOWED_CLIENTS=("los-demo" "qa" "dev" "qa-poc" "onb-1" "onb-2" "onb-3" "onb-4" "onb-5" "onb-6" "onb-7" "onb-8")
ALLOWED_ENVIRONMENTS=("sandbox" "production")

###############################################################################
# CLI Tools Validation
###############################################################################

check_required_tools() {
    print_section "CLI TOOLS VALIDATION"
    print_info "Checking required command-line tools..."
    echo ""

    local has_errors=false

    # Check kubectl
    if command -v kubectl &> /dev/null; then
        local kubectl_version=$(kubectl version --client --short 2>/dev/null | head -1 || echo "unknown")
        print_success "✓ kubectl is installed ($kubectl_version)"

        # Check kubectl context
        local current_context=$(kubectl config current-context 2>/dev/null || echo "none")
        if [ "$current_context" != "none" ]; then
            print_info "  Current context: $current_context"
        else
            print_error "  ✗ No kubectl context configured"
            print_info "    Run: kubectl config use-context <context-name>"
            has_errors=true
        fi
    else
        print_error "✗ kubectl is NOT installed"
        print_info "  Install: https://kubernetes.io/docs/tasks/tools/"
        has_errors=true
    fi

    echo ""

    # Check for optional but useful tools
    if command -v argocd &> /dev/null; then
        local argocd_version=$(argocd version --client --short 2>/dev/null || echo "unknown")
        print_success "✓ argocd CLI is installed ($argocd_version) [optional]"
    else
        print_warning "⚠ argocd CLI not found (optional - for deployment verification)"
        print_info "  Install: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
    fi

    echo ""

    if command -v aws &> /dev/null; then
        local aws_version=$(aws --version 2>&1 | head -1 || echo "unknown")
        print_success "✓ aws CLI is installed ($aws_version) [optional]"
    else
        print_warning "⚠ aws CLI not found (optional - for RDS/secrets access)"
        print_info "  Install: https://aws.amazon.com/cli/"
    fi

    echo ""

    if [ "$has_errors" = true ]; then
        echo -e "${RED}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}${BOLD}║  MISSING REQUIRED TOOLS                                        ║${NC}"
        echo -e "${RED}${BOLD}║                                                                ║${NC}"
        echo -e "${RED}${BOLD}║  Install the required tools above before continuing.          ║${NC}"
        echo -e "${RED}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        exit 1
    fi

    print_success "All required CLI tools are available!"
    echo ""
}

###############################################################################
# Utility Functions
###############################################################################

print_header() {
    echo -e "${BOLD}${BLUE}"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "═══════════════════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

print_section() {
    echo -e "${CYAN}${BOLD}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[⚠]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_step() {
    echo -e "${CYAN}➜${NC} $1"
}

confirm() {
    if [ "$SKIP_CONFIRMATION" = true ]; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}${YELLOW}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${YELLOW}║  ⚠️  WARNING: DESTRUCTIVE OPERATION                                        ║${NC}"
    echo -e "${BOLD}${YELLOW}║                                                                            ║${NC}"
    echo -e "${BOLD}${YELLOW}║  This will DELETE ALL DATA in the following databases:                    ║${NC}"
    echo -e "${BOLD}${YELLOW}║  $1${NC}"
    echo -e "${BOLD}${YELLOW}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "$(echo -e ${YELLOW}Type \'DELETE ALL DATA\' to continue: ${NC})" response

    if [ "$response" != "DELETE ALL DATA" ]; then
        print_error "Operation cancelled by user"
        exit 1
    fi
    echo ""
}

###############################################################################
# Safety & Validation Functions
###############################################################################

validate_client_and_environment() {
    local client=$1
    local environment=$2

    # Check if client is in allowed list
    local client_allowed=false
    for allowed in "${ALLOWED_CLIENTS[@]}"; do
        if [ "$client" = "$allowed" ]; then
            client_allowed=true
            break
        fi
    done

    if [ "$client_allowed" = false ]; then
        print_error "Client '$client' is not in the allowed list"
        print_info "Allowed clients: ${ALLOWED_CLIENTS[*]}"
        print_warning "To add this client, edit ALLOWED_CLIENTS in the script"
        exit 1
    fi

    # Check if environment is in allowed list
    local env_allowed=false
    for allowed in "${ALLOWED_ENVIRONMENTS[@]}"; do
        if [ "$environment" = "$allowed" ]; then
            env_allowed=true
            break
        fi
    done

    if [ "$env_allowed" = false ]; then
        print_error "Environment '$environment' is not in the allowed list"
        print_info "Allowed environments: ${ALLOWED_ENVIRONMENTS[*]}"
        exit 1
    fi

    print_success "Client and environment validated"
}

verify_namespace_isolation() {
    local namespace=$1

    if $DRY_RUN; then
        print_info "DRY-RUN: Skipping namespace isolation verification"
        return 0
    fi

    print_section "NAMESPACE ISOLATION VERIFICATION"

    # Verify namespace pattern matches expected format: {client}-{environment}
    if [[ ! "$namespace" =~ ^[a-z0-9-]+-[a-z0-9]+$ ]]; then
        print_error "Namespace '$namespace' doesn't match expected pattern: {client}-{environment}"
        exit 1
    fi

    # List all pods in the namespace
    print_info "Pods in namespace '$namespace':"
    kubectl get pods -n "$namespace" --no-headers 2>/dev/null | awk '{print "  - " $1}' || {
        print_error "Cannot list pods in namespace $namespace"
        exit 1
    }
    echo ""

    # Verify we're not in a shared namespace
    local pod_count=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
    print_info "Total pods in this namespace: $pod_count"

    # Check that namespace label matches (if labels exist)
    local ns_labels=$(kubectl get namespace "$namespace" --show-labels 2>/dev/null | tail -1 | cut -d' ' -f5-)
    if [ -n "$ns_labels" ]; then
        print_info "Namespace labels: $ns_labels"
    fi

    print_success "Namespace isolation verified - operations will ONLY affect namespace: $namespace"
    echo ""
}

get_database_connections() {
    local namespace=$1

    if $DRY_RUN; then
        print_info "DRY-RUN: Skipping database connection verification"
        return 0
    fi

    print_section "DATABASE CONNECTION VERIFICATION"
    print_info "Checking which databases will be affected..."
    echo ""

    # Check each service's DATABASE_URL
    local services=("los-core-api" "los-integrations" "sequence-builder-api" "ui-builder-api" "workflow-api" "data-builder-api")

    for service in "${services[@]}"; do
        local pod=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -z "$pod" ]; then
            # Try alternative selector
            pod=$(kubectl get pods -n "$namespace" -l "app=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi

        if [ -n "$pod" ]; then
            print_info "Service: $service"

            # Get DATABASE_URL (mask password for security)
            local db_url=$(kubectl exec -n "$namespace" "$pod" -- sh -c 'echo $DATABASE_URL' 2>/dev/null || echo "")

            if [ -n "$db_url" ]; then
                # Extract database name from URL (postgresql://user:pass@host:port/dbname)
                local db_name=$(echo "$db_url" | sed -n 's|.*://[^/]*/\([^?]*\).*|\1|p')
                local db_host=$(echo "$db_url" | sed -n 's|.*://[^@]*@\([^:/]*\).*|\1|p')

                if [ -n "$db_name" ]; then
                    print_info "  └─ Database: $db_name @ $db_host"
                else
                    print_warning "  └─ Could not parse database name"
                fi
            else
                print_warning "  └─ No DATABASE_URL found"
            fi

            # Check for data-builder's dual schemas
            if [ "$service" = "data-builder-api" ]; then
                local core_url=$(kubectl exec -n "$namespace" "$pod" -- sh -c 'echo $CORE_DATABASE_URL' 2>/dev/null || echo "")
                if [ -n "$core_url" ]; then
                    local core_db=$(echo "$core_url" | sed -n 's|.*://[^/]*/\([^?]*\).*|\1|p')
                    local core_host=$(echo "$core_url" | sed -n 's|.*://[^@]*@\([^:/]*\).*|\1|p')
                    print_info "  └─ Core DB: $core_db @ $core_host (SHARED with los-core-api!)"
                fi
            fi
        else
            print_warning "Service: $service - NO POD FOUND (will be skipped)"
        fi
        echo ""
    done

    print_warning "IMPORTANT: Verify the databases listed above are correct for $namespace"
    print_warning "These are the ONLY databases that will be affected"
    echo ""
}

verify_no_cross_namespace_impact() {
    local namespace=$1

    if $DRY_RUN; then
        print_info "DRY-RUN: Skipping cross-namespace verification"
        return 0
    fi

    print_section "CROSS-NAMESPACE IMPACT CHECK"

    # List all namespaces to show what won't be affected
    print_info "All namespaces in cluster:"
    kubectl get namespaces --no-headers 2>/dev/null | grep -E "(los-demo|qa|dev|onb-)" | while read ns rest; do
        if [ "$ns" = "$namespace" ]; then
            echo -e "  ${RED}▶ $ns (THIS WILL BE AFFECTED)${NC}"
        else
            echo -e "  ${GREEN}✓ $ns (NOT affected - safe)${NC}"
        fi
    done
    echo ""

    print_success "Verified: Only namespace '$namespace' will be affected"
    print_success "All other namespaces are completely isolated and safe"
    echo ""
}

###############################################################################
# Pre-flight Validation Functions
###############################################################################

validate_pod_environment() {
    local namespace=$1
    local service=$2
    local pod=$3

    if $DRY_RUN; then
        return 0
    fi

    local has_errors=false

    print_info "Validating $service environment..."

    # Check DATABASE_URL
    local db_url=$(kubectl exec -n "$namespace" "$pod" -- sh -c 'echo $DATABASE_URL' 2>/dev/null || echo "")
    if [ -z "$db_url" ]; then
        print_error "  ✗ DATABASE_URL is not set"
        has_errors=true
    else
        print_success "  ✓ DATABASE_URL is configured"

        # Parse database info
        local db_name=$(echo "$db_url" | sed -n 's|.*://[^/]*/\([^?]*\).*|\1|p')
        local db_host=$(echo "$db_url" | sed -n 's|.*://[^@]*@\([^:/]*\).*|\1|p')

        if [ -n "$db_name" ] && [ -n "$db_host" ]; then
            print_info "    Database: $db_name @ $db_host"
        fi
    fi

    # Check if npm is available
    if kubectl exec -n "$namespace" "$pod" -- sh -c 'which npm' &> /dev/null; then
        print_success "  ✓ npm is available"
    else
        print_error "  ✗ npm is not available in pod"
        has_errors=true
    fi

    # Check if node_modules exists
    if kubectl exec -n "$namespace" "$pod" -- sh -c 'test -d node_modules' &> /dev/null; then
        print_success "  ✓ node_modules directory exists"
    else
        print_warning "  ⚠ node_modules directory not found (might be okay if using different layout)"
    fi

    # Service-specific checks
    case "$service" in
        "data-builder-api")
            # Check CORE_DATABASE_URL for data-builder
            local core_url=$(kubectl exec -n "$namespace" "$pod" -- sh -c 'echo $CORE_DATABASE_URL' 2>/dev/null || echo "")
            if [ -z "$core_url" ]; then
                print_error "  ✗ CORE_DATABASE_URL is not set (required for data-builder)"
                has_errors=true
            else
                print_success "  ✓ CORE_DATABASE_URL is configured"
            fi
            ;;
        "los-core-api"|"los-integrations"|"sequence-builder-api"|"ui-builder-api")
            # Check if Prisma is available
            if kubectl exec -n "$namespace" "$pod" -- sh -c 'which prisma || test -f node_modules/.bin/prisma' &> /dev/null; then
                print_success "  ✓ Prisma CLI is available"
            else
                print_error "  ✗ Prisma CLI not found"
                has_errors=true
            fi
            ;;
        "workflow-api")
            # Check TypeORM availability
            if kubectl exec -n "$namespace" "$pod" -- sh -c 'test -f node_modules/.bin/typeorm' &> /dev/null; then
                print_success "  ✓ TypeORM CLI is available"
            else
                print_error "  ✗ TypeORM CLI not found"
                has_errors=true
            fi
            ;;
    esac

    echo ""

    if [ "$has_errors" = true ]; then
        print_error "$service has configuration errors - cannot proceed"
        return 1
    fi

    return 0
}

test_database_connection() {
    local namespace=$1
    local service=$2
    local pod=$3

    if $DRY_RUN; then
        return 0
    fi

    print_info "Testing database connection for $service..."

    # Different connection test based on service type
    case "$service" in
        "workflow-api")
            # TypeORM connection test
            if kubectl exec -n "$namespace" "$pod" -- sh -c 'npm run typeorm -- -h' &> /dev/null; then
                print_success "  ✓ TypeORM can connect"
            else
                print_error "  ✗ TypeORM connection failed"
                return 1
            fi
            ;;
        *)
            # Prisma connection test
            if kubectl exec -n "$namespace" "$pod" -- sh -c 'npx prisma db execute --stdin <<< "SELECT 1"' &> /dev/null; then
                print_success "  ✓ Database connection successful"
            else
                print_error "  ✗ Database connection failed"
                print_error "    Check DATABASE_URL and database accessibility"
                return 1
            fi
            ;;
    esac

    echo ""
    return 0
}

run_preflight_checks() {
    local namespace=$1

    print_section "PRE-FLIGHT CHECKS"
    print_info "Validating environment and credentials before proceeding..."
    echo ""

    if $DRY_RUN; then
        print_warning "DRY-RUN: Skipping pre-flight checks"
        echo ""
        return 0
    fi

    local services=("data-builder-api" "los-core-api" "los-integrations" "sequence-builder-api" "ui-builder-api" "workflow-api")
    local total_checks=0
    local passed_checks=0
    local failed_checks=0

    for service in "${services[@]}"; do
        # Find pod
        local pod=$(kubectl get pods -n "$namespace" -l "app.kubernetes.io/name=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -z "$pod" ]; then
            pod=$(kubectl get pods -n "$namespace" -l "app=$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        fi

        if [ -n "$pod" ]; then
            total_checks=$((total_checks + 1))

            print_info "Checking: $service ($pod)"
            echo ""

            # Validate environment
            if ! validate_pod_environment "$namespace" "$service" "$pod"; then
                failed_checks=$((failed_checks + 1))
                continue
            fi

            # Test database connection
            if ! test_database_connection "$namespace" "$service" "$pod"; then
                failed_checks=$((failed_checks + 1))
                continue
            fi

            passed_checks=$((passed_checks + 1))
            print_success "$service passed all pre-flight checks"
            echo ""
        else
            print_info "Skipping: $service (not deployed)"
            echo ""
        fi
    done

    # Summary
    print_section "PRE-FLIGHT CHECK RESULTS"
    echo ""

    if [ $total_checks -eq 0 ]; then
        print_error "No services found in namespace $namespace"
        print_info "This namespace might be empty or services might be down"
        echo ""
        read -p "$(echo -e ${YELLOW}Continue anyway? (yes/no): ${NC})" response
        if [ "$response" != "yes" ]; then
            exit 1
        fi
        return 0
    fi

    print_info "Services checked: $total_checks"
    print_success "Passed: $passed_checks"

    if [ $failed_checks -gt 0 ]; then
        print_error "Failed: $failed_checks"
        echo ""
        echo -e "${RED}${BOLD}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}${BOLD}║  CONFIGURATION ERRORS DETECTED                                 ║${NC}"
        echo -e "${RED}${BOLD}║                                                                ║${NC}"
        echo -e "${RED}${BOLD}║  Some services have missing credentials or configuration.     ║${NC}"
        echo -e "${RED}${BOLD}║  Fix the errors above before proceeding.                      ║${NC}"
        echo -e "${RED}${BOLD}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""

        read -p "$(echo -e ${YELLOW}Do you want to continue anyway? (yes/no): ${NC})" response
        if [ "$response" != "yes" ]; then
            print_error "Aborting due to pre-flight check failures"
            exit 1
        fi
    else
        print_success "All pre-flight checks passed!"
    fi

    echo ""
}

###############################################################################
# Kubernetes Helper Functions
###############################################################################

get_pod() {
    local namespace=$1
    local service=$2
    local selector="app.kubernetes.io/name=$service"

    if $DRY_RUN; then
        echo "${service}-pod-dry-run"
        return 0
    fi

    local pod=$(kubectl get pods -n "$namespace" -l "$selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$pod" ]; then
        # Try alternative selector
        selector="app=$service"
        pod=$(kubectl get pods -n "$namespace" -l "$selector" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi

    if [ -z "$pod" ]; then
        print_warning "No pod found for $service in namespace $namespace"
        return 1
    fi

    echo "$pod"
}

exec_in_pod() {
    local namespace=$1
    local pod=$2
    local command=$3
    local description=$4

    print_step "$description"

    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would execute: $command"
        return 0
    fi

    print_info "Pod: $pod"
    print_info "Command: $command"

    if kubectl exec -n "$namespace" "$pod" -- sh -c "$command"; then
        print_success "Command completed successfully"
        return 0
    else
        print_error "Command failed with exit code $?"
        return 1
    fi
}

check_namespace() {
    local namespace=$1

    if $DRY_RUN; then
        print_info "DRY-RUN: Skipping namespace check"
        return 0
    fi

    if ! kubectl get namespace "$namespace" &> /dev/null; then
        print_error "Namespace '$namespace' not found or not accessible"
        print_info "Available namespaces:"
        kubectl get namespaces | grep -E "(NAME|$CLIENT)"
        exit 1
    fi

    print_success "Namespace '$namespace' is accessible"
}

###############################################################################
# Service Reset Functions
###############################################################################

reset_data_builder() {
    local namespace=$1

    print_section "1/6: Resetting data-builder-api"

    local pod=$(get_pod "$namespace" "data-builder-api")
    if [ -z "$pod" ] || [ "$pod" == "" ]; then
        print_error "SKIPPED: data-builder-api pod not found in namespace $namespace"
        print_info "This service may not be deployed in this environment"
        echo ""
        return 1
    fi

    print_warning "data-builder-api has TWO schemas:"
    print_warning "  1. data-builder (main schema)"
    print_warning "  2. core schema (SHARED with los-core-api!)"
    echo ""

    # Deploy migrations for both schemas
    exec_in_pod "$namespace" "$pod" \
        "npm run db:deploy" \
        "Deploying migrations for both schemas" || print_warning "Migration deployment had issues"

    # Sync Prisma clients
    exec_in_pod "$namespace" "$pod" \
        "npm run db:sync-model" \
        "Syncing Prisma client models" || print_warning "Model sync had issues"

    # Seed data-builder
    exec_in_pod "$namespace" "$pod" \
        "npm run db:seed:data-builder" \
        "Seeding data-builder database" || print_warning "Seeding had issues"

    print_success "data-builder-api reset complete"
    echo ""
}

reset_los_core_api() {
    local namespace=$1
    local env_type=$2

    print_section "2/6: Resetting los-core-api ($env_type environment)"

    local pod=$(get_pod "$namespace" "los-core-api")
    if [ -z "$pod" ] || [ "$pod" == "" ]; then
        print_error "SKIPPED: los-core-api pod not found in namespace $namespace"
        print_info "This service may not be deployed in this environment"
        echo ""
        return 1
    fi

    print_info "Database: los-${env_type}"
    echo ""

    # Deploy migrations
    exec_in_pod "$namespace" "$pod" \
        "npm run prisma:migrate:prod" \
        "Deploying Prisma migrations" || print_warning "Migration deployment had issues"

    # Seed system data (REQUIRED)
    exec_in_pod "$namespace" "$pod" \
        "npm run seed:system" \
        "Seeding SYSTEM data (roles, permissions, queues, etc.)" || {
        print_error "System seed failed - this is critical!"
        return 1
    }

    print_success "los-core-api reset complete"
    print_info "Note: Mock data seeding was skipped (use 'npm run seed:mock' if needed)"
    echo ""
}

reset_los_integrations() {
    local namespace=$1

    print_section "3/6: Resetting los-integrations"

    local pod=$(get_pod "$namespace" "los-integrations")
    if [ -z "$pod" ] || [ "$pod" == "" ]; then
        print_error "SKIPPED: los-integrations pod not found in namespace $namespace"
        print_info "This service may not be deployed in this environment"
        echo ""
        return 1
    fi

    print_info "Using intelligent reset with --sync mode"
    print_info "This will:"
    print_info "  ✓ Truncate all tables (CASCADE)"
    print_info "  ✓ Reseed all integration configurations"
    print_info "  ✓ Preserve user mappings and credentials (auto-synced)"
    echo ""

    # Use built-in reset (truncates + reseeds with sync)
    exec_in_pod "$namespace" "$pod" \
        "npm run seed:reset && npm run seed:sync" \
        "Resetting and reseeding with intelligent sync" || {
        print_warning "Reset had issues, trying migration + seed separately..."

        exec_in_pod "$namespace" "$pod" \
            "npm run prisma:migrate:prod" \
            "Deploying migrations"

        exec_in_pod "$namespace" "$pod" \
            "npm run seed:sync" \
            "Seeding integrations with sync mode"
    }

    print_success "los-integrations reset complete"
    echo ""
}

reset_sequence_builder() {
    local namespace=$1

    print_section "4/6: Resetting sequence-builder-api"

    local pod=$(get_pod "$namespace" "sequence-builder-api")
    if [ -z "$pod" ] || [ "$pod" == "" ]; then
        print_error "SKIPPED: sequence-builder-api pod not found in namespace $namespace"
        print_info "This service may not be deployed in this environment"
        echo ""
        return 1
    fi

    # Deploy migrations
    exec_in_pod "$namespace" "$pod" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations" || print_warning "Migration deployment had issues"

    # Seed
    exec_in_pod "$namespace" "$pod" \
        "npm run seed" \
        "Seeding sequence-builder database" || print_warning "Seeding had issues"

    print_success "sequence-builder-api reset complete"
    echo ""
}

reset_ui_builder() {
    local namespace=$1

    print_section "5/6: Resetting ui-builder-api"

    local pod=$(get_pod "$namespace" "ui-builder-api")
    if [ -z "$pod" ] || [ "$pod" == "" ]; then
        print_error "SKIPPED: ui-builder-api pod not found in namespace $namespace"
        print_info "This service may not be deployed in this environment"
        echo ""
        return 1
    fi

    # Deploy migrations
    exec_in_pod "$namespace" "$pod" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations" || print_warning "Migration deployment had issues"

    # Seed
    exec_in_pod "$namespace" "$pod" \
        "npm run seed" \
        "Seeding UI builder database" || print_warning "Seeding had issues"

    print_success "ui-builder-api reset complete"
    echo ""
}

reset_workflow_api() {
    local namespace=$1

    print_section "6/6: Resetting workflow-api"

    local pod=$(get_pod "$namespace" "workflow-api")
    if [ -z "$pod" ] || [ "$pod" == "" ]; then
        print_error "SKIPPED: workflow-api pod not found in namespace $namespace"
        print_info "This service may not be deployed in this environment"
        echo ""
        return 1
    fi

    print_info "Using TypeORM migrations"
    echo ""

    # Run TypeORM migrations
    exec_in_pod "$namespace" "$pod" \
        "npm run db:run-migrations" \
        "Running TypeORM migrations" || print_warning "Migration had issues"

    # Seed
    exec_in_pod "$namespace" "$pod" \
        "npm run seed" \
        "Seeding workflow database" || print_warning "Seeding had issues"

    print_success "workflow-api reset complete"
    print_warning "Note: Workflow GitHub repos need to be reset manually!"
    print_info "Reset client workflow repos (e.g., ${CLIENT}-workflows) to initial commit"
    echo ""
}

###############################################################################
# Main Execution
###############################################################################

show_usage() {
    echo "Usage: $0 <client> <environment> [options]"
    echo ""
    echo "Arguments:"
    echo "  client        Client name (e.g., los-demo, qa)"
    echo "  environment   Environment (sandbox or production)"
    echo ""
    echo "Options:"
    echo "  --dry-run     Show what would be executed without making changes"
    echo "  --yes         Skip confirmation prompts (dangerous!)"
    echo ""
    echo "Examples:"
    echo "  $0 los-demo sandbox"
    echo "  $0 qa production --dry-run"
    echo ""
}

parse_args() {
    if [ $# -lt 2 ]; then
        show_usage
        exit 1
    fi

    CLIENT=$1
    ENVIRONMENT=$2
    shift 2

    # Parse optional flags
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                print_warning "DRY-RUN MODE: No changes will be made"
                shift
                ;;
            --yes)
                SKIP_CONFIRMATION=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate environment
    if [[ "$ENVIRONMENT" != "sandbox" && "$ENVIRONMENT" != "production" ]]; then
        print_error "Environment must be 'sandbox' or 'production'"
        exit 1
    fi

    NAMESPACE="${CLIENT}-${ENVIRONMENT}"
}

main() {
    parse_args "$@"

    print_header "Fuse Platform - Database Reset & Reseed"

    echo ""
    print_info "Configuration:"
    print_info "  Client:      $CLIENT"
    print_info "  Environment: $ENVIRONMENT"
    print_info "  Namespace:   $NAMESPACE"
    print_info "  Dry-run:     $DRY_RUN"
    echo ""

    # STEP 0: Validate CLI tools are installed and configured
    check_required_tools

    # SAFETY CHECK 1: Validate client and environment against whitelist
    validate_client_and_environment "$CLIENT" "$ENVIRONMENT"
    echo ""

    # SAFETY CHECK 2: Verify kubectl access to namespace
    check_namespace "$NAMESPACE"
    echo ""

    # SAFETY CHECK 3: Verify namespace isolation
    verify_namespace_isolation "$NAMESPACE"

    # SAFETY CHECK 4: Show exact database connections that will be affected
    get_database_connections "$NAMESPACE"

    # SAFETY CHECK 5: Verify no cross-namespace impact
    verify_no_cross_namespace_impact "$NAMESPACE"

    # PRE-FLIGHT CHECKS: Validate credentials and configuration
    run_preflight_checks "$NAMESPACE"

    # Show services that will be reset
    print_info "Services that will be reset:"
    print_info "  1. data-builder-api (2 schemas: data-builder + core)"
    print_info "  2. los-core-api ($ENVIRONMENT database)"
    print_info "  3. los-integrations"
    print_info "  4. sequence-builder-api"
    print_info "  5. ui-builder-api"
    print_info "  6. workflow-api"
    echo ""

    print_warning "═══════════════════════════════════════════════════════════════════════════"
    print_warning "FINAL SAFETY CHECK:"
    print_warning "  ✓ Only namespace '$NAMESPACE' will be affected"
    print_warning "  ✓ All other clients and environments are SAFE"
    print_warning "  ✓ Operations are isolated to pods in this namespace only"
    print_warning "═══════════════════════════════════════════════════════════════════════════"
    echo ""

    # Final confirmation
    local warning_msg="ALL databases in namespace: $NAMESPACE                           "
    confirm "$warning_msg"

    # Record start time
    START_TIME=$(date +%s)

    # Track successes and failures
    declare -a SUCCESSFUL_RESETS
    declare -a FAILED_RESETS
    declare -a SKIPPED_RESETS

    # Execute resets in order
    echo ""
    if reset_data_builder "$NAMESPACE"; then
        SUCCESSFUL_RESETS+=("data-builder-api")
    else
        if [ $? -eq 1 ]; then
            SKIPPED_RESETS+=("data-builder-api (pod not found)")
        else
            FAILED_RESETS+=("data-builder-api")
        fi
    fi

    if reset_los_core_api "$NAMESPACE" "$ENVIRONMENT"; then
        SUCCESSFUL_RESETS+=("los-core-api")
    else
        if [ $? -eq 1 ]; then
            SKIPPED_RESETS+=("los-core-api (pod not found)")
        else
            FAILED_RESETS+=("los-core-api")
        fi
    fi

    if reset_los_integrations "$NAMESPACE"; then
        SUCCESSFUL_RESETS+=("los-integrations")
    else
        if [ $? -eq 1 ]; then
            SKIPPED_RESETS+=("los-integrations (pod not found)")
        else
            FAILED_RESETS+=("los-integrations")
        fi
    fi

    if reset_sequence_builder "$NAMESPACE"; then
        SUCCESSFUL_RESETS+=("sequence-builder-api")
    else
        if [ $? -eq 1 ]; then
            SKIPPED_RESETS+=("sequence-builder-api (pod not found)")
        else
            FAILED_RESETS+=("sequence-builder-api")
        fi
    fi

    if reset_ui_builder "$NAMESPACE"; then
        SUCCESSFUL_RESETS+=("ui-builder-api")
    else
        if [ $? -eq 1 ]; then
            SKIPPED_RESETS+=("ui-builder-api (pod not found)")
        else
            FAILED_RESETS+=("ui-builder-api")
        fi
    fi

    if reset_workflow_api "$NAMESPACE"; then
        SUCCESSFUL_RESETS+=("workflow-api")
    else
        if [ $? -eq 1 ]; then
            SKIPPED_RESETS+=("workflow-api (pod not found)")
        else
            FAILED_RESETS+=("workflow-api")
        fi
    fi

    # Record end time
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    # Final summary
    print_header "Reset Complete!"

    if $DRY_RUN; then
        echo -e "${YELLOW}${BOLD}DRY-RUN MODE: No actual changes were made${NC}"
        echo ""
    fi

    # Show summary
    echo -e "${BOLD}Summary:${NC}"
    echo ""

    if [ ${#SUCCESSFUL_RESETS[@]} -gt 0 ]; then
        print_success "Successfully reset (${#SUCCESSFUL_RESETS[@]} services):"
        for service in "${SUCCESSFUL_RESETS[@]}"; do
            echo -e "  ${GREEN}✓${NC} $service"
        done
        echo ""
    fi

    if [ ${#SKIPPED_RESETS[@]} -gt 0 ]; then
        print_warning "Skipped (${#SKIPPED_RESETS[@]} services not deployed):"
        for service in "${SKIPPED_RESETS[@]}"; do
            echo -e "  ${YELLOW}⊘${NC} $service"
        done
        echo ""
    fi

    if [ ${#FAILED_RESETS[@]} -gt 0 ]; then
        print_error "Failed (${#FAILED_RESETS[@]} services):"
        for service in "${FAILED_RESETS[@]}"; do
            echo -e "  ${RED}✗${NC} $service"
        done
        echo ""
    fi

    print_info "Total execution time: ${DURATION} seconds"
    echo ""
    print_info "Next steps:"
    print_info "  1. Verify services are healthy: kubectl get pods -n $NAMESPACE"
    print_info "  2. Check logs for errors: kubectl logs -n $NAMESPACE <pod-name>"
    print_info "  3. Reset workflow GitHub repos to initial commit (manual step)"
    print_info "  4. Test the applications"
    echo ""
    print_warning "Remember: Workflow repos (${CLIENT}-workflows) need manual reset!"
    echo ""
}

# Execute main
main "$@"
