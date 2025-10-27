-- ================================================================================
-- Oracle 19c+ Tablespace Defragmentation Script v3 - LOB & PARTITION SUPPORT
-- ================================================================================
-- Purpose: Defragment tablespace by moving objects to _SHRINK tablespace,
--          with full support for LOB objects and partitioned tables
-- Method:  SOURCE → SOURCE_SHRINK → SOURCE (2-tablespace method)
-- 
-- New Features in v3:
--   • DBMS_REDEFINITION for LOB tables (online with minimal downtime)
--   • Hybrid strategy for partitioned LOB tables
--   • LOB storage parameter preservation
--   • Progress monitoring via DBMS_APPLICATION_INFO
--   • UNDO/TEMP resource checks
--   • Recovery commands in log (no permanent checkpoint tables)
--   • LOB index validation
--   • LONG column detection and skip
-- ================================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
SET PAGESIZE 1000
SET FEEDBACK OFF
SET VERIFY OFF
SET TIMING ON

-- Parameters
ACCEPT v_source_tablespace CHAR PROMPT 'Enter Source Tablespace Name: '
ACCEPT v_objects_per_batch NUMBER DEFAULT 5 PROMPT 'Enter Objects per Batch (default 5): '
ACCEPT v_lob_objects_per_batch NUMBER DEFAULT 2 PROMPT 'Enter LOB Objects per Batch (default 2): '
ACCEPT v_buffer_gb NUMBER DEFAULT 10 PROMPT 'Enter Buffer Size in GB (default 10): '
ACCEPT v_partition_max_count NUMBER DEFAULT 20 PROMPT 'Max Partitions for Online REDEF (default 20): '
ACCEPT v_partition_max_size_gb NUMBER DEFAULT 100 PROMPT 'Max Size GB for Online REDEF (default 100): '
ACCEPT v_dry_run CHAR DEFAULT 'Y' PROMPT 'Dry Run Mode? (Y/N, default Y): '

PROMPT
PROMPT ================================================================================
PROMPT DEFRAGMENTATION SCRIPT v3 - LOB & PARTITION SUPPORT
PROMPT ================================================================================
PROMPT Source Tablespace:           &v_source_tablespace
PROMPT Objects per Batch:           &v_objects_per_batch
PROMPT LOB Objects per Batch:       &v_lob_objects_per_batch
PROMPT Buffer Size:                 &v_buffer_gb GB
PROMPT Partition REDEF Max Count:   &v_partition_max_count
PROMPT Partition REDEF Max Size:    &v_partition_max_size_gb GB
PROMPT Mode:                        &v_dry_run
PROMPT ================================================================================

DECLARE
    v_source_tablespace VARCHAR2(30) := UPPER('&v_source_tablespace');
    v_objects_per_batch NUMBER := &v_objects_per_batch;
    v_lob_objects_per_batch NUMBER := &v_lob_objects_per_batch;
    v_buffer_gb NUMBER := &v_buffer_gb;
    v_buffer_mb NUMBER := v_buffer_gb * 1024;
    v_partition_max_count NUMBER := &v_partition_max_count;
    v_partition_max_size_gb NUMBER := &v_partition_max_size_gb;
    v_dry_run VARCHAR2(1) := UPPER('&v_dry_run');
    
    v_shrink_tablespace VARCHAR2(30);
    v_source_size_mb NUMBER;
    v_source_used_mb NUMBER;
    v_shrink_size_mb NUMBER;
    v_shrink_exists NUMBER;
    v_new_source_size_mb NUMBER;
    
    -- Object counters
    v_total_simple_tables NUMBER := 0;
    v_total_lob_tables NUMBER := 0;
    v_total_part_lob_tables NUMBER := 0;
    v_total_long_tables NUMBER := 0;
    v_total_indexes NUMBER := 0;
    
    v_simple_moved NUMBER := 0;
    v_lob_moved NUMBER := 0;
    v_part_lob_moved NUMBER := 0;
    v_indexes_moved NUMBER := 0;
    
    v_sql VARCHAR2(4000);
    v_lob_storage_clause VARCHAR2(4000);
    
    v_bigfile VARCHAR2(3);
    v_block_size NUMBER;
    
    v_phase_start_time TIMESTAMP;
    v_phase_duration NUMBER;
    v_cmd_start_time TIMESTAMP;
    v_cmd_end_time TIMESTAMP;
    v_cmd_duration NUMBER;
    
    -- Resource tracking
    v_undo_size_gb NUMBER;
    v_undo_free_gb NUMBER;
    v_temp_size_gb NUMBER;
    v_temp_free_gb NUMBER;
    v_estimated_undo_gb NUMBER;
    v_estimated_temp_gb NUMBER;
    
    -- Recovery tracking
    TYPE t_recovery_cmd IS RECORD (
        phase VARCHAR2(100),
        object_name VARCHAR2(200),
        command VARCHAR2(4000),
        status VARCHAR2(20)
    );
    TYPE t_recovery_cmds IS TABLE OF t_recovery_cmd INDEX BY PLS_INTEGER;
    v_recovery_log t_recovery_cmds;
    v_recovery_idx PLS_INTEGER := 0;
    
    -- Helper procedure to log recovery commands
    PROCEDURE log_recovery(p_phase VARCHAR2, p_object VARCHAR2, p_command VARCHAR2, p_status VARCHAR2) IS
    BEGIN
        v_recovery_idx := v_recovery_idx + 1;
        v_recovery_log(v_recovery_idx).phase := p_phase;
        v_recovery_log(v_recovery_idx).object_name := p_object;
        v_recovery_log(v_recovery_idx).command := p_command;
        v_recovery_log(v_recovery_idx).status := p_status;
    END;
    
    -- Helper procedure to print recovery commands
    PROCEDURE print_recovery_log IS
    BEGIN
        IF v_recovery_log.COUNT > 0 THEN
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('================================================================================');
            DBMS_OUTPUT.PUT_LINE('RECOVERY LOG - Commands for Manual Completion if Script Failed');
            DBMS_OUTPUT.PUT_LINE('================================================================================');
            
            FOR i IN 1..v_recovery_log.COUNT LOOP
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('Phase: ' || v_recovery_log(i).phase);
                DBMS_OUTPUT.PUT_LINE('Object: ' || v_recovery_log(i).object_name);
                DBMS_OUTPUT.PUT_LINE('Status: ' || v_recovery_log(i).status);
                DBMS_OUTPUT.PUT_LINE('Command:');
                DBMS_OUTPUT.PUT_LINE(v_recovery_log(i).command || ';');
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('================================================================================');
        END IF;
    END;
    
    -- Helper function to build LOB storage clause
    FUNCTION get_lob_storage_clause(
        p_owner VARCHAR2,
        p_table_name VARCHAR2,
        p_target_tablespace VARCHAR2
    ) RETURN VARCHAR2 IS
        v_clause VARCHAR2(4000) := '';
        v_first BOOLEAN := TRUE;
    BEGIN
        FOR lob_rec IN (
            SELECT 
                column_name,
                securefile,
                compression,
                deduplication,
                in_row,
                chunk,
                pctversion,
                CAST(retention AS VARCHAR2(100)) AS retention,
                CAST(cache AS VARCHAR2(100)) AS cache
            FROM dba_lobs
            WHERE owner = p_owner
            AND table_name = p_table_name
            ORDER BY column_name
        ) LOOP
            IF v_first THEN
                v_first := FALSE;
            ELSE
                v_clause := v_clause || ' ';
            END IF;
            
            v_clause := v_clause || 'LOB (' || lob_rec.column_name || ') STORE AS ';
            
            -- SecureFile or BasicFile
            IF lob_rec.securefile = 'YES' THEN
                v_clause := v_clause || 'SECUREFILE ';
            ELSE
                v_clause := v_clause || 'BASICFILE ';
            END IF;
            
            v_clause := v_clause || '(TABLESPACE ' || p_target_tablespace;
            
            -- Compression
            IF lob_rec.compression = 'MEDIUM' THEN
                v_clause := v_clause || ' COMPRESS MEDIUM';
            ELSIF lob_rec.compression = 'HIGH' THEN
                v_clause := v_clause || ' COMPRESS HIGH';
            ELSIF lob_rec.compression = 'LOW' THEN
                v_clause := v_clause || ' COMPRESS LOW';
            ELSE
                v_clause := v_clause || ' NOCOMPRESS';
            END IF;
            
            -- Deduplication
            IF lob_rec.deduplication = 'YES' THEN
                v_clause := v_clause || ' DEDUPLICATE';
            ELSE
                v_clause := v_clause || ' KEEP_DUPLICATES';
            END IF;
            
            -- In-Row
            IF lob_rec.in_row = 'YES' THEN
                v_clause := v_clause || ' ENABLE STORAGE IN ROW';
            ELSIF lob_rec.in_row = 'NO' THEN
                v_clause := v_clause || ' DISABLE STORAGE IN ROW';
            END IF;
            
            -- Chunk
            IF lob_rec.chunk IS NOT NULL THEN
                v_clause := v_clause || ' CHUNK ' || lob_rec.chunk;
            END IF;
            
            -- PCT Version (for BasicFiles)
            IF lob_rec.securefile = 'NO' AND lob_rec.pctversion IS NOT NULL THEN
                v_clause := v_clause || ' PCTVERSION ' || lob_rec.pctversion;
            END IF;
            
            -- Retention (for SecureFiles)
            IF lob_rec.securefile = 'YES' AND lob_rec.retention IS NOT NULL THEN
                v_clause := v_clause || ' RETENTION ' || lob_rec.retention;
            END IF;
            
            -- Cache
            IF lob_rec.cache = 'YES' THEN
                v_clause := v_clause || ' CACHE';
            ELSIF lob_rec.cache = 'NO' THEN
                v_clause := v_clause || ' NOCACHE';
            ELSIF lob_rec.cache = 'CACHEREADS' THEN
                v_clause := v_clause || ' CACHE READS';
            END IF;
            
            v_clause := v_clause || ')';
        END LOOP;
        
        RETURN v_clause;
    END;
    
