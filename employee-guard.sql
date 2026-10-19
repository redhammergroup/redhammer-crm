-- Red Hammer CRM: enforce employee checkboxes inside the database, not just in the app.
-- Paste into Supabase > SQL Editor > New snippet, then Run. Safe to run again.
-- The owner and partners are not affected (partners can't update jobs at all).

create or replace function public.guard_employee_job_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  o jsonb := old.data;
  d jsonb := new.data;
  -- fields with their own checkbox, or that anyone on the board may touch
  own_keys text[] := array['contract','payments','expenses','docs','partnerPayouts','splitPct','splitBasis',
                           'notes','reminders','workDesc','updatedAt','alarmFor','stage','lost','trade'];
begin
  if public.is_owner() or public.my_emp_perms() is null then
    return new;
  end if;

  if new.id is distinct from old.id or new.partner_id is distinct from old.partner_id then
    raise exception 'Only the owner can change that';
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
  -- adding notes is fine (reminders and payments add one); editing or removing them needs Edit jobs
  if (d->'notes') is distinct from (o->'notes')
     and not (public.emp_can('edit') or coalesce(d->'notes','[]'::jsonb) @> coalesce(o->'notes','[]'::jsonb)) then
    raise exception 'You need Edit jobs access to change notes';
  end if;
  if (d->'workDesc') is distinct from (o->'workDesc') and not (public.emp_can('edit') or public.emp_can('payments')) then
    raise exception 'You need Edit jobs access to change the work description';
  end if;

  -- everything else (name, phone, address, insurance, adjuster, face note...) needs Edit jobs
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
