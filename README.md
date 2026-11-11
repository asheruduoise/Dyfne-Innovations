# UH Government & Community Relations Inventory Management System

Dyfne Innovations | CIS 4375 | Fall 2026

A local web app and MySQL 8.0 database that track GCR merchandise: Stock In, Stock Out (including
multi-item giveaways), low-stock email alerts, and seven reports. It runs on one office computer,
with no cloud hosting.

## Layout
- `db/` database build files `01` to `07`, run in order (Part 1 drops and recreates the database)
- `app/Frontend/` Node.js + Express web app (`server.js`, `mailer.js`, `public/` pages)
- `scripts/` helper scripts (Git Bash/WSL for `.sh`; `backup_db.bat` for Windows)
- `tests/` scenario tests (`test_scenarios.sql`) and permission tests (`test_permissions.sh`)
- `docs/` ERD, data dictionary

## Setup (Windows)
1. Install MySQL 8.0 and Node.js LTS.
2. In the MySQL Command Line Client, as root, run `db/01` through `db/07` in order:
   `source C:/path/to/repo/db/01_schema.sql` ... `07_db_roles_grants.sql`.
3. Create the two accounts (choose your own passwords, at least 16 characters):
   ```sql
   CREATE USER 'svc_gcr_inventory'@'localhost' IDENTIFIED BY 'CHANGE-ME';
   GRANT 'gcr_app_role' TO 'svc_gcr_inventory'@'localhost';
   SET DEFAULT ROLE 'gcr_app_role' TO 'svc_gcr_inventory'@'localhost';
   CREATE USER 'gcr_dba'@'localhost' IDENTIFIED BY 'CHANGE-ME-TOO';
   GRANT 'gcr_dba_role' TO 'gcr_dba'@'localhost';
   SET DEFAULT ROLE 'gcr_dba_role' TO 'gcr_dba'@'localhost';
   ```
4. `cd app/Frontend`, `npm install`, copy `.env.example` to `.env`, and fill in `DB_PASSWORD`
   (and the `SMTP_*` settings if low-stock emails should be sent).
5. `npm start`, then open http://localhost:3000
6. First run: open the Staff page and add the first staff member, then add 1 to 3 alert recipients.

## Rules
- The app connects only as `svc_gcr_inventory` (procedures and views, no direct table access).
- Never commit `.env`. Never put passwords in code.
- The server listens on 127.0.0.1 only. There is no sign-in; each transaction records the staff
  member chosen in the staff picker.
- Backups: `scripts/backup_db.bat` (Windows) or `scripts/backup_db.sh`, scheduled nightly.

## Tests
`tests/test_scenarios.sql` (39 tests, run as root on a throwaway database) covers every use case,
business rule and audit control. Tests are destructive: rebuild the database afterward.
