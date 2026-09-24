-- Generate an internal operator code when one is omitted.
-- Run once in the Supabase SQL Editor.

alter table public.operators
  alter column code set default (
    'OP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
  );

-- Keep the code out of normal operator maintenance. The column remains for
-- compatibility, but inserts always receive a generated value and updates
-- cannot change an existing code.
create or replace function public.manage_operator_code()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    new.code := 'OP-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  elsif new.code is distinct from old.code then
    raise exception 'Operator code is system-generated and cannot be edited';
  end if;
  return new;
end;
$$;

drop trigger if exists manage_operator_code on public.operators;
create trigger manage_operator_code
  before insert or update of code on public.operators
  for each row execute function public.manage_operator_code();
