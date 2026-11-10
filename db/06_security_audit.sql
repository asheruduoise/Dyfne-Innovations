-- =====================================================================
-- UH Government & Community Relations - Inventory Management System
-- Dfyne Innovations | CIS 4375 | Fall 2026
-- Part 6: Security and audit (WBS 4.9)
-- Every write procedure sets @app_user_id / @app_ctx while it runs. Triggers
-- use them to attribute changes; changes made outside the procedures are
-- logged with IsDirectEdit = TRUE and the MySQL account that made them.
-- =====================================================================

USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

ALTER TABLE Item
    ADD COLUMN ModifiedByUserID INT NULL AFTER UpdatedAt,
    ADD CONSTRAINT FK_Item_ModifiedBy FOREIGN KEY (ModifiedByUserID) REFERENCES AppUser (UserID);

CREATE TABLE AuditLog (
    AuditLogID    BIGINT       NOT NULL AUTO_INCREMENT,
    EventTime     DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UserID        INT          NULL,
    Action        VARCHAR(30)  NOT NULL,
    TableName     VARCHAR(64)  NULL,
    RecordID      VARCHAR(64)  NULL,
    OldValue      JSON         NULL,
    NewValue      JSON         NULL,
    Detail        VARCHAR(500) NULL,
    DbAccount     VARCHAR(100) NOT NULL,
    IsDirectEdit  BOOLEAN      NOT NULL DEFAULT FALSE,
    CONSTRAINT PK_AuditLog        PRIMARY KEY (AuditLogID),
    CONSTRAINT FK_AuditLog_User   FOREIGN KEY (UserID) REFERENCES AppUser (UserID),
    CONSTRAINT CK_AuditLog_Action CHECK (Action IN ('Insert', 'Update', 'Delete', 'SetpointChange', 'TransactionDeleted'))
) ENGINE = InnoDB;

CREATE INDEX IX_AuditLog_EventTime ON AuditLog (EventTime);
CREATE INDEX IX_AuditLog_Direct    ON AuditLog (IsDirectEdit, EventTime);
CREATE INDEX IX_AuditLog_Record    ON AuditLog (TableName, RecordID);

DROP FUNCTION  IF EXISTS fn_sec_InAppContext;
DROP PROCEDURE IF EXISTS usp_sec_Log;

DELIMITER $$

CREATE FUNCTION fn_sec_InAppContext() RETURNS BOOLEAN
NOT DETERMINISTIC NO SQL
BEGIN
    RETURN @app_ctx IS NOT NULL;
END$$

CREATE PROCEDURE usp_sec_Log (
    IN p_UserID    INT,
    IN p_Action    VARCHAR(30),
    IN p_TableName VARCHAR(64),
    IN p_RecordID  VARCHAR(64),
    IN p_OldValue  JSON,
    IN p_NewValue  JSON,
    IN p_Detail    VARCHAR(500)
)
BEGIN
    INSERT INTO AuditLog (UserID, Action, TableName, RecordID, OldValue, NewValue, Detail, DbAccount, IsDirectEdit)
    VALUES (COALESCE(p_UserID, @app_user_id), p_Action, p_TableName, p_RecordID, p_OldValue, p_NewValue,
            LEFT(p_Detail, 500), LEFT(SESSION_USER(), 100), NOT fn_sec_InAppContext());
END$$

-- AuditLog is append-only
CREATE TRIGGER trg_sec_AuditLog_BlockUpdate BEFORE UPDATE ON AuditLog FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AuditLog is append-only; rows cannot be changed.';
END$$

CREATE TRIGGER trg_sec_AuditLog_BlockDelete BEFORE DELETE ON AuditLog FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AuditLog is append-only; rows cannot be deleted.';
END$$

-- Staff records are never deleted
CREATE TRIGGER trg_sec_AppUser_BlockDelete BEFORE DELETE ON AppUser FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Staff records cannot be deleted. Deactivate them instead.';
END$$

