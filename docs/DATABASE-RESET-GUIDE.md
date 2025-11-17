# Database Reset & Reseed Guide

## Overview

This guide documents the database reset and reseed procedures for all Fuse Platform services.

## Services and Databases

Based on the image provided, the following services and their databases need to be reset:

| Service | Database (Production) | Database (Sandbox) | ORM |
|---------|----------------------|-------------------|-----|
| los-core-api | `los-production` | `los-sandbox` | Prisma |
| los-integrations | `integrations` | - | Prisma |
| sequence-builder-api | `sequence-builder` | - | Prisma |
| ui-builder-api | `ui-builder` | - | Prisma |
| workflow-api | `workflow-builder` | - | TypeORM |
| data-builder-api | `data-builder` + `los-production`/`los-sandbox` (core) | - | Prisma (2 schemas) |

## Reset Procedures by Service

### 1. los-core-api

**Databases**: `los-production`, `los-sandbox`

**Production Start Script** (`package.json`):
```json
"prod": "npm run prisma:migrate:prod && npm run seed:system && node ..."
```

**Reset Procedure**:
```bash
# 1. Reset migrations
npx prisma migrate reset --force

# OR alternatively, if running in pod:
# 2. Deploy migrations
npm run prisma:migrate:prod  # = prisma migrate deploy

# 3. Seed system data (REQUIRED)
npm run seed:system  # = ts-node -r tsconfig-paths/register src/shared/database/seeders/system/seed.ts seed

# 4. Seed mock data (OPTIONAL - for testing)
npm run seed:mock  # = ts-node -r tsconfig-paths/register src/shared/database/seeders/mock/seed.ts seed
```

**Notes**:
- `seed:system` is REQUIRED - contains essential system data (roles, permissions, queues, etc.)
- `seed:mock` is OPTIONAL - for testing environments only
- Uses nest-commander pattern for seeders

---

### 2. los-integrations

**Database**: `integrations`

**Production Start Script**:
```json
"prod": "npm run prisma:migrate:prod && npm run seed:sync && node ..."
```

**Reset Procedure**:
```bash
# 1. Reset with built-in seeder (RECOMMENDED)
npm run seed:reset  # Truncates all tables and reseeds

# OR manually:
# 2. Deploy migrations
npm run prisma:migrate:prod  # = prisma migrate deploy

# 3. Seed integrations (sync mode - intelligent updates)
npm run seed:sync  # = ts-node prisma/seeders/seed.ts --sync
```

**Seeder Features**:
- `--sync`: Intelligent sync mode (updates system configs, preserves user data)
- `--reset`: Truncates all tables CASCADE before seeding
- `--list`: List all available seeders
- `--integration <name>`: Run only specific integration seeders
- `--dry-run`: Preview changes without applying

**Notes**:
- Seeder system is highly sophisticated with dependency resolution
- Auto-discovers seeders from `prisma/seeders/` directory
- Each integration seeder is idempotent and safe to re-run

---

### 3. sequence-builder-api

**Database**: `sequence-builder`

**Production Start Script**:
```json
"start:prod": "npx prisma migrate deploy && npm run seed && node dist/src/main"
```

**Reset Procedure**:
```bash
# 1. Deploy migrations
npx prisma migrate deploy

# 2. Run seed
npm run seed  # = ts-node scripts/seed/index.ts
```

---

### 4. ui-builder-api

**Database**: `ui-builder`

**Production Start Script**:
```json
"start:prod": "npx prisma migrate deploy && ts-node -r tsconfig-paths/register scripts/seed/index.ts && node ..."
```

**Reset Procedure**:
```bash
# 1. Deploy migrations
npx prisma migrate deploy

# 2. Run seed
npm run seed  # = ts-node -r tsconfig-paths/register scripts/seed/index.ts
```

**Notes**:
- Seeds core entities and UI component definitions
- Has special script: `npm run populate-core-entities` for core entity population

---

### 5. workflow-api

**Database**: `workflow-builder` (TypeORM)

**Production Start Script**:
```json
"start:prod": "npm run db:run-migrations && npm run seed && cross-env TZ=UTC node ..."
```

**Reset Procedure**:
```bash
# 1. Run TypeORM migrations
npm run db:run-migrations  # = typeorm migration:run

# 2. Run seed
npm run seed  # = ts-node ./src/scripts/seeder/index.ts
```

**Additional Requirements**:
- **GitHub Workflow Repositories**: Each client has workflow repos (e.g., `{client}-workflows`)
- These repos need to be reset to initial commit
- Seeder includes workflow definitions stored in `src/scripts/seeder/seeds/workflows/`

---

### 6. data-builder-api

**Databases**:
- `data-builder` (main schema)
- `los-production` or `los-sandbox` (core schema - shared with los-core-api)

**Production Start Script**:
```json
"prod": "npm run build && npm run db:deploy && npm run db:sync-model && npm run db:seed:data-builder && node dist/main.js"
```

