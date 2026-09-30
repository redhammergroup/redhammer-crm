-- Red Hammer CRM: let Tony book appointments (new Appointment column). Paste into Supabase > SQL Editor > New snippet, then Run.
drop policy if exists "partner submits leads" on public.jobs;
create policy "partner submits leads" on public.jobs
  for insert to authenticated
  with check (partner_id is not null and partner_id = public.my_partner_id() and trade = 'roofing' and stage in ('Appointment','Lead'));
