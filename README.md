# UH GCR Inventory: Security & Audit (WBS 4.9) — DevOps package

This package adds the WBS 4.9 Security & Audit Design Spec to the MySQL build (Parts 1-6), plus the DevOps setup to deploy and test it.

> **Platform note:** The spec was written for **SQL Server Express**, but the code base is **MySQL 8.0**. Everything here uses the MySQL version of each control, mapped in §3. The spec's open question "Does 4.3 confirm SQL Server Express?" should be updated to MySQL 8.0.

---

## 1. What's in the folder

```
db/
  01_schema.sql ... 06_index_maintenance.sql   your Parts 1-6 (02 and 03 have small [SEC 4.9] edits)
  07_security_audit.sql     NEW  AuditLog, sign-in/lockout/sessions, audit triggers, review views
  08_db_roles_grants.sql    NEW  DB roles: app = procedures + views only; dba = maintenance
scripts/
  build_db.sh               builds 01-08 in order; refuses to wipe an existing Production DB
  create_db_accounts.sh     creates/rotates svc_gcr_inventory + gcr_dba (passwords from .env)
  harden_server.sh          removes anonymous/remote root, password policy, local_infile off
  backup_db.sh              mysqldump as gcr_dba via login-path (no password in the script)
  run_tests.sh              ONE COMMAND: rebuild + accounts + all security tests
  install_git_hooks.sh      git pre-commit hook that runs gitleaks
tests/
  test_security.sql         71 SQL tests (identity, tamper-proofing, sign-in, detection)
  test_permissions.sh       19 tests run AS the app account (least privilege, injection)
config/
  .env.example              template only; the real .env is git-ignored
  mysqld-hardening.cnf      bind to 127.0.0.1, X protocol off, failed-login logging
.github/workflows/security-ci.yml   CI: gitleaks history scan + full test run in a throwaway MySQL
.gitleaks.toml  .pre-commit-config.yaml  .gitignore
```

**Build order:** `01 → 02 → 03 → 04 → 05 → 06 → 07 → 08`, then `create_db_accounts.sh`.

---

## 2. Changes to existing files (tell the app team)

**Part 2 (`02_core_procedures.sql`):** No signature changes. `usp_RecordTransaction`, `usp_DeleteTransaction`, and `usp_RecordOpeningCount` now set `@app_user_id` while they run and restore it when they finish or fail. Search for `[SEC 4.9]`.

**Part 3 (`03_supporting_procedures.sql`):** These procedures now take the signed-in user as their **first** parameter, so app calls must be updated:

| Procedure | Old call | New call |
|---|---|---|
| `usp_AddItem` | `(name, cat, value, desc, std, @id)` | `(userId, name, cat, value, desc, std, @id)` |
| `usp_AddItemVariant` | `(itemId, gender, size, @id)` | `(userId, itemId, gender, size, @id)` |
| `usp_UpdateItem` | `(itemId, name, cat, value, clear, desc)` | `(userId, itemId, name, cat, value, clear, desc)` |
| `usp_SetItemActive` | `(itemId, active)` | `(userId, itemId, active)` |
| `usp_SetVariantActive` | `(variantId, active)` | `(userId, variantId, active)` |

These procedures also reject inactive users now: `usp_ApplySuggestedSetpoints` and `usp_SetAlertRecipients`.

---

## 3. Spec → implementation map

