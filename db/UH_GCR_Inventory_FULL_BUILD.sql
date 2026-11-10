-- =====================================================================
-- UH Government & Community Relations - Inventory Management System
-- Dfyne Innovations | CIS 4375 | Fall 2026
-- Full build script (MySQL 8.0.16+). Drops and recreates UH_GCR_Inventory.
-- Same as running db/01 to db/07 in order.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Part 1: Schema (tables, constraints, indexes, triggers)
-- Drops and recreates the database.
-- ---------------------------------------------------------------------
SET SQL_SAFE_UPDATES = 0;
DROP DATABASE IF EXISTS UH_GCR_Inventory;
CREATE DATABASE UH_GCR_Inventory CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE UH_GCR_Inventory;

-- Users (uniform access; UserType is descriptive only)
CREATE TABLE AppUser (
    UserID      INT          NOT NULL AUTO_INCREMENT,
    Username    VARCHAR(50)  NOT NULL,
    FirstName   VARCHAR(50)  NOT NULL,
    LastName    VARCHAR(50)  NOT NULL,
    Email       VARCHAR(254) NOT NULL,
    UserType    VARCHAR(30)  NOT NULL,
    IsActive    BOOLEAN      NOT NULL DEFAULT TRUE,
    IsSystemAccount BOOLEAN  NOT NULL DEFAULT FALSE,
    CreatedAt   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CreatedByUserID INT      NULL,
    CONSTRAINT PK_AppUser          PRIMARY KEY (UserID),
    CONSTRAINT FK_AppUser_CreatedBy FOREIGN KEY (CreatedByUserID) REFERENCES AppUser (UserID),
    CONSTRAINT UQ_AppUser_Username UNIQUE (Username),
    CONSTRAINT UQ_AppUser_Email    UNIQUE (Email),
    CONSTRAINT CK_AppUser_Email    CHECK (Email LIKE '%_@_%._%'),
    CONSTRAINT CK_AppUser_Names    CHECK (CHAR_LENGTH(TRIM(FirstName)) > 0 AND CHAR_LENGTH(TRIM(LastName)) > 0),
    CONSTRAINT CK_AppUser_UserType CHECK (UserType IN ('Full-Time Staff', 'Student Worker',
                                                      'Student Intern', 'Other Authorized'))
) ENGINE = InnoDB;

-- Lookup tables
CREATE TABLE Category (
    CategoryID    INT          NOT NULL AUTO_INCREMENT,
    CategoryName  VARCHAR(100) NOT NULL,
    Description   VARCHAR(255) NULL,
    IsActive      BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT PK_Category      PRIMARY KEY (CategoryID),
    CONSTRAINT UQ_Category_Name UNIQUE (CategoryName),
    CONSTRAINT CK_Category_Name CHECK (CHAR_LENGTH(TRIM(CategoryName)) > 0)
) ENGINE = InnoDB;

CREATE TABLE Size (
    SizeCode   VARCHAR(10) NOT NULL,
    SizeName   VARCHAR(30) NOT NULL,
    SortOrder  TINYINT     NOT NULL,
    CONSTRAINT PK_Size           PRIMARY KEY (SizeCode),
    CONSTRAINT UQ_Size_SortOrder UNIQUE (SortOrder)
) ENGINE = InnoDB;

CREATE TABLE DistributionCategory (
    DistributionCategoryID INT          NOT NULL AUTO_INCREMENT,
    CategoryName           VARCHAR(100) NOT NULL,
    Description            VARCHAR(255) NULL,
    IsGiveaway             BOOLEAN      NOT NULL DEFAULT FALSE,
    IsActive               BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT PK_DistributionCategory      PRIMARY KEY (DistributionCategoryID),
    CONSTRAINT UQ_DistributionCategory_Name UNIQUE (CategoryName)
) ENGINE = InnoDB;

CREATE TABLE RecipientContext (
    RecipientContextID INT          NOT NULL AUTO_INCREMENT,
    ContextName        VARCHAR(50)  NOT NULL,
    Description        VARCHAR(255) NULL,
    IsActive           BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT PK_RecipientContext      PRIMARY KEY (RecipientContextID),
    CONSTRAINT UQ_RecipientContext_Name UNIQUE (ContextName)
) ENGINE = InnoDB;

CREATE TABLE EventPurpose (
    EventPurposeID INT          NOT NULL AUTO_INCREMENT,
    PurposeName    VARCHAR(100) NOT NULL,
    IsActive       BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT PK_EventPurpose      PRIMARY KEY (EventPurposeID),
    CONSTRAINT UQ_EventPurpose_Name UNIQUE (PurposeName)
) ENGINE = InnoDB;

-- Merchandise
CREATE TABLE Item (
    ItemID       INT           NOT NULL AUTO_INCREMENT,
    ItemName     VARCHAR(100)  NOT NULL,
    CategoryID   INT           NOT NULL,
    Description  VARCHAR(255)  NULL,
    UnitValue    DECIMAL(10,2) NULL,
    IsActive     BOOLEAN       NOT NULL DEFAULT TRUE,
    CreatedAt    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UpdatedAt    DATETIME      NULL,
    CONSTRAINT PK_Item           PRIMARY KEY (ItemID),
    CONSTRAINT UQ_Item_Name      UNIQUE (ItemName),
    CONSTRAINT FK_Item_Category  FOREIGN KEY (CategoryID) REFERENCES Category (CategoryID),
    CONSTRAINT CK_Item_Name      CHECK (CHAR_LENGTH(TRIM(ItemName)) > 0),
    CONSTRAINT CK_Item_UnitValue CHECK (UnitValue IS NULL OR UnitValue >= 0)
) ENGINE = InnoDB;

CREATE TABLE ItemVariant (
    VariantID  INT         NOT NULL AUTO_INCREMENT,
    ItemID     INT         NOT NULL,
    Gender     VARCHAR(10) NULL,
    SizeCode   VARCHAR(10) NULL,
    IsActive   BOOLEAN     NOT NULL DEFAULT TRUE,
    CreatedAt  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- NULL-safe keys for the unique constraint (MySQL allows repeated NULLs)
    GenderKey  VARCHAR(10) AS (COALESCE(Gender, ''))   STORED,
    SizeKey    VARCHAR(10) AS (COALESCE(SizeCode, '')) STORED,
    CONSTRAINT PK_ItemVariant        PRIMARY KEY (VariantID),
    CONSTRAINT FK_ItemVariant_Item   FOREIGN KEY (ItemID)   REFERENCES Item (ItemID),
    CONSTRAINT FK_ItemVariant_Size   FOREIGN KEY (SizeCode) REFERENCES Size (SizeCode),
    CONSTRAINT CK_ItemVariant_Gender CHECK (Gender IS NULL OR Gender IN ('Ladies', 'Males', 'Unisex')),
    CONSTRAINT UQ_ItemVariant        UNIQUE (ItemID, GenderKey, SizeKey)
) ENGINE = InnoDB;

-- Current quantity and low-stock setpoint, one row per variant
CREATE TABLE InventoryBalance (
    VariantID          INT      NOT NULL,
    CurrentQuantity    INT      NOT NULL DEFAULT 0,
    BaselineQuantity   INT      NULL,
    BaselineCountedAt  DATETIME NULL,

    -- 40% of baseline, minimum 1
    SuggestedSetpoint  INT AS (CASE WHEN BaselineQuantity IS NULL THEN NULL
                                    WHEN BaselineQuantity = 0     THEN 0
                                    ELSE GREATEST(1, ROUND(BaselineQuantity * 0.40)) END) STORED,
    Setpoint           INT      NOT NULL DEFAULT 0,
    SetpointIsManual   BOOLEAN  NOT NULL DEFAULT FALSE,
    SetpointUpdatedAt  DATETIME NULL,
    SetpointUpdatedBy  INT      NULL,
    LastMovementAt     DATETIME NULL,
    CONSTRAINT PK_InventoryBalance         PRIMARY KEY (VariantID),
    CONSTRAINT FK_InventoryBalance_Variant FOREIGN KEY (VariantID)         REFERENCES ItemVariant (VariantID),
    CONSTRAINT FK_InventoryBalance_User    FOREIGN KEY (SetpointUpdatedBy) REFERENCES AppUser (UserID),
    CONSTRAINT CK_InvBal_CurrentQty_NonNeg CHECK (CurrentQuantity >= 0),
    CONSTRAINT CK_InvBal_Baseline_NonNeg   CHECK (BaselineQuantity IS NULL OR BaselineQuantity >= 0),
    CONSTRAINT CK_InvBal_Setpoint_NonNeg   CHECK (Setpoint >= 0)
) ENGINE = InnoDB;

