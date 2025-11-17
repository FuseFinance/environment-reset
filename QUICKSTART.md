# Environment Reset - Quick Reference

## 🚀 Common Commands

### Local Environment Reset
```bash
npm run reset:local onb-1
```

### Kubernetes Environment Reset
```bash
npm run reset:k8s los-demo sandbox
npm run reset:k8s los-demo production
```

### Verify Seeds
```bash
npm run verify:seeds onb-1
```

### Reset Workflows
```bash
npm run reset:workflows los-demo
```

### Check Deployment
```bash
npm run check:deployment los-demo-sandbox
```

## 📋 Pre-Reset Checklist

- [ ] AWS credentials configured (`aws sso login`)
- [ ] Kubectl context set (for K8s resets)
- [ ] Client name confirmed
- [ ] Environment confirmed (sandbox/production)
- [ ] Backup important data (if needed)

## ⚠️ Safety Rules

1. **Only sandbox clients** for local reset (onb-*)
2. **Whitelisted clients only** for K8s reset
3. **Always run dry-run first** for workflows
4. **Verify seeds** after each reset

## 🔍 Verification Steps

1. Run reset command
2. Check output for errors
3. Run `verify:seeds` command
4. Check service logs if needed

## 🆘 Emergency Stop

Press `Ctrl+C` at any time to cancel the operation.
All scripts include cleanup handlers.

## 📞 Need Help?

Run `npm run help` for detailed command information.
