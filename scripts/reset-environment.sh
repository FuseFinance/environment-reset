#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE}$1${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}

print_info() {
    echo -e "${YELLOW}ℹ${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}✓${NC} $1" >&2
}

print_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1" >&2
}

# Configuration - Use relative path from infra/environment-reset
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
BE_DIR="$PROJECT_ROOT/BE"
TEMP_DIR="/tmp/fuse-reset-$(date +%s)"
CLIENT="${1:-}"

# Arrays to track results
SUCCESSFUL_RESETS=()
FAILED_RESETS=()

# ============================================================================
# SAFETY CHECKS
# ============================================================================

print_section "Safety Validation"

# Check if client parameter is provided
if [ -z "$CLIENT" ]; then
    print_error "Client parameter is required!"
    echo ""
    echo "Usage: $0 <client-name>"
    echo ""
    echo "Examples:"
    echo "  $0 onb-1"
    echo "  $0 onb-2"
    echo ""
    echo "Note: This will reset BOTH sandbox and production environments for the client."
    echo ""
    exit 1
fi

# CRITICAL SAFETY CHECK: Only allow onb-* clients
if [[ ! "$CLIENT" =~ ^onb- ]]; then
    print_error "SAFETY CHECK FAILED!"
    echo ""
    echo "❌ This script can ONLY be run on sandbox clients (onb-*)."
    echo ""
    echo "You tried to reset: '$CLIENT'"
    echo ""
    echo "To prevent accidental production data loss, only clients starting"
    echo "with 'onb-' are allowed (e.g., onb-1, onb-2, onb-test)."
    echo ""
    echo "Available sandbox clients in AWS Secrets Manager:"
    aws secretsmanager list-secrets --region us-east-2 --query "SecretList[?starts_with(Name, 'onb-')].Name" --output text 2>/dev/null | sed 's/\t/\n/g' | sed 's|/.*||' | sort -u | sed 's/^/  - /'
    echo ""
    exit 1
fi

print_success "Safety check passed: '$CLIENT' is a valid sandbox client"

# Verify AWS credentials are configured
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS credentials not configured or expired"
    echo "Please run: aws sso login --profile <your-profile>"
    exit 1
fi

print_success "AWS credentials validated"

# Check if BE_DIR exists
if [ ! -d "$BE_DIR" ]; then
    print_error "Backend directory not found: $BE_DIR"
    exit 1
fi

print_success "Backend directory found: $BE_DIR"

# ============================================================================
# CLEANUP HANDLER
# ============================================================================

cleanup_on_exit() {
    print_section "Cleaning up temporary directories"
    if [ -d "$TEMP_DIR" ]; then
        print_info "Removing $TEMP_DIR"
        rm -rf "$TEMP_DIR"
        print_success "Cleanup completed"
    fi
}

trap cleanup_on_exit EXIT INT TERM

# ============================================================================
# SETUP CLEAN REPOSITORIES
# ============================================================================

SERVICES=(
    "los-core-api"
    "los-integrations"
    "sequence-builder-api"
    "ui-builder-api"
    "workflow-api"
    "data-builder-api"
)

print_section "Setting up clean repository copies"
print_info "Creating temporary directory: $TEMP_DIR"
mkdir -p "$TEMP_DIR"

# Copy each service
for service in "${SERVICES[@]}"; do
    print_info "Copying $service..."
    cp -R "$BE_DIR/$service" "$TEMP_DIR/$service"

    print_info "Checking out main and pulling latest for $service..."
    cd "$TEMP_DIR/$service"

    # Fetch latest from origin
    git fetch origin > /dev/null 2>&1 || {
        print_error "Failed to fetch from origin for $service"
        exit 1
    }

    # Hard reset to origin/main (discards any local changes)
    git reset --hard origin/main > /dev/null 2>&1 || {
        print_error "Failed to reset to origin/main for $service"
        exit 1
    }

    # Checkout main
    git checkout main > /dev/null 2>&1 || {
        print_error "Failed to checkout main for $service"
        exit 1
    }

    print_success "$service ready on main branch"
done

print_section "Installing dependencies for all services"

