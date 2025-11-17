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

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
BE_DIR="$PROJECT_ROOT/BE"
CLIENT="${1:-onb-1}"

print_section "Testing sequence-builder-api Reset for Client: $CLIENT"

# Verify AWS credentials
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS credentials not configured or expired"
    echo "Please run: aws sso login --profile <your-profile>"
    exit 1
fi

print_success "AWS credentials validated"

# Get secret
secret_id="$CLIENT/workflows/sequence-builder-api/config"
service_dir="$BE_DIR/sequence-builder-api"

print_info "Fetching secret: $secret_id"
secret_json=$(aws secretsmanager get-secret-value \
    --secret-id "$secret_id" \
    --region us-east-2 \
    --query 'SecretString' \
    --output text 2>&1)

if [ $? -ne 0 ]; then
    print_error "Failed to fetch secret"
    exit 1
fi

# Create temporary .env
if [ -f "$service_dir/.env" ]; then
    print_info "Backing up existing .env"
    mv "$service_dir/.env" "$service_dir/.env.backup"
fi

print_info "Creating temporary .env"
echo "$secret_json" | jq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$service_dir/.env"

# Run migrations and seed with Node version switching
print_info "Changing to $service_dir"
cd "$service_dir"

# Prepare nvm setup
nvm_setup='export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"; nvm use > /dev/null 2>&1;'

print_section "Step 1: Reset Database Schema"
if (eval "$nvm_setup"; set -a; source .env; set +a; npx prisma migrate reset --force --skip-seed) 2>&1 | tee /tmp/seq-builder-reset.log; then
    print_success "Schema reset completed"
else
    print_error "Schema reset failed"
fi

print_section "Step 2: Deploy Prisma Migrations"
if (eval "$nvm_setup"; set -a; source .env; set +a; npx prisma migrate deploy) 2>&1 | tee /tmp/seq-builder-migrate.log; then
    print_success "Migrations completed"
else
    print_error "Migrations failed"
    exit 1
fi

print_section "Step 3: Seed Initial Version"
print_info "Node version that will be used:"
(eval "$nvm_setup"; node --version)

if (eval "$nvm_setup"; set -a; source .env; set +a; npm run seed) 2>&1 | tee /tmp/seq-builder-seed.log; then
    print_success "Seed completed successfully!"
else
    print_error "Seed failed"
    echo ""
    echo "Last 50 lines of output:"
    tail -50 /tmp/seq-builder-seed.log
    exit 1
fi

# Restore original .env
if [ -f "$service_dir/.env.backup" ]; then
    print_info "Restoring original .env"
    mv "$service_dir/.env.backup" "$service_dir/.env"
else
    rm -f "$service_dir/.env"
fi

print_section "✅ Test Complete!"
print_success "sequence-builder-api reset and seed completed successfully"
