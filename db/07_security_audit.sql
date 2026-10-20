/* =====================================================================
   PART 7 : SECURITY & AUDIT  (WBS 4.9 Security & Audit Design Spec)
   Run AFTER Parts 1-6.  Platform: MySQL 8.0.16+
   ---------------------------------------------------------------------
   Spec section -> what this part builds
   §1 Users identified on every transaction
        - AppUser: bcrypt PasswordHash (CHECK rejects anything that is not
          a bcrypt hash, so plain-text passwords cannot be stored),
          lockout + approval + deactivation columns
        - AuditLog: append-only history (UserID, EventTime, Action,
          TableName, RecordID, OldValue, NewValue)
        - Audit triggers stamp/attribute every change to the user that
          the stored procedure passed in (@app_user_id)
        - Item.ModifiedByUserID / ModifiedAt (= UpdatedAt) stamped by trigger
   §2 Uniform access (no tiers): every active AppUser may call every
        procedure; accountability comes from the stamping above.
   §3 Risk #5 unauthorized access
        - sign-in: 5 failed attempts -> 15 min lock; 15 min idle timeout
        - every sign-in / failure / lock / timeout logged
        - direct table edits made OUTSIDE the stored procedures are
          flagged (AuditLog.IsDirectEdit = TRUE)
        - integrity checks: unaudited transactions, balance drift
        - weekly review procedure + account review view
   §4 Credentials not in source: no passwords anywhere in this file.
        DB accounts/grants: 08_db_roles_grants.sql + scripts/.
   ---------------------------------------------------------------------
   HOW THE AUDIT CONTEXT WORKS
     Every write procedure does   SET @app_user_id = p_UserID   while it
     runs and restores it when it finishes or fails. Triggers read it:
       @app_user_id set      -> change made by that user through the app
       @app_user_id NULL     -> change made by someone typing SQL directly
                                (logged with IsDirectEdit = TRUE + DbAccount)
     Sign-in procedures use @sec_system_ctx instead (no user yet).
   ===================================================================== */
USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

/* =====================================================================
   1. TABLE CHANGES
   ===================================================================== */
ALTER TABLE AppUser
    ADD COLUMN PasswordHash        CHAR(60)         NULL AFTER Email,   -- bcrypt only (app hashes; DB never sees plain text)
    ADD COLUMN MustChangePassword  BOOLEAN          NOT NULL DEFAULT TRUE,
    ADD COLUMN PasswordChangedAt   DATETIME         NULL,
    ADD COLUMN FailedLoginCount    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN LockedUntil         DATETIME         NULL,
    ADD COLUMN LastLoginAt         DATETIME         NULL,
    ADD COLUMN ApprovedByUserID    INT              NULL,               -- supervisor who approved the account
    ADD COLUMN DeactivatedAt       DATETIME         NULL,
    ADD COLUMN DeactivatedByUserID INT              NULL,
    ADD COLUMN DeactivationReason  VARCHAR(255)     NULL,
    ADD CONSTRAINT FK_AppUser_ApprovedBy    FOREIGN KEY (ApprovedByUserID)    REFERENCES AppUser (UserID),
    ADD CONSTRAINT FK_AppUser_DeactivatedBy FOREIGN KEY (DeactivatedByUserID) REFERENCES AppUser (UserID),
    -- bcrypt format, cost 10-31: rejects plain text, MD5/SHA hashes, weak cost factors
    ADD CONSTRAINT CK_AppUser_PasswordHash  CHECK (PasswordHash IS NULL OR
        REGEXP_LIKE(PasswordHash, '^\\$2[aby]\\$(1[0-9]|2[0-9]|3[01])\\$[./A-Za-z0-9]{53}$', 'c'));

-- Spec: Item.ModifiedByUserID + ModifiedAt  (ModifiedAt = existing UpdatedAt column)
ALTER TABLE Item
    ADD COLUMN ModifiedByUserID INT NULL AFTER UpdatedAt,
    ADD CONSTRAINT FK_Item_ModifiedBy FOREIGN KEY (ModifiedByUserID) REFERENCES AppUser (UserID);

/* Spec mapping (no rename, so Parts 2-4 keep working):
     InventoryTransaction.CreatedByUserID  = InventoryTransaction.UserID (NOT NULL, FK)
     InventoryTransaction.CreatedAt        = InventoryTransaction.TransactionDate
     AlertConfiguration.ModifiedByUserID   = AlertConfiguration.UpdatedByUserID
     AlertConfiguration.ModifiedAt         = AlertConfiguration.UpdatedAt            */

