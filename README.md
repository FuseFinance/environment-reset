# Fuse Platform - Environment Reset Tools

A comprehensive toolkit for resetting and reseeding databases across all Fuse Platform services.

## Overview

This project contains all the scripts needed to reset environments to a clean state with fresh seed data. It supports both local execution (with AWS Secrets Manager) and Kubernetes-based execution (in deployed environments).

## Directory Structure

```
environment-reset/
├── scripts/               # All reset and verification scripts
│   ├── reset-environment.sh              # Local reset with clean repos
│   ├── reset-and-reseed-all-databases.sh # Kubernetes-based reset
│   ├── reset-workflow-repos.sh           # Reset workflow GitHub repos
│   ├── verify-seeds.sh                   # Verify seeds after reset
│   └── check-deployment-status.sh        # Check K8s deployment status
├── docs/                  # Documentation
│   ├── DATABASE-RESET-GUIDE.md           # Detailed reset procedures
│   ├── SAFETY-GUARANTEES.md              # Safety mechanisms
│   └── ERROR-DETECTION-EXAMPLES.md       # Common errors and fixes
├── package.json           # npm scripts for easy execution
└── README.md              # This file
```

## Prerequisites

### All Operations
- AWS CLI configured (`aws sso login`)
- Access to AWS Secrets Manager (us-east-2)
- Appropriate IAM permissions

### Local Reset
- Node.js and npm installed
- Git CLI
- PostgreSQL client (`psql`) for verification
- `jq` for JSON parsing

### Kubernetes Reset
- `kubectl` configured and authenticated
- Access to the target Kubernetes cluster
- Proper RBAC permissions to exec into pods

### Workflow Reset
- Git CLI with SSH access to GitHub
- Permissions to force push to workflow repositories

## Quick Start

### View Available Commands

```bash
npm run help
```

### Reset Local Environment

Reset a local environment by pulling credentials from AWS Secrets Manager and executing commands in local service directories:

```bash
npm run reset:local:simple onb-1
```

**⚠️ Important: Before Resetting**

1. **Ensure latest versions are deployed**: Make sure all services have their latest versions deployed to the target environment before running a reset. The reset script will use the code from your local repositories, so ensure your local code matches what's deployed.

2. **Update local repositories**: The reset script automatically:
   - Checks out `main` branch on each service repository
   - Pulls latest changes from `origin/main`
   - Installs/updates dependencies
   - Generates Prisma clients if needed

This will:
1. Checkout main branch and pull latest changes for each service
2. Install/update dependencies (npm install)
3. Generate Prisma clients if needed
4. Fetch credentials from AWS Secrets Manager
5. Run migrations and seeds for all services

**Safety**: Only works with `onb-*` clients to prevent accidental production resets.

### Reset Kubernetes Environment

Reset a deployed environment by executing commands in Kubernetes pods:

```bash
npm run reset:k8s los-demo sandbox
npm run reset:k8s los-demo production
```

This will:
1. Validate safety checks (client whitelist, namespace isolation)
2. Run pre-flight checks (credentials, database connections)
3. Execute migrations and seeds in pods
4. Provide detailed progress and error reporting

**Supported clients**: los-demo, qa, dev, qa-poc, onb-1 through onb-8

### Reset Workflow Repositories

Reset a client's workflow GitHub repository to its initial commit:

```bash
npm run reset:workflows los-demo
npm run reset:workflows qa --dry-run  # Preview without changes
```

**Warning**: This force pushes to GitHub, overwriting all workflows!

### Verify Seeds

Verify that all databases were seeded correctly:

```bash
npm run verify:seeds onb-1
```

This checks:
- Version records
- Default workflows (6 expected)
- Integration counts (40+ expected)
- Dealer records
- UI pages and collections
- Data builder seeds

### Check Deployment Status

Check the status of all services in a Kubernetes namespace:

```bash
npm run check:deployment los-demo-sandbox
```

## Services Reset

The reset operations affect the following services and databases:

