/* =====================================================================
   PART 5 : SEED / REFERENCE DATA + GO-LIVE OPENING COUNTS
   >>> Replace every value marked  -- REPLACE  before go-live. <<<
   ===================================================================== */
USE UH_GCR_Inventory;
SET SQL_SAFE_UPDATES = 0;

/* ---------- Users (uniform access; UserType is descriptive only) ---------- */
INSERT INTO AppUser (Username, FirstName, LastName, Email, UserType) VALUES
 ('gcr.admin',    'GCR',     'Administrator', 'gcr.admin@example.edu',    'Full-Time Staff'),   -- REPLACE
 ('gcr.staff1',   'Staff',   'Member',        'gcr.staff1@example.edu',   'Full-Time Staff'),   -- REPLACE
 ('gcr.student1', 'Student', 'Worker',        'gcr.student1@example.edu', 'Student Worker'),    -- REPLACE
 ('gcr.intern1',  'Student', 'Intern',        'gcr.intern1@example.edu',  'Student Intern');    -- REPLACE

/* ---------- Merchandise categories ---------- */
INSERT INTO Category (CategoryName, Description) VALUES
 ('Accessories & Gear',           'Coolers, belt buckles, umbrellas and similar gear'),
 ('Apparel',                      'Jackets, polos, vests - tracked by gender and/or size'),
 ('Bags & Totes',                 'Tote bags and carry items'),
 ('Drinkware',                    'Tumblers, bottles, can coolers'),
 ('Office Supplies & Stationery', 'Folders, journals, notebooks, pens');

/* ---------- Sizes (sort order drives report ordering) ---------- */
INSERT INTO Size (SizeCode, SizeName, SortOrder) VALUES
 ('XS', 'Extra Small', 1), ('S', 'Small', 2), ('M', 'Medium', 3), ('L', 'Large', 4),
 ('XL', 'Extra Large', 5), ('XXL', '2X Large', 6), ('XXXL', '3X Large', 7);

/* ---------- Distribution categories (Stock Out reason) ---------- */
INSERT INTO DistributionCategory (CategoryName, Description, IsGiveaway) VALUES
 ('Community Event / Donation',      'Community events, outreach activities, donations, community-facing purposes', FALSE),
 ('Giveaway - Government Relations', 'Relationship-building gifts/giveaways for government relations activities',   TRUE),
 ('Giveaway - Community Relations',  'Relationship-building gifts/giveaways for community relations activities',    TRUE),
 ('Internal Staff',                  'Merchandise provided for internal office/staff purposes',                     FALSE),
 ('Other / Inventory Adjustment',    'Damaged, lost, or count-correction removals (explain in Notes)',              FALSE);

/* ---------- Recipient context ---------- */
INSERT INTO RecipientContext (ContextName, Description) VALUES
 ('External',               'Recipient outside the University of Houston'),
 ('In-Network / Within UH', 'UH employee, department, or other UH entity outside Government & Community Relations'),
 ('Not Applicable',         'No recipient (e.g., damaged/lost inventory adjustment)');

/* ---------- Event / purpose ---------- */
INSERT INTO EventPurpose (PurposeName) VALUES
 ('Conference'), ('Meeting'), ('Community Outreach'), ('Government Relations Event'),
 ('Government Relations Meeting'), ('Internal Use'), ('Donation'), ('Other');

/* ---------- Item catalog (from reviewed workbook; UnitValue left NULL = unknown) ---------- */
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

/* ---------- Variants (independently tracked units) ---------- */
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

/* every variant gets a balance row (qty 0, setpoint 0 until the opening count) */
INSERT INTO InventoryBalance (VariantID)
SELECT v.VariantID FROM ItemVariant v
 WHERE NOT EXISTS (SELECT 1 FROM InventoryBalance b WHERE b.VariantID = v.VariantID);

/* ---------- Low-inventory alert recipients (1-3, configurable) ---------- */
SET @Admin = (SELECT UserID FROM AppUser WHERE Username = 'gcr.admin');

CALL usp_SetAlertRecipients('[
  {"Slot": 1, "Name": "Project Sponsor",  "Email": "sponsor@example.edu"},
  {"Slot": 2, "Name": "Office Manager",   "Email": "office.manager@example.edu"},
  {"Slot": 3, "Name": "Inventory Backup", "Email": "inventory.backup@example.edu"}
]', @Admin);   -- REPLACE emails (1 to 3 entries allowed)

/* ---------- Sample Common Giveaway Combination (template = convenience only) ---------- */
SET @GRCat = (SELECT DistributionCategoryID FROM DistributionCategory WHERE CategoryName = 'Giveaway - Government Relations');
SET @ComboLines = (SELECT JSON_ARRAYAGG(JSON_OBJECT('VariantID', v.VariantID, 'Quantity', 1))
                     FROM ItemVariant v JOIN Item i ON i.ItemID = v.ItemID
                    WHERE i.ItemName IN ('Red UH Tote Bag', 'Black Can Yeti', 'Red Journal', 'Red Notebook'));

CALL usp_SaveGiveawayCombination('Standard Relationship Gift', @Admin, @ComboLines,
     'Tote, Yeti, Journal, Notebook - users may add/remove/change before submitting', @GRCat, @ComboID);

/* =====================================================================
   GO-LIVE OPENING BALANCES
   The quantities below are the OLD WORKBOOK values used only as
   PLACEHOLDER/TEST data - overwrite "Qty" with the physical recount.
   ===================================================================== */
SET @CountedBy = (SELECT UserID FROM AppUser WHERE Username = 'gcr.admin');   -- REPLACE with counter

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

/* Review: opening balance, suggested setpoint and status per variant */
SELECT CategoryName, ItemName, VariantLabel, BaselineQuantity, CurrentQuantity,
       SuggestedSetpoint, Setpoint, StockStatus
  FROM vw_CurrentInventory
 ORDER BY CategoryName, ItemName, Gender, SizeSortOrder;

SELECT 'Part 5 complete: seed data and opening balances loaded.' AS Status;