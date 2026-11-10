const fs = require('fs');
const {
  Document, Packer, Paragraph, TextRun, Table, TableRow, TableCell, WidthType, ShadingType,
  HeadingLevel, AlignmentType, PageOrientation, BorderStyle, Footer, Header, PageNumber,
  LevelFormat, TableOfContents, PageBreak
} = require('docx');

const RED = 'C8102E', DARK = '333333', LIGHT = 'F7E6E9', GRID = 'BFBFBF';
const FONT = 'Arial';

// ---------- column data: [Column, Data Type, Key, Null, Default, Constraints/Rules, Description]
const tables = [
  { group: 'Users', name: 'AppUser', entity: 'User',
    purpose: 'Authorized Government & Community Relations personnel who submit or correct inventory transactions. All users share the same access level; UserType is descriptive only and does not grant permissions.',
    cols: [
      ['UserID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique, system-generated', 'Unique identifier for each authorized user.'],
      ['Username', 'VARCHAR(50)', 'UQ', 'N', '—', 'Unique', 'Login / CougarNet ID used to identify the user.'],
      ['FirstName', 'VARCHAR(50)', '', 'N', '—', 'Cannot be blank', 'User’s first name.'],
      ['LastName', 'VARCHAR(50)', '', 'N', '—', 'Cannot be blank', 'User’s last name.'],
      ['Email', 'VARCHAR(254)', 'UQ', 'N', '—', 'Unique; must match pattern x@x.x', 'User’s email address.'],
      ['UserType', 'VARCHAR(30)', '', 'N', '—', 'Full-Time Staff | Student Worker | Student Intern | Other Authorized', 'Describes the user’s role in the office (reporting only, not a permission tier).'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Removed staff drop off the “Who are you?” picker and cannot submit new transactions; their history is kept.'],
      ['IsSystemAccount', 'BOOLEAN', '', 'N', 'FALSE', 'TRUE only for the build-script account', 'Marks the account that owns seed data; it is deactivated after the build and hidden from the Staff tab.'],
      ['CreatedAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time the user record was created.'],
      ['CreatedByUserID', 'INT', 'FK → AppUser', 'Y', 'NULL', 'Optional', 'Staff member who added this person in the app’s Staff tab.'],
    ]},
  { group: 'Lookups', name: 'Category', entity: 'Category',
    purpose: 'Controlled list of merchandise categories used to group items and filter reports.',
    cols: [
      ['CategoryID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the category.'],
      ['CategoryName', 'VARCHAR(100)', 'UQ', 'N', '—', 'Unique; cannot be blank', 'Category name (e.g., Apparel, Drinkware).'],
      ['Description', 'VARCHAR(255)', '', 'Y', '—', '', 'Optional description of what the category contains.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Whether the category can be assigned to new items.'],
    ]},
  { group: 'Lookups', name: 'Size', entity: 'Item Variant (supporting)',
    purpose: 'Controlled list of apparel sizes. SortOrder keeps reports in logical size order (XS → XXXL) rather than alphabetical.',
    cols: [
      ['SizeCode', 'VARCHAR(10)', 'PK', 'N', '—', 'Unique', 'Size abbreviation (XS, S, M, L, XL, XXL, XXXL).'],
      ['SizeName', 'VARCHAR(30)', '', 'N', '—', '', 'Full size name (e.g., Extra Large).'],
      ['SortOrder', 'TINYINT', 'UQ', 'N', '—', 'Unique', 'Display/report order, smallest to largest.'],
    ]},
  { group: 'Lookups', name: 'DistributionCategory', entity: 'Distribution Category',
    purpose: 'The business reason for a Stock Out (why merchandise left inventory).',
    cols: [
      ['DistributionCategoryID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the distribution category.'],
      ['CategoryName', 'VARCHAR(100)', 'UQ', 'N', '—', 'Unique', 'Category name (e.g., Giveaway – Government Relations).'],
      ['Description', 'VARCHAR(255)', '', 'Y', '—', '', 'Meaning of the category.'],
      ['IsGiveaway', 'BOOLEAN', '', 'N', 'FALSE', 'TRUE or FALSE', 'Flags relationship-gift categories so the Giveaway report can filter to them.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Whether the category is selectable on new Stock Outs.'],
    ]},
  { group: 'Lookups', name: 'RecipientContext', entity: 'Recipient Context',
    purpose: 'Identifies whether a distribution went to an external recipient or stayed in-network within UH, without creating separate inventory items.',
    cols: [
      ['RecipientContextID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the recipient context.'],
      ['ContextName', 'VARCHAR(50)', 'UQ', 'N', '—', 'Unique', 'External | In-Network / Within UH | Not Applicable.'],
      ['Description', 'VARCHAR(255)', '', 'Y', '—', '', 'Meaning of the context.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Whether the context is selectable on new Stock Outs.'],
    ]},
  { group: 'Lookups', name: 'EventPurpose', entity: 'Event / Purpose detail',
    purpose: 'Controlled list of event or purpose types recorded on a transaction. Free-text detail is stored separately in InventoryTransaction.EventDetails.',
    cols: [
      ['EventPurposeID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the event/purpose.'],
      ['PurposeName', 'VARCHAR(100)', 'UQ', 'N', '—', 'Unique', 'Purpose name (Conference, Meeting, Community Outreach, Donation, etc.).'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Whether the purpose is selectable on new transactions.'],
    ]},
  { group: 'Merchandise', name: 'Item', entity: 'Item',
    purpose: 'The merchandise definition: what the item is, its category, and its optional unit value. Quantities are tracked per variant in InventoryBalance.',
    cols: [
      ['ItemID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique Item ID for each merchandise record.'],
      ['ItemName', 'VARCHAR(100)', 'UQ', 'N', '—', 'Unique; cannot be blank', 'Merchandise name (e.g., Red UH Tote Bag).'],
      ['CategoryID', 'INT', 'FK → Category', 'N', '—', 'Must reference an existing category', 'Category the item belongs to.'],
      ['Description', 'VARCHAR(255)', '', 'Y', '—', '', 'Optional item description.'],
      ['UnitValue', 'DECIMAL(10,2)', '', 'Y', 'NULL', '≥ 0 when provided', 'Optional monetary value per unit. NULL means unknown, which is different from $0.00.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Inactive items are hidden from new transactions; historical transactions remain reportable.'],
      ['CreatedAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time the item was added.'],
      ['UpdatedAt', 'DATETIME', '', 'Y', '—', '', 'Date/time the item was last edited.'],
      ['ModifiedByUserID', 'INT', 'FK → AppUser', 'Y', '—', 'Set by trigger', 'Staff member who last changed the item (NULL if changed outside the app).'],
    ]},
  { group: 'Merchandise', name: 'ItemVariant', entity: 'Item Variant',
    purpose: 'Each independently tracked version of an item (by gender and/or size). Items without sizes have one “Standard” variant with Gender and SizeCode left NULL.',
    unique: 'UNIQUE (ItemID, GenderKey, SizeKey) — an item cannot have the same gender/size combination twice, including the NULL Standard variant.',
    cols: [
      ['VariantID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the stock-keeping unit. Transactions reference this column.'],
      ['ItemID', 'INT', 'FK → Item', 'N', '—', 'Must reference an existing item', 'The item this variant belongs to.'],
      ['Gender', 'VARCHAR(10)', '', 'Y', 'NULL', 'Ladies | Males | Unisex | NULL', 'Gender cut for apparel; NULL when not applicable.'],
      ['SizeCode', 'VARCHAR(10)', 'FK → Size', 'Y', 'NULL', 'Must reference Size when provided', 'Size for apparel; NULL when not applicable.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Inactive variants are hidden from new transactions.'],
      ['CreatedAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time the variant was added.'],
      ['GenderKey', 'VARCHAR(10) (generated, stored)', 'UQ (part)', 'N', 'Calculated', 'COALESCE(Gender, \'\')', 'Blank-for-NULL copy of Gender used in the unique key (MySQL UNIQUE allows repeated NULLs).'],
      ['SizeKey', 'VARCHAR(10) (generated, stored)', 'UQ (part)', 'N', 'Calculated', 'COALESCE(SizeCode, \'\')', 'Blank-for-NULL copy of SizeCode used in the unique key.'],
    ]},
  { group: 'Merchandise', name: 'InventoryBalance', entity: 'Item (current quantity + setpoint)',
    purpose: 'Current-state inventory for each variant (1:1 with ItemVariant). Kept separate from the merchandise definition and from the transaction history that explains how the quantity changed.',
    unique: 'TRIGGER trg_InventoryBalance_LowStockAlert (AFTER UPDATE): whenever CurrentQuantity, Setpoint or BaselineQuantity changes, it creates a Pending InventoryAlert if CurrentQuantity ≤ Setpoint, or resolves the open alert once stock is back above the setpoint.',
    cols: [
      ['VariantID', 'INT', 'PK, FK → ItemVariant', 'N', '—', 'One row per variant', 'The variant whose balance this row holds.'],
      ['CurrentQuantity', 'INT', '', 'N', '0', '≥ 0 (cannot go negative)', 'Units on hand now. Changed only by Stock In / Stock Out transactions.'],
      ['BaselineQuantity', 'INT', '', 'Y', 'NULL', '≥ 0 when provided', 'Verified physical recount entered at go-live. NULL until counted.'],
      ['BaselineCountedAt', 'DATETIME', '', 'Y', '—', '', 'Date/time of the verified recount.'],
      ['SuggestedSetpoint', 'INT (generated, stored)', '', 'Y', 'Calculated', 'ROUND(Baseline × 0.40); minimum 1 when baseline > 0', 'System-suggested restock threshold based on the verified baseline.'],
      ['Setpoint', 'INT', '', 'N', '0', '≥ 0', 'Stored low-stock threshold. An alert is generated when CurrentQuantity ≤ Setpoint. Does not change when stock is replenished.'],
      ['SetpointIsManual', 'BOOLEAN', '', 'N', 'FALSE', 'TRUE or FALSE', 'TRUE when a user overrode the suggested setpoint.'],
      ['SetpointUpdatedAt', 'DATETIME', '', 'Y', '—', '', 'Date/time the setpoint was last set.'],
      ['SetpointUpdatedBy', 'INT', 'FK → AppUser', 'Y', '—', '', 'User who last set the setpoint.'],
      ['LastMovementAt', 'DATETIME', '', 'Y', '—', '', 'Date/time of the most recent stock movement.'],
    ]},
  { group: 'Giveaway Templates', name: 'GiveawayCombination', entity: 'Common Giveaway Combination',
    purpose: 'Optional reusable template of commonly distributed items. A convenience for data entry only; users can add, remove or change items before submitting.',
    cols: [
      ['CombinationID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the template.'],
      ['CombinationName', 'VARCHAR(100)', 'UQ', 'N', '—', 'Unique', 'Template name (e.g., Standard Relationship Gift).'],
      ['Description', 'VARCHAR(255)', '', 'Y', '—', '', 'Optional description of when the template is used.'],
      ['DefaultDistributionCategoryID', 'INT', 'FK → DistributionCategory', 'Y', '—', '', 'Category pre-selected when the template is loaded.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Whether the template appears in the entry form.'],
      ['CreatedByUserID', 'INT', 'FK → AppUser', 'N', '—', '', 'User who created the template.'],
      ['CreatedAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time the template was created.'],
    ]},
  { group: 'Giveaway Templates', name: 'GiveawayCombinationLine', entity: 'Common Giveaway Combination Line',
    purpose: 'Items and suggested quantities in a giveaway template. A saved template must contain at least one line (enforced by usp_SaveGiveawayCombination).',
    unique: 'UNIQUE (CombinationID, VariantID) — an item appears once per template. Lines are deleted automatically with their template (ON DELETE CASCADE).',
    cols: [
      ['CombinationLineID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the template line.'],
      ['CombinationID', 'INT', 'FK → GiveawayCombination', 'N', '—', 'Cascade delete', 'The template this line belongs to.'],
      ['VariantID', 'INT', 'FK → ItemVariant', 'N', '—', '', 'Item variant suggested in the template.'],
      ['SuggestedQuantity', 'INT', '', 'N', '1', '> 0', 'Default quantity; the user may change it before submitting.'],
    ]},
  { group: 'Transactions', name: 'InventoryTransaction', entity: 'Inventory Transaction',
    purpose: 'Header record for one Stock In or Stock Out event. A single-item entry and a multi-item giveaway both use one header with one or more lines.',
    unique: 'CHECK: a Stock Out must have DistributionCategoryID and RecipientContextID and no StockInReason; a Stock In must have a StockInReason and no category or context. CHECK: IsDeleted = 1 requires DeletedAt and DeletedByUserID. Direct DELETE is blocked by trigger; use usp_DeleteTransaction.',
    cols: [
      ['TransactionID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique transaction (distribution) number.'],
      ['TransactionDate', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time of the transaction.'],
      ['UserID', 'INT', 'FK → AppUser', 'N', '—', 'Must be an active user', 'Authorized user who submitted the transaction.'],
      ['TransactionType', 'VARCHAR(3)', '', 'N', '—', 'IN | OUT', 'Stock In increases inventory; Stock Out decreases it.'],
      ['StockInReason', 'VARCHAR(20)', '', 'Y', '—', 'Opening Balance | Received | Returned | Adjustment; required for IN, NULL for OUT', 'Why stock was added.'],
      ['DistributionCategoryID', 'INT', 'FK → DistributionCategory', 'Y', '—', 'Required for OUT, NULL for IN', 'Business reason for the distribution.'],
      ['RecipientContextID', 'INT', 'FK → RecipientContext', 'Y', '—', 'Required for OUT, NULL for IN', 'External vs. In-Network / Within UH.'],
      ['EventPurposeID', 'INT', 'FK → EventPurpose', 'Y', '—', '', 'Type of event or purpose.'],
      ['EventDetails', 'VARCHAR(255)', '', 'Y', '—', '', 'Free-text event/purpose detail (e.g., Government Relations Meeting with county officials).'],
      ['RecipientName', 'VARCHAR(150)', '', 'Y', '—', '', 'Optional recipient person, organization or UH department.'],
      ['CombinationID', 'INT', 'FK → GiveawayCombination', 'Y', '—', '', 'Template used to pre-fill the entry, if any.'],
      ['Notes', 'VARCHAR(1000)', '', 'Y', '—', '', 'Optional notes.'],
      ['IsDeleted', 'BOOLEAN', '', 'N', 'FALSE', 'TRUE or FALSE', 'TRUE when the transaction was deleted as erroneous and its inventory effect reversed. Excluded from reports by default.'],
      ['DeletedAt', 'DATETIME', '', 'Y', '—', 'Required when IsDeleted = TRUE', 'Date/time of deletion.'],
      ['DeletedByUserID', 'INT', 'FK → AppUser', 'Y', '—', 'Required when IsDeleted = TRUE', 'User who deleted the transaction.'],
      ['DeleteReason', 'VARCHAR(255)', '', 'Y', '—', '', 'Why the transaction was deleted.'],
    ]},
  { group: 'Transactions', name: 'TransactionLine', entity: 'Transaction Line',
    purpose: 'Each item and quantity affected by a transaction. Lets one distribution contain many items and one item appear on many distributions.',
    unique: 'UNIQUE (TransactionID, VariantID) — an item appears once per transaction. Direct DELETE is blocked by trigger.',
    cols: [
      ['TransactionLineID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the line.'],
      ['TransactionID', 'INT', 'FK → InventoryTransaction', 'N', '—', '', 'Transaction header this line belongs to.'],
      ['VariantID', 'INT', 'FK → ItemVariant', 'N', '—', 'Must be active for new transactions', 'Item variant moved.'],
      ['Quantity', 'INT', '', 'N', '—', 'Whole number > 0; OUT cannot exceed available stock', 'Units added or removed.'],
      ['UnitValueAtTransaction', 'DECIMAL(10,2)', '', 'Y', 'From Item.UnitValue', '≥ 0 when provided', 'Snapshot of the unit value at the time of the transaction, so later price changes don’t alter history.'],
      ['LineValue', 'DECIMAL(14,2) (generated, virtual)', '', 'Y', 'Calculated', 'Quantity × UnitValueAtTransaction', 'Value of the line; NULL when the unit value is unknown.'],
    ]},
  { group: 'Alerts', name: 'AlertConfiguration', entity: 'Alert Configuration',
    purpose: 'Settings for low-inventory email alerts. Only one configuration can be active at a time (unique ActiveKey).',
    cols: [
      ['AlertConfigurationID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the configuration.'],
      ['ConfigurationName', 'VARCHAR(100)', 'UQ', 'N', '—', 'Unique', 'Configuration name.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'Only one row may be TRUE', 'Marks the configuration currently in use.'],
      ['UpdatedAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time the configuration was last changed.'],
      ['UpdatedByUserID', 'INT', 'FK → AppUser', 'Y', '—', '', 'User who last changed the configuration.'],
      ['ActiveKey', 'TINYINT (generated, stored)', 'UQ', 'Y', 'Calculated', '1 when IsActive, else NULL', 'Unique key that allows only one active configuration.'],
    ]},
  { group: 'Alerts', name: 'AlertRecipient', entity: 'Alert Configuration (recipients)',
    purpose: 'Email addresses that receive low-inventory alerts. RecipientSlot (1–3) caps the list at three configurable recipients.',
    unique: 'UNIQUE (AlertConfigurationID, RecipientSlot) and UNIQUE (AlertConfigurationID, Email). Rows are deleted with their configuration (ON DELETE CASCADE).',
    cols: [
      ['AlertRecipientID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the recipient.'],
      ['AlertConfigurationID', 'INT', 'FK → AlertConfiguration', 'N', '—', 'Cascade delete', 'Configuration the recipient belongs to.'],
      ['RecipientSlot', 'TINYINT', '', 'N', '—', 'BETWEEN 1 AND 3', 'Position 1, 2 or 3; enforces the three-recipient maximum.'],
      ['RecipientName', 'VARCHAR(100)', '', 'Y', '—', '', 'Optional name or role of the recipient.'],
      ['Email', 'VARCHAR(254)', '', 'N', '—', 'Must match pattern x@x.x', 'Address that receives alerts.'],
      ['IsActive', 'BOOLEAN', '', 'N', 'TRUE', 'TRUE or FALSE', 'Whether the recipient currently receives alerts.'],
    ]},
  { group: 'Alerts', name: 'InventoryAlert', entity: 'Inventory Alert',
    purpose: 'Record that an item variant reached or fell below its setpoint and an alert was generated. Only one open (Pending/Sent) alert can exist per variant, which prevents duplicate emails.',
    cols: [
      ['AlertID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the alert.'],
      ['VariantID', 'INT', 'FK → ItemVariant', 'N', '—', 'One open alert per variant', 'Item variant that is low on stock.'],
      ['TriggeringTransactionID', 'INT', 'FK → InventoryTransaction', 'Y', '—', '', 'Transaction that caused the alert; NULL if a setpoint change triggered it.'],
      ['AlertConfigurationID', 'INT', 'FK → AlertConfiguration', 'Y', '—', '', 'Configuration whose recipients are notified.'],
      ['AlertGeneratedAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time the alert was generated.'],
      ['QuantityAtAlert', 'INT', '', 'N', '—', '≥ 0', 'Current quantity when the alert was generated.'],
      ['SetpointAtAlert', 'INT', '', 'N', '—', '≥ 0', 'Setpoint in effect when the alert was generated.'],
      ['AlertStatus', 'VARCHAR(10)', '', 'N', 'Pending', 'Pending | Sent | Resolved', 'Pending = not yet emailed; Sent = emailed; Resolved = stock back above setpoint.'],
      ['EmailSentAt', 'DATETIME', '', 'Y', '—', '', 'Date/time the email was sent.'],
      ['RecipientsNotified', 'VARCHAR(800)', '', 'Y', '—', '', 'Addresses the alert was actually sent to.'],
      ['LastSendError', 'VARCHAR(1000)', '', 'Y', '—', '', 'Error from the last failed send attempt, if any.'],
      ['ResolvedAt', 'DATETIME', '', 'Y', '—', '', 'Date/time the alert was resolved.'],
      ['SendAttempts', 'INT', '', 'N', '0', '≥ 0', 'Number of email attempts (success or failure). After 5, the alert leaves the email queue so a bad address is not retried forever.'],
      ['OpenVariantKey', 'INT (generated, stored)', 'UQ', 'Y', 'Calculated', 'VariantID while Pending or Sent, else NULL', 'Unique key that allows only one open alert per item.'],
    ]},
  { group: 'Audit', name: 'TransactionAudit', entity: 'Inventory Transaction (audit record)',
    purpose: 'Append-only audit log (WBS 5.5). One row is written when a transaction is created and another when it is deleted and reversed, with a JSON snapshot of every line and the balance before and after.',
    unique: 'TRIGGERS trg_TransactionAudit_BlockUpdate and trg_TransactionAudit_BlockDelete make it append-only. LineDetail uses the JSON data type.',
    cols: [
      ['AuditID', 'INT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique', 'Unique identifier for the audit entry.'],
      ['TransactionID', 'INT', 'FK → InventoryTransaction', 'N', '—', '', 'Transaction that was created or deleted.'],
      ['AuditAction', 'VARCHAR(10)', '', 'N', '—', 'Created | Deleted', 'What happened to the transaction.'],
      ['AuditAt', 'DATETIME', '', 'N', 'CURRENT_TIMESTAMP', '', 'Date/time of the action.'],
      ['AuditByUserID', 'INT', 'FK → AppUser', 'N', '—', '', 'User who created or deleted the transaction.'],
      ['TransactionType', 'VARCHAR(3)', '', 'N', '—', 'IN | OUT', 'Type of the audited transaction.'],
      ['LineCount', 'INT', '', 'N', '—', '> 0', 'Number of item lines affected.'],
      ['TotalUnits', 'INT', '', 'N', '—', '> 0', 'Total units moved by this action.'],
      ['InventoryEffect', 'VARCHAR(10)', '', 'N', '—', 'Added | Removed', 'Net inventory effect of this action (deleting a Stock Out = Added).'],
      ['Reason', 'VARCHAR(255)', '', 'Y', '—', '', 'Reason given for a deletion.'],
      ['LineDetail', 'JSON', '', 'Y', '—', 'JSON type: only valid JSON is stored', 'Per-line snapshot: VariantID, Item, Gender, Size, Qty, QtyBefore, QtyAfter.'],
    ]},
  { group: 'Audit', name: 'AuditLog', entity: 'Change Log Entry',
    purpose: 'Append-only change log (WBS 4.9). Triggers record every change to staff, items, variants, setpoints, alert emails, giveaway templates and lookup values with old and new values. Changes made outside the stored procedures are flagged as direct edits with the MySQL account used.',
    unique: 'TRIGGERS trg_sec_AuditLog_BlockUpdate and trg_sec_AuditLog_BlockDelete make it append-only. Reviewed with usp_Security_WeeklyReview.',
    cols: [
      ['AuditLogID', 'BIGINT AUTO_INCREMENT', 'PK', 'N', 'Auto', 'Unique, system-generated', 'Unique identifier for each log entry.'],
      ['EventTime', 'DATETIME(3)', '', 'N', 'CURRENT_TIMESTAMP(3)', '', 'Date/time of the change (millisecond precision).'],
      ['UserID', 'INT', 'FK → AppUser', 'Y', '—', '', 'Staff member credited with the change; NULL for changes made outside the app.'],
      ['Action', 'VARCHAR(30)', '', 'N', '—', 'Insert | Update | Delete | SetpointChange | TransactionDeleted', 'Type of change.'],
      ['TableName', 'VARCHAR(64)', '', 'Y', '—', '', 'Table that changed.'],
      ['RecordID', 'VARCHAR(64)', '', 'Y', '—', '', 'Primary key of the changed row.'],
      ['OldValue', 'JSON', '', 'Y', '—', '', 'Values before the change.'],
      ['NewValue', 'JSON', '', 'Y', '—', '', 'Values after the change.'],
      ['Detail', 'VARCHAR(500)', '', 'Y', '—', '', 'Extra context, e.g. delete reason.'],
      ['DbAccount', 'VARCHAR(100)', '', 'N', '—', '', 'MySQL account that made the change.'],
      ['IsDirectEdit', 'BOOLEAN', '', 'N', 'FALSE', 'TRUE or FALSE', 'TRUE when the change was made outside the stored procedures.'],
    ]},
];

const relationships = [
  ['AppUser', 'AppUser', 'CreatedByUserID', '1 : many (optional)', 'A user may create many other user accounts.'],
  ['AppUser', 'AuditLog', 'UserID', '1 : many (optional)', 'A staff member is credited with many logged changes.'],
  ['AppUser', 'Item', 'ModifiedByUserID', '1 : many (optional)', 'A staff member may change many items.'],
  ['AppUser', 'InventoryTransaction', 'UserID', '1 : many', 'One user creates many transactions.'],
  ['AppUser', 'InventoryTransaction', 'DeletedByUserID', '1 : many (optional)', 'A user may delete many erroneous transactions.'],
  ['AppUser', 'InventoryBalance', 'SetpointUpdatedBy', '1 : many (optional)', 'A user may set many setpoints.'],
  ['AppUser', 'GiveawayCombination', 'CreatedByUserID', '1 : many', 'A user may create many templates.'],
  ['AppUser', 'AlertConfiguration', 'UpdatedByUserID', '1 : many (optional)', 'A user may update the alert configuration.'],
  ['Category', 'Item', 'CategoryID', '1 : many', 'One category contains many items.'],
  ['Item', 'ItemVariant', 'ItemID', '1 : many', 'An item has one or more variants (size/gender).'],
  ['Size', 'ItemVariant', 'SizeCode', '1 : many (optional)', 'A size applies to many apparel variants.'],
  ['ItemVariant', 'InventoryBalance', 'VariantID', '1 : 1', 'Each variant has exactly one current balance and setpoint.'],
  ['InventoryTransaction', 'TransactionLine', 'TransactionID', '1 : many', 'One transaction contains one or more lines.'],
  ['ItemVariant', 'TransactionLine', 'VariantID', '1 : many', 'One item variant appears on many transaction lines.'],
  ['DistributionCategory', 'InventoryTransaction', 'DistributionCategoryID', '1 : many (Stock Out)', 'One distribution category is used by many Stock Outs.'],
  ['RecipientContext', 'InventoryTransaction', 'RecipientContextID', '1 : many (Stock Out)', 'One recipient context applies to many Stock Outs.'],
  ['EventPurpose', 'InventoryTransaction', 'EventPurposeID', '1 : many (optional)', 'One purpose describes many transactions.'],
  ['GiveawayCombination', 'GiveawayCombinationLine', 'CombinationID', '1 : many', 'A template contains one or more item lines.'],
  ['ItemVariant', 'GiveawayCombinationLine', 'VariantID', '1 : many', 'One item variant appears in many templates.'],
  ['GiveawayCombination', 'InventoryTransaction', 'CombinationID', '1 : many (optional)', 'A template can pre-fill many transactions.'],
  ['DistributionCategory', 'GiveawayCombination', 'DefaultDistributionCategoryID', '1 : many (optional)', 'A category can be the default for many templates.'],
  ['ItemVariant', 'InventoryAlert', 'VariantID', '1 : many', 'One item variant generates many alerts over time.'],
  ['InventoryTransaction', 'InventoryAlert', 'TriggeringTransactionID', '1 : many (optional)', 'A transaction can trigger alerts for each affected item.'],
  ['AlertConfiguration', 'AlertRecipient', 'AlertConfigurationID', '1 : 1–3', 'One configuration has up to three email recipients.'],
  ['AlertConfiguration', 'InventoryAlert', 'AlertConfigurationID', '1 : many (optional)', 'Alerts are sent using the active configuration.'],
  ['InventoryTransaction', 'TransactionAudit', 'TransactionID', '1 : 1–2', 'Each transaction has a Created audit row and, if deleted, a Deleted row.'],
  ['AppUser', 'TransactionAudit', 'AuditByUserID', '1 : many', 'A user performs many audited actions.'],
];

const lookups = [
  ['Category', 'Accessories & Gear; Apparel; Bags & Totes; Drinkware; Office Supplies & Stationery'],
  ['Size', 'XS; S; M; L; XL; XXL; XXXL'],
  ['DistributionCategory', 'Community Event / Donation; Giveaway – Government Relations*; Giveaway – Community Relations*; Internal Staff; Other / Inventory Adjustment   (*IsGiveaway = 1)'],
  ['RecipientContext', 'External; In-Network / Within UH; Not Applicable'],
  ['EventPurpose', 'Conference; Meeting; Community Outreach; Government Relations Event; Government Relations Meeting; Internal Use; Donation; Other'],
  ['ItemVariant.Gender', 'Ladies; Males; Unisex; NULL (not applicable)'],
  ['InventoryTransaction.TransactionType', 'IN (Stock In); OUT (Stock Out)'],
  ['InventoryTransaction.StockInReason', 'Opening Balance; Received; Returned; Adjustment'],
  ['InventoryAlert.AlertStatus', 'Pending; Sent; Resolved'],
  ['AppUser.UserType', 'Full-Time Staff; Student Worker; Student Intern; Other Authorized'],
  ['TransactionAudit.AuditAction', 'Created; Deleted'],
  ['TransactionAudit.InventoryEffect', 'Added; Removed'],
];

const rules = [
  ['Item IDs, User IDs and category names are unique', 'Primary keys; UNIQUE constraints on ItemName, Username, Email, CategoryName'],
  ['Apparel sizes/genders are tracked independently', 'ItemVariant table; UNIQUE (ItemID, GenderKey, SizeKey)'],
  ['Every active item has a current quantity and setpoint', 'InventoryBalance row created with every variant; both columns NOT NULL'],
  ['Monetary value is optional; unknown ≠ $0', 'Item.UnitValue and LineValue are nullable; reports sum known values only and count unknowns separately'],
  ['Quantity cannot fall below zero', 'CHECK (CurrentQuantity >= 0) plus availability check in usp_RecordTransaction'],
  ['Stock Out cannot exceed available quantity (all-or-nothing)', 'usp_RecordTransaction locks rows, checks every line, and rejects the whole transaction if any line is short'],
  ['Transaction-line quantities are whole numbers > 0', 'INT data type; CHECK (Quantity > 0)'],
  ['Stock Out requires distribution category and recipient context', 'CHECK CK_InvTxn_TypeRules; validated in usp_RecordTransaction'],
  ['A distribution must contain at least one line', 'Validated in usp_RecordTransaction'],
  ['A saved giveaway template must contain at least one item', 'Validated in usp_SaveGiveawayCombination'],
  ['Only active merchandise is selectable; history kept for inactive items', 'IsActive flags; usp_GetSelectableVariants; usp_RecordTransaction rejects inactive variants; no hard deletes'],
  ['Every inventory change is traceable to a transaction', 'Quantities change only inside procedures that write a transaction; opening counts are recorded as Opening Balance Stock Ins'],
  ['Setpoint is a stored threshold (~40% of verified baseline), user-adjustable', 'SuggestedSetpoint generated column; Setpoint stored; usp_UpdateSetpoint / usp_ApplySuggestedSetpoints'],
  ['Alert when quantity ≤ setpoint; up to three configurable recipients', 'trg_InventoryBalance_LowStockAlert (every balance change); unique OpenVariantKey; AlertRecipient.RecipientSlot 1–3; vw_PendingAlertEmails + usp_MarkAlertSent'],
  ['Deleting a transaction reverses its effect without going negative', 'usp_DeleteTransaction (soft delete); TransactionAudit row with before/after balances; triggers block direct DELETE'],
  ['Transaction deletions are auditable', 'TransactionAudit (append-only via BlockUpdate/BlockDelete triggers); vw_TransactionAuditLog'],
];

const indexes = [
  ['All 18 tables', 'PRIMARY', 'Clustered primary key', 'INT AUTO_INCREMENT (Size: SizeCode; InventoryBalance: VariantID)', 'InnoDB stores rows in PK order: narrow, append-only key, fast joins'],
  ['All foreign keys', '(auto)', 'Foreign-key index', 'Each FK column', 'InnoDB indexes every foreign key automatically for fast joins'],
  ['ItemVariant', 'UQ_ItemVariant', 'Unique', 'ItemID, GenderKey, SizeKey', 'Prevents duplicate size/gender variants (NULL-safe)'],
  ['InventoryTransaction', 'IX_InvTxn_Date', 'Composite', 'TransactionDate, TransactionType, IsDeleted', 'Date-range filters in Usage, History, Giveaway and Forecast reports'],
  ['TransactionLine', 'IX_TxnLine_VariantQty', 'Composite, covering', 'VariantID, Quantity, TransactionID', 'Per-item usage and forecast totals from the index alone'],
  ['TransactionLine', 'UQ_TxnLine_TxnVariant', 'Unique', 'TransactionID, VariantID', 'One line per item per transaction'],
  ['GiveawayCombinationLine', 'UQ_GiveComboLine', 'Unique', 'CombinationID, VariantID', 'One line per item per template'],
  ['InventoryAlert', 'IX_InvAlert_Status', 'Composite', 'AlertStatus, VariantID, AlertGeneratedAt', 'Pending-alert email queue; Low Inventory report'],
  ['InventoryAlert', 'UQ_InventoryAlert_OpenPerVariant', 'Unique (generated column)', 'OpenVariantKey', 'One open alert per item (no duplicate emails)'],
  ['AlertConfiguration', 'UQ_AlertConfiguration_OneActive', 'Unique (generated column)', 'ActiveKey', 'Only one active alert configuration'],
  ['AlertRecipient', 'UQ_AlertRecipient_Slot / _Email', 'Unique', '(ConfigID, RecipientSlot); (ConfigID, Email)', 'Max three slots; no duplicate addresses'],
  ['TransactionAudit', 'IX_TxnAudit_AuditAt', 'Composite', 'AuditAt, AuditAction, TransactionType', 'Audit log by date range'],
  ['Lookup / name tables', 'UQ_*_Name, UQ_AppUser_*', 'Unique', 'Business keys (names, Username, Email)', 'Enforce uniqueness and double as lookup indexes'],
];

const objects = [
  ['trg_InventoryBalance_LowStockAlert', 'Trigger', 'Raises/resolves low-stock alerts on every quantity or setpoint change', '5.7'],
  ['trg_InventoryTransaction_BlockHardDelete', 'Trigger', 'Blocks direct DELETE; forces reversal through usp_DeleteTransaction', '5.5'],
  ['trg_TransactionLine_BlockHardDelete', 'Trigger', 'Blocks direct DELETE of transaction lines', '5.5'],
  ['trg_TransactionAudit_BlockUpdate / _BlockDelete', 'Trigger', 'Make the audit log append-only', '5.5'],
  ['usp_RecordTransaction', 'Procedure', 'Core engine: Stock In / Stock Out / multi-item giveaway from a JSON list of lines; all-or-nothing validation; writes audit row', '5.4'],
  ['usp_StockIn / usp_StockOut', 'Procedure', 'Single-item wrappers for the entry forms', '5.4'],
  ['usp_DeleteTransaction', 'Procedure', 'Reverses inventory, blocks negative balances, soft-deletes, writes audit row', '5.5'],
  ['usp_RecordOpeningCount / usp_LoadOpeningCounts', 'Procedure', 'Go-live verified count → baseline, opening Stock In, suggested setpoint (one item or a JSON list)', '5.3, 5.6'],
  ['usp_LoadOpeningCountsFromImport', 'Procedure', 'Go-live load from Recount_Template.csv imported as table RecountImport; rejects blank/non-numeric counts, then calls usp_LoadOpeningCounts', '5.3, 5.6'],
  ['usp_UpdateSetpoint', 'Procedure', 'Manual setpoint override', '5.6'],
  ['usp_ApplySuggestedSetpoints', 'Procedure', 'Reset one or all setpoints to the ~40% suggestion', '5.6'],
  ['usp_EvaluateLowStock', 'Procedure', 'Bulk/manual re-check of all alerts (e.g., after reactivating items)', '5.7'],
  ['usp_SetAlertRecipients / usp_MarkAlertSent', 'Procedure', 'Configure 1–3 recipients (JSON list); record alerts the application emailed', '5.7'],
  ['usp_CreateUser / usp_UpdateUser / usp_SetUserActive', 'Procedure', 'Staff tab (open to any staff member, no login): add, edit, remove/bring back staff; the last active staff member cannot be removed', '5.2'],
  ['usp_ApplyRecount', 'Procedure', 'Recount for stock already loaded: posts the difference as an audited Adjustment and sets the new baseline/setpoint', '5.3, 5.6'],
  ['usp_AddAlertRecipient / usp_UpdateAlertRecipient / usp_RemoveAlertRecipient', 'Procedure', 'Alert Settings tab (open to any staff member): add (first free slot, max 3), edit, remove (at least one must remain)', '5.7'],
  ['usp_AddItem / usp_AddItemVariant / usp_UpdateItem / usp_SetItemActive / usp_SetVariantActive / usp_GetSelectableVariants', 'Procedure', 'Merchandise maintenance; active-only pick-list', '5.1, 5.2'],
  ['usp_SaveGiveawayCombination / usp_GetCombinationForEntry', 'Procedure', 'Create and load giveaway templates', '5.4'],
  ['usp_rpt_CurrentInventory, _LowInventory, _InventoryUsage, _InventoryValue, _TransactionHistory, _Giveaway, _DemandForecast', 'Procedure', 'The seven required reports (unknown value kept distinct from $0)', '5.8'],
  ['vw_CurrentInventory, vw_LowInventory, vw_InventoryValue, vw_TransactionHistory', 'View', 'Report views used by the report procedures and the UI', '5.8'],
  ['vw_PendingAlertEmails', 'View', 'Alert email queue (under 5 attempts); group by TriggeringTransactionID so one giveaway sends one email', '5.7'],
  ['vw_FailedAlertEmails', 'View', 'Alerts that failed 5 send attempts, for someone to fix the address', '5.7'],
  ['vw_Users / vw_AlertRecipients', 'View', 'Lists for the Staff tab / “Who are you?” picker and the Alert Settings tab (system account hidden)', '5.2, 5.7'],
  ['vw_SetupStatus', 'View', 'One row the app reads at start-up: needs staff / alert recipient / opening counts', '5.2'],
  ['vw_GiveawayCombinations / usp_GetLookups', 'View / Procedure', 'Giveaway templates with their items, and drop-down values for the entry forms', '5.4'],
  ['usp_Security_WeeklyReview', 'Procedure', 'Weekly review: deleted transactions, direct edits, staff and alert-email changes, integrity exceptions', '4.9'],
  ['vw_Security_DirectEdits / vw_Security_ChangeLog / vw_Security_IntegrityExceptions', 'View', 'Changes made outside the app, readable change log, and checks that should always be empty', '4.9'],
  ['gcr_app_role / gcr_dba_role', 'Database role', 'App account runs procedures and reads views only; DBA account for maintenance and backups', '4.9'],
  ['vw_TransactionAuditLog', 'View', 'Readable audit trail with user names', '5.5'],
  ['usp_IndexMaintenance', 'Procedure', 'ANALYZE (and optionally OPTIMIZE) every table to refresh statistics', '5.9'],
];

const wbs = [
  ['4.5', 'Entity Relationship Diagram', 'ERD_dbdiagram_MySQL.dbml — 18 tables, 27 relationships, header/line model, variants, combos, alerts, audit', 'Sections 2, 4'],
  ['4.6', 'Data dictionary and tables overview', 'This document', 'All'],
  ['5.1', 'Create tables, keys and relationships from ERD', 'Part 1 (01_schema.sql) — 18 tables, PKs, 27 FKs', 'Sections 3, 4'],
  ['5.2', 'Constraints (qty ≥ 0, setpoint ≥ 0, optional unit value, unique IDs)', 'Part 1 — CHECK, UNIQUE, DEFAULT, NOT NULL rules', 'Section 3 (Constraints column), 6'],
  ['5.3', 'Seed lookup data and item catalog from old workbook', 'Part 4 (04_seed_data.sql) — lookups, catalog and case-study starting inventory; physical recount applied from the recount CSV (usp_LoadOpeningCountsFromImport)', 'Section 5'],
  ['5.4', 'Stored procedures: Stock In / Stock Out (multi-line, all-or-nothing)', 'Part 2 (02_procedures.sql) — usp_RecordTransaction, usp_StockIn, usp_StockOut', 'Section 8'],
  ['5.5', 'Transaction deletion, inventory reversal, negative-balance prevention, audit record', 'Part 2 — usp_DeleteTransaction; Part 1 — TransactionAudit table + append-only and delete-block triggers; Part 3 — vw_TransactionAuditLog', 'Sections 3.17, 8'],
  ['5.6', 'Setpoint logic (40% suggestion, stored threshold, manual override)', 'Part 1 — SuggestedSetpoint generated column; Part 2 — usp_RecordOpeningCount, usp_UpdateSetpoint, usp_ApplySuggestedSetpoints', 'Section 3.9, 8'],
  ['5.7', 'Low-stock detection and inventory alert records', 'Part 1 — trg_InventoryBalance_LowStockAlert, InventoryAlert, AlertRecipient; Part 2 — usp_EvaluateLowStock, alert procedures', 'Sections 3.14–3.16, 8'],
  ['5.8', 'Report views and queries (7 reports; unknown value distinct from $0)', 'Part 3 (03_reports.sql) — 6 views, 7 usp_rpt_* procedures', 'Section 8'],
  ['5.9', 'Indexing and performance tuning', 'Part 1 — 4 composite indexes + unique and FK indexes; Part 5 (05_maintenance.sql) — tuning notes, usp_IndexMaintenance', 'Section 7'],
];

// ---------- helpers
const border = { style: BorderStyle.SINGLE, size: 4, color: GRID };
const borders = { top: border, bottom: border, left: border, right: border };
const margins = { top: 50, bottom: 50, left: 80, right: 80 };

function cell(text, width, opts = {}) {
  return new TableCell({
    width: { size: width, type: WidthType.DXA },
    borders, margins,
    shading: opts.fill ? { fill: opts.fill, type: ShadingType.CLEAR, color: 'auto' } : undefined,
    children: [new Paragraph({ keepNext: !!opts.keepNext, spacing: { before: 0, after: 0 }, children: [
      new TextRun({ text: String(text), bold: !!opts.bold, color: opts.color || DARK, font: opts.mono ? 'Consolas' : FONT, size: opts.size || (opts.mono ? 15 : 17) })
    ]})],
  });
}

function makeTable(headers, rows, widths, monoCols = [], keep = false) {
  const total = widths.reduce((a, b) => a + b, 0);
  return new Table({
    width: { size: total, type: WidthType.DXA },
    columnWidths: widths,
    rows: [
      new TableRow({ tableHeader: true, children: headers.map((h, i) => cell(h, widths[i], { bold: true, color: 'FFFFFF', fill: RED, keepNext: keep })) }),
      ...rows.map((r, ri) => new TableRow({ cantSplit: true, children: r.map((v, i) =>
        cell(v, widths[i], { fill: ri % 2 ? LIGHT : undefined, mono: monoCols.includes(i), bold: i === 0 && monoCols.includes(0), keepNext: keep && ri < rows.length - 1 })) })),
    ],
  });
}

const p = (text, opts = {}) => new Paragraph({ keepNext: !!opts.keepNext, spacing: { after: opts.after ?? 120 }, children: [new TextRun({ text, font: FONT, size: opts.size || 20, bold: opts.bold, italics: opts.italics, color: opts.color || DARK })] });
const h1 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun(t)] });
const h2 = (t) => new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(t)] });
const bullet = (t) => new Paragraph({ numbering: { reference: 'bul', level: 0 }, spacing: { after: 60 }, children: [new TextRun({ text: t, font: FONT, size: 20 })] });
const spacer = () => new Paragraph({ spacing: { after: 120 }, children: [] });

