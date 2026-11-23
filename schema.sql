-- Infinit Fitness Daganzo: shared reservations and trainer records.
-- Run this file in Supabase SQL Editor before publishing the site.

create extension if not exists pgcrypto;

-- Member names match regardless of capitalization or Spanish accent marks.
create or replace function public.gym_member_name_key(p_name text)
returns text language sql immutable parallel safe set search_path = pg_catalog as $$
  select translate(regexp_replace(lower(trim(coalesce(p_name,''))), '\s+', ' ', 'g'), 'áéíóúüñ', 'aeiouun')
$$;

create table if not exists public.gym_bookings (
  id uuid primary key default gen_random_uuid(),
  class_date date not null,
  class_slot smallint not null check (class_slot between 0 and 2),
  member_name text not null,
  created_at timestamptz not null default now()
);
create unique index if not exists gym_bookings_one_per_member
  on public.gym_bookings (class_date, class_slot, lower(regexp_replace(trim(member_name), '\s+', ' ', 'g')));

create table if not exists public.gym_events (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid,
  class_date date not null,
  class_slot smallint not null check (class_slot between 0 and 2),
  member_name text not null,
  event_type text not null check (event_type in ('reservation','cancellation','absence','absence_reversed')),
  late boolean not null default false,
  created_by text,
  created_at timestamptz not null default now()
);
alter table public.gym_events add column if not exists created_by text;
create index if not exists gym_events_member_created on public.gym_events (lower(member_name), created_at desc);

-- The member list is the allowlist for making new reservations.
create table if not exists public.gym_members (
  member_name text not null,
  member_key text generated always as (lower(regexp_replace(trim(member_name), '\s+', ' ', 'g'))) stored unique,
  created_at timestamptz not null default now()
);
alter table public.gym_members add column if not exists is_active boolean not null default true;
-- Preserve access for people who already have reservations or history.
insert into public.gym_members(member_name)
select member_name from public.gym_bookings
union
select member_name from public.gym_events
on conflict (member_key) do nothing;

-- Merge member registrations that differ only by accents, capitalization, or extra spaces.
-- Keep the spelling with accents when available, and preserve the member as active if any duplicate was active.
do $dedupe_members$
declare v_member record;
begin
  for v_member in
    select public.gym_member_name_key(m.member_name) as normalized_key,
      (array_agg(regexp_replace(trim(m.member_name), '\s+', ' ', 'g')
        order by (length(lower(m.member_name))-length(translate(lower(m.member_name),'áéíóúüñ',''))) desc,
                 m.member_name))[1] as canonical_name,
      bool_or(m.is_active) as is_active
    from public.gym_members m
    group by public.gym_member_name_key(m.member_name)
  loop
    delete from public.gym_members m
      where public.gym_member_name_key(m.member_name)=v_member.normalized_key
        and m.member_name<>v_member.canonical_name;
    update public.gym_members m
      set member_name=v_member.canonical_name,is_active=v_member.is_active
      where public.gym_member_name_key(m.member_name)=v_member.normalized_key;
  end loop;
end;
$dedupe_members$;

-- Per-date exceptions to the regular weekday schedule; slots 0-2 are the three standard session times.
create table if not exists public.gym_class_schedule_overrides (
  class_date date not null,
  class_slot smallint not null check (class_slot between 0 and 2),
  is_open boolean not null,
  updated_by text not null,
  updated_at timestamptz not null default now(),
  primary key (class_date,class_slot)
);
-- Tracks completed warning penalties separately so old warnings stay in history but do not count again.
create table if not exists public.gym_member_warning_resets (
  member_key text primary key,
  member_name text not null,
  reset_at timestamptz not null default now()
);
-- This table is deliberately private to the RPC functions. Add trainer usernames
-- from the Supabase SQL Editor; do not put them in the public website files.
create table if not exists public.gym_trainer_keys (
  trainer_name text not null,
  username_key text generated always as (lower(regexp_replace(trim(trainer_name), '\s+', ' ', 'g'))) stored unique
);
alter table public.gym_trainer_keys
  add column if not exists can_manage_bookings boolean not null default false;
update public.gym_trainer_keys
  set can_manage_bookings = username_key in ('fernando vaquero trainer', 'antonio sánchez trainer');

alter table public.gym_bookings enable row level security;
alter table public.gym_events enable row level security;
alter table public.gym_trainer_keys enable row level security;
alter table public.gym_members enable row level security;
alter table public.gym_member_warning_resets enable row level security;
alter table public.gym_class_schedule_overrides enable row level security;
revoke all on public.gym_bookings, public.gym_events, public.gym_trainer_keys, public.gym_members, public.gym_member_warning_resets, public.gym_class_schedule_overrides from anon, authenticated;
grant usage on schema public to anon, authenticated;

create or replace function public.gym_class_start(p_date date, p_slot smallint)
returns timestamptz language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_slot not between 0 and 2 then raise exception 'Clase no válida'; end if;
  return ((p_date + case p_slot when 0 then time '09:00' when 1 then time '18:00' else time '20:30' end) at time zone 'Europe/Madrid');
end;
$$;

