#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
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
CLIENT="${1:-}"
SECRET_ID="${2:-}"

print_section "Fix DATABASE_URL in AWS Secrets Manager"

if [ -z "$CLIENT" ]; then
    print_error "Client parameter is required!"
    echo ""
    echo "Usage: $0 <client-name> <secret-id>"
    echo ""
    echo "Example: $0 onb-1 onb-1/workflows/los-integrations/config"
    exit 1
fi

if [ -z "$SECRET_ID" ]; then
    print_error "Secret ID parameter is required!"
    echo ""
    echo "Usage: $0 <client-name> <secret-id>"
    echo ""
    echo "Example: $0 onb-1 onb-1/workflows/los-integrations/config"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    print_error "AWS credentials not configured or expired"
    echo "Please run: aws sso login --profile <your-profile>"
    exit 1
fi

print_success "AWS credentials validated"

# Fetch current secret
print_info "Fetching current secret: $SECRET_ID"
CURRENT_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region us-east-2 \
    --query 'SecretString' \
    --output text 2>&1)

if [ $? -ne 0 ]; then
    print_error "Failed to fetch secret: $SECRET_ID"
    echo "$CURRENT_SECRET"
    exit 1
fi

print_success "Secret fetched successfully"

# Extract current DATABASE_URL
CURRENT_DB_URL=$(echo "$CURRENT_SECRET" | jq -r '.DATABASE_URL')
print_info "Current DATABASE_URL:"
echo "  $CURRENT_DB_URL"

# Extract password from current URL (between postgres:// and @)
CURRENT_PASSWORD=$(echo "$CURRENT_DB_URL" | sed -n 's/.*postgres:\/\/postgres:\([^@]*\)@.*/\1/p')

# Try to URL decode the password
DECODED_PASSWORD=$(node -e "try { console.log(decodeURIComponent('$CURRENT_PASSWORD')); } catch(e) { console.log('INVALID_ENCODING'); }" 2>/dev/null)

DB_HOST=$(echo "$CURRENT_DB_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
DB_NAME=$(echo "$CURRENT_DB_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')

# Test if current password works
PASSWORD_WORKS=false

if [ "$DECODED_PASSWORD" != "INVALID_ENCODING" ]; then
    print_info "Testing current password..."
    export PGPASSWORD="$DECODED_PASSWORD"

    if psql -h "$DB_HOST" -U postgres -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
        PASSWORD_WORKS=true
        print_success "Current password works!"
        CORRECT_PASSWORD="$DECODED_PASSWORD"
    fi
fi

# If current password doesn't work or has invalid encoding, get from sandbox
if [ "$PASSWORD_WORKS" = false ]; then
    if [ "$DECODED_PASSWORD" = "INVALID_ENCODING" ]; then
        print_warning "Current DATABASE_URL has invalid URL encoding"
    else
        print_warning "Current password does NOT work"
    fi

    print_info "Fetching correct password from sandbox config..."
    SANDBOX_SECRET=$(aws secretsmanager get-secret-value \
        --secret-id "$CLIENT/sandbox/los-integrations/config" \
        --region us-east-2 \
        --query 'SecretString' \
        --output text 2>&1)

    if [ $? -ne 0 ]; then
        print_error "Failed to fetch sandbox secret for reference"
        exit 1
    fi

    SANDBOX_DB_URL=$(echo "$SANDBOX_SECRET" | jq -r '.DATABASE_URL')
    SANDBOX_PASSWORD=$(echo "$SANDBOX_DB_URL" | sed -n 's/.*postgres:\/\/postgres:\([^@]*\)@.*/\1/p')
    CORRECT_PASSWORD=$(node -e "console.log(decodeURIComponent('$SANDBOX_PASSWORD'))")

    print_info "Password from sandbox: $CORRECT_PASSWORD"

    # Test the sandbox password
    export PGPASSWORD="$CORRECT_PASSWORD"
    if ! psql -h "$DB_HOST" -U postgres -d "$DB_NAME" -c "SELECT 1;" > /dev/null 2>&1; then
        print_error "Even the sandbox password doesn't work! Manual investigation needed."
        exit 1
    fi

    print_success "Sandbox password verified - will use this one"
fi

# Create properly URL-encoded DATABASE_URL
print_info "Creating properly URL-encoded DATABASE_URL..."
CORRECTLY_ENCODED=$(node -e "console.log(encodeURIComponent('$CORRECT_PASSWORD'))")
NEW_DB_URL=$(echo "$CURRENT_DB_URL" | sed "s|postgres://postgres:[^@]*@|postgres://postgres:$CORRECTLY_ENCODED@|")

print_info "New DATABASE_URL:"
echo "  $NEW_DB_URL"

# Ask for confirmation
echo ""
print_warning "⚠️  This will UPDATE the secret in AWS Secrets Manager!"
echo ""
read -p "Type 'UPDATE SECRET' to confirm: " confirmation

if [ "$confirmation" != "UPDATE SECRET" ]; then
    print_error "Update cancelled - confirmation not received"
    exit 1
fi

# Update the secret
print_info "Updating secret with corrected DATABASE_URL..."

# Parse the entire secret as JSON and update just the DATABASE_URL field
UPDATED_SECRET=$(echo "$CURRENT_SECRET" | jq --arg new_url "$NEW_DB_URL" '.DATABASE_URL = $new_url')

# Update the secret in AWS
aws secretsmanager put-secret-value \
    --secret-id "$SECRET_ID" \
    --region us-east-2 \
    --secret-string "$UPDATED_SECRET" > /dev/null 2>&1

if [ $? -ne 0 ]; then
    print_error "Failed to update secret"
    exit 1
fi

print_success "Secret updated successfully!"

# Verify the update
print_info "Verifying updated secret..."
VERIFY_SECRET=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --region us-east-2 \
    --query 'SecretString' \
    --output text 2>&1)

VERIFY_DB_URL=$(echo "$VERIFY_SECRET" | jq -r '.DATABASE_URL')

if [ "$VERIFY_DB_URL" = "$NEW_DB_URL" ]; then
    print_success "Verification passed - DATABASE_URL updated correctly!"
else
    print_error "Verification failed - DATABASE_URL mismatch"
    echo "Expected: $NEW_DB_URL"
    echo "Got: $VERIFY_DB_URL"
    exit 1
fi

print_section "Summary"
echo -e "${GREEN}✓${NC} Secret updated: $SECRET_ID"
echo -e "${GREEN}✓${NC} DATABASE_URL has been corrected"
echo ""
print_info "You can now run the reset script successfully!"
