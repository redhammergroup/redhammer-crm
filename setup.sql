-- Red Hammer CRM database setup. Paste all of this into Supabase > SQL Editor > New query, then click Run.

-- Only the owner account can read or change anything.
create or replace function public.is_owner()
returns boolean
language sql
stable
as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'redhammer.exteriors@gmail.com';
$$;

-- Jobs: one row per customer job. "data" holds the full job (notes, expenses, payments, files).
create table if not exists public.jobs (
  id text primary key,
  trade text not null,
  stage text not null,
  lost boolean not null default false,
  partner_id text,
  data jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Settings: a single row (partners, receipt number).
create table if not exists public.settings (
  id int primary key default 1,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  constraint settings_one_row check (id = 1)
);
insert into public.settings (id, data) values (1, '{"partners":[],"receiptNo":0}') on conflict (id) do nothing;

alter table public.jobs enable row level security;
alter table public.settings enable row level security;

drop policy if exists "owner full access" on public.jobs;
create policy "owner full access" on public.jobs
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

drop policy if exists "owner full access" on public.settings;
create policy "owner full access" on public.settings
  for all to authenticated using (public.is_owner()) with check (public.is_owner());

-- Private file storage for receipt photos, payment receipts and documents.
insert into storage.buckets (id, name, public) values ('files', 'files', false)
  on conflict (id) do nothing;

drop policy if exists "owner files" on storage.objects;
create policy "owner files" on storage.objects
  for all to authenticated
  using (bucket_id = 'files' and public.is_owner())
  with check (bucket_id = 'files' and public.is_owner());

-- Live sync between phone and computer.
do $$
begin
  begin alter publication supabase_realtime add table public.jobs; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.settings; exception when duplicate_object then null; end;
end $$;