-- Reusable giveaway templates
CREATE TABLE GiveawayCombination (
    CombinationID                 INT          NOT NULL AUTO_INCREMENT,
    CombinationName               VARCHAR(100) NOT NULL,
    Description                   VARCHAR(255) NULL,
    DefaultDistributionCategoryID INT          NULL,
    IsActive                      BOOLEAN      NOT NULL DEFAULT TRUE,
    CreatedByUserID               INT          NOT NULL,
    CreatedAt                     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_GiveawayCombination         PRIMARY KEY (CombinationID),
    CONSTRAINT UQ_GiveawayCombination_Name    UNIQUE (CombinationName),
    CONSTRAINT FK_GiveawayCombination_DistCat FOREIGN KEY (DefaultDistributionCategoryID)
                                              REFERENCES DistributionCategory (DistributionCategoryID),
    CONSTRAINT FK_GiveawayCombination_User    FOREIGN KEY (CreatedByUserID) REFERENCES AppUser (UserID)
) ENGINE = InnoDB;

CREATE TABLE GiveawayCombinationLine (
    CombinationLineID INT NOT NULL AUTO_INCREMENT,
    CombinationID     INT NOT NULL,
    VariantID         INT NOT NULL,
    SuggestedQuantity INT NOT NULL DEFAULT 1,
    CONSTRAINT PK_GiveawayCombinationLine   PRIMARY KEY (CombinationLineID),
    CONSTRAINT FK_GiveComboLine_Combination FOREIGN KEY (CombinationID) REFERENCES GiveawayCombination (CombinationID)
                                            ON DELETE CASCADE,
    CONSTRAINT FK_GiveComboLine_Variant     FOREIGN KEY (VariantID) REFERENCES ItemVariant (VariantID),
    CONSTRAINT UQ_GiveComboLine             UNIQUE (CombinationID, VariantID),
    CONSTRAINT CK_GiveComboLine_Qty         CHECK (SuggestedQuantity > 0)
) ENGINE = InnoDB;

-- Transactions (header and lines)
CREATE TABLE InventoryTransaction (
    TransactionID          INT           NOT NULL AUTO_INCREMENT,
    TransactionDate        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UserID                 INT           NOT NULL,
    TransactionType        VARCHAR(3)    NOT NULL,
    StockInReason          VARCHAR(20)   NULL,
    DistributionCategoryID INT           NULL,
    RecipientContextID     INT           NULL,
    EventPurposeID         INT           NULL,
    EventDetails           VARCHAR(255)  NULL,
    RecipientName          VARCHAR(150)  NULL,
    CombinationID          INT           NULL,
    Notes                  VARCHAR(1000) NULL,
    IsDeleted              BOOLEAN       NOT NULL DEFAULT FALSE,
    DeletedAt              DATETIME      NULL,
    DeletedByUserID        INT           NULL,
    DeleteReason           VARCHAR(255)  NULL,
    CONSTRAINT PK_InventoryTransaction    PRIMARY KEY (TransactionID),
    CONSTRAINT FK_InvTxn_User             FOREIGN KEY (UserID)                 REFERENCES AppUser (UserID),
    CONSTRAINT FK_InvTxn_DistCategory     FOREIGN KEY (DistributionCategoryID) REFERENCES DistributionCategory (DistributionCategoryID),
    CONSTRAINT FK_InvTxn_RecipientContext FOREIGN KEY (RecipientContextID)     REFERENCES RecipientContext (RecipientContextID),
    CONSTRAINT FK_InvTxn_EventPurpose     FOREIGN KEY (EventPurposeID)         REFERENCES EventPurpose (EventPurposeID),
    CONSTRAINT FK_InvTxn_Combination      FOREIGN KEY (CombinationID)          REFERENCES GiveawayCombination (CombinationID),
    CONSTRAINT FK_InvTxn_DeletedBy        FOREIGN KEY (DeletedByUserID)        REFERENCES AppUser (UserID),
    CONSTRAINT CK_InvTxn_Type             CHECK (TransactionType IN ('IN', 'OUT')),
    CONSTRAINT CK_InvTxn_StockInReason    CHECK (StockInReason IS NULL OR
                                                 StockInReason IN ('Opening Balance', 'Received', 'Returned', 'Adjustment')),

    CONSTRAINT CK_InvTxn_TypeRules CHECK (
          (TransactionType = 'OUT' AND DistributionCategoryID IS NOT NULL AND RecipientContextID IS NOT NULL AND StockInReason IS NULL)
       OR (TransactionType = 'IN'  AND DistributionCategoryID IS NULL     AND RecipientContextID IS NULL     AND StockInReason IS NOT NULL)),
    CONSTRAINT CK_InvTxn_DeleteRules CHECK (
          (IsDeleted = FALSE AND DeletedAt IS NULL     AND DeletedByUserID IS NULL)
       OR (IsDeleted = TRUE  AND DeletedAt IS NOT NULL AND DeletedByUserID IS NOT NULL))
) ENGINE = InnoDB;

CREATE TABLE TransactionLine (
    TransactionLineID      INT           NOT NULL AUTO_INCREMENT,
    TransactionID          INT           NOT NULL,
    VariantID              INT           NOT NULL,
    Quantity               INT           NOT NULL,
    UnitValueAtTransaction DECIMAL(10,2) NULL,
    LineValue              DECIMAL(14,2) AS (Quantity * UnitValueAtTransaction) VIRTUAL,
    CONSTRAINT PK_TransactionLine     PRIMARY KEY (TransactionLineID),
    CONSTRAINT FK_TxnLine_Transaction FOREIGN KEY (TransactionID) REFERENCES InventoryTransaction (TransactionID),
    CONSTRAINT FK_TxnLine_Variant     FOREIGN KEY (VariantID)     REFERENCES ItemVariant (VariantID),
    CONSTRAINT UQ_TxnLine_TxnVariant  UNIQUE (TransactionID, VariantID),
    CONSTRAINT CK_TxnLine_Quantity    CHECK (Quantity > 0),
    CONSTRAINT CK_TxnLine_UnitValue   CHECK (UnitValueAtTransaction IS NULL OR UnitValueAtTransaction >= 0)
) ENGINE = InnoDB;

-- Low-stock alerts (up to 3 recipients)
CREATE TABLE AlertConfiguration (
    AlertConfigurationID INT          NOT NULL AUTO_INCREMENT,
    ConfigurationName    VARCHAR(100) NOT NULL,
    IsActive             BOOLEAN      NOT NULL DEFAULT TRUE,
    UpdatedAt            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UpdatedByUserID      INT          NULL,
    ActiveKey            TINYINT AS (CASE WHEN IsActive THEN 1 END) STORED,
    CONSTRAINT PK_AlertConfiguration      PRIMARY KEY (AlertConfigurationID),
    CONSTRAINT UQ_AlertConfiguration_Name UNIQUE (ConfigurationName),
    CONSTRAINT UQ_AlertConfiguration_OneActive UNIQUE (ActiveKey),
    CONSTRAINT FK_AlertCfg_User           FOREIGN KEY (UpdatedByUserID) REFERENCES AppUser (UserID)
) ENGINE = InnoDB;

