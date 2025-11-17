#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_section() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
}

print_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

print_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
}

print_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
}

CLIENT="${1:-onb-1}"

# Safety check: Only allow onb-* clients
if [[ ! "$CLIENT" =~ ^onb- ]]; then
    echo -e "${RED}ERROR: This script can ONLY verify sandbox clients (onb-*).${NC}"
    exit 1
fi

print_section "Seed Verification for $CLIENT (BOTH sandbox and production)"

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Helper function to run query
run_query() {
    local db_host=$1
    local db_name=$2
    local db_user=$3
    local db_pass=$4
    local query=$5

    PGPASSWORD="$db_pass" psql -h "$db_host" -p 5432 -U "$db_user" -d "$db_name" -t -c "$query" 2>/dev/null | xargs
}

# ============================================================================
# 1. WORKFLOW-API VERIFICATION
# ============================================================================

print_section "1/6: workflow-api (workflow-builder database)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/workflows/workflow-api/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    PGPASSWORD=$(echo "$SECRET" | jq -r ".POSTGRES_PASSWORD")
    DB_HOST=$(echo "$SECRET" | jq -r ".POSTGRES_HOST")
    DB_USER=$(echo "$SECRET" | jq -r ".POSTGRES_USER")

    # Check version
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    VERSION_COUNT=$(run_query "$DB_HOST" "workflow-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM version;")
    if [ "$VERSION_COUNT" = "1" ]; then
        print_pass "Version record exists (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected 1 version, found $VERSION_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check workflows
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    WORKFLOW_COUNT=$(run_query "$DB_HOST" "workflow-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM workflow;")
    if [ "$WORKFLOW_COUNT" = "6" ]; then
        print_pass "Default workflows seeded (6)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))

        # List workflows
        echo "  Workflows:"
        PGPASSWORD="$PGPASSWORD" psql -h "$DB_HOST" -p 5432 -U "$DB_USER" -d "workflow-builder" -t -c "SELECT '    - ' || wv.name || ' (' || wv.slug || ')' FROM workflow_version wv ORDER BY wv.name;" 2>/dev/null
    else
        print_fail "Expected 6 workflows, found $WORKFLOW_COUNT"
        echo "  Expected workflows:"
        echo "    - adapter-routeone-response"
        echo "    - email-configuration"
        echo "    - funding"
        echo "    - pages"
        echo "    - underwriting"
        echo "    - webhook"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check environment_version
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    ENV_VERSION_COUNT=$(run_query "$DB_HOST" "workflow-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM environment_version;")
    if [ "$ENV_VERSION_COUNT" -ge "1" ]; then
        print_pass "Environment version record exists ($ENV_VERSION_COUNT)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "No environment_version records found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
else
    print_fail "Could not fetch secrets for workflow-api"
    FAILED_CHECKS=$((FAILED_CHECKS + 3))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 3))
fi

# ============================================================================
# 2. SEQUENCE-BUILDER-API VERIFICATION
# ============================================================================

print_section "2/6: sequence-builder-api (sequence-builder database)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/workflows/sequence-builder-api/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    # Check version
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    VERSION_COUNT=$(run_query "$DB_HOST" "sequence-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM version;")
    if [ "$VERSION_COUNT" = "1" ]; then
        print_pass "Version record exists (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected 1 version, found $VERSION_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Note: Seed only creates version, not sequences
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    SEQUENCE_COUNT=$(run_query "$DB_HOST" "sequence-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM sequence;")
    if [ "$SEQUENCE_COUNT" = "0" ]; then
        print_pass "No sequences (seed only creates version)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_warn "Found $SEQUENCE_COUNT sequences (seed doesn't create these, may be old data)"
        WARNINGS=$((WARNINGS + 1))
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    fi
else
    print_fail "Could not fetch secrets for sequence-builder-api"
    FAILED_CHECKS=$((FAILED_CHECKS + 2))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 2))
fi

# ============================================================================
# 3. UI-BUILDER-API VERIFICATION
# ============================================================================

