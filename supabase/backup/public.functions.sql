CREATE OR REPLACE FUNCTION public.adjust_oil_stock(p_outlet_id text, p_oil_type text, p_size text, p_delta integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  insert into oil_inventory (outlet_id, oil_type, size, stock, unit)
  values (p_outlet_id, p_oil_type, p_size, greatest(p_delta, 0), 'botol')
  on conflict (outlet_id, oil_type, size)
  do update set stock = greatest(oil_inventory.stock + p_delta, 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.auto_free_expired_therapists()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare
  v_now bigint;
  r record;
  v_done int := 0;
begin
  v_now := (extract(epoch from now()) * 1000)::bigint;

  -- (1) Terapis yang waktu treatment-nya sudah lewat -> langsung free.
  --     Booking TIDAK disentuh (tetap 'berjalan').
  for r in
    select t.id as tid
    from therapists t
    where t.status = 'ambil_tamu'
      and t.end_at is not null
      and t.end_at <= v_now
  loop
    perform clear_therapist_session(r.tid);
    v_done := v_done + 1;
  end loop;

  -- (2) Terapis 'ambil_tamu' yang tidak punya booking 'berjalan' sama sekali
  --     (status nyangkut dari sisa lama) -> paksa bersihkan jadi free.
  --     KECUALI yang sedang ONCALL (booking status 'selesai' tapi terapis
  --     diberi blok sementara) — itu dibebaskan oleh kasus (1) begitu
  --     jam oncall selesai (end_at lewat).
  for r in
    select t.id as tid
    from therapists t
    where t.status = 'ambil_tamu'
      and not exists (
        select 1 from bookings b
        where b.therapist_id = t.id and b.status = 'berjalan'
      )
      and not exists (
        select 1 from bookings b
        where b.therapist_id = t.id
          and b.booking_source = 'oncall'
          and b.status <> 'batal'
      )
  loop
    perform clear_therapist_session(r.tid);
    v_done := v_done + 1;
  end loop;

  -- (3) BLOKIR ONCALL MASUK: terapis yang masih FREE tapi punya
  --     jadwal oncall akan diblock mulai (jam mulai - 20 menit)
  --     sampai jam selesai oncall.
  for r in
    select b.therapist_id as tid,
           b.outlet_id,
           b.id as booking_id,
           b.treatment_name,
           b.treatment_price,
           b.payment_method,
           b.start_at,
           b.end_at
    from bookings b
    where b.booking_source = 'oncall'
      and b.status <> 'batal'
      and b.start_at is not null
      and b.end_at is not null
      and b.start_at <= v_now + 1200000   -- mulai sudah <= (sekarang + 20 menit)
      and b.end_at > v_now                -- oncall belum selesai
  loop
    if not exists (
      select 1 from therapists t where t.id = r.tid and t.status = 'ambil_tamu'
    ) then
      update therapists set
        status = 'ambil_tamu',
        current_outlet_id = r.outlet_id,
        current_group_id = 'oncall:' || r.booking_id::text,
        current_booking_id = r.booking_id::text,
        current_booking_ids = coalesce(current_booking_ids, '[]'::jsonb) || jsonb_build_array(r.booking_id::text),
        current_treatment_names = coalesce(current_treatment_names, '[]'::jsonb) || jsonb_build_array(r.treatment_name),
        current_treatment_name = r.treatment_name,
        current_paid = true,
        current_payment_method = r.payment_method,
        current_price = r.treatment_price,
        start_at = r.start_at,
        end_at = r.end_at
      where id = r.tid;
      v_done := v_done + 1;
    end if;
  end loop;

  return v_done;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancel_booking_full(p_outlet_id text, p_booking_id uuid, p_therapist_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_uses_oil boolean;
  v_oil_type text;
  v_oil_size text;
begin
  select uses_oil, oil_type, oil_size into v_uses_oil, v_oil_type, v_oil_size
    from bookings where id = p_booking_id and outlet_id = p_outlet_id;

  if found then
    if v_uses_oil and v_oil_type is not null and v_oil_size is not null then
      update oil_inventory
         set stock = stock + 1
       where outlet_id = p_outlet_id and oil_type = v_oil_type and size = v_oil_size;
    end if;
    update bookings set status = 'batal', cancelled_at = now(), completed_at = null
     where id = p_booking_id and outlet_id = p_outlet_id;
    perform log_audit('cancel', p_booking_id, p_outlet_id, jsonb_build_object('type','full'));
  end if;

  if p_therapist_id is not null then
    perform clear_therapist_session(p_therapist_id);
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancel_booking_partial(p_outlet_id text, p_booking_id uuid, p_therapist_id uuid, p_new_price numeric)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_commission_percent numeric;
  v_old_price numeric;
begin
  select commission_percent, treatment_price into v_commission_percent, v_old_price
    from bookings where id = p_booking_id and outlet_id = p_outlet_id;

  if found then
    update bookings set
      status = 'batal_sebagian',
      original_price = v_old_price,
      treatment_price = p_new_price,
      commission_amount = round(v_commission_percent / 100.0 * p_new_price),
      cancelled_at = now()
    where id = p_booking_id and outlet_id = p_outlet_id;
    perform log_audit('cancel_partial', p_booking_id, p_outlet_id,
      jsonb_build_object('old_price', v_old_price, 'new_price', p_new_price));
  end if;

  if p_therapist_id is not null then
    perform clear_therapist_session(p_therapist_id);
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cancel_oncall_booking(p_booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_tid uuid;
  v_other integer := 0;
begin
  if not exists (
    select 1 from bookings
    where id = p_booking_id and booking_source = 'oncall' and status <> 'batal'
  ) then
    raise exception 'Transaksi oncall tidak ditemukan atau sudah dibatalkan';
  end if;

  select therapist_id into v_tid from bookings where id = p_booking_id;

  update bookings
     set status = 'batal',
         paid = false,
         cancelled_at = now()
   where id = p_booking_id and booking_source = 'oncall';

  select count(*) into v_other
    from bookings
   where booking_source = 'oncall'
     and status <> 'batal'
     and id <> p_booking_id
     and therapist_id = v_tid;

  if v_other = 0 then
    update therapists
       set status = 'free',
           current_outlet_id = null,
           current_booking_id = null,
           current_booking_ids = '[]'::jsonb,
           current_treatment_names = '[]'::jsonb,
           current_treatment_name = null,
           current_paid = false,
           current_payment_method = null,
           current_price = null,
           current_group_id = null,
           start_at = null,
           end_at = null
     where current_group_id = 'oncall:' || p_booking_id::text;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.clear_therapist_session(p_therapist_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update therapists set
    status = 'free',
    current_outlet_id = null,
    current_booking_ids = null,
    current_booking_id = null,
    current_treatment_names = null,
    current_treatment_name = null,
    current_paid = null,
    current_payment_method = null,
    current_price = null,
    current_group_id = null,
    start_at = null,
    end_at = null
  where id = p_therapist_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.complete_booking(p_outlet_id text, p_booking_id uuid, p_therapist_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update bookings set status = 'selesai', completed_at = now()
   where id = p_booking_id and outlet_id = p_outlet_id;

  if p_therapist_id is not null then
    perform clear_therapist_session(p_therapist_id);
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.continue_booking(p_therapist_id uuid, p_treatment_id uuid, p_treatment_name text, p_treatment_price numeric, p_commission_percent numeric, p_duration_minutes integer, p_uses_oil boolean, p_oil_type text, p_oil_size text, p_customer_name text DEFAULT ''::text, p_paid boolean DEFAULT false, p_payment_method text DEFAULT 'cash'::text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_booking_id uuid;
  v_commission numeric;
  v_outlet text;
  v_group text;
  v_start bigint;
  v_end bigint;
  v_old_end bigint;
begin
  select current_outlet_id, current_group_id, end_at
  into v_outlet, v_group, v_old_end
  from therapists where id = p_therapist_id;

  if v_outlet is null then
    raise exception 'Terapis tidak sedang mengambil tamu';
  end if;

  v_start := (extract(epoch from now())::bigint * 1000);
  v_end := greatest(coalesce(v_old_end, v_start), v_start) + (p_duration_minutes * 60000);

  select round(p_commission_percent/100.0 * p_treatment_price) into v_commission;

  if p_uses_oil and p_oil_type is not null and p_oil_size is not null then
    update oil_inventory
       set stock = greatest(stock - 1, 0)
     where outlet_id = v_outlet and oil_type = p_oil_type and size = p_oil_size;
  end if;

  insert into bookings (
    outlet_id, therapist_id, therapist_name, treatment_id, treatment_name,
    treatment_price, commission_percent, commission_amount, duration_minutes,
    uses_oil, oil_type, oil_size, customer_name, status, paid, payment_method,
    group_id, start_at, end_at, created_at, original_price
  )
  select
    th.current_outlet_id, th.id, th.name, p_treatment_id, p_treatment_name,
    p_treatment_price, p_commission_percent, v_commission, p_duration_minutes,
    p_uses_oil, p_oil_type, p_oil_size, p_customer_name,
    'berjalan', p_paid, p_payment_method,
    th.current_group_id, v_start, v_end, now(), null
  from therapists th
  where th.id = p_therapist_id
  returning id into v_booking_id;

  update therapists t set
    current_booking_ids = coalesce(t.current_booking_ids, '[]'::jsonb) || jsonb_build_array(v_booking_id::text),
    current_booking_id = v_booking_id::text,
    current_treatment_names = coalesce(t.current_treatment_names, '[]'::jsonb) || jsonb_build_array(p_treatment_name),
    current_price = (select sum(treatment_price) from bookings where therapist_id = p_therapist_id and status = 'berjalan'),
    current_paid = (select bool_and(paid) from bookings where therapist_id = p_therapist_id and status = 'berjalan'),
    current_payment_method = coalesce(t.current_payment_method, p_payment_method),
    end_at = v_end
  where t.id = p_therapist_id;

  return v_booking_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_booking(p_outlet_id text, p_therapist_id uuid, p_therapist_name text, p_treatment_id uuid, p_treatment_name text, p_treatment_price numeric, p_commission_percent numeric, p_duration_minutes integer, p_uses_oil boolean, p_oil_type text, p_oil_size text, p_customer_name text, p_paid boolean, p_payment_method text, p_group_id text, p_update_therapist boolean DEFAULT true, p_original_price numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_booking_id uuid;
  v_commission numeric;
  v_end_at bigint;
  v_start_at bigint;
begin
  select round(p_commission_percent/100.0 * p_treatment_price) into v_commission;
  v_start_at := (extract(epoch from now())::bigint * 1000);
  v_end_at := v_start_at + (p_duration_minutes * 60000);

  if p_uses_oil and p_oil_type is not null and p_oil_size is not null then
    update oil_inventory
       set stock = greatest(stock - 1, 0)
     where outlet_id = p_outlet_id and oil_type = p_oil_type and size = p_oil_size;
  end if;

  insert into bookings (
    outlet_id, therapist_id, therapist_name, treatment_id, treatment_name,
    treatment_price, commission_percent, commission_amount, duration_minutes,
    uses_oil, oil_type, oil_size, customer_name, status, paid, payment_method,
    group_id, start_at, end_at, created_at, original_price
  ) values (
    p_outlet_id, p_therapist_id, p_therapist_name, p_treatment_id, p_treatment_name,
    p_treatment_price, p_commission_percent, v_commission, p_duration_minutes,
    p_uses_oil, p_oil_type, p_oil_size, p_customer_name,
    'berjalan', p_paid, p_payment_method, p_group_id,
    v_start_at, v_end_at, now(), p_original_price
  ) returning id into v_booking_id;

  if p_update_therapist and p_therapist_id is not null then
    update therapists set
      status = 'ambil_tamu',
      current_outlet_id = p_outlet_id,
      current_booking_ids = coalesce(current_booking_ids, '[]'::jsonb) || jsonb_build_array(v_booking_id::text),
      current_treatment_names = coalesce(current_treatment_names, '[]'::jsonb) || jsonb_build_array(p_treatment_name),
      current_booking_id = v_booking_id::text,
      current_treatment_name = p_treatment_name,
      current_paid = p_paid,
      current_payment_method = p_payment_method,
      current_price = p_treatment_price,
      current_group_id = p_group_id,
      start_at = v_start_at,
      end_at = v_end_at
    where id = p_therapist_id;
  end if;

  return v_booking_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_booking(p_outlet_id text, p_therapist_id uuid, p_therapist_name text, p_treatment_id uuid, p_treatment_name text, p_treatment_price numeric, p_commission_percent numeric, p_duration_minutes integer, p_uses_oil boolean, p_oil_type text, p_oil_size text, p_customer_name text, p_paid boolean, p_payment_method text, p_group_id text, p_update_therapist boolean DEFAULT true, p_original_price numeric DEFAULT NULL::numeric, p_discount_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_booking_id uuid;
  v_commission numeric;
  v_end_at bigint;
  v_start_at bigint;
  v_uid uuid := auth.uid();
  v_discount_pct numeric;
begin
  select round(p_commission_percent/100.0 * p_treatment_price) into v_commission;
  v_start_at := (extract(epoch from now())::bigint * 1000);
  v_end_at := v_start_at + (p_duration_minutes * 60000);
  -- Jika ada original_price lebih tinggi dari harga bayar -> dianggap diskon
  v_discount_pct := case
    when p_original_price is not null and p_original_price > p_treatment_price
      then round(100 - (p_treatment_price::numeric * 100 / p_original_price), 1)
    else 0
  end;

  if p_uses_oil and p_oil_type is not null and p_oil_size is not null then
    update oil_inventory
       set stock = greatest(stock - 1, 0)
     where outlet_id = p_outlet_id and oil_type = p_oil_type and size = p_oil_size;
  end if;

  insert into bookings (
    outlet_id, therapist_id, therapist_name, treatment_id, treatment_name,
    treatment_price, commission_percent, commission_amount, duration_minutes,
    uses_oil, oil_type, oil_size, customer_name, status, paid, payment_method,
    group_id, start_at, end_at, created_at, original_price, created_by,
    discount_pct, discount_reason
  ) values (
    p_outlet_id, p_therapist_id, p_therapist_name, p_treatment_id, p_treatment_name,
    p_treatment_price, p_commission_percent, v_commission, p_duration_minutes,
    p_uses_oil, p_oil_type, p_oil_size, p_customer_name,
    'berjalan', p_paid, p_payment_method, p_group_id,
    v_start_at, v_end_at, now(), p_original_price, v_uid,
    v_discount_pct, case when v_discount_pct > 0 then p_discount_reason else null end
  ) returning id into v_booking_id;

  if p_update_therapist and p_therapist_id is not null then
    update therapists set
      status = 'ambil_tamu',
      current_outlet_id = p_outlet_id,
      current_booking_ids = coalesce(current_booking_ids, '[]'::jsonb) || jsonb_build_array(v_booking_id::text),
      current_treatment_names = coalesce(current_treatment_names, '[]'::jsonb) || jsonb_build_array(p_treatment_name),
      current_booking_id = v_booking_id::text,
      current_treatment_name = p_treatment_name,
      current_paid = p_paid,
      current_payment_method = p_payment_method,
      current_price = p_treatment_price,
      current_group_id = p_group_id,
      start_at = v_start_at,
      end_at = v_end_at
    where id = p_therapist_id;
  end if;

  perform log_audit('create', v_booking_id, p_outlet_id,
    jsonb_build_object('therapist', p_therapist_name, 'treatment', p_treatment_name,
      'price', p_treatment_price, 'original_price', p_original_price, 'paid', p_paid,
      'discount_reason', p_discount_reason));

  return v_booking_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_booking_batch(p_items jsonb, p_group_id text)
 RETURNS TABLE(booking_id uuid)
 LANGUAGE plpgsql
AS $function$
declare
  v_booking_id uuid;
  v_commission numeric;
  v_end bigint;
  v_start bigint;
  v_ids uuid[] := '{}';
  v_uid uuid := auth.uid();
  v_discount_pct numeric;
  rec record;
begin
  v_start := (extract(epoch from now())::bigint * 1000);

  for rec in
    select * from jsonb_to_recordset(p_items) as x(
      outlet_id text,
      therapist_id uuid,
      therapist_name text,
      treatment_id uuid,
      treatment_name text,
      treatment_price numeric,
      commission_percent numeric,
      duration_minutes int,
      uses_oil boolean,
      oil_type text,
      oil_size text,
      customer_name text,
      paid boolean,
      payment_method text,
      original_price numeric,
      discount_reason text
    )
  loop
    if rec.uses_oil and rec.oil_type is not null and rec.oil_size is not null then
      update oil_inventory set stock = greatest(stock - 1, 0)
       where outlet_id = rec.outlet_id and oil_type = rec.oil_type and size = rec.oil_size;
    end if;

    v_commission := round(rec.commission_percent / 100.0 * rec.treatment_price);
    v_end := v_start + coalesce(rec.duration_minutes, 0) * 60000;
    v_discount_pct := case
      when rec.original_price is not null and rec.original_price > rec.treatment_price
        then round(100 - (rec.treatment_price::numeric * 100 / rec.original_price), 1)
      else 0
    end;
    if v_discount_pct > 0 and coalesce(rec.discount_reason, '') = '' then
      raise exception 'Alasan diskon wajib diisi';
    end if;

    insert into bookings (
      outlet_id, therapist_id, therapist_name, treatment_id, treatment_name,
      treatment_price, commission_percent, commission_amount, duration_minutes,
      uses_oil, oil_type, oil_size, customer_name, status, paid, payment_method,
      group_id, start_at, end_at, created_at, original_price, created_by,
      discount_pct, discount_reason
    ) values (
      rec.outlet_id, rec.therapist_id, rec.therapist_name, rec.treatment_id, rec.treatment_name,
      rec.treatment_price, rec.commission_percent, v_commission, coalesce(rec.duration_minutes,0),
      coalesce(rec.uses_oil, true), rec.oil_type, rec.oil_size, coalesce(rec.customer_name,''),
      'berjalan', coalesce(rec.paid, false), coalesce(rec.payment_method,'cash'),
      p_group_id, v_start, v_end, now(), rec.original_price, v_uid,
      v_discount_pct, case when v_discount_pct > 0 then rec.discount_reason else null end
    ) returning id into v_booking_id;

    v_ids := v_ids || v_booking_id;
    return query select v_booking_id;
  end loop;

  update therapists t set
    status = 'ambil_tamu',
    current_outlet_id = agg.outlet_id,
    current_booking_ids = agg.ids,
    current_booking_id = agg.ids->>0,
    current_treatment_names = agg.names,
    current_treatment_name = agg.name_str,
    current_paid = agg.all_paid,
    current_payment_method = agg.method,
    current_price = agg.total_price,
    current_group_id = p_group_id,
    start_at = v_start,
    end_at = v_start + agg.total_duration * 60000
  from (
    select
      therapist_id,
      outlet_id,
      jsonb_agg(id::text order by id::text) as ids,
      jsonb_agg(treatment_name order by id::text) as names,
      string_agg(treatment_name, ', ' order by id::text) as name_str,
      bool_and(paid) as all_paid,
      (array_agg(payment_method order by id::text))[array_length(array_agg(payment_method order by id::text),1)] as method,
      sum(coalesce(treatment_price,0)) as total_price,
      sum(coalesce(duration_minutes,0)) as total_duration
    from bookings
    where id = any(v_ids)
    group by therapist_id, outlet_id
  ) agg
  where t.id = agg.therapist_id;

  -- Audit untuk tiap booking yang dibuat
  for rec in select id, outlet_id from bookings where id = any(v_ids) loop
    perform log_audit('create', rec.id, rec.outlet_id);
  end loop;

  return;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_oncall_booking(p_outlet_id text, p_therapist_id uuid, p_package_name text, p_duration_minutes integer, p_treatment_price numeric, p_customer_name text, p_payment_method text, p_commission_percent numeric, p_hotel_commission numeric)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_booking_id uuid;
  v_commission numeric;
  v_therapist_name text;
  v_start_at bigint;
  v_end_at bigint;
begin
  select name into v_therapist_name from therapists where id = p_therapist_id;
  if v_therapist_name is null then
    raise exception 'Terapis tidak ditemukan';
  end if;

  if exists (select 1 from therapists where id = p_therapist_id and status = 'ambil_tamu') then
    raise exception 'Terapis sedang sibuk (Ambil Tamu), tidak bisa dijadwalkan oncall';
  end if;

  select round(p_commission_percent/100.0 * (p_treatment_price - coalesce(p_hotel_commission, 0))) into v_commission;
  v_start_at := (extract(epoch from now())::bigint * 1000);
  v_end_at := v_start_at + (p_duration_minutes * 60000);

  insert into bookings (
    outlet_id, therapist_id, therapist_name, treatment_id, treatment_name,
    treatment_price, commission_percent, commission_amount, duration_minutes,
    uses_oil, customer_name, status, paid, payment_method,
    start_at, end_at, created_at, original_price,
    booking_source, hotel_commission
  ) values (
    p_outlet_id, p_therapist_id, v_therapist_name, null,
    p_package_name, p_treatment_price, p_commission_percent, v_commission, p_duration_minutes,
    false, p_customer_name, 'selesai', true, p_payment_method,
    v_start_at, v_end_at, now(), p_treatment_price,
    'oncall', p_hotel_commission
  ) returning id into v_booking_id;

  -- JADWAL oncall disimpan, tapi status TIDAK diubah ke ambil_tamu.
  -- Block/pemblokiran dilakukan otomatis 20 menit sebelum jam mulai
  -- oleh auto_free_expired_therapists.
  update therapists set
    current_outlet_id = p_outlet_id,
    current_booking_ids = coalesce(current_booking_ids, '[]'::jsonb) || jsonb_build_array(v_booking_id::text),
    current_treatment_names = coalesce(current_treatment_names, '[]'::jsonb) || jsonb_build_array(p_package_name),
    current_treatment_name = p_package_name,
    current_booking_id = v_booking_id::text,
    current_paid = true,
    current_payment_method = p_payment_method,
    current_price = p_treatment_price,
    current_group_id = 'oncall:' || v_booking_id::text,
    start_at = v_start_at,
    end_at = v_end_at
  where id = p_therapist_id;

  return v_booking_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_oncall_booking_multi(p_outlet_id text, p_customer_name text, p_payment_method text, p_package_name text, p_duration_minutes integer, p_treatment_price numeric, p_commission_percent numeric, p_hotel_commission numeric, p_entries jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_e jsonb;
  v_tid uuid;
  v_tname text;
  v_start_hour int;
  v_start_minute int;
  v_start_ts timestamptz;
  v_end_ts timestamptz;
  v_wib date;
  v_commission numeric;
  v_booking_id uuid;
  v_count int := 0;
begin
  if jsonb_typeof(p_entries) <> 'array' or jsonb_array_length(p_entries) = 0 then
    raise exception 'Minimal satu terapis harus dipilih dengan waktu mulai';
  end if;

  select round(p_commission_percent/100.0 * (p_treatment_price - coalesce(p_hotel_commission, 0))) into v_commission;
  v_wib := (now() at time zone 'utc' + interval '7 hours')::date;

  for v_e in select value from jsonb_array_elements(p_entries) loop
    v_tid := (v_e->>'therapist_id')::uuid;
    v_start_hour := (v_e->>'start_hour')::int;
    v_start_minute := (v_e->>'start_minute')::int;

    select name into v_tname from therapists where id = v_tid;
    if v_tname is null then
      raise exception 'Terapis tidak ditemukan';
    end if;

    if exists (select 1 from therapists where id = v_tid and status = 'ambil_tamu') then
      raise exception 'Terapis % sedang sibuk (Ambil Tamu), tidak bisa dijadwalkan oncall', v_tname;
    end if;

    if v_start_hour is null or v_start_minute is null then
      raise exception 'Waktu mulai belum diatur untuk terapis %', v_tname;
    end if;

    v_start_ts := (v_wib + make_interval(hours => v_start_hour, mins => v_start_minute))
                  at time zone 'Asia/Makassar';

    if v_start_ts < now() - interval '5 minutes' then
      raise exception 'Waktu mulai untuk % sudah lewat/terlalu dekat. Pilih jam di masa depan.', v_tname;
    end if;

    v_end_ts := v_start_ts + make_interval(mins => p_duration_minutes);

    insert into bookings (
      outlet_id, therapist_id, therapist_name, treatment_id, treatment_name,
      treatment_price, commission_percent, commission_amount, duration_minutes,
      uses_oil, customer_name, status, paid, payment_method,
      start_at, end_at, created_at, original_price,
      booking_source, hotel_commission
    ) values (
      p_outlet_id, v_tid, v_tname, null,
      p_package_name, p_treatment_price, p_commission_percent, v_commission, p_duration_minutes,
      false, p_customer_name, 'selesai', true, p_payment_method,
      (extract(epoch from v_start_ts)::bigint * 1000),
      (extract(epoch from v_end_ts)::bigint * 1000),
      now(), p_treatment_price,
      'oncall', p_hotel_commission
    ) returning id into v_booking_id;

    -- JADWAL oncall disimpan, tapi status TIDAK diubah ke ambil_tamu.
    -- Block/pemblokiran dilakukan otomatis 20 menit sebelum jam mulai
    -- oleh auto_free_expired_therapists.
    update therapists set
      current_outlet_id = p_outlet_id,
      current_group_id = 'oncall:' || v_booking_id::text,
      current_booking_id = v_booking_id::text,
      current_booking_ids = coalesce(current_booking_ids, '[]'::jsonb) || jsonb_build_array(v_booking_id::text),
      current_treatment_names = coalesce(current_treatment_names, '[]'::jsonb) || jsonb_build_array(p_package_name),
      current_treatment_name = p_package_name,
      current_paid = true,
      current_payment_method = p_payment_method,
      current_price = p_treatment_price,
      start_at = (extract(epoch from v_start_ts)::bigint * 1000),
      end_at = (extract(epoch from v_end_ts)::bigint * 1000)
    where id = v_tid;

    v_count := v_count + 1;
  end loop;

  if v_count = 0 then
    raise exception 'Tidak ada terapis yang berhasil dijadwalkan';
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_inventory_item(p_outlet_id text, p_item_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  delete from inventory_logs where outlet_id = p_outlet_id and item_id = p_item_id;
  delete from inventory where id = p_item_id and outlet_id = p_outlet_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_booking_correction(p_booking_id uuid, p_treatment_id uuid DEFAULT NULL::uuid, p_treatment_name text DEFAULT NULL::text, p_treatment_price numeric DEFAULT NULL::numeric, p_commission_percent numeric DEFAULT NULL::numeric, p_new_therapist_id uuid DEFAULT NULL::uuid, p_uses_oil boolean DEFAULT NULL::boolean, p_oil_type text DEFAULT NULL::text, p_oil_size text DEFAULT NULL::text, p_discount_pct numeric DEFAULT NULL::numeric, p_discount_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_outlet text;
  v_old_therapist uuid;
  v_orig_uses_oil boolean;
  v_old_oil_type text;
  v_old_oil_size text;
  v_old_oil text;
  v_new_oil text;
  v_new_price numeric;
  v_new_commission numeric;
  v_base numeric;
  v_old_original numeric;
  v_status text;
begin
  -- ---- KEAMANAN: wajib office ---- 
  if not is_office_op() then
    raise exception 'Anda tidak berhak melakukan koreksi booking.';
  end if;

  -- ---- Ambil data lama ----
  select outlet_id, therapist_id, uses_oil, oil_type, oil_size,
         treatment_price, commission_percent, status, original_price
    into v_outlet, v_old_therapist, v_orig_uses_oil, v_old_oil_type, v_old_oil_size,
         v_new_price, v_new_commission, v_status, v_old_original
    from bookings where id = p_booking_id;

  if not found then raise exception 'Booking tidak ditemukan'; end if;

  if v_status in ('batal', 'batal_sebagian') then
    raise exception 'Booking sudah dibatalkan dan tidak bisa dikoreksi.';
  end if;

  -- ---- Tentukan nilai baru (fallback ke lama) ----
  v_new_price := coalesce(p_treatment_price, v_new_price);
  v_new_commission := coalesce(p_commission_percent, v_new_commission);

  -- ---- Terapkan diskon baru (bila dikirim) ----
  -- Basis diskon = harga yang dikoreksi (p_treatment_price), atau original_price
  -- yang sudah tersimpan, atau harga saat ini.
  if p_discount_pct is not null then
    if p_discount_pct < 0 or p_discount_pct > 100 then
      raise exception 'Diskon harus antara 0 dan 100%%.';
    end if;
    if p_discount_pct > 0 and coalesce(p_discount_reason, '') = '' then
      raise exception 'Alasan diskon wajib diisi.';
    end if;
    v_base := coalesce(p_treatment_price, v_old_original, v_new_price);
    if p_discount_pct > 0 then
      v_new_price := round(v_base * (1 - p_discount_pct / 100.0));
    else
      v_new_price := v_base;
    end if;
  end if;

  -- Stok: bandingkan minyak LAMA (asal dari DB) vs minyak BARU (hasil koreksi)
  v_old_oil := case when v_orig_uses_oil then (coalesce(v_old_oil_type,'')||'_'||coalesce(v_old_oil_size,'')) end;
  v_new_oil := case when coalesce(p_uses_oil, v_orig_uses_oil) then (coalesce(p_oil_type,'')||'_'||coalesce(p_oil_size,'')) end;

  if v_old_oil is distinct from v_new_oil then
    if v_orig_uses_oil and v_old_oil_type is not null and v_old_oil_size is not null then
      update oil_inventory set stock = stock + 1
       where outlet_id = v_outlet and oil_type = v_old_oil_type and size = v_old_oil_size;
    end if;
    if coalesce(p_uses_oil, v_orig_uses_oil) and p_oil_type is not null and p_oil_size is not null then
      if (select stock from oil_inventory
           where outlet_id = v_outlet and oil_type = p_oil_type and size = p_oil_size) <= 0 then
        raise exception 'Stok minyak habis';
      end if;
      update oil_inventory set stock = stock - 1
       where outlet_id = v_outlet and oil_type = p_oil_type and size = p_oil_size;
    end if;
  end if;

  -- ---- Update booking ----
  update bookings set
    treatment_id = coalesce(p_treatment_id, treatment_id),
    treatment_name = coalesce(p_treatment_name, treatment_name),
    treatment_price = v_new_price,
    commission_percent = v_new_commission,
    commission_amount = round(v_new_commission / 100.0 * v_new_price),
    uses_oil = coalesce(p_uses_oil, uses_oil),
    oil_type = case when coalesce(p_uses_oil, uses_oil) then coalesce(p_oil_type, oil_type) else null end,
    oil_size = case when coalesce(p_uses_oil, uses_oil) then coalesce(p_oil_size, oil_size) else null end,
    therapist_id = coalesce(p_new_therapist_id, therapist_id),
    therapist_name = case
      when p_new_therapist_id is not null
        then (select name from therapists where id = p_new_therapist_id)
      else therapist_name
    end,
    original_price = case
      when p_discount_pct is not null and p_discount_pct > 0 then v_base
      when p_discount_pct is not null and p_discount_pct = 0 then null
      else original_price
    end,
    discount_pct = case
      when p_discount_pct is not null then p_discount_pct
      else discount_pct
    end,
    discount_reason = case
      when p_discount_pct is not null and p_discount_pct > 0 then p_discount_reason
      when p_discount_pct is not null and p_discount_pct = 0 then null
      else discount_reason
    end
  where id = p_booking_id;

  -- ---- Perbarui session terapis bila terapis diganti / aktif ----
  if p_new_therapist_id is not null and p_new_therapist_id <> v_old_therapist then
    perform refresh_therapist_session(v_old_therapist);
    perform refresh_therapist_session(p_new_therapist_id);
  elsif v_status = 'berjalan' then
    perform refresh_therapist_session(v_old_therapist);
  end if;

  -- ---- Audit ----
  perform log_audit('edit', p_booking_id, v_outlet,
    jsonb_build_object(
      'treatment_id', p_treatment_id,
      'treatment_name', p_treatment_name,
      'treatment_price', p_treatment_price,
      'commission_percent', p_commission_percent,
      'therapist_id', p_new_therapist_id,
      'uses_oil', p_uses_oil,
      'oil_type', p_oil_type,
      'oil_size', p_oil_size,
      'discount_pct', p_discount_pct,
      'discount_reason', p_discount_reason
    ));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_booking_correction(p_booking_id uuid, p_treatment_id uuid DEFAULT NULL::uuid, p_treatment_name text DEFAULT NULL::text, p_treatment_price numeric DEFAULT NULL::numeric, p_commission_percent numeric DEFAULT NULL::numeric, p_new_therapist_id uuid DEFAULT NULL::uuid, p_uses_oil boolean DEFAULT NULL::boolean, p_oil_type text DEFAULT NULL::text, p_oil_size text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_outlet text;
  v_old_therapist uuid;
  v_orig_uses_oil boolean;
  v_old_oil_type text;
  v_old_oil_size text;
  v_old_oil text;
  v_new_oil text;
  v_new_price numeric;
  v_new_commission numeric;
  v_status text;
begin
  -- ---- KEAMANAN: wajib office ---- 
  if not is_office_op() then
    raise exception 'Anda tidak berhak melakukan koreksi booking.';
  end if;

  -- ---- Ambil data lama ----
  select outlet_id, therapist_id, uses_oil, oil_type, oil_size,
         treatment_price, commission_percent, status
    into v_outlet, v_old_therapist, v_orig_uses_oil, v_old_oil_type, v_old_oil_size,
         v_new_price, v_new_commission, v_status
    from bookings where id = p_booking_id;

  if not found then raise exception 'Booking tidak ditemukan'; end if;

  if v_status in ('batal', 'batal_sebagian') then
    raise exception 'Booking sudah dibatalkan dan tidak bisa dikoreksi.';
  end if;

  -- ---- Tentukan nilai baru (fallback ke lama) ----
  v_new_price := coalesce(p_treatment_price, v_new_price);
  v_new_commission := coalesce(p_commission_percent, v_new_commission);

  -- Stok: bandingkan minyak LAMA (asal dari DB) vs minyak BARU (hasil koreksi)
  v_old_oil := case when v_orig_uses_oil then (coalesce(v_old_oil_type,'')||'_'||coalesce(v_old_oil_size,'')) end;
  v_new_oil := case when coalesce(p_uses_oil, v_orig_uses_oil) then (coalesce(p_oil_type,'')||'_'||coalesce(p_oil_size,'')) end;

  if v_old_oil is distinct from v_new_oil then
    if v_orig_uses_oil and v_old_oil_type is not null and v_old_oil_size is not null then
      update oil_inventory set stock = stock + 1
       where outlet_id = v_outlet and oil_type = v_old_oil_type and size = v_old_oil_size;
    end if;
    if coalesce(p_uses_oil, v_orig_uses_oil) and p_oil_type is not null and p_oil_size is not null then
      if (select stock from oil_inventory
           where outlet_id = v_outlet and oil_type = p_oil_type and size = p_oil_size) <= 0 then
        raise exception 'Stok minyak habis';
      end if;
      update oil_inventory set stock = stock - 1
       where outlet_id = v_outlet and oil_type = p_oil_type and size = p_oil_size;
    end if;
  end if;

  -- ---- Update booking ----
  update bookings set
    treatment_id = coalesce(p_treatment_id, treatment_id),
    treatment_name = coalesce(p_treatment_name, treatment_name),
    treatment_price = v_new_price,
    commission_percent = v_new_commission,
    commission_amount = round(v_new_commission / 100.0 * v_new_price),
    uses_oil = coalesce(p_uses_oil, uses_oil),
    oil_type = case when coalesce(p_uses_oil, uses_oil) then coalesce(p_oil_type, oil_type) else null end,
    oil_size = case when coalesce(p_uses_oil, uses_oil) then coalesce(p_oil_size, oil_size) else null end,
    therapist_id = coalesce(p_new_therapist_id, therapist_id),
    therapist_name = case
      when p_new_therapist_id is not null
        then (select name from therapists where id = p_new_therapist_id)
      else therapist_name
    end
  where id = p_booking_id;

  -- ---- Perbarui session terapis bila terapis diganti / aktif ----
  if p_new_therapist_id is not null and p_new_therapist_id <> v_old_therapist then
    perform refresh_therapist_session(v_old_therapist);
    perform refresh_therapist_session(p_new_therapist_id);
  elsif v_status = 'berjalan' then
    perform refresh_therapist_session(v_old_therapist);
  end if;

  -- ---- Audit ----
  perform log_audit('edit', p_booking_id, v_outlet,
    jsonb_build_object(
      'treatment_id', p_treatment_id,
      'treatment_name', p_treatment_name,
      'treatment_price', p_treatment_price,
      'commission_percent', p_commission_percent,
      'therapist_id', p_new_therapist_id,
      'uses_oil', p_uses_oil,
      'oil_type', p_oil_type,
      'oil_size', p_oil_size
    ));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_booking_details(p_outlet_id text, p_booking_id uuid, p_treatment_id uuid, p_treatment_name text, p_treatment_price numeric, p_commission_percent numeric, p_duration_minutes integer, p_uses_oil boolean, p_oil_type text, p_oil_size text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_old_uses_oil boolean;
  v_old_oil_type text;
  v_old_oil_size text;
  v_old_oil text;
  v_new_oil text;
  v_old_price numeric;
begin
  select uses_oil, oil_type, oil_size, treatment_price
    into v_old_uses_oil, v_old_oil_type, v_old_oil_size, v_old_price
    from bookings where id = p_booking_id and outlet_id = p_outlet_id;
  if not found then raise exception 'Booking tidak ditemukan'; end if;

  v_old_oil  := case when v_old_uses_oil then (coalesce(v_old_oil_type,'')||'_'||coalesce(v_old_oil_size,'')) end;
  v_new_oil  := case when p_uses_oil     then (coalesce(p_oil_type,'')||'_'||coalesce(p_oil_size,'')) end;

  if v_old_oil is distinct from v_new_oil then
    if v_old_uses_oil and v_old_oil_type is not null and v_old_oil_size is not null then
      update oil_inventory set stock = stock + 1
       where outlet_id = p_outlet_id and oil_type = v_old_oil_type and size = v_old_oil_size;
    end if;
    if p_uses_oil and p_oil_type is not null and p_oil_size is not null then
      if (select stock from oil_inventory
           where outlet_id = p_outlet_id and oil_type = p_oil_type and size = p_oil_size) <= 0 then
        raise exception 'Stok minyak habis';
      end if;
      update oil_inventory set stock = stock - 1
       where outlet_id = p_outlet_id and oil_type = p_oil_type and size = p_oil_size;
    end if;
  end if;

  update bookings set
    treatment_id = p_treatment_id,
    treatment_name = p_treatment_name,
    treatment_price = p_treatment_price,
    commission_percent = p_commission_percent,
    commission_amount = round(p_commission_percent / 100.0 * p_treatment_price),
    duration_minutes = p_duration_minutes,
    uses_oil = p_uses_oil,
    oil_type = case when p_uses_oil then p_oil_type else null end,
    oil_size = case when p_uses_oil then p_oil_size else null end
  where id = p_booking_id and outlet_id = p_outlet_id;

  perform log_audit('edit', p_booking_id, p_outlet_id,
    jsonb_build_object('old_price', v_old_price, 'new_price', p_treatment_price));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.edit_oncall_booking(p_booking_id uuid, p_therapist_id uuid, p_therapist_name text, p_package_name text, p_duration_minutes integer, p_price numeric, p_commission_percent numeric, p_hotel_commission numeric, p_customer_name text, p_payment_method text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (
    select 1 from bookings
    where id = p_booking_id and booking_source = 'oncall'
  ) then
    raise exception 'Booking oncall tidak ditemukan';
  end if;

  update bookings
     set therapist_id = p_therapist_id,
         therapist_name = coalesce(p_therapist_name, therapist_name),
         treatment_name = coalesce(p_package_name, treatment_name),
         duration_minutes = coalesce(p_duration_minutes, duration_minutes),
         treatment_price = p_price,
         original_price = null,
         commission_percent = p_commission_percent,
         commission_amount = round(p_commission_percent / 100.0 * (p_price - coalesce(p_hotel_commission, 0))),
         hotel_commission = p_hotel_commission,
         customer_name = coalesce(p_customer_name, ''),
         payment_method = p_payment_method
   where id = p_booking_id and booking_source = 'oncall';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hapus_booking_office(p_booking_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_outlet text;
  v_therapist uuid;
  v_uses_oil boolean;
  v_oil_type text;
  v_oil_size text;
  v_status text;
begin
  -- ---- KEAMANAN: wajib office ----
  if not is_office_op() then
    raise exception 'Anda tidak berhak menghapus booking.';
  end if;

  select outlet_id, therapist_id, uses_oil, oil_type, oil_size, status
    into v_outlet, v_therapist, v_uses_oil, v_oil_type, v_oil_size, v_status
    from bookings where id = p_booking_id;

  if not found then raise exception 'Booking tidak ditemukan'; end if;

  if v_status in ('batal', 'batal_sebagian') then
    raise exception 'Booking sudah batal.';
  end if;

  -- Kembalikan stok minyak (kalau pakai)
  if v_uses_oil and v_oil_type is not null and v_oil_size is not null then
    update oil_inventory set stock = stock + 1
     where outlet_id = v_outlet and oil_type = v_oil_type and size = v_oil_size;
  end if;

  -- Tandai batal (data tetap ada di DB)
  update bookings set status = 'batal', cancelled_at = now(), completed_at = null
   where id = p_booking_id;

  -- Bila sedang berjalan: perbarui session terapis (bersihkan bila tak ada
  -- treatment berjalan lain, atau pakai sisa treatment yang masih berjalan)
  if v_status = 'berjalan' and v_therapist is not null then
    perform refresh_therapist_session(v_therapist);
  end if;

  -- Audit
  perform log_audit('cancel', p_booking_id, v_outlet,
    jsonb_build_object('action', 'office_hapus_treatment'));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.is_office_op()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
  select lower(coalesce(
    (auth.jwt() ->> 'email'),
    (select u.email from auth.users u where u.id = auth.uid()),
    ''
  )) = 'office.op@dayang.com'
$function$
;

CREATE OR REPLACE FUNCTION public.koreksi_pembayaran(p_booking_id uuid, p_paid boolean, p_payment_method text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update bookings
     set paid = p_paid,
         payment_method = case when p_paid then coalesce(p_payment_method, payment_method) else null end
   where id = p_booking_id;

  if not found then
    raise exception 'Booking tidak ditemukan';
  end if;

  -- Jaga agar kartu Status Terapis ikut sinkron kalau terapisnya sedang ambil tamu.
  update therapists
     set current_paid = p_paid,
         current_payment_method = case when p_paid then coalesce(p_payment_method, current_payment_method) else null end
   where current_booking_ids is not null
     and current_booking_ids @> jsonb_build_array(p_booking_id::text);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.log_audit(p_action text, p_record_id uuid, p_outlet_id text DEFAULT NULL::text, p_detail jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_uid uuid := auth.uid();
  v_name text;
begin
  select name into v_name from users where id = v_uid;
  insert into audit_logs (actor, actor_name, action, table_name, record_id, outlet_id, detail)
  values (v_uid, coalesce(v_name, 'system'), p_action, 'bookings', p_record_id, p_outlet_id, p_detail);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.log_office_login()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_email text;
  v_name text;
begin
  select email into v_email from auth.users where id = auth.uid();

  -- Hanya dicatat bila yang login memang akun office
  if lower(coalesce(v_email, '')) <> 'office.op@dayang.com' then
    return;
  end if;

  select name into v_name from users where id = auth.uid();

  insert into audit_logs (actor, actor_name, action, table_name, record_id, outlet_id, detail)
  values (auth.uid(), coalesce(v_name, 'office'), 'login', 'session', null, null, '{}'::jsonb);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_booking_paid(p_outlet_id text, p_booking_id uuid, p_therapist_id uuid, p_payment_method text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
begin
  update bookings
     set paid = true,
         payment_method = coalesce(p_payment_method, payment_method)
   where id = p_booking_id and outlet_id = p_outlet_id;

  if p_therapist_id is not null then
    update therapists
       set current_paid = true,
           current_payment_method = coalesce(p_payment_method, current_payment_method)
     where id = p_therapist_id
       and exists (
         select 1 from bookings b
         where b.id = p_booking_id and b.outlet_id = p_outlet_id
           and b.therapist_id = p_therapist_id
       );
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_booking_paid(p_outlet_id text, p_booking_id uuid, p_therapist_id uuid, p_payment_method text, p_discount_pct numeric DEFAULT NULL::numeric, p_discount_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_current_price numeric;
  v_new_price numeric;
  v_uid uuid := auth.uid();
begin
  select treatment_price, coalesce(original_price, treatment_price)
    into v_current_price, v_new_price
    from bookings where id = p_booking_id and outlet_id = p_outlet_id;

  if not found then raise exception 'Booking tidak ditemukan'; end if;

  if p_discount_pct is not null and p_discount_pct > 0 then
    if coalesce(p_discount_reason, '') = '' then
      raise exception 'Alasan diskon wajib diisi';
    end if;
    v_new_price := round(v_current_price * (1 - p_discount_pct / 100.0));
  end if;

  update bookings
     set paid = true,
         payment_method = coalesce(p_payment_method, payment_method),
         paid_by = v_uid,
         original_price = case
            when p_discount_pct is not null and p_discount_pct > 0 then coalesce(original_price, v_current_price)
            else original_price
         end,
         treatment_price = case
            when p_discount_pct is not null and p_discount_pct > 0 then v_new_price
            else treatment_price
         end,
         discount_pct = coalesce(p_discount_pct, 0),
         discount_reason = coalesce(p_discount_reason, discount_reason),
         commission_amount = case
            when p_discount_pct is not null and p_discount_pct > 0 then round(commission_percent / 100.0 * v_new_price)
            else commission_amount
         end
   where id = p_booking_id and outlet_id = p_outlet_id;

  if p_therapist_id is not null then
    update therapists
       set current_paid = true,
           current_payment_method = coalesce(p_payment_method, current_payment_method),
           current_price = (
             select coalesce(sum(coalesce(treatment_price,0)),0)
               from bookings
              where therapist_id = p_therapist_id
                and outlet_id = p_outlet_id
                and status = 'berjalan'
           )
     where id = p_therapist_id
       and exists (
         select 1 from bookings b
         where b.id = p_booking_id and b.outlet_id = p_outlet_id
           and b.therapist_id = p_therapist_id
       );
  end if;

  perform log_audit('pay', p_booking_id, p_outlet_id,
    jsonb_build_object('method', p_payment_method, 'discount_pct', p_discount_pct,
      'reason', p_discount_reason, 'new_price', case when p_discount_pct is not null and p_discount_pct > 0 then v_new_price end));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.refresh_therapist_session(p_therapist_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_count int;
  v_total_price numeric;
  v_total_duration int;
  v_outlet text;
  v_ids jsonb;
  v_names jsonb;
  v_all_paid boolean;
  v_method text;
  v_start bigint;
  v_end bigint;
begin
  select
    count(*),
    coalesce(sum(coalesce(treatment_price,0)),0),
    coalesce(sum(coalesce(duration_minutes,0)),0),
    min(outlet_id),
    jsonb_agg(id::text order by start_at),
    jsonb_agg(treatment_name order by start_at),
    bool_and(coalesce(paid,false)),
    (array_agg(payment_method order by start_at))[1],
    min(start_at),
    max(end_at)
  into v_count, v_total_price, v_total_duration, v_outlet,
       v_ids, v_names, v_all_paid, v_method, v_start, v_end
  from bookings
  where therapist_id = p_therapist_id and status = 'berjalan';

  if v_count is null or v_count = 0 then
    update therapists set
      status = 'free', current_outlet_id = null,
      current_booking_ids = null, current_booking_id = null,
      current_treatment_names = null, current_treatment_name = null,
      current_paid = null, current_payment_method = null,
      current_price = null, current_group_id = null,
      start_at = null, end_at = null
    where id = p_therapist_id;
  else
    update therapists set
      status = 'ambil_tamu',
      current_outlet_id = v_outlet,
      current_booking_ids = v_ids,
      current_booking_id = v_ids->>0,
      current_treatment_names = v_names,
      current_treatment_name = v_names->>0,
      current_paid = v_all_paid,
      current_payment_method = v_method,
      current_price = v_total_price,
      start_at = v_start,
      end_at = v_end
    where id = p_therapist_id;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.stock_in_out(p_outlet_id text, p_item_id uuid, p_qty integer, p_note text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
  v_current int;
begin
  select stock into v_current from inventory
   where id = p_item_id and outlet_id = p_outlet_id for update;

  if not found then raise exception 'Item tidak ditemukan'; end if;

  insert into inventory_logs (outlet_id, item_id, type, qty, note, created_at)
  values (p_outlet_id, p_item_id, case when p_qty >= 0 then 'in' else 'out' end, abs(p_qty), coalesce(p_note,''), now());

  if p_qty < 0 then
    update inventory set stock = v_current + p_qty  -- p_qty negatif -> kurangi
     where id = p_item_id and outlet_id = p_outlet_id;
    if v_current + p_qty < 0 then raise exception 'Stok tidak cukup'; end if;
  else
    update inventory set stock = v_current + p_qty
     where id = p_item_id and outlet_id = p_outlet_id;
  end if;
end;
$function$
;
