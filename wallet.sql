-- ===== SEHEMU A: majedwali ya salio =====
alter table profiles add column if not exists balance int not null default 0;
alter table profiles drop constraint if exists profiles_balance_nonneg;
alter table profiles add constraint profiles_balance_nonneg check (balance >= 0);
revoke insert, update, delete on profiles from anon, authenticated;

create table if not exists wallet_tx (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null references profiles(user_id) on delete cascade,
  kind text not null,
  amount int not null,
  balance_after int not null,
  note text
);
create table if not exists deposits (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null references profiles(user_id) on delete cascade,
  amount int not null check (amount > 0),
  network text,
  phone text,
  sms text,
  sms_hash text,
  status text not null default 'pending' check (status in ('pending','confirmed','rejected')),
  note text,
  decided_at timestamptz
);
create unique index if not exists deposits_sms_unique on deposits(sms_hash) where status <> 'rejected';
create table if not exists withdrawals (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id uuid not null references profiles(user_id) on delete cascade,
  amount int not null check (amount > 0),
  network text not null,
  phone text not null,
  status text not null default 'pending' check (status in ('pending','paid','rejected')),
  note text,
  decided_at timestamptz
);
create table if not exists room_codes (
  tournament_id bigint not null references tournaments(id) on delete cascade,
  round_no int not null,
  code text not null,
  primary key (tournament_id, round_no)
);
alter table registrations add column if not exists fee_paid int not null default 0;
alter table registrations add column if not exists prize_amount int;

alter table wallet_tx enable row level security;
alter table deposits enable row level security;
alter table withdrawals enable row level security;
alter table room_codes enable row level security;

create policy "mchezaji anaona miamala yake" on wallet_tx for select to authenticated using (user_id = auth.uid());
create policy "admin anaona miamala yote" on wallet_tx for select to authenticated using (is_admin());
create policy "mchezaji anaona amana zake" on deposits for select to authenticated using (user_id = auth.uid());
create policy "admin anaona amana zote" on deposits for select to authenticated using (is_admin());
create policy "mchezaji anaona utoaji wake" on withdrawals for select to authenticated using (user_id = auth.uid());
create policy "admin anaona utoaji wote" on withdrawals for select to authenticated using (is_admin());
create policy "admin anadhibiti code" on room_codes for all to authenticated using (is_admin()) with check (is_admin());

revoke all on wallet_tx, deposits, withdrawals, room_codes from anon, authenticated;
grant select on wallet_tx, deposits, withdrawals to authenticated;
grant select, insert, update, delete on room_codes to authenticated;

