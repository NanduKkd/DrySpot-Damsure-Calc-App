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
ssh root@damsure.nandakrishnan.in 'bash -lc "cd /root/DrySpot-Damsure-Calc-App && git pull origin main && cd backend && npm install && npm run build && pm2 restart damsure-api"'
```

If you know backend dependencies did not change and want the faster version, use:

```bash
ssh root@damsure.nandakrishnan.in 'bash -lc "cd /root/DrySpot-Damsure-Calc-App && git pull origin main && cd backend && npm run build && pm2 restart damsure-api"'
```

## Migration Status

- Do not include `npm run db:migrate` in the current deploy command.
- The command currently fails because the server does not have a Sequelize CLI migration setup (`backend/config/config.json` is missing, and there is no `migrations/` directory).
- The backend currently applies schema changes on startup via `sequelize.sync({ alter: true })` in [backend/src/app.ts](/Users/nandakrishnan/applca/orch-test-1/DrySpot-Damsure-Calc-App/backend/src/app.ts:48).
- If proper Sequelize migrations are added later, insert `npm run db:migrate` in the backend directory before `pm2 restart damsure-api`.