const W = 14400; // landscape content width (11in - 2 x 0.5in)
const colWidths = [2750, 1850, 1900, 500, 1750, 2100, 3550];

// ---------- content
const children = [];

// Title block
children.push(
  new Paragraph({ spacing: { before: 1200, after: 120 }, children: [new TextRun({ text: 'DATA DICTIONARY', font: FONT, size: 22, bold: true, color: RED, characterSpacing: 40 })] }),
  new Paragraph({ spacing: { after: 120 }, children: [new TextRun({ text: 'UH Government & Community Relations Inventory Management System', font: FONT, size: 44, bold: true, color: DARK })] }),
  new Paragraph({ border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: RED, space: 8 } }, spacing: { after: 360 }, children: [new TextRun({ text: 'Local MySQL 8.0 database  •  18 tables  •  137 columns', font: FONT, size: 22, color: '666666' })] }),
  p('Dfyne Innovations  |  CIS 4375  |  Fall 2026', { size: 22 }),
  p('Client: University of Houston Government and Community Relations', { size: 22 }),
  p('Project Sponsor: AVC/AVP Sara Donatto, Local Relations and Strategic Initiatives', { size: 22 }),
  p('Prepared by: Adyan Jamal, Backend Developer / Database Lead', { size: 22 }),
  new Paragraph({ children: [new PageBreak()] }),
);