create or replace function public.gym_class_is_open(p_date date, p_slot smallint)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select o.is_open from public.gym_class_schedule_overrides o where o.class_date=p_date and o.class_slot=p_slot),
    extract(isodow from p_date) between 1 and 5
  )
$$;
drop function if exists public.get_class_counts(date,date);
create function public.get_class_counts(p_start_date date, p_end_date date)
returns table(class_date date, class_slot smallint, remaining_places bigint, is_open boolean)
language sql stable security definer set search_path = public, pg_temp as $$
  select dates.class_date::date, slots.class_slot::smallint,
    greatest(0::bigint,6::bigint-count(b.id)),
    coalesce(o.is_open,extract(isodow from dates.class_date) between 1 and 5)
  from generate_series(p_start_date::timestamp,p_end_date::timestamp,interval '1 day') as dates(class_date)
  cross join generate_series(0,2) as slots(class_slot)
  left join public.gym_bookings b on b.class_date=dates.class_date::date and b.class_slot=slots.class_slot
  left join public.gym_class_schedule_overrides o on o.class_date=dates.class_date::date and o.class_slot=slots.class_slot
  group by dates.class_date,slots.class_slot,o.is_open
$$;

-- Once a warning penalty has ended, consume that warning set. The events remain in history.
create or replace function public.reset_expired_warning_penalty(p_member_name text)
returns date language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text; v_key text; v_reset_at timestamptz; v_warning_count bigint; v_last_warning timestamptz; v_first_allowed_date date; v_pre_reset_count bigint; v_pre_reset_last_warning timestamptz;
begin
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  v_key := public.gym_member_name_key(v_name);
  perform pg_advisory_xact_lock(hashtextextended('warning-reset:' || v_key,0));
  select coalesce(max(r.reset_at),'-infinity'::timestamptz) into v_reset_at
    from public.gym_member_warning_resets r
    where public.gym_member_name_key(r.member_name)=v_key;
  -- If the previous +5-day rule already reset this warning set on day five, restore it through that fifth day.
  if v_reset_at > '-infinity'::timestamptz then
    with warning_states_before_reset as (
      select e.booking_id,e.event_type,e.created_at,
        row_number() over(partition by e.booking_id order by e.created_at desc,e.id desc) as rn
      from public.gym_events e
      where e.booking_id is not null
        and public.gym_member_name_key(e.member_name)=v_key
        and e.created_at<v_reset_at
        and e.created_at>=v_reset_at-interval '14 days'
        and e.event_type in ('absence','absence_reversed')
    )
    select count(*),max(created_at) into v_pre_reset_count,v_pre_reset_last_warning
      from warning_states_before_reset where rn=1 and event_type='absence';
    if v_pre_reset_count>=2
      and (now() at time zone 'Europe/Madrid')::date < (v_pre_reset_last_warning at time zone 'Europe/Madrid')::date+6 then
      delete from public.gym_member_warning_resets r where public.gym_member_name_key(r.member_name)=v_key;
      v_reset_at := '-infinity'::timestamptz;
    end if;
  end if;
  with warning_states as (
    select e.booking_id,e.event_type,e.created_at,
      row_number() over(partition by e.booking_id order by e.created_at desc,e.id desc) as rn
    from public.gym_events e
    where e.booking_id is not null
      and public.gym_member_name_key(e.member_name)=v_key
      and e.created_at>v_reset_at
      and e.event_type in ('absence','absence_reversed')
  )
  select count(*),max(created_at) into v_warning_count,v_last_warning
  from warning_states
  where rn=1 and event_type='absence' and created_at>=now()-interval '14 days';
  if v_warning_count>=2 then
    v_first_allowed_date := (v_last_warning at time zone 'Europe/Madrid')::date+6;
    if (now() at time zone 'Europe/Madrid')::date>=v_first_allowed_date then
      insert into public.gym_member_warning_resets(member_key,member_name,reset_at)
        values(v_key,v_name,now())
      on conflict(member_key) do update set member_name=excluded.member_name,reset_at=excluded.reset_at;
      return null;
    end if;
    return v_first_allowed_date;
  end if;
  return null;
