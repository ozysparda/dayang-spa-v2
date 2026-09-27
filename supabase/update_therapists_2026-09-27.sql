-- ============================================================
-- UPDATE JADWAL & OUTLET TERAPIS per LIST 27-09-2026
-- Mengupdate kolom shift + home_outlet_id sesuai list.
-- Status:
--   * terapis yang TERDAFTAR hari ini -> dibuka jadi 'free'
--     (kecuali sedang ambil_tamu agar sesi berjalan tidak rusak)
--   * terapis OFF (Nur, Doni, Putri, Novita) -> 'libur'
-- Nama dicocokkan case-insensitive; yang tak ditemukan dilaporkan.
-- ============================================================

do $$
declare
  r record;
  v_count int := 0;
begin
  for r in (
    select * from (values
      -- Dream (DR)
      ('Ali','DR','sp1'), ('Destia','DR','sp2'), ('Indah','DR','sp2'),
      ('HANUM','DR','sp1'), ('Jefri','DR','st'), ('Riska','DR','st'), ('Ron','DR','sp2'),
      -- Rere (RR)
      ('rifan','RR','15'), ('Ijal','RR','sp2'), ('tumin','RR','sp2'),
      ('ayuhaa','RR','15'), ('aulia','RR','11'), ('aisyah','RR','sp1'), ('sahni','RR','st'),
      -- Dayang Putri (DP)
      ('Bayu','DP','sp2'), ('Titik','DP','sp1'), ('Nas','DP','sp2'),
      ('Ega','DP','sp1'), ('Uswa','DP','sp1'), ('Sumi','DP','15'),
      -- Dayang 1 (D1)
      ('Ily','D1','15'), ('Riri','D1','sp1'), ('Rizal','D1','11'),
      -- Dayang 2 (D2)
      ('Panji','D2','sp2'), ('Pian','D2','sp1'),
      -- Yulis (Y)
      ('Ayy','Y','sp2'), ('Reno','Y','st')
    ) v(nama, outlet, shift)
  ) loop
    update therapists
       set home_outlet_id = r.outlet,
           shift = r.shift,
           status = case when status = 'ambil_tamu' then status else 'free' end
     where lower(name) = lower(r.nama);
    if found then
      v_count := v_count + 1;
    else
      raise notice 'TIDAK DITEMUKAN: %', r.nama;
    end if;
  end loop;

  for r in (select * from (values ('Nur'),('Doni'),('Putri'),('Novita')) v(nama)) loop
    update therapists set status = 'libur' where lower(name) = lower(r.nama);
    if found then
      v_count := v_count + 1;
    else
      raise notice 'OFF TIDAK DITEMUKAN: %', r.nama;
    end if;
  end loop;

  raise notice 'TOTAL UPDATE: % baris', v_count;
end $$;