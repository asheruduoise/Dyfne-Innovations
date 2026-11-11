-- =====================================================================
-- UH Government & Community Relations - Inventory Management System
-- Dfyne Innovations | CIS 4375 | Fall 2026
-- Part 7: Database roles (no passwords; accounts are created by
-- scripts/create_db_accounts.sh)
--   gcr_app_role  svc_gcr_inventory  run procedures and read views only
--   gcr_dba_role  gcr_dba            maintenance and backups
-- =====================================================================

CREATE ROLE IF NOT EXISTS 'gcr_app_role', 'gcr_dba_role';

GRANT EXECUTE ON UH_GCR_Inventory.* TO 'gcr_app_role';

GRANT SELECT ON UH_GCR_Inventory.vw_CurrentInventory              TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_LowInventory                  TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_InventoryValue                TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_TransactionHistory            TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_TransactionAuditLog           TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_PendingAlertEmails            TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_FailedAlertEmails             TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Users                         TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_AlertRecipients               TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_SetupStatus                   TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_GiveawayCombinations          TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_DeletedTransactions  TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_DirectEdits          TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_ChangeLog            TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_AccountReview        TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_Security_IntegrityExceptions  TO 'gcr_app_role';

GRANT ALL PRIVILEGES ON UH_GCR_Inventory.* TO 'gcr_dba_role';
GRANT PROCESS, RELOAD ON *.* TO 'gcr_dba_role';
GRANT SHOW_ROUTINE ON *.* TO 'gcr_dba_role';

SELECT 'Part 7 complete: roles and grants applied. BUILD FINISHED.' AS Status;