BEGIN
    -- Set module for tracking
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'INITIALIZATION'
    );
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('PHASE 1: PRE-FLIGHT CHECKS');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    v_phase_start_time := SYSTIMESTAMP;
    
    -- 1. Check if source tablespace exists
    BEGIN
        SELECT bigfile, block_size
        INTO v_bigfile, v_block_size
        FROM dba_tablespaces
        WHERE tablespace_name = v_source_tablespace;
        
        DBMS_OUTPUT.PUT_LINE('✓ Source tablespace found: ' || v_source_tablespace);
        DBMS_OUTPUT.PUT_LINE('  Type: ' || CASE WHEN v_bigfile = 'YES' THEN 'BIGFILE' ELSE 'SMALLFILE' END);
        DBMS_OUTPUT.PUT_LINE('  Block Size: ' || v_block_size || ' bytes');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            DBMS_OUTPUT.PUT_LINE('✗ ERROR: Source tablespace ' || v_source_tablespace || ' not found!');
            RETURN;
    END;
    
    -- 2. Get source tablespace size
    DECLARE
        v_source_hwm_mb NUMBER;
    BEGIN
        SELECT CEIL(SUM(bytes)/1024/1024)
        INTO v_source_size_mb
        FROM dba_data_files
        WHERE tablespace_name = v_source_tablespace;
        
        SELECT CEIL(NVL(SUM(bytes), 0)/1024/1024)
        INTO v_source_used_mb
        FROM dba_segments
        WHERE tablespace_name = v_source_tablespace;
        
        SELECT CEIL(SUM(NVL(hwm.hwm_bytes, df.bytes))/1024/1024)
        INTO v_source_hwm_mb
        FROM dba_data_files df
        LEFT JOIN 
            (SELECT 
                 file_id, 
                 MAX(block_id + blocks - 1) * 
                 (SELECT TO_NUMBER(value) FROM v$parameter WHERE name = 'db_block_size') AS hwm_bytes
             FROM dba_extents
             WHERE tablespace_name = v_source_tablespace
             GROUP BY file_id) hwm
        ON df.file_id = hwm.file_id
        WHERE df.tablespace_name = v_source_tablespace;
        
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Source Tablespace Analysis:');
        DBMS_OUTPUT.PUT_LINE('  Allocated Size: ' || v_source_size_mb || ' MB (' || ROUND(v_source_size_mb/1024, 2) || ' GB)');
        DBMS_OUTPUT.PUT_LINE('  Used Space:     ' || v_source_used_mb || ' MB (' || ROUND(v_source_used_mb/1024, 2) || ' GB)');
        DBMS_OUTPUT.PUT_LINE('  High Water Mark:' || v_source_hwm_mb || ' MB (' || ROUND(v_source_hwm_mb/1024, 2) || ' GB)');
        DBMS_OUTPUT.PUT_LINE('  Wasted Space:   ' || (v_source_size_mb - v_source_used_mb) || ' MB (' || 
                             ROUND((v_source_size_mb - v_source_used_mb)/1024, 2) || ' GB)');
        DBMS_OUTPUT.PUT_LINE('  Efficiency:     ' || ROUND((v_source_used_mb / v_source_size_mb) * 100, 2) || '%');
    END;
    
    -- 3. Calculate shrink tablespace size
    v_shrink_tablespace := v_source_tablespace || '_SHRINK';
    v_shrink_size_mb := v_source_used_mb + v_buffer_mb;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Shrink Tablespace Plan:');
    DBMS_OUTPUT.PUT_LINE('  Name: ' || v_shrink_tablespace);
    DBMS_OUTPUT.PUT_LINE('  Size: ' || v_shrink_size_mb || ' MB (' || ROUND(v_shrink_size_mb/1024, 2) || ' GB)');
    DBMS_OUTPUT.PUT_LINE('  Formula: Used (' || v_source_used_mb || ' MB) + Buffer (' || v_buffer_mb || ' MB)');
    
    -- 4. Check if shrink tablespace already exists
    SELECT COUNT(*)
    INTO v_shrink_exists
    FROM dba_tablespaces
    WHERE tablespace_name = v_shrink_tablespace;
    
    IF v_shrink_exists > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('✗ ERROR: Shrink tablespace ' || v_shrink_tablespace || ' already exists!');
        DBMS_OUTPUT.PUT_LINE('  Please drop it first:');
        DBMS_OUTPUT.PUT_LINE('  DROP TABLESPACE ' || v_shrink_tablespace || ' INCLUDING CONTENTS AND DATAFILES;');
        RETURN;
    END IF;
    
    -- 5. Count and categorize objects
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Object Categorization:');
    
    -- Category 1: Simple tables (no LOB, no LONG, no partitions)
    SELECT COUNT(*)
    INTO v_total_simple_tables
    FROM dba_tables t
    WHERE t.tablespace_name = v_source_tablespace
    AND t.partitioned = 'NO'
    AND t.nested = 'NO'
    AND NOT EXISTS (
        SELECT 1 FROM dba_lobs l 
        WHERE l.owner = t.owner AND l.table_name = t.table_name
    )
    AND NOT EXISTS (
        SELECT 1 FROM dba_tab_columns c
        WHERE c.owner = t.owner 
        AND c.table_name = t.table_name
        AND c.data_type IN ('LONG', 'LONG RAW')
    );
    
    DBMS_OUTPUT.PUT_LINE('  Category 1 (Simple Tables):         ' || v_total_simple_tables || ' tables');
    
    -- Category 2: LOB tables (non-partitioned)
    SELECT COUNT(DISTINCT t.table_name)
    INTO v_total_lob_tables
    FROM dba_tables t
    INNER JOIN dba_lobs l ON t.owner = l.owner AND t.table_name = l.table_name
    WHERE t.tablespace_name = v_source_tablespace
    AND t.partitioned = 'NO'
    AND NOT EXISTS (
        SELECT 1 FROM dba_tab_columns c
        WHERE c.owner = t.owner 
        AND c.table_name = t.table_name
        AND c.data_type IN ('LONG', 'LONG RAW')
    );
    
    DBMS_OUTPUT.PUT_LINE('  Category 2 (LOB Non-Partitioned):   ' || v_total_lob_tables || ' tables');
    
    -- Category 3: Partitioned LOB tables
    SELECT COUNT(DISTINCT t.table_name)
    INTO v_total_part_lob_tables
    FROM dba_tables t
    INNER JOIN dba_part_tables pt ON t.owner = pt.owner AND t.table_name = pt.table_name
    INNER JOIN dba_lobs l ON t.owner = l.owner AND t.table_name = l.table_name
    WHERE t.tablespace_name = v_source_tablespace
    OR EXISTS (
        SELECT 1 FROM dba_tab_partitions tp
        WHERE tp.table_owner = t.owner
        AND tp.table_name = t.table_name
        AND tp.tablespace_name = v_source_tablespace
    );
    
    DBMS_OUTPUT.PUT_LINE('  Category 3 (Partitioned LOB):       ' || v_total_part_lob_tables || ' tables');
    
    -- Category 4: LONG/LONG RAW tables
    SELECT COUNT(DISTINCT t.table_name)
    INTO v_total_long_tables
    FROM dba_tables t
    INNER JOIN dba_tab_columns c ON t.owner = c.owner AND t.table_name = c.table_name
    WHERE t.tablespace_name = v_source_tablespace
    AND c.data_type IN ('LONG', 'LONG RAW');
    
    IF v_total_long_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  Category 4 (LONG/LONG RAW):         ' || v_total_long_tables || ' tables [WILL BE SKIPPED]');
        DBMS_OUTPUT.PUT_LINE('  ⚠️  WARNING: Tables with LONG columns cannot be moved with this script.');
        DBMS_OUTPUT.PUT_LINE('     Consider migrating LONG to CLOB before defragmentation.');
    END IF;
    
    -- Count indexes
    SELECT COUNT(*)
    INTO v_total_indexes
    FROM dba_indexes
    WHERE tablespace_name = v_source_tablespace
    AND index_type NOT IN ('LOB');
    
    DBMS_OUTPUT.PUT_LINE('  Indexes:                            ' || v_total_indexes || ' indexes');
    
    -- 6. Resource checks (UNDO/TEMP)
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Resource Requirements Check:');
    
    -- Estimate UNDO requirement (~60% of LOB data size)
    DECLARE
        v_lob_size_mb NUMBER;
    BEGIN
        SELECT CEIL(NVL(SUM(s.bytes), 0)/1024/1024)
        INTO v_lob_size_mb
        FROM dba_lobs l
        JOIN dba_segments s ON l.owner = s.owner AND l.segment_name = s.segment_name
        WHERE l.tablespace_name = v_source_tablespace
        OR EXISTS (
            SELECT 1 FROM dba_tables t
            WHERE t.owner = l.owner
            AND t.table_name = l.table_name
            AND t.tablespace_name = v_source_tablespace
        );
        
        v_estimated_undo_gb := ROUND((v_source_used_mb * 0.5 + v_lob_size_mb * 0.6) / 1024, 2);
        v_estimated_temp_gb := ROUND((v_source_used_mb * 0.3) / 1024, 2);
    END;
    
    -- Check current UNDO
    BEGIN
        SELECT 
            ROUND(SUM(d.bytes)/1024/1024/1024, 2),
            ROUND((SUM(d.bytes) - SUM(NVL(f.bytes, 0)))/1024/1024/1024, 2)
        INTO v_undo_size_gb, v_undo_free_gb
        FROM dba_data_files d
        LEFT JOIN (
            SELECT tablespace_name, SUM(bytes) bytes 
            FROM dba_free_space 
            GROUP BY tablespace_name
        ) f ON d.tablespace_name = f.tablespace_name
        WHERE d.tablespace_name IN (
            SELECT tablespace_name FROM dba_tablespaces WHERE contents = 'UNDO'
        );
        
        v_undo_free_gb := v_undo_size_gb - v_undo_free_gb;
        
        DBMS_OUTPUT.PUT_LINE('  UNDO Tablespace:');
        DBMS_OUTPUT.PUT_LINE('    Required: ~' || v_estimated_undo_gb || ' GB');
        DBMS_OUTPUT.PUT_LINE('    Available: ' || v_undo_free_gb || ' GB / ' || v_undo_size_gb || ' GB total');
        
        IF v_undo_free_gb < v_estimated_undo_gb THEN
            DBMS_OUTPUT.PUT_LINE('    ⚠️  WARNING: Insufficient UNDO space!');
            DBMS_OUTPUT.PUT_LINE('    Recommendation: Extend UNDO tablespace before proceeding');
            DBMS_OUTPUT.PUT_LINE('    Command: ALTER TABLESPACE <undo_ts> ADD DATAFILE SIZE ' || 
                                 CEIL(v_estimated_undo_gb - v_undo_free_gb + 5) || 'G;');
        ELSE
            DBMS_OUTPUT.PUT_LINE('    ✓ Sufficient UNDO space available');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('    (Could not check UNDO status)');
    END;
    
    -- Check current TEMP
    BEGIN
        DECLARE
            v_temp_ts_name VARCHAR2(30);
            v_temp_used_gb NUMBER;
        BEGIN
            SELECT tablespace_name
            INTO v_temp_ts_name
            FROM dba_tablespaces
            WHERE contents = 'TEMPORARY'
            AND ROWNUM = 1;
            
            SELECT ROUND(SUM(bytes)/1024/1024/1024, 2)
            INTO v_temp_size_gb
            FROM dba_temp_files
            WHERE tablespace_name = v_temp_ts_name;
            
            SELECT ROUND(NVL(SUM(bytes_used), 0)/1024/1024/1024, 2)
            INTO v_temp_used_gb
            FROM v$temp_extent_pool
            WHERE tablespace_name = v_temp_ts_name;
            
            v_temp_free_gb := v_temp_size_gb - v_temp_used_gb;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('  TEMP Tablespace (' || v_temp_ts_name || '):');
            DBMS_OUTPUT.PUT_LINE('    Required: ~' || v_estimated_temp_gb || ' GB');
            DBMS_OUTPUT.PUT_LINE('    Available: ' || v_temp_free_gb || ' GB / ' || v_temp_size_gb || ' GB total');
            
            IF v_temp_free_gb < v_estimated_temp_gb THEN
                DBMS_OUTPUT.PUT_LINE('    ⚠️  WARNING: Insufficient TEMP space!');
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('    📋 RECOMMENDATION: Create dedicated TEMP tablespace:');
                DBMS_OUTPUT.PUT_LINE('       CREATE TEMPORARY TABLESPACE DEFRAG_TEMP');
                DBMS_OUTPUT.PUT_LINE('         TEMPFILE SIZE ' || CEIL(v_estimated_temp_gb + 2) || 'G AUTOEXTEND ON;');
                DBMS_OUTPUT.PUT_LINE('       ALTER SESSION SET TEMPORARY_TABLESPACE = DEFRAG_TEMP;');
                DBMS_OUTPUT.PUT_LINE('       -- After completion:');
                DBMS_OUTPUT.PUT_LINE('       DROP TABLESPACE DEFRAG_TEMP INCLUDING CONTENTS AND DATAFILES;');
            ELSE
                DBMS_OUTPUT.PUT_LINE('    ✓ Sufficient TEMP space available');
            END IF;
        END;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('    (Could not check TEMP status)');
    END;
    
    v_phase_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_phase_start_time));
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Phase duration: ' || ROUND(v_phase_duration, 2) || ' seconds');
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('✓ Pre-flight checks completed');
    
    -- Stop here if resource issues detected in dry run
    IF v_dry_run = 'Y' THEN
        IF (v_undo_free_gb < v_estimated_undo_gb) OR (v_temp_free_gb < v_estimated_temp_gb) THEN
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('⚠️  DRY RUN: Resource issues detected. Please address before running for real.');
            RETURN;
        END IF;
    END IF;
    
    -- ============================================================================
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('PHASE 2: CREATE SHRINK TABLESPACE');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    v_phase_start_time := SYSTIMESTAMP;
    
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'PHASE_2_CREATE_SHRINK'
    );
    
    v_sql := 'CREATE ';
    IF v_bigfile = 'YES' THEN
        v_sql := v_sql || 'BIGFILE ';
    END IF;
    v_sql := v_sql || 'TABLESPACE ' || v_shrink_tablespace || 
             ' DATAFILE SIZE ' || v_shrink_size_mb || 'M AUTOEXTEND ON';
    
    DBMS_OUTPUT.PUT_LINE('Creating shrink tablespace...');
    DBMS_OUTPUT.PUT_LINE('SQL: ' || v_sql);
    
    IF v_dry_run = 'N' THEN
        v_cmd_start_time := SYSTIMESTAMP;
        BEGIN
            EXECUTE IMMEDIATE v_sql;
            v_cmd_end_time := SYSTIMESTAMP;
            DBMS_OUTPUT.PUT_LINE('✓ Shrink tablespace created successfully');
            log_recovery('PHASE_2', v_shrink_tablespace, 
                        'DROP TABLESPACE ' || v_shrink_tablespace || ' INCLUDING CONTENTS AND DATAFILES',
                        'CREATED');
        EXCEPTION
            WHEN OTHERS THEN
                DBMS_OUTPUT.PUT_LINE('✗ Failed to create shrink tablespace: ' || SQLERRM);
                RAISE;
        END;
    ELSE
        DBMS_OUTPUT.PUT_LINE('[DRY RUN - Command not executed]');
    END IF;
    
    v_phase_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_phase_start_time));
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Phase duration: ' || ROUND(v_phase_duration, 2) || ' seconds');
    
    -- ============================================================================
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('PHASE 3: MOVE OBJECTS TO SHRINK TABLESPACE');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    v_phase_start_time := SYSTIMESTAMP;
    
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'PHASE_3_MOVE_TO_SHRINK'
    );
    
    -- ======================
    -- PHASE 3A: Simple Tables
    -- ======================
    IF v_total_simple_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('--- PHASE 3A: Moving Simple Tables (ONLINE) ---');
        DBMS_OUTPUT.PUT_LINE('');
        
        DECLARE
            v_batch_count NUMBER := 0;
        BEGIN
            FOR rec IN (
                SELECT t.owner, t.table_name,
                       ROUND(NVL(s.bytes, 0)/1024/1024, 2) AS size_mb
                FROM dba_tables t
                LEFT JOIN dba_segments s ON t.owner = s.owner AND t.table_name = s.segment_name
                WHERE t.tablespace_name = v_source_tablespace
                AND t.partitioned = 'NO'
                AND t.nested = 'NO'
                AND NOT EXISTS (
                    SELECT 1 FROM dba_lobs l 
                    WHERE l.owner = t.owner AND l.table_name = t.table_name
                )
                AND NOT EXISTS (
                    SELECT 1 FROM dba_tab_columns c
                    WHERE c.owner = t.owner 
                    AND c.table_name = t.table_name
                    AND c.data_type IN ('LONG', 'LONG RAW')
                )
                ORDER BY NVL(s.bytes, 0) DESC
            ) LOOP
                v_batch_count := v_batch_count + 1;
                
                IF MOD(v_batch_count - 1, v_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('Batch ' || CEIL(v_batch_count / v_objects_per_batch) || ':');
                END IF;
                
                v_sql := 'ALTER TABLE ' || rec.owner || '.' || rec.table_name || 
                        ' MOVE TABLESPACE ' || v_shrink_tablespace || ' ONLINE UPDATE INDEXES';
                
                DBMS_OUTPUT.PUT_LINE('  [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' || 
                                    rec.owner || '.' || rec.table_name || ' (' || rec.size_mb || ' MB)');
                
                IF v_dry_run = 'N' THEN
                    v_cmd_start_time := SYSTIMESTAMP;
                    BEGIN
                        DBMS_APPLICATION_INFO.SET_ACTION('Moving ' || rec.owner || '.' || rec.table_name);
                        EXECUTE IMMEDIATE v_sql;
                        v_cmd_end_time := SYSTIMESTAMP;
                        v_cmd_duration := EXTRACT(SECOND FROM (v_cmd_end_time - v_cmd_start_time));
                        DBMS_OUTPUT.PUT_LINE('    ✓ Moved successfully (' || ROUND(v_cmd_duration, 2) || 's)');
                        v_simple_moved := v_simple_moved + 1;
                        
                        log_recovery('PHASE_3A', rec.owner || '.' || rec.table_name,
                                    'ALTER TABLE ' || rec.owner || '.' || rec.table_name || 
                                    ' MOVE TABLESPACE ' || v_source_tablespace || ' ONLINE UPDATE INDEXES',
                                    'MOVED_TO_SHRINK');
                    EXCEPTION
                        WHEN OTHERS THEN
                            DBMS_OUTPUT.PUT_LINE('    ✗ Failed: ' || SQLERRM);
                            log_recovery('PHASE_3A', rec.owner || '.' || rec.table_name,
                                        'ALTER TABLE ' || rec.owner || '.' || rec.table_name || 
                                        ' MOVE TABLESPACE ' || v_source_tablespace || ' ONLINE UPDATE INDEXES',
                                        'FAILED');
                    END;
                ELSE
                    DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                END IF;
                
                IF MOD(v_batch_count, v_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('');
                END IF;
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('Simple tables moved: ' || v_simple_moved || ' / ' || v_total_simple_tables);
        END;
    END IF;
    
    -- ======================
    -- PHASE 3B: LOB Tables (Non-Partitioned) - DBMS_REDEFINITION
    -- ======================
    IF v_total_lob_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('--- PHASE 3B: Moving LOB Tables (DBMS_REDEFINITION - Online) ---');
        DBMS_OUTPUT.PUT_LINE('');
        
        DECLARE
            v_batch_count NUMBER := 0;
            v_interim_table VARCHAR2(30);
            v_num_errors PLS_INTEGER;
        BEGIN
            FOR rec IN (
                SELECT DISTINCT t.owner, t.table_name,
                       ROUND(NVL(s.bytes, 0)/1024/1024, 2) AS table_size_mb,
                       COUNT(DISTINCT l.column_name) AS lob_count
                FROM dba_tables t
                LEFT JOIN dba_segments s ON t.owner = s.owner AND t.table_name = s.segment_name
                INNER JOIN dba_lobs l ON t.owner = l.owner AND t.table_name = l.table_name
                WHERE t.tablespace_name = v_source_tablespace
                AND t.partitioned = 'NO'
                AND NOT EXISTS (
                    SELECT 1 FROM dba_tab_columns c
                    WHERE c.owner = t.owner 
                    AND c.table_name = t.table_name
                    AND c.data_type IN ('LONG', 'LONG RAW')
                )
                GROUP BY t.owner, t.table_name, s.bytes
                ORDER BY NVL(s.bytes, 0) DESC
            ) LOOP
                v_batch_count := v_batch_count + 1;
                
                IF MOD(v_batch_count - 1, v_lob_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('Batch ' || CEIL(v_batch_count / v_lob_objects_per_batch) || ':');
                END IF;
                
                v_interim_table := 'INT_' || SUBSTR(rec.table_name, 1, 24);
                
                -- Get LOB storage clause
                v_lob_storage_clause := get_lob_storage_clause(rec.owner, rec.table_name, v_shrink_tablespace);
                
                DBMS_OUTPUT.PUT_LINE('  [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' || 
                                    rec.owner || '.' || rec.table_name || 
                                    ' (' || rec.table_size_mb || ' MB, ' || rec.lob_count || ' LOBs)');
                DBMS_OUTPUT.PUT_LINE('    Method: DBMS_REDEFINITION (online with minimal downtime)');
                
                IF v_dry_run = 'N' THEN
                    v_cmd_start_time := SYSTIMESTAMP;
                    BEGIN
                        DBMS_APPLICATION_INFO.SET_ACTION('REDEF: ' || rec.owner || '.' || rec.table_name);
                        
                        -- Step 1: Check if table can be redefined
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Checking redefinition capability...');
                        DBMS_REDEFINITION.CAN_REDEF_TABLE(
                            uname => rec.owner,
                            tname => rec.table_name,
                            options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                        );
                        
                        -- Step 2: Create interim table with LOB storage in shrink tablespace
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Creating interim table...');
                        
                        v_sql := 'CREATE TABLE ' || rec.owner || '.' || v_interim_table || 
                                ' TABLESPACE ' || v_shrink_tablespace || ' AS SELECT * FROM ' || 
                                rec.owner || '.' || rec.table_name || ' WHERE 1=0';
                        EXECUTE IMMEDIATE v_sql;
                        
                        -- Apply LOB storage clause if needed
                        IF v_lob_storage_clause IS NOT NULL THEN
                            v_sql := 'ALTER TABLE ' || rec.owner || '.' || v_interim_table || 
                                    ' MOVE TABLESPACE ' || v_shrink_tablespace || ' ' || v_lob_storage_clause;
                            EXECUTE IMMEDIATE v_sql;
                        END IF;
                        
                        -- Step 3: Start redefinition
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Starting redefinition...');
                        DBMS_REDEFINITION.START_REDEF_TABLE(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table,
                            options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                        );
                        
                        -- Step 4: Copy dependent objects (indexes, constraints, triggers)
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Copying dependent objects...');
                        DBMS_REDEFINITION.COPY_TABLE_DEPENDENTS(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table,
                            copy_indexes => DBMS_REDEFINITION.CONS_ORIG_PARAMS,
                            copy_triggers => TRUE,
                            copy_constraints => TRUE,
                            copy_privileges => TRUE,
                            ignore_errors => FALSE,
                            num_errors => v_num_errors,
                            copy_statistics => TRUE
                        );
                        
                        IF v_num_errors > 0 THEN
                            DBMS_OUTPUT.PUT_LINE('    ⚠️  ' || v_num_errors || ' errors during dependent copy');
                        END IF;
                        
                        -- Step 5: Synchronize (may take time for large tables)
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Synchronizing data...');
                        DBMS_REDEFINITION.SYNC_INTERIM_TABLE(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table
                        );
                        
                        -- Step 6: Finish redefinition (brief exclusive lock here)
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Finishing redefinition (brief lock)...');
                        DBMS_REDEFINITION.FINISH_REDEF_TABLE(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table
                        );
                        
                        -- Step 7: Drop interim table
                        v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                        EXECUTE IMMEDIATE v_sql;
                        
                        v_cmd_end_time := SYSTIMESTAMP;
                        v_cmd_duration := EXTRACT(SECOND FROM (v_cmd_end_time - v_cmd_start_time));
                        DBMS_OUTPUT.PUT_LINE('    ✓ Redefinition completed (' || ROUND(v_cmd_duration/60, 2) || ' min)');
                        v_lob_moved := v_lob_moved + 1;
                        
                        log_recovery('PHASE_3B', rec.owner || '.' || rec.table_name,
                                    '-- Use DBMS_REDEFINITION to move back to ' || v_source_tablespace,
                                    'MOVED_TO_SHRINK');
                        
                    EXCEPTION
                        WHEN OTHERS THEN
                            DBMS_OUTPUT.PUT_LINE('    ✗ Failed: ' || SQLERRM);
                            
                            -- Cleanup on error
                            BEGIN
                                DBMS_REDEFINITION.ABORT_REDEF_TABLE(
                                    uname => rec.owner,
                                    orig_table => rec.table_name,
                                    int_table => v_interim_table
                                );
                                
                                v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                                EXECUTE IMMEDIATE v_sql;
                            EXCEPTION
                                WHEN OTHERS THEN NULL;
                            END;
                            
                            log_recovery('PHASE_3B', rec.owner || '.' || rec.table_name,
                                        '-- FAILED - Manual intervention required',
                                        'FAILED');
                    END;
                ELSE
                    DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                    DBMS_OUTPUT.PUT_LINE('    Will use: ' || v_lob_storage_clause);
                END IF;
                
                IF MOD(v_batch_count, v_lob_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('');
                END IF;
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('LOB tables moved: ' || v_lob_moved || ' / ' || v_total_lob_tables);
        END;
    END IF;
    
    -- ======================
    -- PHASE 3C: Partitioned LOB Tables (Hybrid Strategy)
    -- ======================
    IF v_total_part_lob_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('--- PHASE 3C: Moving Partitioned LOB Tables (Hybrid Strategy) ---');
        DBMS_OUTPUT.PUT_LINE('');
        
        DECLARE
            v_batch_count NUMBER := 0;
            v_interim_table VARCHAR2(30);
            v_num_errors PLS_INTEGER;
            v_partition_count NUMBER;
            v_table_size_gb NUMBER;
            v_use_redef BOOLEAN;
        BEGIN
            FOR rec IN (
                SELECT 
                    t.owner,
                    t.table_name,
                    pt.partitioning_type,
                    COUNT(DISTINCT tp.partition_name) AS partition_count,
                    ROUND(NVL(SUM(s.bytes), 0)/1024/1024/1024, 2) AS total_size_gb,
                    COUNT(DISTINCT l.column_name) AS lob_count
                FROM dba_tables t
                INNER JOIN dba_part_tables pt ON t.owner = pt.owner AND t.table_name = pt.table_name
                INNER JOIN dba_tab_partitions tp ON t.owner = tp.table_owner AND t.table_name = tp.table_name
                LEFT JOIN dba_segments s ON tp.table_owner = s.owner 
                                         AND tp.table_name = s.segment_name 
                                         AND tp.partition_name = s.partition_name
                INNER JOIN dba_lobs l ON t.owner = l.owner AND t.table_name = l.table_name
                WHERE t.tablespace_name = v_source_tablespace
                OR tp.tablespace_name = v_source_tablespace
                GROUP BY t.owner, t.table_name, pt.partitioning_type
                ORDER BY SUM(s.bytes) DESC
            ) LOOP
                v_batch_count := v_batch_count + 1;
                v_partition_count := rec.partition_count;
                v_table_size_gb := rec.total_size_gb;
                
                -- Decide strategy: DBMS_REDEF (online) vs partition-by-partition (safer)
                v_use_redef := (v_partition_count <= v_partition_max_count AND 
                               v_table_size_gb <= v_partition_max_size_gb);
                
                DBMS_OUTPUT.PUT_LINE('Table ' || v_batch_count || ':');
                DBMS_OUTPUT.PUT_LINE('  [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' || 
                                    rec.owner || '.' || rec.table_name);
                DBMS_OUTPUT.PUT_LINE('    Partitions: ' || v_partition_count || 
                                    ' (' || rec.partitioning_type || ')');
                DBMS_OUTPUT.PUT_LINE('    Size: ' || v_table_size_gb || ' GB');
                DBMS_OUTPUT.PUT_LINE('    LOBs: ' || rec.lob_count);
                
                IF v_use_redef THEN
                    DBMS_OUTPUT.PUT_LINE('    Strategy: DBMS_REDEFINITION (online - whole table)');
                    
                    IF v_dry_run = 'N' THEN
                        v_interim_table := 'INT_' || SUBSTR(rec.table_name, 1, 24);
                        v_cmd_start_time := SYSTIMESTAMP;
                        
                        BEGIN
                            DBMS_APPLICATION_INFO.SET_ACTION('REDEF_PART: ' || rec.owner || '.' || rec.table_name);
                            
                            DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Starting online redefinition...');
                            
                            -- Similar to Phase 3B but for partitioned table
                            DBMS_REDEFINITION.CAN_REDEF_TABLE(
                                uname => rec.owner,
                                tname => rec.table_name,
                                options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                            );
                            
                            -- Create interim partitioned table
                            v_sql := 'CREATE TABLE ' || rec.owner || '.' || v_interim_table || 
                                    ' TABLESPACE ' || v_shrink_tablespace || 
                                    ' AS SELECT * FROM ' || rec.owner || '.' || rec.table_name || 
                                    ' WHERE 1=0';
                            EXECUTE IMMEDIATE v_sql;
                            
                            DBMS_REDEFINITION.START_REDEF_TABLE(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table,
                                options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                            );
                            
                            DBMS_REDEFINITION.COPY_TABLE_DEPENDENTS(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table,
                                copy_indexes => DBMS_REDEFINITION.CONS_ORIG_PARAMS,
                                copy_triggers => TRUE,
                                copy_constraints => TRUE,
                                copy_privileges => TRUE,
                                ignore_errors => FALSE,
                                num_errors => v_num_errors
                            );
                            
                            DBMS_REDEFINITION.SYNC_INTERIM_TABLE(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table
                            );
                            
                            DBMS_REDEFINITION.FINISH_REDEF_TABLE(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table
                            );
                            
                            v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                            EXECUTE IMMEDIATE v_sql;
                            
                            v_cmd_end_time := SYSTIMESTAMP;
                            v_cmd_duration := EXTRACT(SECOND FROM (v_cmd_end_time - v_cmd_start_time));
                            DBMS_OUTPUT.PUT_LINE('    ✓ Redefinition completed (' || 
                                               ROUND(v_cmd_duration/60, 2) || ' min)');
                            v_part_lob_moved := v_part_lob_moved + 1;
                            
                        EXCEPTION
                            WHEN OTHERS THEN
                                DBMS_OUTPUT.PUT_LINE('    ✗ Failed: ' || SQLERRM);
                                BEGIN
                                    DBMS_REDEFINITION.ABORT_REDEF_TABLE(
                                        uname => rec.owner,
                                        orig_table => rec.table_name,
                                        int_table => v_interim_table
                                    );
                                    v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                                    EXECUTE IMMEDIATE v_sql;
                                EXCEPTION
                                    WHEN OTHERS THEN NULL;
                                END;
                        END;
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                    END IF;
                    
                ELSE
                    DBMS_OUTPUT.PUT_LINE('    Strategy: Partition-by-partition move (safer for large tables)');
                    DBMS_OUTPUT.PUT_LINE('    ⚠️  Each partition will be offline during move');
                    DBMS_OUTPUT.PUT_LINE('    ⚠️  Other partitions remain accessible');
                    
                    IF v_dry_run = 'N' THEN
                        DECLARE
                            v_part_moved NUMBER := 0;
                        BEGIN
                            FOR part_rec IN (
                                SELECT partition_name,
                                       ROUND(NVL(s.bytes, 0)/1024/1024, 2) AS size_mb
                                FROM dba_tab_partitions tp
                                LEFT JOIN dba_segments s ON tp.table_owner = s.owner
                                                        AND tp.table_name = s.segment_name
                                                        AND tp.partition_name = s.partition_name
                                WHERE tp.table_owner = rec.owner
                                AND tp.table_name = rec.table_name
                                AND tp.tablespace_name = v_source_tablespace
                                ORDER BY tp.partition_position
                            ) LOOP
                                v_lob_storage_clause := get_lob_storage_clause(
                                    rec.owner, rec.table_name, v_shrink_tablespace
                                );
                                
                                v_sql := 'ALTER TABLE ' || rec.owner || '.' || rec.table_name || 
                                        ' MOVE PARTITION ' || part_rec.partition_name || 
                                        ' TABLESPACE ' || v_shrink_tablespace;
                                
                                IF v_lob_storage_clause IS NOT NULL THEN
                                    v_sql := v_sql || ' ' || v_lob_storage_clause;
                                END IF;
                                
                                DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' ||
                                                    'Partition: ' || part_rec.partition_name || 
                                                    ' (' || part_rec.size_mb || ' MB)');
                                
                                BEGIN
                                    DBMS_APPLICATION_INFO.SET_ACTION('Moving partition ' || part_rec.partition_name);
                                    EXECUTE IMMEDIATE v_sql;
                                    DBMS_OUTPUT.PUT_LINE('      ✓ Moved');
                                    v_part_moved := v_part_moved + 1;
                                EXCEPTION
                                    WHEN OTHERS THEN
                                        DBMS_OUTPUT.PUT_LINE('      ✗ Failed: ' || SQLERRM);
                                END;
                            END LOOP;
                            
                            DBMS_OUTPUT.PUT_LINE('    Partitions moved: ' || v_part_moved || ' / ' || v_partition_count);
                            
                            IF v_part_moved = v_partition_count THEN
                                v_part_lob_moved := v_part_lob_moved + 1;
                            END IF;
                        END;
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('    [DRY RUN - Would move ' || v_partition_count || ' partitions]');
                    END IF;
                END IF;
                
                DBMS_OUTPUT.PUT_LINE('');
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('Partitioned LOB tables processed: ' || v_part_lob_moved || ' / ' || v_total_part_lob_tables);
        END;
    END IF;
    
    v_phase_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_phase_start_time));
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Phase duration: ' || ROUND(v_phase_duration/60, 2) || ' minutes');
    
    -- ============================================================================
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('PHASE 4: RESIZE SOURCE TABLESPACE');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    v_phase_start_time := SYSTIMESTAMP;
    
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'PHASE_4_RESIZE_SOURCE'
    );
    
    -- Calculate new source size (used + buffer)
    v_new_source_size_mb := v_source_used_mb + v_buffer_mb;
    
    DBMS_OUTPUT.PUT_LINE('Resizing source tablespace to reclaim space...');
    DBMS_OUTPUT.PUT_LINE('  Current size: ' || v_source_size_mb || ' MB');
    DBMS_OUTPUT.PUT_LINE('  New size:     ' || v_new_source_size_mb || ' MB');
    DBMS_OUTPUT.PUT_LINE('  Space reclaimed: ' || (v_source_size_mb - v_new_source_size_mb) || ' MB (' ||
                         ROUND((v_source_size_mb - v_new_source_size_mb)/1024, 2) || ' GB)');
    
    IF v_dry_run = 'N' THEN
        BEGIN
            FOR df_rec IN (
                SELECT file_name, file_id, bytes
                FROM dba_data_files
                WHERE tablespace_name = v_source_tablespace
                ORDER BY file_id
            ) LOOP
                BEGIN
                    v_sql := 'ALTER DATABASE DATAFILE ''' || df_rec.file_name || 
                            ''' RESIZE ' || v_new_source_size_mb || 'M';
                    
                    DBMS_OUTPUT.PUT_LINE('');
                    DBMS_OUTPUT.PUT_LINE('Resizing datafile: ' || df_rec.file_name);
                    
                    EXECUTE IMMEDIATE v_sql;
                    DBMS_OUTPUT.PUT_LINE('✓ Resized successfully');
                    
                    log_recovery('PHASE_4', df_rec.file_name,
                                'ALTER DATABASE DATAFILE ''' || df_rec.file_name || 
                                ''' RESIZE ' || CEIL(df_rec.bytes/1024/1024) || 'M',
                                'RESIZED');
                    
                    EXIT; -- Only resize first datafile in simple case
                EXCEPTION
                    WHEN OTHERS THEN
                        IF SQLCODE = -3297 THEN
                            DBMS_OUTPUT.PUT_LINE('⚠️  Cannot shrink below HWM, trying smaller size...');
                            -- Try with slightly larger size
                            v_new_source_size_mb := v_new_source_size_mb + 1024;
                            v_sql := 'ALTER DATABASE DATAFILE ''' || df_rec.file_name || 
                                    ''' RESIZE ' || v_new_source_size_mb || 'M';
                            EXECUTE IMMEDIATE v_sql;
                            DBMS_OUTPUT.PUT_LINE('✓ Resized to ' || v_new_source_size_mb || ' MB');
                        ELSE
                            DBMS_OUTPUT.PUT_LINE('✗ Resize failed: ' || SQLERRM);
                            RAISE;
                        END IF;
                END;
            END LOOP;
        END;
    ELSE
        DBMS_OUTPUT.PUT_LINE('[DRY RUN - Resize not executed]');
    END IF;
    
    v_phase_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_phase_start_time));
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Phase duration: ' || ROUND(v_phase_duration, 2) || ' seconds');
    
    -- ============================================================================
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('PHASE 5: MOVE OBJECTS BACK TO SOURCE TABLESPACE');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    v_phase_start_time := SYSTIMESTAMP;
    
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'PHASE_5_MOVE_BACK'
    );
    
    -- Reset counters
    v_simple_moved := 0;
    v_lob_moved := 0;
    v_part_lob_moved := 0;
    
    -- ======================
    -- PHASE 5A: Simple Tables
    -- ======================
    IF v_total_simple_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('--- PHASE 5A: Moving Simple Tables Back (ONLINE) ---');
        DBMS_OUTPUT.PUT_LINE('');
        
        DECLARE
            v_batch_count NUMBER := 0;
        BEGIN
            FOR rec IN (
                SELECT t.owner, t.table_name,
                       ROUND(NVL(s.bytes, 0)/1024/1024, 2) AS size_mb
                FROM dba_tables t
                LEFT JOIN dba_segments s ON t.owner = s.owner AND t.table_name = s.segment_name
                WHERE t.tablespace_name = v_shrink_tablespace
                AND t.partitioned = 'NO'
                AND t.nested = 'NO'
                AND NOT EXISTS (
                    SELECT 1 FROM dba_lobs l 
                    WHERE l.owner = t.owner AND l.table_name = t.table_name
                )
                ORDER BY NVL(s.bytes, 0) DESC
            ) LOOP
                v_batch_count := v_batch_count + 1;
                
                IF MOD(v_batch_count - 1, v_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('Batch ' || CEIL(v_batch_count / v_objects_per_batch) || ':');
                END IF;
                
                v_sql := 'ALTER TABLE ' || rec.owner || '.' || rec.table_name || 
                        ' MOVE TABLESPACE ' || v_source_tablespace || ' ONLINE UPDATE INDEXES';
                
                DBMS_OUTPUT.PUT_LINE('  [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' || 
                                    rec.owner || '.' || rec.table_name || ' (' || rec.size_mb || ' MB)');
                
                IF v_dry_run = 'N' THEN
                    v_cmd_start_time := SYSTIMESTAMP;
                    BEGIN
                        DBMS_APPLICATION_INFO.SET_ACTION('Moving back ' || rec.owner || '.' || rec.table_name);
                        EXECUTE IMMEDIATE v_sql;
                        v_cmd_end_time := SYSTIMESTAMP;
                        v_cmd_duration := EXTRACT(SECOND FROM (v_cmd_end_time - v_cmd_start_time));
                        DBMS_OUTPUT.PUT_LINE('    ✓ Moved back successfully (' || ROUND(v_cmd_duration, 2) || 's)');
                        v_simple_moved := v_simple_moved + 1;
                    EXCEPTION
                        WHEN OTHERS THEN
                            DBMS_OUTPUT.PUT_LINE('    ✗ Failed: ' || SQLERRM);
                            log_recovery('PHASE_5A', rec.owner || '.' || rec.table_name,
                                        v_sql, 'FAILED_MOVE_BACK');
                    END;
                ELSE
                    DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                END IF;
                
                IF MOD(v_batch_count, v_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('');
                END IF;
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('Simple tables moved back: ' || v_simple_moved || ' / ' || v_total_simple_tables);
        END;
    END IF;
    
    -- ======================
    -- PHASE 5B: LOB Tables - DBMS_REDEFINITION
    -- ======================
    IF v_total_lob_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('--- PHASE 5B: Moving LOB Tables Back (DBMS_REDEFINITION) ---');
        DBMS_OUTPUT.PUT_LINE('');
        
        DECLARE
            v_batch_count NUMBER := 0;
            v_interim_table VARCHAR2(30);
            v_num_errors PLS_INTEGER;
        BEGIN
            FOR rec IN (
                SELECT DISTINCT t.owner, t.table_name,
                       ROUND(NVL(s.bytes, 0)/1024/1024, 2) AS table_size_mb,
                       COUNT(DISTINCT l.column_name) AS lob_count
                FROM dba_tables t
                LEFT JOIN dba_segments s ON t.owner = s.owner AND t.table_name = s.segment_name
                INNER JOIN dba_lobs l ON t.owner = l.owner AND t.table_name = l.table_name
                WHERE t.tablespace_name = v_shrink_tablespace
                AND t.partitioned = 'NO'
                GROUP BY t.owner, t.table_name, s.bytes
                ORDER BY NVL(s.bytes, 0) DESC
            ) LOOP
                v_batch_count := v_batch_count + 1;
                
                IF MOD(v_batch_count - 1, v_lob_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('Batch ' || CEIL(v_batch_count / v_lob_objects_per_batch) || ':');
                END IF;
                
                v_interim_table := 'INT_' || SUBSTR(rec.table_name, 1, 24);
                v_lob_storage_clause := get_lob_storage_clause(rec.owner, rec.table_name, v_source_tablespace);
                
                DBMS_OUTPUT.PUT_LINE('  [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] ' || 
                                    rec.owner || '.' || rec.table_name || 
                                    ' (' || rec.table_size_mb || ' MB, ' || rec.lob_count || ' LOBs)');
                
                IF v_dry_run = 'N' THEN
                    v_cmd_start_time := SYSTIMESTAMP;
                    BEGIN
                        DBMS_APPLICATION_INFO.SET_ACTION('REDEF back: ' || rec.owner || '.' || rec.table_name);
                        
                        DBMS_OUTPUT.PUT_LINE('    [' || TO_CHAR(SYSTIMESTAMP, 'HH24:MI:SS') || '] Starting redefinition...');
                        
                        DBMS_REDEFINITION.CAN_REDEF_TABLE(
                            uname => rec.owner,
                            tname => rec.table_name,
                            options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                        );
                        
                        v_sql := 'CREATE TABLE ' || rec.owner || '.' || v_interim_table || 
                                ' TABLESPACE ' || v_source_tablespace || ' AS SELECT * FROM ' || 
                                rec.owner || '.' || rec.table_name || ' WHERE 1=0';
                        EXECUTE IMMEDIATE v_sql;
                        
                        IF v_lob_storage_clause IS NOT NULL THEN
                            v_sql := 'ALTER TABLE ' || rec.owner || '.' || v_interim_table || 
                                    ' MOVE TABLESPACE ' || v_source_tablespace || ' ' || v_lob_storage_clause;
                            EXECUTE IMMEDIATE v_sql;
                        END IF;
                        
                        DBMS_REDEFINITION.START_REDEF_TABLE(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table,
                            options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                        );
                        
                        DBMS_REDEFINITION.COPY_TABLE_DEPENDENTS(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table,
                            copy_indexes => DBMS_REDEFINITION.CONS_ORIG_PARAMS,
                            copy_triggers => TRUE,
                            copy_constraints => TRUE,
                            copy_privileges => TRUE,
                            ignore_errors => FALSE,
                            num_errors => v_num_errors,
                            copy_statistics => TRUE
                        );
                        
                        DBMS_REDEFINITION.SYNC_INTERIM_TABLE(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table
                        );
                        
                        DBMS_REDEFINITION.FINISH_REDEF_TABLE(
                            uname => rec.owner,
                            orig_table => rec.table_name,
                            int_table => v_interim_table
                        );
                        
                        v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                        EXECUTE IMMEDIATE v_sql;
                        
                        v_cmd_end_time := SYSTIMESTAMP;
                        v_cmd_duration := EXTRACT(SECOND FROM (v_cmd_end_time - v_cmd_start_time));
                        DBMS_OUTPUT.PUT_LINE('    ✓ Moved back successfully (' || ROUND(v_cmd_duration/60, 2) || ' min)');
                        v_lob_moved := v_lob_moved + 1;
                        
                    EXCEPTION
                        WHEN OTHERS THEN
                            DBMS_OUTPUT.PUT_LINE('    ✗ Failed: ' || SQLERRM);
                            BEGIN
                                DBMS_REDEFINITION.ABORT_REDEF_TABLE(
                                    uname => rec.owner,
                                    orig_table => rec.table_name,
                                    int_table => v_interim_table
                                );
                                v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                                EXECUTE IMMEDIATE v_sql;
                            EXCEPTION
                                WHEN OTHERS THEN NULL;
                            END;
                            log_recovery('PHASE_5B', rec.owner || '.' || rec.table_name,
                                        '-- Manual intervention required', 'FAILED_MOVE_BACK');
                    END;
                ELSE
                    DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                END IF;
                
                IF MOD(v_batch_count, v_lob_objects_per_batch) = 0 THEN
                    DBMS_OUTPUT.PUT_LINE('');
                END IF;
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('LOB tables moved back: ' || v_lob_moved || ' / ' || v_total_lob_tables);
        END;
    END IF;
    
    -- ======================
    -- PHASE 5C: Partitioned LOB Tables
    -- ======================
    IF v_total_part_lob_tables > 0 THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('--- PHASE 5C: Moving Partitioned LOB Tables Back ---');
        DBMS_OUTPUT.PUT_LINE('');
        
        DECLARE
            v_batch_count NUMBER := 0;
            v_interim_table VARCHAR2(30);
            v_num_errors PLS_INTEGER;
            v_partition_count NUMBER;
            v_table_size_gb NUMBER;
            v_use_redef BOOLEAN;
        BEGIN
            FOR rec IN (
                SELECT 
                    t.owner,
                    t.table_name,
                    pt.partitioning_type,
                    COUNT(DISTINCT tp.partition_name) AS partition_count,
                    ROUND(NVL(SUM(s.bytes), 0)/1024/1024/1024, 2) AS total_size_gb
                FROM dba_tables t
                INNER JOIN dba_part_tables pt ON t.owner = pt.owner AND t.table_name = pt.table_name
                INNER JOIN dba_tab_partitions tp ON t.owner = tp.table_owner AND t.table_name = tp.table_name
                LEFT JOIN dba_segments s ON tp.table_owner = s.owner 
                                         AND tp.table_name = s.segment_name 
                                         AND tp.partition_name = s.partition_name
                WHERE t.tablespace_name = v_shrink_tablespace
                OR tp.tablespace_name = v_shrink_tablespace
                GROUP BY t.owner, t.table_name, pt.partitioning_type
                ORDER BY SUM(s.bytes) DESC
            ) LOOP
                v_batch_count := v_batch_count + 1;
                v_partition_count := rec.partition_count;
                v_table_size_gb := rec.total_size_gb;
                v_use_redef := (v_partition_count <= v_partition_max_count AND 
                               v_table_size_gb <= v_partition_max_size_gb);
                
                DBMS_OUTPUT.PUT_LINE('Table ' || v_batch_count || ': ' || rec.owner || '.' || rec.table_name);
                
                IF v_use_redef THEN
                    DBMS_OUTPUT.PUT_LINE('    Strategy: DBMS_REDEFINITION');
                    
                    IF v_dry_run = 'N' THEN
                        v_interim_table := 'INT_' || SUBSTR(rec.table_name, 1, 24);
                        BEGIN
                            DBMS_REDEFINITION.CAN_REDEF_TABLE(
                                uname => rec.owner,
                                tname => rec.table_name,
                                options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                            );
                            
                            v_sql := 'CREATE TABLE ' || rec.owner || '.' || v_interim_table || 
                                    ' TABLESPACE ' || v_source_tablespace || 
                                    ' AS SELECT * FROM ' || rec.owner || '.' || rec.table_name || 
                                    ' WHERE 1=0';
                            EXECUTE IMMEDIATE v_sql;
                            
                            DBMS_REDEFINITION.START_REDEF_TABLE(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table,
                                options_flag => DBMS_REDEFINITION.CONS_USE_ROWID
                            );
                            
                            DBMS_REDEFINITION.COPY_TABLE_DEPENDENTS(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table,
                                copy_indexes => DBMS_REDEFINITION.CONS_ORIG_PARAMS,
                                copy_triggers => TRUE,
                                copy_constraints => TRUE,
                                copy_privileges => TRUE,
                                ignore_errors => FALSE,
                                num_errors => v_num_errors
                            );
                            
                            DBMS_REDEFINITION.SYNC_INTERIM_TABLE(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table
                            );
                            
                            DBMS_REDEFINITION.FINISH_REDEF_TABLE(
                                uname => rec.owner,
                                orig_table => rec.table_name,
                                int_table => v_interim_table
                            );
                            
                            v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                            EXECUTE IMMEDIATE v_sql;
                            
                            DBMS_OUTPUT.PUT_LINE('    ✓ Moved back successfully');
                            v_part_lob_moved := v_part_lob_moved + 1;
                        EXCEPTION
                            WHEN OTHERS THEN
                                DBMS_OUTPUT.PUT_LINE('    ✗ Failed: ' || SQLERRM);
                                BEGIN
                                    DBMS_REDEFINITION.ABORT_REDEF_TABLE(
                                        uname => rec.owner,
                                        orig_table => rec.table_name,
                                        int_table => v_interim_table
                                    );
                                    v_sql := 'DROP TABLE ' || rec.owner || '.' || v_interim_table || ' PURGE';
                                    EXECUTE IMMEDIATE v_sql;
                                EXCEPTION
                                    WHEN OTHERS THEN NULL;
                                END;
                        END;
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                    END IF;
                ELSE
                    DBMS_OUTPUT.PUT_LINE('    Strategy: Partition-by-partition');
                    
                    IF v_dry_run = 'N' THEN
                        DECLARE
                            v_part_moved NUMBER := 0;
                        BEGIN
                            FOR part_rec IN (
                                SELECT partition_name
                                FROM dba_tab_partitions tp
                                WHERE tp.table_owner = rec.owner
                                AND tp.table_name = rec.table_name
                                AND tp.tablespace_name = v_shrink_tablespace
                                ORDER BY tp.partition_position
                            ) LOOP
                                v_lob_storage_clause := get_lob_storage_clause(
                                    rec.owner, rec.table_name, v_source_tablespace
                                );
                                
                                v_sql := 'ALTER TABLE ' || rec.owner || '.' || rec.table_name || 
                                        ' MOVE PARTITION ' || part_rec.partition_name || 
                                        ' TABLESPACE ' || v_source_tablespace;
                                
                                IF v_lob_storage_clause IS NOT NULL THEN
                                    v_sql := v_sql || ' ' || v_lob_storage_clause;
                                END IF;
                                
                                BEGIN
                                    EXECUTE IMMEDIATE v_sql;
                                    v_part_moved := v_part_moved + 1;
                                EXCEPTION
                                    WHEN OTHERS THEN
                                        DBMS_OUTPUT.PUT_LINE('      ✗ Partition ' || part_rec.partition_name || 
                                                           ' failed: ' || SQLERRM);
                                END;
                            END LOOP;
                            
                            DBMS_OUTPUT.PUT_LINE('    Partitions moved back: ' || v_part_moved);
                            IF v_part_moved > 0 THEN
                                v_part_lob_moved := v_part_lob_moved + 1;
                            END IF;
                        END;
                    ELSE
                        DBMS_OUTPUT.PUT_LINE('    [DRY RUN]');
                    END IF;
                END IF;
                DBMS_OUTPUT.PUT_LINE('');
            END LOOP;
            
            DBMS_OUTPUT.PUT_LINE('Partitioned LOB tables moved back: ' || v_part_lob_moved || ' / ' || v_total_part_lob_tables);
        END;
    END IF;
    
    -- Rebuild indexes that are in shrink tablespace
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Rebuilding indexes...');
    
    DECLARE
        v_idx_count NUMBER := 0;
    BEGIN
        FOR idx_rec IN (
            SELECT owner, index_name, tablespace_name
            FROM dba_indexes
            WHERE tablespace_name = v_shrink_tablespace
            AND index_type != 'LOB'
            ORDER BY owner, index_name
        ) LOOP
            v_sql := 'ALTER INDEX ' || idx_rec.owner || '.' || idx_rec.index_name || 
                    ' REBUILD TABLESPACE ' || v_source_tablespace || ' ONLINE';
            
            IF v_dry_run = 'N' THEN
                BEGIN
                    EXECUTE IMMEDIATE v_sql;
                    v_idx_count := v_idx_count + 1;
                EXCEPTION
                    WHEN OTHERS THEN
                        DBMS_OUTPUT.PUT_LINE('  ✗ Index ' || idx_rec.owner || '.' || idx_rec.index_name || 
                                           ' rebuild failed: ' || SQLERRM);
                END;
            END IF;
        END LOOP;
        
        IF v_dry_run = 'N' THEN
            DBMS_OUTPUT.PUT_LINE('✓ Rebuilt ' || v_idx_count || ' indexes');
        ELSE
            DBMS_OUTPUT.PUT_LINE('[DRY RUN]');
        END IF;
    END;
    
    v_phase_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_phase_start_time));
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Phase duration: ' || ROUND(v_phase_duration/60, 2) || ' minutes');
    
    -- ============================================================================
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('PHASE 6: VERIFY AND CLEANUP');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    v_phase_start_time := SYSTIMESTAMP;
    
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'PHASE_6_CLEANUP'
    );
    
    -- Verify shrink tablespace is empty
    DECLARE
        v_shrink_objects NUMBER := 0;
    BEGIN
        IF v_dry_run = 'N' THEN
            SELECT COUNT(*)
            INTO v_shrink_objects
            FROM dba_segments
            WHERE tablespace_name = v_shrink_tablespace;
            
            DBMS_OUTPUT.PUT_LINE('Verification:');
            DBMS_OUTPUT.PUT_LINE('  Objects remaining in ' || v_shrink_tablespace || ': ' || v_shrink_objects);
            
            IF v_shrink_objects = 0 THEN
                DBMS_OUTPUT.PUT_LINE('  ✓ Shrink tablespace is empty');
                
                v_sql := 'DROP TABLESPACE ' || v_shrink_tablespace || ' INCLUDING CONTENTS AND DATAFILES';
                
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('--- Manual Cleanup Required ---');
                DBMS_OUTPUT.PUT_LINE('The following command was NOT executed automatically.');
                DBMS_OUTPUT.PUT_LINE('Please review and execute manually when ready:');
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE(v_sql || ';');
                DBMS_OUTPUT.PUT_LINE('');
            ELSE
                DBMS_OUTPUT.PUT_LINE('  ✗ WARNING: Shrink tablespace is not empty!');
                DBMS_OUTPUT.PUT_LINE('  Please investigate before dropping.');
                DBMS_OUTPUT.PUT_LINE('');
                DBMS_OUTPUT.PUT_LINE('  Query to check objects:');
                DBMS_OUTPUT.PUT_LINE('  SELECT owner, segment_name, segment_type, bytes/1024/1024 AS size_mb');
                DBMS_OUTPUT.PUT_LINE('  FROM dba_segments');
                DBMS_OUTPUT.PUT_LINE('  WHERE tablespace_name = ''' || v_shrink_tablespace || ''';');
            END IF;
        ELSE
            DBMS_OUTPUT.PUT_LINE('[DRY RUN - Verification skipped]');
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('After execution, manually drop shrink tablespace:');
            DBMS_OUTPUT.PUT_LINE('DROP TABLESPACE ' || v_shrink_tablespace || ' INCLUDING CONTENTS AND DATAFILES;');
        END IF;
    END;
    
    v_phase_duration := EXTRACT(SECOND FROM (SYSTIMESTAMP - v_phase_start_time));
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('Phase duration: ' || ROUND(v_phase_duration, 2) || ' seconds');
    
    -- ============================================================================
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    DBMS_OUTPUT.PUT_LINE('DEFRAGMENTATION COMPLETE');
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    
    IF v_dry_run = 'N' THEN
        DECLARE
            v_final_source_size_mb NUMBER;
        BEGIN
            SELECT CEIL(SUM(bytes)/1024/1024)
            INTO v_final_source_size_mb
            FROM dba_data_files
            WHERE tablespace_name = v_source_tablespace;
            
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('Results:');
            DBMS_OUTPUT.PUT_LINE('  Original Size:    ' || v_source_size_mb || ' MB (' || 
                                 ROUND(v_source_size_mb/1024, 2) || ' GB)');
            DBMS_OUTPUT.PUT_LINE('  Final Size:       ' || v_final_source_size_mb || ' MB (' || 
                                 ROUND(v_final_source_size_mb/1024, 2) || ' GB)');
            DBMS_OUTPUT.PUT_LINE('  Space Reclaimed:  ' || (v_source_size_mb - v_final_source_size_mb) || ' MB (' || 
                                 ROUND((v_source_size_mb - v_final_source_size_mb)/1024, 2) || ' GB)');
            DBMS_OUTPUT.PUT_LINE('  Efficiency Gain:  ' || 
                                 ROUND(((v_source_size_mb - v_final_source_size_mb) / v_source_size_mb) * 100, 2) || '%');
            DBMS_OUTPUT.PUT_LINE('');
            DBMS_OUTPUT.PUT_LINE('Objects Processed:');
            DBMS_OUTPUT.PUT_LINE('  Category 1 (Simple):         ' || v_simple_moved || ' / ' || v_total_simple_tables);
            DBMS_OUTPUT.PUT_LINE('  Category 2 (LOB):            ' || v_lob_moved || ' / ' || v_total_lob_tables);
            DBMS_OUTPUT.PUT_LINE('  Category 3 (Partitioned LOB):' || v_part_lob_moved || ' / ' || v_total_part_lob_tables);
            IF v_total_long_tables > 0 THEN
                DBMS_OUTPUT.PUT_LINE('  Category 4 (LONG - skipped): ' || v_total_long_tables);
            END IF;
        END;
    ELSE
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('DRY RUN Summary:');
        DBMS_OUTPUT.PUT_LINE('  Would process:');
        DBMS_OUTPUT.PUT_LINE('    ' || v_total_simple_tables || ' simple tables');
        DBMS_OUTPUT.PUT_LINE('    ' || v_total_lob_tables || ' LOB tables');
        DBMS_OUTPUT.PUT_LINE('    ' || v_total_part_lob_tables || ' partitioned LOB tables');
        IF v_total_long_tables > 0 THEN
            DBMS_OUTPUT.PUT_LINE('    ' || v_total_long_tables || ' LONG tables (will be skipped)');
        END IF;
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('  Estimated space savings: ' || 
                             (v_source_size_mb - v_new_source_size_mb) || ' MB (' || 
                             ROUND((v_source_size_mb - v_new_source_size_mb)/1024, 2) || ' GB)');
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('To execute for real, run with: Dry Run Mode? N');
    END IF;
    
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('✓ All phases completed successfully!');
    
    DBMS_APPLICATION_INFO.SET_MODULE(
        module_name => 'DEFRAG_V3',
        action_name => 'COMPLETED'
    );
    
    DBMS_OUTPUT.PUT_LINE('================================================================================');
    
    -- Print recovery log if any issues
    IF v_recovery_log.COUNT > 0 THEN
        print_recovery_log();
    END IF;
    
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('================================================================================');
        DBMS_OUTPUT.PUT_LINE('✗ FATAL ERROR');
        DBMS_OUTPUT.PUT_LINE('================================================================================');
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        DBMS_OUTPUT.PUT_LINE('Code:  ' || SQLCODE);
        DBMS_OUTPUT.PUT_LINE('');
        
        -- Print recovery log
        print_recovery_log();
        
        DBMS_OUTPUT.PUT_LINE('');
        DBMS_OUTPUT.PUT_LINE('Manual cleanup may be required:');
        DBMS_OUTPUT.PUT_LINE('DROP TABLESPACE ' || v_shrink_tablespace || ' INCLUDING CONTENTS AND DATAFILES;');
        RAISE;
END;
/

SET FEEDBACK ON
SET VERIFY ON
SET TIMING OFF

PROMPT
PROMPT ================================================================================
PROMPT Script Part 1 execution finished.
PROMPT ================================================================================
