# UH GCR Inventory Management System

Dfyne Innovations | CIS 4375 | Fall 2026

MySQL 8.0 database and a Node.js web app for UH Government & Community Relations merchandise.

There is **no login**. Staff choose their name in **Working as** at the top of every page, and the database records who made each transaction and change. Any staff member can add or remove staff and alert emails in the app.

## Folder layout

```
db/
  01_schema.sql              tables, constraints, indexes, triggers
  02_procedures.sql          all business logic (stock in/out, deletes, counts, setpoints, staff, alerts)
  03_reports.sql             views and the 7 report procedures
  04_seed_data.sql           lookups, item catalog, starting inventory (case study workbook)
  05_index_maintenance.sql   usp_IndexMaintenance
  06_security_audit.sql      AuditLog, change tracking, direct-edit detection, weekly review (WBS 4.9)
  07_db_roles_grants.sql     gcr_app_role (procedures + views only) and gcr_dba_role
  UH_GCR_Inventory_FULL_BUILD.sql   01-07 in one file, for MySQL Workbench
  Recount_Template.csv       fill in VerifiedQty after the physical recount
app/Frontend/
  server.js                  JSON API over the stored procedures
  mailer.js                  low-stock email job
  public/                    the web pages
scripts/                     build, accounts, backups, server hardening, tests
tests/
  test_scenarios.sql         39 tests: every use case, business rule and audit control
  test_permissions.sh        19 tests run as the app account (least privilege)
docs/                        ERD (dbdiagram.io) and data dictionary
```

## Set up on a PC

1. **Build the database.** In MySQL Workbench, open `db/UH_GCR_Inventory_FULL_BUILD.sql` and click Execute (lightning bolt). The last result should say `BUILD FINISHED`. Or run `./scripts/build_db.sh`.
2. **Create the app's database account.** Put `SVC_DB_PASSWORD` and `DBA_DB_PASSWORD` (16+ characters each) in a root `.env`, then run `./scripts/create_db_accounts.sh`. Or in Workbench:
   ```sql
   CREATE USER 'svc_gcr_inventory'@'localhost' IDENTIFIED BY '<password>';
   GRANT 'gcr_app_role' TO 'svc_gcr_inventory'@'localhost';
   SET DEFAULT ROLE 'gcr_app_role' TO 'svc_gcr_inventory'@'localhost';
   ```
3. **Start the app.**
   ```bash
   cd app/Frontend
   npm install
   cp .env.example .env      # set DB_PASSWORD to the svc_gcr_inventory password
   npm start                 # open http://localhost:3000
   ```
4. **First launch.** The banner at the top lists what's left:
   - **Staff:** add everyone who records inventory.
   - **Email Alerts:** add 1 to 3 people who get low-stock emails.
5. **Turn on alert emails.** Fill in the `SMTP_*` and `ALERT_FROM` lines in `app/Frontend/.env` and restart the app. Until then, alerts wait in the queue and send once email is configured.
6. **Physical recount.** Fill in `VerifiedQty` in `db/Recount_Template.csv`. In Workbench, right-click `UH_GCR_Inventory`, choose **Table Data Import Wizard**, and import the file as a new table named `RecountImport`. Then run `CALL usp_LoadOpeningCountsFromImport(<your staff ID>);`. Each difference from the starting inventory is posted as an audited adjustment.

**After go-live, never rebuild.** The build drops the database, and `build_db.sh` refuses to run on production unless you pass `--rebuild-production`. Back up with `scripts/backup_db.sh`.

## Pages

| Page | What it does | Database calls |
|---|---|---|
| Dashboard / Inventory | Stock levels, low-stock count, setpoint changes | `vw_CurrentInventory`, `usp_UpdateSetpoint`, `usp_ApplySuggestedSetpoints` |
| Stock Transactions | Stock In / Stock Out (one or many items), recent list, delete with reason | `usp_RecordTransaction`, `usp_DeleteTransaction` |
| Giveaway Combinations | Use or save templates; submit a giveaway as one Stock Out | `vw_GiveawayCombinations`, `usp_SaveGiveawayCombination` |
| Reports | The 7 reports plus the weekly security review; CSV download | `usp_rpt_*`, `usp_Security_WeeklyReview` |
| Email Alerts | Up to 3 low-stock recipients | `vw_AlertRecipients`, `usp_SetAlertRecipients` |
| Staff | Add, edit, deactivate staff | `vw_Users`, `usp_CreateUser`, `usp_UpdateUser`, `usp_SetUserActive` |

## Security (WBS 4.9, no-login version)

- **App account:** the app connects as `svc_gcr_inventory`, which can only run procedures and read views. It has no table access.
- **Who did what:** every change made through the app is credited to the selected staff member in `TransactionAudit` and `AuditLog`.
- **Edits outside the app:** anything changed directly in Workbench is flagged in `AuditLog` (`IsDirectEdit`) with the MySQL account that made it, and `vw_Security_IntegrityExceptions` catches balances that no longer match the transaction history.
- **Protected records:** audit logs are append-only, posted transactions can't be edited, and staff can't be deleted, only deactivated.
- **Weekly review:** run the **Weekly Security Review** report, or `CALL usp_Security_WeeklyReview(7);`.
- **Local only:** the web server listens on `127.0.0.1`, so only the office PC can open the app. Because there is no login, keep it that way.

## Tests

```bash
./scripts/run_tests.sh      # rebuilds a throwaway database; never run with GCR_ENV=production
```
The expected ending is `Scenario suite: 39 passed`, `Permission tests: 19 passed`, and `RESULT: ALL TESTS PASSED`.
