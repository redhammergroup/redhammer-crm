-- Red Hammer CRM: partner logins (Tony). Paste into Supabase > SQL Editor > New snippet, then Run.

-- Which login belongs to which partner, and their split (only the owner can change this).
create table if not exists public.partner_accounts (
  email text primary key,
  partner_id text not null,
  name text,
  pct numeric not null default 15,
  basis text not null default 'profit',
  notify_topic text,
  updated_at timestamptz not null default now()
);
alter table public.partner_accounts enable row level security;

-- The partner id for whoever is signed in (null for anyone who isn't a partner).
create or replace function public.my_partner_id()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select partner_id from public.partner_accounts
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  limit 1;
$$;
grant execute on function public.my_partner_id() to authenticated;

drop policy if exists "owner full access" on public.partner_accounts;
create policy "owner full access" on public.partner_accounts
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

drop policy if exists "partner reads own account" on public.partner_accounts;
create policy "partner reads own account" on public.partner_accounts
  for select to authenticated using (lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

grant select, insert, update, delete on public.partner_accounts to authenticated;

-- A partner can see only the jobs tagged with their name...
drop policy if exists "partner reads own leads" on public.jobs;
create policy "partner reads own leads" on public.jobs
  for select to authenticated
  using (partner_id is not null and partner_id = public.my_partner_id());

-- ...and can only add brand-new roofing leads under their own name (no editing or deleting).
drop policy if exists "partner submits leads" on public.jobs;
create policy "partner submits leads" on public.jobs
  for insert to authenticated
  with check (partner_id is not null and partner_id = public.my_partner_id() and trade = 'roofing' and stage = 'Lead');

-- A partner can view receipt photos on their own jobs only.
drop policy if exists "partner reads own job files" on storage.objects;
create policy "partner reads own job files" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'files'
    and exists (
      select 1 from public.jobs j
      where j.id = split_part(storage.objects.name, '/', 1)
        and j.partner_id is not null
        and j.partner_id = public.my_partner_id()
    )
  );