end;
$$;
create or replace function public.reserve_class(p_class_date date, p_slot smallint, p_member_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text; v_today date; v_id uuid; v_count bigint; v_first_allowed_date date;
begin
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  v_today := (now() at time zone 'Europe/Madrid')::date;
  if array_length(regexp_split_to_array(v_name, ' '), 1) < 3 then raise exception 'Escribe nombre y dos apellidos'; end if;
  if not exists(select 1 from public.gym_members m where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name)) then
    raise exception 'SOCIO_NO_ENCONTRADO: No encontramos ese nombre en la base de datos de socios';
  end if;
  if not exists(select 1 from public.gym_members m where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name) and m.is_active) then
    raise exception 'SOCIO_INACTIVO: Tu perfil de socio está desactivado. Contacta con el gimnasio para reactivarlo';
  end if;
  -- Store the exact official spelling from the member register, regardless of how it was typed.
  select m.member_name into v_name from public.gym_members m
    where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name) and m.is_active
    order by m.member_name limit 1;
  v_first_allowed_date := public.reset_expired_warning_penalty(v_name);
  if v_first_allowed_date is not null and p_class_date<v_first_allowed_date then
    raise exception 'SOCIO_BLOQUEADO: Has acumulado 2 warnings en los últimos 14 días. No puedes reservar ni acudir a clases durante los 5 días posteriores al último warning. Podrás reservar clases con fecha desde el %.',
      to_char(v_first_allowed_date,'DD/MM/YYYY');
  end if;
  if p_slot is null or p_slot not between 0 and 2 then raise exception 'Clase no válida'; end if;
  if not public.gym_class_is_open(p_class_date,p_slot) then raise exception 'Esta clase no está abierta para reservas'; end if;
  if p_class_date < v_today or p_class_date > v_today + 7 then raise exception 'Solo se puede reservar con hasta 7 días de antelación'; end if;
  if public.gym_class_start(p_class_date,p_slot) < date_trunc('minute',now())+interval '10 minutes' then
    raise exception 'RESERVA_CERRADA: Las reservas se cierran 10 minutos antes del inicio de la clase';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('member:' || p_class_date::text || ':' || public.gym_member_name_key(v_name), 0));
  if exists (
    select 1 from public.gym_bookings b
    where b.class_date=p_class_date
      and public.gym_member_name_key(b.member_name)=public.gym_member_name_key(v_name)
  ) then
    raise exception 'Solo puedes reservar una clase al día. Cancela tu otra reserva si quieres elegir otra hora.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('class:' || p_class_date::text || ':' || p_slot::text, 0));
  select count(*) into v_count from public.gym_bookings b where b.class_date=p_class_date and b.class_slot=p_slot;
  if v_count >= 6 then raise exception 'Esta clase ya está completa (máximo 6 personas)'; end if;
  insert into public.gym_bookings(class_date,class_slot,member_name) values(p_class_date,p_slot,v_name) returning id into v_id;
  insert into public.gym_events(booking_id,class_date,class_slot,member_name,event_type) values(v_id,p_class_date,p_slot,v_name,'reservation');
  return jsonb_build_object('ok',true,'booking_id',v_id);
exception when unique_violation then
  raise exception 'Ya existe una reserva para ese nombre en esta clase';
end;
$$;

create or replace function public.cancel_class(p_class_date date, p_slot smallint, p_member_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text; v_booking public.gym_bookings%rowtype; v_late boolean;
begin
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  select * into v_booking from public.gym_bookings b
  where b.class_date=p_class_date and b.class_slot=p_slot
    and public.gym_member_name_key(b.member_name)=public.gym_member_name_key(v_name)
  for update;
  if not found then raise exception 'No encontramos una reserva con ese nombre en esta clase'; end if;
  if public.gym_class_start(p_class_date,p_slot) <= now() then raise exception 'La clase ya ha comenzado'; end if;
  if public.gym_class_start(p_class_date,p_slot)-now() < interval '1 hour' then
    raise exception 'CANCELACION_MENOS_DE_1HORA: No se puede cancelar una reserva cuando falta menos de una hora para la clase';
  end if;
  v_late := public.gym_class_start(p_class_date,p_slot) - now() < interval '2 hours';
  delete from public.gym_bookings where id=v_booking.id;
  insert into public.gym_events(booking_id,class_date,class_slot,member_name,event_type,late)
    values(v_booking.id,p_class_date,p_slot,v_booking.member_name,'cancellation',v_late);
  return jsonb_build_object('ok',true,'late',v_late);
end;
$$;

-- Return only the matching member's active bookings; never expose other names.
create or replace function public.my_confirmed_bookings(p_member_name text)
returns table(class_date date, class_slot smallint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_name text;
begin
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if array_length(regexp_split_to_array(v_name, ' '), 1) < 3 then
    raise exception 'Escribe nombre y dos apellidos';
  end if;
  return query
    select b.class_date, b.class_slot
    from public.gym_bookings b
    where public.gym_member_name_key(b.member_name)=public.gym_member_name_key(v_name)
    order by b.class_date,b.class_slot;
end;
$$;

-- Let a member see their current warning penalty as soon as they enter their name.
-- This returns only that member's eligibility date and never exposes warning details or other names.
create or replace function public.member_reservation_status(p_member_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_name text; v_member_name text; v_is_active boolean; v_first_allowed_date date; v_reset_at timestamptz; v_warning_count bigint;
begin
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if array_length(regexp_split_to_array(v_name, ' '), 1) < 3 then
    raise exception 'Escribe nombre y dos apellidos';
  end if;
  select m.member_name,m.is_active into v_member_name,v_is_active
  from public.gym_members m
  where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name)
  limit 1;
  if not found then return jsonb_build_object('is_member',false,'blocked_until',null); end if;
  if not v_is_active then return jsonb_build_object('is_member',true,'is_active',false,'blocked_until',null); end if;
  v_first_allowed_date := public.reset_expired_warning_penalty(v_member_name);
  select coalesce(max(r.reset_at),'-infinity'::timestamptz) into v_reset_at
    from public.gym_member_warning_resets r
    where public.gym_member_name_key(r.member_name)=public.gym_member_name_key(v_member_name);
  with warning_states as (
    select e.booking_id,e.event_type,e.created_at,
      row_number() over(partition by e.booking_id order by e.created_at desc,e.id desc) as rn
    from public.gym_events e
    where e.booking_id is not null
      and public.gym_member_name_key(e.member_name)=public.gym_member_name_key(v_member_name)
      and e.created_at>v_reset_at
      and e.event_type in ('absence','absence_reversed')
  )
  select count(*) into v_warning_count
    from warning_states
    where rn=1 and event_type='absence' and created_at>=now()-interval '14 days';
  return jsonb_build_object('is_member',true,'is_active',true,'warning_count',v_warning_count,'blocked_until',v_first_allowed_date);
end;
$$;

create or replace function public.trainer_data(p_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key) then
    raise exception 'Usuario entrenador no válido' using errcode='42501';
  end if;
  perform public.reset_expired_warning_penalty(m.member_name) from public.gym_members m;
  return jsonb_build_object(
    'is_owner', coalesce((select t.can_manage_bookings from public.gym_trainer_keys t where t.username_key=v_key),false),
    'members', coalesce((select jsonb_agg(jsonb_build_object('member_name',m.member_name,'is_active',m.is_active) order by m.is_active desc,m.member_name) from public.gym_members m),'[]'::jsonb),
    'bookings', coalesce((select jsonb_agg(to_jsonb(b) order by b.class_date,b.class_slot,b.member_name) from public.gym_bookings b),'[]'::jsonb),
    'events', coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at) from public.gym_events e),'[]'::jsonb),
    'warning_resets', coalesce((select jsonb_agg(jsonb_build_object('member_name',r.member_name,'reset_at',r.reset_at)) from public.gym_member_warning_resets r),'[]'::jsonb)
  );