CREATE TABLE AuditLog (
    AuditLogID    BIGINT       NOT NULL AUTO_INCREMENT,
    EventTime     DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    UserID        INT          NULL,              -- NULL = unknown user (failed sign-in) or direct SQL edit
    Action        VARCHAR(30)  NOT NULL,
    TableName     VARCHAR(64)  NULL,
    RecordID      VARCHAR(64)  NULL,
    OldValue      JSON         NULL,
    NewValue      JSON         NULL,
    Detail        VARCHAR(500) NULL,
    DbAccount     VARCHAR(100) NOT NULL,          -- MySQL login that made the change
    IsDirectEdit  BOOLEAN      NOT NULL DEFAULT FALSE,
    CONSTRAINT PK_AuditLog        PRIMARY KEY (AuditLogID),
    CONSTRAINT FK_AuditLog_User   FOREIGN KEY (UserID) REFERENCES AppUser (UserID),
    CONSTRAINT CK_AuditLog_Action CHECK (Action IN (
        'Insert', 'Update', 'Delete', 'SetpointChange', 'TransactionDeleted',
        'LoginSuccess', 'LoginFailed', 'LoginBlocked', 'AccountLocked', 'AccountUnlocked',
        'Logout', 'SessionTimeout', 'PasswordChanged'))
) ENGINE = InnoDB;

CREATE INDEX IX_AuditLog_EventTime ON AuditLog (EventTime);
CREATE INDEX IX_AuditLog_Action    ON AuditLog (Action, EventTime);
CREATE INDEX IX_AuditLog_Direct    ON AuditLog (IsDirectEdit, EventTime);
CREATE INDEX IX_AuditLog_Record    ON AuditLog (TableName, RecordID);

CREATE TABLE AppSession (
    SessionID      BIGINT       NOT NULL AUTO_INCREMENT,
    TokenHash      CHAR(64)     NOT NULL,         -- SHA-256 of the token; the token itself is never stored
    UserID         INT          NOT NULL,
    ClientInfo     VARCHAR(255) NULL,
    CreatedAt      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    LastActivityAt DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    EndedAt        DATETIME     NULL,
    EndReason      VARCHAR(20)  NULL,
    CONSTRAINT PK_AppSession        PRIMARY KEY (SessionID),
    CONSTRAINT UQ_AppSession_Token  UNIQUE (TokenHash),
    CONSTRAINT FK_AppSession_User   FOREIGN KEY (UserID) REFERENCES AppUser (UserID),
    CONSTRAINT CK_AppSession_Reason CHECK (EndReason IS NULL OR
        EndReason IN ('Logout', 'IdleTimeout', 'UserDeactivated', 'PasswordReset'))
) ENGINE = InnoDB;

CREATE INDEX IX_AppSession_Open ON AppSession (UserID, EndedAt, LastActivityAt);

/* =====================================================================
   2. HELPERS
   ===================================================================== */
DROP FUNCTION  IF EXISTS fn_sec_InAppContext;
DROP FUNCTION  IF EXISTS fn_sec_IsBcryptHash;
DROP PROCEDURE IF EXISTS usp_sec_Log;

DELIMITER $$

-- TRUE when the current statement is running inside an app stored procedure
CREATE FUNCTION fn_sec_InAppContext() RETURNS BOOLEAN
NOT DETERMINISTIC NO SQL
BEGIN
    RETURN (@app_user_id IS NOT NULL OR @sec_system_ctx IS NOT NULL);
END$$

CREATE FUNCTION fn_sec_IsBcryptHash(p_Hash VARCHAR(255)) RETURNS BOOLEAN
DETERMINISTIC NO SQL
BEGIN
    RETURN p_Hash IS NOT NULL
       AND REGEXP_LIKE(p_Hash, '^\\$2[aby]\\$(1[0-9]|2[0-9]|3[01])\\$[./A-Za-z0-9]{53}$', 'c');
END$$

-- Single write path into AuditLog (triggers and procedures call this)
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

DELIMITER ;

/* =====================================================================
   3. TRIGGERS
   ===================================================================== */
DELIMITER $$

/* ---------- AuditLog: append-only ---------- */
CREATE TRIGGER trg_sec_AuditLog_BlockUpdate BEFORE UPDATE ON AuditLog FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AuditLog is append-only; rows cannot be changed.';
END$$

CREATE TRIGGER trg_sec_AuditLog_BlockDelete BEFORE DELETE ON AuditLog FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'AuditLog is append-only; rows cannot be deleted.';
END$$

/* ---------- AppUser ---------- */
CREATE TRIGGER trg_sec_AppUser_BlockDelete BEFORE DELETE ON AppUser FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Users cannot be deleted (history must stay traceable). Use usp_User_Deactivate.';
END$$

CREATE TRIGGER trg_sec_AppUser_AfterInsert AFTER INSERT ON AppUser FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'AppUser', NEW.UserID, NULL,
         JSON_OBJECT('Username', NEW.Username, 'FirstName', NEW.FirstName, 'LastName', NEW.LastName,
                     'Email', NEW.Email, 'UserType', NEW.UserType, 'IsActive', NEW.IsActive,
                     'ApprovedByUserID', NEW.ApprovedByUserID, 'HasPassword', NEW.PasswordHash IS NOT NULL),
         NULL);