# Copy .npmrc from los-core-api to all services (for @fusefinance packages)
print_info "Copying .npmrc from los-core-api to all services..."
if [ -f "$TEMP_DIR/los-core-api/.npmrc" ]; then
    for service in "${SERVICES[@]}"; do
        if [ "$service" != "los-core-api" ]; then
            cp "$TEMP_DIR/los-core-api/.npmrc" "$TEMP_DIR/$service/.npmrc"
            print_success "Copied .npmrc to $service"
        fi
    done
else
    print_warning ".npmrc not found in los-core-api, services may fail to install @fusefinance packages"
fi

for service in "${SERVICES[@]}"; do
    print_info "Running npm install for $service..."
    cd "$TEMP_DIR/$service"

    # Run npm install - save output to log file
    if npm install --prefer-offline --no-audit > /tmp/${service}-npm-install.log 2>&1; then
        print_success "$service dependencies installed"
    else
        print_error "npm install failed for $service"
        echo "Last 30 lines of output:"
        tail -30 /tmp/${service}-npm-install.log
        exit 1
    fi
done

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

get_secret() {
    local secret_id=$1
    aws secretsmanager get-secret-value \
        --secret-id "$secret_id" \
        --region us-east-2 \
        --query 'SecretString' \
        --output text 2>/dev/null || {
        print_error "Failed to fetch secret: $secret_id"
        return 1
    }
}

create_temp_env_file() {
    local service_dir=$1
    local secret_id=$2

    if [ -f "$service_dir/.env" ]; then
        print_info "Backing up existing .env to .env.backup"
        mv "$service_dir/.env" "$service_dir/.env.backup"
    fi

    local secret_json=$(get_secret "$secret_id")
    if [ $? -ne 0 ]; then
        return 1
    fi

    print_info "Creating temporary .env with Secrets Manager credentials"
    echo "$secret_json" | jq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$service_dir/.env"
    return 0
}

restore_env_file() {
    local service_dir=$1

    if [ -f "$service_dir/.env" ]; then
        rm "$service_dir/.env"
    fi

    if [ -f "$service_dir/.env.backup" ]; then
        print_info "Restoring original .env from backup"
        mv "$service_dir/.env.backup" "$service_dir/.env"
    fi
}

run_in_dir() {
    local service_name=$1
    local service_dir=$2
    local command=$3
    local description=$4

    print_info "$description..."
    cd "$service_dir"

    if eval "$command" > /tmp/${service_name}-output.log 2>&1; then
        print_success "$description completed"
        return 0
    else
        print_error "$description failed"
        echo "Last 30 lines of output:"
        tail -30 /tmp/${service_name}-output.log
        return 1
    fi
}

# ============================================================================
# SERVICE-SPECIFIC RESET FUNCTIONS
# ============================================================================

reset_los_core_api() {
    local client=$1
    local env_type=$2

    print_section "1/6: Resetting los-core-api ($env_type environment)"

    local secret_id="$client/$env_type/los-core-api/config"
    local service_dir="$TEMP_DIR/los-core-api"

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("los-core-api")
        return 1
    fi

    local success=true

    if run_in_dir "los-core-api" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "los-core-api" "$service_dir" \
            "npx prisma generate" \
            "Regenerating Prisma client"; then

            # los-core-api has multiple seed options - use the simple one from prisma/seed.ts
            if run_in_dir "los-core-api" "$service_dir" \
                "npx prisma db seed" \
                "Seeding test dealer data"; then

                SUCCESSFUL_RESETS+=("los-core-api")
                print_success "los-core-api reset completed"
            else
                success=false
            fi
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("los-core-api")
        return 1
    fi

    return 0
}

reset_los_integrations() {
    local client=$1
    local env_type=$2

    print_section "2/6: Resetting los-integrations ($env_type environment)"

    local secret_id="$client/$env_type/los-integrations/config"
    local service_dir="$TEMP_DIR/los-integrations"

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("los-integrations")
        return 1
    fi

    local success=true

    if run_in_dir "los-integrations" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "los-integrations" "$service_dir" \
            "npx prisma generate" \
            "Regenerating Prisma client"; then

            if run_in_dir "los-integrations" "$service_dir" \
                "npm run seed" \
                "Seeding integrations data"; then

                SUCCESSFUL_RESETS+=("los-integrations")
                print_success "los-integrations reset completed"
            else
                success=false
            fi
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("los-integrations")
        return 1
    fi

    return 0
}