// TOC
children.push(
  new Paragraph({ spacing: { after: 200 }, children: [new TextRun({ text: 'Contents', font: FONT, size: 32, bold: true, color: RED })] }),
  ...['1. Purpose and Conventions', '2. Table Summary', '3. Table Definitions', ...tables.map((t, i) => `      3.${i + 1}  ${t.name}`), '4. Relationships', '5. Controlled Values', '6. Business Rule Traceability', '7. Indexes and Performance', '8. Triggers, Procedures and Views', '9. WBS Coverage Matrix']
    .map(t => new Paragraph({ spacing: { after: 40 }, children: [new TextRun({ text: t, font: FONT, size: t.startsWith(' ') ? 19 : 21, bold: !t.startsWith(' '), color: DARK })] })),
  new Paragraph({ children: [new PageBreak()] }),
);

// 1. Purpose & conventions
children.push(
  h1('1. Purpose and Conventions'),
  p('This data dictionary defines every table and column in the UH Government and Community Relations inventory database. It is the reference for the frontend, QA, reporting and future maintenance teams, and it matches the ERD and the MySQL build script column for column.'),
  h2('Column legend'),
  bullet('Key: PK = primary key; FK → Table = foreign key referencing that table; UQ = unique.'),
  bullet('Null: N = required (NOT NULL); Y = optional (NULL allowed).'),
  bullet('Default: value MySQL supplies when none is given. Auto = AUTO_INCREMENT (system-generated). — = no default.'),
  bullet('Generated: value calculated by the database from other columns; it cannot be entered directly.'),
  h2('Design conventions'),
  bullet('Platform: MySQL 8.0.16 or later (InnoDB), managed in MySQL Workbench. Names use PascalCase; primary keys are TableName + ID.'),
  bullet('Merchandise is modeled in three layers: Item (definition) → ItemVariant (independently tracked size/gender unit) → InventoryBalance (current quantity and setpoint).'),
  bullet('All inventory movements use a header/line structure (InventoryTransaction / TransactionLine), so single-item and multi-item distributions are stored the same way.'),
  bullet('Records are deactivated (IsActive = FALSE) or soft-deleted (IsDeleted = TRUE) rather than physically removed, so history stays reportable.'),
  bullet('Dates and times use DATETIME (to the second). Money uses DECIMAL(10,2). Yes/no flags use BOOLEAN (stored as TINYINT(1)).'),
  new Paragraph({ children: [new PageBreak()] }),
);

