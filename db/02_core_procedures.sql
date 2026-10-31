/* =====================================================================
   PART 2 : CORE STORED PROCEDURES
   Multi-item input is a JSON array, e.g.
     '[{"VariantID": 7, "Quantity": 1}, {"VariantID": 8, "Quantity": 2}]'
   MySQL procedures have no default parameters: pass NULL for anything
   optional, and a session variable (@id) for OUT parameters.
   ===================================================================== */
USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

DROP PROCEDURE IF EXISTS usp_EvaluateLowStock;
DROP PROCEDURE IF EXISTS usp_RecordTransaction;
DROP PROCEDURE IF EXISTS usp_StockIn;
DROP PROCEDURE IF EXISTS usp_StockOut;
DROP PROCEDURE IF EXISTS usp_DeleteTransaction;
DROP PROCEDURE IF EXISTS usp_RecordOpeningCount;
DROP PROCEDURE IF EXISTS usp_LoadOpeningCounts;

DELIMITER $$

/* =====================================================================
   usp_EvaluateLowStock  (manual / bulk re-check)
   Routine detection is automatic via trg_InventoryBalance_LowStockAlert.
   Scope: one transaction's items, one variant, or (both NULL) everything.
   ===================================================================== */
CREATE PROCEDURE usp_EvaluateLowStock (
    IN p_TriggeringTransactionID INT,
    IN p_VariantID               INT
)
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

    -- 1) raise alerts for counted, active items at/below setpoint with no open alert
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

    -- 2) resolve open alerts that are no longer low
    UPDATE InventoryAlert a
    JOIN InventoryBalance b ON b.VariantID = a.VariantID
       SET a.AlertStatus = 'Resolved', a.ResolvedAt = NOW()
     WHERE a.OpenVariantKey IS NOT NULL
       AND b.CurrentQuantity > b.Setpoint
       AND (p_VariantID IS NULL OR a.VariantID = p_VariantID);

    SET SESSION sql_safe_updates = v_safe;
END$$

/* =====================================================================
   usp_RecordTransaction  (CORE ENGINE)
   Stock In, Individual Stock Out, Multi-Item Giveaway.
   All-or-nothing: if ANY line is short, nothing is written.
   p_Lines = '[{"VariantID":1,"Quantity":2}, ...]'
   ===================================================================== */
