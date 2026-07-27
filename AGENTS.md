# AGENTS.md

## Server Deployment

- SSH host: `root@damsure.nandakrishnan.in`
- Deployed repo on server: `/root/DrySpot-Damsure-Calc-App`
- Git remote on server: `https://github.com/NanduKkd/DrySpot-Damsure-Calc-App.git`
- Deployed branch: `main`
- Backend directory on server: `/root/DrySpot-Damsure-Calc-App/backend`
- PM2 process name: `damsure-api`

## Canonical Deploy Command

Use this one-liner for the current backend deploy:

```bash
ssh root@damsure.nandakrishnan.in 'bash -lc "cd /root/DrySpot-Damsure-Calc-App && git pull origin main && cd backend && npm install && npm run build && npm run db:migrate && pm2 restart damsure-api"'
```

If you know backend dependencies did not change and want the faster version, use:

```bash
ssh root@damsure.nandakrishnan.in 'bash -lc "cd /root/DrySpot-Damsure-Calc-App && git pull origin main && cd backend && npm run build && npm run db:migrate && pm2 restart damsure-api"'
```

## Migration Status

- `npm run db:migrate` uses environment-driven Sequelize CLI configuration in `backend/config/config.js`; it does not contain credentials or a production password default.
- Migrations run before PM2 restart. The server no longer mutates schema on startup and will not listen until it authenticates to the database.
- This first migration is a non-destructive delta baseline for an existing Damsure database. It expects `users`, `warranties`, and `proposals` to already exist, creates/records the migration in `SequelizeMeta`, adds only missing columns, and selects the newest non-deleted warranty per client for the active-warranty guard.
- Manual preflight: take a database backup, confirm `DB_*` (`DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_HOST`, optional `DB_PORT`/`DB_SSL`) or `DATABASE_URL` (and `NODE_ENV=production`) are set for the deploy shell, and run `npm run db:migrate` once while observing its output. Runtime and migration tooling use the same resolver and deliberately fail if this non-test configuration is incomplete. Do not use this migration to initialise an empty database.
- `npm run db:migrate:undo` only removes the active-warranty unique index. It intentionally leaves added columns/data in place because dropping them after production use would be destructive.
