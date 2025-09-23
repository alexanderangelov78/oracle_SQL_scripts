-- Check tablespace usage
SELECT 
    tablespace_name,
    ROUND(total_size_mb, 2) as total_mb,
    ROUND(used_mb, 2) as used_mb,
    ROUND(free_mb, 2) as free_mb,
    ROUND((used_mb/total_size_mb)*100, 2) as pct_used
FROM (
    SELECT 
        ts.tablespace_name,
        NVL(df.total_size, 0) / 1024 / 1024 as total_size_mb,
        NVL(df.total_size - fs.free_space, 0) / 1024 / 1024 as used_mb,
        NVL(fs.free_space, 0) / 1024 / 1024 as free_mb
    FROM dba_tablespaces ts
    LEFT JOIN (SELECT tablespace_name, SUM(bytes) as total_size 
               FROM dba_data_files GROUP BY tablespace_name) df 
        ON ts.tablespace_name = df.tablespace_name
    LEFT JOIN (SELECT tablespace_name, SUM(bytes) as free_space 
               FROM dba_free_space GROUP BY tablespace_name) fs 
        ON ts.tablespace_name = fs.tablespace_name
    WHERE ts.tablespace_name = 'SHRINK_TEST'
);

-- Check high water mark
SELECT 
    file_name,
    tablespace_name,
    file_id,
    ROUND(bytes/1024/1024, 2) as current_size_mb,
    ROUND(((blocks-1)*8192)/1024/1024, 2) as hwm_mb,
    ROUND(bytes/1024/1024 - ((blocks-1)*8192)/1024/1024, 2) as shrinkable_mb
FROM dba_data_files
WHERE tablespace_name = 'SHRINK_TEST';

-- When shrink fails, find what's blocking it
SELECT 
    owner,
    segment_name,
    segment_type,
    file_id,
    block_id,
    blocks,
    ROUND(bytes/1024/1024, 2) as size_mb,
    ROUND((block_id + blocks - 1) * 8192 / 1024 / 1024, 2) as end_position_mb
FROM dba_extents
WHERE tablespace_name = 'SHRINK_TEST'
AND file_id = (SELECT file_id FROM dba_data_files WHERE tablespace_name = 'SHRINK_TEST')
ORDER BY block_id DESC
FETCH FIRST 10 ROWS ONLY;

-- Real-time Space Usage
SELECT 
    tablespace_name,
    ROUND(SUM(bytes)/1024/1024, 2) as total_mb,
    COUNT(*) as num_datafiles
FROM dba_data_files
WHERE tablespace_name = 'SHRINK_TEST'
GROUP BY tablespace_name;



---fragmentation analysis
SELECT 
    tablespace_name,
    COUNT(*) as free_chunks,
    ROUND(MAX(bytes/1024/1024), 2) as largest_free_mb,
    ROUND(MIN(bytes/1024/1024), 2) as smallest_free_mb,
    ROUND(AVG(bytes/1024/1024), 2) as avg_free_mb
FROM dba_free_space
WHERE tablespace_name = 'SHRINK_TEST'
GROUP BY tablespace_name;


--segmentation distribution
SELECT 
    owner,
    segment_type,
    COUNT(*) as num_segments,
    ROUND(SUM(bytes/1024/1024), 2) as total_mb
FROM dba_segments
WHERE tablespace_name = 'SHRINK_TEST'
GROUP BY owner, segment_type
ORDER BY total_mb DESC;