END$$

CREATE TRIGGER trg_sec_AppUser_AfterUpdate AFTER UPDATE ON AppUser FOR EACH ROW
BEGIN
    -- identity / access changes
    IF NOT (NEW.Username <=> OLD.Username AND NEW.FirstName <=> OLD.FirstName AND NEW.LastName <=> OLD.LastName
        AND NEW.Email <=> OLD.Email AND NEW.UserType <=> OLD.UserType AND NEW.IsActive <=> OLD.IsActive) THEN
        CALL usp_sec_Log(NULL, 'Update', 'AppUser', NEW.UserID,
             JSON_OBJECT('Username', OLD.Username, 'FirstName', OLD.FirstName, 'LastName', OLD.LastName,
                         'Email', OLD.Email, 'UserType', OLD.UserType, 'IsActive', OLD.IsActive),
             JSON_OBJECT('Username', NEW.Username, 'FirstName', NEW.FirstName, 'LastName', NEW.LastName,
                         'Email', NEW.Email, 'UserType', NEW.UserType, 'IsActive', NEW.IsActive,
                         'DeactivationReason', NEW.DeactivationReason),
             NULL);
    END IF;
    -- password changes: logged, but the hash itself is NEVER written to the log
    IF NOT (NEW.PasswordHash <=> OLD.PasswordHash) THEN
        CALL usp_sec_Log(NULL, 'PasswordChanged', 'AppUser', NEW.UserID, NULL, NULL,
             IF(@app_user_id <=> NEW.UserID, 'Changed by the user', 'Set/reset by another user or outside the app'));
    END IF;
    -- lockout fields changed outside the sign-in procedures (e.g. someone unlocking by hand)
    IF NOT fn_sec_InAppContext()
       AND NOT (NEW.FailedLoginCount <=> OLD.FailedLoginCount AND NEW.LockedUntil <=> OLD.LockedUntil) THEN
        CALL usp_sec_Log(NULL, 'Update', 'AppUser', NEW.UserID,
             JSON_OBJECT('FailedLoginCount', OLD.FailedLoginCount, 'LockedUntil', OLD.LockedUntil),
             JSON_OBJECT('FailedLoginCount', NEW.FailedLoginCount, 'LockedUntil', NEW.LockedUntil),
             'Lockout fields changed outside the sign-in procedures');
    END IF;
END$$

/* ---------- Item: stamp ModifiedByUserID / ModifiedAt, log every change ---------- */
CREATE TRIGGER trg_sec_Item_BeforeInsert BEFORE INSERT ON Item FOR EACH ROW
BEGIN
    SET NEW.ModifiedByUserID = @app_user_id;
END$$

CREATE TRIGGER trg_sec_Item_BeforeUpdate BEFORE UPDATE ON Item FOR EACH ROW
BEGIN
    SET NEW.ModifiedByUserID = @app_user_id,   -- NULL for direct SQL edits (and flagged below)
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

/* ---------- ItemVariant ---------- */
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

/* ---------- InventoryBalance: setpoint history + quantity edits outside procedures ---------- */
CREATE TRIGGER trg_sec_InventoryBalance_BeforeUpdate BEFORE UPDATE ON InventoryBalance FOR EACH ROW
BEGIN
    IF NOT (NEW.Setpoint <=> OLD.Setpoint) THEN
        SET NEW.SetpointUpdatedBy = @app_user_id,   -- never credit a direct edit to the last app user
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
    -- quantities may only move through transactions (already audited in TransactionAudit)
    IF NOT fn_sec_InAppContext()
       AND NOT (NEW.CurrentQuantity <=> OLD.CurrentQuantity AND NEW.BaselineQuantity <=> OLD.BaselineQuantity) THEN
        CALL usp_sec_Log(NULL, 'Update', 'InventoryBalance', NEW.VariantID,
             JSON_OBJECT('CurrentQuantity', OLD.CurrentQuantity, 'BaselineQuantity', OLD.BaselineQuantity),
             JSON_OBJECT('CurrentQuantity', NEW.CurrentQuantity, 'BaselineQuantity', NEW.BaselineQuantity),
             'Quantity changed without a Stock In/Out transaction');
    END IF;
END$$

/* ---------- AlertConfiguration / AlertRecipient (who changed the alert emails) ---------- */
CREATE TRIGGER trg_sec_AlertConfiguration_AfterInsert AFTER INSERT ON AlertConfiguration FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'AlertConfiguration', NEW.AlertConfigurationID, NULL,
         JSON_OBJECT('ConfigurationName', NEW.ConfigurationName, 'IsActive', NEW.IsActive), NULL);
