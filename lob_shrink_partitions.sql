/*******************************************************************************
 Script Name: lob_shrink_partitions.sql
 Purpose: Move LOB partitions to shrink tablespace and reclaim space
 Version: 2.0 (Final - Simplified cursor)
 Oracle: 19c
 Date: 27-OCT-2025
*******************************************************************************/

SET FEEDBACK OFF
SET VERIFY OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET TIMING ON
SET LINESIZE 200
SET PAGESIZE 9999
SET ECHO OFF
SET TERMOUT ON
SET TRIMSPOOL ON

COLUMN today_timestamp NEW_VALUE log_timestamp NOPRINT
SELECT TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') AS today_timestamp FROM DUAL;

SPOOL lob_shrink_&log_timestamp..log

PROMPT ================================================================================
PROMPT LOB PARTITION SHRINK SCRIPT - Oracle 19c
PROMPT ================================================================================
PROMPT Start Time: 
SELECT TO_CHAR(SYSDATE, 'DD-MON-YYYY HH24:MI:SS') AS start_time FROM DUAL;
PROMPT ================================================================================

ACCEPT p_source_tbs PROMPT 'Enter SOURCE TABLESPACE name: '
ACCEPT p_compression PROMPT 'Enter COMPRESSION TYPE (NOCOMPRESS/COMPRESS LOW/COMPRESS MEDIUM/COMPRESS HIGH): '
ACCEPT p_parallel PROMPT 'Enter PARALLEL DEGREE (e.g., 4, 8, 16): '
ACCEPT p_dry_run PROMPT 'DRY RUN MODE? (Y/N): '

VARIABLE v_source_tbs VARCHAR2(30)
VARIABLE v_temp_tbs VARCHAR2(30)
VARIABLE v_compression VARCHAR2(50)
VARIABLE v_parallel NUMBER
VARIABLE v_dry_run VARCHAR2(1)

BEGIN
    :v_source_tbs := UPPER('&p_source_tbs');
    :v_temp_tbs := UPPER('&p_source_tbs') || '_SHRINK';
    :v_compression := UPPER('&p_compression');
    :v_parallel := TO_NUMBER('&p_parallel');
    :v_dry_run := UPPER('&p_dry_run');
