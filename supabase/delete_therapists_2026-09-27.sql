-- ============================================================
-- HAPUS TERAPIS DI LUAR LIST 27-09-2026 (audit trail)
-- 28 terapis aktif pada roster hari ini; 4 OFF (Nur/Doni/
-- Putri/Novita) dipertahankan sebagai 'libur'.
-- Yang dihapus = terapis yang TIDAK ada di roster dan BUKAN
-- grup OFF. Riwayat transaksi lama diputuskan therapist_id-nya
-- (nama tetap tersimpan di bookings.therapist_name),
-- sehingga laporan/komisi masa lalu tidak berubah.
-- Salinan baris terapis tersimpan di backup lokal
-- (deleted_therapists_2026-09-27.csv).
-- ============================================================

do $$
declare
  v_roster text[] := array[
    'ali','destia','indah','hanum','jefri','riska','ron',
    'ripan','ijal','tumin','ayuha','aulia','aisyah','sahni',
    'bayu','titik','nas','ega','uswa','sumi','azi',
    'ily','riri','rizal','panji','pian','ayy','reno'];
  v_off text[] := array['nur','doni','putri','novita'];
  v_del int;
begin
  create temp table _del as
    select id from therapists
     where lower(name) not in (select unnest(v_roster))
       and lower(name) not in (select unnest(v_off));

  update bookings set therapist_id = null
   where therapist_id in (select id from _del);

  delete from therapists where id in (select id from _del);
  get diagnostics v_del = row_count;
  raise notice 'Terapis dihapus: %', v_del;
end $$;