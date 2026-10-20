/* =====================================================================
   SECURITY & AUDIT TEST SUITE  (WBS 4.9)
   !!! DESTRUCTIVE: run ONLY on a throwaway Dev/Test build, never on
   Production. scripts/run_tests.sh rebuilds the database first.
   Run as an administrator account after Parts 1-8.
   Results land in gcr_test.Result; the last query prints the summary.
   ===================================================================== */
DROP DATABASE IF EXISTS gcr_test;
CREATE DATABASE gcr_test;

CREATE TABLE gcr_test.Result (
    ResultID INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    TestID   VARCHAR(10)  NOT NULL,
    TestName VARCHAR(200) NOT NULL,
    Passed   BOOLEAN      NOT NULL,
    Detail   VARCHAR(500) NULL
);

DELIMITER $$

CREATE PROCEDURE gcr_test.ok (IN p_ID VARCHAR(10), IN p_Name VARCHAR(200), IN p_Cond BOOLEAN, IN p_Detail VARCHAR(500))
BEGIN
    INSERT INTO gcr_test.Result (TestID, TestName, Passed, Detail)
    VALUES (p_ID, p_Name, COALESCE(p_Cond, FALSE), LEFT(p_Detail, 500));
END$$

-- Runs p_Sql and passes if it FAILS with a message containing p_Fragment
CREATE PROCEDURE gcr_test.expect_error (IN p_ID VARCHAR(10), IN p_Name VARCHAR(200), IN p_Sql TEXT, IN p_Fragment VARCHAR(200))
BEGIN
    DECLARE v_msg TEXT DEFAULT NULL;
    DECLARE v_tmp TEXT;
    DECLARE v_err BOOLEAN DEFAULT FALSE;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_tmp = MESSAGE_TEXT;   -- must be the first statement in the handler
            IF NOT v_err THEN                                   -- keep the FIRST error only
                SET v_msg = v_tmp, v_err = TRUE;
            END IF;
        END;
        SET @tst_sql = p_Sql;
        PREPARE tst_stmt FROM @tst_sql;
        EXECUTE tst_stmt;
    END;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;   -- statement may already be gone
        DEALLOCATE PREPARE tst_stmt;
    END;
    CALL gcr_test.ok(p_ID, p_Name, v_err AND (p_Fragment IS NULL OR LOCATE(p_Fragment, v_msg) > 0),
                     COALESCE(v_msg, 'NO ERROR RAISED - expected one'));
END$$

-- Runs p_Sql and passes if it SUCCEEDS
CREATE PROCEDURE gcr_test.expect_ok (IN p_ID VARCHAR(10), IN p_Name VARCHAR(200), IN p_Sql TEXT)
BEGIN
    DECLARE v_msg TEXT DEFAULT NULL;
    DECLARE v_tmp TEXT;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1 v_tmp = MESSAGE_TEXT;
            SET v_msg = COALESCE(v_msg, v_tmp);
        END;
        SET @tst_sql = p_Sql;
        PREPARE tst_stmt FROM @tst_sql;
        EXECUTE tst_stmt;
    END;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
        DEALLOCATE PREPARE tst_stmt;
    END;
    CALL gcr_test.ok(p_ID, p_Name, v_msg IS NULL, COALESCE(v_msg, 'ran without error'));
END$$

DELIMITER ;

USE UH_GCR_Inventory;
SET @app_user_id = NULL, @sec_system_ctx = NULL;

/* ---------- fixtures (seed users: 1 admin, 2 staff, 3 student, 4 intern) ---------- */
SET @admin = 1, @staff = 2, @student = 3, @intern = 4;
-- TEST-ONLY bcrypt hashes (passwords are throwaway strings, never used anywhere real)
SET @hashA = '$2b$12$YwdxUrzR1Ww0/KAGGamTXOtqi/6YtnwxNjc08qWQkRUJWZchSI7d.';
SET @hashB = '$2b$12$qIC1acC4MMM3GFHBvfc4iOaQT83RFsLsBbo8uTFkaN8PGE5ns6Vje';
SET @hashWeak = '$2b$04$mZvDWhKs9ik7Ugteo5zBjuJQMR//5VTpL.qVgEGRByVZtOS2fmPwq';   -- cost 4: too weak
SET @distCat = (SELECT DistributionCategoryID FROM DistributionCategory WHERE CategoryName = 'Community Event / Donation');
SET @rcpCtx  = (SELECT RecipientContextID FROM RecipientContext WHERE ContextName = 'External');
SET @variant = (SELECT v.VariantID FROM ItemVariant v JOIN Item i ON i.ItemID = v.ItemID WHERE i.ItemName = 'Red Notebook');
SET @variant2 = (SELECT v.VariantID FROM ItemVariant v JOIN Item i ON i.ItemID = v.ItemID WHERE i.ItemName = 'Red Folder');
SET @itemNotebook = (SELECT ItemID FROM Item WHERE ItemName = 'Red Notebook');

