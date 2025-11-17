#!/bin/bash

###############################################################################
# Reset Workflow GitHub Repositories to Initial Commit
#
# This script resets client workflow repositories to their initial commit.
# Each client has a dedicated workflow repository (e.g., los-demo-workflows).
#
# Usage:
#   ./reset-workflow-repos.sh <client> [--dry-run]
#
# Examples:
#   ./reset-workflow-repos.sh los-demo
#   ./reset-workflow-repos.sh qa --dry-run
#
# Prerequisites:
#   - git CLI installed
#   - SSH access to GitHub (FuseFinance org)
#   - Proper permissions to force push
#
# WARNING: This will force push to the repository, overwriting all workflows!
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=false
CLIENT=""
REPO_NAME=""
GITHUB_ORG="FuseFinance"

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

show_usage() {
    echo "Usage: $0 <client> [--dry-run]"
    echo ""
    echo "Arguments:"
    echo "  client      Client name (e.g., los-demo, qa, acusi)"
    echo ""
    echo "Options:"
    echo "  --dry-run   Show what would be done without making changes"
    echo ""
    echo "Examples:"
    echo "  $0 los-demo"
    echo "  $0 qa --dry-run"
    echo ""
}

confirm() {
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ⚠️  WARNING: This will OVERWRITE the workflow repository!        ║${NC}"
    echo -e "${YELLOW}║                                                                    ║${NC}"
    echo -e "${YELLOW}║  Repository: $REPO_NAME${NC}"
    echo -e "${YELLOW}║  All workflows will be reset to the initial commit.              ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "$(echo -e ${YELLOW}Type \'RESET WORKFLOWS\' to continue: ${NC})" response

    if [ "$response" != "RESET WORKFLOWS" ]; then
        print_error "Operation cancelled by user"
        exit 1
    fi
}

# Parse arguments
if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

CLIENT=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            print_warning "DRY-RUN MODE: No changes will be made"
            shift
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Determine repository name
REPO_NAME="${CLIENT}-workflows"
REPO_URL="git@github.com:${GITHUB_ORG}/${REPO_NAME}.git"
TEMP_DIR="/tmp/${REPO_NAME}-reset-$(date +%s)"

print_info "Configuration:"
print_info "  Client:     $CLIENT"
print_info "  Repository: $REPO_NAME"
print_info "  URL:        $REPO_URL"
print_info "  Dry-run:    $DRY_RUN"
echo ""

# Confirm the operation
if ! $DRY_RUN; then
    confirm
fi

# Clone the repository
print_info "Cloning repository to temporary directory..."
if $DRY_RUN; then
    print_warning "[DRY-RUN] Would clone: $REPO_URL"
else
    if ! git clone "$REPO_URL" "$TEMP_DIR"; then
        print_error "Failed to clone repository"
        print_info "Make sure you have SSH access to GitHub and the repository exists"
        exit 1
    fi
    print_success "Repository cloned to $TEMP_DIR"
fi

# Find initial commit
print_info "Finding initial commit..."
if ! $DRY_RUN; then
    cd "$TEMP_DIR"

    INITIAL_COMMIT=$(git log --reverse --oneline | head -1 | awk '{print $1}')

    if [ -z "$INITIAL_COMMIT" ]; then
        print_error "Could not find initial commit"
        exit 1
    fi

    INITIAL_MESSAGE=$(git log --reverse --oneline | head -1 | cut -d' ' -f2-)

    print_success "Initial commit found: $INITIAL_COMMIT"
    print_info "Commit message: $INITIAL_MESSAGE"
else
    print_warning "[DRY-RUN] Would find initial commit"
    INITIAL_COMMIT="abc1234"
fi

echo ""

# Reset to initial commit
print_info "Resetting to initial commit..."
if $DRY_RUN; then
    print_warning "[DRY-RUN] Would execute: git reset --hard $INITIAL_COMMIT"
else
    if ! git reset --hard "$INITIAL_COMMIT"; then
        print_error "Failed to reset to initial commit"
        exit 1
    fi
    print_success "Local repository reset to initial commit"
fi

# Force push
print_info "Force pushing to remote..."
if $DRY_RUN; then
    print_warning "[DRY-RUN] Would execute: git push --force origin main"
else
    if ! git push --force origin main; then
        print_error "Failed to force push to remote"
        print_warning "Local repository at $TEMP_DIR is still reset"
        print_info "You can manually push later with: cd $TEMP_DIR && git push --force"
        exit 1
    fi
    print_success "Workflows reset to initial commit on GitHub!"
fi

# Cleanup
if ! $DRY_RUN; then
    print_info "Cleaning up temporary directory..."
    cd - > /dev/null
    rm -rf "$TEMP_DIR"
    print_success "Cleanup complete"
fi

echo ""
print_success "═════════════════════════════════════════════════════"
print_success "  Workflow repository reset complete!"
print_success "═════════════════════════════════════════════════════"
echo ""

if $DRY_RUN; then
    echo -e "${YELLOW}DRY-RUN MODE: No actual changes were made${NC}"
    echo ""
fi

print_info "Repository: https://github.com/${GITHUB_ORG}/${REPO_NAME}"
print_info "Verify the reset at the GitHub repository"
echo ""