// 2. Table summary
children.push(
  h1('2. Table Summary'),
  makeTable(['Table', 'Area', 'Case Study Entity', 'Purpose'],
    tables.map(t => [t.name, t.group, t.entity, t.purpose]), [2800, 1500, 2500, 7600], [0]),
  new Paragraph({ children: [new PageBreak()] }),
);

// 3. Table definitions
children.push(h1('3. Table Definitions'));
let n = 0;
for (const t of tables) {
  n++;
  children.push(
    h2(`3.${n}  ${t.name}`),
    p(t.purpose, { after: 60, keepNext: true }),
    p(`Case study entity: ${t.entity}   |   Area: ${t.group}`, { size: 18, italics: true, color: '666666', keepNext: true }),
    makeTable(['Column', 'Data Type', 'Key', 'Null', 'Default', 'Constraints / Rules', 'Description'], t.cols, colWidths, [0], true),
  );
  if (t.unique) children.push(new Paragraph({ spacing: { before: 80, after: 60 }, children: [
    new TextRun({ text: 'Table-level rules: ', bold: true, font: FONT, size: 18, color: DARK }),
    new TextRun({ text: t.unique, font: FONT, size: 18, color: DARK })] }));
  children.push(spacer());
}
children.push(new Paragraph({ children: [new PageBreak()] }));

