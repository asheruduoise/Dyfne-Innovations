# GCR Inventory Web App

- **Step 1:** serves Kiet's pages and reads live inventory from MySQL.
- **Step 2:** sign-in, plus Stock In / Stock Out saved to the database under the signed-in user.

## Run it
1. Build the database first (repo root): `bash scripts/build_db.sh` then `bash scripts/create_db_accounts.sh`.
   This includes `db/09_app_lookups.sql`, which Step 2 needs.
2. Install Node.js LTS.
3. `cd app/Frontend`, then `npm install`
4. Copy `.env.example` to `.env` and set `DB_PASSWORD` to the `svc_gcr_inventory` password.
5. Set the first password (seed users start with none, so nobody can sign in yet):
   ```bash
   npm run set-password -- gcr.admin
   ```
6. `npm start`, then open http://localhost:3000 and sign in as `gcr.admin`.

## Passwords
- `npm run set-password -- <username>` sets a user's own password.
- `npm run set-password -- <username> --by gcr.admin` sets a **temporary** password;
  the user must choose a new one the first time they sign in.
- Passwords must be at least 12 characters. They are typed without showing on screen,
  hashed with bcrypt (cost 12), and only the hash reaches the database.

## How sign-in works
- Follows the contract in the main README, section 4. The database does the lockout
  (5 wrong passwords = locked 15 minutes), the 15-minute idle timeout, and the audit log.
- The session token lives in an `HttpOnly`, `SameSite=Strict` cookie. Only its SHA-256 is stored.
- Every transaction uses the signed-in user's ID from the session. The browser never sends a user ID.
- Wrong username and wrong password give the same message.

## Rules
- The app connects ONLY as `svc_gcr_inventory` (procedures and views, no table access).
- Never commit `.env`. Never put passwords in code.
- The server listens on 127.0.0.1 by default. If it is ever opened to the network, serve it
  over HTTPS and add `Secure` to the session cookie in `auth.js` first.

## Layout
- `server.js` routes:
  - open: `/api/health`, `POST /api/login`, `POST /api/logout`
  - signed in: `/api/me`, `POST /api/change-password`
  - signed in (and password not pending change): `/api/inventory`, `/api/dashboard`,
    `/api/form-options`, `/api/transactions/recent`, `POST /api/transactions`
- `auth.js` sign-in, sessions, passwords
- `set-password.js` command-line password setup
- `db.js` connection pool
- `public/` Kiet's front end (`index.html`, `style.css`, `script.js`) plus `data.js` (API calls, sign-in, form saving)

## Not done yet
- Giveaway Combinations and Reports pages are still previews.
- No in-app screen for adding users or resetting passwords; use `set-password` for now.
