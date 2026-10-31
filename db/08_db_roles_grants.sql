/* =====================================================================
   PART 8 : DATABASE ROLES & GRANTS  (Spec §2 + §3 database layer)
   Run as an administrator AFTER Part 7. Contains NO passwords.
   Accounts are created by scripts/create_db_accounts.sh, which reads
   the passwords from environment variables / the protected .env file.

   Role             Account               What it can do
   ---------------  --------------------  ---------------------------------------
   gcr_app_role     svc_gcr_inventory     EXECUTE stored procedures + SELECT the
                    (the application)     report/security views. NO table access:
                                          cannot SELECT/INSERT/UPDATE/DELETE any
                                          table, cannot read password hashes.
   gcr_dba_role     gcr_dba               Server maintenance and backups only.
                    (1-2 team members)    Any data change it makes is flagged in
                                          AuditLog as a direct edit.

   Uniform access (spec §2): every GCR person signs in to the APP and gets
   the same permissions there. People never get their own MySQL login.
   ===================================================================== */
CREATE ROLE IF NOT EXISTS 'gcr_app_role', 'gcr_dba_role';

/* ---------- application role: procedures + views only ---------- */
GRANT EXECUTE ON UH_GCR_Inventory.* TO 'gcr_app_role';

GRANT SELECT ON UH_GCR_Inventory.vw_CurrentInventory              TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_LowInventory                  TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_InventoryValue                TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_TransactionHistory            TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_PendingAlertEmails            TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_TransactionAuditLog           TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_FailedLogins         TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_DeletedTransactions  TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_DirectEdits          TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_AccountReview        TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_IntegrityExceptions  TO 'gcr_app_role';

/* ---------- maintenance role ---------- */
GRANT ALL PRIVILEGES ON UH_GCR_Inventory.* TO 'gcr_dba_role';
GRANT PROCESS, RELOAD ON *.* TO 'gcr_dba_role';          -- mysqldump / FLUSH for backups

/* Review what each role holds:
   SHOW GRANTS FOR 'gcr_app_role';
   SHOW GRANTS FOR 'gcr_dba_role';                                   */

SELECT 'Part 8 complete: roles and grants applied.' AS Status;