// 4. Relationships
children.push(
  h1('4. Relationships'),
  p('Every foreign key in the database, with its cardinality. Parent = the “one” side; Child = the “many” side that holds the foreign key.'),
  makeTable(['Parent Table', 'Child Table', 'Foreign Key Column', 'Cardinality', 'Business Meaning'],
    relationships, [2600, 2800, 3000, 1900, 4100], [0, 1, 2]),
  new Paragraph({ children: [new PageBreak()] }),
);

// 5. Controlled values
children.push(
  h1('5. Controlled Values'),
  p('Allowed values for lookup tables (initial seed data) and CHECK-constrained columns.'),
  makeTable(['Table / Column', 'Allowed Values'], lookups, [4200, 10200], [0]),
  new Paragraph({ children: [new PageBreak()] }),
  h1('6. Business Rule Traceability'),
  p('How each case study business and validation rule is enforced in the database.'),
  makeTable(['Business Rule', 'Where It Is Enforced'], rules, [5600, 8800], [], true),
  new Paragraph({ children: [new PageBreak()] }),
  h1('7. Indexes and Performance'),
  p('Every index in the database and the workload it serves. Tuning notes and the maintenance procedure are in Part 5 of the build (05_maintenance.sql).'),
  makeTable(['Table', 'Index', 'Type', 'Columns', 'Purpose'], indexes, [2300, 3100, 1900, 3400, 3700], [1]),
  spacer(),
  p('Concurrency: stock-out and delete procedures lock affected balance rows (SELECT ... FOR UPDATE) for the duration of the transaction so two users cannot oversell the same item. Every write procedure rolls back completely on any error.', { size: 18 }),
  new Paragraph({ children: [new PageBreak()] }),
  h1('8. Triggers, Procedures and Views'),
  p('Programmable objects that enforce the business rules. All inventory changes go through these; users never edit tables directly.'),
  makeTable(['Object', 'Type', 'Purpose', 'WBS'], objects, [5300, 1300, 6900, 900], [0]),
  new Paragraph({ children: [new PageBreak()] }),
  h1('9. WBS Coverage Matrix'),
  p('Where each Database Development work package is implemented and documented.'),
  makeTable(['WBS', 'Task', 'Implemented In (SQL / ERD)', 'Documented In'], wbs, [700, 4300, 6600, 2800], [], true),
);

