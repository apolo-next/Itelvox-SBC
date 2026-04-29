-- dSIPRouter Caller ID Mask schema
-- Provides per-client (endpoint group), per-endpoint (trunk) and
-- per-prefix (per trunk) outbound caller ID rewriting via Kamailio htable.

DROP TABLE IF EXISTS `dsip_caller_id_mask_assignments`;
DROP TABLE IF EXISTS `dsip_caller_id_masks`;
DROP TABLE IF EXISTS `dsip_caller_id_mask_groups`;

/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `dsip_caller_id_mask_groups` (
    `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `name`        VARCHAR(128) NOT NULL,
    `description` VARCHAR(255) NOT NULL DEFAULT '',
    `created_at`  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_caller_id_mask_groups_name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `dsip_caller_id_masks` (
    `id`            INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `mask_group_id` INT UNSIGNED NOT NULL,
    `number`        VARCHAR(64)  NOT NULL,
    `idx`           INT UNSIGNED NOT NULL,
    PRIMARY KEY (`id`),
    KEY `ix_caller_id_masks_group` (`mask_group_id`, `idx`),
    CONSTRAINT `fk_caller_id_masks_group`
        FOREIGN KEY (`mask_group_id`) REFERENCES `dsip_caller_id_mask_groups` (`id`)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;

/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE TABLE `dsip_caller_id_mask_assignments` (
    `id`              INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `mask_group_id`   INT UNSIGNED NOT NULL,
    `assignment_type` ENUM('endpointgroup','endpoint','prefix') NOT NULL,
    `gwgroupid`       INT UNSIGNED DEFAULT NULL,
    `gwid`            INT UNSIGNED DEFAULT NULL,
    `prefix`          VARCHAR(32)  DEFAULT NULL,
    `enabled`         TINYINT(1)   NOT NULL DEFAULT 1,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_caller_id_assignment` (`assignment_type`, `gwgroupid`, `gwid`, `prefix`),
    KEY `ix_caller_id_assignment_group` (`mask_group_id`),
    CONSTRAINT `fk_caller_id_assignment_group`
        FOREIGN KEY (`mask_group_id`) REFERENCES `dsip_caller_id_mask_groups` (`id`)
        ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
/*!40101 SET character_set_client = @saved_cs_client */;


-- View consumed by Kamailio htable 'caller_id_masks'.
-- Stores both the indexed numbers (key '<gid>:<idx>') and the count per
-- group (key '<gid>::count'), so the route can pick a random number.
DROP TABLE IF EXISTS `dsip_caller_id_masks_h`;
DROP VIEW  IF EXISTS `dsip_caller_id_masks_h`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE VIEW `dsip_caller_id_masks_h` AS
    SELECT CAST(CONCAT(mask_group_id, ':', `idx`) AS CHAR) AS `mkey`,
           CAST(`number` AS CHAR)                          AS `mvalue`
    FROM dsip_caller_id_masks
    UNION ALL
    SELECT CAST(CONCAT(mask_group_id, '::count') AS CHAR) AS `mkey`,
           CAST(COUNT(*) AS CHAR)                         AS `mvalue`
    FROM dsip_caller_id_masks
    GROUP BY mask_group_id;
/*!40101 SET character_set_client = @saved_cs_client */;


-- View consumed by Kamailio htable 'caller_id_assignments'.
-- Maps lookup keys to the mask_group_id to use:
--   eg:<gwgroupid>          -> client (endpoint group) level
--   ep:<gwid>               -> per-endpoint (trunk) level
--   px:<gwid>:<prefix>      -> per-prefix on a specific trunk
DROP TABLE IF EXISTS `dsip_caller_id_assignments_h`;
DROP VIEW  IF EXISTS `dsip_caller_id_assignments_h`;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8 */;
CREATE VIEW `dsip_caller_id_assignments_h` AS
    SELECT CAST(CONCAT('eg:', gwgroupid) AS CHAR) AS `mkey`,
           CAST(mask_group_id AS CHAR)            AS `mvalue`
    FROM dsip_caller_id_mask_assignments
    WHERE assignment_type = 'endpointgroup' AND enabled = 1 AND gwgroupid IS NOT NULL
    UNION ALL
    SELECT CAST(CONCAT('ep:', gwid) AS CHAR), CAST(mask_group_id AS CHAR)
    FROM dsip_caller_id_mask_assignments
    WHERE assignment_type = 'endpoint' AND enabled = 1 AND gwid IS NOT NULL
    UNION ALL
    SELECT CAST(CONCAT('px:', gwid, ':', prefix) AS CHAR), CAST(mask_group_id AS CHAR)
    FROM dsip_caller_id_mask_assignments
    WHERE assignment_type = 'prefix' AND enabled = 1 AND gwid IS NOT NULL AND prefix IS NOT NULL;
/*!40101 SET character_set_client = @saved_cs_client */;
