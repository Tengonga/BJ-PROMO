-- =====================================================================
--  BlackJack Smashburger · Promo QR
--  Pegar entero en Supabase → SQL Editor → Run
--  Antes de ejecutar: cambia fechas, cupos y la CLAVE DEL PERSONAL (abajo)
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- Configuración (una sola fila) ----------
create table if not exists public.promo_config (
  id             int primary key default 1 check (id = 1),
  max_tickets    int not null default 1000,
  burger_quota   int not null default 200,      -- cuántos de los 1000 son burger; el resto, patatas
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  staff_pin_hash text not null
);

-- ---------- Tickets ----------
create table if not exists public.tickets (
  id           bigint generated always as identity primary key,
  code         text unique not null,
  contact      text unique not null,             -- email o móvil normalizado: 1 ticket por contacto
  contact_type text not null check (contact_type in ('email','phone')),
  prize        text not null check (prize in ('burger','patatas')),
  created_at   timestamptz not null default now(),
  redeemed_at  timestamptz,
  redeemed_at_sede text
);

-- Nadie lee ni escribe las tablas directamente: todo pasa por las funciones de abajo
alter table public.promo_config enable row level security;
alter table public.tickets      enable row level security;
revoke all on public.promo_config, public.tickets from anon, authenticated;

-- ---------- Generador de códigos (sin 0/O/1/I para que no se confundan) ----------
create or replace function public._rand_chars(n int)
returns text language plpgsql volatile
set search_path = public, extensions as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32 caracteres
  b bytea := extensions.gen_random_bytes(n);
  r text := '';
begin
  for i in 0..n-1 loop
    r := r || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return r;
end $$;

-- ---------- Cliente: pedir ticket ----------
create or replace function public.claim_ticket(p_contact text, p_consent boolean)
returns json language plpgsql security definer
set search_path = public, extensions as $$
declare
  cfg            public.promo_config;
  v_contact      text;
  v_type         text;
  v_issued       int;
  v_burgers      int;
  v_remaining    int;
  v_burgers_left int;
  v_prize        text;
  v_code         text;
begin
  if not coalesce(p_consent, false) then
    return json_build_object('status', 'no_consent');
  end if;

  select * into cfg from public.promo_config where id = 1;
  if now() < cfg.starts_at then return json_build_object('status', 'not_started', 'starts_at', cfg.starts_at); end if;
  if now() > cfg.ends_at   then return json_build_object('status', 'ended'); end if;

  -- Normalizar contacto
  v_contact := lower(trim(coalesce(p_contact, '')));
  if v_contact ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then
    v_type := 'email';
  else
    v_contact := regexp_replace(v_contact, '\D', '', 'g');
    if length(v_contact) = 11 and left(v_contact, 2) = '34' then v_contact := substr(v_contact, 3); end if;
    if length(v_contact) = 13 and left(v_contact, 4) = '0034' then v_contact := substr(v_contact, 5); end if;
    if v_contact ~ '^[67]\d{8}$' then
      v_type := 'phone';
    else
      return json_build_object('status', 'invalid_contact');
    end if;
  end if;

  -- Un solo ticket a la vez: así el tope de 1000 nunca se supera aunque escaneen 50 a la vez
  perform pg_advisory_xact_lock(4242);

  if exists (select 1 from public.tickets where contact = v_contact) then
    return json_build_object('status', 'already');
  end if;

  select count(*), count(*) filter (where prize = 'burger')
    into v_issued, v_burgers
    from public.tickets;

  if v_issued >= cfg.max_tickets then
    return json_build_object('status', 'sold_out');
  end if;

  -- Sorteo tipo "urna": siempre salen exactamente burger_quota burgers en total
  v_remaining    := cfg.max_tickets - v_issued;
  v_burgers_left := greatest(cfg.burger_quota - v_burgers, 0);
  if random() < v_burgers_left::float / v_remaining then
    v_prize := 'burger';
  else
    v_prize := 'patatas';
  end if;

  loop
    v_code := 'BJ-' || public._rand_chars(4) || '-' || public._rand_chars(4);
    exit when not exists (select 1 from public.tickets where code = v_code);
  end loop;

  insert into public.tickets (code, contact, contact_type, prize)
  values (v_code, v_contact, v_type, v_prize);

  return json_build_object(
    'status',  'ok',
    'code',    v_code,
    'prize',   v_prize,
    'ends_at', cfg.ends_at,
    'left',    v_remaining - 1
  );
