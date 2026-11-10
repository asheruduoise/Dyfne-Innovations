-- =====================================================================
-- UH Government & Community Relations - Inventory Management System
-- Dfyne Innovations | CIS 4375 | Fall 2026
-- Part 2: Stored procedures
-- =====================================================================

USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

DROP PROCEDURE IF EXISTS usp_EvaluateLowStock;
DROP PROCEDURE IF EXISTS usp_RecordTransaction;
DROP PROCEDURE IF EXISTS usp_StockIn;
DROP PROCEDURE IF EXISTS usp_StockOut;
DROP PROCEDURE IF EXISTS usp_DeleteTransaction;
DROP PROCEDURE IF EXISTS usp_RecordOpeningCount;
DROP PROCEDURE IF EXISTS usp_LoadOpeningCounts;
DROP PROCEDURE IF EXISTS usp_ApplyRecount;
DROP PROCEDURE IF EXISTS usp_LoadOpeningCountsFromImport;
DROP PROCEDURE IF EXISTS usp_UpdateSetpoint;
DROP PROCEDURE IF EXISTS usp_ApplySuggestedSetpoints;
DROP PROCEDURE IF EXISTS usp_AddItem;
DROP PROCEDURE IF EXISTS usp_AddItemVariant;
DROP PROCEDURE IF EXISTS usp_UpdateItem;
DROP PROCEDURE IF EXISTS usp_SetItemActive;
DROP PROCEDURE IF EXISTS usp_SetVariantActive;
DROP PROCEDURE IF EXISTS usp_GetSelectableVariants;
DROP PROCEDURE IF EXISTS usp_SaveGiveawayCombination;
DROP PROCEDURE IF EXISTS usp_GetCombinationForEntry;
DROP PROCEDURE IF EXISTS usp_SetAlertRecipients;
DROP PROCEDURE IF EXISTS usp_MarkAlertSent;
DROP PROCEDURE IF EXISTS usp_GetLookups;
DROP PROCEDURE IF EXISTS usp_CreateUser;
DROP PROCEDURE IF EXISTS usp_UpdateUser;
DROP PROCEDURE IF EXISTS usp_SetUserActive;
DROP PROCEDURE IF EXISTS usp_AddAlertRecipient;
DROP PROCEDURE IF EXISTS usp_UpdateAlertRecipient;
DROP PROCEDURE IF EXISTS usp_RemoveAlertRecipient;

DELIMITER $$

