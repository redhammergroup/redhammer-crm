-- Red Hammer CRM: storage meter. Paste into Supabase > SQL Editor > New snippet, then Run.
create or replace function public.storage_usage()
returns jsonb
language sql
stable
security definer
set search_path = public, storage
as $$
  select case when public.is_owner() then jsonb_build_object(
    'files_bytes', coalesce((select sum((metadata->>'size')::bigint) from storage.objects where bucket_id = 'files'), 0),
    'files_count', (select count(*) from storage.objects where bucket_id = 'files'),
    'db_bytes', pg_database_size(current_database())
  ) else null end;
$$;
revoke all on function public.storage_usage() from public;
grant execute on function public.storage_usage() to authenticated;