end;
$$;

-- Fernando and Toni can add people to the reservation allowlist.
create or replace function public.trainer_add_member(p_key text, p_member_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_name text;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'No tienes permiso para dar de alta socios' using errcode='42501';
  end if;
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if array_length(regexp_split_to_array(v_name, ' '), 1) < 3 then raise exception 'Escribe nombre y dos apellidos'; end if;
  if exists(select 1 from public.gym_members m where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name)) then
    raise exception 'Ese socio ya está dado de alta';
  end if;
  insert into public.gym_members(member_name) values(v_name);
  if not found then raise exception 'Ese socio ya está dado de alta'; end if;
  return jsonb_build_object('ok',true,'member_name',v_name);
end;
$$;

-- Fernando and Toni may activate or deactivate a member profile.
create or replace function public.trainer_set_member_active(p_key text,p_member_name text,p_is_active boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_name text;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'Solo Fernando o Toni pueden cambiar el estado de los socios' using errcode='42501';
  end if;
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if v_name='' then raise exception 'Selecciona un socio válido'; end if;
  if p_is_active is null then raise exception 'El estado seleccionado no es válido'; end if;
  update public.gym_members m set is_active=p_is_active
    where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name)
    returning m.member_name into v_name;
  if not found then raise exception 'No encontramos ese socio en el registro'; end if;
  return jsonb_build_object('ok',true,'member_name',v_name,'is_active',p_is_active);
end;
$$;