CREATE TABLE AlertRecipient (
    AlertRecipientID     INT          NOT NULL AUTO_INCREMENT,
    AlertConfigurationID INT          NOT NULL,
    RecipientSlot        TINYINT      NOT NULL,
    RecipientName        VARCHAR(100) NULL,
    Email                VARCHAR(254) NOT NULL,
    IsActive             BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT PK_AlertRecipient        PRIMARY KEY (AlertRecipientID),
    CONSTRAINT FK_AlertRecipient_Config FOREIGN KEY (AlertConfigurationID) REFERENCES AlertConfiguration (AlertConfigurationID)
                                        ON DELETE CASCADE,
    CONSTRAINT UQ_AlertRecipient_Slot   UNIQUE (AlertConfigurationID, RecipientSlot),
    CONSTRAINT UQ_AlertRecipient_Email  UNIQUE (AlertConfigurationID, Email),
    CONSTRAINT CK_AlertRecipient_Slot   CHECK (RecipientSlot BETWEEN 1 AND 3),
    CONSTRAINT CK_AlertRecipient_Email  CHECK (Email LIKE '%_@_%._%')
) ENGINE = InnoDB;

CREATE TABLE InventoryAlert (
    AlertID                 INT           NOT NULL AUTO_INCREMENT,
    VariantID               INT           NOT NULL,
    TriggeringTransactionID INT           NULL,
    AlertConfigurationID    INT           NULL,
    AlertGeneratedAt        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    QuantityAtAlert         INT           NOT NULL,
    SetpointAtAlert         INT           NOT NULL,
    AlertStatus             VARCHAR(10)   NOT NULL DEFAULT 'Pending',
    EmailSentAt             DATETIME      NULL,
    RecipientsNotified      VARCHAR(800)  NULL,
    LastSendError           VARCHAR(1000) NULL,
    ResolvedAt              DATETIME      NULL,
    SendAttempts            INT           NOT NULL DEFAULT 0,

    OpenVariantKey          INT AS (CASE WHEN AlertStatus IN ('Pending', 'Sent') THEN VariantID END) STORED,
    CONSTRAINT PK_InventoryAlert        PRIMARY KEY (AlertID),
    CONSTRAINT FK_InvAlert_Variant      FOREIGN KEY (VariantID)               REFERENCES ItemVariant (VariantID),
    CONSTRAINT FK_InvAlert_Transaction  FOREIGN KEY (TriggeringTransactionID) REFERENCES InventoryTransaction (TransactionID),
    CONSTRAINT FK_InvAlert_Config       FOREIGN KEY (AlertConfigurationID)    REFERENCES AlertConfiguration (AlertConfigurationID),
    CONSTRAINT UQ_InventoryAlert_OpenPerVariant UNIQUE (OpenVariantKey),
    CONSTRAINT CK_InvAlert_Status       CHECK (AlertStatus IN ('Pending', 'Sent', 'Resolved')),
    CONSTRAINT CK_InvAlert_Qty          CHECK (QuantityAtAlert >= 0 AND SetpointAtAlert >= 0),
    CONSTRAINT CK_InvAlert_SendAttempts CHECK (SendAttempts >= 0)
) ENGINE = InnoDB;

-- Append-only audit log
CREATE TABLE TransactionAudit (
    AuditID         INT          NOT NULL AUTO_INCREMENT,
    TransactionID   INT          NOT NULL,
    AuditAction     VARCHAR(10)  NOT NULL,
    AuditAt         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    AuditByUserID   INT          NOT NULL,
    TransactionType VARCHAR(3)   NOT NULL,
    LineCount       INT          NOT NULL,
    TotalUnits      INT          NOT NULL,
    InventoryEffect VARCHAR(10)  NOT NULL,
    Reason          VARCHAR(255) NULL,
    LineDetail      JSON         NULL,
    CONSTRAINT PK_TransactionAudit     PRIMARY KEY (AuditID),
    CONSTRAINT FK_TxnAudit_Transaction FOREIGN KEY (TransactionID) REFERENCES InventoryTransaction (TransactionID),
    CONSTRAINT FK_TxnAudit_User        FOREIGN KEY (AuditByUserID) REFERENCES AppUser (UserID),
    CONSTRAINT CK_TxnAudit_Action      CHECK (AuditAction IN ('Created', 'Deleted')),
    CONSTRAINT CK_TxnAudit_Type        CHECK (TransactionType IN ('IN', 'OUT')),
    CONSTRAINT CK_TxnAudit_Effect      CHECK (InventoryEffect IN ('Added', 'Removed')),
    CONSTRAINT CK_TxnAudit_Counts      CHECK (LineCount > 0 AND TotalUnits > 0)
) ENGINE = InnoDB;

CREATE INDEX IX_InvTxn_Date        ON InventoryTransaction (TransactionDate, TransactionType, IsDeleted);
CREATE INDEX IX_TxnLine_VariantQty ON TransactionLine (VariantID, Quantity, TransactionID);
CREATE INDEX IX_InvAlert_Status    ON InventoryAlert (AlertStatus, VariantID, AlertGeneratedAt);
CREATE INDEX IX_TxnAudit_AuditAt   ON TransactionAudit (AuditAt, AuditAction, TransactionType);

-- Triggers
DELIMITER $$

CREATE TRIGGER trg_InventoryTransaction_BlockHardDelete
BEFORE DELETE ON InventoryTransaction
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Direct DELETE is not allowed. Use usp_DeleteTransaction so inventory is reversed.';
END$$

CREATE TRIGGER trg_TransactionLine_BlockHardDelete
BEFORE DELETE ON TransactionLine
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Direct DELETE of transaction lines is not allowed. Use usp_DeleteTransaction.';
END$$

CREATE TRIGGER trg_TransactionAudit_BlockUpdate
BEFORE UPDATE ON TransactionAudit
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'TransactionAudit is append-only; rows cannot be changed.';
END$$

CREATE TRIGGER trg_TransactionAudit_BlockDelete
BEFORE DELETE ON TransactionAudit
FOR EACH ROW
BEGIN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'TransactionAudit is append-only; rows cannot be deleted.';
END$$

-- Raises or resolves an alert whenever quantity or setpoint changes
CREATE TRIGGER trg_InventoryBalance_LowStockAlert
AFTER UPDATE ON InventoryBalance
FOR EACH ROW
BEGIN
    IF NOT (NEW.CurrentQuantity  <=> OLD.CurrentQuantity
        AND NEW.Setpoint         <=> OLD.Setpoint
        AND NEW.BaselineQuantity <=> OLD.BaselineQuantity) THEN

        IF NEW.BaselineQuantity IS NOT NULL AND NEW.CurrentQuantity <= NEW.Setpoint THEN
            INSERT INTO InventoryAlert (VariantID, TriggeringTransactionID, AlertConfigurationID,
                                        QuantityAtAlert, SetpointAtAlert, AlertStatus)
            SELECT NEW.VariantID, @TriggeringTransactionID,
                   (SELECT AlertConfigurationID FROM AlertConfiguration WHERE IsActive LIMIT 1),
                   NEW.CurrentQuantity, NEW.Setpoint, 'Pending'
            FROM ItemVariant v
            JOIN Item i ON i.ItemID = v.ItemID
            WHERE v.VariantID = NEW.VariantID
              AND v.IsActive AND i.IsActive
              AND NOT EXISTS (SELECT 1 FROM InventoryAlert a
                              WHERE a.OpenVariantKey = NEW.VariantID);
        ELSEIF NEW.CurrentQuantity > NEW.Setpoint THEN
            UPDATE InventoryAlert
               SET AlertStatus = 'Resolved', ResolvedAt = NOW()
             WHERE OpenVariantKey = NEW.VariantID;
        END IF;
    END IF;
END$$

DELIMITER ;