**Reset Procedure**:
```bash
# 1. Deploy both schemas
npm run db:deploy  # = runs db:deploy:data-builder AND db:deploy:core in parallel

# Individual schema commands:
npm run db:deploy:data-builder  # = prisma migrate deploy --schema=./prisma-data-builder/schema.prisma
npm run db:deploy:core          # = prisma migrate deploy --schema=./prisma-core/schema.prisma

# 2. Sync Prisma clients
npm run db:sync-model  # = runs db:sync-model:data-builder AND db:sync-model:core in parallel

# 3. Seed data-builder database
npm run db:seed:data-builder  # = tsx prisma-data-builder/seed.script.ts
```

**Special Reset Commands**:
```bash
# DANGER: Complete reset (drops all tables)
npm run db:migrate-reset  # Resets both schemas

# Individual resets:
npm run db:data-builder:danger:migrate-reset
npm run db:migrate-reset:core
```

**Notes**:
- Has TWO separate Prisma schemas
- Core schema is SHARED with los-core-api - be careful with resets!
- Seeds include: version info, tags, data groups, option sets

---

## Kubernetes/ArgoCD Deployment

### Namespace Structure

Services are deployed per client in Kubernetes namespaces:
- Format: `{client}-{environment}`
- Examples: `los-demo-sandbox`, `los-demo-production`, `qa-sandbox`, `qa-production`

### ArgoCD Configuration

- ArgoCD configurations: `/Users/felipemachado/Sites/fuse/infra/infra-client-deployments/argocd/`
- Helm charts: `/Users/felipemachado/Sites/fuse/infra/infra-client-deployments/charts/`

### Executing Commands in Pods

To run reset commands in a specific environment:

```bash
# 1. Get pod name
kubectl get pods -n {namespace} -l "app.kubernetes.io/name={service-name}"

# Example:
kubectl get pods -n los-demo-sandbox -l "app.kubernetes.io/name=los-core-api"

# 2. Execute command in pod
kubectl exec -n {namespace} {pod-name} -- sh -c "npm run seed:system"

# Example:
kubectl exec -n los-demo-sandbox los-core-api-abc123-xyz -- sh -c "npm run seed:system"
```

---

## Migration Reset vs Seed Only

### When to Reset Migrations

**Reset migrations** (drops all tables and recreates from scratch):
- Initial setup
- Major schema changes
- Complete environment wipe

```bash
# Prisma
npx prisma migrate reset --force

# TypeORM
npm run db:revert-migration  # Reverts all migrations
npm run db:run-migrations     # Re-runs them
```

### When to Seed Only

**Seed only** (assumes tables exist, just populates data):
- Regular data refresh
- After manual table truncation
- Testing new seed data

```bash
# Just run the seed command
npm run seed:system
npm run seed:sync
# etc.
```

---

## Important Warnings

### ⚠️ data-builder-api Core Schema

The `data-builder-api` **core schema** is SHARED with `los-core-api`!

- **Database**: Same database as los-core-api (`los-production` or `los-sandbox`)
- **Impact**: Resetting data-builder core schema affects los-core-api
- **Recommendation**: Only reset data-builder schema, not core schema, unless you're resetting everything

### ⚠️ Production Databases

- Always confirm before resetting production databases
- Consider backing up before reset
- Some services (like los-integrations) preserve user data (mappings, credentials) even during resets

### ⚠️ Workflow Git Repositories

Workflow-api stores workflows in client-specific GitHub repositories:
- Format: `{client}-workflows`
- Need to be reset to initial commit separately
- Not handled by database seeding

---

## Recommended Reset Order

When resetting everything for a client environment:

1. **data-builder-api** (both schemas)
2. **los-core-api** (production OR sandbox based on environment)
3. **los-integrations**
4. **sequence-builder-api**
5. **ui-builder-api**
6. **workflow-api**
7. **Workflow Git Repos** (manual reset to initial commit)

This order respects dependencies between services.

---

## Quick Reference Commands

### los-core-api
```bash
npm run prisma:migrate:prod && npm run seed:system
```

### los-integrations
```bash
npm run seed:reset  # Best option - truncates and reseeds
```

### sequence-builder-api
```bash
npx prisma migrate deploy && npm run seed
```

### ui-builder-api
```bash
npx prisma migrate deploy && npm run seed
```

### workflow-api
```bash
npm run db:run-migrations && npm run seed
```

### data-builder-api
```bash
npm run db:deploy && npm run db:sync-model && npm run db:seed:data-builder
```

---

## Troubleshooting

### Migrations Fail

```bash
# Check current migration status
npx prisma migrate status

# Check database connection
npx prisma db execute --stdin <<< "SELECT 1"
```

### Seeds Fail

```bash
# For los-integrations, use dry-run to preview
npm run seed:dry

# For los-integrations, list available seeders
npm run seed:list

# Check logs for specific errors
kubectl logs -n {namespace} {pod-name} --tail=100
```

### Pod Not Found

```bash
# List all pods in namespace
kubectl get pods -n {namespace}

# Check deployment status
kubectl get deployments -n {namespace}

# Check ArgoCD sync status
argocd app get {client}-{environment}
```

---

## See Also

- [infra-client-deployments](../infra/infra-client-deployments/)
- [ArgoCD Applications](../infra/infra-client-deployments/argocd/)
- [Helm Charts](../infra/infra-client-deployments/charts/)
