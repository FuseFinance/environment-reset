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

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
BE_DIR="$PROJECT_ROOT/BE"
CLIENT="${1:-}"

# Arrays to track results
SUCCESSFUL_RESETS=()
PARTIAL_RESETS=()  # Migrations completed but seed failed
FAILED_RESETS=()

# Parse service filters from arguments
SELECTED_SERVICES=()
shift # Remove client argument
while [[ $# -gt 0 ]]; do
    case $1 in
        --service|-s)
            SELECTED_SERVICES+=("$2")
            shift 2
            ;;
        --only)
            SELECTED_SERVICES+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            shift
            ;;
    esac
done

# Helper function to check if a service should be reset
should_reset_service() {
    local service=$1

    # If no services selected, reset all
    if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
        return 0
    fi

    # Check if service is in selected list
    for selected in "${SELECTED_SERVICES[@]}"; do
        if [ "$service" = "$selected" ]; then
            return 0
        fi
    done

    return 1
}

# ============================================================================
# SAFETY CHECKS
# ============================================================================

print_section "Safety Validation"

if [ -z "$CLIENT" ]; then
    print_error "Client parameter is required!"
    echo ""
    echo "Usage: $0 <client-name> [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --service <name>, -s <name>    Reset specific service(s)"
    echo "  --only <name>                  Alias for --service"
    echo ""
    echo "EXAMPLES:"
    echo "  $0 onb-1                                  # Reset all services"
    echo "  $0 onb-1 --service sequence-builder-api   # Reset one service"
    echo "  $0 onb-1 -s los-core-api -s workflow-api  # Reset multiple services"
    echo ""
    echo "AVAILABLE SERVICES:"
    echo "  - los-core-api (sandbox and workflows environments)"
    echo "  - los-integrations (sandbox and workflows environments)"
    echo "  - sequence-builder-api"
    echo "  - ui-builder-api"
    echo "  - workflow-api"
    echo "  - data-builder-api"
    exit 1
fi

# CRITICAL SAFETY CHECK: Only allow onb-* clients
if [[ ! "$CLIENT" =~ ^onb- ]]; then
    print_error "SAFETY CHECK FAILED! This script can ONLY be run on sandbox clients (onb-*)."
    exit 1
fi

print_success "Safety check passed: '$CLIENT' is a valid sandbox client"

# Verify AWS credentials
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
# HELPER FUNCTIONS
# ============================================================================

get_secret() {
    local secret_id=$1
    local result=$(aws secretsmanager get-secret-value \
        --secret-id "$secret_id" \
        --region us-east-2 \
        --query 'SecretString' \
        --output text 2>&1)

    if [ $? -ne 0 ]; then
        if echo "$result" | grep -q "ResourceNotFoundException"; then
            print_warning "Secret not found: $secret_id (environment may not exist)"
            return 2  # Special return code for not found
        else
            print_error "Failed to fetch secret: $secret_id"
            return 1
        fi
    fi

    echo "$result"
    return 0
}