END$$

CREATE TRIGGER trg_sec_AlertConfiguration_AfterUpdate AFTER UPDATE ON AlertConfiguration FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Update', 'AlertConfiguration', NEW.AlertConfigurationID,
         JSON_OBJECT('ConfigurationName', OLD.ConfigurationName, 'IsActive', OLD.IsActive, 'UpdatedByUserID', OLD.UpdatedByUserID),
         JSON_OBJECT('ConfigurationName', NEW.ConfigurationName, 'IsActive', NEW.IsActive, 'UpdatedByUserID', NEW.UpdatedByUserID), NULL);
END$$

CREATE TRIGGER trg_sec_AlertRecipient_AfterInsert AFTER INSERT ON AlertRecipient FOR EACH ROW
BEGIN
    CALL usp_sec_Log(NULL, 'Insert', 'AlertRecipient', NEW.AlertRecipientID, NULL,
         JSON_OBJECT('AlertConfigurationID', NEW.AlertConfigurationID, 'Slot', NEW.RecipientSlot,
                     'Name', NEW.RecipientName, 'Email', NEW.Email, 'IsActive', NEW.IsActive), NULL);
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
         JSON_OBJECT('AlertConfigurationID', OLD.AlertConfigurationID, 'Slot', OLD.RecipientSlot,
                     'Name', OLD.RecipientName, 'Email', OLD.Email), NULL, NULL);
END$$

/* ---------- GiveawayCombination ---------- */
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

/* ---------- InventoryTransaction: posted records are immutable except soft delete ---------- */
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
    -- normal inserts are audited by TransactionAudit; only flag inserts made outside the procedures
    IF NOT fn_sec_InAppContext() THEN
        CALL usp_sec_Log(NULL, 'Insert', 'InventoryTransaction', NEW.TransactionID, NULL,
             JSON_OBJECT('UserID', NEW.UserID, 'TransactionType', NEW.TransactionType, 'TransactionDate', NEW.TransactionDate),
             'Transaction inserted without usp_RecordTransaction');
    END IF;
END$$

/* ---------- TransactionLine: immutable ---------- */
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

/* ---------- Lookup tables (no app procedures exist, so every change is a direct edit) ---------- */
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

/* =====================================================================
   4. SIGN-IN, LOCKOUT AND SESSION PROCEDURES  (spec §1, §3)
   Flow for the app:
     1) CALL usp_Auth_GetCredentials(username)        -> PasswordHash
     2) app checks the typed password with bcrypt.compare()
        (if no user came back, compare against a dummy hash anyway so
         response time doesn't reveal whether the username exists)
     3) CALL usp_Auth_RecordLoginAttempt(username, passwordOk, clientInfo,
                                         @outcome, @userId, @token)
        outcome: 'OK' | 'Failed' | 'Locked'
        Show ONE generic message for Failed ("Username or password is
        incorrect"). Store @token in the session cookie.
     4) Every request: CALL usp_Auth_ValidateSession(token, @userId, @status)
        status: 'OK' | 'Expired' | 'Invalid'. Pass @userId to every
        procedure. The user never types their own ID.
     5) Sign-out: CALL usp_Auth_Logout(token)
   Policy (spec §3): 5 failed attempts -> locked 15 minutes;
                     15 minutes idle -> session ends.
   ===================================================================== */
DROP PROCEDURE IF EXISTS usp_Auth_GetCredentials;
DROP PROCEDURE IF EXISTS usp_Auth_RecordLoginAttempt;
DROP PROCEDURE IF EXISTS usp_Auth_ValidateSession;
DROP PROCEDURE IF EXISTS usp_Auth_Logout;
DROP PROCEDURE IF EXISTS usp_Auth_EndIdleSessions;

DELIMITER $$

CREATE PROCEDURE usp_Auth_GetCredentials (
    IN p_Username VARCHAR(50)
)
BEGIN
    SELECT UserID, Username, PasswordHash, IsActive,
           COALESCE(LockedUntil > NOW(), FALSE) AS IsLocked,
           MustChangePassword
      FROM AppUser
     WHERE Username = TRIM(p_Username);
END$$

