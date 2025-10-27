/*******************************************************************************
 Script Name: lob_shrink_partitions.sql
 Purpose: Move LOB partitions to shrink tablespace and reclaim space
 Version: 1.0
 Oracle: 19c
 Author: Oracle DBA Team
 Date: 24-OCT-2025
*******************************************************************************/

-- Disable feedback for cleaner output
SET FEEDBACK OFF
SET VERIFY OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET TIMING ON
SET LINESIZE 200
SET PAGESIZE 9999
SET ECHO ON

-- Generate timestamp for log file
COLUMN today_timestamp NEW_VALUE log_timestamp
SELECT TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') AS today_timestamp FROM DUAL;

-- Start spooling
SPOOL lob_shrink_&log_timestamp..log APPEND

PROMPT ================================================================================
PROMPT LOB PARTITION SHRINK SCRIPT - Oracle 19c
PROMPT ================================================================================
PROMPT Start Time: 
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS') AS start_time FROM DUAL;
PROMPT ================================================================================

-- Accept input parameters
ACCEPT p_source_tbs PROMPT 'Enter SOURCE TABLESPACE name: '
ACCEPT p_compression PROMPT 'Enter COMPRESSION TYPE (NOCOMPRESS/COMPRESS LOW/COMPRESS MEDIUM/COMPRESS HIGH): '
ACCEPT p_parallel PROMPT 'Enter PARALLEL DEGREE (e.g., 4, 8, 16): '
ACCEPT p_dry_run PROMPT 'DRY RUN MODE? (Y/N): '

-- Set variables
VARIABLE v_source_tbs VARCHAR2(30)
VARIABLE v_temp_tbs VARCHAR2(30)
VARIABLE v_compression VARCHAR2(50)
VARIABLE v_parallel NUMBER
VARIABLE v_dry_run VARCHAR2(1)

EXEC :v_source_tbs := UPPER('&p_source_tbs');
EXEC :v_temp_tbs := UPPER('&p_source_tbs') || '_SHRINK';
EXEC :v_compression := UPPER('&p_compression');
EXEC :v_parallel := TO_NUMBER('&p_parallel');
EXEC :v_dry_run := UPPER('&p_dry_run');

PROMPT
PROMPT ================================================================================
PROMPT INPUT PARAMETERS
PROMPT ================================================================================
PROMPT Source Tablespace.....: &p_source_tbs
PROMPT Temp Tablespace.......: &p_source_tbs._SHRINK
PROMPT Compression Type......: &p_compression
PROMPT Parallel Degree.......: &p_parallel
PROMPT Dry Run Mode..........: &p_dry_run
PROMPT ================================================================================
PROMPT