create_temp_env_file() {
    local service_dir=$1
    local secret_id=$2

    if [ -f "$service_dir/.env" ]; then
        print_info "Backing up existing .env to .env.backup"
        mv "$service_dir/.env" "$service_dir/.env.backup"
    fi

    local secret_json=$(get_secret "$secret_id")
    local secret_status=$?

    if [ $secret_status -eq 2 ]; then
        # Secret not found - environment doesn't exist, skip gracefully
        return 2
    elif [ $secret_status -ne 0 ]; then
        # Other error
        return 1
    fi

    print_info "Creating temporary .env with Secrets Manager credentials"
    # Create .env file without quotes - values will be properly handled when exported
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

# Helper function to export environment variables from JSON secret
export_env_from_secret() {
    local secret_id=$1
    local secret_json=$(get_secret "$secret_id")
    local secret_status=$?
    
    if [ $secret_status -ne 0 ]; then
        return $secret_status
    fi
    
    # Export each key-value pair from JSON, properly escaping values
    echo "$secret_json" | jq -r 'to_entries | .[] | "export \(.key)=\"\(.value | gsub("\""; "\\\""))\" "' | while IFS= read -r export_line; do
        eval "$export_line"
    done
}

# Helper function to setup service directory (git, npm, prisma)
setup_service_directory() {
    local service_name=$1
    local service_dir=$2

    cd "$service_dir"

    # Initialize variables
    local node_path_prefix=""
    local needs_npm_install=false

    # Step 1: Git checkout main and pull
    print_info "Checking out main branch and pulling latest changes..."

    # Store hash of package-lock.json before pull (if exists)
    local package_lock_hash_before=""
    if [ -f "package-lock.json" ]; then
        package_lock_hash_before=$(md5 -q package-lock.json 2>/dev/null || md5sum package-lock.json 2>/dev/null | cut -d' ' -f1)
    fi

    if git checkout main > /tmp/${service_name}-git-checkout.log 2>&1; then
        print_success "Checked out main branch"

        # Stash any local changes before pulling
        if git diff --quiet && git diff --cached --quiet; then
            print_info "No local changes to stash"
        else
            print_info "Stashing local changes before pull..."
            git stash push -m "Auto-stash by reset script at $(date)" > /tmp/${service_name}-git-stash.log 2>&1
            print_success "Local changes stashed (can be restored with 'git stash pop')"
        fi

        if git pull origin main > /tmp/${service_name}-git-pull.log 2>&1; then
            print_success "Pulled latest changes"

            # Check if package-lock.json changed after pull
            local package_lock_hash_after=""
            if [ -f "package-lock.json" ]; then
                package_lock_hash_after=$(md5 -q package-lock.json 2>/dev/null || md5sum package-lock.json 2>/dev/null | cut -d' ' -f1)
            fi

            if [ "$package_lock_hash_before" != "$package_lock_hash_after" ]; then
                print_warning "package-lock.json changed, will reinstall dependencies"
                needs_npm_install=true
            fi
        else
            print_warning "Git pull failed, continuing anyway"
            tail -10 /tmp/${service_name}-git-pull.log
        fi
    else
        print_warning "Git checkout failed, continuing anyway"
        tail -10 /tmp/${service_name}-git-checkout.log
    fi

    # Step 2: Determine Node version and set PATH if .nvmrc exists
    if [ -f ".nvmrc" ]; then
        local node_version=$(cat .nvmrc | tr -d '[:space:]')
        local nvm_node_dir="$HOME/.nvm/versions/node/v${node_version}"

        # Find the actual installed version (might have patch version)
        if [ -d "$HOME/.nvm/versions/node" ]; then
            local actual_version=$(ls -1 "$HOME/.nvm/versions/node" | grep "^v${node_version}" | sort -V | tail -1)
            if [ -n "$actual_version" ]; then
                nvm_node_dir="$HOME/.nvm/versions/node/$actual_version"
            fi
        fi

        if [ -d "$nvm_node_dir/bin" ]; then
            node_path_prefix="export PATH=\"$nvm_node_dir/bin:\$PATH\";"
            print_info "Using Node from: $nvm_node_dir"

            # Check if we need to run npm install
            if [ ! -f ".node-version-installed" ] || [ "$(cat .node-version-installed 2>/dev/null)" != "$actual_version" ]; then
                needs_npm_install=true
            fi
        else
            print_warning "Node version $node_version not found in nvm, using system Node"
        fi
    fi

    # Step 3: Copy .npmrc from a reference service if missing (for GitHub package authentication)
    if [ ! -f ".npmrc" ] && [ -f "$BE_DIR/los-core-api/.npmrc" ]; then
        print_info "Copying .npmrc from los-core-api for GitHub packages authentication..."
        cp "$BE_DIR/los-core-api/.npmrc" .npmrc
        print_success ".npmrc copied"
    fi

    # Step 4: Run npm install if needed
    # Always run after git pull to ensure new dependencies are installed
    if [ "$needs_npm_install" = true ] || [ ! -d "node_modules" ]; then
        if [ "$needs_npm_install" = true ]; then
            print_info "Node version or dependencies changed, removing node_modules..."
            rm -rf node_modules
        fi
        print_info "Running npm install with Node $actual_version..."
        if (eval "$node_path_prefix"; npm install --no-audit --no-fund) > /tmp/${service_name}-npm-install.log 2>&1; then
            print_success "npm install completed"
            # Mark this Node version as installed
            if [ -n "$actual_version" ]; then
                echo "$actual_version" > .node-version-installed
            fi
        else
            print_error "npm install failed"
            tail -20 /tmp/${service_name}-npm-install.log
            return 1
        fi
    else
        # Even if node_modules exists, run npm install to catch new dependencies from git pull
        # This is fast if nothing changed
        print_info "Running npm install to update dependencies..."
        if (eval "$node_path_prefix"; npm install --no-audit --no-fund) > /tmp/${service_name}-npm-install.log 2>&1; then
            print_success "npm install completed"
        else
            print_warning "npm install failed, but continuing anyway"
            tail -20 /tmp/${service_name}-npm-install.log
        fi
    fi

    # Step 5: Run prisma generate if service uses Prisma
    if [ -d "prisma" ] || [ -d "prisma-core" ] || [ -d "prisma-data-builder" ] || [ -f "prisma.config.ts" ] || grep -q "prisma generate\|generate-client" package.json 2>/dev/null; then
        print_info "Running prisma generate..."

        # Special handling for data-builder-api with multiple schemas
        if [ -d "prisma-core" ] && [ -d "prisma-data-builder" ]; then
            print_info "Detected multiple Prisma schemas (data-builder-api)"
            if (eval "$node_path_prefix"; npx prisma generate --schema=./prisma-core/schema.prisma) > /tmp/${service_name}-prisma-generate-core.log 2>&1; then
                print_success "Prisma generate (core) completed"
            else
                print_error "Prisma generate (core) failed"
                tail -20 /tmp/${service_name}-prisma-generate-core.log
                return 1
            fi

            if (eval "$node_path_prefix"; npx prisma generate --schema=./prisma-data-builder/schema.prisma) > /tmp/${service_name}-prisma-generate-data-builder.log 2>&1; then
                print_success "Prisma generate (data-builder) completed"
            else
                print_error "Prisma generate (data-builder) failed"
                tail -20 /tmp/${service_name}-prisma-generate-data-builder.log
                return 1
            fi
        else
            # Standard single-schema services
            # Try to find the prisma generate command from package.json
            local prisma_cmd="npx prisma generate"
            if grep -q "\"generate-client\":" package.json 2>/dev/null; then
                prisma_cmd="npm run generate-client"
            elif grep -q "\"prisma:generate\":" package.json 2>/dev/null; then
                prisma_cmd="npm run prisma:generate"
            fi

            if (eval "$node_path_prefix"; $prisma_cmd) > /tmp/${service_name}-prisma-generate.log 2>&1; then
                print_success "Prisma generate completed"
            else
                print_error "Prisma generate failed"
                tail -20 /tmp/${service_name}-prisma-generate.log
                return 1
            fi
        fi
    fi

    # Export node_path_prefix for use in run_in_dir
    echo "$node_path_prefix"
}

run_in_dir() {
    local service_name=$1
    local service_dir=$2
    local command=$3
    local description=$4
    local use_dotenv=${5:-false}

    print_info "$description..."
    cd "$service_dir"

    # Get node_path_prefix from environment or detect it
    local node_path_prefix=""
    if [ -f ".nvmrc" ]; then
        local node_version=$(cat .nvmrc | tr -d '[:space:]')
        local nvm_node_dir="$HOME/.nvm/versions/node/v${node_version}"

        # Find the actual installed version
        if [ -d "$HOME/.nvm/versions/node" ]; then
            local actual_version=$(ls -1 "$HOME/.nvm/versions/node" | grep "^v${node_version}" | sort -V | tail -1)
            if [ -n "$actual_version" ]; then
                nvm_node_dir="$HOME/.nvm/versions/node/$actual_version"
            fi
        fi

        if [ -d "$nvm_node_dir/bin" ]; then
            node_path_prefix="export PATH=\"$nvm_node_dir/bin:\$PATH\";"
        fi
    fi

    # If use_dotenv is true and .env exists, run command in subshell with loaded env
    if [ "$use_dotenv" = "true" ] && [ -f ".env" ]; then
        # Use printf %q to safely escape all special characters in values
        # This is the most reliable method for handling special chars like $, !, ^, etc.
        local env_exports=""
        while IFS= read -r line || [ -n "$line" ]; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            # Skip lines that don't contain =
            [[ ! "$line" =~ = ]] && continue
            
            # Extract key and value (everything after first =)
            local key="${line%%=*}"
            local value="${line#*=}"
            
            # Remove leading/trailing whitespace from key
            key=$(echo "$key" | xargs)
            
            # Use printf %q to properly escape the value for shell evaluation
            # This handles ALL special characters safely
            local escaped_value
            printf -v escaped_value '%q' "$value"
            
            env_exports="${env_exports}export ${key}=${escaped_value};"
        done < .env
        
        if (eval "$node_path_prefix"; eval "$env_exports"; eval "$command") > /tmp/${service_name}-output.log 2>&1; then
            print_success "$description completed"
            return 0
        else
            print_error "$description failed"
            echo "Last 30 lines of output:"
            tail -30 /tmp/${service_name}-output.log
            return 1
        fi
    else
        if (eval "$node_path_prefix"; eval "$command") > /tmp/${service_name}-output.log 2>&1; then
            print_success "$description completed"
            return 0
        else
            print_error "$description failed"
            echo "Last 30 lines of output:"
            tail -30 /tmp/${service_name}-output.log
            return 1
        fi
    fi
}

# ============================================================================
# SERVICE-SPECIFIC RESET FUNCTIONS
# ============================================================================

reset_los_core_api() {
    local client=$1
    local env_type=$2

    print_section "Resetting los-core-api ($env_type environment)"

    local secret_id="$client/$env_type/los-core-api/config"
    local service_dir="$BE_DIR/los-core-api"

    # Setup: git checkout/pull, npm install, prisma generate
    if ! setup_service_directory "los-core-api-$env_type" "$service_dir"; then
        FAILED_RESETS+=("los-core-api-$env_type")
        return 1
    fi

    create_temp_env_file "$service_dir" "$secret_id"
    local create_status=$?

    if [ $create_status -eq 2 ]; then
        print_warning "Skipping los-core-api ($env_type) - environment not configured"
        return 0
    elif [ $create_status -ne 0 ]; then
        FAILED_RESETS+=("los-core-api-$env_type")
        return 1
    fi

    local success=true

    if run_in_dir "los-core-api-$env_type" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "los-core-api-$env_type" "$service_dir" \
            "npx prisma db seed" \
            "Seeding test dealer data"; then

            SUCCESSFUL_RESETS+=("los-core-api-$env_type")
            print_success "los-core-api ($env_type) reset completed"
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("los-core-api-$env_type")
        return 1
    fi

    return 0
}

reset_los_integrations() {
    local client=$1
    local env_type=$2

    print_section "Resetting los-integrations ($env_type environment)"

    local secret_id="$client/$env_type/los-integrations/config"
    local service_dir="$BE_DIR/los-integrations"

    # Setup: git checkout/pull, npm install, prisma generate
    if ! setup_service_directory "los-integrations-$env_type" "$service_dir"; then
        FAILED_RESETS+=("los-integrations-$env_type")
        return 1
    fi

    create_temp_env_file "$service_dir" "$secret_id"
    local create_status=$?

    if [ $create_status -eq 2 ]; then
        print_warning "Skipping los-integrations ($env_type) - environment not configured"
        return 0
    elif [ $create_status -ne 0 ]; then
        FAILED_RESETS+=("los-integrations-$env_type")
        return 1
    fi

    local success=true

    if run_in_dir "los-integrations-$env_type" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "los-integrations-$env_type" "$service_dir" \
            "npm run seed" \
            "Seeding integrations data"; then

            SUCCESSFUL_RESETS+=("los-integrations-$env_type")
            print_success "los-integrations ($env_type) reset completed"
        else
            success=false
        fi
    else
        success=false
    fi

    restore_env_file "$service_dir"

    if [ "$success" = false ]; then
        FAILED_RESETS+=("los-integrations-$env_type")
        return 1
    fi

    return 0
}

reset_sequence_builder_api() {
    local client=$1

    print_section "Resetting sequence-builder-api"

    local secret_id="$client/workflows/sequence-builder-api/config"
    local service_dir="$BE_DIR/sequence-builder-api"

    # Setup: git checkout/pull, npm install, prisma generate
    if ! setup_service_directory "sequence-builder-api" "$service_dir"; then
        FAILED_RESETS+=("sequence-builder-api")
        return 1
    fi

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("sequence-builder-api")
        return 1
    fi

    local success=true

    # Drop and recreate schema to ensure clean state
    if run_in_dir "sequence-builder-api" "$service_dir" \
        "npx prisma migrate reset --force --skip-seed" \
        "Resetting database schema"; then

        print_success "Database schema reset completed"
    else
        print_warning "Schema reset failed, attempting deployment anyway"
    fi

    if run_in_dir "sequence-builder-api" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "sequence-builder-api" "$service_dir" \
            "npm run seed" \
            "Seeding initial version" \
            true; then
            SUCCESSFUL_RESETS+=("sequence-builder-api")
            print_success "sequence-builder-api reset completed"
        else
            print_warning "Migrations completed but seed failed"
            PARTIAL_RESETS+=("sequence-builder-api")
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

    print_section "Resetting ui-builder-api"

    local secret_id="$client/workflows/ui-builder-api/config"
    local service_dir="$BE_DIR/ui-builder-api"

    # Setup: git checkout/pull, npm install, prisma generate
    if ! setup_service_directory "ui-builder-api" "$service_dir"; then
        FAILED_RESETS+=("ui-builder-api")
        return 1
    fi

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("ui-builder-api")
        return 1
    fi

    local success=true

    # Drop and recreate schema to ensure clean state
    if run_in_dir "ui-builder-api" "$service_dir" \
        "npx prisma migrate reset --force --skip-seed" \
        "Resetting database schema"; then

        print_success "Database schema reset completed"
    else
        print_warning "Schema reset failed, attempting deployment anyway"
    fi

    if run_in_dir "ui-builder-api" "$service_dir" \
        "npx prisma migrate deploy" \
        "Deploying Prisma migrations"; then

        if run_in_dir "ui-builder-api" "$service_dir" \
            "npm run seed" \
            "Seeding pages, collections, and menu items" \
            true; then

            SUCCESSFUL_RESETS+=("ui-builder-api")
            print_success "ui-builder-api reset completed"
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

    print_section "Resetting workflow-api"

    local secret_id="$client/workflows/workflow-api/config"
    local service_dir="$BE_DIR/workflow-api"

    # Setup: git checkout/pull, npm install, prisma generate
    # Note: workflow-api uses TypeORM, not Prisma, so prisma generate will be skipped
    if ! setup_service_directory "workflow-api" "$service_dir"; then
        FAILED_RESETS+=("workflow-api")
        return 1
    fi

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
            "Seeding version and workflows" \
            true; then

            SUCCESSFUL_RESETS+=("workflow-api")
            print_success "workflow-api reset completed"
        else
            print_warning "Migrations completed but seed failed"
            PARTIAL_RESETS+=("workflow-api")
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

    print_section "Resetting data-builder-api"

    local secret_id="$client/workflows/data-builder-api/config"
    local service_dir="$BE_DIR/data-builder-api"

    # Setup: git checkout/pull, npm install, prisma generate
    if ! setup_service_directory "data-builder-api" "$service_dir"; then
        FAILED_RESETS+=("data-builder-api")
        return 1
    fi

    if ! create_temp_env_file "$service_dir" "$secret_id"; then
        FAILED_RESETS+=("data-builder-api")
        return 1
    fi

    local success=true

    # Drop and recreate schemas to ensure clean state
    print_info "Resetting database schemas..."
    if run_in_dir "data-builder-api" "$service_dir" \
        "npx prisma migrate reset --force --skip-seed --schema=./prisma-core/schema.prisma" \
        "Resetting core schema"; then
        print_success "Core schema reset completed"
    else
        print_warning "Core schema reset failed, attempting deployment anyway"
    fi

    if run_in_dir "data-builder-api" "$service_dir" \
        "npx prisma migrate reset --force --skip-seed --schema=./prisma-data-builder/schema.prisma" \
        "Resetting data-builder schema"; then
        print_success "Data-builder schema reset completed"
    else
        print_warning "Data-builder schema reset failed, attempting deployment anyway"
    fi

    # Create non-public schemas before migrations (custom, options_sets)
    print_info "Creating non-public database schemas..."
    if run_in_dir "data-builder-api" "$service_dir" \
        "npx prisma db execute --schema=./prisma-core/schema.prisma --stdin <<< 'CREATE SCHEMA IF NOT EXISTS \"custom\"; CREATE SCHEMA IF NOT EXISTS \"options_sets\";'" \
        "Creating custom and options_sets schemas"; then
        print_success "Non-public schemas created"
    else
        print_warning "Failed to create non-public schemas, may already exist or migrations will handle it"
    fi

    if run_in_dir "data-builder-api" "$service_dir" \
        "npx prisma migrate deploy --schema=./prisma-core/schema.prisma" \
        "Deploying core schema migrations"; then

        if run_in_dir "data-builder-api" "$service_dir" \
            "npx prisma migrate deploy --schema=./prisma-data-builder/schema.prisma" \
            "Deploying data-builder schema migrations"; then

            if run_in_dir "data-builder-api" "$service_dir" \
                "npm run db:seed:data-builder" \
                "Seeding data-builder data" \
                true; then

                SUCCESSFUL_RESETS+=("data-builder-api")
                print_success "data-builder-api reset completed"
            else
                print_warning "Migrations completed but seed failed"
                PARTIAL_RESETS+=("data-builder-api")
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

print_section "Starting Database Reset for Client: $CLIENT"

# Show what will be reset
if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
    echo "This will reset ALL databases for client '$CLIENT' (BOTH environments):"
else
    echo "This will reset SELECTED services for client '$CLIENT':"
    echo ""
    echo "Selected services:"
    for service in "${SELECTED_SERVICES[@]}"; do
        echo "  - $service"
    done
fi

echo ""
echo "Environments:"
echo "  - sandbox (development/testing)"
echo "  - workflows (production)"
echo ""
echo "⚠️  WARNING: This will DELETE ALL DATA in these databases!"
echo ""
read -p "Type 'DELETE ALL DATA' to confirm: " confirmation

if [ "$confirmation" != "DELETE ALL DATA" ]; then
    print_error "Reset cancelled - confirmation not received"
    exit 1
fi

print_info "Confirmation received. Proceeding with reset..."

# Execute resets for both environments
# Note: "workflows" is technically the production environment (technical debt naming)
if should_reset_service "los-core-api"; then
    reset_los_core_api "$CLIENT" "sandbox"
    reset_los_core_api "$CLIENT" "workflows"
fi

if should_reset_service "los-integrations"; then
    reset_los_integrations "$CLIENT" "sandbox"
    reset_los_integrations "$CLIENT" "workflows"
fi

# Services with shared workflow databases
if should_reset_service "sequence-builder-api"; then
    reset_sequence_builder_api "$CLIENT"
fi

if should_reset_service "ui-builder-api"; then
    reset_ui_builder_api "$CLIENT"
fi

if should_reset_service "workflow-api"; then
    reset_workflow_api "$CLIENT"
fi

if should_reset_service "data-builder-api"; then
    reset_data_builder_api "$CLIENT"
fi

# ============================================================================
# SUMMARY
# ============================================================================

print_section "Reset Summary"

if [ ${#SUCCESSFUL_RESETS[@]} -gt 0 ]; then
    echo -e "${GREEN}Fully successful (${#SUCCESSFUL_RESETS[@]}):${NC}"
    for service in "${SUCCESSFUL_RESETS[@]}"; do
        echo -e "  ${GREEN}✓${NC} $service"
    done
    echo ""
fi

if [ ${#PARTIAL_RESETS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Partial success - migrations completed but seed failed (${#PARTIAL_RESETS[@]}):${NC}"
    for service in "${PARTIAL_RESETS[@]}"; do
        echo -e "  ${YELLOW}⚠${NC} $service (migrations only)"
    done
    echo ""
fi

if [ ${#FAILED_RESETS[@]} -gt 0 ]; then
    echo -e "${RED}Failed resets (${#FAILED_RESETS[@]}):${NC}"
    for service in "${FAILED_RESETS[@]}"; do
        echo -e "  ${RED}✗${NC} $service"
    done
    echo ""
fi

# Determine overall result
if [ ${#FAILED_RESETS[@]} -gt 0 ]; then
    print_error "Some services failed to reset completely. Check logs above for details."
    exit 1
elif [ ${#PARTIAL_RESETS[@]} -gt 0 ]; then
    print_warning "Reset completed with warnings: Some services have migrations but seed failed."
    print_info "Services with partial success need manual seed execution or Node version fix."
    print_info "You can verify seeds with: npm run verify:seeds -- $CLIENT"
    exit 1
else
    print_success "All databases reset successfully!"
    print_info "You can now verify the seeds with: npm run verify:seeds -- $CLIENT"
fi