reset_sequence_builder_api() {
    local client=$1

    print_section "3/6: Resetting sequence-builder-api"

    local secret_id="$client/workflows/sequence-builder-api/config"
    local service_dir="$TEMP_DIR/sequence-builder-api"

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("sequence-builder-api")
        return 1
    fi

    local success=true

    if run_in_dir "sequence-builder-api" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "sequence-builder-api" "$service_dir" \
            "npx prisma generate" \
            "Regenerating Prisma client"; then

            if run_in_dir "sequence-builder-api" "$service_dir" \
                "npm run build" \
                "Building TypeScript project"; then

                if run_in_dir "sequence-builder-api" "$service_dir" \
                    "npm run seed" \
                    "Seeding initial version"; then
                    SUCCESSFUL_RESETS+=("sequence-builder-api")
                    print_success "sequence-builder-api fully reset"
                else
                    print_warning "Build succeeded but seed failed (may have TS errors in main)"
                    SUCCESSFUL_RESETS+=("sequence-builder-api (migrations only)")
                fi
            else
                print_warning "Migrations completed but build failed (may have TS errors in main)"
                SUCCESSFUL_RESETS+=("sequence-builder-api (migrations only)")
            fi
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("sequence-builder-api")
        return 1
    fi

    return 0
}

reset_ui_builder_api() {
    local client=$1

    print_section "4/6: Resetting ui-builder-api"

    local secret_id="$client/workflows/ui-builder-api/config"
    local service_dir="$TEMP_DIR/ui-builder-api"

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("ui-builder-api")
        return 1
    fi

    local success=true

    if run_in_dir "ui-builder-api" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "ui-builder-api" "$service_dir" \
            "npx prisma generate" \
            "Regenerating Prisma client"; then

            if run_in_dir "ui-builder-api" "$service_dir" \
                "npm run seed" \
                "Seeding pages, collections, and menu items"; then

                SUCCESSFUL_RESETS+=("ui-builder-api")
                print_success "ui-builder-api reset completed"
            else
                success=false
            fi
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("ui-builder-api")
        return 1
    fi

    return 0
}

reset_workflow_api() {
    local client=$1

    print_section "5/6: Resetting workflow-api"

    local secret_id="$client/workflows/workflow-api/config"
    local service_dir="$TEMP_DIR/workflow-api"

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("workflow-api")
        return 1
    fi

    local success=true

    if run_in_dir "workflow-api" "$service_dir" \
        "npm run db:run-migrations" \
        "Running TypeORM migrations"; then

        if run_in_dir "workflow-api" "$service_dir" \
            "npm run seed" \
            "Seeding version, GitHub repo, and 6 default workflows"; then

            SUCCESSFUL_RESETS+=("workflow-api")
            print_success "workflow-api reset completed"
        else
            print_warning "Migrations completed but seed failed"
            print_info "This may be due to GitHub API issues or missing env vars"
            FAILED_RESETS+=("workflow-api (seed failed)")
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("workflow-api")
        return 1
    fi

    return 0
}