END;
/

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
    
    v_initial_used_gb   NUMBER := 0;
    v_initial_free_gb   NUMBER := 0;
    v_final_used_gb     NUMBER := 0;
    v_final_free_gb     NUMBER := 0;
    
    v_tbs_exists        NUMBER := 0;
    v_temp_tbs_exists   NUMBER := 0;

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
        SELECT 
            table_owner AS owner,
            table_name,
            partition_name,
            lob_columns,
            size_gb
        FROM (
            SELECT 
                lp.table_owner,
                lp.table_name,
                lp.partition_name,
                LISTAGG(lp.column_name, ',') WITHIN GROUP (ORDER BY lp.column_name) AS lob_columns,
                SUM(ROUND(s.bytes/1024/1024/1024, 2)) AS size_gb
            FROM dba_lob_partitions lp
            JOIN dba_segments s 
                ON lp.lob_partition_name = s.partition_name
               AND lp.lob_name = s.segment_name
            WHERE lp.tablespace_name = v_source_tbs
            GROUP BY lp.table_owner, lp.table_name, lp.partition_name
            ORDER BY 5 DESC
        );

    PROCEDURE log_message(p_message VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('[' || TO_CHAR(SYSTIMESTAMP, 'DD-MON-YYYY HH24:MI:SS') || '] ' || p_message);
    END;

    PROCEDURE capture_tbs_metrics(p_when VARCHAR2) IS
        v_used NUMBER := 0;
        v_free NUMBER := 0;
    BEGIN
        SELECT NVL(ROUND(SUM(bytes)/1024/1024/1024, 2), 0)
        INTO v_used
        FROM dba_segments
        WHERE tablespace_name = v_source_tbs;

        BEGIN
            SELECT NVL(ROUND(SUM(bytes)/1024/1024/1024, 2), 0)
            INTO v_free
            FROM dba_free_space
            WHERE tablespace_name = v_source_tbs;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_free := 0;
        END;

        IF p_when = 'BEFORE' THEN
            v_initial_used_gb := v_used;
            v_initial_free_gb := v_free;
        ELSE
            v_final_used_gb := v_used;
            v_final_free_gb := v_free;
        END IF;

        log_message(p_when || ' TBS Metrics - Used: ' || v_used || ' GB, Free: ' || v_free || ' GB');
    END;

    FUNCTION build_lob_clause(p_cols VARCHAR2, p_tablespace VARCHAR2, p_comp VARCHAR2)
        RETURN VARCHAR2
    IS
        v_pos NUMBER := 1;
        v_comma NUMBER;
        v_col VARCHAR2(128);
        v_clause VARCHAR2(4000) := '';
        v_cols VARCHAR2(4000) := p_cols || ',';
    BEGIN
        LOOP
            v_comma := INSTR(v_cols, ',', v_pos);
            EXIT WHEN v_comma = 0;
            v_col := TRIM(SUBSTR(v_cols, v_pos, v_comma - v_pos));
            IF v_col IS NOT NULL THEN
                v_clause := v_clause || ' LOB (' || v_col || ') STORE AS (TABLESPACE ' || p_tablespace || ' ' || p_comp || ')';
            END IF;
            v_pos := v_comma + 1;
        END LOOP;
        RETURN v_clause;
    END;

BEGIN
    log_message('================================================================================');
    log_message('INITIALIZATION PHASE');
    log_message('================================================================================');

    DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'INITIALIZATION');

    SELECT COUNT(*) INTO v_tbs_exists 
    FROM dba_tablespaces 
    WHERE tablespace_name = v_source_tbs;

    IF v_tbs_exists = 0 THEN
        log_message('ERROR: Source tablespace ' || v_source_tbs || ' does not exist!');
        RETURN;
    END IF;
    log_message('Source tablespace ' || v_source_tbs || ' verified.');

    SELECT COUNT(*) INTO v_temp_tbs_exists 
    FROM dba_tablespaces 
    WHERE tablespace_name = v_temp_tbs;

    IF v_temp_tbs_exists = 0 AND v_dry_run = 'N' THEN
        log_message('WARNING: Temp tablespace ' || v_temp_tbs || ' does not exist!');
        log_message('Please create it before EXECUTE mode:');
        log_message('  CREATE TABLESPACE ' || v_temp_tbs || ' DATAFILE SIZE 10G AUTOEXTEND ON;');
        RETURN;
    END IF;

    capture_tbs_metrics('BEFORE');

    log_message('================================================================================');
    log_message('DISCOVERY PHASE');
    log_message('================================================================================');

    DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'DISCOVERY');

    OPEN c_lob_partitions;
    FETCH c_lob_partitions BULK COLLECT INTO v_lob_list;
    CLOSE c_lob_partitions;

    v_total_partitions := v_lob_list.COUNT;

    IF v_total_partitions = 0 THEN
        log_message('No LOB partitions found in tablespace ' || v_source_tbs);
        log_message('');
        log_message('Quick check - run this query to see what segments exist:');
        log_message('  SELECT SEGMENT_TYPE, COUNT(*) FROM dba_segments');
        log_message('  WHERE tablespace_name = ''' || v_source_tbs || '''');
        log_message('  GROUP BY SEGMENT_TYPE;');
        RETURN;
    END IF;

    FOR i IN 1..v_lob_list.COUNT LOOP
        v_total_size_gb := v_total_size_gb + NVL(v_lob_list(i).size_gb,0);
    END LOOP;

    log_message('Total Partitions Found: ' || v_total_partitions);
    log_message('Total LOB Size: ' || ROUND(v_total_size_gb, 2) || ' GB');
    log_message('================================================================================');

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

    log_message('================================================================================');
    log_message('PHASE 1: MOVING TO TEMPORARY TABLESPACE (' || v_temp_tbs || ')');
    log_message('================================================================================');

    FOR i IN 1..v_lob_list.COUNT LOOP
        BEGIN
            v_sql := 'ALTER TABLE ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || 
                     ' MOVE PARTITION ' || v_lob_list(i).partition_name;

            v_sql := v_sql || build_lob_clause(v_lob_list(i).lob_columns, v_temp_tbs, v_compression)
                    || ' ONLINE PARALLEL ' || v_parallel;

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

    IF v_dry_run = 'N' AND v_success_count > 0 THEN
        log_message('================================================================================');
        log_message('PHASE 2: MOVING BACK TO SOURCE TABLESPACE (' || v_source_tbs || ')');
        log_message('================================================================================');

        v_success_count := 0;
        v_fail_count := 0;

        FOR i IN 1..v_lob_list.COUNT LOOP
            BEGIN
                v_sql := 'ALTER TABLE ' || v_lob_list(i).owner || '.' || v_lob_list(i).table_name || 
                         ' MOVE PARTITION ' || v_lob_list(i).partition_name;

                v_sql := v_sql || build_lob_clause(v_lob_list(i).lob_columns, v_source_tbs, v_compression)
                        || ' ONLINE PARALLEL ' || v_parallel;

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

    IF v_dry_run = 'N' THEN
        log_message('================================================================================');
        log_message('POST-EXECUTION VALIDATION');
        log_message('================================================================================');

        DBMS_APPLICATION_INFO.SET_MODULE('LOB_SHRINK_SCRIPT', 'VALIDATION');

        capture_tbs_metrics('AFTER');

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
        IF v_initial_used_gb > 0 THEN
            log_message('  Reduction %:     ' || ROUND(((v_initial_used_gb - v_final_used_gb) / v_initial_used_gb) * 100, 2) || '%');
        END IF;
        log_message('================================================================================');
    END IF;

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

PROMPT
PROMPT Log file created: lob_shrink_&log_timestamp..log
PROMPT