CREATE PROCEDURE usp_Auth_RecordLoginAttempt (
    IN  p_Username     VARCHAR(50),
    IN  p_PasswordOk   BOOLEAN,          -- result of bcrypt.compare() in the app
    IN  p_ClientInfo   VARCHAR(255),     -- e.g. PC name / IP
    OUT p_Outcome      VARCHAR(10),      -- OK | Failed | Locked
    OUT p_UserID       INT,              -- set only when OK
    OUT p_SessionToken CHAR(64)          -- set only when OK; store in the session cookie
)
BEGIN
    DECLARE c_MaxFailures  INT DEFAULT 5;    -- spec §3
    DECLARE c_LockMinutes  INT DEFAULT 15;   -- spec §3
    DECLARE v_uid          INT;
    DECLARE v_active       BOOLEAN;
    DECLARE v_locked_until DATETIME;
    DECLARE v_fails        INT;
    DECLARE v_token        CHAR(64);
    DECLARE v_client       VARCHAR(255) DEFAULT LEFT(COALESCE(p_ClientInfo, 'unknown client'), 200);
    DECLARE v_prev_sys     INT DEFAULT @sec_system_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @sec_system_ctx = v_prev_sys;
        RESIGNAL;
    END;

    SET @sec_system_ctx = 1;
    SET p_Outcome = 'Failed', p_UserID = NULL, p_SessionToken = NULL;

    START TRANSACTION;
    SELECT UserID, IsActive, LockedUntil, FailedLoginCount
      INTO v_uid, v_active, v_locked_until, v_fails
      FROM AppUser WHERE Username = TRIM(p_Username)
       FOR UPDATE;

    IF v_uid IS NULL THEN
        CALL usp_sec_Log(NULL, 'LoginFailed', 'AppUser', NULL, NULL, NULL,
             CONCAT('Unknown username "', LEFT(COALESCE(p_Username, ''), 50), '" from ', v_client));

    ELSEIF NOT v_active THEN
        CALL usp_sec_Log(v_uid, 'LoginFailed', 'AppUser', v_uid, NULL, NULL,
             CONCAT('Deactivated account from ', v_client));

    ELSEIF v_locked_until > NOW() THEN
        SET p_Outcome = 'Locked';
        CALL usp_sec_Log(v_uid, 'LoginBlocked', 'AppUser', v_uid, NULL, NULL,
             CONCAT('Account locked until ', v_locked_until, '; attempt from ', v_client));

    ELSEIF COALESCE(p_PasswordOk, FALSE) THEN
        UPDATE AppUser SET FailedLoginCount = 0, LockedUntil = NULL, LastLoginAt = NOW()
         WHERE UserID = v_uid;
        SET v_token = LOWER(HEX(RANDOM_BYTES(32)));                   -- 256-bit random token
        INSERT INTO AppSession (TokenHash, UserID, ClientInfo)
        VALUES (SHA2(v_token, 256), v_uid, v_client);
        SET p_Outcome = 'OK', p_UserID = v_uid, p_SessionToken = v_token;
        CALL usp_sec_Log(v_uid, 'LoginSuccess', 'AppUser', v_uid, NULL, NULL, CONCAT('From ', v_client));

    ELSE
        SET v_fails = v_fails + 1;
        CALL usp_sec_Log(v_uid, 'LoginFailed', 'AppUser', v_uid, NULL, NULL,
             CONCAT('Wrong password (attempt ', v_fails, ' of ', c_MaxFailures, ') from ', v_client));
        IF v_fails >= c_MaxFailures THEN
            UPDATE AppUser SET FailedLoginCount = 0,
                               LockedUntil = NOW() + INTERVAL c_LockMinutes MINUTE
             WHERE UserID = v_uid;
            SET p_Outcome = 'Locked';
            CALL usp_sec_Log(v_uid, 'AccountLocked', 'AppUser', v_uid, NULL, NULL,
                 CONCAT(c_MaxFailures, ' failed sign-ins; locked for ', c_LockMinutes, ' minutes'));
        ELSE
            UPDATE AppUser SET FailedLoginCount = v_fails WHERE UserID = v_uid;
        END IF;
    END IF;

    COMMIT;
    SET @sec_system_ctx = v_prev_sys;
END$$

CREATE PROCEDURE usp_Auth_ValidateSession (
    IN  p_SessionToken CHAR(64),
    OUT p_UserID       INT,              -- NULL unless status = OK (every write procedure rejects NULL)
    OUT p_Status       VARCHAR(10)       -- OK | Expired | Invalid
)
BEGIN
    DECLARE c_IdleMinutes INT DEFAULT 15;    -- spec §1/§3
    DECLARE v_sid    BIGINT;
    DECLARE v_uid    INT;
    DECLARE v_last   DATETIME;
    DECLARE v_ended  DATETIME;
    DECLARE v_active BOOLEAN;
    DECLARE v_prev_sys INT DEFAULT @sec_system_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET @sec_system_ctx = v_prev_sys;
        RESIGNAL;
    END;

    SET @sec_system_ctx = 1;
    SET p_UserID = NULL, p_Status = 'Invalid';

    START TRANSACTION;
    SELECT s.SessionID, s.UserID, s.LastActivityAt, s.EndedAt, u.IsActive
      INTO v_sid, v_uid, v_last, v_ended, v_active
      FROM AppSession s JOIN AppUser u ON u.UserID = s.UserID
     WHERE s.TokenHash = SHA2(COALESCE(p_SessionToken, ''), 256)
       FOR UPDATE;

    IF v_sid IS NULL OR v_ended IS NOT NULL THEN
        SET p_Status = 'Invalid';
    ELSEIF NOT v_active THEN
        UPDATE AppSession SET EndedAt = NOW(), EndReason = 'UserDeactivated' WHERE SessionID = v_sid;
        SET p_Status = 'Invalid';
    ELSEIF v_last < NOW() - INTERVAL c_IdleMinutes MINUTE THEN
        UPDATE AppSession SET EndedAt = NOW(), EndReason = 'IdleTimeout' WHERE SessionID = v_sid;
        CALL usp_sec_Log(v_uid, 'SessionTimeout', 'AppSession', v_sid, NULL, NULL,
             CONCAT('Idle since ', v_last));
        SET p_Status = 'Expired';
    ELSE
        UPDATE AppSession SET LastActivityAt = NOW() WHERE SessionID = v_sid;
        SET p_UserID = v_uid, p_Status = 'OK';
    END IF;

    COMMIT;
    SET @sec_system_ctx = v_prev_sys;