/* =====================================================================
   A. EVERY CHANGE IS TRACEABLE TO A PERSON  (spec §1)
   ===================================================================== */
CALL gcr_test.ok('A00', 'Clean build has no integrity exceptions',
     (SELECT COUNT(*) = 0 FROM vw_Security_IntegrityExceptions), NULL);

CALL gcr_test.expect_error('A01', 'Stock Out with no user is rejected',
     CONCAT('CALL UH_GCR_Inventory.usp_StockOut(NULL, ', @variant, ', 1, ', @distCat, ', ', @rcpCtx, ', NULL, NULL, NULL, NULL, @x)'),
     'not an active authorized user');

CALL gcr_test.expect_error('A02', 'Stock Out with an unknown user ID is rejected',
     CONCAT('CALL UH_GCR_Inventory.usp_StockOut(9999, ', @variant, ', 1, ', @distCat, ', ', @rcpCtx, ', NULL, NULL, NULL, NULL, @x)'),
     'not an active authorized user');

CALL gcr_test.ok('A03', 'Audit context is cleared after a FAILED procedure', @app_user_id IS NULL,
     CONCAT('@app_user_id = ', COALESCE(@app_user_id, 'NULL')));

SET @directBefore = (SELECT COUNT(*) FROM AuditLog WHERE IsDirectEdit);
CALL usp_StockOut(@staff, @variant, 2, @distCat, @rcpCtx, NULL, 'Test event', 'Test recipient', 'A04 test', @t1);

CALL gcr_test.ok('A04', 'Stock Out is stamped with the signed-in user',
     (SELECT UserID = @staff FROM InventoryTransaction WHERE TransactionID = @t1), CONCAT('TransactionID ', @t1));
CALL gcr_test.ok('A05', 'TransactionAudit "Created" row names the same user',
     (SELECT COUNT(*) = 1 FROM TransactionAudit WHERE TransactionID = @t1 AND AuditAction = 'Created' AND AuditByUserID = @staff), NULL);
CALL gcr_test.ok('A06', 'Audit context is cleared after a SUCCESSFUL procedure', @app_user_id IS NULL, NULL);

CALL usp_UpdateItem(@student, @itemNotebook, NULL, NULL, 2.50, FALSE, NULL);
CALL gcr_test.ok('A07', 'Item edit stamps Item.ModifiedByUserID',
     (SELECT ModifiedByUserID = @student AND UpdatedAt IS NOT NULL FROM Item WHERE ItemID = @itemNotebook), NULL);
CALL gcr_test.ok('A08', 'Item edit is in AuditLog with user + old/new value',
     (SELECT COUNT(*) = 1 FROM AuditLog
       WHERE TableName = 'Item' AND RecordID = @itemNotebook AND Action = 'Update' AND UserID = @student
         AND JSON_EXTRACT(OldValue, '$.UnitValue') IS NOT NULL AND JSON_EXTRACT(NewValue, '$.UnitValue') = 2.50
         AND NOT IsDirectEdit), NULL);

CALL usp_UpdateSetpoint(@variant, 77, @intern);
CALL gcr_test.ok('A09', 'Setpoint change logged with user and old/new setpoint',
     (SELECT COUNT(*) = 1 FROM AuditLog
       WHERE Action = 'SetpointChange' AND RecordID = @variant AND UserID = @intern
         AND JSON_EXTRACT(NewValue, '$.Setpoint') = 77 AND NOT IsDirectEdit), NULL);