SELECT 'Part 1 complete: schema created.' AS Status;

-- ---------------------------------------------------------------------
-- Part 2: Stored procedures
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Part 3: Views and reports
-- ---------------------------------------------------------------------
USE UH_GCR_Inventory;

CREATE OR REPLACE VIEW vw_CurrentInventory AS
SELECT i.ItemID,
       v.VariantID,
       c.CategoryID,
       c.CategoryName,
       i.ItemName,
       v.Gender,
       v.SizeCode,
       s.SortOrder                                                   AS SizeSortOrder,
       COALESCE(NULLIF(CONCAT_WS(' ', v.Gender, v.SizeCode), ''), 'Standard') AS VariantLabel,
       b.CurrentQuantity,
       b.Setpoint,
       b.SuggestedSetpoint,
       b.SetpointIsManual,
       b.BaselineQuantity,
       i.UnitValue,
       CAST(b.CurrentQuantity * i.UnitValue AS DECIMAL(12,2))        AS TotalValue,
       IF(i.UnitValue IS NULL, 'Not Provided', 'Provided')           AS ValueStatus,
       CASE WHEN b.BaselineQuantity IS NULL      THEN 'Not Yet Counted'
            WHEN b.CurrentQuantity = 0           THEN 'Out of Stock'
            WHEN b.CurrentQuantity <= b.Setpoint THEN 'Low Stock'
            ELSE 'OK' END                                            AS StockStatus,
       b.LastMovementAt,
       i.IsActive                                                    AS ItemIsActive,
       v.IsActive                                                    AS VariantIsActive
  FROM ItemVariant v
  JOIN Item i             ON i.ItemID     = v.ItemID
  JOIN Category c         ON c.CategoryID = i.CategoryID
  JOIN InventoryBalance b ON b.VariantID  = v.VariantID
  LEFT JOIN Size s        ON s.SizeCode   = v.SizeCode;

CREATE OR REPLACE VIEW vw_LowInventory AS
SELECT ci.CategoryName, ci.ItemName, ci.VariantLabel, ci.VariantID,
       ci.CurrentQuantity, ci.Setpoint, ci.BaselineQuantity, ci.StockStatus,
       ci.Setpoint - ci.CurrentQuantity                                       AS UnitsBelowSetpoint,
       GREATEST(COALESCE(ci.BaselineQuantity, 0) - ci.CurrentQuantity, 0)     AS QtyToRestoreBaseline,
       a.AlertID, a.AlertStatus, a.AlertGeneratedAt, a.EmailSentAt,
       COALESCE(a.AlertStatus, 'No Open Alert')                               AS AlertState
  FROM vw_CurrentInventory ci
  LEFT JOIN InventoryAlert a ON a.OpenVariantKey = ci.VariantID
 WHERE ci.ItemIsActive AND ci.VariantIsActive
   AND ci.BaselineQuantity IS NOT NULL
   AND ci.CurrentQuantity <= ci.Setpoint;

CREATE OR REPLACE VIEW vw_InventoryValue AS
SELECT CategoryID, CategoryName, ItemName, VariantLabel, VariantID, CurrentQuantity, UnitValue, TotalValue
  FROM vw_CurrentInventory
 WHERE UnitValue IS NOT NULL AND ItemIsActive AND VariantIsActive;

CREATE OR REPLACE VIEW vw_TransactionHistory AS
SELECT t.TransactionID,
       t.TransactionDate,
       t.TransactionType,
       IF(t.TransactionType = 'IN', 'Stock In', 'Stock Out')               AS TransactionTypeLabel,
       t.StockInReason,
       t.UserID,
       CONCAT(u.FirstName, ' ', u.LastName)                                AS SubmittedBy,
       ci.CategoryName,
       ci.ItemName,
       ci.VariantLabel,
       tl.VariantID,
       tl.Quantity,
       IF(t.TransactionType = 'OUT', -tl.Quantity, tl.Quantity)            AS SignedQuantity,
       tl.UnitValueAtTransaction,
       tl.LineValue,
       dc.CategoryName                                                     AS DistributionCategory,
       rc.ContextName                                                      AS RecipientContext,
       ep.PurposeName                                                      AS EventPurpose,
       t.EventDetails,
       t.RecipientName,
       gc.CombinationName                                                  AS TemplateUsed,
       t.Notes,
       t.IsDeleted,
       t.DeletedAt,
       CONCAT(du.FirstName, ' ', du.LastName)                              AS DeletedBy,
       t.DeleteReason
  FROM InventoryTransaction t
  JOIN TransactionLine tl           ON tl.TransactionID = t.TransactionID
  JOIN AppUser u                    ON u.UserID         = t.UserID
  JOIN vw_CurrentInventory ci       ON ci.VariantID     = tl.VariantID
  LEFT JOIN DistributionCategory dc ON dc.DistributionCategoryID = t.DistributionCategoryID
  LEFT JOIN RecipientContext rc     ON rc.RecipientContextID     = t.RecipientContextID
  LEFT JOIN EventPurpose ep         ON ep.EventPurposeID         = t.EventPurposeID
  LEFT JOIN GiveawayCombination gc  ON gc.CombinationID          = t.CombinationID
  LEFT JOIN AppUser du              ON du.UserID                 = t.DeletedByUserID;

-- Email queue: group by TriggeringTransactionID to send one email per transaction
CREATE OR REPLACE VIEW vw_PendingAlertEmails AS
SELECT a.AlertID, a.TriggeringTransactionID, a.AlertGeneratedAt,
       ci.CategoryName, ci.ItemName, ci.VariantLabel,
       ci.CurrentQuantity, ci.Setpoint,
       a.SendAttempts, a.LastSendError,
       r.Recipients
  FROM InventoryAlert a
  JOIN vw_CurrentInventory ci ON ci.VariantID = a.VariantID
  CROSS JOIN (SELECT GROUP_CONCAT(ar.Email ORDER BY ar.RecipientSlot SEPARATOR ';') AS Recipients
                FROM AlertRecipient ar
                JOIN AlertConfiguration ac ON ac.AlertConfigurationID = ar.AlertConfigurationID
               WHERE ac.IsActive AND ar.IsActive) r
 WHERE a.AlertStatus = 'Pending'
   AND a.SendAttempts < 5
   AND r.Recipients IS NOT NULL;

CREATE OR REPLACE VIEW vw_FailedAlertEmails AS
SELECT a.AlertID, a.TriggeringTransactionID, a.AlertGeneratedAt,
       ci.ItemName, ci.VariantLabel, ci.CurrentQuantity, ci.Setpoint,
       a.SendAttempts, a.LastSendError
  FROM InventoryAlert a
  JOIN vw_CurrentInventory ci ON ci.VariantID = a.VariantID
 WHERE a.AlertStatus = 'Pending'
   AND a.SendAttempts >= 5;

-- Application views
CREATE OR REPLACE VIEW vw_GiveawayCombinations AS
SELECT gc.CombinationID, gc.CombinationName, gc.Description,
       gc.DefaultDistributionCategoryID, dc.CategoryName AS DefaultDistributionCategory,
       gl.VariantID, ci.ItemName, ci.VariantLabel, gl.SuggestedQuantity,
       ci.CurrentQuantity, (ci.ItemIsActive AND ci.VariantIsActive) AS IsSelectable
  FROM GiveawayCombination gc
  JOIN GiveawayCombinationLine gl      ON gl.CombinationID = gc.CombinationID
  JOIN vw_CurrentInventory ci          ON ci.VariantID     = gl.VariantID
  LEFT JOIN DistributionCategory dc    ON dc.DistributionCategoryID = gc.DefaultDistributionCategoryID
 WHERE gc.IsActive;

