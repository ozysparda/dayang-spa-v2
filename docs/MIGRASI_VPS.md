# Skema Migrasi Dayang Spa — Supabase Cloud → Self-host VPS

Tujuan: lepas dari Supabase cloud (lewat kuota egress & log), semua data & fungsionalitas
tetap sama di server sendiri. Aplikasi (React PWA) **tidak perlu ditulis ulang** —
self-host Supabase memakai SDK/fitur yang sama. Yang berubah hanya URL + anon key.

---

## 1. Ringkasan & Biaya

| Item | Estimasi |
|---|---|
| VPS (2 vCPU / 4 GB RAM, disk 40 GB) | ± 5–8 USD/bulan (Hetzner CX22/CPX21 di singapore) |
| Domain + HTTPS | ± 8 USD/tahun (domain murah) + Caddy (gratis) |
| Waktu pengerjaan | 1 hari (target selesai sebelum 28 Sep) |
| Downtime aplikasi | Hanya saat cutover (1–2 jam, pilih jam sepi) |
| Password kasir | Tetap sama (auth.users ikut dimigrasi) |

> Kenapa 4 GB RAM? Stack Supabase self-host: Postgres + Kong + Auth(GoTrue) + Realtime +
> Storage + Studio berjalan via Docker (banyak container). 4 GB adalah minimum yang wajar
> agar tidak kena oom-kill. Tambah swap 4 GB untuk amannya.

---

## 2. Persiapan (H-1)

1. **Backup final dari Supabase cloud** (sebelum cutover selalu buat snapshot baru).
   - Schema + data `auth`+`public` + 27 fungsi (tools kita sudah siap; backup CSV diformat
     tab/generik agar mudah di-import balik).
2. **Siapkan akun VPS & domain**.
   - Provider: Hetzner / DigitalOcean / Vultr — region **Singapura** (latensi rendah ke ID).
   - Domain contoh: `db.dayangspa.id` (subdomain untuk Supabase) — DNS diarahkan ke IP VPS.
3. **Masukkan IP VPS ke allowlist DB cloud** (Settings → Database → Connection pooling)
   agar VPS bisa menjalankan `pg_dump` terhadap database cloud.

---

## 3. Setup Server (Hari H, langkah A)

SSH ke VPS (Ubuntu 22.04/24.04), lalu:

```bash
# 1) Update & user non-root
apt update && apt upgrade -y
adduser dayang && usermod -aG sudo dayang

# 2) Firewall (buka 22, 80, 443, 54321/54322 bila perlu)
ufw allow OpenSSH && ufw allow 80 && ufw allow 443 && ufw enable

# 3) Docker + Compose
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# 4) Swap 4GB (cadangan RAM)
fallocate -l 4G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

## 4. Pasang Supabase Self-host

```bash
git clone --depth 1 https://github.com/supabase/supabase
cd supabase/docker
cp .env.example .env
# isi .env: POSTGRES_PASSWORD, JWT_SECRET, ANON_KEY, SERVICE_ROLE_KEY, SITE_URL,
#           API_EXTERNAL_URL, STORAGE_* (tetapkan sekarang, jangan ubah setelah data masuk)
docker compose up -d
```

- **PENTING**: ANON_KEY & SERVICE_ROLE_KEY dibuat dari JWT_SECRET + `docker run
  supabase/config` (generator). Kunci ini wajib konsisten dengan `.env` Frontend nanti.
- HTTPS: jalankan **Caddy** atau nginx di depan; atau aktifkan `HTTPS=true` pada
  `kong`/`studio`. Arahkan domain `db.dayangspa.id` → IP VPS.
- Aktifkan Realtime publication agar status terapis live:
  ```sql
  create publication supabase_realtime for table therapists, treatments, bookings,
    reservations, oil_inventory, inventory, attendance;
  ```

## 5. Migrasi Data (langkah B)

Urutan teraman (dua jalur, saling cadangan):

1. **`pg_dump` penuh** dari cloud (schema + data + auth) → restore ke Postgres VPS.
   ```bash
   # dari VPS (gunakan connection string SUPERUSER cloud, allowlist IP sudah ditambah)
   pg_dump "postgresql://postgres.<ref>:<PASSWORD>@aws-0-<region>.pooler.supabase.com:5432/postgres" \
     --schema=public --schema=auth --no-owner -f cloud.sql
   psql "$DATABASE_URL_LOKAL" -f cloud.sql
   ```
2. **Cadangan CSV** (yang sudah kita punya) → import sebagai verifikasi jumlah baris:
   `bookings` ≈ 3.935+ , `therapists` = 32, `treatments` = 89, `users`, `oil_inventory`, dst.
3. **Fungsi RPC**: ciptakan kembali 27 fungsi dari `supabase/*.sql` (sudah ada) + `schema.sql`.
4. Cocokkan jumlah baris per tabel (cloud vs VPS) sebelum lanjut.

> Kalau `pg_dump` terkendala (mis. rights di auth schema), jalur CSV + fungsi tetap cukup:
> import tiap CSV lalu buat ulang tabel dari `schema.sql`.

## 6. Alihkan Aplikasi (langkah C)

1. Ubah konfigurasi Frontend (di repo):
   - `src/lib/supabase.js` → `VITE_SUPABASE_URL` ke `https://db.dayangspa.id`
   - `VITE_SUPABASE_ANON_KEY` ke ANON_KEY self-host (sama dengan `.env` server)
2. Build & deploy PWA (auto-deploy Vercel/GitHub Pages saat push).
3. **Hard refresh** (CTRL+SHIFT+R) di semua perangkat kasir/display.
4. Uji: login kasir (password lama), list WA real-time, transaksi baru, oncall, laporan.

## 7. Cutover & Pemantauan (langkah D)

Urutan:
1. Jam sepi (mis. 02:00): **backup final cloud** → migrasi baru → uji → **switch URL**.
2. Jalan paralel ±1–2 minggu: VPS jadi sistem utama, cloud dibiarkan (cadangan), sesekali
   cek laporan apakah angka konsisten.
3. Setelah stabil: **matikan/langganan Supabase cloud dibatalkan** (hapus proyek setelah
   semua data terverifikasi).

Pemeliharaan rutin (jadwal):
- Backup DB VPS tiap malam (`pg_dumpall`/`pg_dump` → folder + rsync ke tempat lain).
- `apt update && apt upgrade && docker compose pull && docker compose up -d` bulanan.
- Pantau disk (`df -h`) & RAM (`free -h`).

---

## 8. Risiko & Antisipasi

| Risiko | Antisipasi |
|---|---|
| IP allowlist cloud blokir dump | Tambah IP VPS ke allowlist; atau pakai pooler |
| `auth.users` tidak ikut (password berubah) | Ikuti jalur `pg_dump --schema=auth`; fallback reset password kasir |
| Kuota cloud direstriksi sebelum selesai (28 Sep) | Lakukan migrasi hari ini juga; opsi darurat aktifkan Pro sementara |
| Versi self-host tertinggal dari cloud | Cek catatan rilis; supabase-js v2 kompatibel |
| Server down → semua outlet berhenti | Backup harian + monitoring uptime (uptime robot/gratis) |

## 9. Yang saya perlukan dari Anda untuk mulai

1. **VPS aktif** (Hetzner/DO/Vultr, region SG) — kirim IP-nya.
2. **Domain** untuk Supabase (mis. `db.xxx...` ) — atau sementara pakai IP + sertifikat.
3. **Buka akses** untuk saya bantu setup (pasang SSH key atau beri user + password sekali pakai).
4. **Konfirmasi password DB cloud** (sudah ada di `dburl.txt`) untuk `pg_dump` dari VPS.