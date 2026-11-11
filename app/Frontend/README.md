# GCR Inventory Web App

Serves the pages in `public/` and a JSON API over the stored procedures. See the root README for full setup.

## Run it
1. Install Node.js LTS.
2. `cd app/Frontend`, then `npm install`
3. Copy `.env.example` to `.env` and set `DB_PASSWORD` to the `svc_gcr_inventory` password.
4. `npm start`, then open http://localhost:3000

## Rules
- The app connects only as `svc_gcr_inventory` (procedures and views, no table access).
- Never commit `.env`. Never put passwords in code.
- The server listens on 0.0.0.0 (HOST in .env) so staff on the UH campus network (UH guest Wi-Fi) can reach it at 'http://<hosting PC IP>:3000'. MySQL stays on 127.0.0.1 and is never exposed. Allow inbound TCP 3000 in Windows Firewall; do not open 3306.
## Files
- `server.js`: API routes (inventory, transactions, giveaways, reports, staff, alert recipients, setup status)
- `mailer.js`: sends low-stock emails from `vw_PendingAlertEmails` and records each attempt (needs the SMTP settings in `.env`)
- `public/`: Kiet's pages plus `app.js` (shared API and staff picker), `transactions.js`, `giveaways.js`, `reports.js`, `staff.js`, `alerts.js`, `data.js`