END$$

CREATE PROCEDURE usp_Auth_Logout (
    IN p_SessionToken CHAR(64)
)
BEGIN
    DECLARE v_sid BIGINT;
    DECLARE v_uid INT;
    DECLARE v_prev_sys INT DEFAULT @sec_system_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @sec_system_ctx = v_prev_sys; RESIGNAL; END;
    SET @sec_system_ctx = 1;

    SELECT SessionID, UserID INTO v_sid, v_uid
      FROM AppSession
     WHERE TokenHash = SHA2(COALESCE(p_SessionToken, ''), 256) AND EndedAt IS NULL;

    IF v_sid IS NOT NULL THEN
        UPDATE AppSession SET EndedAt = NOW(), EndReason = 'Logout' WHERE SessionID = v_sid;
        CALL usp_sec_Log(v_uid, 'Logout', 'AppSession', v_sid, NULL, NULL, NULL);
    END IF;
    SET @sec_system_ctx = v_prev_sys;
END$$

-- Housekeeping: close idle sessions in bulk (optional event every 5 minutes, see bottom)
CREATE PROCEDURE usp_Auth_EndIdleSessions ()
BEGIN
    DECLARE v_prev_sys INT DEFAULT @sec_system_ctx;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @sec_system_ctx = v_prev_sys; RESIGNAL; END;
    SET @sec_system_ctx = 1;

    INSERT INTO AuditLog (UserID, Action, TableName, RecordID, Detail, DbAccount, IsDirectEdit)
    SELECT UserID, 'SessionTimeout', 'AppSession', SessionID, CONCAT('Idle since ', LastActivityAt),
           LEFT(SESSION_USER(), 100), FALSE
      FROM AppSession
     WHERE EndedAt IS NULL AND LastActivityAt < NOW() - INTERVAL 15 MINUTE;

    UPDATE AppSession SET EndedAt = NOW(), EndReason = 'IdleTimeout'
     WHERE EndedAt IS NULL AND LastActivityAt < NOW() - INTERVAL 15 MINUTE;

    SET @sec_system_ctx = v_prev_sys;
END$$

DELIMITER ;

/* =====================================================================
   5. ACCOUNT MANAGEMENT  (spec §3 people process)
   - New accounts: approved by the GCR supervisor; the approving user is
     recorded in ApprovedByUserID. The account starts with a temporary
     password (bcrypt hash) and MustChangePassword = TRUE.
   - Departing students/interns: usp_User_Deactivate within 1 business
     day; ends their open sessions immediately. Users are never deleted.
   ===================================================================== */
DROP PROCEDURE IF EXISTS usp_User_Create;
DROP PROCEDURE IF EXISTS usp_User_Deactivate;
DROP PROCEDURE IF EXISTS usp_User_Reactivate;
DROP PROCEDURE IF EXISTS usp_User_SetPassword;
DROP PROCEDURE IF EXISTS usp_User_Unlock;

DELIMITER $$