-- Fernando and Toni may correct a registered member's name without losing bookings or history.
create or replace function public.trainer_rename_member(p_key text,p_old_name text,p_new_name text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_key text; v_old text; v_new text; v_old_key text; v_new_key text;
begin
  v_key:=lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'Solo Fernando o Toni pueden modificar los datos de los socios' using errcode='42501';
  end if;
  v_old:=regexp_replace(trim(coalesce(p_old_name,'')), '\s+', ' ', 'g');
  v_new:=regexp_replace(trim(coalesce(p_new_name,'')), '\s+', ' ', 'g');
  if array_length(regexp_split_to_array(v_new,' '),1)<3 then raise exception 'Escribe el nombre y los dos apellidos'; end if;
  v_old_key:=public.gym_member_name_key(v_old);
  v_new_key:=public.gym_member_name_key(v_new);
  if v_old_key='' then raise exception 'Selecciona un socio válido'; end if;
  perform pg_advisory_xact_lock(hashtextextended('member-rename:'||v_old_key,0));
  if exists(select 1 from public.gym_members m where public.gym_member_name_key(m.member_name)=v_new_key and public.gym_member_name_key(m.member_name)<>v_old_key) then
    raise exception 'Ya existe un socio con ese nombre';
  end if;
  update public.gym_members m set member_name=v_new
    where public.gym_member_name_key(m.member_name)=v_old_key;
  if not found then raise exception 'No encontramos ese socio en el registro'; end if;
  update public.gym_bookings b set member_name=v_new where public.gym_member_name_key(b.member_name)=v_old_key;
  update public.gym_events e set member_name=v_new where public.gym_member_name_key(e.member_name)=v_old_key;
  update public.gym_member_warning_resets r set member_key=v_new_key,member_name=v_new
    where public.gym_member_name_key(r.member_name)=v_old_key;
  return jsonb_build_object('ok',true,'old_name',v_old,'member_name',v_new);
end;
$$;
-- Any registered trainer may add a booking for a registered member on a past or future weekday.
create or replace function public.trainer_add_booking(p_key text, p_member_name text, p_class_date date, p_slot smallint)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_name text; v_trainer text; v_id uuid; v_count bigint; v_today date; v_first_allowed_date date;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  select trainer_name into v_trainer from public.gym_trainer_keys where username_key=v_key;
  if not found then raise exception 'Usuario entrenador no válido' using errcode='42501'; end if;
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if array_length(regexp_split_to_array(v_name, ' '), 1) < 3 then raise exception 'Selecciona un socio válido'; end if;
  if not exists(select 1 from public.gym_members m where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name)) then
    raise exception 'El socio seleccionado no está dado de alta';
  end if;
  if not exists(select 1 from public.gym_members m where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name) and m.is_active) then
    raise exception 'El perfil de este socio está desactivado; no se puede añadir una reserva';
  end if;
  -- Keep the official registered spelling in both the booking and its history event.
  select m.member_name into v_name from public.gym_members m
    where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name) and m.is_active
    order by m.member_name limit 1;
  v_today := (now() at time zone 'Europe/Madrid')::date;
  v_first_allowed_date := public.reset_expired_warning_penalty(v_name);
  if p_class_date>=v_today and v_first_allowed_date is not null and p_class_date<v_first_allowed_date then
    raise exception 'SOCIO_BLOQUEADO: Has acumulado 2 warnings en los últimos 14 días. No puedes reservar ni acudir a clases durante los 5 días posteriores al último warning. Podrás reservar clases con fecha desde el %.',
      to_char(v_first_allowed_date,'DD/MM/YYYY');
  end if;
  if p_slot not between 0 and 2 then raise exception 'Clase no válida'; end if;
  if p_slot is null or p_slot not between 0 and 2 then raise exception 'Clase no válida'; end if;
  if not public.gym_class_is_open(p_class_date,p_slot) then raise exception 'Esta clase no está abierta en la fecha seleccionada'; end if;
  perform pg_advisory_xact_lock(hashtextextended('member:' || p_class_date::text || ':' || public.gym_member_name_key(v_name), 0));
  if exists(select 1 from public.gym_bookings b where b.class_date=p_class_date and public.gym_member_name_key(b.member_name)=public.gym_member_name_key(v_name)) then
    raise exception 'Ese socio ya tiene una reserva registrada para ese día';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('class:' || p_class_date::text || ':' || p_slot::text, 0));
  select count(*) into v_count from public.gym_bookings b where b.class_date=p_class_date and b.class_slot=p_slot;
  if v_count >= 6 then raise exception 'Esta clase ya está completa (máximo 6 personas)'; end if;
  insert into public.gym_bookings(class_date,class_slot,member_name) values(p_class_date,p_slot,v_name) returning id into v_id;
  insert into public.gym_events(booking_id,class_date,class_slot,member_name,event_type,created_by)
    values(v_id,p_class_date,p_slot,v_name,'reservation',v_trainer);
  return jsonb_build_object('ok',true,'booking_id',v_id,'created_by',v_trainer);
exception when unique_violation then
  raise exception 'Ya existe una reserva para ese socio en esa clase';
end;
$$;
-- Fernando and Toni control the session slots for an exact calendar date.
create or replace function public.trainer_set_class_schedule(p_key text,p_class_date date,p_open_slots smallint[])
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_trainer text; v_slot smallint; v_open boolean;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  select trainer_name into v_trainer from public.gym_trainer_keys where username_key=v_key and can_manage_bookings;
  if not found then raise exception 'Solo Fernando o Toni pueden gestionar los horarios' using errcode='42501'; end if;
  if p_class_date is null then raise exception 'Selecciona una fecha'; end if;
  if exists(select 1 from unnest(coalesce(p_open_slots,'{}'::smallint[])) s where s is null or s not between 0 and 2) then
    raise exception 'Selecciona horarios válidos';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('schedule:' || p_class_date::text,0));
  if exists(
    select 1 from public.gym_bookings b
    where b.class_date=p_class_date and not(coalesce(b.class_slot=any(coalesce(p_open_slots,'{}'::smallint[])),false))
  ) then
    raise exception 'Hay reservas en alguna clase que quieres cerrar. Cancela primero esas reservas desde Reservas y vuelve a guardar el horario.';
  end if;
  delete from public.gym_class_schedule_overrides where class_date=p_class_date;
  for v_slot in 0..2 loop
    v_open := coalesce(v_slot=any(coalesce(p_open_slots,'{}'::smallint[])),false);
    if v_open is distinct from (extract(isodow from p_class_date) between 1 and 5) then
      insert into public.gym_class_schedule_overrides(class_date,class_slot,is_open,updated_by)
        values(p_class_date,v_slot,v_open,v_trainer);
    end if;
  end loop;
  return jsonb_build_object('ok',true,'class_date',p_class_date);