| Spec 4.9 item | Where it's built |
|---|---|
| §1 Named sign-in, no shared logins | `AppUser` + `usp_Auth_*`. One row per person; the DB has no generic app login |
| §1 bcrypt, never plain text | `CK_AppUser_PasswordHash` **rejects anything that isn't a bcrypt hash (cost ≥10)** |
| §1 15-min idle timeout | `AppSession` + `usp_Auth_ValidateSession` (only the token's SHA-256 is stored) |
| §1 `CreatedByUserID NOT NULL` | `InventoryTransaction.UserID` (already NOT NULL + FK). Same column, existing name kept |
| §1 Soft delete with who/when/why | Existing `usp_DeleteTransaction` + new `TransactionDeleted` audit event |
| §1 `Item/AlertConfiguration.ModifiedBy/At` | `Item.ModifiedByUserID` + `UpdatedAt` (stamped by trigger); `AlertConfiguration.UpdatedByUserID/UpdatedAt` |
| §1 `AuditLog` append-only | `AuditLog` + triggers blocking UPDATE/DELETE |
| §2 One uniform role | Every active `AppUser` can call every procedure. DB role `gcr_app_role` = EXECUTE + view SELECT only |
| §3 5 failures → 15-min lock | `usp_Auth_RecordLoginAttempt` |
| §3 App can't edit tables directly | `08_db_roles_grants.sql`: app account has **no table privileges** |
| §3 "sa disabled" | `harden_server.sh`: no remote root, no anonymous users, password policy |
| §3 Firewall / SQL Browser off | `mysqld-hardening.cnf`: `bind-address=127.0.0.1`, `mysqlx=OFF`, plus firewall rule |
| §3 SQL Server Audit (failed SQL logins, outside edits) | MySQL Community has no audit plugin, so: `log_error_verbosity=3` logs failed MySQL logins; **every table edit made outside a procedure is flagged** `AuditLog.IsDirectEdit = TRUE` with the MySQL account |
| §3 Weekly review | `CALL usp_Security_WeeklyReview(7);` (6 result sets) |
| §3 Semester account review | `SELECT * FROM vw_Security_AccountReview;` |
| §3 Departing users removed in 1 day | `usp_User_Deactivate` (ends their sessions immediately; users can never be deleted) |
| §4 No secrets in code | `.env` (git-ignored), `create_db_accounts.sh` reads env vars, login-paths for scripts |
| §4 gitleaks before each commit | `.pre-commit-config.yaml` or `install_git_hooks.sh`, plus CI history scan |
| §4 Dev/Test throwaway passwords | `run_tests.sh` and CI generate random passwords every run |

**Additions beyond the spec, at no cost:** posted transactions and lines can't be edited, deleted transactions can't be un-deleted, and `vw_Security_IntegrityExceptions` catches balance drift and unaudited transactions. That last check works even if someone bypassed the triggers.

---

## 4. What the app must do (contract)

```text
SIGN IN
  1. CALL usp_Auth_GetCredentials(username)              -> PasswordHash
  2. ok = bcrypt.compare(typedPassword, hash)             (no row? compare against a dummy hash anyway)
  3. CALL usp_Auth_RecordLoginAttempt(username, ok, clientInfo, @outcome, @userId, @token)
       OK     -> store @token in the session cookie; if MustChangePassword, force a change
       Failed -> "Username or password is incorrect."   (same message for unknown user)
       Locked -> "Too many attempts. Try again in 15 minutes."
EVERY REQUEST
  4. CALL usp_Auth_ValidateSession(token, @userId, @status)   OK | Expired | Invalid
     Pass @userId into every procedure. The user never types it.
SIGN OUT
  5. CALL usp_Auth_Logout(token)
PASSWORDS
  - Enforce 12+ characters in the app, then hash with bcrypt cost 12.
    Pass ONLY the hash to usp_User_Create / usp_User_SetPassword.
```

**Production config (spec §4):** Keep the svc password and SMTP password in `appsettings.Production.json` or `.env` on the GCR PC only, encrypted with DPAPI. In PowerShell, run as the Windows account that runs the app:

```powershell
# encrypt once
Read-Host "svc_gcr_inventory password" -AsSecureString | ConvertFrom-SecureString | Set-Content C:\GCR\secrets\db.enc
# read at startup (only this Windows account on this PC can decrypt it)
$s = Get-Content C:\GCR\secrets\db.enc | ConvertTo-SecureString
$pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
```

---

## 5. Setup

### Dev / Test (your laptop, WSL, or Git Bash)
```bash
cp config/.env.example .env          # GCR_ENV=dev; leave passwords blank, tests generate them
./scripts/run_tests.sh               # builds everything and runs all 90 tests
./scripts/install_git_hooks.sh       # or: pip install pre-commit && pre-commit install
```

### Production (GCR office PC), one time
1. Install MySQL 8.0. Add `config/mysqld-hardening.cnf` to `my.ini`, add the firewall rule from that file, and restart MySQL.
2. Store the admin login without a password in any script: `mysql_config_editor set --login-path=gcr_admin --host=localhost --user=root --password`
3. Create `.env` with `GCR_ENV=production`, `MYSQL_ADMIN_LOGIN_PATH=gcr_admin`, and unique 16+ character `SVC_DB_PASSWORD` and `DBA_DB_PASSWORD`.
4. `./scripts/harden_server.sh`, then `./scripts/build_db.sh`, then `./scripts/create_db_accounts.sh`
5. Delete the passwords from `.env`: the app keeps its copy DPAPI-encrypted. To rotate later, put new values back temporarily and re-run `create_db_accounts.sh`.
6. Set a password for each real user through the app: seed users start with **no password** and can't sign in until one is set. Replace the `-- REPLACE` values in Part 5 first.
7. Schedule `backup_db.sh` (Task Scheduler) to a folder on the BitLocker drive.

**After go-live, never run `build_db.sh` on Production.** Part 1 drops the database, so the script refuses unless you pass `--rebuild-production` on purpose.

---

## 6. How to test it

### A. Automated: one command
```bash
./scripts/run_tests.sh
```
Expected ending:
```
SQL suite: 71 passed, 0 failed
Permission tests: 19 passed, 0 failed
RESULT: ALL SECURITY TESTS PASSED
```
It exits non-zero on any failure, which is what CI uses. The tests are **destructive** and refuse to run when `GCR_ENV=production`.

| Group | IDs | What it proves | Spec |
|---|---|---|---|
| Traceability | A00-A17 | No-user/unknown-user rejected; every change stamped with the user; old/new values logged; context never leaks between calls; normal app use creates **zero** direct-edit flags | §1 |
| Tamper-proofing | B01-B10 | AuditLog/TransactionAudit can't be changed; transactions can't be hard-deleted, edited, re-attributed or un-deleted; users can't be deleted; plain-text and weak (cost 4) passwords rejected | §1 |
| Sign-in & accounts | C01-C31 | Approver recorded; token stored hashed; 14 min idle OK / 16 min expired; 4 fails OK, 5th locks for 15 min; locked + right password still locked; unknown user = same answer; unlock, own change vs. reset, logout, deactivation ends sessions; no hash ever in the log | §1 §3 |
| Detection | D00-D11 | Hand edits to quantity, item, setpoint, transactions, lockout, and lookups are each flagged with the MySQL account; balance drift and unaudited transactions caught; weekly review runs | §3 |
| App account | P01-P19 | Can run procedures and read views; **cannot** read AppUser/hashes or AuditLog, edit/insert/delete/truncate/drop/create, change triggers, grant itself rights, or read mysql.user; SQL-injection text stored as plain data; MySQL lock after 5 bad passwords | §2 §3 |

### B. Manual demo in MySQL Workbench (good for the 4.9 review)
Run these on a **Dev** build after `run_tests.sh`, or after `build_db.sh` + `create_db_accounts.sh`:

```sql
USE UH_GCR_Inventory;
-- 1) Everyone is identified: post a stock out as user 2, then see who did it
CALL usp_StockOut(2, 1, 1, 1, 1, NULL, 'Demo', NULL, NULL, @t);
SELECT TransactionID, UserID, TransactionDate FROM InventoryTransaction WHERE TransactionID = @t;
SELECT * FROM vw_TransactionAuditLog WHERE TransactionID = @t;

-- 2) Lockout: 5 wrong passwords (set a password for user 3 first)
CALL usp_User_SetPassword(1, 3, '$2b$12$YwdxUrzR1Ww0/KAGGamTXOtqi/6YtnwxNjc08qWQkRUJWZchSI7d.');  -- test-only hash  gitleaks:allow
CALL usp_Auth_RecordLoginAttempt('gcr.student1', FALSE, 'demo', @o, @u, @tk);  -- run 5 times
SELECT @o;                                  -- 'Locked' on the 5th
SELECT * FROM vw_Security_FailedLogins;

-- 3) Tamper attempt: blocked
UPDATE AuditLog SET Detail = 'hide this';   -- Error: AuditLog is append-only

-- 4) "Insider" edit outside the app: allowed for an admin, but caught
UPDATE InventoryBalance SET CurrentQuantity = CurrentQuantity + 100 WHERE VariantID = 2;
SELECT * FROM vw_Security_DirectEdits;          -- shows who (MySQL account), what, old/new
SELECT * FROM vw_Security_IntegrityExceptions;  -- "Balance does not match transaction history"

-- 5) Weekly review
CALL usp_Security_WeeklyReview(7);
```

Least privilege demo: open a Workbench connection **as `svc_gcr_inventory`** and try `SELECT * FROM AppUser;`. Expected result: `SELECT command denied`.

### C. Secrets (spec §4)
```bash
echo 'Pwd=Summer2026!Gcr' > leak.txt && git add leak.txt && git commit -m test   # fake secret  gitleaks:allow
# -> "possible secret found - commit blocked"
git rm --cached leak.txt && rm leak.txt
gitleaks detect --source . --config .gitleaks.toml   # whole history -> "no leaks found"
```
The project rules catch hard-coded `IDENTIFIED BY '...'`, password/Pwd assignments in config or connection strings, SMTP passwords, and committed bcrypt hashes. Real `.env` and `appsettings.Production.json` files are git-ignored.

### D. Server / PC layer (on the GCR PC, after the restart)
```powershell
netstat -ano | findstr :3306      # should show 127.0.0.1:3306 only, NOT 0.0.0.0:3306
netstat -ano | findstr :33060     # should show nothing (X protocol off)
manage-bde -status C:             # BitLocker: "Protection On"
```
```sql
SELECT User, Host FROM mysql.user WHERE User = '' OR (User = 'root' AND Host NOT IN ('localhost','127.0.0.1','::1'));  -- 0 rows
SHOW VARIABLES LIKE 'local_infile';              -- OFF
SHOW CREATE USER 'svc_gcr_inventory'@'localhost'; -- ... FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1
```
From a **different** PC, `mysql -h <GCR-PC-IP> -u svc_gcr_inventory -p` should fail to connect.

### E. CI
Push to GitHub and the **security-ci** workflow runs both jobs. It generates fresh random passwords on every run, so no GitHub secrets are needed.

---

## 7. Known limits (state these in the review)
- **Someone with admin DB access can still get around the audit.** `TRUNCATE` skips triggers, and a person could set `@app_user_id` by hand. Their MySQL account is still recorded on every row, and the integrity view catches the resulting data mismatches, so keep `gcr_dba`/root to 1-2 people and review weekly.
- **MySQL Community has no built-in audit plugin.** Failed *MySQL* logins only go to the error log (`log_error_verbosity=3`). Failed *app* sign-ins go to `AuditLog`.
- **Uniform access is by design.** "Supervisor approves accounts" is recorded (`ApprovedByUserID`), not enforced by a role.
- **Some controls live in the app, not the database:** the 12-character minimum, bcrypt hashing, and DPAPI storage.