CALL gcr_test.ok('A10', 'InventoryBalance.SetpointUpdatedBy = the user',
     (SELECT SetpointUpdatedBy = @intern FROM InventoryBalance WHERE VariantID = @variant), NULL);

CALL usp_SetAlertRecipients('[{"Slot":1,"Name":"Test","Email":"test.alerts@example.edu"}]', @staff);
CALL gcr_test.ok('A11', 'Alert email change stamps AlertConfiguration.UpdatedByUserID',
     (SELECT UpdatedByUserID = @staff FROM AlertConfiguration WHERE IsActive), NULL);
CALL gcr_test.ok('A12', 'Alert email change logged per recipient with the user',
     (SELECT COUNT(*) >= 1 FROM AuditLog WHERE TableName = 'AlertRecipient' AND Action = 'Insert'
         AND UserID = @staff AND JSON_UNQUOTE(JSON_EXTRACT(NewValue, '$.Email')) = 'test.alerts@example.edu'), NULL);

CALL usp_DeleteTransaction(@t1, @admin, 'Entered twice by mistake');
CALL gcr_test.ok('A13', 'Delete logged as TransactionDeleted with user and reason',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'TransactionDeleted' AND RecordID = @t1
         AND UserID = @admin AND Detail = 'Entered twice by mistake'), NULL);
CALL gcr_test.ok('A14', 'Delete keeps the row (soft delete) with who/when/why',
     (SELECT IsDeleted AND DeletedByUserID = @admin AND DeletedAt IS NOT NULL AND DeleteReason IS NOT NULL
        FROM InventoryTransaction WHERE TransactionID = @t1), NULL);

CALL usp_AddItem(@staff, 'Test Lanyard', (SELECT CategoryID FROM Category WHERE CategoryName = 'Accessories & Gear'),
                 1.25, 'A15 test item', TRUE, @newItem);
CALL gcr_test.ok('A15', 'New item stamped and logged with the creating user',
     (SELECT i.ModifiedByUserID = @staff
             AND EXISTS (SELECT 1 FROM AuditLog a WHERE a.TableName = 'Item' AND a.RecordID = @newItem
                                                  AND a.Action = 'Insert' AND a.UserID = @staff)
        FROM Item i WHERE i.ItemID = @newItem), NULL);

CALL gcr_test.expect_error('A16', 'Item deactivation requires an active user',
     CONCAT('CALL UH_GCR_Inventory.usp_SetItemActive(NULL, ', @newItem, ', FALSE)'), 'not an active authorized user');

CALL gcr_test.ok('A17', 'Normal app activity creates ZERO direct-edit flags',
     (SELECT COUNT(*) FROM AuditLog WHERE IsDirectEdit) = @directBefore, NULL);

/* =====================================================================
   B. RECORDS CAN'T BE QUIETLY REWRITTEN
   ===================================================================== */
CALL gcr_test.expect_error('B01', 'AuditLog rows cannot be updated',
     'UPDATE UH_GCR_Inventory.AuditLog SET Detail = ''tampered'' ORDER BY AuditLogID LIMIT 1', 'append-only');
CALL gcr_test.expect_error('B02', 'AuditLog rows cannot be deleted',
     'DELETE FROM UH_GCR_Inventory.AuditLog ORDER BY AuditLogID LIMIT 1', 'append-only');
CALL gcr_test.expect_error('B03', 'TransactionAudit rows cannot be updated',
     'UPDATE UH_GCR_Inventory.TransactionAudit SET Reason = ''tampered'' ORDER BY AuditID LIMIT 1', 'append-only');
CALL gcr_test.expect_error('B04', 'Transactions cannot be hard-deleted',
     CONCAT('DELETE FROM UH_GCR_Inventory.InventoryTransaction WHERE TransactionID = ', @t1), 'Direct DELETE is not allowed');
CALL gcr_test.expect_error('B05', 'Transaction line quantities cannot be edited',
     CONCAT('UPDATE UH_GCR_Inventory.TransactionLine SET Quantity = 1 WHERE TransactionID = ', @t1), 'cannot be edited');
CALL gcr_test.expect_error('B06', 'Who-posted-it (UserID) cannot be rewritten',
     CONCAT('UPDATE UH_GCR_Inventory.InventoryTransaction SET UserID = ', @admin, ' WHERE TransactionID = ', @t1), 'cannot be edited');