-- Main PL/SQL Block
DECLARE
    v_source_tbs        VARCHAR2(30) := :v_source_tbs;
    v_temp_tbs          VARCHAR2(30) := :v_temp_tbs;
    v_compression       VARCHAR2(50) := :v_compression;
    v_parallel          NUMBER := :v_parallel;
    v_dry_run           VARCHAR2(1) := :v_dry_run;
    
    v_sql               VARCHAR2(4000);
    v_start_time        NUMBER;
    v_end_time          NUMBER;
    v_elapsed_sec       NUMBER;
    v_start_ts          TIMESTAMP;
    v_end_ts            TIMESTAMP;
    
    v_total_partitions  NUMBER := 0;
    v_success_count     NUMBER := 0;
    v_fail_count        NUMBER := 0;
    v_total_size_gb     NUMBER := 0;
    
    v_initial_used_gb   NUMBER;
    v_initial_free_gb   NUMBER;
    v_final_used_gb     NUMBER;
    v_final_free_gb     NUMBER;
    
    v_tbs_exists        NUMBER;
    v_temp_tbs_exists   NUMBER;
    
    TYPE t_lob_rec IS RECORD (
        owner               VARCHAR2(128),
        table_name          VARCHAR2(128),
        partition_name      VARCHAR2(128),
        lob_columns         VARCHAR2(4000),
        size_gb             NUMBER
    );
    
    TYPE t_lob_tab IS TABLE OF t_lob_rec INDEX BY PLS_INTEGER;
    v_lob_list t_lob_tab;
    
    CURSOR c_lob_partitions IS
        SELECT owner, table_name, partition_name, lob_columns, size_gb
        FROM (
            SELECT DISTINCT
                l.owner,
                l.table_name,
                tp.partition_name,
                LISTAGG(l.column_name, ',') WITHIN GROUP (ORDER BY l.column_name) AS lob_columns,
                ROUND(SUM(s.bytes)/1024/1024/1024, 2) AS size_gb
            FROM dba_lobs l
            JOIN dba_lob_partitions lp 
                ON l.owner = lp.table_owner 
                AND l.table_name = lp.table_name 
                AND l.column_name = lp.column_name
            JOIN dba_tab_partitions tp 
                ON l.owner = tp.table_owner 
                AND l.table_name = tp.table_name 
                AND lp.lob_partition_name LIKE '%' || tp.partition_name || '%'
            JOIN dba_segments s 
                ON lp.lob_partition_name = s.partition_name 
                AND l.segment_name = s.segment_name
                AND s.owner = l.owner
            WHERE s.tablespace_name = v_source_tbs
                AND s.segment_type = 'LOBSEGMENT'
            GROUP BY l.owner, l.table_name, tp.partition_name
            ORDER BY size_gb DESC
        );
    
    PROCEDURE log_message(p_message VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('[' || TO_CHAR(SYSTIMESTAMP, 'DD-MON-YYYY HH24:MI:SS') || '] ' || p_message);
    END;
    
    PROCEDURE capture_tbs_metrics IS
    BEGIN
        SELECT ROUND(SUM(bytes)/1024/1024/1024, 2)
        INTO v_initial_used_gb
        FROM dba_segments
        WHERE tablespace_name = v_source_tbs;
        
        SELECT ROUND(SUM(bytes)/1024/1024/1024, 2)
        INTO v_initial_free_gb
        FROM dba_free_space
        WHERE tablespace_name = v_source_tbs;
        
        log_message('Initial TBS Metrics - Used: ' || v_initial_used_gb || ' GB, Free: ' || v_initial_free_gb || ' GB');
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_initial_free_gb := 0;
    END;
    
BEGIN
    log_message('================================================================================');
    log_message('INITIALIZATION PHASE');
    log_message('================================================================================');
    
    -- Set session tracking
    DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'INITIALIZATION');
    
    -- Verify source tablespace exists
    SELECT COUNT(*) INTO v_tbs_exists 
    FROM dba_tablespaces 
    WHERE tablespace_name = v_source_tbs;
    
    IF v_tbs_exists = 0 THEN
        log_message('ERROR: Source tablespace ' || v_source_tbs || ' does not exist!');
        RETURN;
    END IF;
    
    log_message('Source tablespace ' || v_source_tbs || ' verified.');
    
    -- Check if temp tablespace exists
    SELECT COUNT(*) INTO v_temp_tbs_exists 
    FROM dba_tablespaces 
    WHERE tablespace_name = v_temp_tbs;
    
    IF v_temp_tbs_exists = 0 AND v_dry_run = 'N' THEN
        log_message('WARNING: Temp tablespace ' || v_temp_tbs || ' does not exist!');
        log_message('Please create it manually before running in EXECUTE mode:');
        log_message('  CREATE TABLESPACE ' || v_temp_tbs || ' DATAFILE SIZE 10G AUTOEXTEND ON;');
        RETURN;
    END IF;
    
    -- Capture initial metrics
    capture_tbs_metrics;
    
    log_message('================================================================================');
    log_message('DISCOVERY PHASE');
    log_message('================================================================================');
    
    DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'DISCOVERY');
    
    -- Load LOB partitions
    OPEN c_lob_partitions;
    FETCH c_lob_partitions BULK COLLECT INTO v_lob_list;
    CLOSE c_lob_partitions;
    
    v_total_partitions := v_lob_list.COUNT;
    
    IF v_total_partitions = 0 THEN
        log_message('No LOB partitions found in tablespace ' || v_source_tbs);
        RETURN;
    END IF;
    
    -- Calculate total size
    FOR i IN 1..v_lob_list.COUNT LOOP
        v_total_size_gb := v_total_size_gb + v_lob_list(i).size_gb;
    END LOOP;
    
    log_message('Total Partitions Found: ' || v_total_partitions);
    log_message('Total LOB Size: ' || ROUND(v_total_size_gb, 2) || ' GB');
    log_message('================================================================================');
    
    -- List all partitions
    FOR i IN 1..v_lob_list.COUNT LOOP
        log_message('  [' || i || '] ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || 
                   '.' || v_lob_list(i).partition_name || ' | LOBs: ' || v_lob_list(i).lob_columns || 
                   ' | Size: ' || v_lob_list(i).size_gb || ' GB');
    END LOOP;
    
    log_message('================================================================================');
    
    IF v_dry_run = 'Y' THEN
        log_message('DRY RUN MODE - Generating commands without execution');
        log_message('================================================================================');
    END IF;
    
    -- PHASE 1: Move to Temp Tablespace
    log_message('================================================================================');
    log_message('PHASE 1: MOVING TO TEMPORARY TABLESPACE (' || v_temp_tbs || ')');
    log_message('================================================================================');
    
    FOR i IN 1..v_lob_list.COUNT LOOP
        BEGIN
            -- Build ALTER TABLE command
            v_sql := 'ALTER TABLE ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || 
                     ' MOVE PARTITION ' || v_lob_list(i).partition_name;
            
            -- Add LOB columns
            DECLARE
                v_lob_col VARCHAR2(128);
                v_lob_clause VARCHAR2(4000) := '';
                v_pos NUMBER := 1;
                v_comma NUMBER;
            BEGIN
                LOOP
                    v_comma := INSTR(v_lob_list(i).lob_columns, ',', v_pos);
                    IF v_comma = 0 THEN
                        v_lob_col := TRIM(SUBSTR(v_lob_list(i).lob_columns, v_pos));
                        v_lob_clause := v_lob_clause || ' LOB (' || v_lob_col || ') STORE AS (TABLESPACE ' || 
                                       v_temp_tbs || ' ' || v_compression || ')';
                        EXIT;
                    ELSE
                        v_lob_col := TRIM(SUBSTR(v_lob_list(i).lob_columns, v_pos, v_comma - v_pos));
                        v_lob_clause := v_lob_clause || ' LOB (' || v_lob_col || ') STORE AS (TABLESPACE ' || 
                                       v_temp_tbs || ' ' || v_compression || ')';
                        v_pos := v_comma + 1;
                    END IF;
                END LOOP;
                
                v_sql := v_sql || v_lob_clause || ' ONLINE PARALLEL ' || v_parallel;
            END;
            
            -- Update session info
            DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 
                'PHASE1: ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || '.' || 
                v_lob_list(i).partition_name || ' -> ' || v_temp_tbs);
            
            log_message('--------------------------------------------------------------------------------');
            log_message('[' || i || '/' || v_total_partitions || '] Processing: ' || 
                       v_lob_list(i).owner || '.' || v_lob_list(i).table_name || '.' || v_lob_list(i).partition_name);
            log_message('  LOB Columns: ' || v_lob_list(i).lob_columns);
            log_message('  Size: ' || v_lob_list(i).size_gb || ' GB');
            log_message('  Direction: ' || v_source_tbs || ' -> ' || v_temp_tbs);
            log_message('  SQL: ' || v_sql);
            
            IF v_dry_run = 'N' THEN
                v_start_time := DBMS_UTILITY.GET_TIME;
                v_start_ts := SYSTIMESTAMP;
                
                log_message('  Executing... START: ' || TO_CHAR(v_start_ts, 'HH24:MI:SS'));
                
                EXECUTE IMMEDIATE v_sql;
                
                v_end_time := DBMS_UTILITY.GET_TIME;
                v_end_ts := SYSTIMESTAMP;
                v_elapsed_sec := (v_end_time - v_start_time) / 100;
                
                log_message('  Completed! END: ' || TO_CHAR(v_end_ts, 'HH24:MI:SS') || 
                           ' | Duration: ' || ROUND(v_elapsed_sec/60, 2) || ' minutes');
                log_message('  Status: SUCCESS');
                
                v_success_count := v_success_count + 1;
            ELSE
                log_message('  Status: DRY RUN - Command generated only');
            END IF;
            
        EXCEPTION
            WHEN OTHERS THEN
                log_message('  Status: FAILED');
                log_message('  Error: ' || SQLERRM);
                v_fail_count := v_fail_count + 1;
        END;
    END LOOP;
    
    log_message('================================================================================');
    log_message('PHASE 1 COMPLETE');
    log_message('Success: ' || v_success_count || ' | Failed: ' || v_fail_count);
    log_message('================================================================================');
    
    -- PHASE 2: Move back to Source Tablespace
    IF v_dry_run = 'N' AND v_success_count > 0 THEN
        log_message('================================================================================');
        log_message('PHASE 2: MOVING BACK TO SOURCE TABLESPACE (' || v_source_tbs || ')');
        log_message('================================================================================');
        
        v_success_count := 0;
        v_fail_count := 0;
        
        FOR i IN 1..v_lob_list.COUNT LOOP
            BEGIN
                -- Build ALTER TABLE command
                v_sql := 'ALTER TABLE ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || 
                         ' MOVE PARTITION ' || v_lob_list(i).partition_name;
                
                -- Add LOB columns
                DECLARE
                    v_lob_col VARCHAR2(128);
                    v_lob_clause VARCHAR2(4000) := '';
                    v_pos NUMBER := 1;
                    v_comma NUMBER;
                BEGIN
                    LOOP
                        v_comma := INSTR(v_lob_list(i).lob_columns, ',', v_pos);
                        IF v_comma = 0 THEN
                            v_lob_col := TRIM(SUBSTR(v_lob_list(i).lob_columns, v_pos));
                            v_lob_clause := v_lob_clause || ' LOB (' || v_lob_col || ') STORE AS (TABLESPACE ' || 
                                           v_source_tbs || ' ' || v_compression || ')';
                            EXIT;
                        ELSE
                            v_lob_col := TRIM(SUBSTR(v_lob_list(i).lob_columns, v_pos, v_comma - v_pos));
                            v_lob_clause := v_lob_clause || ' LOB (' || v_lob_col || ') STORE AS (TABLESPACE ' || 
                                           v_source_tbs || ' ' || v_compression || ')';
                            v_pos := v_comma + 1;
                        END IF;
                    END LOOP;
                    
                    v_sql := v_sql || v_lob_clause || ' ONLINE PARALLEL ' || v_parallel;
                END;
                
                -- Update session info
                DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 
                    'PHASE2: ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || '.' || 
                    v_lob_list(i).partition_name || ' -> ' || v_source_tbs);
                
                log_message('--------------------------------------------------------------------------------');
                log_message('[' || i || '/' || v_total_partitions || '] Processing: ' || 
                           v_lob_list(i).owner || '.' || v_lob_list(i).table_name || '.' || v_lob_list(i).partition_name);
                log_message('  Direction: ' || v_temp_tbs || ' -> ' || v_source_tbs);
                log_message('  SQL: ' || v_sql);
                
                v_start_time := DBMS_UTILITY.GET_TIME;
                v_start_ts := SYSTIMESTAMP;
                
                log_message('  Executing... START: ' || TO_CHAR(v_start_ts, 'HH24:MI:SS'));
                
                EXECUTE IMMEDIATE v_sql;
                
                v_end_time := DBMS_UTILITY.GET_TIME;
                v_end_ts := SYSTIMESTAMP;
                v_elapsed_sec := (v_end_time - v_start_time) / 100;
                
                log_message('  Completed! END: ' || TO_CHAR(v_end_ts, 'HH24:MI:SS') || 
                           ' | Duration: ' || ROUND(v_elapsed_sec/60, 2) || ' minutes');
                log_message('  Status: SUCCESS');
                
                v_success_count := v_success_count + 1;
                
            EXCEPTION
                WHEN OTHERS THEN
                    log_message('  Status: FAILED');
                    log_message('  Error: ' || SQLERRM);
                    v_fail_count := v_fail_count + 1;
            END;
        END LOOP;
        
        log_message('================================================================================');
        log_message('PHASE 2 COMPLETE');
        log_message('Success: ' || v_success_count || ' | Failed: ' || v_fail_count);
        log_message('================================================================================');
    END IF;
    
    -- POST-EXECUTION VALIDATION
    IF v_dry_run = 'N' THEN
        log_message('================================================================================');
        log_message('POST-EXECUTION VALIDATION');
        log_message('================================================================================');
        
        DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'VALIDATION');
        
        -- Capture final metrics
        SELECT ROUND(SUM(bytes)/1024/1024/1024, 2)
        INTO v_final_used_gb
        FROM dba_segments
        WHERE tablespace_name = v_source_tbs;
        
        BEGIN
            SELECT ROUND(SUM(bytes)/1024/1024/1024, 2)
            INTO v_final_free_gb
            FROM dba_free_space
            WHERE tablespace_name = v_source_tbs;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_final_free_gb := 0;
        END;
        
        log_message('');
        log_message('TABLESPACE SIZE COMPARISON:');
        log_message('----------------------------');
        log_message('BEFORE:');
        log_message('  Used Space:  ' || v_initial_used_gb || ' GB');
        log_message('  Free Space:  ' || v_initial_free_gb || ' GB');
        log_message('  Total:       ' || (v_initial_used_gb + v_initial_free_gb) || ' GB');
        log_message('');
        log_message('AFTER:');
        log_message('  Used Space:  ' || v_final_used_gb || ' GB');
        log_message('  Free Space:  ' || v_final_free_gb || ' GB');
        log_message('  Total:       ' || (v_final_used_gb + v_final_free_gb) || ' GB');
        log_message('');
        log_message('SPACE RECLAIMED:');
        log_message('  Reduced Used:    ' || ROUND(v_initial_used_gb - v_final_used_gb, 2) || ' GB');
        log_message('  Increased Free:  ' || ROUND(v_final_free_gb - v_initial_free_gb, 2) || ' GB');
        log_message('  Reduction %:     ' || ROUND(((v_initial_used_gb - v_final_used_gb) / v_initial_used_gb) * 100, 2) || '%');
        log_message('================================================================================');
    END IF;
    
    -- Final cleanup
    DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'COMPLETED');
    
    log_message('');
    log_message('================================================================================');
    log_message('SCRIPT EXECUTION COMPLETED');
    log_message('================================================================================');
    
EXCEPTION
    WHEN OTHERS THEN
        log_message('FATAL ERROR: ' || SQLERRM);
        log_message('Error Stack: ' || DBMS_UTILITY.FORMAT_ERROR_STACK);
        RAISE;
END;
/

PROMPT
PROMPT ================================================================================
PROMPT End Time:
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS') AS end_time FROM DUAL;
PROMPT ================================================================================

SPOOL OFF
SET FEEDBACK ON
SET VERIFY ON
SET ECHO OFF

PROMPT
PROMPT Log file created: lob_shrink_&log_timestamp..log
PROMPT
