# GCR Inventory Web App

Step 1: serves Kiet's pages and reads live inventory from MySQL.

## Run it
1. Install Node.js LTS.
2. `cd app`, then `npm install`
3. Copy `.env.example` to `.env` and set `DB_PASSWORD` to the `svc_gcr_inventory` password.
4. `npm start`, then open http://localhost:3000

## Rules
- The app connects ONLY as `svc_gcr_inventory` (procedures and views, no table access).
- Never commit `.env`. Never put passwords in code.
- No login yet (Step 2). The server listens on 127.0.0.1 only; do not change HOST until login exists.

## Layout
- `server.js` routes: `/api/health`, `/api/inventory`, `/api/dashboard`
- `db.js` connection pool
- `public/` Kiet's front end (`index.html`, `style.css`, `script.js`) plus `data.js` (fills tables from the API)