CREATE OR REPLACE VIEW vw_Users AS
SELECT u.UserID, u.Username, u.FirstName, u.LastName,
       CONCAT(u.FirstName, ' ', u.LastName) AS FullName,
       u.Email, u.UserType, u.IsActive,
       u.CreatedAt,
       CONCAT(c.FirstName, ' ', c.LastName)  AS AddedBy
  FROM AppUser u
  LEFT JOIN AppUser c ON c.UserID = u.CreatedByUserID
 WHERE NOT u.IsSystemAccount;

CREATE OR REPLACE VIEW vw_AlertRecipients AS
SELECT ar.AlertRecipientID, ar.RecipientSlot, ar.RecipientName, ar.Email,
       ac.UpdatedAt AS ConfigUpdatedAt,
       CONCAT(u.FirstName, ' ', u.LastName) AS ConfigUpdatedBy
  FROM AlertRecipient ar
  JOIN AlertConfiguration ac ON ac.AlertConfigurationID = ar.AlertConfigurationID AND ac.IsActive
  LEFT JOIN AppUser u        ON u.UserID = ac.UpdatedByUserID
 WHERE ar.IsActive;

CREATE OR REPLACE VIEW vw_SetupStatus AS
SELECT x.ActiveUsers, x.AlertRecipients, x.VariantsCounted, x.ActiveVariants,
       (x.ActiveUsers = 0)                    AS NeedsStaff,
       (x.AlertRecipients = 0)                AS NeedsAlertRecipient,
       (x.VariantsCounted < x.ActiveVariants) AS NeedsOpeningCounts
  FROM (SELECT (SELECT COUNT(*) FROM AppUser WHERE IsActive AND NOT IsSystemAccount) AS ActiveUsers,
               (SELECT COUNT(*) FROM vw_AlertRecipients)                             AS AlertRecipients,
               (SELECT COUNT(*) FROM InventoryBalance WHERE BaselineQuantity IS NOT NULL) AS VariantsCounted,
               (SELECT COUNT(*) FROM ItemVariant WHERE IsActive)                    AS ActiveVariants) x;

CREATE OR REPLACE VIEW vw_TransactionAuditLog AS
SELECT a.AuditID, a.AuditAt, a.AuditAction, a.TransactionID,
       IF(a.TransactionType = 'IN', 'Stock In', 'Stock Out') AS TransactionTypeLabel,
       CONCAT(u.FirstName, ' ', u.LastName)                  AS PerformedBy,
       a.LineCount, a.TotalUnits, a.InventoryEffect, a.Reason, a.LineDetail
  FROM TransactionAudit a
  JOIN AppUser u ON u.UserID = a.AuditByUserID;

DROP PROCEDURE IF EXISTS usp_rpt_CurrentInventory;
DROP PROCEDURE IF EXISTS usp_rpt_LowInventory;
DROP PROCEDURE IF EXISTS usp_rpt_InventoryUsage;
DROP PROCEDURE IF EXISTS usp_rpt_InventoryValue;
DROP PROCEDURE IF EXISTS usp_rpt_TransactionHistory;
DROP PROCEDURE IF EXISTS usp_rpt_Giveaway;
DROP PROCEDURE IF EXISTS usp_rpt_DemandForecast;

DELIMITER $$

-- Reports
CREATE PROCEDURE usp_rpt_CurrentInventory (
    IN p_CategoryID      INT,
    IN p_IncludeInactive BOOLEAN
)
BEGIN
    SELECT CategoryName, ItemName, VariantLabel, CurrentQuantity, Setpoint,
           UnitValue, TotalValue, StockStatus, LastMovementAt,
           IF(ItemIsActive AND VariantIsActive, 'Active', 'Inactive') AS Status
      FROM vw_CurrentInventory
     WHERE (p_CategoryID IS NULL OR CategoryID = p_CategoryID)
       AND (COALESCE(p_IncludeInactive, FALSE) OR (ItemIsActive AND VariantIsActive))
     ORDER BY CategoryName, ItemName, Gender, SizeSortOrder;
END$$

CREATE PROCEDURE usp_rpt_LowInventory ()
BEGIN
    SELECT CategoryName, ItemName, VariantLabel, CurrentQuantity, Setpoint,
           UnitsBelowSetpoint, QtyToRestoreBaseline, StockStatus,
           AlertState, AlertGeneratedAt, EmailSentAt
      FROM vw_LowInventory
     ORDER BY (StockStatus <> 'Out of Stock'), UnitsBelowSetpoint DESC, ItemName;
END$$

CREATE PROCEDURE usp_rpt_InventoryUsage (
    IN p_StartDate              DATE,
    IN p_EndDate                DATE,
    IN p_CategoryID             INT,
    IN p_DistributionCategoryID INT
)
BEGIN
    DECLARE v_end DATETIME DEFAULT DATE_ADD(p_EndDate, INTERVAL 1 DAY);

    WITH OutLines AS (
        SELECT t.TransactionID, t.DistributionCategoryID, t.RecipientContextID,
               tl.VariantID, tl.Quantity, tl.LineValue
          FROM InventoryTransaction t
          JOIN TransactionLine tl ON tl.TransactionID = t.TransactionID
         WHERE t.TransactionType = 'OUT' AND NOT t.IsDeleted
           AND t.TransactionDate >= p_StartDate AND t.TransactionDate < v_end
           AND (p_DistributionCategoryID IS NULL OR t.DistributionCategoryID = p_DistributionCategoryID)
    )
    SELECT ci.CategoryName, ci.ItemName, ci.VariantLabel,
           SUM(o.Quantity)                                     AS QtyDistributed,
           COUNT(DISTINCT o.TransactionID)                     AS NumDistributions,
           SUM(o.LineValue)                                    AS KnownValueDistributed,
           SUM(IF(o.LineValue IS NULL, o.Quantity, 0))         AS UnitsWithUnknownValue,
           ci.CurrentQuantity
      FROM OutLines o
      JOIN vw_CurrentInventory ci ON ci.VariantID = o.VariantID
     WHERE (p_CategoryID IS NULL OR ci.CategoryID = p_CategoryID)
     GROUP BY ci.VariantID, ci.CategoryName, ci.ItemName, ci.VariantLabel, ci.CurrentQuantity
     ORDER BY QtyDistributed DESC, ci.ItemName;

    WITH OutLines AS (
        SELECT t.TransactionID, t.DistributionCategoryID, t.RecipientContextID,
               tl.VariantID, tl.Quantity, tl.LineValue
          FROM InventoryTransaction t
          JOIN TransactionLine tl ON tl.TransactionID = t.TransactionID
         WHERE t.TransactionType = 'OUT' AND NOT t.IsDeleted
           AND t.TransactionDate >= p_StartDate AND t.TransactionDate < v_end
           AND (p_DistributionCategoryID IS NULL OR t.DistributionCategoryID = p_DistributionCategoryID)
    )
    SELECT dc.CategoryName                  AS DistributionCategory,
           rc.ContextName                   AS RecipientContext,
           COUNT(DISTINCT o.TransactionID)  AS NumDistributions,
           SUM(o.Quantity)                  AS TotalUnits,
           SUM(o.LineValue)                 AS KnownValueDistributed
      FROM OutLines o
      JOIN DistributionCategory dc ON dc.DistributionCategoryID = o.DistributionCategoryID
      JOIN RecipientContext rc     ON rc.RecipientContextID     = o.RecipientContextID
      JOIN vw_CurrentInventory ci  ON ci.VariantID              = o.VariantID
     WHERE (p_CategoryID IS NULL OR ci.CategoryID = p_CategoryID)
     GROUP BY dc.CategoryName, rc.ContextName
     ORDER BY TotalUnits DESC;
END$$

