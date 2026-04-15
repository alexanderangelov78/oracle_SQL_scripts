
SELECT
    owner,
    object_type,
    COUNT(*) AS invalid_count
FROM
    dba_objects
WHERE
    status = 'INVALID'
GROUP BY
    owner,
    object_type
ORDER BY
    owner,
    object_type;