print_section "3/6: ui-builder-api (ui-builder database)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/workflows/ui-builder-api/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    VERSION_ID="cfb47945-75bb-4c03-8315-ed18d2fe4750"

    # Check version
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    VERSION_COUNT=$(run_query "$DB_HOST" "ui-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM version WHERE id = '$VERSION_ID';")
    if [ "$VERSION_COUNT" = "1" ]; then
        print_pass "Version record exists (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Version record not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check pages
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PAGE_COUNT=$(run_query "$DB_HOST" "ui-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM page WHERE version_id = '$VERSION_ID';")
    if [ "$PAGE_COUNT" = "11" ]; then
        print_pass "Core pages seeded (11)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected 11 pages, found $PAGE_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check collections
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    COLLECTION_COUNT=$(run_query "$DB_HOST" "ui-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM collection WHERE version_id = '$VERSION_ID' AND is_core = true;")
    if [ "$COLLECTION_COUNT" -ge "2" ]; then
        print_pass "Core collections seeded ($COLLECTION_COUNT)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected at least 2 core collections, found $COLLECTION_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check menu items
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    MENU_COUNT=$(run_query "$DB_HOST" "ui-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM application_menu_item WHERE version_id = '$VERSION_ID';")
    if [ "$MENU_COUNT" = "11" ]; then
        print_pass "Application menu items seeded (11)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected 11 menu items, found $MENU_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check platform settings
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    PLATFORM_SETTINGS_COUNT=$(run_query "$DB_HOST" "ui-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM platform_settings WHERE version_id = '$VERSION_ID';")
    if [ "$PLATFORM_SETTINGS_COUNT" = "1" ]; then
        print_pass "Platform settings created (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected 1 platform settings record, found $PLATFORM_SETTINGS_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
else
    print_fail "Could not fetch secrets for ui-builder-api"
    FAILED_CHECKS=$((FAILED_CHECKS + 5))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 5))
fi

# ============================================================================
# 4. LOS-CORE-API VERIFICATION (SANDBOX)
# ============================================================================

print_section "4a/7: los-core-api (sandbox)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/sandbox/los-core-api/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    # Check dealer
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    DEALER_COUNT=$(run_query "$DB_HOST" "los-sandbox" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM dealer;")
    if [ "$DEALER_COUNT" = "1" ]; then
        print_pass "Test dealer seeded (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))

        # Show dealer info
        DEALER_CODE=$(run_query "$DB_HOST" "los-sandbox" "$DB_USER" "$PGPASSWORD" "SELECT code FROM dealer LIMIT 1;")
        DEALER_NAME=$(run_query "$DB_HOST" "los-sandbox" "$DB_USER" "$PGPASSWORD" "SELECT name FROM dealer LIMIT 1;")
        echo "  Dealer: $DEALER_NAME (code: $DEALER_CODE)"
    else
        print_fail "Expected 1 dealer, found $DEALER_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
else
    print_fail "Could not fetch secrets for los-core-api (sandbox)"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
fi

# ============================================================================
# 4B. LOS-CORE-API VERIFICATION (PRODUCTION)
# ============================================================================

print_section "4b/7: los-core-api (production)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/production/los-core-api/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    # Check dealer
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    DEALER_COUNT=$(run_query "$DB_HOST" "los-production" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM dealer;")
    if [ "$DEALER_COUNT" = "1" ]; then
        print_pass "Test dealer seeded (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))

        # Show dealer info
        DEALER_CODE=$(run_query "$DB_HOST" "los-production" "$DB_USER" "$PGPASSWORD" "SELECT code FROM dealer LIMIT 1;")
        DEALER_NAME=$(run_query "$DB_HOST" "los-production" "$DB_USER" "$PGPASSWORD" "SELECT name FROM dealer LIMIT 1;")
        echo "  Dealer: $DEALER_NAME (code: $DEALER_CODE)"
    else
        print_fail "Expected 1 dealer, found $DEALER_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
else
    print_fail "Could not fetch secrets for los-core-api (production)"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
fi

# ============================================================================
# 5A. LOS-INTEGRATIONS VERIFICATION (SANDBOX)
# ============================================================================

print_section "5a/7: los-integrations (sandbox)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/sandbox/los-integrations/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    # Check integrations (table name is plural: integrations)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    INTEGRATION_COUNT=$(run_query "$DB_HOST" "integrations" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM integrations;")
    if [ "$INTEGRATION_COUNT" -ge "40" ]; then
        print_pass "Integrations seeded ($INTEGRATION_COUNT)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected at least 40 integrations, found $INTEGRATION_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check categories (table name is plural: categories)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    CATEGORY_COUNT=$(run_query "$DB_HOST" "integrations" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM categories;")
    if [ "$CATEGORY_COUNT" -ge "5" ]; then
        print_pass "Integration categories seeded ($CATEGORY_COUNT)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected at least 5 categories, found $CATEGORY_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # List categories
    echo "  Categories:"
    PGPASSWORD="$PGPASSWORD" psql -h "$DB_HOST" -p 5432 -U "$DB_USER" -d "integrations" -t -c "SELECT '    - ' || name FROM categories ORDER BY name;" 2>/dev/null