CREATE TRIGGER trg_sec_AppUser_AfterInsert AFTER INSERT ON AppUser FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'AppUser', NEW.UserID, NULL,
         JSON_OBJECT('Username', NEW.Username, 'FirstName', NEW.FirstName, 'LastName', NEW.LastName,
                     'Email', NEW.Email, 'UserType', NEW.UserType, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_AppUser_AfterUpdate AFTER UPDATE ON AppUser FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'AppUser', NEW.UserID,
         JSON_OBJECT('Username', OLD.Username, 'FirstName', OLD.FirstName, 'LastName', OLD.LastName,
                     'Email', OLD.Email, 'UserType', OLD.UserType, 'IsActive', OLD.IsActive),
         JSON_OBJECT('Username', NEW.Username, 'FirstName', NEW.FirstName, 'LastName', NEW.LastName,
                     'Email', NEW.Email, 'UserType', NEW.UserType, 'IsActive', NEW.IsActive), NULL);
END$$

-- Item: stamp who changed it
CREATE TRIGGER trg_sec_Item_BeforeInsert BEFORE INSERT ON Item FOR EACH ROW
BEGIN
    SET NEW.ModifiedByUserID = @app_user_id;
END$$

CREATE TRIGGER trg_sec_Item_BeforeUpdate BEFORE UPDATE ON Item FOR EACH ROW
BEGIN
    SET NEW.ModifiedByUserID = IF(fn_sec_InAppContext(), @app_user_id, NULL),
        NEW.UpdatedAt        = NOW();
END$$

