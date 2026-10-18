/* =====================================================================
   UH Government & Community Relations - Inventory Management System
   Dfyne Innovations | CIS 4375 | Fall 2026
   PART 1 : DATABASE + TABLES + CONSTRAINTS + INDEXES + TRIGGERS
   Platform: MySQL 8.0.16+  (run in MySQL Workbench)
   WARNING : Part 1 DROPS and recreates the database (clean rebuild).
   ===================================================================== */

SET SQL_SAFE_UPDATES = 0;   -- Workbench "safe updates" blocks some set-based UPDATEs
DROP DATABASE IF EXISTS UH_GCR_Inventory;
CREATE DATABASE UH_GCR_Inventory CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE UH_GCR_Inventory;

/* =====================================================================
   1. USERS  (uniform access - no permission tiers by design)
   ===================================================================== */
CREATE TABLE AppUser (
    UserID      INT          NOT NULL AUTO_INCREMENT,
    Username    VARCHAR(50)  NOT NULL,                -- CougarNet ID / login
    FirstName   VARCHAR(50)  NOT NULL,
    LastName    VARCHAR(50)  NOT NULL,
    Email       VARCHAR(254) NOT NULL,
    UserType    VARCHAR(30)  NOT NULL,                -- descriptive only, NOT a permission tier
    IsActive    BOOLEAN      NOT NULL DEFAULT TRUE,
    CreatedAt   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT PK_AppUser          PRIMARY KEY (UserID),
    CONSTRAINT UQ_AppUser_Username UNIQUE (Username),
    CONSTRAINT UQ_AppUser_Email    UNIQUE (Email),
    CONSTRAINT CK_AppUser_Email    CHECK (Email LIKE '%_@_%._%'),
    CONSTRAINT CK_AppUser_Names    CHECK (CHAR_LENGTH(TRIM(FirstName)) > 0 AND CHAR_LENGTH(TRIM(LastName)) > 0),
    CONSTRAINT CK_AppUser_UserType CHECK (UserType IN ('Full-Time Staff', 'Student Worker',
                                                      'Student Intern', 'Other Authorized'))
) ENGINE = InnoDB;

/* =====================================================================
   2. LOOKUP / CONTROLLED-VALUE TABLES
   ===================================================================== */
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
    SizeCode   VARCHAR(10) NOT NULL,                  -- XS, S, M, L, XL, XXL, XXXL
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
    ContextName        VARCHAR(50)  NOT NULL,         -- External | In-Network / Within UH | Not Applicable
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

/* =====================================================================
   3. MERCHANDISE: Item (definition) -> ItemVariant (tracked unit)
                   -> InventoryBalance (current state, 1:1 with variant)
   ===================================================================== */
CREATE TABLE Item (
    ItemID       INT           NOT NULL AUTO_INCREMENT,
    ItemName     VARCHAR(100)  NOT NULL,
    CategoryID   INT           NOT NULL,
    Description  VARCHAR(255)  NULL,
    UnitValue    DECIMAL(10,2) NULL,                  -- OPTIONAL. NULL = unknown (not the same as $0.00)
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
    Gender     VARCHAR(10) NULL,                      -- Ladies | Males | Unisex | NULL (n/a)
    SizeCode   VARCHAR(10) NULL,                      -- FK to Size | NULL (n/a)
    IsActive   BOOLEAN     NOT NULL DEFAULT TRUE,
    CreatedAt  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- MySQL UNIQUE allows repeated NULLs, so uniqueness uses NULL-safe keys
    GenderKey  VARCHAR(10) AS (COALESCE(Gender, ''))   STORED,
    SizeKey    VARCHAR(10) AS (COALESCE(SizeCode, '')) STORED,
    CONSTRAINT PK_ItemVariant        PRIMARY KEY (VariantID),
    CONSTRAINT FK_ItemVariant_Item   FOREIGN KEY (ItemID)   REFERENCES Item (ItemID),
    CONSTRAINT FK_ItemVariant_Size   FOREIGN KEY (SizeCode) REFERENCES Size (SizeCode),
    CONSTRAINT CK_ItemVariant_Gender CHECK (Gender IS NULL OR Gender IN ('Ladies', 'Males', 'Unisex')),
    CONSTRAINT UQ_ItemVariant        UNIQUE (ItemID, GenderKey, SizeKey)
) ENGINE = InnoDB;