CALL gcr_test.expect_error('B07', 'A deleted transaction cannot be un-deleted',
     CONCAT('UPDATE UH_GCR_Inventory.InventoryTransaction SET IsDeleted = FALSE, DeletedAt = NULL, DeletedByUserID = NULL WHERE TransactionID = ', @t1),
     'cannot be restored');
CALL gcr_test.expect_error('B08', 'Users cannot be deleted',
     CONCAT('DELETE FROM UH_GCR_Inventory.AppUser WHERE UserID = ', @intern), 'cannot be deleted');
CALL gcr_test.expect_error('B09', 'Plain-text password is rejected by the database',
     CONCAT('UPDATE UH_GCR_Inventory.AppUser SET PasswordHash = ''MyPassword123!'' WHERE UserID = ', @intern), 'CK_AppUser_PasswordHash');
CALL gcr_test.expect_error('B10', 'Weak bcrypt (cost 4) is rejected',
     CONCAT('CALL UH_GCR_Inventory.usp_User_SetPassword(', @admin, ', ', @intern, ', ''', @hashWeak, ''')'), 'bcrypt');

/* =====================================================================
   C. SIGN-IN, LOCKOUT, SESSIONS, ACCOUNT LIFECYCLE  (spec §1, §3)
   ===================================================================== */
CALL usp_User_Create(@admin, 'gcr.tester', 'Test', 'User', 'gcr.tester@example.edu', 'Student Worker', @hashA, @tester);
CALL gcr_test.ok('C01', 'New account records approver and forces password change',
     (SELECT ApprovedByUserID = @admin AND MustChangePassword AND PasswordHash = @hashA FROM AppUser WHERE UserID = @tester), NULL);
CALL gcr_test.ok('C02', 'Account creation logged with approver (no hash in log)',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE TableName = 'AppUser' AND Action = 'Insert' AND RecordID = @tester
         AND UserID = @admin AND JSON_EXTRACT(NewValue, '$.HasPassword') = TRUE), NULL);
CALL gcr_test.expect_error('C03', 'Account creation with a plain-text password is rejected',
     CONCAT('CALL UH_GCR_Inventory.usp_User_Create(', @admin, ', ''gcr.bad'', ''Bad'', ''User'', ''bad@example.edu'', ''Student Worker'', ''Password123!'', @x)'),
     'bcrypt');

-- successful sign-in
CALL usp_Auth_RecordLoginAttempt('gcr.tester', TRUE, 'test-pc', @outcome, @uid, @token);
CALL gcr_test.ok('C04', 'Correct password -> OK + user ID + 64-char token',
     @outcome = 'OK' AND @uid = @tester AND CHAR_LENGTH(@token) = 64, CONCAT('outcome=', @outcome));
CALL gcr_test.ok('C05', 'Only the SHA-256 of the token is stored, never the token',
     (SELECT COUNT(*) = 1 FROM AppSession WHERE TokenHash = SHA2(@token, 256))
     AND (SELECT COUNT(*) = 0 FROM AppSession WHERE TokenHash = @token), NULL);
CALL gcr_test.ok('C06', 'Sign-in logged (LoginSuccess)',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'LoginSuccess' AND UserID = @tester), NULL);

CALL usp_Auth_ValidateSession(@token, @sessUser, @sessStatus);
CALL gcr_test.ok('C07', 'Active session returns the user', @sessStatus = 'OK' AND @sessUser = @tester, @sessStatus);

-- 14 minutes idle: still fine
UPDATE AppSession SET LastActivityAt = NOW() - INTERVAL 14 MINUTE WHERE TokenHash = SHA2(@token, 256);
CALL usp_Auth_ValidateSession(@token, @sessUser, @sessStatus);
CALL gcr_test.ok('C08', '14 minutes idle -> session still valid', @sessStatus = 'OK', @sessStatus);

-- 16 minutes idle: expired
UPDATE AppSession SET LastActivityAt = NOW() - INTERVAL 16 MINUTE WHERE TokenHash = SHA2(@token, 256);
CALL usp_Auth_ValidateSession(@token, @sessUser, @sessStatus);
CALL gcr_test.ok('C09', '16 minutes idle -> Expired and no user returned', @sessStatus = 'Expired' AND @sessUser IS NULL, @sessStatus);
CALL gcr_test.ok('C10', 'Timeout ends the session and is logged',
     (SELECT EndReason = 'IdleTimeout' FROM AppSession WHERE TokenHash = SHA2(@token, 256))
     AND (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'SessionTimeout' AND UserID = @tester), NULL);
CALL usp_Auth_ValidateSession(@token, @sessUser, @sessStatus);
CALL gcr_test.ok('C11', 'Expired token cannot be reused', @sessStatus = 'Invalid', @sessStatus);
CALL usp_Auth_ValidateSession('0000000000000000000000000000000000000000000000000000000000000000', @sessUser, @sessStatus);
CALL gcr_test.ok('C12', 'Made-up token is rejected', @sessStatus = 'Invalid' AND @sessUser IS NULL, @sessStatus);

-- lockout: 4 failures -> still Failed
CALL usp_Auth_RecordLoginAttempt('gcr.tester', FALSE, 'test-pc', @outcome, @uid, @token2);
CALL usp_Auth_RecordLoginAttempt('gcr.tester', FALSE, 'test-pc', @outcome, @uid, @token2);
CALL usp_Auth_RecordLoginAttempt('gcr.tester', FALSE, 'test-pc', @outcome, @uid, @token2);
CALL usp_Auth_RecordLoginAttempt('gcr.tester', FALSE, 'test-pc', @outcome, @uid, @token2);
CALL gcr_test.ok('C13', '4 wrong passwords -> Failed, not yet locked',
     @outcome = 'Failed' AND (SELECT FailedLoginCount = 4 AND LockedUntil IS NULL FROM AppUser WHERE UserID = @tester),
     CONCAT('outcome=', @outcome));
-- 5th failure -> locked for 15 minutes
CALL usp_Auth_RecordLoginAttempt('gcr.tester', FALSE, 'test-pc', @outcome, @uid, @token2);
CALL gcr_test.ok('C14', '5th wrong password -> Locked for 15 minutes',
     @outcome = 'Locked' AND (SELECT LockedUntil BETWEEN NOW() + INTERVAL 14 MINUTE AND NOW() + INTERVAL 16 MINUTE
                                FROM AppUser WHERE UserID = @tester),
     CONCAT('outcome=', @outcome));
CALL gcr_test.ok('C15', 'Lockout and each failure are logged',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'AccountLocked' AND UserID = @tester)
     AND (SELECT COUNT(*) = 5 FROM AuditLog WHERE Action = 'LoginFailed' AND UserID = @tester), NULL);
-- correct password while locked
CALL usp_Auth_RecordLoginAttempt('gcr.tester', TRUE, 'test-pc', @outcome, @uid, @token2);
CALL gcr_test.ok('C16', 'Correct password while locked -> still Locked, no session',
     @outcome = 'Locked' AND @token2 IS NULL AND @uid IS NULL, CONCAT('outcome=', @outcome));
CALL gcr_test.ok('C17', 'Blocked attempt is logged (LoginBlocked)',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'LoginBlocked' AND UserID = @tester), NULL);

-- unknown username gets the same answer as a wrong password
CALL usp_Auth_RecordLoginAttempt('no.such.user', FALSE, 'test-pc', @outcome, @uid, @token2);
CALL gcr_test.ok('C18', 'Unknown username -> Failed (same as wrong password)', @outcome = 'Failed', @outcome);
CALL gcr_test.ok('C19', 'Unknown username attempt is logged with no user',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'LoginFailed' AND UserID IS NULL AND Detail LIKE '%no.such.user%'), NULL);

-- unlock through the app
CALL usp_User_Unlock(@admin, @tester);
CALL gcr_test.ok('C20', 'Unlock clears the lock and is logged (not a direct edit)',
     (SELECT LockedUntil IS NULL AND FailedLoginCount = 0 FROM AppUser WHERE UserID = @tester)
     AND (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'AccountUnlocked' AND RecordID = @tester
            AND UserID = @admin AND NOT IsDirectEdit), NULL);

CALL usp_Auth_RecordLoginAttempt('gcr.tester', TRUE, 'test-pc', @outcome, @uid, @token3);
CALL gcr_test.ok('C21', 'After unlock the user can sign in', @outcome = 'OK', @outcome);

-- own password change
CALL usp_User_SetPassword(@tester, @tester, @hashB);
CALL gcr_test.ok('C22', 'Own password change clears MustChangePassword and is logged',
     (SELECT NOT MustChangePassword AND PasswordHash = @hashB FROM AppUser WHERE UserID = @tester)
     AND (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'PasswordChanged' AND RecordID = @tester
            AND UserID = @tester AND Detail = 'Changed by the user'), NULL);

-- reset by someone else ends their sessions
CALL usp_User_SetPassword(@admin, @tester, @hashA);
CALL usp_Auth_ValidateSession(@token3, @sessUser, @sessStatus);
CALL gcr_test.ok('C23', 'Password reset by another user ends the user''s sessions',
     @sessStatus = 'Invalid' AND (SELECT MustChangePassword FROM AppUser WHERE UserID = @tester), @sessStatus);

-- logout
CALL usp_Auth_RecordLoginAttempt('gcr.tester', TRUE, 'test-pc', @outcome, @uid, @token4);
CALL usp_Auth_Logout(@token4);
CALL usp_Auth_ValidateSession(@token4, @sessUser, @sessStatus);
CALL gcr_test.ok('C24', 'Logout ends the session and is logged',
     @sessStatus = 'Invalid' AND (SELECT COUNT(*) = 1 FROM AuditLog WHERE Action = 'Logout' AND UserID = @tester), @sessStatus);

-- deactivation (departing student)
CALL usp_Auth_RecordLoginAttempt('gcr.tester', TRUE, 'test-pc', @outcome, @uid, @token5);
CALL gcr_test.expect_error('C25', 'Users cannot deactivate themselves',
     CONCAT('CALL UH_GCR_Inventory.usp_User_Deactivate(', @tester, ', ', @tester, ', ''leaving'')'), 'your own account');
CALL gcr_test.expect_error('C26', 'Deactivation requires a reason',
     CONCAT('CALL UH_GCR_Inventory.usp_User_Deactivate(', @admin, ', ', @tester, ', '''')'), 'reason is required');