-- Manual low-stock re-check (one transaction, one variant, or all)
CREATE PROCEDURE usp_EvaluateLowStock (
    IN p_TriggeringTransactionID INT,
    IN p_VariantID               INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(NULL, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_safe TINYINT DEFAULT @@SESSION.sql_safe_updates;
        DECLARE v_config INT;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            SET SESSION sql_safe_updates = v_safe;
            RESIGNAL;
        END;
        SET SESSION sql_safe_updates = 0;

        SELECT MAX(AlertConfigurationID) INTO v_config FROM AlertConfiguration WHERE IsActive;

        INSERT INTO InventoryAlert (VariantID, TriggeringTransactionID, AlertConfigurationID,
                                    QuantityAtAlert, SetpointAtAlert, AlertStatus)
        SELECT b.VariantID, p_TriggeringTransactionID, v_config, b.CurrentQuantity, b.Setpoint, 'Pending'
        FROM InventoryBalance b
        JOIN ItemVariant v ON v.VariantID = b.VariantID
        JOIN Item i        ON i.ItemID    = v.ItemID
        WHERE b.BaselineQuantity IS NOT NULL
          AND v.IsActive AND i.IsActive
          AND b.CurrentQuantity <= b.Setpoint
          AND (p_VariantID IS NULL OR b.VariantID = p_VariantID)
          AND (p_TriggeringTransactionID IS NULL OR b.VariantID IN
                 (SELECT tl.VariantID FROM TransactionLine tl WHERE tl.TransactionID = p_TriggeringTransactionID))
          AND NOT EXISTS (SELECT 1 FROM InventoryAlert a WHERE a.OpenVariantKey = b.VariantID);

        UPDATE InventoryAlert a
        JOIN InventoryBalance b ON b.VariantID = a.VariantID
           SET a.AlertStatus = 'Resolved', a.ResolvedAt = NOW()
         WHERE a.OpenVariantKey IS NOT NULL
           AND b.CurrentQuantity > b.Setpoint
           AND (p_VariantID IS NULL OR a.VariantID = p_VariantID);

        SET SESSION sql_safe_updates = v_safe;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Records a Stock In / Stock Out / giveaway. All-or-nothing; locks balances to prevent overselling.
-- p_Lines: '[{"VariantID":1,"Quantity":2}, ...]'
CREATE PROCEDURE usp_RecordTransaction (
    IN  p_UserID                 INT,
    IN  p_TransactionType        VARCHAR(3),
    IN  p_Lines                  JSON,
    IN  p_StockInReason          VARCHAR(20),
    IN  p_DistributionCategoryID INT,
    IN  p_RecipientContextID     INT,
    IN  p_EventPurposeID         INT,
    IN  p_EventDetails           VARCHAR(255),
    IN  p_RecipientName          VARCHAR(150),
    IN  p_CombinationID          INT,
    IN  p_Notes                  VARCHAR(1000),
    OUT p_NewTransactionID       INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_safe     TINYINT DEFAULT @@SESSION.sql_safe_updates;
        DECLARE v_type     VARCHAR(3)  DEFAULT UPPER(TRIM(p_TransactionType));
        DECLARE v_reason   VARCHAR(20) DEFAULT p_StockInReason;
        DECLARE v_msg      VARCHAR(2000);
        DECLARE v_count    INT;
        DECLARE v_distinct INT;
        DECLARE v_bad      INT;
        DECLARE v_units    INT;
        DECLARE v_audit    JSON;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            SET @TriggeringTransactionID = NULL;
            SET SESSION sql_safe_updates = v_safe;
            RESIGNAL;
        END;
        SET SESSION sql_safe_updates = 0;
        SET p_NewTransactionID = NULL;

        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: user is not an active authorized user.';
        END IF;

        IF v_type IS NULL OR v_type NOT IN ('IN', 'OUT') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: transaction type must be IN or OUT.';
        END IF;

        IF p_Lines IS NULL OR JSON_TYPE(p_Lines) <> 'ARRAY' OR JSON_LENGTH(p_Lines) = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: at least one item line is required.';
        END IF;

        SELECT COUNT(*), COUNT(DISTINCT j.VariantID),
               SUM(j.VariantID IS NULL OR j.Quantity IS NULL OR j.Quantity <= 0)
          INTO v_count, v_distinct, v_bad
          FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID',
                                                  Quantity  INT PATH '$.Quantity')) j;

        IF v_bad > 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: every line needs a VariantID and a quantity greater than zero.';
        END IF;
        IF v_distinct < v_count THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: an item appears on more than one line; combine it into one line.';
        END IF;

        IF v_type = 'IN' THEN
            SET v_reason = COALESCE(v_reason, 'Received');
            IF v_reason NOT IN ('Received', 'Returned', 'Adjustment') THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock In reason must be Received, Returned, or Adjustment.';
            END IF;
            IF p_DistributionCategoryID IS NOT NULL OR p_RecipientContextID IS NOT NULL THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock In cannot have a distribution category or recipient context.';
            END IF;
        ELSE
            IF v_reason IS NOT NULL THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock Out cannot have a Stock In reason.';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM DistributionCategory
                           WHERE DistributionCategoryID = p_DistributionCategoryID AND IsActive) THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock Out rejected: a valid, active distribution category is required.';
            END IF;
            IF NOT EXISTS (SELECT 1 FROM RecipientContext
                           WHERE RecipientContextID = p_RecipientContextID AND IsActive) THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Stock Out rejected: a valid recipient context (External / In-Network) is required.';
            END IF;
        END IF;

        IF p_EventPurposeID IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM EventPurpose WHERE EventPurposeID = p_EventPurposeID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: event/purpose is not valid.';
        END IF;

        IF p_CombinationID IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM GiveawayCombination WHERE CombinationID = p_CombinationID) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction rejected: giveaway combination template does not exist.';
        END IF;

        SELECT GROUP_CONCAT(j.VariantID ORDER BY j.VariantID SEPARATOR ', ')
          INTO v_msg
          FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID')) j
          LEFT JOIN ItemVariant v      ON v.VariantID = j.VariantID
          LEFT JOIN Item i             ON i.ItemID    = v.ItemID
          LEFT JOIN InventoryBalance b ON b.VariantID = j.VariantID
         WHERE v.VariantID IS NULL OR NOT v.IsActive OR NOT i.IsActive OR b.VariantID IS NULL;

        IF v_msg IS NOT NULL THEN
            SET v_msg = LEFT(CONCAT('Rejected: inactive or unknown VariantID(s): ', v_msg), 128);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        START TRANSACTION;

        SELECT COUNT(*) INTO v_count
          FROM InventoryBalance b
         WHERE b.VariantID IN (SELECT j.VariantID
                                 FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID')) j)
           FOR UPDATE;

        IF v_type = 'OUT' THEN
            SELECT GROUP_CONCAT(CONCAT(i.ItemName,
                                       IF(v.Gender IS NULL AND v.SizeCode IS NULL, '',
                                          CONCAT(' (', CONCAT_WS(' ', v.Gender, v.SizeCode), ')')),
                                       ' req ', j.Quantity, '/avail ', b.CurrentQuantity) SEPARATOR '; ')
              INTO v_msg
              FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID',
                                                      Quantity  INT PATH '$.Quantity')) j
              JOIN InventoryBalance b ON b.VariantID = j.VariantID
              JOIN ItemVariant v      ON v.VariantID = j.VariantID
              JOIN Item i             ON i.ItemID    = v.ItemID
             WHERE j.Quantity > b.CurrentQuantity;

            IF v_msg IS NOT NULL THEN
                SET v_msg = LEFT(CONCAT('Insufficient inventory - nothing saved. ', v_msg), 128);
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
        END IF;

        INSERT INTO InventoryTransaction
              (UserID, TransactionType, StockInReason, DistributionCategoryID, RecipientContextID,
               EventPurposeID, EventDetails, RecipientName, CombinationID, Notes)
        VALUES (p_UserID, v_type, IF(v_type = 'IN', v_reason, NULL), p_DistributionCategoryID, p_RecipientContextID,
                p_EventPurposeID, NULLIF(TRIM(p_EventDetails), ''), NULLIF(TRIM(p_RecipientName), ''),
                p_CombinationID, NULLIF(TRIM(p_Notes), ''));
        SET p_NewTransactionID = LAST_INSERT_ID();

        INSERT INTO TransactionLine (TransactionID, VariantID, Quantity, UnitValueAtTransaction)
        SELECT p_NewTransactionID, j.VariantID, j.Quantity, i.UnitValue
          FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID',
                                                  Quantity  INT PATH '$.Quantity')) j
          JOIN ItemVariant v ON v.VariantID = j.VariantID
          JOIN Item i        ON i.ItemID    = v.ItemID;

        SET @TriggeringTransactionID = p_NewTransactionID;

        UPDATE InventoryBalance b
        JOIN TransactionLine tl ON tl.VariantID = b.VariantID AND tl.TransactionID = p_NewTransactionID
           SET b.CurrentQuantity = b.CurrentQuantity + IF(v_type = 'IN', tl.Quantity, -tl.Quantity),
               b.LastMovementAt  = NOW();

        SET @TriggeringTransactionID = NULL;

        SELECT JSON_ARRAYAGG(JSON_OBJECT('VariantID', tl.VariantID, 'Item', i.ItemName,
                                         'Gender', v.Gender, 'Size', v.SizeCode, 'Qty', tl.Quantity,
                                         'QtyBefore', b.CurrentQuantity - IF(v_type = 'IN', tl.Quantity, -tl.Quantity),
                                         'QtyAfter', b.CurrentQuantity)),
               COUNT(*), SUM(tl.Quantity)
          INTO v_audit, v_count, v_units
          FROM TransactionLine tl
          JOIN InventoryBalance b ON b.VariantID = tl.VariantID
          JOIN ItemVariant v      ON v.VariantID = tl.VariantID
          JOIN Item i             ON i.ItemID    = v.ItemID
         WHERE tl.TransactionID = p_NewTransactionID;

        INSERT INTO TransactionAudit (TransactionID, AuditAction, AuditByUserID, TransactionType,
                                      LineCount, TotalUnits, InventoryEffect, LineDetail)
        VALUES (p_NewTransactionID, 'Created', p_UserID, v_type, v_count, v_units,
                IF(v_type = 'IN', 'Added', 'Removed'), v_audit);

        COMMIT;
        SET SESSION sql_safe_updates = v_safe;

        SELECT t.TransactionID, t.TransactionDate, t.TransactionType,
               i.ItemName, v.Gender, v.SizeCode, tl.Quantity,
               b.CurrentQuantity AS NewQuantity, b.Setpoint,
               IF(b.CurrentQuantity <= b.Setpoint, 'LOW STOCK - alert generated', 'OK') AS StockStatus
          FROM InventoryTransaction t
          JOIN TransactionLine tl ON tl.TransactionID = t.TransactionID
          JOIN ItemVariant v      ON v.VariantID      = tl.VariantID
          JOIN Item i             ON i.ItemID         = v.ItemID
          JOIN InventoryBalance b ON b.VariantID      = tl.VariantID
         WHERE t.TransactionID = p_NewTransactionID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_StockIn (
    IN  p_UserID           INT,
    IN  p_VariantID        INT,
    IN  p_Quantity         INT,
    IN  p_StockInReason    VARCHAR(20),
    IN  p_EventDetails     VARCHAR(255),
    IN  p_Notes            VARCHAR(1000),
    OUT p_NewTransactionID INT
)
BEGIN
    IF p_Quantity IS NULL OR p_Quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be a whole number greater than zero.';
    END IF;
    CALL usp_RecordTransaction(p_UserID, 'IN',
         JSON_ARRAY(JSON_OBJECT('VariantID', p_VariantID, 'Quantity', p_Quantity)),
         p_StockInReason, NULL, NULL, NULL, p_EventDetails, NULL, NULL, p_Notes, p_NewTransactionID);
