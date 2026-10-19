-- Red Hammer CRM: send appointment alarms and reminders from the database every 5 minutes,
-- so they arrive even when nobody has the app open. Paste into Supabase > SQL Editor, then Run. Safe to run again.
-- The app still schedules alerts ahead of time when it's open; both mark "alarmFor", so nothing is sent twice.

create extension if not exists pg_net;
create extension if not exists pg_cron;

create or replace function public.send_due_alarms()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
  owner_topic text := (select data->>'notifyTopic' from public.settings where id = 1);
  link text := 'https://redhammergroup.github.io/redhammer-crm/';
  j record;
  d jsonb;
  r jsonb;
  rems jsonb;
  topic text;
  appt bigint;
  changed boolean;
  sent int := 0;
begin
  for j in select id, data from public.jobs where not lost for update skip locked loop
    d := j.data;
    changed := false;

    -- appointment: alarm during the hour before it starts
    if owner_topic is not null and (d->>'appointmentAt') ~ '^\d+$' then
      appt := (d->>'appointmentAt')::bigint;
      if now_ms >= appt - 3600000 and now_ms < appt and (d->>'alarmFor') is distinct from (d->>'appointmentAt') then
        perform net.http_post(
          url := 'https://ntfy.sh',
          body := jsonb_build_object(
            'topic', owner_topic,
            'title', 'Appointment soon: ' || coalesce(nullif(d->>'name', ''), 'customer'),
            'message', concat_ws(E'\n',
              to_char(to_timestamp(appt / 1000.0) at time zone 'America/Chicago', 'Dy Mon FMDD, FMHH12:MI AM'),
              nullif(d->>'address', ''), nullif(d->>'phone', '')),
            'priority', 5, 'tags', jsonb_build_array('alarm_clock'), 'click', link));
        d := jsonb_set(d, '{alarmFor}', d->'appointmentAt');
        changed := true; sent := sent + 1;
      end if;
    end if;

    -- reminders that came due in the last 2 hours and haven't been sent
    if jsonb_typeof(d->'reminders') = 'array' then
      rems := '[]'::jsonb;
      for r in select value from jsonb_array_elements(d->'reminders') loop
        if coalesce((r->>'done')::boolean, false) = false
           and (r->>'at') ~ '^\d+$'
           and (r->>'at')::bigint <= now_ms and (r->>'at')::bigint > now_ms - 7200000
           and (r->>'alarmFor') is distinct from (r->>'at') then
          topic := case when coalesce(r->>'by', '') = '' or lower(r->>'by') = 'redhammer.exteriors@gmail.com' then owner_topic
                        else (select e.notify_topic from public.employees e where lower(e.email) = lower(r->>'by') and e.active limit 1) end;
          if topic is not null then
            perform net.http_post(
              url := 'https://ntfy.sh',
              body := jsonb_build_object(
                'topic', topic,
                'title', 'Reminder: ' || coalesce(nullif(d->>'name', ''), 'customer'),
                'message', concat_ws(E'\n', coalesce(nullif(r->>'text', ''), 'Reach back out'), nullif(d->>'phone', ''), nullif(d->>'address', '')),
                'priority', 5, 'tags', jsonb_build_array('alarm_clock'), 'click', link));
            r := jsonb_set(r, '{alarmFor}', r->'at');
            changed := true; sent := sent + 1;
          end if;
        end if;
        rems := rems || jsonb_build_array(r);
      end loop;
      if changed then d := jsonb_set(d, '{reminders}', rems); end if;
    end if;

    if changed then
      update public.jobs set data = d, updated_at = now() where id = j.id;
    end if;
  end loop;
  return sent;
end;
$$;

-- only the scheduler runs this, not app logins
revoke all on function public.send_due_alarms() from public, anon, authenticated;

select cron.schedule('rh-alarms', '*/5 * * * *', $cron$select public.send_due_alarms()$cron$);
