-- Red Hammer CRM: employee logins with checkbox permissions.
-- Paste into Supabase > SQL Editor > New snippet, then Run.

create table if not exists public.employees (
  email text primary key,
  name text,
  perms jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  notify_topic text,
  updated_at timestamptz not null default now()
);
alter table public.employees enable row level security;

-- The signed-in employee's permissions (null if they aren't an active employee).
create or replace function public.my_emp_perms()
returns jsonb language sql stable security definer set search_path = public as $$
  select perms from public.employees
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and active
  limit 1;
$$;
create or replace function public.emp_can(k text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((public.my_emp_perms() ->> k)::boolean, false);
$$;
grant execute on function public.my_emp_perms() to authenticated;
grant execute on function public.emp_can(text) to authenticated;

drop policy if exists "owner full access" on public.employees;
create policy "owner full access" on public.employees
  for all to authenticated using (public.is_owner()) with check (public.is_owner());
drop policy if exists "employee reads own row" on public.employees;
create policy "employee reads own row" on public.employees
  for select to authenticated using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
grant select, insert, update, delete on public.employees to authenticated;

-- Jobs: only on the boards they're allowed, and only the actions they're allowed.
drop policy if exists "employee reads boards" on public.jobs;
create policy "employee reads boards" on public.jobs
  for select to authenticated using (public.emp_can('b_' || trade));
drop policy if exists "employee adds leads" on public.jobs;
create policy "employee adds leads" on public.jobs
  for insert to authenticated with check (public.emp_can('b_' || trade) and public.emp_can('addLeads'));
drop policy if exists "employee updates jobs" on public.jobs;
create policy "employee updates jobs" on public.jobs
  for update to authenticated
  using (public.emp_can('b_' || trade) and (public.emp_can('edit') or public.emp_can('expenses') or public.emp_can('payments') or public.emp_can('files')))
  with check (public.emp_can('b_' || trade));
drop policy if exists "employee deletes jobs" on public.jobs;
create policy "employee deletes jobs" on public.jobs
  for delete to authenticated using (public.emp_can('b_' || trade) and public.emp_can('delete'));

-- Settings: employees can read (sub list for dropdowns), never change.
drop policy if exists "employee reads settings" on public.settings;
create policy "employee reads settings" on public.settings
  for select to authenticated using (public.my_emp_perms() is not null);

-- Files: view on their boards; upload if they can add expenses, payments or files; delete only with delete access.
drop policy if exists "employee reads files" on storage.objects;
create policy "employee reads files" on storage.objects
  for select to authenticated using (bucket_id = 'files' and exists (
    select 1 from public.jobs j where j.id = split_part(storage.objects.name, '/', 1) and public.emp_can('b_' || j.trade)));
drop policy if exists "employee uploads files" on storage.objects;
create policy "employee uploads files" on storage.objects
  for insert to authenticated with check (bucket_id = 'files' and exists (
    select 1 from public.jobs j where j.id = split_part(storage.objects.name, '/', 1) and public.emp_can('b_' || j.trade)
      and (public.emp_can('expenses') or public.emp_can('payments') or public.emp_can('files'))));
drop policy if exists "employee deletes files" on storage.objects;
create policy "employee deletes files" on storage.objects
  for delete to authenticated using (bucket_id = 'files' and public.emp_can('delete') and exists (
    select 1 from public.jobs j where j.id = split_part(storage.objects.name, '/', 1) and public.emp_can('b_' || j.trade)));