END$$

CREATE PROCEDURE usp_StockOut (
    IN  p_UserID                 INT,
    IN  p_VariantID              INT,
    IN  p_Quantity               INT,
    IN  p_DistributionCategoryID INT,
    IN  p_RecipientContextID     INT,
    IN  p_EventPurposeID         INT,
    IN  p_EventDetails           VARCHAR(255),
    IN  p_RecipientName          VARCHAR(150),
    IN  p_Notes                  VARCHAR(1000),
    OUT p_NewTransactionID       INT
)
BEGIN
    IF p_Quantity IS NULL OR p_Quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be a whole number greater than zero.';
    END IF;
    CALL usp_RecordTransaction(p_UserID, 'OUT',
         JSON_ARRAY(JSON_OBJECT('VariantID', p_VariantID, 'Quantity', p_Quantity)),
         NULL, p_DistributionCategoryID, p_RecipientContextID, p_EventPurposeID,
         p_EventDetails, p_RecipientName, NULL, p_Notes, p_NewTransactionID);
END$$

-- Soft-deletes a transaction and reverses its inventory
CREATE PROCEDURE usp_DeleteTransaction (
    IN p_TransactionID   INT,
    IN p_DeletedByUserID INT,
    IN p_DeleteReason    VARCHAR(255)
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_DeletedByUserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_safe    TINYINT DEFAULT @@SESSION.sql_safe_updates;
        DECLARE v_type    VARCHAR(3);
        DECLARE v_deleted TINYINT;
        DECLARE v_msg     VARCHAR(2000);
        DECLARE v_count   INT;
        DECLARE v_units   INT;
        DECLARE v_audit   JSON;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            SET @TriggeringTransactionID = NULL;
            SET SESSION sql_safe_updates = v_safe;
            RESIGNAL;
        END;
        SET SESSION sql_safe_updates = 0;

        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_DeletedByUserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delete rejected: user is not an active authorized user.';
        END IF;

        START TRANSACTION;

        SELECT TransactionType, IsDeleted INTO v_type, v_deleted
          FROM InventoryTransaction WHERE TransactionID = p_TransactionID FOR UPDATE;

        IF v_type IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delete rejected: transaction does not exist.';
        END IF;
        IF v_deleted THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delete rejected: transaction was already deleted.';
        END IF;

        SELECT COUNT(*) INTO v_count
          FROM InventoryBalance b
         WHERE b.VariantID IN (SELECT tl.VariantID FROM TransactionLine tl WHERE tl.TransactionID = p_TransactionID)
           FOR UPDATE;

        IF v_type = 'IN' THEN
            SELECT GROUP_CONCAT(CONCAT(i.ItemName, ' -> ', b.CurrentQuantity - tl.Quantity) SEPARATOR '; ')
              INTO v_msg
              FROM TransactionLine tl
              JOIN InventoryBalance b ON b.VariantID = tl.VariantID
              JOIN ItemVariant v      ON v.VariantID = tl.VariantID
              JOIN Item i             ON i.ItemID    = v.ItemID
             WHERE tl.TransactionID = p_TransactionID
               AND b.CurrentQuantity - tl.Quantity < 0;

            IF v_msg IS NOT NULL THEN
                SET v_msg = LEFT(CONCAT('Delete rejected: reversal would make inventory negative. ', v_msg), 128);
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
        END IF;

        SET @TriggeringTransactionID = p_TransactionID;

        UPDATE InventoryBalance b
        JOIN TransactionLine tl ON tl.VariantID = b.VariantID AND tl.TransactionID = p_TransactionID
           SET b.CurrentQuantity = b.CurrentQuantity + IF(v_type = 'OUT', tl.Quantity, -tl.Quantity),
               b.LastMovementAt  = NOW();

        SET @TriggeringTransactionID = NULL;

        UPDATE InventoryTransaction
           SET IsDeleted = TRUE, DeletedAt = NOW(), DeletedByUserID = p_DeletedByUserID,
               DeleteReason = NULLIF(TRIM(p_DeleteReason), '')
         WHERE TransactionID = p_TransactionID;

        SELECT JSON_ARRAYAGG(JSON_OBJECT('VariantID', tl.VariantID, 'Item', i.ItemName,
                                         'Gender', v.Gender, 'Size', v.SizeCode, 'Qty', tl.Quantity,
                                         'QtyBefore', b.CurrentQuantity - IF(v_type = 'OUT', tl.Quantity, -tl.Quantity),
                                         'QtyAfter', b.CurrentQuantity)),
               COUNT(*), SUM(tl.Quantity)
          INTO v_audit, v_count, v_units
          FROM TransactionLine tl
          JOIN InventoryBalance b ON b.VariantID = tl.VariantID
          JOIN ItemVariant v      ON v.VariantID = tl.VariantID
          JOIN Item i             ON i.ItemID    = v.ItemID
         WHERE tl.TransactionID = p_TransactionID;

        INSERT INTO TransactionAudit (TransactionID, AuditAction, AuditByUserID, TransactionType,
                                      LineCount, TotalUnits, InventoryEffect, Reason, LineDetail)
        VALUES (p_TransactionID, 'Deleted', p_DeletedByUserID, v_type, v_count, v_units,
                IF(v_type = 'OUT', 'Added', 'Removed'), NULLIF(TRIM(p_DeleteReason), ''), v_audit);

        COMMIT;
        SET SESSION sql_safe_updates = v_safe;

        SELECT CONCAT('Transaction ', p_TransactionID, ' deleted and inventory reversed.') AS Result;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Opening count: sets baseline and setpoint, posts an Opening Balance Stock In
CREATE PROCEDURE usp_RecordOpeningCount (
    IN p_VariantID   INT,
    IN p_VerifiedQty INT,
    IN p_UserID      INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_safe      TINYINT DEFAULT @@SESSION.sql_safe_updates;
        DECLARE v_txn       INT DEFAULT NULL;
        DECLARE v_before    INT;
        DECLARE v_suggested INT;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            SET @TriggeringTransactionID = NULL;
            SET SESSION sql_safe_updates = v_safe;
            RESIGNAL;
        END;
        SET SESSION sql_safe_updates = 0;

        IF p_VerifiedQty IS NULL OR p_VerifiedQty < 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Verified count must be zero or greater.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM InventoryBalance WHERE VariantID = p_VariantID) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Variant does not exist / has no inventory balance row.';
        END IF;
        IF EXISTS (SELECT 1 FROM InventoryBalance WHERE VariantID = p_VariantID AND BaselineQuantity IS NOT NULL) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Opening count already recorded for this variant. Use Stock In/Out (Adjustment) instead.';
        END IF;

        SET v_suggested = IF(p_VerifiedQty = 0, 0, GREATEST(1, ROUND(p_VerifiedQty * 0.40)));

        START TRANSACTION;

        SELECT CurrentQuantity INTO v_before FROM InventoryBalance WHERE VariantID = p_VariantID FOR UPDATE;

        IF p_VerifiedQty > 0 THEN
            INSERT INTO InventoryTransaction (UserID, TransactionType, StockInReason, Notes)
            VALUES (p_UserID, 'IN', 'Opening Balance', 'Verified physical recount - official go-live opening balance');
            SET v_txn = LAST_INSERT_ID();

            INSERT INTO TransactionLine (TransactionID, VariantID, Quantity, UnitValueAtTransaction)
            SELECT v_txn, v.VariantID, p_VerifiedQty, i.UnitValue
              FROM ItemVariant v JOIN Item i ON i.ItemID = v.ItemID
             WHERE v.VariantID = p_VariantID;
        END IF;

        SET @TriggeringTransactionID = v_txn;

        UPDATE InventoryBalance
           SET BaselineQuantity  = p_VerifiedQty,
               BaselineCountedAt = NOW(),
               CurrentQuantity   = CurrentQuantity + p_VerifiedQty,
               LastMovementAt    = IF(p_VerifiedQty > 0, NOW(), LastMovementAt),
               SetpointUpdatedAt = IF(SetpointIsManual, SetpointUpdatedAt, NOW()),
               SetpointUpdatedBy = IF(SetpointIsManual, SetpointUpdatedBy, p_UserID),
               Setpoint          = IF(SetpointIsManual, Setpoint, v_suggested)
         WHERE VariantID = p_VariantID;

        SET @TriggeringTransactionID = NULL;

        IF v_txn IS NOT NULL THEN
            INSERT INTO TransactionAudit (TransactionID, AuditAction, AuditByUserID, TransactionType,
                                          LineCount, TotalUnits, InventoryEffect, LineDetail)
            SELECT v_txn, 'Created', p_UserID, 'IN', 1, p_VerifiedQty, 'Added',
                   JSON_ARRAY(JSON_OBJECT('VariantID', v.VariantID, 'Item', i.ItemName, 'Gender', v.Gender,
                                          'Size', v.SizeCode, 'Qty', p_VerifiedQty,
                                          'QtyBefore', v_before, 'QtyAfter', b.CurrentQuantity))
              FROM ItemVariant v
              JOIN Item i             ON i.ItemID    = v.ItemID
              JOIN InventoryBalance b ON b.VariantID = v.VariantID
             WHERE v.VariantID = p_VariantID;
        END IF;

        COMMIT;
        SET SESSION sql_safe_updates = v_safe;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Recount for a variant that already has stock: posts the difference as an adjustment
CREATE PROCEDURE usp_ApplyRecount (
    IN p_VariantID   INT,
    IN p_VerifiedQty INT,
    IN p_UserID      INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_safe TINYINT DEFAULT @@SESSION.sql_safe_updates;
        DECLARE v_curr INT;
        DECLARE v_diff INT;
        DECLARE v_txn  INT;
        DECLARE v_cat  INT;
        DECLARE v_ctx  INT;

        IF p_VerifiedQty IS NULL OR p_VerifiedQty < 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Verified count must be zero or greater.';
        END IF;
        SELECT CurrentQuantity INTO v_curr FROM InventoryBalance WHERE VariantID = p_VariantID;
        IF v_curr IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Variant does not exist / has no inventory balance row.';
        END IF;

        SET v_diff = p_VerifiedQty - v_curr;
        IF v_diff > 0 THEN
            CALL usp_StockIn(p_UserID, p_VariantID, v_diff, 'Adjustment', NULL,
                             'Verified physical recount - count correction', v_txn);
        ELSEIF v_diff < 0 THEN
            SELECT DistributionCategoryID INTO v_cat FROM DistributionCategory WHERE CategoryName = 'Other / Inventory Adjustment';
            SELECT RecipientContextID     INTO v_ctx FROM RecipientContext     WHERE ContextName  = 'Not Applicable';
            CALL usp_StockOut(p_UserID, p_VariantID, -v_diff, v_cat, v_ctx, NULL, NULL, NULL,
                              'Verified physical recount - count correction', v_txn);
        END IF;

        SET SESSION sql_safe_updates = 0;
        UPDATE InventoryBalance
           SET BaselineQuantity  = p_VerifiedQty,
               BaselineCountedAt = NOW(),
               SetpointUpdatedAt = IF(SetpointIsManual, SetpointUpdatedAt, NOW()),
               SetpointUpdatedBy = IF(SetpointIsManual, SetpointUpdatedBy, p_UserID),
               Setpoint          = IF(SetpointIsManual, Setpoint,
                                      IF(p_VerifiedQty = 0, 0, GREATEST(1, ROUND(p_VerifiedQty * 0.40))))
         WHERE VariantID = p_VariantID;
        SET SESSION sql_safe_updates = v_safe;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Bulk counts from JSON: '[{"Item":"Red UH Polo","Gender":"Ladies","Size":"L","Qty":4}, ...]'
CREATE PROCEDURE usp_LoadOpeningCounts (
    IN p_Counts JSON,
    IN p_UserID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_done    INT DEFAULT 0;
        DECLARE v_item    VARCHAR(100);
        DECLARE v_gender  VARCHAR(10);
        DECLARE v_size    VARCHAR(10);
        DECLARE v_qty     INT;
        DECLARE v_variant INT;
        DECLARE v_msg     VARCHAR(255);
        DECLARE cur CURSOR FOR
            SELECT j.ItemName, j.Gender, j.SizeCode, j.Qty
              FROM JSON_TABLE(p_Counts, '$[*]' COLUMNS (ItemName VARCHAR(100) PATH '$.Item',
                                                       Gender   VARCHAR(10)  PATH '$.Gender',
                                                       SizeCode VARCHAR(10)  PATH '$.Size',
                                                       Qty      INT          PATH '$.Qty')) j;
        DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

        OPEN cur;
        read_loop: LOOP
            FETCH cur INTO v_item, v_gender, v_size, v_qty;
            IF v_done = 1 THEN LEAVE read_loop; END IF;

            SET v_variant = NULL;
            SELECT MAX(v.VariantID) INTO v_variant
              FROM ItemVariant v JOIN Item i ON i.ItemID = v.ItemID
             WHERE i.ItemName = v_item AND v.Gender <=> v_gender AND v.SizeCode <=> v_size;

            IF v_variant IS NULL THEN
                SET v_msg = LEFT(CONCAT('No catalog variant for: ', v_item, ' ', COALESCE(v_gender, ''), ' ', COALESCE(v_size, '')), 128);
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;

            IF EXISTS (SELECT 1 FROM InventoryBalance WHERE VariantID = v_variant AND BaselineQuantity IS NULL) THEN
                CALL usp_RecordOpeningCount(v_variant, v_qty, p_UserID);
            ELSE
                CALL usp_ApplyRecount(v_variant, v_qty, p_UserID);
            END IF;
        END LOOP;
        CLOSE cur;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Loads the recount from the RecountImport table (Recount_Template.csv via Table Data Import Wizard)
CREATE PROCEDURE usp_LoadOpeningCountsFromImport (
    IN p_UserID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_bad  VARCHAR(2000);
        DECLARE v_json JSON;
        SET SESSION group_concat_max_len = 8192;

        SELECT GROUP_CONCAT(CONCAT_WS(' ', TRIM(r.ItemName), NULLIF(TRIM(r.Gender), ''),
                                      NULLIF(TRIM(r.Size), '')) SEPARATOR '; ')
          INTO v_bad
          FROM RecountImport r
         WHERE NULLIF(TRIM(r.VerifiedQty), '') IS NULL
            OR TRIM(r.VerifiedQty) NOT REGEXP '^[0-9]+$';
        IF v_bad IS NOT NULL THEN
            SET v_bad = LEFT(CONCAT('Fill in a whole-number VerifiedQty for: ', v_bad), 128);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_bad;
        END IF;

        SELECT JSON_ARRAYAGG(JSON_OBJECT('Item',   TRIM(r.ItemName),
                                         'Gender', NULLIF(TRIM(r.Gender), ''),
                                         'Size',   NULLIF(TRIM(r.Size), ''),
                                         'Qty',    CAST(TRIM(r.VerifiedQty) AS UNSIGNED)))
          INTO v_json
          FROM RecountImport r;

        CALL usp_LoadOpeningCounts(v_json, p_UserID);

        SELECT CategoryName, ItemName, VariantLabel, BaselineQuantity, CurrentQuantity,
               SuggestedSetpoint, Setpoint, StockStatus
          FROM vw_CurrentInventory
         ORDER BY CategoryName, ItemName, Gender, SizeSortOrder;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Setpoints
CREATE PROCEDURE usp_UpdateSetpoint (
    IN p_VariantID   INT,
    IN p_NewSetpoint INT,
    IN p_UserID      INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        IF p_NewSetpoint IS NULL OR p_NewSetpoint < 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Setpoint must be zero or greater.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM InventoryBalance WHERE VariantID = p_VariantID) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Variant does not exist.';
        END IF;

        UPDATE InventoryBalance
           SET Setpoint = p_NewSetpoint, SetpointIsManual = TRUE,
               SetpointUpdatedAt = NOW(), SetpointUpdatedBy = p_UserID
         WHERE VariantID = p_VariantID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_ApplySuggestedSetpoints (
    IN p_UserID    INT,
    IN p_VariantID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_safe TINYINT DEFAULT @@SESSION.sql_safe_updates;
        SET SESSION sql_safe_updates = 0;

        UPDATE InventoryBalance
           SET Setpoint = SuggestedSetpoint, SetpointIsManual = FALSE,
               SetpointUpdatedAt = NOW(), SetpointUpdatedBy = p_UserID
         WHERE SuggestedSetpoint IS NOT NULL
           AND (p_VariantID IS NULL OR VariantID = p_VariantID);

        SET SESSION sql_safe_updates = v_safe;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Merchandise maintenance (quantities change only through transactions)
CREATE PROCEDURE usp_AddItem (
    IN  p_UserID                INT,
    IN  p_ItemName              VARCHAR(100),
    IN  p_CategoryID            INT,
    IN  p_UnitValue             DECIMAL(10,2),
    IN  p_Description           VARCHAR(255),
    IN  p_CreateStandardVariant BOOLEAN,
    OUT p_NewItemID             INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Select an active staff member.';
        END IF;

        IF CHAR_LENGTH(TRIM(COALESCE(p_ItemName, ''))) = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Item name is required.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM Category WHERE CategoryID = p_CategoryID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A valid active category is required.';
        END IF;
        IF p_UnitValue < 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unit value cannot be negative.';
        END IF;

        START TRANSACTION;
        INSERT INTO Item (ItemName, CategoryID, UnitValue, Description)
        VALUES (TRIM(p_ItemName), p_CategoryID, p_UnitValue, p_Description);
        SET p_NewItemID = LAST_INSERT_ID();

        IF COALESCE(p_CreateStandardVariant, TRUE) THEN
            INSERT INTO ItemVariant (ItemID, Gender, SizeCode) VALUES (p_NewItemID, NULL, NULL);
            INSERT INTO InventoryBalance (VariantID) VALUES (LAST_INSERT_ID());
        END IF;
        COMMIT;

        SELECT p_NewItemID AS NewItemID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_AddItemVariant (
    IN p_UserID    INT,
    IN  p_ItemID       INT,
    IN  p_Gender       VARCHAR(10),
    IN  p_SizeCode     VARCHAR(10),
    OUT p_NewVariantID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Select an active staff member.';
        END IF;

        IF NOT EXISTS (SELECT 1 FROM Item WHERE ItemID = p_ItemID) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Item does not exist.';
        END IF;

        START TRANSACTION;
        INSERT INTO ItemVariant (ItemID, Gender, SizeCode) VALUES (p_ItemID, p_Gender, p_SizeCode);
        SET p_NewVariantID = LAST_INSERT_ID();
        INSERT INTO InventoryBalance (VariantID) VALUES (p_NewVariantID);
        COMMIT;

        SELECT p_NewVariantID AS NewVariantID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_UpdateItem (
    IN p_UserID    INT,
    IN p_ItemID         INT,
    IN p_ItemName       VARCHAR(100),
    IN p_CategoryID     INT,
    IN p_UnitValue      DECIMAL(10,2),
    IN p_ClearUnitValue BOOLEAN,
    IN p_Description    VARCHAR(255)
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Select an active staff member.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM Item WHERE ItemID = p_ItemID) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Item does not exist.';
        END IF;
        IF p_UnitValue < 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unit value cannot be negative.';
        END IF;

        UPDATE Item
           SET ItemName    = COALESCE(NULLIF(TRIM(p_ItemName), ''), ItemName),
               CategoryID  = COALESCE(p_CategoryID, CategoryID),
               UnitValue   = IF(COALESCE(p_ClearUnitValue, FALSE), NULL, COALESCE(p_UnitValue, UnitValue)),
               Description = COALESCE(p_Description, Description),
               UpdatedAt   = NOW()
         WHERE ItemID = p_ItemID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_SetItemActive (
    IN p_UserID    INT,
    IN p_ItemID   INT,
    IN p_IsActive BOOLEAN
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Select an active staff member.';
        END IF;
        UPDATE Item SET IsActive = p_IsActive, UpdatedAt = NOW() WHERE ItemID = p_ItemID;

        IF p_IsActive THEN CALL usp_EvaluateLowStock(NULL, NULL); END IF;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_SetVariantActive (
    IN p_UserID    INT,
    IN p_VariantID INT,
    IN p_IsActive  BOOLEAN
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Select an active staff member.';
        END IF;
        UPDATE ItemVariant SET IsActive = p_IsActive WHERE VariantID = p_VariantID;
        IF p_IsActive THEN CALL usp_EvaluateLowStock(NULL, p_VariantID); END IF;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_GetSelectableVariants (
    IN p_CategoryID INT
)
BEGIN
    SELECT v.VariantID, i.ItemID, c.CategoryName, i.ItemName, v.Gender, v.SizeCode,
           CONCAT(i.ItemName, IF(v.Gender IS NULL AND v.SizeCode IS NULL, '',
                                 CONCAT(' - ', CONCAT_WS(' ', v.Gender, v.SizeCode)))) AS DisplayName,
           b.CurrentQuantity, b.Setpoint
      FROM ItemVariant v
      JOIN Item i             ON i.ItemID     = v.ItemID
      JOIN Category c         ON c.CategoryID = i.CategoryID
      JOIN InventoryBalance b ON b.VariantID  = v.VariantID
      LEFT JOIN Size s        ON s.SizeCode   = v.SizeCode
     WHERE i.IsActive AND v.IsActive
       AND (p_CategoryID IS NULL OR i.CategoryID = p_CategoryID)
     ORDER BY c.CategoryName, i.ItemName, v.Gender, s.SortOrder;
END$$

-- Giveaway templates
CREATE PROCEDURE usp_SaveGiveawayCombination (
    IN  p_CombinationName               VARCHAR(100),
    IN  p_UserID                        INT,
    IN  p_Lines                         JSON,
    IN  p_Description                   VARCHAR(255),
    IN  p_DefaultDistributionCategoryID INT,
    OUT p_CombinationID                 INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_bad INT;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

        IF p_Lines IS NULL OR JSON_TYPE(p_Lines) <> 'ARRAY' OR JSON_LENGTH(p_Lines) = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A giveaway combination must contain at least one item.';
        END IF;
        SELECT COUNT(*) INTO v_bad
          FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID', Quantity INT PATH '$.Quantity')) j
          LEFT JOIN ItemVariant v ON v.VariantID = j.VariantID
         WHERE v.VariantID IS NULL OR j.Quantity IS NULL OR j.Quantity <= 0;
        IF v_bad > 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Template contains an unknown item or a quantity of zero or less.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
        END IF;

        START TRANSACTION;
        SET p_CombinationID = NULL;
        SELECT CombinationID INTO p_CombinationID FROM GiveawayCombination WHERE CombinationName = p_CombinationName;

        IF p_CombinationID IS NULL THEN
            INSERT INTO GiveawayCombination (CombinationName, Description, DefaultDistributionCategoryID, CreatedByUserID)
            VALUES (p_CombinationName, p_Description, p_DefaultDistributionCategoryID, p_UserID);
            SET p_CombinationID = LAST_INSERT_ID();
        ELSE
            UPDATE GiveawayCombination
               SET Description = COALESCE(p_Description, Description),
                   DefaultDistributionCategoryID = COALESCE(p_DefaultDistributionCategoryID, DefaultDistributionCategoryID),
                   IsActive = TRUE
             WHERE CombinationID = p_CombinationID;
            DELETE FROM GiveawayCombinationLine WHERE CombinationID = p_CombinationID;
        END IF;

        INSERT INTO GiveawayCombinationLine (CombinationID, VariantID, SuggestedQuantity)
        SELECT p_CombinationID, j.VariantID, j.Quantity
          FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID', Quantity INT PATH '$.Quantity')) j;
        COMMIT;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_GetCombinationForEntry (
    IN p_CombinationID INT
)
BEGIN
    SELECT gc.CombinationID, gc.CombinationName, gc.DefaultDistributionCategoryID,
           gl.VariantID, i.ItemName, v.Gender, v.SizeCode,
           gl.SuggestedQuantity, b.CurrentQuantity AS Available,
           CASE WHEN NOT i.IsActive OR NOT v.IsActive         THEN 'Inactive - remove'
                WHEN b.CurrentQuantity < gl.SuggestedQuantity THEN 'Insufficient - adjust'
                ELSE 'OK' END AS LineStatus
      FROM GiveawayCombination gc
      JOIN GiveawayCombinationLine gl ON gl.CombinationID = gc.CombinationID
      JOIN ItemVariant v              ON v.VariantID      = gl.VariantID
      JOIN Item i                     ON i.ItemID         = v.ItemID
      JOIN InventoryBalance b         ON b.VariantID      = gl.VariantID
     WHERE gc.CombinationID = p_CombinationID
     ORDER BY i.ItemName;
END$$

-- Alerts: the application sends email from vw_PendingAlertEmails, then calls usp_MarkAlertSent
CREATE PROCEDURE usp_SetAlertRecipients (
    IN p_Recipients JSON,
    IN p_UserID     INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_config INT;
        DECLARE v_count  INT;
        DECLARE v_bad    INT;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

        IF p_Recipients IS NULL OR JSON_TYPE(p_Recipients) <> 'ARRAY' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Recipients must be a JSON array of 1 to 3 entries.';
        END IF;
        SELECT COUNT(*), SUM(j.Slot IS NULL OR j.Slot NOT BETWEEN 1 AND 3 OR j.Email IS NULL OR j.Email NOT LIKE '%_@_%._%')
          INTO v_count, v_bad
          FROM JSON_TABLE(p_Recipients, '$[*]' COLUMNS (Slot INT PATH '$.Slot', Email VARCHAR(254) PATH '$.Email')) j;
        IF v_count NOT BETWEEN 1 AND 3 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Between one and three alert recipients are required.';
        END IF;
        IF v_bad > 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Each recipient needs a Slot of 1-3 and a valid email address.';
        END IF;

        START TRANSACTION;
        SELECT MAX(AlertConfigurationID) INTO v_config FROM AlertConfiguration WHERE IsActive;

        IF v_config IS NULL THEN
            INSERT INTO AlertConfiguration (ConfigurationName, UpdatedByUserID)
            VALUES ('Low Inventory Alerts', p_UserID);
            SET v_config = LAST_INSERT_ID();
        ELSE
            UPDATE AlertConfiguration SET UpdatedAt = NOW(), UpdatedByUserID = p_UserID
             WHERE AlertConfigurationID = v_config;
        END IF;

        DELETE FROM AlertRecipient WHERE AlertConfigurationID = v_config;

        INSERT INTO AlertRecipient (AlertConfigurationID, RecipientSlot, RecipientName, Email)
        SELECT v_config, j.Slot, NULLIF(TRIM(j.RecipientName), ''), LOWER(TRIM(j.Email))
          FROM JSON_TABLE(p_Recipients, '$[*]' COLUMNS (Slot          INT          PATH '$.Slot',
                                                       RecipientName VARCHAR(100) PATH '$.Name',
                                                       Email         VARCHAR(254) PATH '$.Email')) j;
        COMMIT;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- p_SendError NULL = sent; after 5 failed attempts the alert moves to vw_FailedAlertEmails
CREATE PROCEDURE usp_MarkAlertSent (
    IN p_AlertID            INT,
    IN p_RecipientsNotified VARCHAR(800),
    IN p_SendError          VARCHAR(1000)
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(NULL, @app_user_id), @app_ctx = 1;
    BEGIN
        IF p_SendError IS NOT NULL THEN
            UPDATE InventoryAlert
               SET LastSendError = p_SendError, SendAttempts = SendAttempts + 1
             WHERE AlertID = p_AlertID AND AlertStatus = 'Pending';
        ELSE
            UPDATE InventoryAlert
               SET AlertStatus = 'Sent', EmailSentAt = NOW(), SendAttempts = SendAttempts + 1,
                   RecipientsNotified = p_RecipientsNotified, LastSendError = NULL
             WHERE AlertID = p_AlertID AND AlertStatus = 'Pending';
        END IF;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Staff maintenance (managed in the web app)
CREATE PROCEDURE usp_CreateUser (
    IN  p_Email           VARCHAR(254),
    IN  p_FirstName       VARCHAR(50),
    IN  p_LastName        VARCHAR(50),
    IN  p_UserType        VARCHAR(30),
    IN  p_Username        VARCHAR(50),
    IN  p_CreatedByUserID INT,
    OUT p_NewUserID       INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_CreatedByUserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_email    VARCHAR(254) DEFAULT LOWER(TRIM(p_Email));
        DECLARE v_username VARCHAR(50);
        DECLARE v_type     VARCHAR(30) DEFAULT COALESCE(NULLIF(TRIM(p_UserType), ''), 'Other Authorized');

        IF p_CreatedByUserID IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_CreatedByUserID AND IsActive AND NOT IsSystemAccount) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pick an active staff member (or leave blank).';
        END IF;
        IF v_email IS NULL OR v_email NOT LIKE '%_@_%._%' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Enter a valid email address.';
        END IF;
        IF NULLIF(TRIM(p_FirstName), '') IS NULL OR NULLIF(TRIM(p_LastName), '') IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'First and last name are required.';
        END IF;
        IF v_type NOT IN ('Full-Time Staff', 'Student Worker', 'Student Intern', 'Other Authorized') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User type must be Full-Time Staff, Student Worker, Student Intern or Other Authorized.';
        END IF;
        IF EXISTS (SELECT 1 FROM AppUser WHERE Email = v_email AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A staff member with this email already exists.';
        END IF;
        IF EXISTS (SELECT 1 FROM AppUser WHERE Email = v_email) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This email belongs to a deactivated staff member - reactivate them instead.';
        END IF;

        SET v_username = COALESCE(NULLIF(TRIM(p_Username), ''), SUBSTRING_INDEX(v_email, '@', 1));
        IF EXISTS (SELECT 1 FROM AppUser WHERE Username = v_username) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That username is taken - enter a different username.';
        END IF;

        INSERT INTO AppUser (Username, FirstName, LastName, Email, UserType, CreatedByUserID)
        VALUES (v_username, TRIM(p_FirstName), TRIM(p_LastName), v_email, v_type, p_CreatedByUserID);
        SET p_NewUserID = LAST_INSERT_ID();
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_UpdateUser (
    IN p_UserID          INT,
    IN p_Email           VARCHAR(254),
    IN p_FirstName       VARCHAR(50),
    IN p_LastName        VARCHAR(50),
    IN p_UserType        VARCHAR(30),
    IN p_UpdatedByUserID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UpdatedByUserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_email VARCHAR(254) DEFAULT LOWER(TRIM(p_Email));

        IF p_UpdatedByUserID IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UpdatedByUserID AND IsActive AND NOT IsSystemAccount) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pick an active staff member (or leave blank).';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND NOT IsSystemAccount) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Staff member not found.';
        END IF;
        IF v_email IS NOT NULL THEN
            IF v_email NOT LIKE '%_@_%._%' THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Enter a valid email address.';
            END IF;
            IF EXISTS (SELECT 1 FROM AppUser WHERE Email = v_email AND UserID <> p_UserID) THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Another staff member already uses this email.';
            END IF;
        END IF;
        IF p_UserType IS NOT NULL
           AND p_UserType NOT IN ('Full-Time Staff', 'Student Worker', 'Student Intern', 'Other Authorized') THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User type must be Full-Time Staff, Student Worker, Student Intern or Other Authorized.';
        END IF;

        UPDATE AppUser
           SET Email     = COALESCE(v_email, Email),
               FirstName = COALESCE(NULLIF(TRIM(p_FirstName), ''), FirstName),
               LastName  = COALESCE(NULLIF(TRIM(p_LastName), ''),  LastName),
               UserType  = COALESCE(p_UserType, UserType)
         WHERE UserID = p_UserID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_SetUserActive (
    IN p_UserID          INT,
    IN p_IsActive        BOOLEAN,
    IN p_UpdatedByUserID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UpdatedByUserID, @app_user_id), @app_ctx = 1;
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND NOT IsSystemAccount) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Staff member not found.';
        END IF;
        IF NOT p_IsActive
           AND (SELECT COUNT(*) FROM AppUser WHERE IsActive AND NOT IsSystemAccount AND UserID <> p_UserID) = 0 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Add another staff member before removing the last one.';
        END IF;

        UPDATE AppUser SET IsActive = p_IsActive WHERE UserID = p_UserID;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Alert recipient maintenance (managed in the web app)
CREATE PROCEDURE usp_AddAlertRecipient (
    IN  p_Name             VARCHAR(100),
    IN  p_Email            VARCHAR(254),
    IN  p_UserID           INT,
    OUT p_AlertRecipientID INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_email  VARCHAR(254) DEFAULT LOWER(TRIM(p_Email));
        DECLARE v_config INT;
        DECLARE v_slot   INT;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

        IF p_UserID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pick an active staff member (or leave blank).';
        END IF;
        IF v_email IS NULL OR v_email NOT LIKE '%_@_%._%' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Enter a valid email address.';
        END IF;

        START TRANSACTION;
        SELECT MAX(AlertConfigurationID) INTO v_config FROM AlertConfiguration WHERE IsActive;
        IF v_config IS NULL THEN
            INSERT INTO AlertConfiguration (ConfigurationName, UpdatedByUserID)
            VALUES ('Low Inventory Alerts', p_UserID);
            SET v_config = LAST_INSERT_ID();
        END IF;
        SELECT AlertConfigurationID INTO v_config FROM AlertConfiguration
         WHERE AlertConfigurationID = v_config FOR UPDATE;

        IF EXISTS (SELECT 1 FROM AlertRecipient WHERE AlertConfigurationID = v_config AND Email = v_email) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That email is already an alert recipient.';
        END IF;

        SELECT MIN(s.n) INTO v_slot
          FROM (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3) s
         WHERE NOT EXISTS (SELECT 1 FROM AlertRecipient ar
                            WHERE ar.AlertConfigurationID = v_config AND ar.RecipientSlot = s.n);
        IF v_slot IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'There are already three alert recipients - remove or edit one first.';
        END IF;

        INSERT INTO AlertRecipient (AlertConfigurationID, RecipientSlot, RecipientName, Email)
        VALUES (v_config, v_slot, NULLIF(TRIM(p_Name), ''), v_email);
        SET p_AlertRecipientID = LAST_INSERT_ID();

        UPDATE AlertConfiguration SET UpdatedAt = NOW(), UpdatedByUserID = p_UserID
         WHERE AlertConfigurationID = v_config;
        COMMIT;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_UpdateAlertRecipient (
    IN p_AlertRecipientID INT,
    IN p_Name             VARCHAR(100),
    IN p_Email            VARCHAR(254),
    IN p_UserID           INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_email  VARCHAR(254) DEFAULT LOWER(TRIM(p_Email));
        DECLARE v_config INT;

        IF p_UserID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pick an active staff member (or leave blank).';
        END IF;
        SELECT AlertConfigurationID INTO v_config FROM AlertRecipient WHERE AlertRecipientID = p_AlertRecipientID;
        IF v_config IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Alert recipient not found.';
        END IF;
        IF v_email IS NOT NULL THEN
            IF v_email NOT LIKE '%_@_%._%' THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Enter a valid email address.';
            END IF;
            IF EXISTS (SELECT 1 FROM AlertRecipient WHERE AlertConfigurationID = v_config
                                                      AND Email = v_email AND AlertRecipientID <> p_AlertRecipientID) THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'That email is already an alert recipient.';
            END IF;
        END IF;

        UPDATE AlertRecipient
           SET RecipientName = COALESCE(NULLIF(TRIM(p_Name), ''), RecipientName),
               Email         = COALESCE(v_email, Email)
         WHERE AlertRecipientID = p_AlertRecipientID;
        UPDATE AlertConfiguration SET UpdatedAt = NOW(), UpdatedByUserID = p_UserID
         WHERE AlertConfigurationID = v_config;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

CREATE PROCEDURE usp_RemoveAlertRecipient (
    IN p_AlertRecipientID INT,
    IN p_UserID           INT
)
BEGIN
    DECLARE v_ctx_user INT DEFAULT @app_user_id;
    DECLARE v_ctx_app  INT DEFAULT @app_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
        RESIGNAL;
    END;
    SET @app_user_id = COALESCE(p_UserID, @app_user_id), @app_ctx = 1;
    BEGIN
        DECLARE v_config INT;
        DECLARE v_count  INT;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

        IF p_UserID IS NOT NULL AND NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Pick an active staff member (or leave blank).';
        END IF;

        START TRANSACTION;
        SELECT AlertConfigurationID INTO v_config FROM AlertRecipient WHERE AlertRecipientID = p_AlertRecipientID;
        IF v_config IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Alert recipient not found.';
        END IF;
        SELECT AlertConfigurationID INTO v_config FROM AlertConfiguration
         WHERE AlertConfigurationID = v_config FOR UPDATE;
        SELECT COUNT(*) INTO v_count FROM AlertRecipient WHERE AlertConfigurationID = v_config;
        IF v_count <= 1 THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'At least one alert recipient is required - edit this one or add another first.';
        END IF;

        DELETE FROM AlertRecipient WHERE AlertRecipientID = p_AlertRecipientID;
        UPDATE AlertConfiguration SET UpdatedAt = NOW(), UpdatedByUserID = p_UserID
         WHERE AlertConfigurationID = v_config;
        COMMIT;
    END;
    SET @app_user_id = v_ctx_user, @app_ctx = v_ctx_app;
END$$

-- Drop-down values for the entry forms
CREATE PROCEDURE usp_GetLookups ()
BEGIN
    SELECT DistributionCategoryID AS id, CategoryName AS name, IsGiveaway
      FROM DistributionCategory WHERE IsActive ORDER BY CategoryName;
    SELECT RecipientContextID AS id, ContextName AS name
      FROM RecipientContext WHERE IsActive ORDER BY RecipientContextID;
    SELECT EventPurposeID AS id, PurposeName AS name
      FROM EventPurpose WHERE IsActive ORDER BY PurposeName;
    SELECT CategoryID AS id, CategoryName AS name
      FROM Category WHERE IsActive ORDER BY CategoryName;
    SELECT SizeCode AS id, SizeName AS name FROM Size ORDER BY SortOrder;
END$$

DELIMITER ;

SELECT 'Part 2 complete: procedures created.' AS Status;