CREATE PROCEDURE usp_User_Create (
    IN  p_ApprovedByUserID INT,          -- signed-in supervisor approving the account
    IN  p_Username         VARCHAR(50),  -- CougarNet ID
    IN  p_FirstName        VARCHAR(50),
    IN  p_LastName         VARCHAR(50),
    IN  p_Email            VARCHAR(254),
    IN  p_UserType         VARCHAR(30),
    IN  p_TempPasswordHash CHAR(60),     -- bcrypt hash produced by the app
    OUT p_NewUserID        INT
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_ApprovedByUserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_ApprovedByUserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Account creation rejected: approver is not an active authorized user.';
    END IF;
    IF NOT fn_sec_IsBcryptHash(p_TempPasswordHash) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Password must be supplied as a bcrypt hash (cost 10+), never as plain text.';
    END IF;

    INSERT INTO AppUser (Username, FirstName, LastName, Email, UserType, PasswordHash,
                         MustChangePassword, PasswordChangedAt, ApprovedByUserID)
    VALUES (TRIM(p_Username), TRIM(p_FirstName), TRIM(p_LastName), TRIM(p_Email), p_UserType,
            p_TempPasswordHash, TRUE, NOW(), p_ApprovedByUserID);
    SET p_NewUserID = LAST_INSERT_ID();

    SET @app_user_id = v_prev_ctx;
END$$

CREATE PROCEDURE usp_User_Deactivate (
    IN p_ActorUserID  INT,
    IN p_TargetUserID INT,
    IN p_Reason       VARCHAR(255)
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_ActorUserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_ActorUserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rejected: user is not an active authorized user.';
    END IF;
    IF p_ActorUserID = p_TargetUserID THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You cannot deactivate your own account.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_TargetUserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Target account does not exist or is already inactive.';
    END IF;
    IF CHAR_LENGTH(TRIM(COALESCE(p_Reason, ''))) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A reason is required (e.g. "Internship ended").';
    END IF;

    START TRANSACTION;
    UPDATE AppUser
       SET IsActive = FALSE, DeactivatedAt = NOW(), DeactivatedByUserID = p_ActorUserID,
           DeactivationReason = TRIM(p_Reason)
     WHERE UserID = p_TargetUserID;
    UPDATE AppSession SET EndedAt = NOW(), EndReason = 'UserDeactivated'
     WHERE UserID = p_TargetUserID AND EndedAt IS NULL;
    COMMIT;

    SET @app_user_id = v_prev_ctx;
END$$

CREATE PROCEDURE usp_User_Reactivate (
    IN p_ActorUserID  INT,
    IN p_TargetUserID INT
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_ActorUserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_ActorUserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rejected: user is not an active authorized user.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_TargetUserID AND NOT IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Target account does not exist or is already active.';
    END IF;

    UPDATE AppUser
       SET IsActive = TRUE, DeactivatedAt = NULL, DeactivatedByUserID = NULL, DeactivationReason = NULL,
           ApprovedByUserID = p_ActorUserID, MustChangePassword = TRUE
     WHERE UserID = p_TargetUserID;

    SET @app_user_id = v_prev_ctx;
END$$

-- Own change: MustChangePassword -> FALSE.  Reset for someone else: -> TRUE and their sessions end.
CREATE PROCEDURE usp_User_SetPassword (
    IN p_ActorUserID     INT,
    IN p_TargetUserID    INT,
    IN p_NewPasswordHash CHAR(60)
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_ActorUserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_ActorUserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rejected: user is not an active authorized user.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_TargetUserID) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Target account does not exist.';
    END IF;
    IF NOT fn_sec_IsBcryptHash(p_NewPasswordHash) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Password must be supplied as a bcrypt hash (cost 10+), never as plain text.';
    END IF;

    START TRANSACTION;
    UPDATE AppUser
       SET PasswordHash = p_NewPasswordHash, PasswordChangedAt = NOW(),
           MustChangePassword = (p_ActorUserID <> p_TargetUserID)
     WHERE UserID = p_TargetUserID;
    IF p_ActorUserID <> p_TargetUserID THEN
        UPDATE AppSession SET EndedAt = NOW(), EndReason = 'PasswordReset'
         WHERE UserID = p_TargetUserID AND EndedAt IS NULL;
    END IF;
    COMMIT;

    SET @app_user_id = v_prev_ctx;
END$$

CREATE PROCEDURE usp_User_Unlock (
    IN p_ActorUserID  INT,
    IN p_TargetUserID INT
)
BEGIN
    DECLARE v_prev_ctx INT DEFAULT @app_user_id;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @app_user_id = v_prev_ctx; RESIGNAL; END;
    SET @app_user_id = p_ActorUserID;

    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_ActorUserID AND IsActive) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rejected: user is not an active authorized user.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM AppUser WHERE UserID = p_TargetUserID) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Target account does not exist.';
    END IF;

    UPDATE AppUser SET FailedLoginCount = 0, LockedUntil = NULL WHERE UserID = p_TargetUserID;
    CALL usp_sec_Log(p_ActorUserID, 'AccountUnlocked', 'AppUser', p_TargetUserID, NULL, NULL, NULL);

    SET @app_user_id = v_prev_ctx;
END$$

DELIMITER ;

/* =====================================================================
   6. REVIEW VIEWS  (spec §3 "Detecting it if it happens")
   ===================================================================== */
CREATE OR REPLACE VIEW vw_Security_FailedLogins AS
SELECT a.AuditLogID, a.EventTime, a.Action, a.UserID, u.Username, a.Detail
  FROM AuditLog a
  LEFT JOIN AppUser u ON u.UserID = a.UserID
 WHERE a.Action IN ('LoginFailed', 'LoginBlocked', 'AccountLocked');

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

CREATE OR REPLACE VIEW vw_Security_AccountReview AS
SELECT u.UserID, u.Username, CONCAT(u.FirstName, ' ', u.LastName) AS FullName, u.UserType, u.IsActive,
       u.CreatedAt, ap.Username AS ApprovedBy, u.LastLoginAt,
       DATEDIFF(NOW(), COALESCE(u.LastLoginAt, u.CreatedAt)) AS DaysSinceLastSignIn,
       u.PasswordHash IS NOT NULL                            AS HasPassword,
       COALESCE(u.LockedUntil > NOW(), FALSE)                AS IsLocked,
       u.DeactivatedAt, u.DeactivationReason,
       (SELECT COUNT(*) FROM AppSession s
         WHERE s.UserID = u.UserID AND s.EndedAt IS NULL
           AND s.LastActivityAt >= NOW() - INTERVAL 15 MINUTE) AS OpenSessions,
       CASE WHEN NOT u.IsActive                             THEN 'Deactivated'
            WHEN u.LockedUntil > NOW()                      THEN 'Locked - check failed sign-ins'
            WHEN u.PasswordHash IS NULL                     THEN 'No password set - cannot sign in'
            WHEN u.ApprovedByUserID IS NULL                 THEN 'No recorded approver - confirm with supervisor'
            WHEN u.LastLoginAt IS NULL                      THEN 'Never signed in - confirm still needed'
            WHEN u.LastLoginAt < NOW() - INTERVAL 30 DAY    THEN 'No sign-in for 30+ days - confirm still needed'
            ELSE 'OK' END AS ReviewFlag
  FROM AppUser u
  LEFT JOIN AppUser ap ON ap.UserID = u.ApprovedByUserID;

-- Should always be EMPTY. Any row means data was changed outside the procedures.
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

/* =====================================================================
   7. WEEKLY REVIEW  (spec §3: Asher reviews weekly; supervisor reviews
      the account list at semester end)
      CALL usp_Security_WeeklyReview(7);
   ===================================================================== */
DROP PROCEDURE IF EXISTS usp_Security_WeeklyReview;

DELIMITER $$

CREATE PROCEDURE usp_Security_WeeklyReview (
    IN p_Days INT                       -- NULL = 7
)
BEGIN
    DECLARE v_from DATETIME DEFAULT NOW() - INTERVAL COALESCE(p_Days, 7) DAY;

    -- RS1: summary
    SELECT v_from AS ReviewFrom, NOW() AS ReviewTo,
           (SELECT COUNT(*) FROM AuditLog WHERE Action = 'LoginFailed'   AND EventTime >= v_from) AS FailedSignIns,
           (SELECT COUNT(*) FROM AuditLog WHERE Action = 'AccountLocked' AND EventTime >= v_from) AS Lockouts,
           (SELECT COUNT(*) FROM TransactionAudit WHERE AuditAction = 'Deleted' AND AuditAt >= v_from) AS DeletedTransactions,
           (SELECT COUNT(*) FROM AuditLog WHERE IsDirectEdit AND EventTime >= v_from) AS DirectEdits,
           (SELECT COUNT(*) FROM vw_Security_IntegrityExceptions)                        AS IntegrityExceptions,
           (SELECT COUNT(*) FROM vw_Security_AccountReview WHERE ReviewFlag NOT IN ('OK', 'Deactivated')) AS AccountsToReview;

    -- RS2: failed sign-ins / lockouts
    SELECT * FROM vw_Security_FailedLogins WHERE EventTime >= v_from ORDER BY EventTime DESC;
    -- RS3: deleted transactions
    SELECT * FROM vw_Security_DeletedTransactions WHERE DeletedAt >= v_from ORDER BY DeletedAt DESC;
    -- RS4: changes made outside the app (should be empty or explained)
    SELECT * FROM vw_Security_DirectEdits WHERE EventTime >= v_from ORDER BY EventTime DESC;
    -- RS5: accounts needing attention
    SELECT * FROM vw_Security_AccountReview WHERE ReviewFlag NOT IN ('OK', 'Deactivated') ORDER BY ReviewFlag, Username;
    -- RS6: integrity exceptions (should be empty)
    SELECT * FROM vw_Security_IntegrityExceptions;
END$$

DELIMITER ;

/* Optional scheduled housekeeping (requires event_scheduler = ON):
   CREATE EVENT IF NOT EXISTS ev_EndIdleSessions
     ON SCHEDULE EVERY 5 MINUTE DO CALL usp_Auth_EndIdleSessions();
*/

SELECT 'Part 7 complete: security & audit objects created.' AS Status;
