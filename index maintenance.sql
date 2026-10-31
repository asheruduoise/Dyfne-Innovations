/* =====================================================================
   PART 6 : INDEXING & PERFORMANCE MAINTENANCE  (WBS 5.9)
   Tuning notes
   - Every table is clustered on an INT AUTO_INCREMENT primary key.
   - InnoDB automatically indexes every foreign key column.
   - Composite indexes cover the report filters (see Part 1, section 7).
   - Generated-column unique keys enforce "one open alert per item" and
     "one active alert config".
   - Write procedures lock affected balance rows (SELECT ... FOR UPDATE)
     and roll back completely on any error.
   - usp_IndexMaintenance refreshes optimizer statistics (ANALYZE TABLE)
     and can rebuild tables (OPTIMIZE TABLE). Run weekly or after bulk loads.
   ===================================================================== */
USE UH_GCR_Inventory;

DROP PROCEDURE IF EXISTS usp_IndexMaintenance;

DELIMITER $$

CREATE PROCEDURE usp_IndexMaintenance (
    IN p_Rebuild BOOLEAN      -- FALSE = ANALYZE only (fast); TRUE = also OPTIMIZE (rebuild)
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

/* Optional weekly schedule (requires the MySQL event scheduler to be ON):
   SET GLOBAL event_scheduler = ON;
   CREATE EVENT IF NOT EXISTS ev_WeeklyIndexMaintenance
     ON SCHEDULE EVERY 1 WEEK STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 2 HOUR)
     DO CALL usp_IndexMaintenance(FALSE);
*/

SELECT 'Part 6 complete: BUILD FINISHED.' AS Status;