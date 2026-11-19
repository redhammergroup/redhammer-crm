-- Red Hammer CRM: salesman logins only see their own pipeline.
-- Paste into Supabase > SQL Editor > New snippet, then Run. Safe to run again.
-- Needs employees-setup.sql and employee-guard.sql to have been run first (they have).
--
-- A job belongs to a salesman when its data.ownerEmail is their login email.
-- Employees with the "own" checkbox (the Salesman quick set) can only read, add, change
-- and upload files on jobs they own. Everyone else works exactly as before.

create or replace function public.my_email()
returns text language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

create or replace function public.emp_sees_job(job_trade text, job_data jsonb)
returns boolean language sql stable security definer set search_path = public as $$
  select public.emp_can('b_' || job_trade)
     and (not public.emp_can('own') or lower(coalesce(job_data ->> 'ownerEmail', '')) = public.my_email());
$$;
grant execute on function public.my_email() to authenticated;
grant execute on function public.emp_sees_job(text, jsonb) to authenticated;

-- Jobs
drop policy if exists "employee reads boards" on public.jobs;
create policy "employee reads boards" on public.jobs
  for select to authenticated using (public.emp_sees_job(trade, data));
drop policy if exists "employee adds leads" on public.jobs;
create policy "employee adds leads" on public.jobs
  for insert to authenticated with check (public.emp_sees_job(trade, data) and public.emp_can('addLeads'));
drop policy if exists "employee updates jobs" on public.jobs;
create policy "employee updates jobs" on public.jobs
  for update to authenticated
  using (public.emp_sees_job(trade, data) and (public.emp_can('edit') or public.emp_can('expenses') or public.emp_can('payments') or public.emp_can('files')))
  with check (public.emp_sees_job(trade, data));
drop policy if exists "employee deletes jobs" on public.jobs;
create policy "employee deletes jobs" on public.jobs
  for delete to authenticated using (public.emp_sees_job(trade, data) and public.emp_can('delete'));

-- Files
drop policy if exists "employee reads files" on storage.objects;
create policy "employee reads files" on storage.objects
  for select to authenticated using (bucket_id = 'files' and exists (
    select 1 from public.jobs j where j.id = split_part(storage.objects.name, '/', 1) and public.emp_sees_job(j.trade, j.data)));
drop policy if exists "employee uploads files" on storage.objects;
create policy "employee uploads files" on storage.objects
  for insert to authenticated with check (bucket_id = 'files' and exists (
    select 1 from public.jobs j where j.id = split_part(storage.objects.name, '/', 1) and public.emp_sees_job(j.trade, j.data)
      and (public.emp_can('expenses') or public.emp_can('payments') or public.emp_can('files'))));
drop policy if exists "employee deletes files" on storage.objects;
create policy "employee deletes files" on storage.objects
  for delete to authenticated using (bucket_id = 'files' and public.emp_can('delete') and exists (
    select 1 from public.jobs j where j.id = split_part(storage.objects.name, '/', 1) and public.emp_sees_job(j.trade, j.data)));

-- Job guard: same as employee-guard.sql, plus only the owner can assign or reassign a lead's salesman.
create or replace function public.guard_employee_job_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  o jsonb := old.data;
  d jsonb := new.data;
  own_keys text[] := array['contract','payments','expenses','docs','partnerPayouts','splitPct','splitBasis',
                           'notes','reminders','workDesc','updatedAt','alarmFor','stage','lost','trade'];
begin
  if public.is_owner() or public.my_emp_perms() is null then
    return new;
  end if;

  if new.id is distinct from old.id or new.partner_id is distinct from old.partner_id then
    raise exception 'Only the owner can change that';
  end if;
  if (d->'ownerEmail') is distinct from (o->'ownerEmail') then
    raise exception 'Only the owner can change which salesman a lead belongs to';
  end if;
  if (d->'partnerPayouts') is distinct from (o->'partnerPayouts')
     or (d->'splitPct') is distinct from (o->'splitPct')
     or (d->'splitBasis') is distinct from (o->'splitBasis') then
    raise exception 'Only the owner can change partner splits or payouts';
  end if;

  if (new.stage is distinct from old.stage or new.lost is distinct from old.lost or new.trade is distinct from old.trade
      or (d->'stage') is distinct from (o->'stage') or (d->'lost') is distinct from (o->'lost') or (d->'trade') is distinct from (o->'trade'))
     and not public.emp_can('edit') then
    raise exception 'You need Edit jobs access to change the stage, board or lost status';
  end if;
  if new.trade is distinct from old.trade and not public.emp_can('b_' || new.trade) then
    raise exception 'You don''t have access to that board';
  end if;

  if (d->'contract') is distinct from (o->'contract') and not public.emp_can('money') then
    raise exception 'You need See money access to change the contract price';
  end if;
  if (d->'payments') is distinct from (o->'payments') and not public.emp_can('payments') then
    raise exception 'You need Payments access to change payments';
  end if;
  if (d->'expenses') is distinct from (o->'expenses') and not public.emp_can('expenses') then
    raise exception 'You need Expenses access to change expenses';
  end if;
  if (d->'docs') is distinct from (o->'docs') and not (public.emp_can('files') or public.emp_can('payments') or public.emp_can('money')) then
    raise exception 'You need Documents access to change files';
  end if;
  if (d->'notes') is distinct from (o->'notes')
     and not (public.emp_can('edit') or coalesce(d->'notes','[]'::jsonb) @> coalesce(o->'notes','[]'::jsonb)) then
    raise exception 'You need Edit jobs access to change notes';
  end if;
  if (d->'workDesc') is distinct from (o->'workDesc') and not (public.emp_can('edit') or public.emp_can('payments')) then
    raise exception 'You need Edit jobs access to change the work description';
  end if;

  if (d - own_keys) is distinct from (o - own_keys) and not public.emp_can('edit') then
    raise exception 'You need Edit jobs access to change job details';
  end if;

  return new;
end;
$$;

drop trigger if exists guard_employee_job_update on public.jobs;
create trigger guard_employee_job_update
  before update on public.jobs
  for each row execute function public.guard_employee_job_update();