CALL usp_User_Deactivate(@admin, @tester, 'Semester ended');
CALL usp_Auth_ValidateSession(@token5, @sessUser, @sessStatus);
CALL gcr_test.ok('C27', 'Deactivation immediately ends open sessions',
     @sessStatus = 'Invalid' AND (SELECT EndReason = 'UserDeactivated' FROM AppSession WHERE TokenHash = SHA2(@token5, 256)), @sessStatus);
CALL usp_Auth_RecordLoginAttempt('gcr.tester', TRUE, 'test-pc', @outcome, @uid, @token6);
CALL gcr_test.ok('C28', 'Deactivated user cannot sign in', @outcome = 'Failed' AND @token6 IS NULL, @outcome);
CALL gcr_test.expect_error('C29', 'Deactivated user cannot post a transaction',
     CONCAT('CALL UH_GCR_Inventory.usp_StockOut(', @tester, ', ', @variant, ', 1, ', @distCat, ', ', @rcpCtx, ', NULL, NULL, NULL, NULL, @x)'),
     'not an active authorized user');
CALL gcr_test.ok('C30', 'Deactivation logged with who and reason',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE TableName = 'AppUser' AND Action = 'Update' AND RecordID = @tester
         AND UserID = @admin AND JSON_EXTRACT(NewValue, '$.IsActive') = 0
         AND JSON_UNQUOTE(JSON_EXTRACT(NewValue, '$.DeactivationReason')) = 'Semester ended'), NULL);