else
    print_fail "Could not fetch secrets for los-integrations (sandbox)"
    FAILED_CHECKS=$((FAILED_CHECKS + 2))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 2))
fi

# ============================================================================
# 5B. LOS-INTEGRATIONS VERIFICATION (PRODUCTION)
# ============================================================================

print_section "5b/7: los-integrations (production)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/production/los-integrations/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    # Check integrations (table name is plural: integrations)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    INTEGRATION_COUNT=$(run_query "$DB_HOST" "integrations" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM integrations;")
    if [ "$INTEGRATION_COUNT" -ge "40" ]; then
        print_pass "Integrations seeded ($INTEGRATION_COUNT)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected at least 40 integrations, found $INTEGRATION_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # Check categories (table name is plural: categories)
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    CATEGORY_COUNT=$(run_query "$DB_HOST" "integrations" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM categories;")
    if [ "$CATEGORY_COUNT" -ge "5" ]; then
        print_pass "Integration categories seeded ($CATEGORY_COUNT)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected at least 5 categories, found $CATEGORY_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi

    # List categories
    echo "  Categories:"
    PGPASSWORD="$PGPASSWORD" psql -h "$DB_HOST" -p 5432 -U "$DB_USER" -d "integrations" -t -c "SELECT '    - ' || name FROM categories ORDER BY name;" 2>/dev/null
else
    print_fail "Could not fetch secrets for los-integrations (production)"
    FAILED_CHECKS=$((FAILED_CHECKS + 2))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 2))
fi

# ============================================================================
# 6. DATA-BUILDER-API VERIFICATION
# ============================================================================

print_section "6/7: data-builder-api (data-builder database)"

SECRET=$(aws secretsmanager get-secret-value --secret-id "$CLIENT/workflows/data-builder-api/config" --region us-east-2 --query SecretString --output text 2>/dev/null)
if [ $? -eq 0 ]; then
    # data-builder-api uses DATA_BUILDER_DATABASE_URL (not DATABASE_URL)
    DATABASE_URL=$(echo "$SECRET" | jq -r ".DATA_BUILDER_DATABASE_URL")
    PGPASSWORD=$(echo "$DATABASE_URL" | sed -n "s/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p")
    DB_HOST=$(echo "$DATABASE_URL" | sed -n "s/.*@\([^:]*\):.*/\1/p")
    DB_USER="postgres"

    # Check version
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    VERSION_COUNT=$(run_query "$DB_HOST" "data-builder" "$DB_USER" "$PGPASSWORD" "SELECT COUNT(*) FROM version;")
    if [ "$VERSION_COUNT" = "1" ]; then
        print_pass "Version record exists (1)"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        print_fail "Expected 1 version, found $VERSION_COUNT"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
else
    print_fail "Could not fetch secrets for data-builder-api"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================

print_section "Verification Summary"

echo -e "Total checks: $TOTAL_CHECKS"
echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
if [ $FAILED_CHECKS -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED_CHECKS${NC}"
fi
if [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Warnings: $WARNINGS${NC}"
fi
echo ""

PERCENTAGE=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))

if [ $FAILED_CHECKS -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}✓ ALL CHECKS PASSED ($PERCENTAGE%)${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}✗ SOME CHECKS FAILED ($PERCENTAGE% passed)${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "To fix issues, run:"
    echo "  cd ~/Sites/fuse/BE/scripts && bash reset-environment.sh $CLIENT"
    exit 1
fi