end $$;

-- ---------- Público: cuántos quedan ----------
create or replace function public.tickets_left()
returns json language sql security definer stable
set search_path = public as $$
  select json_build_object(
    'left',      greatest(c.max_tickets - (select count(*) from public.tickets), 0),
    'starts_at', c.starts_at,
    'ends_at',   c.ends_at
  )
  from public.promo_config c where c.id = 1;
$$;

-- ---------- Personal: comprobar clave ----------
create or replace function public._staff_ok(p_pin text)
returns boolean language plpgsql security definer volatile
set search_path = public, extensions as $$
declare ok boolean;
begin
  select extensions.crypt(coalesce(p_pin, ''), staff_pin_hash) = staff_pin_hash
    into ok from public.promo_config where id = 1;
  if not coalesce(ok, false) then
    perform pg_sleep(1);  -- frena intentos de adivinar la clave
  end if;
  return coalesce(ok, false);
end $$;

-- ---------- Personal: consultar ticket ----------
create or replace function public.check_ticket(p_code text, p_pin text)
returns json language plpgsql security definer
set search_path = public as $$
declare t public.tickets;
begin
  if not public._staff_ok(p_pin) then return json_build_object('status', 'bad_pin'); end if;
  select * into t from public.tickets where code = upper(trim(p_code));
  if not found then return json_build_object('status', 'not_found'); end if;
  return json_build_object(
    'status',      case when t.redeemed_at is null then 'valid' else 'used' end,
    'code',        t.code,
    'prize',       t.prize,
    'created_at',  t.created_at,
    'redeemed_at', t.redeemed_at,
    'sede',        t.redeemed_at_sede
  );
end $$;

-- ---------- Personal: canjear ticket ----------
create or replace function public.redeem_ticket(p_code text, p_pin text, p_sede text)
returns json language plpgsql security definer
set search_path = public as $$
declare t public.tickets;
begin
  if not public._staff_ok(p_pin) then return json_build_object('status', 'bad_pin'); end if;

  update public.tickets
     set redeemed_at = now(), redeemed_at_sede = p_sede
   where code = upper(trim(p_code)) and redeemed_at is null
  returning * into t;

  if found then
    return json_build_object('status', 'redeemed', 'code', t.code, 'prize', t.prize);
  end if;

  select * into t from public.tickets where code = upper(trim(p_code));
  if not found then return json_build_object('status', 'not_found'); end if;
  return json_build_object('status', 'used', 'code', t.code, 'prize', t.prize,
                           'redeemed_at', t.redeemed_at, 'sede', t.redeemed_at_sede);
end $$;

-- ---------- Permisos: la web solo puede llamar a estas 4 funciones ----------
revoke all on function public._rand_chars(int)  from public, anon, authenticated;
revoke all on function public._staff_ok(text)   from public, anon, authenticated;
revoke all on function public.claim_ticket(text, boolean)       from public;
revoke all on function public.tickets_left()                    from public;
revoke all on function public.check_ticket(text, text)          from public;
revoke all on function public.redeem_ticket(text, text, text)   from public;
grant execute on function public.claim_ticket(text, boolean)     to anon;
grant execute on function public.tickets_left()                  to anon;
grant execute on function public.check_ticket(text, text)        to anon;
grant execute on function public.redeem_ticket(text, text, text) to anon;

-- =====================================================================
--  CONFIGURA AQUÍ: fechas, cupos y clave del personal (mínimo 10 caracteres)
-- =====================================================================
insert into public.promo_config (id, max_tickets, burger_quota, starts_at, ends_at, staff_pin_hash)
values (
  1,
  1000,                                   -- tickets totales
  200,                                    -- de ellos, burgers (el resto patatas)
  '2026-11-20 00:00:00+01',               -- inicio
  '2026-12-20 23:59:59+01',               -- fin
  extensions.crypt('CAMBIA-ESTA-CLAVE', extensions.gen_salt('bf'))
)
on conflict (id) do update set
  max_tickets    = excluded.max_tickets,
  burger_quota   = excluded.burger_quota,
  starts_at      = excluded.starts_at,
  ends_at        = excluded.ends_at,
  staff_pin_hash = excluded.staff_pin_hash;