CALL gcr_test.ok('C31', 'No password hash ever appears in AuditLog',
     (SELECT COUNT(*) = 0 FROM AuditLog
       WHERE CAST(OldValue AS CHAR) LIKE '%$2b$%' OR CAST(NewValue AS CHAR) LIKE '%$2b$%' OR Detail LIKE '%$2b$%'), NULL);

/* =====================================================================
   D. DETECTING CHANGES MADE OUTSIDE THE APP  (spec §3)
   These statements are run by hand (no procedure) on purpose.
   ===================================================================== */
SET @app_user_id = NULL, @sec_system_ctx = NULL;
CALL gcr_test.ok('D00', 'After all app activity: no integrity exceptions',
     (SELECT COUNT(*) = 0 FROM vw_Security_IntegrityExceptions), NULL);

UPDATE InventoryBalance SET CurrentQuantity = CurrentQuantity + 50 WHERE VariantID = @variant2;
CALL gcr_test.ok('D01', 'Hand-edited quantity is flagged as a direct edit with the DB account',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE IsDirectEdit AND TableName = 'InventoryBalance'
         AND RecordID = @variant2 AND UserID IS NULL AND DbAccount = SESSION_USER()), NULL);
CALL gcr_test.ok('D02', 'Hand-edited quantity shows up as balance drift',
     (SELECT COUNT(*) = 1 FROM vw_Security_IntegrityExceptions
       WHERE Issue = 'Balance does not match transaction history' AND RecordID = @variant2), NULL);

