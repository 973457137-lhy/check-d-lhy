-- Stage 14E-1: keep Flutter ARGB color values lossless in cloud storage.
-- The guards make this safe for projects where tasks.color was fixed manually.

begin;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'tasks'
      and column_name = 'color'
      and data_type = 'integer'
  ) then
    alter table public.tasks
      alter column color type bigint using color::bigint;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'plans'
      and column_name = 'color'
      and data_type = 'integer'
  ) then
    alter table public.plans
      alter column color type bigint using color::bigint;
  end if;
end;
$$;

commit;