| Service | Database | Environment | ORM |
|---------|----------|-------------|-----|
| los-core-api | los-sandbox / los-production | Separate | Prisma |
| los-integrations | integrations | Separate | Prisma |
| sequence-builder-api | sequence-builder | Shared | Prisma |
| ui-builder-api | ui-builder | Shared | Prisma |
| workflow-api | workflow-builder | Shared | TypeORM |
| data-builder-api | data-builder + core | Shared | Prisma (2 schemas) |

## Safety Mechanisms

### Client Whitelist
Only pre-approved clients can be reset (prevents accidental production resets).

### Namespace Isolation
Kubernetes operations are isolated to specific namespaces (e.g., `los-demo-sandbox`).

### Confirmation Prompts
All destructive operations require explicit user confirmation.

### Pre-flight Checks
- Validates AWS credentials
- Checks database connectivity
- Verifies environment variables
- Tests CLI tool availability

### Dry-run Mode
Most scripts support `--dry-run` to preview changes without execution.

## Common Workflows

### Full Environment Reset (Local)

```bash
# 1. Ensure latest versions are deployed to the environment
#    (Verify deployments are up-to-date before proceeding)

# 2. Reset all databases (automatically updates local repos to latest)
npm run reset:local:simple onb-1

# 3. Verify seeds
npm run verify:seeds onb-1

# 4. Reset workflows (if needed)
npm run reset:workflows onb-1
```

### Full Environment Reset (Kubernetes)

```bash
# 1. Check deployment status
npm run check:deployment los-demo-sandbox

# 2. Reset databases
npm run reset:k8s los-demo sandbox

# 3. Verify seeds
npm run verify:seeds los-demo

# 4. Reset workflows (manual step)
npm run reset:workflows los-demo
```

### Reset Only Workflows

```bash
# Preview changes
npm run reset:workflows qa -- --dry-run

# Execute reset
npm run reset:workflows qa
```

## Seed Data Created

After a successful reset, the following seed data is created:

### los-core-api
- System data (roles, permissions, queues)
- Test dealer (code: VI2JX, name: "Demo Dealer")

### los-integrations
- 40+ integration configurations
- 5+ integration categories
- Integration field mappings

### sequence-builder-api
- Initial version (v0.0.0)

### ui-builder-api
- 11 core pages
- Core collections
- 11 application menu items
- Platform settings

### workflow-api
- Initial version
- GitHub repository configuration
- 6 default workflows:
  - adapter-routeone-response
  - email-configuration
  - funding
  - pages
  - underwriting
  - webhook

### data-builder-api
- Initial version
- Data builder configuration

## Troubleshooting

### AWS Credentials Expired

```bash
aws sso login --profile <your-profile>
```

### Kubectl Context Not Set

```bash
kubectl config get-contexts
kubectl config use-context <context-name>
```

### Service Not Found in Namespace

Check if the service is deployed:

```bash
kubectl get pods -n <namespace>
```

### Migration Failures

Check the service logs:

```bash
kubectl logs -n <namespace> <pod-name>
```

### Seed Verification Failures

Re-run the reset and check for errors:

```bash
npm run reset:k8s <client> <environment>
npm run verify:seeds <client>
```

## Path Configuration

All scripts use **relative paths** from the `environment-reset` directory:

- Backend services: `../../BE/`
- Project root: `../../../`

This makes the project portable and independent of absolute paths.

## Error Handling

All scripts include:
- Proper error detection and reporting
- Cleanup handlers (trap EXIT/INT/TERM)
- Detailed logs saved to `/tmp/`
- Color-coded output for easy scanning

## Support

For issues or questions:
1. Check the [DATABASE-RESET-GUIDE.md](docs/DATABASE-RESET-GUIDE.md) for detailed procedures
2. Review [ERROR-DETECTION-EXAMPLES.md](docs/ERROR-DETECTION-EXAMPLES.md) for common errors
3. Contact the DevOps team

## License

UNLICENSED - Internal use only