UPDATE Item SET UnitValue = 999.99 WHERE ItemID = @itemNotebook;
CALL gcr_test.ok('D03', 'Hand-edited item is flagged and ModifiedByUserID is cleared',
     (SELECT ModifiedByUserID IS NULL FROM Item WHERE ItemID = @itemNotebook)
     AND (SELECT COUNT(*) = 1 FROM AuditLog WHERE IsDirectEdit AND TableName = 'Item' AND RecordID = @itemNotebook), NULL);

UPDATE InventoryBalance SET Setpoint = 0 WHERE VariantID = @variant;
CALL gcr_test.ok('D04', 'Hand-edited setpoint is flagged and not credited to the last app user',
     (SELECT SetpointUpdatedBy IS NULL FROM InventoryBalance WHERE VariantID = @variant)
     AND (SELECT COUNT(*) = 1 FROM AuditLog WHERE IsDirectEdit AND Action = 'SetpointChange' AND RecordID = @variant), NULL);

INSERT INTO InventoryTransaction (UserID, TransactionType, StockInReason) VALUES (@admin, 'IN', 'Received');
SET @fakeTxn = LAST_INSERT_ID();
CALL gcr_test.ok('D05', 'Hand-inserted transaction is flagged',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE IsDirectEdit AND TableName = 'InventoryTransaction' AND RecordID = @fakeTxn), NULL);
CALL gcr_test.ok('D06', 'Hand-inserted transaction fails the integrity checks',
     (SELECT COUNT(*) = 2 FROM vw_Security_IntegrityExceptions WHERE TableName = 'InventoryTransaction' AND RecordID = @fakeTxn), NULL);

UPDATE AppUser SET LockedUntil = NOW() + INTERVAL 1 DAY WHERE UserID = @intern;
CALL gcr_test.ok('D07', 'Hand-edited lockout fields are flagged',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE IsDirectEdit AND TableName = 'AppUser' AND RecordID = @intern), NULL);

UPDATE EventPurpose SET PurposeName = 'Other (edited)' WHERE PurposeName = 'Other';
CALL gcr_test.ok('D08', 'Hand-edited lookup value is flagged',
     (SELECT COUNT(*) = 1 FROM AuditLog WHERE IsDirectEdit AND TableName = 'EventPurpose'), NULL);

CALL gcr_test.ok('D09', 'Direct-edit review view lists every hand edit above',
     (SELECT COUNT(*) >= 6 FROM vw_Security_DirectEdits), NULL);
CALL gcr_test.ok('D10', 'Account review flags seed users with no password',
     (SELECT COUNT(*) >= 1 FROM vw_Security_AccountReview WHERE ReviewFlag = 'No password set - cannot sign in'), NULL);
CALL gcr_test.expect_ok('D11', 'Weekly review procedure runs', 'CALL UH_GCR_Inventory.usp_Security_WeeklyReview(7)');

/* =====================================================================
   SUMMARY
   ===================================================================== */
SELECT CONCAT(SUM(Passed), ' passed, ', SUM(NOT Passed), ' failed, ', COUNT(*), ' total') AS Summary
  FROM gcr_test.Result;
SELECT TestID, TestName, Detail FROM gcr_test.Result WHERE NOT Passed ORDER BY ResultID;