CREATE PROCEDURE usp_RecordTransaction (
    IN  p_UserID                 INT,
    IN  p_TransactionType        VARCHAR(3),      -- 'IN' | 'OUT'
    IN  p_Lines                  JSON,
    IN  p_StockInReason          VARCHAR(20),     -- IN : Received | Returned | Adjustment (NULL = Received)
    IN  p_DistributionCategoryID INT,             -- OUT: required
    IN  p_RecipientContextID     INT,             -- OUT: required
    IN  p_EventPurposeID         INT,
    IN  p_EventDetails           VARCHAR(255),
    IN  p_RecipientName          VARCHAR(150),
    IN  p_CombinationID          INT,
    IN  p_Notes                  VARCHAR(1000),
    OUT p_NewTransactionID       INT
)
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
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;          -- [SEC 4.9] audit context
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @TriggeringTransactionID = NULL;
        SET @app_user_id = v_prev_ctx;                    -- [SEC 4.9]
        SET SESSION sql_safe_updates = v_safe;
        RESIGNAL;
    END;
    SET SESSION sql_safe_updates = 0;
    SET @app_user_id = p_UserID;                          -- [SEC 4.9] triggers stamp/attribute this user
    SET p_NewTransactionID = NULL;

    /* ---------- header validation ---------- */
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

    /* ---------- lines must be existing, ACTIVE merchandise ---------- */
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

    /* lock affected balance rows so two users can't oversell the same item */
    SELECT COUNT(*) INTO v_count
      FROM InventoryBalance b
     WHERE b.VariantID IN (SELECT j.VariantID
                             FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID')) j)
       FOR UPDATE;

    /* availability: every line, all-or-nothing */
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

    /* header */
    INSERT INTO InventoryTransaction
          (UserID, TransactionType, StockInReason, DistributionCategoryID, RecipientContextID,
           EventPurposeID, EventDetails, RecipientName, CombinationID, Notes)
    VALUES (p_UserID, v_type, IF(v_type = 'IN', v_reason, NULL), p_DistributionCategoryID, p_RecipientContextID,
            p_EventPurposeID, NULLIF(TRIM(p_EventDetails), ''), NULLIF(TRIM(p_RecipientName), ''),
            p_CombinationID, NULLIF(TRIM(p_Notes), ''));
    SET p_NewTransactionID = LAST_INSERT_ID();

    /* lines (unit value snapshot keeps historical value accurate) */
    INSERT INTO TransactionLine (TransactionID, VariantID, Quantity, UnitValueAtTransaction)
    SELECT p_NewTransactionID, j.VariantID, j.Quantity, i.UnitValue
      FROM JSON_TABLE(p_Lines, '$[*]' COLUMNS (VariantID INT PATH '$.VariantID',
                                              Quantity  INT PATH '$.Quantity')) j
      JOIN ItemVariant v ON v.VariantID = j.VariantID
      JOIN Item i        ON i.ItemID    = v.ItemID;

    /* update inventory; trg_InventoryBalance_LowStockAlert checks setpoints */
    SET @TriggeringTransactionID = p_NewTransactionID;

    UPDATE InventoryBalance b
    JOIN TransactionLine tl ON tl.VariantID = b.VariantID AND tl.TransactionID = p_NewTransactionID
       SET b.CurrentQuantity = b.CurrentQuantity + IF(v_type = 'IN', tl.Quantity, -tl.Quantity),
           b.LastMovementAt  = NOW();

    SET @TriggeringTransactionID = NULL;

    /* audit record (WBS 5.5) */
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
    SET @app_user_id = v_prev_ctx;                        -- [SEC 4.9]
    SET SESSION sql_safe_updates = v_safe;

    /* confirmation for the UI */
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
END$$

/* ---------- single-item wrappers for the entry forms ---------- */
CREATE PROCEDURE usp_StockIn (
    IN  p_UserID           INT,
    IN  p_VariantID        INT,
    IN  p_Quantity         INT,
    IN  p_StockInReason    VARCHAR(20),       -- NULL = Received
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

/* =====================================================================
   usp_DeleteTransaction  (Use Case 04)
   Reverses inventory, blocks negative balances, soft-deletes, audits.
   ===================================================================== */
CREATE PROCEDURE usp_DeleteTransaction (
    IN p_TransactionID   INT,
    IN p_DeletedByUserID INT,
    IN p_DeleteReason    VARCHAR(255)
)
BEGIN
    DECLARE v_safe    TINYINT DEFAULT @@SESSION.sql_safe_updates;
    DECLARE v_type    VARCHAR(3);
    DECLARE v_deleted TINYINT;
    DECLARE v_msg     VARCHAR(2000);
    DECLARE v_count   INT;
    DECLARE v_units   INT;
    DECLARE v_audit   JSON;
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;          -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @TriggeringTransactionID = NULL;
        SET @app_user_id = v_prev_ctx;                    -- [SEC 4.9]
        SET SESSION sql_safe_updates = v_safe;
        RESIGNAL;
    END;
    SET SESSION sql_safe_updates = 0;
    SET @app_user_id = p_DeletedByUserID;                 -- [SEC 4.9]

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

    -- deleting a Stock IN removes units; they must still be on the shelf
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

    -- reverse inventory (low-stock trigger re-checks each affected item)
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

    -- audit record: what was reversed, balances before/after
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
    SET @app_user_id = v_prev_ctx;                        -- [SEC 4.9]
    SET SESSION sql_safe_updates = v_safe;

    SELECT CONCAT('Transaction ', p_TransactionID, ' deleted and inventory reversed.') AS Result;
END$$

/* =====================================================================
   usp_RecordOpeningCount  (Go-Live)
   Verified recount -> baseline + 'Opening Balance' Stock In +
   setpoint = ~40% suggestion (unless already set manually).
   ===================================================================== */
CREATE PROCEDURE usp_RecordOpeningCount (
    IN p_VariantID   INT,
    IN p_VerifiedQty INT,
    IN p_UserID      INT
)
BEGIN
    DECLARE v_safe      TINYINT DEFAULT @@SESSION.sql_safe_updates;
    DECLARE v_txn       INT DEFAULT NULL;
    DECLARE v_before    INT;
    DECLARE v_suggested INT;
    DECLARE v_prev_ctx  INT DEFAULT @app_user_id;         -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @TriggeringTransactionID = NULL;
        SET @app_user_id = v_prev_ctx;                    -- [SEC 4.9]
        SET SESSION sql_safe_updates = v_safe;
        RESIGNAL;
    END;
    SET SESSION sql_safe_updates = 0;
    SET @app_user_id = p_UserID;                          -- [SEC 4.9]

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

    -- same formula as InventoryBalance.SuggestedSetpoint
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

    -- ONE update so the low-stock trigger evaluates the final state only
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
    SET @app_user_id = v_prev_ctx;                        -- [SEC 4.9]
    SET SESSION sql_safe_updates = v_safe;
END$$

/* usp_LoadOpeningCounts - bulk go-live load from a JSON list:
   '[{"Item":"Red UH Polo","Gender":"Ladies","Size":"L","Qty":4}, ...]'
   Gender/Size omitted = Standard variant. Already-counted variants are skipped. */
CREATE PROCEDURE usp_LoadOpeningCounts (
    IN p_Counts JSON,
    IN p_UserID INT
)
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
        END IF;
    END LOOP;
    CLOSE cur;
END$$

DELIMITER ;

SELECT 'Part 2 complete: core procedures created.' AS Status;