CREATE PROCEDURE usp_rpt_InventoryValue (
    IN p_CategoryID INT
)
BEGIN
    SELECT CategoryName, ItemName, VariantLabel, CurrentQuantity, UnitValue, TotalValue
      FROM vw_InventoryValue
     WHERE (p_CategoryID IS NULL OR CategoryID = p_CategoryID)
     ORDER BY TotalValue DESC;

    SELECT IF(GROUPING(CategoryName) = 1, 'ALL CATEGORIES', CategoryName)  AS CategoryName,
           SUM(TotalValue)                                                  AS KnownInventoryValue,
           SUM(IF(UnitValue IS NOT NULL, CurrentQuantity, 0))               AS UnitsWithValue,
           SUM(IF(UnitValue IS NULL,     CurrentQuantity, 0))               AS UnitsWithoutValue,
           SUM(UnitValue IS NULL)                                           AS VariantsMissingValue
      FROM vw_CurrentInventory
     WHERE ItemIsActive AND VariantIsActive
       AND (p_CategoryID IS NULL OR CategoryID = p_CategoryID)
     GROUP BY CategoryName WITH ROLLUP;
END$$

CREATE PROCEDURE usp_rpt_TransactionHistory (
    IN p_StartDate       DATE,
    IN p_EndDate         DATE,
    IN p_TransactionType VARCHAR(3),
    IN p_UserID          INT,
    IN p_VariantID       INT,
    IN p_IncludeDeleted  BOOLEAN
)
BEGIN
    SELECT TransactionID, TransactionDate, TransactionTypeLabel, StockInReason, SubmittedBy,
           CategoryName, ItemName, VariantLabel, Quantity, LineValue,
           DistributionCategory, RecipientContext, EventPurpose, EventDetails, RecipientName,
           TemplateUsed, Notes,
           IF(IsDeleted, 'Deleted / Reversed', 'Active') AS RecordStatus,
           DeletedAt, DeletedBy, DeleteReason
      FROM vw_TransactionHistory
     WHERE (p_StartDate IS NULL OR TransactionDate >= p_StartDate)
       AND (p_EndDate   IS NULL OR TransactionDate <  DATE_ADD(p_EndDate, INTERVAL 1 DAY))
       AND (p_TransactionType IS NULL OR TransactionType = p_TransactionType)
       AND (p_UserID    IS NULL OR UserID    = p_UserID)
       AND (p_VariantID IS NULL OR VariantID = p_VariantID)
       AND (COALESCE(p_IncludeDeleted, FALSE) OR NOT IsDeleted)
     ORDER BY TransactionDate DESC, TransactionID DESC, ItemName;
END$$

CREATE PROCEDURE usp_rpt_Giveaway (
    IN p_StartDate              DATE,
    IN p_EndDate                DATE,
    IN p_DistributionCategoryID INT,
    IN p_RecipientContextID     INT,
    IN p_GiveawayOnly           BOOLEAN,
    IN p_MultiItemOnly          BOOLEAN
)
BEGIN
    SET SESSION group_concat_max_len = 8192;

    WITH Txn AS (
        SELECT t.TransactionID
          FROM InventoryTransaction t
          JOIN DistributionCategory dc ON dc.DistributionCategoryID = t.DistributionCategoryID
         WHERE t.TransactionType = 'OUT' AND NOT t.IsDeleted
           AND (p_StartDate IS NULL OR t.TransactionDate >= p_StartDate)
           AND (p_EndDate   IS NULL OR t.TransactionDate <  DATE_ADD(p_EndDate, INTERVAL 1 DAY))
           AND (p_DistributionCategoryID IS NULL OR t.DistributionCategoryID = p_DistributionCategoryID)
           AND (p_RecipientContextID     IS NULL OR t.RecipientContextID     = p_RecipientContextID)
           AND (NOT COALESCE(p_GiveawayOnly, FALSE) OR dc.IsGiveaway)
           AND (NOT COALESCE(p_MultiItemOnly, FALSE)
                OR (SELECT COUNT(*) FROM TransactionLine x WHERE x.TransactionID = t.TransactionID) >= 2)
    ),
    Agg AS (
        SELECT tl.TransactionID,
               COUNT(*)                        AS DistinctItems,
               SUM(tl.Quantity)                AS TotalUnits,
               SUM(tl.LineValue)               AS KnownValue,
               SUM(tl.LineValue IS NULL)       AS UnknownValueLines,
               GROUP_CONCAT(CONCAT(tl.Quantity, ' x ', ci.ItemName,
                                   IF(ci.VariantLabel = 'Standard', '', CONCAT(' (', ci.VariantLabel, ')')))
                            ORDER BY ci.ItemName SEPARATOR ', ') AS ItemsDistributed
          FROM TransactionLine tl
          JOIN Txn f                  ON f.TransactionID = tl.TransactionID
          JOIN vw_CurrentInventory ci ON ci.VariantID    = tl.VariantID
         GROUP BY tl.TransactionID
    )
    SELECT t.TransactionID                         AS DistributionNo,
           t.TransactionDate,
           CONCAT(u.FirstName, ' ', u.LastName)    AS SubmittedBy,
           dc.CategoryName                         AS DistributionCategory,
           rc.ContextName                          AS RecipientContext,
           ep.PurposeName                          AS EventPurpose,
           t.EventDetails,
           t.RecipientName,
           gc.CombinationName                      AS TemplateUsed,
           agg.DistinctItems,
           agg.TotalUnits,
           agg.ItemsDistributed,
           agg.KnownValue,
           IF(agg.UnknownValueLines > 0, 'Partial / Unknown', 'Complete') AS ValueCompleteness
      FROM Agg agg
      JOIN InventoryTransaction t       ON t.TransactionID = agg.TransactionID
      JOIN AppUser u                    ON u.UserID        = t.UserID
      JOIN DistributionCategory dc      ON dc.DistributionCategoryID = t.DistributionCategoryID
      JOIN RecipientContext rc          ON rc.RecipientContextID     = t.RecipientContextID
      LEFT JOIN EventPurpose ep         ON ep.EventPurposeID         = t.EventPurposeID
      LEFT JOIN GiveawayCombination gc  ON gc.CombinationID          = t.CombinationID
     ORDER BY t.TransactionDate DESC, t.TransactionID DESC;

    WITH Txn AS (
        SELECT t.TransactionID
          FROM InventoryTransaction t
          JOIN DistributionCategory dc ON dc.DistributionCategoryID = t.DistributionCategoryID
         WHERE t.TransactionType = 'OUT' AND NOT t.IsDeleted
           AND (p_StartDate IS NULL OR t.TransactionDate >= p_StartDate)
           AND (p_EndDate   IS NULL OR t.TransactionDate <  DATE_ADD(p_EndDate, INTERVAL 1 DAY))
           AND (p_DistributionCategoryID IS NULL OR t.DistributionCategoryID = p_DistributionCategoryID)
           AND (p_RecipientContextID     IS NULL OR t.RecipientContextID     = p_RecipientContextID)
           AND (NOT COALESCE(p_GiveawayOnly, FALSE) OR dc.IsGiveaway)
    ),
    ItemsPerTxn AS (
        SELECT DISTINCT tl.TransactionID, v.ItemID
          FROM TransactionLine tl
          JOIN Txn f         ON f.TransactionID = tl.TransactionID
          JOIN ItemVariant v ON v.VariantID     = tl.VariantID
    )
    SELECT i1.ItemName AS ItemA, i2.ItemName AS ItemB, COUNT(*) AS TimesGivenTogether
      FROM ItemsPerTxn a
      JOIN ItemsPerTxn b ON b.TransactionID = a.TransactionID AND b.ItemID > a.ItemID
      JOIN Item i1       ON i1.ItemID = a.ItemID
      JOIN Item i2       ON i2.ItemID = b.ItemID
     GROUP BY i1.ItemName, i2.ItemName
     ORDER BY TimesGivenTogether DESC, ItemA, ItemB;
END$$

