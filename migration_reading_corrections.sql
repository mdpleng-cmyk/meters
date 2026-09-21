-- Reading corrections and controlled backfills.
-- Run after the existing meter-reading migrations.

create table if not exists public.meter_reading_audit (
  id uuid primary key default gen_random_uuid(),
  reading_id uuid not null references public.meter_readings(id) on delete cascade,
  action text not null check (action in ('UPDATE')),
  old_reading_value numeric,
  new_reading_value numeric,
  old_reading_date date,
  new_reading_date date,
  changed_by uuid references public.operators(id),
  changed_at timestamptz not null default now(),
  reason text
);

-- Supabase Table Editor changes have no auth.uid(); keep those audit rows
-- with a null actor instead of failing the underlying reading update.
alter table public.meter_reading_audit
  alter column changed_by drop not null;

alter table public.meter_reading_audit enable row level security;

drop policy if exists meter_reading_audit_control_room_read on public.meter_reading_audit;
create policy meter_reading_audit_control_room_read
  on public.meter_reading_audit for select
  using (is_control_room_or_admin());

create or replace function public.enforce_meter_reading_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  can_control boolean := is_control_room_or_admin();
begin
  if not can_control then
    if old.recorded_by <> auth.uid()
       or old.recorded_at < now() - interval '8 hours'
       or new.meter_id <> old.meter_id
       or new.shift <> old.shift
       or new.recorded_by <> old.recorded_by
       or new.recorded_at <> old.recorded_at then
      raise exception 'Only your own reading can be edited within 8 hours';
    end if;
  end if;

  if new.notes is null or new.notes = old.notes then
    new.notes := old.notes;
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_meter_reading_update on public.meter_readings;
create trigger enforce_meter_reading_update
  before update on public.meter_readings
  for each row execute function public.enforce_meter_reading_update();

create or replace function public.audit_meter_reading_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.meter_reading_audit (
    reading_id, action, old_reading_value, new_reading_value,
    old_reading_date, new_reading_date, changed_by, reason
  ) values (
    old.id, 'UPDATE', old.reading_value, new.reading_value,
    old.reading_date, new.reading_date, auth.uid(), new.notes
  );
  return new;
end;
$$;

drop trigger if exists audit_meter_reading_update on public.meter_readings;
create trigger audit_meter_reading_update
  after update on public.meter_readings
  for each row execute function public.audit_meter_reading_update();

-- Permit Control Room/Admin to create a row attributed to their own account
-- when backfilling a missed reading. The date restriction is enforced below.
drop policy if exists meter_readings_control_room_insert on public.meter_readings;
create policy meter_readings_control_room_insert
  on public.meter_readings for insert
  with check (
    is_control_room_or_admin()
    and recorded_by = auth.uid()
    and reading_date <= current_date
  );

-- Existing policies may continue to permit each user's own INSERT. This policy
-- adds the controlled update window without widening access to other rows.
drop policy if exists meter_readings_owner_update_window on public.meter_readings;
create policy meter_readings_owner_update_window
  on public.meter_readings for update
  using (
    is_control_room_or_admin()
    or (
      recorded_by = auth.uid()
      and recorded_at >= now() - interval '8 hours'
    )
  )
  with check (
    is_control_room_or_admin()
    or (
      recorded_by = auth.uid()
      and recorded_at >= now() - interval '8 hours'
    )
  );

-- Keep previous_reading and generated consumption correct after a historical
-- insert or a value correction. The depth guard prevents recursive updates.
create or replace function public.rebuild_meter_reading_chain()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if pg_trigger_depth() > 1 then return new; end if;
  update public.meter_readings r
  set previous_reading = (
    select p.reading_value
    from public.meter_readings p
    where p.meter_id = r.meter_id
      and p.id <> r.id
      and (p.reading_date, p.recorded_at) < (r.reading_date, r.recorded_at)
    order by p.reading_date desc, p.recorded_at desc
    limit 1
  )
  where r.meter_id = new.meter_id
    and r.previous_reading is distinct from (
      select p.reading_value
      from public.meter_readings p
      where p.meter_id = r.meter_id
        and p.id <> r.id
        and (p.reading_date, p.recorded_at) < (r.reading_date, r.recorded_at)
      order by p.reading_date desc, p.recorded_at desc
      limit 1
    );
  return new;
end;
$$;

drop trigger if exists rebuild_meter_reading_chain on public.meter_readings;
create trigger rebuild_meter_reading_chain
  after insert or update of meter_id, reading_value, reading_date, recorded_at
  on public.meter_readings
  for each row execute function public.rebuild_meter_reading_chain();

-- Keep the app documentation aligned with the deployed policy.