-- ===== SEHEMU B: kazi za mchezaji (kuweka, kutoa, kujiunga) =====
create or replace function request_deposit(p_amount int, p_network text, p_phone text, p_sms text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_hash text; v_id bigint;
begin
  if v_uid is null then raise exception 'Ingia kwanza'; end if;
  if p_amount is null or p_amount < 500 or p_amount > 1000000 then raise exception 'Kiasi kiwe kuanzia TSh 500'; end if;
  if length(coalesce(p_sms,'')) < 20 or length(p_sms) > 1000 then raise exception 'Bandika meseji kamili ya muamala'; end if;
  if length(coalesce(p_phone,'')) < 9 or length(p_phone) > 20 then raise exception 'Namba ya simu si sahihi'; end if;
  if (select count(*) from deposits where user_id = v_uid and status = 'pending') >= 5 then
    raise exception 'Una maombi mengi yanayosubiri. Subiri yahakikiwe kwanza';
  end if;
  v_hash := md5(lower(regexp_replace(p_sms, '\s+', ' ', 'g')));
  if exists(select 1 from deposits where sms_hash = v_hash and status <> 'rejected') then
    raise exception 'Meseji hii ya muamala imeshatumika';
  end if;
  insert into deposits(user_id, amount, network, phone, sms, sms_hash)
  values (v_uid, p_amount, p_network, p_phone, p_sms, v_hash) returning id into v_id;
  return v_id;
end $$;

create or replace function request_withdrawal(p_amount int, p_network text, p_phone text) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_bal int; v_new int; v_id bigint;
begin
  if v_uid is null then raise exception 'Ingia kwanza'; end if;
  if p_amount is null or p_amount < 1000 then raise exception 'Kiwango cha chini cha kutoa ni TSh 1,000'; end if;
  if length(coalesce(p_network,'')) < 3 or length(coalesce(p_phone,'')) < 9 or length(p_phone) > 20 then
    raise exception 'Jaza mtandao na namba ya kupokea';
  end if;
  select balance into v_bal from profiles where user_id = v_uid for update;
  if v_bal is null then raise exception 'Akaunti haina wasifu'; end if;
  if v_bal < p_amount then raise exception 'Salio halitoshi'; end if;
  v_new := v_bal - p_amount;
  update profiles set balance = v_new where user_id = v_uid;
  insert into withdrawals(user_id, amount, network, phone) values (v_uid, p_amount, p_network, p_phone) returning id into v_id;
  insert into wallet_tx(user_id, kind, amount, balance_after, note)
  values (v_uid, 'withdrawal', -p_amount, v_new, 'Ombi la kutoa pesa #' || v_id);
  return v_id;
end $$;

create or replace function join_tournament(p_tournament bigint) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  t tournaments%rowtype;
  v_name text; v_phone text; v_bal int; v_new int; tk text; v_code text;
begin
  if v_uid is null then raise exception 'Ingia kwanza'; end if;
  select * into t from tournaments where id = p_tournament and active for update;
  if not found then raise exception 'Kombe halipatikani'; end if;
  if t.filled >= t.slots then raise exception 'Kombe limejaa'; end if;
  select name, phone, balance into v_name, v_phone, v_bal from profiles where user_id = v_uid for update;
  if v_name is null then raise exception 'Akaunti haina wasifu'; end if;
  if exists(select 1 from registrations where tournament_id = t.id and round_no = t.round_no and user_id = v_uid and status <> 'rejected') then
    raise exception 'Tayari umejiunga na kombe hili';
  end if;
  if t.fee > 0 then
    if v_bal < t.fee then raise exception 'Salio halitoshi. Weka pesa kwanza'; end if;
    v_new := v_bal - t.fee;
    update profiles set balance = v_new where user_id = v_uid;
    insert into wallet_tx(user_id, kind, amount, balance_after, note) values (v_uid, 'entry', -t.fee, v_new, 'Ada ya ' || t.title);
  end if;
  loop
    tk := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists(select 1 from registrations where ticket = tk);
  end loop;
  select code into v_code from room_codes where tournament_id = t.id and round_no = t.round_no;
  insert into registrations(user_id, tournament_id, ticket, kind, player_name, phone, status, room_code, fee_paid)
  values (v_uid, t.id, tk, case when t.fee > 0 then 'paid' else 'free' end, v_name, v_phone, 'confirmed', v_code, t.fee);
  update tournaments set filled = filled + 1 where id = t.id;
  return tk;
end $$;

grant execute on function request_deposit(int,text,text,text) to authenticated;
grant execute on function request_withdrawal(int,text,text) to authenticated;
grant execute on function join_tournament(bigint) to authenticated;

-- ===== SEHEMU C: kazi za admin =====
create or replace function confirm_deposit(p_id bigint, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare d deposits%rowtype; v_new int;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select * into d from deposits where id = p_id for update;
  if not found then raise exception 'Ombi halipo'; end if;
  if d.status <> 'pending' then raise exception 'Ombi hili limeshashughulikiwa'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Kiasi si sahihi'; end if;
  update profiles set balance = balance + p_amount where user_id = d.user_id returning balance into v_new;
  if v_new is null then raise exception 'Mchezaji hana wasifu'; end if;
  update deposits set status = 'confirmed', amount = p_amount, decided_at = now() where id = p_id;
  insert into wallet_tx(user_id, kind, amount, balance_after, note) values (d.user_id, 'deposit', p_amount, v_new, 'Amana #' || p_id);
end $$;

create or replace function reject_deposit(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare d deposits%rowtype;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select * into d from deposits where id = p_id for update;
  if not found then raise exception 'Ombi halipo'; end if;
  if d.status <> 'pending' then raise exception 'Ombi hili limeshashughulikiwa'; end if;
  update deposits set status = 'rejected', note = nullif(trim(coalesce(p_note,'')), ''), decided_at = now() where id = p_id;
end $$;

create or replace function pay_withdrawal(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare w withdrawals%rowtype;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select * into w from withdrawals where id = p_id for update;
  if not found then raise exception 'Ombi halipo'; end if;
  if w.status <> 'pending' then raise exception 'Ombi hili limeshashughulikiwa'; end if;
  update withdrawals set status = 'paid', note = nullif(trim(coalesce(p_note,'')), ''), decided_at = now() where id = p_id;
end $$;

create or replace function reject_withdrawal(p_id bigint, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare w withdrawals%rowtype; v_new int;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select * into w from withdrawals where id = p_id for update;
  if not found then raise exception 'Ombi halipo'; end if;
  if w.status <> 'pending' then raise exception 'Ombi hili limeshashughulikiwa'; end if;
  update profiles set balance = balance + w.amount where user_id = w.user_id returning balance into v_new;
  update withdrawals set status = 'rejected', note = nullif(trim(coalesce(p_note,'')), ''), decided_at = now() where id = p_id;
  insert into wallet_tx(user_id, kind, amount, balance_after, note) values (w.user_id, 'refund', w.amount, v_new, 'Ombi la kutoa #' || p_id || ' limekataliwa');
end $$;

create or replace function award_prize(p_registration bigint, p_amount int, p_place int) returns void
language plpgsql security definer set search_path = public as $$
declare r registrations%rowtype; v_new int;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select * into r from registrations where id = p_registration for update;
  if not found then raise exception 'Mshiriki hayupo'; end if;
  if r.status <> 'confirmed' then raise exception 'Mshiriki hajathibitishwa'; end if;
  if r.prize_paid then raise exception 'Zawadi imeshatolewa kwa mshiriki huyu'; end if;
  if r.user_id is null then raise exception 'Mshiriki huyu hana akaunti (usajili wa zamani). Mlipe kwa mkono'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 10000000 then raise exception 'Kiasi si sahihi'; end if;
  update profiles set balance = balance + p_amount where user_id = r.user_id returning balance into v_new;
  if v_new is null then raise exception 'Mchezaji hana wasifu'; end if;
  update registrations set prize_paid = true, prize_amount = p_amount, prize_note = 'Mshindi wa ' || p_place where id = r.id;
  insert into wallet_tx(user_id, kind, amount, balance_after, note) values (r.user_id, 'prize', p_amount, v_new, 'Zawadi: mshindi wa ' || p_place);
end $$;

create or replace function remove_registration(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare r registrations%rowtype; v_new int;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select * into r from registrations where id = p_id for update;
  if not found then raise exception 'Mshiriki hayupo'; end if;
  if r.status <> 'confirmed' then raise exception 'Mshiriki huyu hajathibitishwa'; end if;
  if r.prize_paid then raise exception 'Ameshapewa zawadi, hawezi kuondolewa'; end if;
  update registrations set status = 'rejected', room_code = null where id = r.id;
  update tournaments set filled = greatest(0, filled - 1) where id = r.tournament_id and round_no = r.round_no;
  if r.fee_paid > 0 and r.user_id is not null then
    update profiles set balance = balance + r.fee_paid where user_id = r.user_id returning balance into v_new;
    if v_new is not null then
      insert into wallet_tx(user_id, kind, amount, balance_after, note) values (r.user_id, 'refund', r.fee_paid, v_new, 'Marejesho ya ada (umeondolewa kwenye kombe)');
    end if;
  end if;
end $$;

create or replace function set_room_code(p_tournament bigint, p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare v_round int;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  select round_no into v_round from tournaments where id = p_tournament;
  if v_round is null then raise exception 'Kombe halipo'; end if;
  if length(trim(coalesce(p_code,''))) < 1 then raise exception 'Weka code'; end if;
  insert into room_codes(tournament_id, round_no, code) values (p_tournament, v_round, trim(p_code))
  on conflict (tournament_id, round_no) do update set code = excluded.code;
  update registrations set room_code = trim(p_code) where tournament_id = p_tournament and round_no = v_round and status = 'confirmed';
end $$;

create or replace function admin_adjust(p_user uuid, p_amount int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare v_new int;
begin
  if not is_admin() then raise exception 'Hairuhusiwi'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 10000000 then raise exception 'Kiasi si sahihi'; end if;
  update profiles set balance = balance + p_amount where user_id = p_user returning balance into v_new;
  if v_new is null then raise exception 'Mchezaji hayupo'; end if;
  insert into wallet_tx(user_id, kind, amount, balance_after, note)
  values (p_user, 'adjust', p_amount, v_new, coalesce(nullif(trim(coalesce(p_note,'')), ''), 'Marekebisho ya admin'));
end $$;

grant execute on function confirm_deposit(bigint,int) to authenticated;
grant execute on function reject_deposit(bigint,text) to authenticated;
grant execute on function pay_withdrawal(bigint,text) to authenticated;
grant execute on function reject_withdrawal(bigint,text) to authenticated;
grant execute on function award_prize(bigint,int,int) to authenticated;
grant execute on function remove_registration(bigint) to authenticated;
grant execute on function set_room_code(bigint,text) to authenticated;
grant execute on function admin_adjust(uuid,int,text) to authenticated;