CREATE PROCEDURE usp_rpt_DemandForecast (
    IN p_LookbackDays INT,
    IN p_CoverageDays INT,
    IN p_CategoryID   INT
)
BEGIN
    DECLARE v_lookback INT DEFAULT COALESCE(p_LookbackDays, 180);
    DECLARE v_coverage INT DEFAULT COALESCE(p_CoverageDays, 90);
    DECLARE v_from DATETIME;

    IF v_lookback <= 0 OR v_coverage <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lookback and coverage days must be greater than zero.';
    END IF;
    SET v_from = DATE_SUB(NOW(), INTERVAL v_lookback DAY);

    WITH UsageStats AS (
        SELECT tl.VariantID,
               SUM(tl.Quantity)                AS QtyOut,
               COUNT(DISTINCT t.TransactionID) AS NumDistributions,
               MAX(t.TransactionDate)          AS LastDistributedAt
          FROM InventoryTransaction t
          JOIN TransactionLine tl ON tl.TransactionID = t.TransactionID
         WHERE t.TransactionType = 'OUT' AND NOT t.IsDeleted
           AND t.TransactionDate >= v_from
         GROUP BY tl.VariantID
    ),
    Calc AS (
        SELECT ci.CategoryName, ci.ItemName, ci.VariantLabel, ci.CurrentQuantity, ci.Setpoint,
               ci.StockStatus, ci.Gender, ci.SizeSortOrder,
               COALESCE(u.QtyOut, 0)           AS QtyOutInWindow,
               COALESCE(u.NumDistributions, 0) AS NumDistributions,
               u.LastDistributedAt,
               COALESCE(u.QtyOut, 0) / v_lookback AS AvgDailyUsage
          FROM vw_CurrentInventory ci
          LEFT JOIN UsageStats u ON u.VariantID = ci.VariantID
         WHERE ci.ItemIsActive AND ci.VariantIsActive
           AND (p_CategoryID IS NULL OR ci.CategoryID = p_CategoryID)
    )
    SELECT CategoryName, ItemName, VariantLabel,
           QtyOutInWindow, NumDistributions, LastDistributedAt,
           ROUND(AvgDailyUsage * 30, 2)                                     AS AvgMonthlyUsage,
           DENSE_RANK() OVER (ORDER BY QtyOutInWindow DESC)                 AS UsageRank,
           CurrentQuantity, Setpoint, StockStatus,
           IF(AvgDailyUsage > 0, FLOOR(CurrentQuantity / AvgDailyUsage), NULL) AS EstDaysOfStockLeft,
           CASE WHEN CurrentQuantity <= Setpoint THEN 0
                WHEN AvgDailyUsage > 0 THEN FLOOR((CurrentQuantity - Setpoint) / AvgDailyUsage) END AS EstDaysUntilSetpoint,
           CASE WHEN AvgDailyUsage > 0 AND CurrentQuantity > Setpoint
                THEN DATE(DATE_ADD(NOW(), INTERVAL FLOOR((CurrentQuantity - Setpoint) / AvgDailyUsage) DAY)) END AS EstSetpointDate,
           GREATEST(CEILING(AvgDailyUsage * v_coverage) + Setpoint - CurrentQuantity, 0) AS SuggestedReorderQty,
           CASE WHEN QtyOutInWindow = 0 THEN 'No recent demand'
                WHEN CurrentQuantity <= Setpoint THEN 'Reorder now'
                WHEN AvgDailyUsage > 0 AND (CurrentQuantity - Setpoint) / AvgDailyUsage <= 30 THEN 'Reorder within 30 days'
                ELSE 'Sufficient' END                                       AS Recommendation
      FROM Calc
     ORDER BY QtyOutInWindow DESC, ItemName, Gender, SizeSortOrder;
END$$

DELIMITER ;

SELECT 'Part 3 complete: reports created.' AS Status;

-- ---------------------------------------------------------------------
-- Part 4: Reference data and starting inventory
-- ---------------------------------------------------------------------
USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

-- System account that owns the seed data (deactivated at the end of this script)
INSERT INTO AppUser (Username, FirstName, LastName, Email, UserType, IsSystemAccount)
VALUES ('system', 'GCR', 'System', 'system@gcr-inventory.invalid', 'Other Authorized', TRUE);

-- Lookup values
INSERT INTO Category (CategoryName, Description) VALUES
 ('Accessories & Gear',           'Coolers, belt buckles, umbrellas and similar gear'),
 ('Apparel',                      'Jackets, polos, vests - tracked by gender and/or size'),
 ('Bags & Totes',                 'Tote bags and carry items'),
 ('Drinkware',                    'Tumblers, bottles, can coolers'),
 ('Office Supplies & Stationery', 'Folders, journals, notebooks, pens');

INSERT INTO Size (SizeCode, SizeName, SortOrder) VALUES
 ('XS', 'Extra Small', 1), ('S', 'Small', 2), ('M', 'Medium', 3), ('L', 'Large', 4),
 ('XL', 'Extra Large', 5), ('XXL', '2X Large', 6), ('XXXL', '3X Large', 7);

INSERT INTO DistributionCategory (CategoryName, Description, IsGiveaway) VALUES
 ('Community Event / Donation',      'Community events, outreach activities, donations, community-facing purposes', FALSE),
 ('Giveaway - Government Relations', 'Relationship-building gifts/giveaways for government relations activities',   TRUE),
 ('Giveaway - Community Relations',  'Relationship-building gifts/giveaways for community relations activities',    TRUE),
 ('Internal Staff',                  'Merchandise provided for internal office/staff purposes',                     FALSE),
 ('Other / Inventory Adjustment',    'Damaged, lost, or count-correction removals (explain in Notes)',              FALSE);

INSERT INTO RecipientContext (ContextName, Description) VALUES
 ('External',               'Recipient outside the University of Houston'),
 ('In-Network / Within UH', 'UH employee, department, or other UH entity outside Government & Community Relations'),
 ('Not Applicable',         'No recipient (e.g., damaged/lost inventory adjustment)');

INSERT INTO EventPurpose (PurposeName) VALUES
 ('Conference'), ('Meeting'), ('Community Outreach'), ('Government Relations Event'),
 ('Government Relations Meeting'), ('Internal Use'), ('Donation'), ('Other');

-- Item catalog and variants
INSERT INTO Item (ItemName, CategoryID)
SELECT x.ItemName, c.CategoryID
  FROM (          SELECT 'Red Igloo Cooler' AS ItemName, 'Accessories & Gear' AS CategoryName
        UNION ALL SELECT 'UH Belt Buckle',           'Accessories & Gear'
        UNION ALL SELECT 'Umbrella',                 'Accessories & Gear'
        UNION ALL SELECT 'Black Jacket',             'Apparel'
        UNION ALL SELECT 'Red UH Polo',              'Apparel'
        UNION ALL SELECT 'UH Vest',                  'Apparel'
        UNION ALL SELECT 'Red UH Tote Bag',          'Bags & Totes'
        UNION ALL SELECT 'Black Can Yeti',           'Drinkware'
        UNION ALL SELECT 'Red Plastic Water Bottle', 'Drinkware'
        UNION ALL SELECT 'Red Folder',               'Office Supplies & Stationery'
        UNION ALL SELECT 'Red Journal',              'Office Supplies & Stationery'
        UNION ALL SELECT 'Red Notebook',             'Office Supplies & Stationery') x
  JOIN Category c ON c.CategoryName = x.CategoryName;