CREATE TRIGGER trg_sec_Item_AfterInsert AFTER INSERT ON Item FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'Item', NEW.ItemID, NULL,
         JSON_OBJECT('ItemName', NEW.ItemName, 'CategoryID', NEW.CategoryID, 'UnitValue', NEW.UnitValue,
                     'Description', NEW.Description, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_Item_AfterUpdate AFTER UPDATE ON Item FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'Item', NEW.ItemID,
         JSON_OBJECT('ItemName', OLD.ItemName, 'CategoryID', OLD.CategoryID, 'UnitValue', OLD.UnitValue,
                     'Description', OLD.Description, 'IsActive', OLD.IsActive),
         JSON_OBJECT('ItemName', NEW.ItemName, 'CategoryID', NEW.CategoryID, 'UnitValue', NEW.UnitValue,
                     'Description', NEW.Description, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_Item_AfterDelete AFTER DELETE ON Item FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Delete', 'Item', OLD.ItemID,
         JSON_OBJECT('ItemName', OLD.ItemName, 'CategoryID', OLD.CategoryID, 'UnitValue', OLD.UnitValue,
                     'Description', OLD.Description, 'IsActive', OLD.IsActive), NULL, NULL);
END$$

CREATE TRIGGER trg_sec_ItemVariant_AfterInsert AFTER INSERT ON ItemVariant FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'ItemVariant', NEW.VariantID, NULL,
         JSON_OBJECT('ItemID', NEW.ItemID, 'Gender', NEW.Gender, 'SizeCode', NEW.SizeCode, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_ItemVariant_AfterUpdate AFTER UPDATE ON ItemVariant FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'ItemVariant', NEW.VariantID,
         JSON_OBJECT('ItemID', OLD.ItemID, 'Gender', OLD.Gender, 'SizeCode', OLD.SizeCode, 'IsActive', OLD.IsActive),
         JSON_OBJECT('ItemID', NEW.ItemID, 'Gender', NEW.Gender, 'SizeCode', NEW.SizeCode, 'IsActive', NEW.IsActive), NULL);
END$$

-- InventoryBalance: setpoint history; quantity edits outside a transaction are flagged
CREATE TRIGGER trg_sec_InventoryBalance_BeforeUpdate BEFORE UPDATE ON InventoryBalance FOR EACH ROW
BEGIN
    IF NOT (NEW.Setpoint <=> OLD.Setpoint) THEN
        SET NEW.SetpointUpdatedBy = IF(fn_sec_InAppContext(), @app_user_id, NULL),
            NEW.SetpointUpdatedAt = NOW();
    END IF;
END$$

CREATE TRIGGER trg_sec_InventoryBalance_AfterUpdate AFTER UPDATE ON InventoryBalance FOR EACH ROW
BEGIN
    IF NOT (NEW.Setpoint <=> OLD.Setpoint) THEN
        CALL usp_sec_Log(NULL, 'SetpointChange', 'InventoryBalance', NEW.VariantID,
             JSON_OBJECT('Setpoint', OLD.Setpoint, 'SetpointIsManual', OLD.SetpointIsManual),
             JSON_OBJECT('Setpoint', NEW.Setpoint, 'SetpointIsManual', NEW.SetpointIsManual), NULL);
    END IF;
    IF NOT fn_sec_InAppContext()
       AND NOT (NEW.CurrentQuantity <=> OLD.CurrentQuantity AND NEW.BaselineQuantity <=> OLD.BaselineQuantity) THEN
        CALL usp_sec_Log(NULL, 'Update', 'InventoryBalance', NEW.VariantID,
             JSON_OBJECT('CurrentQuantity', OLD.CurrentQuantity, 'BaselineQuantity', OLD.BaselineQuantity),
             JSON_OBJECT('CurrentQuantity', NEW.CurrentQuantity, 'BaselineQuantity', NEW.BaselineQuantity),
             'Quantity changed without a Stock In/Out transaction');
    END IF;
END$$

-- Alert configuration and recipients
CREATE TRIGGER trg_sec_AlertConfiguration_AfterInsert AFTER INSERT ON AlertConfiguration FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'AlertConfiguration', NEW.AlertConfigurationID, NULL,
         JSON_OBJECT('ConfigurationName', NEW.ConfigurationName, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_AlertRecipient_AfterInsert AFTER INSERT ON AlertRecipient FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'AlertRecipient', NEW.AlertRecipientID, NULL,
         JSON_OBJECT('Slot', NEW.RecipientSlot, 'Name', NEW.RecipientName, 'Email', NEW.Email), NULL);
END$$

CREATE TRIGGER trg_sec_AlertRecipient_AfterUpdate AFTER UPDATE ON AlertRecipient FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'AlertRecipient', NEW.AlertRecipientID,
         JSON_OBJECT('Slot', OLD.RecipientSlot, 'Name', OLD.RecipientName, 'Email', OLD.Email, 'IsActive', OLD.IsActive),
         JSON_OBJECT('Slot', NEW.RecipientSlot, 'Name', NEW.RecipientName, 'Email', NEW.Email, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_AlertRecipient_AfterDelete AFTER DELETE ON AlertRecipient FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Delete', 'AlertRecipient', OLD.AlertRecipientID,
         JSON_OBJECT('Slot', OLD.RecipientSlot, 'Name', OLD.RecipientName, 'Email', OLD.Email), NULL, NULL);
END$$

CREATE TRIGGER trg_sec_GiveawayCombination_AfterInsert AFTER INSERT ON GiveawayCombination FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'GiveawayCombination', NEW.CombinationID, NULL,
         JSON_OBJECT('CombinationName', NEW.CombinationName, 'Description', NEW.Description, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_GiveawayCombination_AfterUpdate AFTER UPDATE ON GiveawayCombination FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'GiveawayCombination', NEW.CombinationID,
         JSON_OBJECT('CombinationName', OLD.CombinationName, 'Description', OLD.Description, 'IsActive', OLD.IsActive),
         JSON_OBJECT('CombinationName', NEW.CombinationName, 'Description', NEW.Description, 'IsActive', NEW.IsActive), NULL);
END$$

-- Posted transactions are immutable except for soft delete
CREATE TRIGGER trg_sec_InventoryTransaction_BeforeUpdate BEFORE UPDATE ON InventoryTransaction FOR EACH ROW
BEGIN
    IF OLD.IsDeleted AND NOT NEW.IsDeleted THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A deleted transaction cannot be restored. Enter a new transaction instead.';
    END IF;
    IF OLD.IsDeleted AND NOT (NEW.DeletedAt <=> OLD.DeletedAt AND NEW.DeletedByUserID <=> OLD.DeletedByUserID
                              AND NEW.DeleteReason <=> OLD.DeleteReason) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delete details of a transaction cannot be changed.';
    END IF;
    IF NOT (NEW.TransactionDate <=> OLD.TransactionDate AND NEW.UserID <=> OLD.UserID
        AND NEW.TransactionType <=> OLD.TransactionType AND NEW.StockInReason <=> OLD.StockInReason
        AND NEW.DistributionCategoryID <=> OLD.DistributionCategoryID AND NEW.RecipientContextID <=> OLD.RecipientContextID
        AND NEW.EventPurposeID <=> OLD.EventPurposeID AND NEW.EventDetails <=> OLD.EventDetails
        AND NEW.RecipientName <=> OLD.RecipientName AND NEW.CombinationID <=> OLD.CombinationID
        AND NEW.Notes <=> OLD.Notes) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Posted transactions cannot be edited. Delete (with reversal) and re-enter.';
    END IF;
END$$

CREATE TRIGGER trg_sec_InventoryTransaction_AfterUpdate AFTER UPDATE ON InventoryTransaction FOR EACH ROW
BEGIN
    IF NEW.IsDeleted AND NOT OLD.IsDeleted THEN
        CALL usp_sec_Log(NEW.DeletedByUserID, 'TransactionDeleted', 'InventoryTransaction', NEW.TransactionID,
             JSON_OBJECT('IsDeleted', FALSE),
             JSON_OBJECT('IsDeleted', TRUE, 'DeletedAt', NEW.DeletedAt, 'DeletedByUserID', NEW.DeletedByUserID),
             NEW.DeleteReason);
    END IF;
END$$

CREATE TRIGGER trg_sec_InventoryTransaction_AfterInsert AFTER INSERT ON InventoryTransaction FOR EACH ROW
BEGIN
    IF NOT fn_sec_InAppContext() THEN
        CALL usp_sec_Log(NULL, 'Insert', 'InventoryTransaction', NEW.TransactionID, NULL,
             JSON_OBJECT('UserID', NEW.UserID, 'TransactionType', NEW.TransactionType, 'TransactionDate', NEW.TransactionDate),
             'Transaction inserted without usp_RecordTransaction');
    END IF;
END$$

CREATE TRIGGER trg_sec_TransactionLine_BlockUpdate BEFORE UPDATE ON TransactionLine FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Transaction lines cannot be edited. Delete the transaction (with reversal) and re-enter.';
END$$

CREATE TRIGGER trg_sec_TransactionLine_AfterInsert AFTER INSERT ON TransactionLine FOR EACH ROW
BEGIN
    IF NOT fn_sec_InAppContext() THEN
        CALL usp_sec_Log(NULL, 'Insert', 'TransactionLine', NEW.TransactionLineID, NULL,
             JSON_OBJECT('TransactionID', NEW.TransactionID, 'VariantID', NEW.VariantID, 'Quantity', NEW.Quantity),
             'Line inserted without usp_RecordTransaction');
    END IF;
END$$

-- Lookup tables have no app procedures, so every change is a direct edit
CREATE TRIGGER trg_sec_Category_AfterInsert AFTER INSERT ON Category FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'Category', NEW.CategoryID, NULL,
         JSON_OBJECT('CategoryName', NEW.CategoryName, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_Category_AfterUpdate AFTER UPDATE ON Category FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'Category', NEW.CategoryID,
         JSON_OBJECT('CategoryName', OLD.CategoryName, 'IsActive', OLD.IsActive),
         JSON_OBJECT('CategoryName', NEW.CategoryName, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_Category_AfterDelete AFTER DELETE ON Category FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Delete', 'Category', OLD.CategoryID,
         JSON_OBJECT('CategoryName', OLD.CategoryName, 'IsActive', OLD.IsActive), NULL, NULL);
END$$

CREATE TRIGGER trg_sec_DistributionCategory_AfterInsert AFTER INSERT ON DistributionCategory FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'DistributionCategory', NEW.DistributionCategoryID, NULL,
         JSON_OBJECT('CategoryName', NEW.CategoryName, 'IsGiveaway', NEW.IsGiveaway, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_DistributionCategory_AfterUpdate AFTER UPDATE ON DistributionCategory FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'DistributionCategory', NEW.DistributionCategoryID,
         JSON_OBJECT('CategoryName', OLD.CategoryName, 'IsGiveaway', OLD.IsGiveaway, 'IsActive', OLD.IsActive),
         JSON_OBJECT('CategoryName', NEW.CategoryName, 'IsGiveaway', NEW.IsGiveaway, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_DistributionCategory_AfterDelete AFTER DELETE ON DistributionCategory FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Delete', 'DistributionCategory', OLD.DistributionCategoryID,
         JSON_OBJECT('CategoryName', OLD.CategoryName, 'IsGiveaway', OLD.IsGiveaway), NULL, NULL);
END$$

CREATE TRIGGER trg_sec_RecipientContext_AfterInsert AFTER INSERT ON RecipientContext FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'RecipientContext', NEW.RecipientContextID, NULL,
         JSON_OBJECT('ContextName', NEW.ContextName, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_RecipientContext_AfterUpdate AFTER UPDATE ON RecipientContext FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'RecipientContext', NEW.RecipientContextID,
         JSON_OBJECT('ContextName', OLD.ContextName, 'IsActive', OLD.IsActive),
         JSON_OBJECT('ContextName', NEW.ContextName, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_RecipientContext_AfterDelete AFTER DELETE ON RecipientContext FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Delete', 'RecipientContext', OLD.RecipientContextID,
         JSON_OBJECT('ContextName', OLD.ContextName), NULL, NULL);
END$$

CREATE TRIGGER trg_sec_EventPurpose_AfterInsert AFTER INSERT ON EventPurpose FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'EventPurpose', NEW.EventPurposeID, NULL,
         JSON_OBJECT('PurposeName', NEW.PurposeName, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_EventPurpose_AfterUpdate AFTER UPDATE ON EventPurpose FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'EventPurpose', NEW.EventPurposeID,
         JSON_OBJECT('PurposeName', OLD.PurposeName, 'IsActive', OLD.IsActive),
         JSON_OBJECT('PurposeName', NEW.PurposeName, 'IsActive', NEW.IsActive), NULL);
END$$
CREATE TRIGGER trg_sec_EventPurpose_AfterDelete AFTER DELETE ON EventPurpose FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Delete', 'EventPurpose', OLD.EventPurposeID,
         JSON_OBJECT('PurposeName', OLD.PurposeName), NULL, NULL);
END$$

DELIMITER ;

-- Review views
CREATE OR REPLACE VIEW vw_Security_DeletedTransactions AS
SELECT ta.TransactionID, ta.AuditAt AS DeletedAt,
       CONCAT(du.FirstName, ' ', du.LastName) AS DeletedBy,
       t.TransactionDate                       AS OriginalDate,
       CONCAT(ou.FirstName, ' ', ou.LastName) AS OriginallySubmittedBy,
       IF(ta.TransactionType = 'IN', 'Stock In', 'Stock Out') AS TransactionTypeLabel,
       ta.LineCount, ta.TotalUnits, ta.Reason, ta.LineDetail
  FROM TransactionAudit ta
  JOIN AppUser du              ON du.UserID       = ta.AuditByUserID
  JOIN InventoryTransaction t  ON t.TransactionID = ta.TransactionID
  JOIN AppUser ou              ON ou.UserID       = t.UserID
 WHERE ta.AuditAction = 'Deleted';

CREATE OR REPLACE VIEW vw_Security_DirectEdits AS
SELECT AuditLogID, EventTime, DbAccount, Action, TableName, RecordID, OldValue, NewValue, Detail
  FROM AuditLog
 WHERE IsDirectEdit;

CREATE OR REPLACE VIEW vw_Security_ChangeLog AS
SELECT a.AuditLogID, a.EventTime, a.Action, a.TableName, a.RecordID,
       CONCAT(u.FirstName, ' ', u.LastName) AS ChangedBy,
       a.OldValue, a.NewValue, a.Detail, a.IsDirectEdit, a.DbAccount
  FROM AuditLog a
  LEFT JOIN AppUser u ON u.UserID = a.UserID;

CREATE OR REPLACE VIEW vw_Security_AccountReview AS
SELECT u.UserID, u.Username, CONCAT(u.FirstName, ' ', u.LastName) AS FullName, u.Email, u.UserType,
       u.IsActive, u.CreatedAt,
       (SELECT MAX(t.TransactionDate) FROM InventoryTransaction t WHERE t.UserID = u.UserID) AS LastTransactionAt,
       CASE WHEN NOT u.IsActive THEN 'Deactivated'
            WHEN NOT EXISTS (SELECT 1 FROM InventoryTransaction t WHERE t.UserID = u.UserID)
                 THEN 'No transactions yet - confirm still needed'
            WHEN (SELECT MAX(t.TransactionDate) FROM InventoryTransaction t WHERE t.UserID = u.UserID)
                 < NOW() - INTERVAL 60 DAY THEN 'No activity for 60+ days - confirm still needed'
            ELSE 'OK' END AS ReviewFlag
  FROM AppUser u
 WHERE NOT u.IsSystemAccount;

-- Should always be empty. Any row means data was changed outside the procedures.
CREATE OR REPLACE VIEW vw_Security_IntegrityExceptions AS
SELECT 'Transaction has no Created audit record' AS Issue, 'InventoryTransaction' AS TableName,
       t.TransactionID AS RecordID, CONCAT('Posted ', t.TransactionDate) AS Detail
  FROM InventoryTransaction t
 WHERE NOT EXISTS (SELECT 1 FROM TransactionAudit a
                    WHERE a.TransactionID = t.TransactionID AND a.AuditAction = 'Created')
UNION ALL
SELECT 'Deleted transaction has no Deleted audit record', 'InventoryTransaction',
       t.TransactionID, CONCAT('Deleted ', t.DeletedAt)
  FROM InventoryTransaction t
 WHERE t.IsDeleted
   AND NOT EXISTS (SELECT 1 FROM TransactionAudit a
                    WHERE a.TransactionID = t.TransactionID AND a.AuditAction = 'Deleted')
UNION ALL
SELECT 'Transaction has no item lines', 'InventoryTransaction', t.TransactionID, NULL
  FROM InventoryTransaction t
 WHERE NOT EXISTS (SELECT 1 FROM TransactionLine tl WHERE tl.TransactionID = t.TransactionID)
UNION ALL
SELECT 'Balance does not match transaction history', 'InventoryBalance', b.VariantID,
       CONCAT('Current ', b.CurrentQuantity, ' vs expected ', COALESCE(x.Expected, 0))
  FROM InventoryBalance b
  LEFT JOIN (SELECT tl.VariantID,
                    SUM(IF(t.TransactionType = 'IN', tl.Quantity, -tl.Quantity)) AS Expected
               FROM TransactionLine tl
               JOIN InventoryTransaction t ON t.TransactionID = tl.TransactionID
              WHERE NOT t.IsDeleted
              GROUP BY tl.VariantID) x ON x.VariantID = b.VariantID
 WHERE b.CurrentQuantity <> COALESCE(x.Expected, 0);

DROP PROCEDURE IF EXISTS usp_Security_WeeklyReview;

DELIMITER $$

-- CALL usp_Security_WeeklyReview(7);
CREATE PROCEDURE usp_Security_WeeklyReview (
    IN p_Days INT
)
BEGIN
    DECLARE v_from DATETIME DEFAULT NOW() - INTERVAL COALESCE(p_Days, 7) DAY;

    SELECT v_from AS ReviewFrom, NOW() AS ReviewTo,
           (SELECT COUNT(*) FROM TransactionAudit WHERE AuditAction = 'Deleted' AND AuditAt >= v_from) AS DeletedTransactions,
           (SELECT COUNT(*) FROM AuditLog WHERE IsDirectEdit AND EventTime >= v_from)                AS DirectEdits,
           (SELECT COUNT(*) FROM AuditLog WHERE TableName IN ('AppUser', 'AlertRecipient')
                                            AND EventTime >= v_from)                                 AS StaffOrAlertChanges,
           (SELECT COUNT(*) FROM vw_Security_IntegrityExceptions)                                    AS IntegrityExceptions,
           (SELECT COUNT(*) FROM vw_Security_AccountReview WHERE ReviewFlag NOT IN ('OK', 'Deactivated')) AS AccountsToReview;

    SELECT * FROM vw_Security_DeletedTransactions WHERE DeletedAt >= v_from ORDER BY DeletedAt DESC;
    SELECT * FROM vw_Security_DirectEdits WHERE EventTime >= v_from ORDER BY EventTime DESC;
    SELECT * FROM vw_Security_ChangeLog
     WHERE TableName IN ('AppUser', 'AlertRecipient') AND EventTime >= v_from ORDER BY EventTime DESC;
    SELECT * FROM vw_Security_AccountReview WHERE ReviewFlag NOT IN ('OK', 'Deactivated') ORDER BY ReviewFlag, Username;
    SELECT * FROM vw_Security_IntegrityExceptions;
END$$

DELIMITER ;

SELECT 'Part 6 complete: security and audit objects created.' AS Status;