end;
$$;
-- Fernando and Toni can remove any active booking from the trainer roster.
create or replace function public.trainer_cancel_booking(p_key text, p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_booking public.gym_bookings%rowtype; v_start timestamptz; v_late boolean;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'No tienes permiso para cancelar reservas desde el panel' using errcode='42501';
  end if;
  select * into v_booking from public.gym_bookings where id=p_booking_id for update;
  if not found then raise exception 'La reserva ya no existe'; end if;
  v_start := public.gym_class_start(v_booking.class_date,v_booking.class_slot);
  v_late := v_start > now() and v_start - now() < interval '2 hours';
  delete from public.gym_bookings where id=v_booking.id;
  insert into public.gym_events(booking_id,class_date,class_slot,member_name,event_type,late)
    values(v_booking.id,v_booking.class_date,v_booking.class_slot,v_booking.member_name,'cancellation',v_late);
  return jsonb_build_object('ok',true,'late',v_late);
end;
$$;

-- Fernando and Toni can permanently delete a member and all their booking history.
create or replace function public.trainer_delete_member_history(p_key text, p_member_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_name text; v_bookings bigint; v_events bigint;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'No tienes permiso para borrar historiales' using errcode='42501';
  end if;
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if v_name='' then raise exception 'Selecciona un socio válido'; end if;
  delete from public.gym_bookings b
    where public.gym_member_name_key(b.member_name)=public.gym_member_name_key(v_name);
  get diagnostics v_bookings = row_count;
  delete from public.gym_events e
    where public.gym_member_name_key(e.member_name)=public.gym_member_name_key(v_name);
  get diagnostics v_events = row_count;
  delete from public.gym_members m where public.gym_member_name_key(m.member_name)=public.gym_member_name_key(v_name);
  return jsonb_build_object('ok',true,'bookings_deleted',v_bookings,'events_deleted',v_events,'member_deleted',found);
end;
$$;

-- Clear only history events for one member; keep their member record and active bookings.
create or replace function public.trainer_clear_member_history(p_key text, p_member_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_name text; v_events bigint;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'No tienes permiso para borrar historiales' using errcode='42501';
  end if;
  v_name := regexp_replace(trim(coalesce(p_member_name,'')), '\s+', ' ', 'g');
  if v_name='' then raise exception 'Selecciona un socio válido'; end if;
  delete from public.gym_events e
    where public.gym_member_name_key(e.member_name)=public.gym_member_name_key(v_name);
  get diagnostics v_events = row_count;
  return jsonb_build_object('ok',true,'events_deleted',v_events);
end;
$$;

-- Clear all history events while preserving the member list and active bookings.
create or replace function public.trainer_clear_all_member_history(p_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_events bigint;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'No tienes permiso para borrar historiales' using errcode='42501';
  end if;
  delete from public.gym_events where true;
  get diagnostics v_events = row_count;
  return jsonb_build_object('ok',true,'events_deleted',v_events);
end;
$$;

-- Compatibility alias: bulk history deletion never removes members or active bookings.
create or replace function public.trainer_delete_all_member_history(p_key text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text; v_events bigint;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key and t.can_manage_bookings) then
    raise exception 'No tienes permiso para borrar historiales' using errcode='42501';
  end if;
  delete from public.gym_events where true;
  get diagnostics v_events = row_count;
  return jsonb_build_object('ok',true,'events_deleted',v_events);
end;
$$;

create or replace function public.set_absence(p_key text, p_booking_id uuid, p_absent boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_booking public.gym_bookings%rowtype; v_key text; v_last text; v_class_end timestamptz; v_first_allowed_date date;
begin
  v_key := lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_keys t where t.username_key=v_key) then raise exception 'Usuario entrenador no válido' using errcode='42501'; end if;
  select * into v_booking from public.gym_bookings where id=p_booking_id;
  if not found then raise exception 'La reserva ya no existe'; end if;
  if p_absent and v_booking.class_date < (now() at time zone 'Europe/Madrid')::date - 6 then
    raise exception 'Solo puedes registrar warnings de sesiones de los últimos 7 días';
  end if;
  v_class_end := public.gym_class_start(v_booking.class_date,v_booking.class_slot)
    + case v_booking.class_slot when 0 then interval '1 hour' else interval '30 minutes' end;
  if v_class_end >= now() then raise exception 'La falta se puede marcar cuando termine la clase'; end if;
  v_first_allowed_date := public.reset_expired_warning_penalty(v_booking.member_name);
  select event_type into v_last from public.gym_events where booking_id=p_booking_id and event_type in ('absence','absence_reversed') order by created_at desc limit 1;
  if p_absent and v_last is distinct from 'absence' then
    insert into public.gym_events(booking_id,class_date,class_slot,member_name,event_type) values(p_booking_id,v_booking.class_date,v_booking.class_slot,v_booking.member_name,'absence');
  elsif not p_absent and v_last='absence' then
    insert into public.gym_events(booking_id,class_date,class_slot,member_name,event_type) values(p_booking_id,v_booking.class_date,v_booking.class_slot,v_booking.member_name,'absence_reversed');
  end if;
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.gym_class_start(date,smallint) from public, anon, authenticated;
revoke all on function public.get_class_counts(date,date) from public, anon, authenticated;
revoke all on function public.gym_class_is_open(date,smallint) from public, anon, authenticated;
revoke all on function public.trainer_set_class_schedule(text,date,smallint[]) from public, anon, authenticated;
revoke all on function public.reset_expired_warning_penalty(text) from public, anon, authenticated;
revoke all on function public.reserve_class(date,smallint,text) from public, anon, authenticated;
revoke all on function public.cancel_class(date,smallint,text) from public, anon, authenticated;
revoke all on function public.my_confirmed_bookings(text) from public, anon, authenticated;
revoke all on function public.member_reservation_status(text) from public, anon, authenticated;
revoke all on function public.trainer_data(text) from public, anon, authenticated;
revoke all on function public.trainer_add_member(text,text) from public, anon, authenticated;
revoke all on function public.trainer_set_member_active(text,text,boolean) from public, anon, authenticated;
revoke all on function public.trainer_rename_member(text,text,text) from public, anon, authenticated;
revoke all on function public.trainer_add_booking(text,text,date,smallint) from public, anon, authenticated;
revoke all on function public.trainer_cancel_booking(text,uuid) from public, anon, authenticated;
revoke all on function public.trainer_delete_member_history(text,text) from public, anon, authenticated;
revoke all on function public.trainer_clear_member_history(text,text) from public, anon, authenticated;
revoke all on function public.trainer_clear_all_member_history(text) from public, anon, authenticated;
revoke all on function public.trainer_delete_all_member_history(text) from public, anon, authenticated;
revoke all on function public.set_absence(text,uuid,boolean) from public, anon, authenticated;
grant execute on function public.get_class_counts(date,date) to anon, authenticated;
grant execute on function public.gym_class_is_open(date,smallint) to anon, authenticated;
grant execute on function public.trainer_set_class_schedule(text,date,smallint[]) to anon, authenticated;
grant execute on function public.reserve_class(date,smallint,text) to anon, authenticated;
grant execute on function public.cancel_class(date,smallint,text) to anon, authenticated;
grant execute on function public.my_confirmed_bookings(text) to anon, authenticated;
grant execute on function public.member_reservation_status(text) to anon, authenticated;
grant execute on function public.trainer_data(text) to anon, authenticated;
grant execute on function public.trainer_add_member(text,text) to anon, authenticated;
grant execute on function public.trainer_set_member_active(text,text,boolean) to anon, authenticated;
grant execute on function public.trainer_rename_member(text,text,text) to anon, authenticated;
grant execute on function public.trainer_add_booking(text,text,date,smallint) to anon, authenticated;
grant execute on function public.trainer_cancel_booking(text,uuid) to anon, authenticated;
grant execute on function public.trainer_delete_member_history(text,text) to anon, authenticated;
grant execute on function public.trainer_clear_member_history(text,text) to anon, authenticated;
grant execute on function public.trainer_clear_all_member_history(text) to anon, authenticated;
grant execute on function public.trainer_delete_all_member_history(text) to anon, authenticated;
grant execute on function public.set_absence(text,uuid,boolean) to anon, authenticated;

-- Refresh Supabase/PostgREST's RPC function cache after applying the schema.
notify pgrst, 'reload schema';

-- Basic trainer password authentication. Password hashes and session tokens stay in the database.
alter table public.gym_trainer_keys
  add column if not exists login_username text,
  add column if not exists login_username_key text generated always as (lower(regexp_replace(trim(login_username), '\s+', ' ', 'g'))) stored,
  add column if not exists password_hash text;
create unique index if not exists gym_trainer_keys_login_username_key_key
  on public.gym_trainer_keys(login_username_key) where login_username_key is not null;

create table if not exists public.gym_trainer_auth_sessions (
  token uuid primary key default gen_random_uuid(),
  trainer_key text not null references public.gym_trainer_keys(username_key) on delete cascade,
  expires_at timestamptz not null default (now() + interval '12 hours')
);
-- Keep trainer sessions valid until the trainer explicitly logs out.
alter table public.gym_trainer_auth_sessions alter column expires_at drop not null;
alter table public.gym_trainer_auth_sessions alter column expires_at drop default;
update public.gym_trainer_auth_sessions set expires_at=null;
alter table public.gym_trainer_auth_sessions enable row level security;
revoke all on public.gym_trainer_auth_sessions from public, anon, authenticated;

create or replace function public.trainer_password_hash(p_password text)
returns text language sql security definer set search_path=public,extensions,pg_temp as $$
  select crypt(coalesce(p_password,''),gen_salt('bf'))
$$;
revoke all on function public.trainer_password_hash(text) from public,anon,authenticated;

create or replace function public.trainer_login(p_username text, p_password text)
returns jsonb language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_trainer public.gym_trainer_keys%rowtype; v_token uuid;
begin
  select * into v_trainer from public.gym_trainer_keys t
  where t.login_username_key=lower(regexp_replace(trim(coalesce(p_username,'')), '\s+', ' ', 'g'))
    and t.password_hash is not null
    and crypt(coalesce(p_password,''),t.password_hash)=t.password_hash;
  if not found then raise exception 'Usuario o contraseña incorrectos' using errcode='42501'; end if;
  delete from public.gym_trainer_auth_sessions where expires_at is not null and expires_at<=now();
  insert into public.gym_trainer_auth_sessions(trainer_key) values(v_trainer.username_key) returning token into v_token;
  return jsonb_build_object('trainer_name',v_trainer.trainer_name,'token',v_token);
end;
$$;

create or replace function public.require_trainer_session(p_key text,p_token uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_key text;
begin
  v_key:=lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  if not exists(select 1 from public.gym_trainer_auth_sessions s where s.token=p_token and s.trainer_key=v_key and (s.expires_at is null or s.expires_at>now())) then
    raise exception 'La sesión del entrenador ha caducado. Vuelve a acceder.' using errcode='42501';
  end if;
end;
$$;

create or replace function public.trainer_logout(p_key text,p_token uuid)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_key text;
begin
  v_key:=lower(regexp_replace(trim(coalesce(p_key,'')), '\s+', ' ', 'g'));
  delete from public.gym_trainer_auth_sessions s
  where s.token=p_token and s.trainer_key=v_key;
  return jsonb_build_object('ok',true);
end;
$$;

-- Authenticated wrappers: every trainer action requires a database session token.
create or replace function public.trainer_data(p_key text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_data(p_key); end; $$;
create or replace function public.trainer_add_member(p_key text,p_member_name text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_add_member(p_key,p_member_name); end; $$;
create or replace function public.trainer_set_member_active(p_key text,p_member_name text,p_is_active boolean,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_set_member_active(p_key,p_member_name,p_is_active); end; $$;
create or replace function public.trainer_rename_member(p_key text,p_old_name text,p_new_name text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_rename_member(p_key,p_old_name,p_new_name); end; $$;
create or replace function public.trainer_add_booking(p_key text,p_member_name text,p_class_date date,p_slot smallint,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_add_booking(p_key,p_member_name,p_class_date,p_slot); end; $$;
create or replace function public.trainer_set_class_schedule(p_key text,p_class_date date,p_open_slots smallint[],p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_set_class_schedule(p_key,p_class_date,p_open_slots); end; $$;
create or replace function public.trainer_cancel_booking(p_key text,p_booking_id uuid,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_cancel_booking(p_key,p_booking_id); end; $$;
create or replace function public.trainer_delete_member_history(p_key text,p_member_name text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_delete_member_history(p_key,p_member_name); end; $$;
create or replace function public.trainer_clear_member_history(p_key text,p_member_name text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_clear_member_history(p_key,p_member_name); end; $$;
create or replace function public.trainer_clear_all_member_history(p_key text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_clear_all_member_history(p_key); end; $$;
create or replace function public.trainer_delete_all_member_history(p_key text,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.trainer_delete_all_member_history(p_key); end; $$;
create or replace function public.set_absence(p_key text,p_booking_id uuid,p_absent boolean,p_token uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$ begin perform public.require_trainer_session(p_key,p_token); return public.set_absence(p_key,p_booking_id,p_absent); end; $$;

-- Disable the old name-only entry points and expose only session-protected trainer actions.
revoke all on function public.trainer_login(text,text) from public,anon,authenticated;
revoke all on function public.require_trainer_session(text,uuid) from public,anon,authenticated;
revoke all on function public.trainer_logout(text,uuid) from public,anon,authenticated;
grant execute on function public.trainer_login(text,text) to anon,authenticated;
grant execute on function public.trainer_logout(text,uuid) to anon,authenticated;
revoke all on function public.trainer_data(text) from public,anon,authenticated;
revoke all on function public.trainer_add_member(text,text) from public,anon,authenticated;
revoke all on function public.trainer_set_member_active(text,text,boolean) from public,anon,authenticated;
revoke all on function public.trainer_rename_member(text,text,text) from public,anon,authenticated;
revoke all on function public.trainer_add_booking(text,text,date,smallint) from public,anon,authenticated;
revoke all on function public.trainer_set_class_schedule(text,date,smallint[]) from public,anon,authenticated;
revoke all on function public.trainer_cancel_booking(text,uuid) from public,anon,authenticated;
revoke all on function public.trainer_delete_member_history(text,text) from public,anon,authenticated;
revoke all on function public.trainer_clear_member_history(text,text) from public,anon,authenticated;
revoke all on function public.trainer_clear_all_member_history(text) from public,anon,authenticated;
revoke all on function public.trainer_delete_all_member_history(text) from public,anon,authenticated;
revoke all on function public.set_absence(text,uuid,boolean) from public,anon,authenticated;
grant execute on function public.trainer_data(text,uuid) to anon,authenticated;
grant execute on function public.trainer_add_member(text,text,uuid) to anon,authenticated;
grant execute on function public.trainer_set_member_active(text,text,boolean,uuid) to anon,authenticated;
grant execute on function public.trainer_rename_member(text,text,text,uuid) to anon,authenticated;
grant execute on function public.trainer_add_booking(text,text,date,smallint,uuid) to anon,authenticated;
grant execute on function public.trainer_set_class_schedule(text,date,smallint[],uuid) to anon,authenticated;
grant execute on function public.trainer_cancel_booking(text,uuid,uuid) to anon,authenticated;
grant execute on function public.trainer_delete_member_history(text,text,uuid) to anon,authenticated;
grant execute on function public.trainer_clear_member_history(text,text,uuid) to anon,authenticated;
grant execute on function public.trainer_clear_all_member_history(text,uuid) to anon,authenticated;
grant execute on function public.trainer_delete_all_member_history(text,uuid) to anon,authenticated;
grant execute on function public.set_absence(text,uuid,boolean,uuid) to anon,authenticated;
notify pgrst, 'reload schema';

