# Error Detection Examples

This document shows examples of what you'll see when the script detects configuration errors **BEFORE** running any destructive operations.

---

## Example 1: Missing CLI Tools

If kubectl is not installed or configured:

```bash
$ ./reset-and-reseed-all-databases.sh onb-1 sandbox

═══════════════════════════════════════════════════════════
  Fuse Platform - Database Reset & Reseed
═══════════════════════════════════════════════════════════

[INFO] Configuration:
[INFO]   Client:      onb-1
[INFO]   Environment: sandbox
[INFO]   Namespace:   onb-1-sandbox
[INFO]   Dry-run:     false

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CLI TOOLS VALIDATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Checking required command-line tools...

[✗] kubectl is NOT installed
[INFO]   Install: https://kubernetes.io/docs/tasks/tools/

╔════════════════════════════════════════════════════════════════╗
║  MISSING REQUIRED TOOLS                                        ║
║                                                                ║
║  Install the required tools above before continuing.          ║
╚════════════════════════════════════════════════════════════════╝

[✗] Exiting...
```

---

## Example 2: kubectl Not Configured

If kubectl is installed but no context is configured:

```bash
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CLI TOOLS VALIDATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Checking required command-line tools...

[✓] kubectl is installed (Client Version: v1.28.0)
[✗]   ✗ No kubectl context configured
[INFO]     Run: kubectl config use-context <context-name>

╔════════════════════════════════════════════════════════════════╗
║  MISSING REQUIRED TOOLS                                        ║
║                                                                ║
║  Install the required tools above before continuing.          ║
╚════════════════════════════════════════════════════════════════╝
```

**Fix:**
```bash
# List available contexts
kubectl config get-contexts

# Use the correct context
kubectl config use-context arn:aws:eks:us-east-2:123456789:cluster/fuse-cluster
```

---

## Example 3: Missing DATABASE_URL

If a service is missing its database connection string:

```bash
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PRE-FLIGHT CHECKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Validating environment and credentials before proceeding...

[INFO] Checking: los-core-api (los-core-api-7d9f8b6c5-x9k2m)

[INFO] Validating los-core-api environment...
[✗]   ✗ DATABASE_URL is not set
[✓]   ✓ npm is available
[✓]   ✓ node_modules directory exists
[✓]   ✓ Prisma CLI is available

[✗] los-core-api has configuration errors - cannot proceed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PRE-FLIGHT CHECK RESULTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Services checked: 1
[✓] Passed: 0
[✗] Failed: 1

╔════════════════════════════════════════════════════════════════╗
║  CONFIGURATION ERRORS DETECTED                                 ║
║                                                                ║
║  Some services have missing credentials or configuration.     ║
║  Fix the errors above before proceeding.                      ║
╚════════════════════════════════════════════════════════════════╝

Do you want to continue anyway? (yes/no): _
```

**What's wrong:** The ExternalSecret for DATABASE_URL isn't synced to the pod.

**Fix:**
```bash
# Check external secret status
kubectl get externalsecrets -n onb-1-sandbox

# Check if secret exists
kubectl get secrets -n onb-1-sandbox

# Force refresh external secret
kubectl annotate externalsecret <name> -n onb-1-sandbox force-sync="$(date +%s)" --overwrite

# Restart pod to pick up new secret
kubectl rollout restart deployment los-core-api -n onb-1-sandbox
```

---

## Example 4: Database Connection Failed

If DATABASE_URL is set but database is unreachable:

