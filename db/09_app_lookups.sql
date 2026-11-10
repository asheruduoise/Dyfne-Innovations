/* =====================================================================
   PART 9 : APP LOOKUP VIEWS  (web app Step 2)
   Run as an administrator AFTER Part 8.

   Gives the app account just enough to run sign-in and fill the
   Stock Transactions form:
     - active users: ID, username and display name only
       (no email, password hash, or lockout details)
     - active distribution categories and recipient contexts
   The app account still has NO table access (Part 8).
   ===================================================================== */
USE UH_GCR_Inventory;

CREATE OR REPLACE VIEW vw_App_ActiveUsers AS
SELECT UserID, Username, CONCAT(FirstName, ' ', LastName) AS DisplayName, UserType
  FROM AppUser
 WHERE IsActive;

CREATE OR REPLACE VIEW vw_App_DistributionCategories AS
SELECT DistributionCategoryID, CategoryName, Description, IsGiveaway
  FROM DistributionCategory
 WHERE IsActive;

CREATE OR REPLACE VIEW vw_App_RecipientContexts AS
SELECT RecipientContextID, ContextName, Description
  FROM RecipientContext
 WHERE IsActive;

GRANT SELECT ON UH_GCR_Inventory.vw_App_ActiveUsers            TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_App_DistributionCategories TO 'gcr_app_role';
GRANT SELECT ON UH_GCR_Inventory.vw_App_RecipientContexts      TO 'gcr_app_role';

SELECT 'Part 9 complete: app lookup views created.' AS Status;