// ---------- document
const doc = new Document({
  creator: 'Adyan Jamal',
  title: 'UH GCR Inventory Management System - Data Dictionary',
  styles: {
    default: { document: { run: { font: FONT, size: 20 } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 32, bold: true, font: FONT, color: RED }, paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 24, bold: true, font: FONT, color: DARK }, paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 1, keepNext: true } },
    ],
  },
  numbering: { config: [{ reference: 'bul', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
    style: { paragraph: { indent: { left: 540, hanging: 270 } } } }] }] },
  sections: [{
    properties: { page: { size: { width: 12240, height: 15840, orientation: PageOrientation.LANDSCAPE },
                          margin: { top: 720, bottom: 720, left: 720, right: 720 } } },
    headers: { default: new Header({ children: [new Paragraph({ alignment: AlignmentType.RIGHT, children: [
      new TextRun({ text: 'UH GCR Inventory Management System  |  Data Dictionary', font: FONT, size: 16, color: '888888' })] })] }) },
    footers: { default: new Footer({ children: [new Paragraph({ alignment: AlignmentType.CENTER, children: [
      new TextRun({ text: 'Dfyne Innovations  •  Page ', font: FONT, size: 16, color: '888888' }),
      new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: 16, color: '888888' })] })] }) },
    children,
  }],
});

const total = tables.reduce((a, t) => a + t.cols.length, 0);
console.log('tables', tables.length, 'columns', total);
Packer.toBuffer(doc).then(b => fs.writeFileSync(process.argv[2], b));
