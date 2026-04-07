set lines 200
col username format a30
col profile  format a20
col resource_name format a25
col raw_limit format a12
col effective_limit format a12

select u.username,
       u.profile,
       p.resource_name,
       p.limit as raw_limit,
       case
         when p.limit = 'DEFAULT' then
           ( select d.limit
             from dba_profiles d
             where d.profile = 'DEFAULT'
               and d.resource_name = p.resource_name )
         else p.limit
       end as effective_limit
from dba_users u
join dba_profiles p
  on p.profile = u.profile
where u.username = upper('&username')
  and p.resource_name in ('PASSWORD_ROLLOVER_TIME','PASSWORD_GRACE_TIME');
