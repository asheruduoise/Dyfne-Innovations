/* =====================================================================
   UH GCR Inventory Management System  (MySQL 8.0)
   TEST SCENARIOS (QA / demo) - exercises every use case and rule and
   returns a PASS/FAIL table, then runs all seven reports.
   !! Run on a DEV copy. To reset afterward, re-run the full build. !!
   ===================================================================== */
USE UH_GCR_Inventory;

DROP PROCEDURE IF EXISTS tst_RunAll;
DROP TEMPORARY TABLE IF EXISTS TestResults;
CREATE TEMPORARY TABLE TestResults (
    TestNo  INT AUTO_INCREMENT PRIMARY KEY,
    Test    VARCHAR(120),
    Result  VARCHAR(4),
    Detail  VARCHAR(400)
);

DELIMITER $$
CREATE PROCEDURE tst_RunAll ()
BEGIN
    DECLARE v_user, v_catGR, v_catComm, v_catCR, v_ctxExt, v_ctxUH, v_purpMtg, v_purpOut INT;
    DECLARE v_umbrella, v_cooler, v_tote, v_yeti, v_journal, v_notebook, v_poloML, v_vestM, v_vestItem, v_combo INT;
    DECLARE v_t1, v_t2, v_t3, v_t5, v_t7a, v_t7b, v_t10, v_x INT;
    DECLARE v_before, v_after, v_qty, v_set, v_nb INT;
    DECLARE v_err VARCHAR(400);
    DECLARE v_folderV, v_bottleV INT;
    DECLARE v_admin, v_u2, v_r1, v_r2, v_r3, v_r4 INT;

    /* ---------- Fresh build: case-study inventory in, staff + alert emails added in the app ---------- */
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Build loads case-study inventory (28 variants, 1586 units)',
            IF((SELECT CONCAT(COUNT(*), '/', SUM(CurrentQuantity), '/', SUM(BaselineQuantity)) FROM InventoryBalance) = '28/1586/1586'
               AND (SELECT CONCAT(NeedsStaff, NeedsAlertRecipient, NeedsOpeningCounts) FROM vw_SetupStatus) = '110',
               'PASS', 'FAIL'), NULL);

    CALL usp_CreateUser('Test.Admin@uh.edu', 'Test', 'Admin', 'Full-Time Staff', NULL, NULL, v_admin);
    CALL usp_CreateUser('student1@uh.edu', 'Student', 'Worker', 'Student Worker', NULL, NULL, v_user);   -- same rights
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Any staff member can add staff (no login); email lower-cased, username from email',
            IF((SELECT CONCAT(Username, '|', Email) FROM AppUser WHERE UserID = v_admin) = 'test.admin|test.admin@uh.edu'
               AND v_user IS NOT NULL, 'PASS', 'FAIL'), NULL);

    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_CreateUser('STUDENT1@uh.edu', 'Dup', 'User', NULL, 'other', NULL, v_x);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Duplicate email rejected', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    CALL usp_CreateUser('temp.worker@uh.edu', 'Temp', 'Worker', 'Student Intern', NULL, v_admin, v_u2);
    CALL usp_SetUserActive(v_u2, FALSE, NULL);
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_StockIn(v_u2, (SELECT VariantID FROM vw_CurrentInventory WHERE ItemName = 'Umbrella'), 1, 'Received', NULL, NULL, v_x);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Removed staff member drops off the picker and cannot record transactions',
            IF(v_err IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vw_Users WHERE UserID = v_u2 AND IsActive), 'PASS', 'FAIL'), v_err);

    CALL usp_SetUserActive(v_admin, FALSE, NULL);
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_SetUserActive(v_user, FALSE, NULL);
    END;
    CALL usp_SetUserActive(v_admin, TRUE, NULL);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Last active staff member cannot be removed', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    CALL usp_AddAlertRecipient('Project Sponsor', 'sponsor@example.edu', NULL, v_r1);
    CALL usp_AddAlertRecipient('Office Manager', 'office.manager@example.edu', NULL, v_r2);
    CALL usp_AddAlertRecipient('Inventory Backup', 'backup@example.edu', NULL, v_r3);
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_AddAlertRecipient('Fourth', 'fourth@example.edu', NULL, v_r4);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Alert emails added by anyone in the app; fourth recipient rejected',
            IF(v_err IS NOT NULL AND (SELECT COUNT(*) FROM vw_AlertRecipients) = 3, 'PASS', 'FAIL'), v_err);

    CALL usp_RemoveAlertRecipient(v_r2, NULL);
    CALL usp_AddAlertRecipient('New Manager', 'new.manager@example.edu', v_user, v_r4);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Removed recipient slot is reused by the next one added',
            IF((SELECT RecipientSlot FROM AlertRecipient WHERE AlertRecipientID = v_r4) = 2, 'PASS', 'FAIL'), NULL);

    SELECT DistributionCategoryID INTO v_catGR   FROM DistributionCategory WHERE CategoryName = 'Giveaway - Government Relations';
    SELECT DistributionCategoryID INTO v_catComm FROM DistributionCategory WHERE CategoryName = 'Community Event / Donation';
    SELECT DistributionCategoryID INTO v_catCR   FROM DistributionCategory WHERE CategoryName = 'Giveaway - Community Relations';
    SELECT RecipientContextID INTO v_ctxExt FROM RecipientContext WHERE ContextName = 'External';
    SELECT RecipientContextID INTO v_ctxUH  FROM RecipientContext WHERE ContextName = 'In-Network / Within UH';
    SELECT EventPurposeID INTO v_purpMtg FROM EventPurpose WHERE PurposeName = 'Government Relations Meeting';
    SELECT EventPurposeID INTO v_purpOut FROM EventPurpose WHERE PurposeName = 'Community Outreach';
    SELECT VariantID INTO v_umbrella FROM vw_CurrentInventory WHERE ItemName = 'Umbrella';
    SELECT VariantID INTO v_cooler   FROM vw_CurrentInventory WHERE ItemName = 'Red Igloo Cooler';
    SELECT VariantID INTO v_tote     FROM vw_CurrentInventory WHERE ItemName = 'Red UH Tote Bag';
    SELECT VariantID INTO v_yeti     FROM vw_CurrentInventory WHERE ItemName = 'Black Can Yeti';
    SELECT VariantID INTO v_journal  FROM vw_CurrentInventory WHERE ItemName = 'Red Journal';
    SELECT VariantID INTO v_notebook FROM vw_CurrentInventory WHERE ItemName = 'Red Notebook';
    SELECT VariantID INTO v_folderV  FROM vw_CurrentInventory WHERE ItemName = 'Red Folder';
    SELECT VariantID INTO v_bottleV  FROM vw_CurrentInventory WHERE ItemName = 'Red Plastic Water Bottle';
    SELECT VariantID INTO v_poloML   FROM vw_CurrentInventory WHERE ItemName = 'Red UH Polo' AND Gender = 'Males' AND SizeCode = 'L';
    SELECT VariantID INTO v_vestM    FROM vw_CurrentInventory WHERE ItemName = 'UH Vest' AND SizeCode = 'M';
    SELECT ItemID    INTO v_vestItem FROM Item WHERE ItemName = 'UH Vest';
    SELECT CombinationID INTO v_combo FROM GiveawayCombination WHERE CombinationName = 'Standard Relationship Gift';

    /* ---------- Physical recount trues-up the case-study quantities ---------- */
    CALL usp_LoadOpeningCounts('[{"Item": "Umbrella", "Qty": 9}, {"Item": "Red Igloo Cooler", "Qty": 2}]', v_admin);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Recount trues-up loaded stock (+3 Adjustment In, -1 Adjustment Out, new baseline)',
            IF((SELECT CONCAT(CurrentQuantity, '/', BaselineQuantity) FROM InventoryBalance WHERE VariantID = v_umbrella) = '9/9'
               AND (SELECT CONCAT(CurrentQuantity, '/', BaselineQuantity) FROM InventoryBalance WHERE VariantID = v_cooler) = '2/2'
               AND (SELECT COUNT(*) FROM InventoryTransaction WHERE Notes = 'Verified physical recount - count correction') = 2,
               'PASS', 'FAIL'), NULL);


    /* demo values so value reports have data (other items stay "unknown") */
    CALL usp_UpdateItem(v_admin, (SELECT ItemID FROM Item WHERE ItemName = 'Red UH Tote Bag'), NULL, NULL, 4.50, NULL, NULL);
    CALL usp_UpdateItem(v_admin, (SELECT ItemID FROM Item WHERE ItemName = 'Black Can Yeti'),  NULL, NULL, 28.00, NULL, NULL);

    /* ---------- UC01 Stock In ---------- */
    SELECT CurrentQuantity INTO v_before FROM InventoryBalance WHERE VariantID = v_umbrella;
    CALL usp_StockIn(v_user, v_umbrella, 10, 'Received', NULL, 'TEST: umbrella shipment', v_t1);
    SELECT CurrentQuantity INTO v_after FROM InventoryBalance WHERE VariantID = v_umbrella;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('UC01 Stock In adds to inventory', IF(v_after = v_before + 10, 'PASS', 'FAIL'), CONCAT(v_before, ' -> ', v_after));

    /* ---------- UC02 Individual Stock Out ---------- */
    SELECT CurrentQuantity INTO v_before FROM InventoryBalance WHERE VariantID = v_poloML;
    CALL usp_StockOut(v_user, v_poloML, 2, v_catComm, v_ctxExt, v_purpOut, 'TEST: Third Ward outreach', NULL, NULL, v_t2);
    SELECT CurrentQuantity INTO v_after FROM InventoryBalance WHERE VariantID = v_poloML;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('UC02 Stock Out deducts inventory', IF(v_after = v_before - 2, 'PASS', 'FAIL'), CONCAT(v_before, ' -> ', v_after));

    /* ---------- UC03 Multi-item giveaway (case study scenario) ---------- */
    CALL usp_RecordTransaction(v_user, 'OUT',
         JSON_ARRAY(JSON_OBJECT('VariantID', v_tote, 'Quantity', 1),
                    JSON_OBJECT('VariantID', v_yeti, 'Quantity', 1),
                    JSON_OBJECT('VariantID', v_journal, 'Quantity', 1)),
         NULL, v_catGR, v_ctxExt, v_purpMtg, 'TEST: Meeting with external government stakeholder', NULL, NULL, NULL, v_t3);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('UC03 Multi-item giveaway = 1 header / 3 lines',
            IF((SELECT COUNT(*) FROM TransactionLine WHERE TransactionID = v_t3) = 3, 'PASS', 'FAIL'),
            CONCAT('Transaction ', v_t3));

    /* ---------- Rule: insufficient stock rejects the WHOLE transaction ---------- */
    SELECT CurrentQuantity INTO v_before FROM InventoryBalance WHERE VariantID = v_tote;
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_RecordTransaction(v_user, 'OUT',
             JSON_ARRAY(JSON_OBJECT('VariantID', v_tote, 'Quantity', 1), JSON_OBJECT('VariantID', v_cooler, 'Quantity', 99)),
             NULL, v_catGR, v_ctxExt, NULL, NULL, NULL, NULL, NULL, v_x);
    END;
    SELECT CurrentQuantity INTO v_after FROM InventoryBalance WHERE VariantID = v_tote;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Insufficient stock rejected, no partial deduction',
            IF(v_err IS NOT NULL AND v_after = v_before, 'PASS', 'FAIL'), v_err);

    /* ---------- Rule: Stock Out requires distribution category ---------- */
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_StockOut(v_user, v_tote, 1, NULL, v_ctxExt, NULL, NULL, NULL, NULL, v_x);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Stock Out without category rejected', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    /* ---------- Rule: quantity must be > 0 ---------- */
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_StockIn(v_user, v_tote, 0, NULL, NULL, NULL, v_x);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Zero quantity rejected', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    /* ---------- UC05/UC06 Setpoint reached -> alert (trigger) ---------- */
    SELECT CurrentQuantity, Setpoint INTO v_before, v_set FROM InventoryBalance WHERE VariantID = v_umbrella;
    SET v_qty = v_before - v_set;   -- drop exactly to the setpoint
    CALL usp_StockOut(v_user, v_umbrella, v_qty, v_catCR, v_ctxExt, NULL, 'TEST: community fair', NULL, NULL, v_t5);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('UC06 Low-stock alert at qty <= setpoint',
            IF(EXISTS (SELECT 1 FROM InventoryAlert WHERE VariantID = v_umbrella AND AlertStatus = 'Pending'
                                                     AND TriggeringTransactionID = v_t5), 'PASS', 'FAIL'),
            CONCAT('setpoint ', v_set));

    /* ---------- UC04 Delete erroneous Stock Out -> reversal, alert resolves, audit ---------- */
    SELECT CurrentQuantity INTO v_before FROM InventoryBalance WHERE VariantID = v_umbrella;
    CALL usp_DeleteTransaction(v_t5, v_user, 'TEST: entered wrong item');
    SELECT CurrentQuantity INTO v_after FROM InventoryBalance WHERE VariantID = v_umbrella;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('UC04 Delete Stock Out returns units', IF(v_after = v_before + v_qty, 'PASS', 'FAIL'),
            CONCAT(v_before, ' -> ', v_after));
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Alert auto-resolved after reversal',
            IF(NOT EXISTS (SELECT 1 FROM InventoryAlert WHERE OpenVariantKey = v_umbrella), 'PASS', 'FAIL'), NULL);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('5.5 Audit has Created + Deleted rows',
            IF(EXISTS (SELECT 1 FROM TransactionAudit WHERE TransactionID = v_t5 AND AuditAction = 'Created')
               AND EXISTS (SELECT 1 FROM TransactionAudit WHERE TransactionID = v_t5 AND AuditAction = 'Deleted'
                                                          AND InventoryEffect = 'Added' AND Reason IS NOT NULL),
               'PASS', 'FAIL'), NULL);

    /* ---------- Rule: audit log is append-only ---------- */
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        UPDATE TransactionAudit SET Reason = 'tamper' WHERE AuditID = (SELECT MIN(a.AuditID) FROM (SELECT AuditID FROM TransactionAudit) a);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Audit log cannot be modified', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    /* ---------- Rule: deleting a Stock In cannot create negative inventory ---------- */
    CALL usp_StockIn(v_user, v_cooler, 1, NULL, NULL, 'TEST', v_t7a);
    SELECT CurrentQuantity INTO v_qty FROM InventoryBalance WHERE VariantID = v_cooler;
    CALL usp_StockOut(v_user, v_cooler, v_qty, v_catComm, v_ctxExt, NULL, NULL, NULL, NULL, v_t7b);
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_DeleteTransaction(v_t7a, v_user, NULL);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Negative-balance delete blocked', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);
    CALL usp_DeleteTransaction(v_t7b, v_user, 'TEST cleanup');
    CALL usp_DeleteTransaction(v_t7a, v_user, 'TEST cleanup');

    /* ---------- Rule: direct DELETE is blocked ---------- */
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        DELETE FROM InventoryTransaction WHERE TransactionID = v_t1;
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Direct DELETE blocked', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    /* ---------- Rule: setpoint is a stored threshold (does not move on restock) ---------- */
    SELECT Setpoint INTO v_set FROM InventoryBalance WHERE VariantID = v_umbrella;
    CALL usp_StockIn(v_user, v_umbrella, 50, NULL, NULL, 'TEST restock', v_x);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Setpoint unchanged after restock',
            IF((SELECT Setpoint FROM InventoryBalance WHERE VariantID = v_umbrella) = v_set, 'PASS', 'FAIL'),
            CONCAT('setpoint ', v_set));

    /* ---------- UC05 Manual setpoint override ---------- */
    CALL usp_UpdateSetpoint(v_journal, 25, v_user);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Manual setpoint override saved',
            IF((SELECT Setpoint FROM InventoryBalance WHERE VariantID = v_journal) = 25, 'PASS', 'FAIL'), NULL);

    /* ---------- 5.7 Trigger raises alert on setpoint change; 5.6 reset resolves it ---------- */
    SELECT CurrentQuantity INTO v_nb FROM InventoryBalance WHERE VariantID = v_notebook;
    CALL usp_UpdateSetpoint(v_notebook, v_nb, v_user);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('5.7 Trigger alert on setpoint change',
            IF(EXISTS (SELECT 1 FROM InventoryAlert WHERE VariantID = v_notebook AND AlertStatus = 'Pending'
                                                     AND TriggeringTransactionID IS NULL), 'PASS', 'FAIL'), NULL);
    CALL usp_ApplySuggestedSetpoints(v_user, v_notebook);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('5.6 Reset to suggested setpoint resolves alert',
            IF(NOT EXISTS (SELECT 1 FROM InventoryAlert WHERE OpenVariantKey = v_notebook), 'PASS', 'FAIL'), NULL);

    /* ---------- Story 09: template -> modify -> submit as In-Network gift ---------- */
    CALL usp_GetCombinationForEntry(v_combo);
    CALL usp_RecordTransaction(v_user, 'OUT',
         JSON_ARRAY(JSON_OBJECT('VariantID', v_tote, 'Quantity', 2),      -- changed qty
                    JSON_OBJECT('VariantID', v_yeti, 'Quantity', 1),
                    JSON_OBJECT('VariantID', v_journal, 'Quantity', 1),
                    JSON_OBJECT('VariantID', v_poloML, 'Quantity', 1)),   -- notebook removed, polo added
         NULL, v_catCR, v_ctxUH, NULL, 'TEST: thank-you gift to UH department',
         'UH College of Engineering', v_combo, NULL, v_t10);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Template modified and submitted (In-Network)',
            IF((SELECT COUNT(*) FROM TransactionLine WHERE TransactionID = v_t10) = 4, 'PASS', 'FAIL'), NULL);

    /* ---------- Rule: inactive items not selectable, history retained ---------- */
    CALL usp_StockOut(v_user, v_vestM, 1, v_catComm, v_ctxExt, NULL, 'TEST: before deactivation', NULL, NULL, v_x);
    CALL usp_SetItemActive(v_user, v_vestItem, FALSE);
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_StockOut(v_user, v_vestM, 1, v_catComm, v_ctxExt, NULL, NULL, NULL, NULL, v_x);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Inactive item rejected on new transaction', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('History kept for inactive item',
            IF(EXISTS (SELECT 1 FROM vw_TransactionHistory WHERE VariantID = v_vestM AND TransactionType = 'OUT'),
               'PASS', 'FAIL'), NULL);
    CALL usp_SetItemActive(v_user, v_vestItem, TRUE);

    /* ---------- Email job: one email per giveaway + retry limit ---------- */
    BEGIN
        DECLARE v_q1, v_q2, v_tx, v_a1, v_a2, v_i INT;
        SELECT CurrentQuantity - Setpoint INTO v_q1 FROM InventoryBalance WHERE VariantID = v_folderV;
        SELECT CurrentQuantity - Setpoint INTO v_q2 FROM InventoryBalance WHERE VariantID = v_bottleV;
        CALL usp_RecordTransaction(v_user, 'OUT',
             JSON_ARRAY(JSON_OBJECT('VariantID', v_folderV, 'Quantity', v_q1),
                        JSON_OBJECT('VariantID', v_bottleV, 'Quantity', v_q2)),
             NULL, v_catComm, v_ctxExt, NULL, 'TEST: large event order', NULL, NULL, NULL, v_tx);
        INSERT INTO TestResults (Test, Result, Detail)
        VALUES ('Giveaway alerts share one TriggeringTransactionID (one email)',
                IF((SELECT COUNT(*) FROM vw_PendingAlertEmails WHERE TriggeringTransactionID = v_tx) = 2, 'PASS', 'FAIL'),
                CONCAT('transaction ', v_tx));

        SELECT AlertID INTO v_a1 FROM InventoryAlert WHERE OpenVariantKey = v_folderV;
        SELECT AlertID INTO v_a2 FROM InventoryAlert WHERE OpenVariantKey = v_bottleV;
        SET v_i = 0;
        WHILE v_i < 5 DO
            CALL usp_MarkAlertSent(v_a1, NULL, 'TEST: 550 mailbox not found');
            SET v_i = v_i + 1;
        END WHILE;
        INSERT INTO TestResults (Test, Result, Detail)
        VALUES ('Bad address leaves queue after 5 failed attempts',
                IF(NOT EXISTS (SELECT 1 FROM vw_PendingAlertEmails WHERE AlertID = v_a1)
                   AND EXISTS (SELECT 1 FROM vw_FailedAlertEmails WHERE AlertID = v_a1 AND SendAttempts = 5),
                   'PASS', 'FAIL'), NULL);

        CALL usp_MarkAlertSent(v_a2, 'sponsor@example.edu', NULL);
        INSERT INTO TestResults (Test, Result, Detail)
        VALUES ('Successful send marks Sent and counts the attempt',
                IF((SELECT CONCAT(AlertStatus, SendAttempts) FROM InventoryAlert WHERE AlertID = v_a2) = 'Sent1', 'PASS', 'FAIL'), NULL);
    END;

    /* last recipient can't be removed (alerts would go nowhere) */
    CALL usp_RemoveAlertRecipient(v_r1, v_admin);
    CALL usp_RemoveAlertRecipient(v_r3, v_admin);
    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        CALL usp_RemoveAlertRecipient(v_r4, v_admin);
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Last alert recipient cannot be removed', IF(v_err IS NOT NULL AND (SELECT COUNT(*) FROM vw_AlertRecipients) = 1, 'PASS', 'FAIL'), v_err);

    /* ---------- Security and audit (WBS 4.9) ---------- */
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('App activity creates no direct-edit flags and no integrity exceptions',
            IF((SELECT COUNT(*) FROM AuditLog WHERE IsDirectEdit) = 0
               AND (SELECT COUNT(*) FROM vw_Security_IntegrityExceptions) = 0, 'PASS', 'FAIL'),
            CONCAT((SELECT COUNT(*) FROM AuditLog WHERE IsDirectEdit), ' flags'));

    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Staff and alert-email changes are logged with who made them',
            IF(EXISTS (SELECT 1 FROM AuditLog WHERE TableName = 'AlertRecipient' AND Action = 'Insert' AND UserID = v_user)
               AND EXISTS (SELECT 1 FROM AuditLog WHERE TableName = 'AppUser' AND Action = 'Update' AND RecordID = v_u2),
               'PASS', 'FAIL'), NULL);

    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Item change stamped with the acting staff member',
            IF((SELECT ModifiedByUserID FROM Item WHERE ItemID = v_vestItem) = v_user, 'PASS', 'FAIL'), NULL);

    SET @app_ctx = NULL, @app_user_id = NULL;
    UPDATE InventoryBalance SET CurrentQuantity = CurrentQuantity + 100 WHERE VariantID = v_tote;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Quantity edited outside the app is flagged and caught by the integrity check',
            IF(EXISTS (SELECT 1 FROM vw_Security_DirectEdits WHERE TableName = 'InventoryBalance' AND RecordID = v_tote)
               AND EXISTS (SELECT 1 FROM vw_Security_IntegrityExceptions WHERE RecordID = v_tote), 'PASS', 'FAIL'), NULL);
    UPDATE InventoryBalance SET CurrentQuantity = CurrentQuantity - 100 WHERE VariantID = v_tote;

    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        UPDATE AuditLog SET Detail = 'hide this' WHERE AuditLogID = 1;
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('AuditLog cannot be changed', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        UPDATE InventoryTransaction SET Notes = 'edited' WHERE TransactionID = v_t1;
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Posted transactions cannot be edited', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);

    SET v_err = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MESSAGE_TEXT;
        DELETE FROM AppUser WHERE UserID = v_u2;
    END;
    INSERT INTO TestResults (Test, Result, Detail)
    VALUES ('Staff records cannot be deleted', IF(v_err IS NOT NULL, 'PASS', 'FAIL'), v_err);
END$$
DELIMITER ;

CALL tst_RunAll();

/* ---------- RESULTS ---------- */
SELECT * FROM TestResults ORDER BY TestNo;
SELECT CONCAT(SUM(Result = 'PASS'), ' of ', COUNT(*), ' tests passed') AS Summary FROM TestResults;

/* ---------- ALL SEVEN REPORTS ---------- */
SET @Start = DATE_SUB(CURDATE(), INTERVAL 30 DAY);
SET @End   = CURDATE();
CALL usp_rpt_CurrentInventory(NULL, FALSE);
CALL usp_rpt_LowInventory();
CALL usp_rpt_InventoryUsage(@Start, @End, NULL, NULL);
CALL usp_rpt_InventoryValue(NULL);
CALL usp_rpt_TransactionHistory(@Start, @End, NULL, NULL, NULL, TRUE);
CALL usp_rpt_Giveaway(@Start, @End, NULL, NULL, FALSE, FALSE);
CALL usp_rpt_DemandForecast(30, 90, NULL);
SELECT * FROM vw_TransactionAuditLog ORDER BY AuditID DESC LIMIT 20;

DROP PROCEDURE IF EXISTS tst_RunAll;