INSERT INTO ItemVariant (ItemID, Gender, SizeCode)
SELECT i.ItemID, x.Gender, x.SizeCode
  FROM (          SELECT 'Red Igloo Cooler' AS ItemName, CAST(NULL AS CHAR(10)) AS Gender, CAST(NULL AS CHAR(10)) AS SizeCode
        UNION ALL SELECT 'UH Belt Buckle',           NULL,     NULL
        UNION ALL SELECT 'Umbrella',                 NULL,     NULL
        UNION ALL SELECT 'Red UH Tote Bag',          NULL,     NULL
        UNION ALL SELECT 'Black Can Yeti',           NULL,     NULL
        UNION ALL SELECT 'Red Plastic Water Bottle', NULL,     NULL
        UNION ALL SELECT 'Red Folder',               NULL,     NULL
        UNION ALL SELECT 'Red Journal',              NULL,     NULL
        UNION ALL SELECT 'Red Notebook',             NULL,     NULL
        UNION ALL SELECT 'Black Jacket',             NULL,     'XS'
        UNION ALL SELECT 'Black Jacket',             NULL,     'XXL'
        UNION ALL SELECT 'Black Jacket',             NULL,     'XXXL'
        UNION ALL SELECT 'Black Jacket',             'Ladies', 'L'
        UNION ALL SELECT 'Black Jacket',             'Ladies', 'S'
        UNION ALL SELECT 'Black Jacket',             'Males',  'M'
        UNION ALL SELECT 'Red UH Polo',              'Ladies', 'S'
        UNION ALL SELECT 'Red UH Polo',              'Ladies', 'M'
        UNION ALL SELECT 'Red UH Polo',              'Ladies', 'L'
        UNION ALL SELECT 'Red UH Polo',              'Ladies', 'XL'
        UNION ALL SELECT 'Red UH Polo',              'Ladies', 'XXL'
        UNION ALL SELECT 'Red UH Polo',              'Males',  'S'
        UNION ALL SELECT 'Red UH Polo',              'Males',  'M'
        UNION ALL SELECT 'Red UH Polo',              'Males',  'L'
        UNION ALL SELECT 'Red UH Polo',              'Males',  'XL'
        UNION ALL SELECT 'Red UH Polo',              'Males',  'XXL'
        UNION ALL SELECT 'UH Vest',                  NULL,     'S'
        UNION ALL SELECT 'UH Vest',                  NULL,     'M'
        UNION ALL SELECT 'UH Vest',                  NULL,     'L') x
  JOIN Item i ON i.ItemName = x.ItemName;

INSERT INTO InventoryBalance (VariantID)
SELECT v.VariantID FROM ItemVariant v
 WHERE NOT EXISTS (SELECT 1 FROM InventoryBalance b WHERE b.VariantID = v.VariantID);

SET @Admin = (SELECT UserID FROM AppUser WHERE Username = 'system');

SET @GRCat = (SELECT DistributionCategoryID FROM DistributionCategory WHERE CategoryName = 'Giveaway - Government Relations');
SET @ComboLines = (SELECT JSON_ARRAYAGG(JSON_OBJECT('VariantID', v.VariantID, 'Quantity', 1))
                     FROM ItemVariant v JOIN Item i ON i.ItemID = v.ItemID
                    WHERE i.ItemName IN ('Red UH Tote Bag', 'Black Can Yeti', 'Red Journal', 'Red Notebook'));

CALL usp_SaveGiveawayCombination('Standard Relationship Gift', @Admin, @ComboLines,
     'Tote, Yeti, Journal, Notebook - users may add/remove/change before submitting', @GRCat, @ComboID);

-- Starting inventory from the existing workbook. The physical recount replaces it
-- (usp_LoadOpeningCountsFromImport).
SET @CountedBy = (SELECT UserID FROM AppUser WHERE Username = 'system');

CALL usp_LoadOpeningCounts('[
  {"Item": "Red Igloo Cooler",                                 "Qty": 3},
  {"Item": "UH Belt Buckle",                                   "Qty": 64},
  {"Item": "Umbrella",                                         "Qty": 6},
  {"Item": "Black Jacket",                       "Size": "XS",   "Qty": 3},
  {"Item": "Black Jacket",                       "Size": "XXL",  "Qty": 2},
  {"Item": "Black Jacket",                       "Size": "XXXL", "Qty": 1},
  {"Item": "Black Jacket",   "Gender": "Ladies", "Size": "L",    "Qty": 1},
  {"Item": "Black Jacket",   "Gender": "Ladies", "Size": "S",    "Qty": 1},
  {"Item": "Black Jacket",   "Gender": "Males",  "Size": "M",    "Qty": 2},
  {"Item": "Red UH Polo",    "Gender": "Ladies", "Size": "L",    "Qty": 4},
  {"Item": "Red UH Polo",    "Gender": "Ladies", "Size": "M",    "Qty": 1},
  {"Item": "Red UH Polo",    "Gender": "Ladies", "Size": "S",    "Qty": 2},
  {"Item": "Red UH Polo",    "Gender": "Ladies", "Size": "XL",   "Qty": 4},
  {"Item": "Red UH Polo",    "Gender": "Ladies", "Size": "XXL",  "Qty": 3},
  {"Item": "Red UH Polo",    "Gender": "Males",  "Size": "L",    "Qty": 5},
  {"Item": "Red UH Polo",    "Gender": "Males",  "Size": "M",    "Qty": 3},
  {"Item": "Red UH Polo",    "Gender": "Males",  "Size": "S",    "Qty": 3},
  {"Item": "Red UH Polo",    "Gender": "Males",  "Size": "XL",   "Qty": 5},
  {"Item": "Red UH Polo",    "Gender": "Males",  "Size": "XXL",  "Qty": 2},
  {"Item": "UH Vest",                            "Size": "L",    "Qty": 4},
  {"Item": "UH Vest",                            "Size": "M",    "Qty": 4},
  {"Item": "UH Vest",                            "Size": "S",    "Qty": 3},
  {"Item": "Red UH Tote Bag",                                  "Qty": 186},
  {"Item": "Black Can Yeti",                                   "Qty": 23},
  {"Item": "Red Plastic Water Bottle",                         "Qty": 42},
  {"Item": "Red Folder",                                       "Qty": 496},
  {"Item": "Red Journal",                                      "Qty": 130},
  {"Item": "Red Notebook",                                     "Qty": 583}
]', @CountedBy);

UPDATE AppUser SET IsActive = FALSE WHERE IsSystemAccount;

SELECT * FROM vw_SetupStatus;

SELECT 'Part 4 complete: seed data and starting inventory loaded.' AS Status;

-- ---------------------------------------------------------------------
-- Part 5: Index maintenance
-- Run usp_IndexMaintenance(FALSE) weekly or after bulk loads; TRUE also rebuilds tables.
-- ---------------------------------------------------------------------
USE UH_GCR_Inventory;

DROP PROCEDURE IF EXISTS usp_IndexMaintenance;

DELIMITER $$

CREATE PROCEDURE usp_IndexMaintenance (
    IN p_Rebuild BOOLEAN
)
BEGIN
    DECLARE v_done  INT DEFAULT 0;
    DECLARE v_table VARCHAR(64);
    DECLARE cur CURSOR FOR
        SELECT TABLE_NAME FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
         ORDER BY TABLE_NAME;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur;
    tbl_loop: LOOP
        FETCH cur INTO v_table;
        IF v_done = 1 THEN LEAVE tbl_loop; END IF;

        SET @sql = CONCAT('ANALYZE TABLE `', v_table, '`');
        PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;

        IF COALESCE(p_Rebuild, FALSE) THEN
            SET @sql = CONCAT('OPTIMIZE TABLE `', v_table, '`');
            PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
        END IF;
    END LOOP;
    CLOSE cur;
END$$

DELIMITER ;

SELECT 'Part 5 complete: maintenance procedures created.' AS Status;

-- ---------------------------------------------------------------------
-- Part 6: Security and audit (WBS 4.9)
-- Every write procedure sets @app_user_id / @app_ctx while it runs. Triggers
-- use them to attribute changes; changes made outside the procedures are
-- logged with IsDirectEdit = TRUE and the MySQL account that made them.
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- Part 7: Database roles (no passwords; accounts are created by
-- scripts/create_db_accounts.sh)
--   gcr_app_role  svc_gcr_inventory  run procedures and read views only
--   gcr_dba_role  gcr_dba            maintenance and backups
-- ---------------------------------------------------------------------
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

SELECT 'Part 7 complete: roles and grants applied. BUILD FINISHED.' AS Status;
