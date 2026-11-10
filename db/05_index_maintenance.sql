-- =====================================================================
-- UH Government & Community Relations - Inventory Management System
-- Dfyne Innovations | CIS 4375 | Fall 2026
-- Part 5: Index maintenance
-- Run usp_IndexMaintenance(FALSE) weekly or after bulk loads; TRUE also rebuilds tables.
-- =====================================================================

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
