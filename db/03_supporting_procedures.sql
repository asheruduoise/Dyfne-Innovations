/* =====================================================================
   PART 3 : SETPOINT / MERCHANDISE / TEMPLATE / ALERT PROCEDURES
   [SEC 4.9] changes in this part (Security & Audit Design Spec 4.9):
     - Every write procedure now takes the signed-in user (p_UserID) and
       rejects inactive/unknown users. NEW parameter on:
         usp_AddItem, usp_AddItemVariant, usp_UpdateItem,
         usp_SetItemActive, usp_SetVariantActive   (p_UserID is FIRST)
     - Every write procedure sets @app_user_id for the duration of the call
       so the Part 7 audit triggers can stamp/attribute the change, and
       restores it on success AND on error.
   ===================================================================== */
USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

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

DELIMITER $$

/* ---------- SETPOINTS (low-stock trigger reacts to the new value) ---------- */
CREATE PROCEDURE usp_UpdateSetpoint (
    IN p_VariantID   INT,
    IN p_NewSetpoint INT,
    IN p_UserID      INT
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

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

    SET @app_user_id = v_prev_ctx;
END$$

-- Reset one variant (or all when p_VariantID IS NULL) to the ~40% suggestion
CREATE PROCEDURE usp_ApplySuggestedSetpoints (
    IN p_UserID    INT,
    IN p_VariantID INT
)
BEGIN
    DECLARE v_safe TINYINT DEFAULT @@SESSION.sql_safe_updates;
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @app_user_id = v_prev_ctx;
        SET SESSION sql_safe_updates = v_safe;
        RESIGNAL;
    END;
    SET @app_user_id = p_UserID;
    SET SESSION sql_safe_updates = 0;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN   -- [SEC 4.9]
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
    END IF;

    UPDATE InventoryBalance
       SET Setpoint = SuggestedSetpoint, SetpointIsManual = FALSE,
           SetpointUpdatedAt = NOW(), SetpointUpdatedBy = p_UserID
     WHERE SuggestedSetpoint IS NOT NULL
       AND (p_VariantID IS NULL OR VariantID = p_VariantID);

    SET SESSION sql_safe_updates = v_safe;
    SET @app_user_id = v_prev_ctx;
END$$

/* ---------- MERCHANDISE (quantity only changes through transactions) ---------- */
CREATE PROCEDURE usp_AddItem (
    IN  p_UserID                INT,             -- [SEC 4.9] NEW: signed-in user
    IN  p_ItemName              VARCHAR(100),
    IN  p_CategoryID            INT,
    IN  p_UnitValue             DECIMAL(10,2),   -- NULL = unknown
    IN  p_Description           VARCHAR(255),
    IN  p_CreateStandardVariant BOOLEAN,         -- FALSE for apparel (add sized variants instead)
    OUT p_NewItemID             INT
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
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

    SET @app_user_id = v_prev_ctx;
    SELECT p_NewItemID AS NewItemID;
END$$

CREATE PROCEDURE usp_AddItemVariant (
    IN  p_UserID       INT,                      -- [SEC 4.9] NEW
    IN  p_ItemID       INT,
    IN  p_Gender       VARCHAR(10),
    IN  p_SizeCode     VARCHAR(10),
    OUT p_NewVariantID INT
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM Item WHERE ItemID = p_ItemID) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Item does not exist.';
    END IF;

    START TRANSACTION;
    INSERT INTO ItemVariant (ItemID, Gender, SizeCode) VALUES (p_ItemID, p_Gender, p_SizeCode);
    SET p_NewVariantID = LAST_INSERT_ID();
    INSERT INTO InventoryBalance (VariantID) VALUES (p_NewVariantID);   -- every variant gets qty + setpoint
    COMMIT;

    SET @app_user_id = v_prev_ctx;
    SELECT p_NewVariantID AS NewVariantID;
END$$

-- Pass NULL to leave a field unchanged; p_ClearUnitValue = TRUE sets value back to "unknown"
CREATE PROCEDURE usp_UpdateItem (
    IN p_UserID         INT,                     -- [SEC 4.9] NEW
    IN p_ItemID         INT,
    IN p_ItemName       VARCHAR(100),
    IN p_CategoryID     INT,
    IN p_UnitValue      DECIMAL(10,2),
    IN p_ClearUnitValue BOOLEAN,
    IN p_Description    VARCHAR(255)
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
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

    SET @app_user_id = v_prev_ctx;
END$$

CREATE PROCEDURE usp_SetItemActive (
    IN p_UserID   INT,                           -- [SEC 4.9] NEW
    IN p_ItemID   INT,
    IN p_IsActive BOOLEAN
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
    END IF;

    UPDATE Item SET IsActive = p_IsActive, UpdatedAt = NOW() WHERE ItemID = p_ItemID;
    -- history untouched; inactive items stop appearing in pick-lists
    IF p_IsActive THEN CALL usp_EvaluateLowStock(NULL, NULL); END IF;

    SET @app_user_id = v_prev_ctx;
END$$

CREATE PROCEDURE usp_SetVariantActive (
    IN p_UserID    INT,                          -- [SEC 4.9] NEW
    IN p_VariantID INT,
    IN p_IsActive  BOOLEAN
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
    END IF;

    UPDATE ItemVariant SET IsActive = p_IsActive WHERE VariantID = p_VariantID;
    IF p_IsActive THEN CALL usp_EvaluateLowStock(NULL, p_VariantID); END IF;

    SET @app_user_id = v_prev_ctx;
END$$

-- Pick-list for entry forms: ONLY active merchandise is selectable (NULL = all categories)
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

/* ---------- GIVEAWAY COMBINATION TEMPLATES ---------- */
-- Create or replace a template; p_Lines = '[{"VariantID":1,"Quantity":1}, ...]'
CREATE PROCEDURE usp_SaveGiveawayCombination (
    IN  p_CombinationName               VARCHAR(100),
    IN  p_UserID                        INT,
    IN  p_Lines                         JSON,
    IN  p_Description                   VARCHAR(255),
    IN  p_DefaultDistributionCategoryID INT,
    OUT p_CombinationID                 INT
)
BEGIN
    DECLARE v_bad INT;
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

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

    SET @app_user_id = v_prev_ctx;
END$$

-- Loads a template into the entry form; user can still add/remove/change lines
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

/* ---------- ALERTS: MySQL cannot send email; the app reads
   vw_PendingAlertEmails, sends via SMTP, then calls usp_MarkAlertSent ---------- */
-- '[{"Slot":1,"Name":"Sponsor","Email":"a@uh.edu"}, ...]'  (1 to 3 entries)
CREATE PROCEDURE usp_SetAlertRecipients (
    IN p_Recipients JSON,
    IN p_UserID     INT
)
BEGIN
    DECLARE v_config INT;
    DECLARE v_count  INT;
    DECLARE v_bad    INT;
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;                       -- [SEC 4.9]
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_UserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_UserID AND IsActive) THEN   -- [SEC 4.9]
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User is not an active authorized user.';
    END IF;
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
    SELECT v_config, j.Slot, j.RecipientName, TRIM(j.Email)
      FROM JSON_TABLE(p_Recipients, '$[*]' COLUMNS (Slot          INT          PATH '$.Slot',
                                                   RecipientName VARCHAR(100) PATH '$.Name',
                                                   Email         VARCHAR(254) PATH '$.Email')) j;
    COMMIT;

    SET @app_user_id = v_prev_ctx;
END$$

-- Called by the application after it emails an alert (pass p_SendError to log a failure)
CREATE PROCEDURE usp_MarkAlertSent (
    IN p_AlertID            INT,
    IN p_RecipientsNotified VARCHAR(800),
    IN p_SendError          VARCHAR(1000)
)
BEGIN
    IF p_SendError IS NOT NULL THEN
        UPDATE InventoryAlert SET LastSendError = p_SendError WHERE AlertID = p_AlertID;
    ELSE
        UPDATE InventoryAlert
           SET AlertStatus = 'Sent', EmailSentAt = NOW(),
               RecipientsNotified = p_RecipientsNotified, LastSendError = NULL
         WHERE AlertID = p_AlertID AND AlertStatus = 'Pending';
    END IF;
END$$

DELIMITER ;

SELECT 'Part 3 complete: supporting procedures created.' AS Status;