CREATE TABLE InventoryBalance (
    VariantID          INT      NOT NULL,
    CurrentQuantity    INT      NOT NULL DEFAULT 0,
    BaselineQuantity   INT      NULL,                 -- verified physical count at go-live (NULL = not yet counted)
    BaselineCountedAt  DATETIME NULL,
    -- Suggested setpoint = ~40% of verified baseline, rounded, minimum 1 when baseline > 0
    SuggestedSetpoint  INT AS (CASE WHEN BaselineQuantity IS NULL THEN NULL
                                    WHEN BaselineQuantity = 0     THEN 0
                                    ELSE GREATEST(1, ROUND(BaselineQuantity * 0.40)) END) STORED,
    Setpoint           INT      NOT NULL DEFAULT 0,   -- STORED threshold
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

/* =====================================================================
   4. COMMON GIVEAWAY COMBINATION (optional data-entry template)
   ===================================================================== */
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

/* =====================================================================
   5. INVENTORY TRANSACTION (header) + TRANSACTION LINE (detail)
   ===================================================================== */
CREATE TABLE InventoryTransaction (
    TransactionID          INT           NOT NULL AUTO_INCREMENT,
    TransactionDate        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UserID                 INT           NOT NULL,
    TransactionType        VARCHAR(3)    NOT NULL,     -- 'IN' | 'OUT'
    StockInReason          VARCHAR(20)   NULL,         -- IN only
    DistributionCategoryID INT           NULL,         -- OUT only (required)
    RecipientContextID     INT           NULL,         -- OUT only (required)
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
    -- Stock Out MUST have distribution category + recipient context; Stock In must not
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
    UnitValueAtTransaction DECIMAL(10,2) NULL,         -- snapshot of Item.UnitValue (NULL = unknown)
    LineValue              DECIMAL(14,2) AS (Quantity * UnitValueAtTransaction) VIRTUAL,
    CONSTRAINT PK_TransactionLine     PRIMARY KEY (TransactionLineID),
    CONSTRAINT FK_TxnLine_Transaction FOREIGN KEY (TransactionID) REFERENCES InventoryTransaction (TransactionID),
    CONSTRAINT FK_TxnLine_Variant     FOREIGN KEY (VariantID)     REFERENCES ItemVariant (VariantID),
    CONSTRAINT UQ_TxnLine_TxnVariant  UNIQUE (TransactionID, VariantID),
    CONSTRAINT CK_TxnLine_Quantity    CHECK (Quantity > 0),
    CONSTRAINT CK_TxnLine_UnitValue   CHECK (UnitValueAtTransaction IS NULL OR UnitValueAtTransaction >= 0)
) ENGINE = InnoDB;

/* =====================================================================
   6. ALERT CONFIGURATION (max 3 recipients) + INVENTORY ALERT
   ===================================================================== */
CREATE TABLE AlertConfiguration (
    AlertConfigurationID INT          NOT NULL AUTO_INCREMENT,
    ConfigurationName    VARCHAR(100) NOT NULL,
    IsActive             BOOLEAN      NOT NULL DEFAULT TRUE,
    UpdatedAt            DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UpdatedByUserID      INT          NULL,
    ActiveKey            TINYINT AS (CASE WHEN IsActive THEN 1 END) STORED,   -- only ONE active config
    CONSTRAINT PK_AlertConfiguration      PRIMARY KEY (AlertConfigurationID),
    CONSTRAINT UQ_AlertConfiguration_Name UNIQUE (ConfigurationName),
    CONSTRAINT UQ_AlertConfiguration_OneActive UNIQUE (ActiveKey),
    CONSTRAINT FK_AlertCfg_User           FOREIGN KEY (UpdatedByUserID) REFERENCES AppUser (UserID)
) ENGINE = InnoDB;

CREATE TABLE AlertRecipient (
    AlertRecipientID     INT          NOT NULL AUTO_INCREMENT,
    AlertConfigurationID INT          NOT NULL,
    RecipientSlot        TINYINT      NOT NULL,       -- 1, 2, 3 -> hard cap of three recipients
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
    TriggeringTransactionID INT           NULL,       -- NULL when a setpoint change triggered it
    AlertConfigurationID    INT           NULL,
    AlertGeneratedAt        DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    QuantityAtAlert         INT           NOT NULL,
    SetpointAtAlert         INT           NOT NULL,
    AlertStatus             VARCHAR(10)   NOT NULL DEFAULT 'Pending',
    EmailSentAt             DATETIME      NULL,
    RecipientsNotified      VARCHAR(800)  NULL,
    LastSendError           VARCHAR(1000) NULL,
    ResolvedAt              DATETIME      NULL,
    -- only ONE open (Pending/Sent) alert per variant -> no duplicate emails
    OpenVariantKey          INT AS (CASE WHEN AlertStatus IN ('Pending', 'Sent') THEN VariantID END) STORED,
    CONSTRAINT PK_InventoryAlert        PRIMARY KEY (AlertID),
    CONSTRAINT FK_InvAlert_Variant      FOREIGN KEY (VariantID)               REFERENCES ItemVariant (VariantID),
    CONSTRAINT FK_InvAlert_Transaction  FOREIGN KEY (TriggeringTransactionID) REFERENCES InventoryTransaction (TransactionID),
    CONSTRAINT FK_InvAlert_Config       FOREIGN KEY (AlertConfigurationID)    REFERENCES AlertConfiguration (AlertConfigurationID),
    CONSTRAINT UQ_InventoryAlert_OpenPerVariant UNIQUE (OpenVariantKey),
    CONSTRAINT CK_InvAlert_Status       CHECK (AlertStatus IN ('Pending', 'Sent', 'Resolved')),
    CONSTRAINT CK_InvAlert_Qty          CHECK (QuantityAtAlert >= 0 AND SetpointAtAlert >= 0)
) ENGINE = InnoDB;

/* =====================================================================
   6b. TRANSACTION AUDIT (append-only)
   ===================================================================== */
CREATE TABLE TransactionAudit (
    AuditID         INT          NOT NULL AUTO_INCREMENT,
    TransactionID   INT          NOT NULL,
    AuditAction     VARCHAR(10)  NOT NULL,            -- Created | Deleted
    AuditAt         DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    AuditByUserID   INT          NOT NULL,
    TransactionType VARCHAR(3)   NOT NULL,            -- IN | OUT
    LineCount       INT          NOT NULL,
    TotalUnits      INT          NOT NULL,
    InventoryEffect VARCHAR(10)  NOT NULL,            -- Added | Removed
    Reason          VARCHAR(255) NULL,
    LineDetail      JSON         NULL,                -- per line: VariantID, Item, Gender, Size, Qty, QtyBefore, QtyAfter
    CONSTRAINT PK_TransactionAudit     PRIMARY KEY (AuditID),
    CONSTRAINT FK_TxnAudit_Transaction FOREIGN KEY (TransactionID) REFERENCES InventoryTransaction (TransactionID),
    CONSTRAINT FK_TxnAudit_User        FOREIGN KEY (AuditByUserID) REFERENCES AppUser (UserID),
    CONSTRAINT CK_TxnAudit_Action      CHECK (AuditAction IN ('Created', 'Deleted')),
    CONSTRAINT CK_TxnAudit_Type        CHECK (TransactionType IN ('IN', 'OUT')),
    CONSTRAINT CK_TxnAudit_Effect      CHECK (InventoryEffect IN ('Added', 'Removed')),
    CONSTRAINT CK_TxnAudit_Counts      CHECK (LineCount > 0 AND TotalUnits > 0)
) ENGINE = InnoDB;

/* =====================================================================
   7. PERFORMANCE INDEXES (FK columns are auto-indexed by InnoDB)
   ===================================================================== */
CREATE INDEX IX_InvTxn_Date        ON InventoryTransaction (TransactionDate, TransactionType, IsDeleted);
CREATE INDEX IX_TxnLine_VariantQty ON TransactionLine (VariantID, Quantity, TransactionID);
CREATE INDEX IX_InvAlert_Status    ON InventoryAlert (AlertStatus, VariantID, AlertGeneratedAt);
CREATE INDEX IX_TxnAudit_AuditAt   ON TransactionAudit (AuditAt, AuditAction, TransactionType);

/* =====================================================================
   8. TRIGGERS
   ===================================================================== */
DELIMITER $$

-- Hard DELETEs bypass inventory reversal -> blocked; use usp_DeleteTransaction
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

-- Audit log is append-only
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

/* LOW-STOCK ALERT TRIGGER (WBS 5.7)
   CurrentQuantity <= Setpoint and no open alert -> new Pending alert
   CurrentQuantity >  Setpoint and an open alert -> mark Resolved     */
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