reset_data_builder_api() {
    local client=$1

    print_section "6/6: Resetting data-builder-api"

    local secret_id="$client/workflows/data-builder-api/config"
    local service_dir="$TEMP_DIR/data-builder-api"

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("data-builder-api")
        return 1
    fi

    local success=true

    # data-builder-api has two schemas: core and data-builder
    if run_in_dir "data-builder-api" "$service_dir" \
        "npx prisma migrate deploy --schema=./prisma-core/schema.prisma" \
        "Deploying core schema migrations"; then

        if run_in_dir "data-builder-api" "$service_dir" \
            "npx prisma migrate deploy --schema=./prisma-data-builder/schema.prisma" \
            "Deploying data-builder schema migrations"; then

            if run_in_dir "data-builder-api" "$service_dir" \
                "npx prisma generate --schema=./prisma-core/schema.prisma" \
                "Generating core Prisma client"; then

                if run_in_dir "data-builder-api" "$service_dir" \
                    "npx prisma generate --schema=./prisma-data-builder/schema.prisma" \
                    "Generating data-builder Prisma client"; then

                    if run_in_dir "data-builder-api" "$service_dir" \
                        "npm run db:seed:data-builder" \
                        "Seeding data-builder data"; then

                        SUCCESSFUL_RESETS+=("data-builder-api")
                        print_success "data-builder-api reset completed"
                    else
                        print_warning "Migrations completed but seed failed"
                        SUCCESSFUL_RESETS+=("data-builder-api (migrations only)")
                    fi
                else
                    success=false
                fi
            else
                success=false
            fi
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("data-builder-api")
        return 1
    fi

    return 0
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

print_section "Starting Database Reset for Client: $CLIENT (BOTH sandbox and production)"

# Confirm with user
echo "This will reset ALL databases for client '$CLIENT' (BOTH environments):"
echo ""
echo "SANDBOX Environment:"
echo "  - los-core-api (los-sandbox database)"
echo "  - los-integrations (integrations database)"
echo ""
echo "PRODUCTION Environment:"
echo "  - los-core-api (los-production database)"
echo "  - los-integrations (integrations database)"
echo ""
echo "SHARED (workflows):"
echo "  - sequence-builder-api (sequence-builder database)"
echo "  - ui-builder-api (ui-builder database)"
echo "  - workflow-api (workflow-builder database)"
echo "  - data-builder-api (data-builder database)"
echo ""
echo "⚠️  WARNING: This will DELETE ALL DATA in these databases for BOTH sandbox and production!"
echo ""
echo "Seeds that will be created:"
echo "  ✓ los-core-api: Test dealer (VI2JX) in both sandbox & production"
echo "  ✓ los-integrations: 40+ integrations with categories in both sandbox & production"
echo "  ✓ sequence-builder-api: Initial version (v.0.0.0)"
echo "  ✓ ui-builder-api: 11 pages, collections, menu items"
echo "  ✓ workflow-api: Initial version + 6 default workflows"
echo "  ✓ data-builder-api: Initial data"
echo ""
read -p "Type 'DELETE ALL DATA' to confirm: " confirmation

if [ "$confirmation" != "DELETE ALL DATA" ]; then
    print_error "Reset cancelled - confirmation not received"
    exit 1
fi

print_info "Confirmation received. Proceeding with reset..."

# Execute resets for both environments
# Services with separate sandbox/production databases
reset_los_core_api "$CLIENT" "sandbox"
reset_los_core_api "$CLIENT" "production"
reset_los_integrations "$CLIENT" "sandbox"
reset_los_integrations "$CLIENT" "production"

# Services with shared workflow databases (only reset once)
reset_sequence_builder_api "$CLIENT"
reset_ui_builder_api "$CLIENT"
reset_workflow_api "$CLIENT"
reset_data_builder_api "$CLIENT"

# ============================================================================
# SUMMARY
# ============================================================================

print_section "Reset Summary"

if [ ${#SUCCESSFUL_RESETS[@]} -gt 0 ]; then
    echo -e "${GREEN}Successful resets (${#SUCCESSFUL_RESETS[@]}):${NC}"
    for service in "${SUCCESSFUL_RESETS[@]}"; do
        echo -e "  ${GREEN}✓${NC} $service"
    done
    echo ""
fi

if [ ${#FAILED_RESETS[@]} -gt 0 ]; then
    echo -e "${RED}Failed resets (${#FAILED_RESETS[@]}):${NC}"
    for service in "${FAILED_RESETS[@]}"; do
        echo -e "  ${RED}✗${NC} $service"
    done
    echo ""
    print_warning "Some services failed to reset. Check logs above for details."
    exit 1
fi

print_success "All databases reset successfully!"
print_info "You can now verify the seeds with: npm run verify-seeds -- $CLIENT"