```bash
[INFO] Checking: los-core-api (los-core-api-7d9f8b6c5-x9k2m)

[INFO] Validating los-core-api environment...
[✓]   ✓ DATABASE_URL is configured
[INFO]     Database: los-sandbox @ postgres-onb1-sandbox.abc123.us-east-2.rds.amazonaws.com
[✓]   ✓ npm is available
[✓]   ✓ node_modules directory exists
[✓]   ✓ Prisma CLI is available

[INFO] Testing database connection for los-core-api...
[✗]   ✗ Database connection failed
[✗]     Check DATABASE_URL and database accessibility

[✗] los-core-api database connection failed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PRE-FLIGHT CHECK RESULTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Services checked: 1
[✓] Passed: 0
[✗] Failed: 1

╔════════════════════════════════════════════════════════════════╗
║  CONFIGURATION ERRORS DETECTED                                 ║
║                                                                ║
║  Some services have missing credentials or configuration.     ║
║  Fix the errors above before proceeding.                      ║
╚════════════════════════════════════════════════════════════════╝
```

**Possible causes:**
1. RDS instance is stopped or terminated
2. Security group not allowing pod IP range
3. DATABASE_URL has wrong hostname/port
4. Database credentials are incorrect
5. VPN/network connectivity issue

**How to debug:**
```bash
# Test connection from pod
kubectl exec -n onb-1-sandbox los-core-api-abc123 -- sh -c 'npx prisma db execute --stdin <<< "SELECT 1"'

# Check RDS status (if using AWS RDS)
aws rds describe-db-instances --db-instance-identifier onb1-sandbox

# Check security groups
aws rds describe-db-instances --db-instance-identifier onb1-sandbox --query 'DBInstances[0].VpcSecurityGroups'

# Verify DATABASE_URL format
kubectl exec -n onb-1-sandbox los-core-api-abc123 -- sh -c 'echo $DATABASE_URL' | sed 's/:.*@/:***@/'
```

---

## Example 5: Missing Prisma CLI

If node_modules is missing or Prisma isn't installed:

```bash
[INFO] Validating los-core-api environment...
[✓]   ✓ DATABASE_URL is configured
[INFO]     Database: los-sandbox @ postgres-onb1-sandbox.abc123.us-east-2.rds.amazonaws.com
[✓]   ✓ npm is available
[⚠]   ⚠ node_modules directory not found (might be okay if using different layout)
[✗]   ✗ Prisma CLI not found

[✗] los-core-api has configuration errors - cannot proceed
```

**Possible causes:**
1. Pod build failed
2. npm install didn't run
3. Dockerfile doesn't copy node_modules
4. Using production image without dev dependencies

**Fix:**
Check the pod's Dockerfile and ensure Prisma is installed:
```dockerfile
RUN npm install
RUN npm install -g prisma  # If needed globally
```

---

## Example 6: data-builder Missing CORE_DATABASE_URL

data-builder-api requires TWO database URLs:

```bash
[INFO] Checking: data-builder-api (data-builder-api-4e7c9a2-n8m3p)

[INFO] Validating data-builder-api environment...
[✓]   ✓ DATABASE_URL is configured
[INFO]     Database: data-builder @ postgres-onb1-sandbox.abc123.us-east-2.rds.amazonaws.com
[✓]   ✓ npm is available
[✓]   ✓ node_modules directory exists
[✗]   ✗ CORE_DATABASE_URL is not set (required for data-builder)

[✗] data-builder-api has configuration errors - cannot proceed
```

**Fix:**
data-builder-api needs both:
- `DATABASE_URL` → points to data-builder schema
- `CORE_DATABASE_URL` → points to los-production/los-sandbox schema (shared with los-core-api)

Check ExternalSecret configuration:
```bash
kubectl get externalsecret data-builder-api -n onb-1-sandbox -o yaml
```

---

## Example 7: All Checks Pass ✅

When everything is configured correctly:

```bash
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  CLI TOOLS VALIDATION
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Checking required command-line tools...

[✓] kubectl is installed (Client Version: v1.28.0)
[INFO]   Current context: arn:aws:eks:us-east-2:123456789:cluster/fuse-cluster

[✓] argocd CLI is installed (v2.9.0) [optional]

[✓] aws CLI is installed (aws-cli/2.13.0) [optional]

[✓] All required CLI tools are available!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PRE-FLIGHT CHECKS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Validating environment and credentials before proceeding...

[INFO] Checking: los-core-api (los-core-api-7d9f8b6c5-x9k2m)

[INFO] Validating los-core-api environment...
[✓]   ✓ DATABASE_URL is configured
[INFO]     Database: los-sandbox @ postgres-onb1-sandbox.abc123.us-east-2.rds.amazonaws.com
[✓]   ✓ npm is available
[✓]   ✓ node_modules directory exists
[✓]   ✓ Prisma CLI is available

[INFO] Testing database connection for los-core-api...
[✓]   ✓ Database connection successful

[✓] los-core-api passed all pre-flight checks

[INFO] Checking: los-integrations (los-integrations-8c4d7a5b-p3n8j)

[INFO] Validating los-integrations environment...
[✓]   ✓ DATABASE_URL is configured
[INFO]     Database: integrations @ postgres-onb1-sandbox.abc123.us-east-2.rds.amazonaws.com
[✓]   ✓ npm is available
[✓]   ✓ node_modules directory exists
[✓]   ✓ Prisma CLI is available

[INFO] Testing database connection for los-integrations...
[✓]   ✓ Database connection successful

[✓] los-integrations passed all pre-flight checks

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  PRE-FLIGHT CHECK RESULTS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

[INFO] Services checked: 2
[✓] Passed: 2

[✓] All pre-flight checks passed!

[INFO] Services that will be reset:
  1. los-core-api (sandbox database)
  2. los-integrations
  ...

Type 'DELETE ALL DATA' to continue: _
```

---

## Summary of Checks

The script performs these validations **BEFORE** any destructive operations:

### CLI Tools (runs first)
- ✅ kubectl installed
- ✅ kubectl context configured
- ⚠️ argocd installed (optional)
- ⚠️ aws CLI installed (optional)

### Per-Service Checks
- ✅ `DATABASE_URL` is set
- ✅ Database connection works
- ✅ npm/node is available
- ✅ Prisma or TypeORM CLI is available
- ✅ node_modules exists
- ✅ Service-specific requirements

### If Checks Fail

You have two options:
1. **Abort** (recommended) - Fix the configuration and re-run
2. **Continue anyway** - Risky, operations will likely fail

---

## Troubleshooting Common Issues

### Issue: DATABASE_URL not set

**Check ExternalSecrets:**
```bash
kubectl get externalsecrets -n onb-1-sandbox
kubectl describe externalsecret los-core-api -n onb-1-sandbox
```

**Force refresh:**
```bash
kubectl annotate externalsecret los-core-api -n onb-1-sandbox \
  force-sync="$(date +%s)" --overwrite
```

**Restart pod:**
```bash
kubectl rollout restart deployment los-core-api -n onb-1-sandbox
```

### Issue: Database connection failed

**Test from pod:**
```bash
kubectl exec -n onb-1-sandbox <pod-name> -- \
  sh -c 'npx prisma db execute --stdin <<< "SELECT 1"'
```

**Check RDS status:**
```bash
aws rds describe-db-instances --db-instance-identifier <instance-id>
```

**Check security groups:**
```bash
# Get VPC security groups
aws rds describe-db-instances --db-instance-identifier <instance-id> \
  --query 'DBInstances[0].VpcSecurityGroups'

# Check inbound rules
aws ec2 describe-security-groups --group-ids <sg-id>
```

### Issue: Prisma/TypeORM not found

**Check if dependencies installed:**
```bash
kubectl exec -n onb-1-sandbox <pod-name> -- \
  sh -c 'ls -la node_modules/.bin/ | grep -E "prisma|typeorm"'
```

**Check package.json:**
```bash
kubectl exec -n onb-1-sandbox <pod-name> -- \
  sh -c 'cat package.json | grep -A 2 prisma'
```

---

## Best Practices

1. **Always run the script first** to see what's configured
2. **Fix errors immediately** - don't continue with errors
3. **Check ExternalSecrets** if DATABASE_URL is missing
4. **Verify RDS access** if connection fails
5. **Use dry-run mode** to test: `--dry-run`
