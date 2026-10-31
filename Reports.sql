/* =====================================================================
   PART 4 : REPORTING VIEWS + 7 REPORT PROCEDURES
     1. Current Inventory        -> vw_CurrentInventory / usp_rpt_CurrentInventory
     2. Low Inventory / Restock  -> vw_LowInventory     / usp_rpt_LowInventory
     3. Inventory Usage          -> usp_rpt_InventoryUsage
     4. Inventory Value          -> vw_InventoryValue   / usp_rpt_InventoryValue
     5. Transaction History      -> vw_TransactionHistory / usp_rpt_TransactionHistory
     6. Giveaway / Relationship  -> usp_rpt_Giveaway
     7. Demand / Forecasting     -> usp_rpt_DemandForecast
   Deleted (reversed) transactions are excluded unless requested.
   Missing unit values stay NULL ("unknown") - never treated as $0.
   ===================================================================== */
USE UH_GCR_Inventory;

/* ---------- base view: one row per item variant ---------- */
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
       i.UnitValue,                                                  -- NULL = unknown
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

/* ---------- report 2 view: low inventory with open alert ---------- */
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

/* ---------- report 4 view: valued items only ---------- */
CREATE OR REPLACE VIEW vw_InventoryValue AS
SELECT CategoryID, CategoryName, ItemName, VariantLabel, VariantID, CurrentQuantity, UnitValue, TotalValue
  FROM vw_CurrentInventory
 WHERE UnitValue IS NOT NULL AND ItemIsActive AND VariantIsActive;

/* ---------- report 5 view: line-level transaction history ---------- */
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

/* ---------- support view: alert email queue for the application ---------- */
CREATE OR REPLACE VIEW vw_PendingAlertEmails AS
SELECT a.AlertID, a.AlertGeneratedAt,
       ci.CategoryName, ci.ItemName, ci.VariantLabel,
       ci.CurrentQuantity, ci.Setpoint,
       r.Recipients
  FROM InventoryAlert a
  JOIN vw_CurrentInventory ci ON ci.VariantID = a.VariantID
  CROSS JOIN (SELECT GROUP_CONCAT(ar.Email ORDER BY ar.RecipientSlot SEPARATOR ';') AS Recipients
                FROM AlertRecipient ar
                JOIN AlertConfiguration ac ON ac.AlertConfigurationID = ar.AlertConfigurationID
               WHERE ac.IsActive AND ar.IsActive) r
 WHERE a.AlertStatus = 'Pending';

/* ---------- support view: readable audit log ---------- */
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

/* REPORT 1 - CURRENT INVENTORY   (NULL category = all) */
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

/* REPORT 2 - LOW INVENTORY / RESTOCK */
CREATE PROCEDURE usp_rpt_LowInventory ()
BEGIN
    SELECT CategoryName, ItemName, VariantLabel, CurrentQuantity, Setpoint,
           UnitsBelowSetpoint, QtyToRestoreBaseline, StockStatus,
           AlertState, AlertGeneratedAt, EmailSentAt
      FROM vw_LowInventory
     ORDER BY (StockStatus <> 'Out of Stock'), UnitsBelowSetpoint DESC, ItemName;
END$$

/* REPORT 3 - INVENTORY USAGE (date range)
   RS1: by item/variant   RS2: by distribution category & recipient context */
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

/* REPORT 4 - INVENTORY VALUE (only items WITH a value are summed) */
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

/* REPORT 5 - TRANSACTION HISTORY   (all filters optional: pass NULL) */
CREATE PROCEDURE usp_rpt_TransactionHistory (
    IN p_StartDate       DATE,
    IN p_EndDate         DATE,
    IN p_TransactionType VARCHAR(3),     -- 'IN' | 'OUT' | NULL = both
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

/* REPORT 6 - GIVEAWAY / RELATIONSHIP GIFT
   RS1: one row per distribution, items given TOGETHER in one cell
   RS2: item pairs most often given together */
CREATE PROCEDURE usp_rpt_Giveaway (
    IN p_StartDate              DATE,
    IN p_EndDate                DATE,
    IN p_DistributionCategoryID INT,
    IN p_RecipientContextID     INT,
    IN p_GiveawayOnly           BOOLEAN,     -- TRUE = only IsGiveaway categories
    IN p_MultiItemOnly          BOOLEAN      -- TRUE = only distributions with 2+ items
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

/* REPORT 7 - DEMAND / FORECASTING  (NULLs default to 180 / 90 days) */
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

SELECT 'Part 4 complete: reports created.' AS Status;