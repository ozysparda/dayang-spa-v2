import { supabase } from './supabase';
import { OUTLETS, SHIFTS } from './constants';

// Jam selesai shift normal (menit sejak 00:00) — patokan overtime.
//  - Shift SP1 : 11:00-14:00 & 17:00-22:00   -> selesai 22:00
//  - Shift SP2 : 12:00-15:00 & 18:00-23:00   -> selesai 23:00
//  - Shift SP  : 11:00-15:00 & 18:00-23:00   -> selesai 23:00
//  - Shift Malam / 15: 15:00-23:00           -> selesai 23:00
//  - Shift 11: 11:00-23:00                    -> selesai 23:00
//  - Shift ST / Short: 11:00-16:00            -> selesai 16:00
const SHIFT_END_MINUTES = {
  [SHIFTS.SP]: 23 * 60,
  [SHIFTS.SP1]: 22 * 60,
  [SHIFTS.SP2]: 23 * 60,
  [SHIFTS.MALAM]: 23 * 60,
  [SHIFTS.AD]: 23 * 60,
  [SHIFTS.T11]: 23 * 60,
  [SHIFTS.ST]: 16 * 60
};

// Ambil penyesuaian overtime manual dalam rentang tanggal.
// Dipakai getOvertimeReport untuk MENIMPA hasil hitung otomatis.
export async function getOvertimeAdjustments(startDate, endDate) {
  const { data, error } = await supabase
    .from('overtime_adjustments')
    .select('therapist_id, work_date, adjusted_minutes, reason')
    .gte('work_date', startDate)
    .lte('work_date', endDate);
  if (error) throw error;
  const map = {};
  (data || []).forEach((r) => {
    map[`${r.therapist_id}|${r.work_date}`] = {
      adjustedMinutes: Number(r.adjusted_minutes) || 0,
      reason: r.reason || ''
    };
  });
  return map;
}

// Set/simpan koreksi overtime (upsert per terapis + tanggal).
export async function setOvertimeAdjustment({ therapistId, date, adjustedMinutes, reason, createdBy = '' }) {
  const { error } = await supabase
    .from('overtime_adjustments')
    .upsert(
      {
        therapist_id: therapistId,
        work_date: date,
        adjusted_minutes: Math.max(0, Math.round(Number(adjustedMinutes) || 0)),
        reason: reason || '',
        created_by: createdBy
      },
      { onConflict: 'therapist_id,work_date' }
    );
  if (error) throw error;
}

// Hapus koreksi -> kembali ke hitung otomatis.
export async function removeOvertimeAdjustment(therapistId, date) {
  const { error } = await supabase
    .from('overtime_adjustments')
    .delete()
    .eq('therapist_id', therapistId)
    .eq('work_date', date);
  if (error) throw error;
}

function toMinutes(ms) {
  return Math.max(0, Math.floor(ms / 60000));
}

// Batas UTC untuk satu hari LOKAL (WIB = UTC+7)
function wibDayBoundsUtc(dateStr) {
  const [y, m, d] = dateStr.split('-').map(Number);
  const startUtc = new Date(Date.UTC(y, m - 1, d, 0, 0, 0) - 7 * 3600000);
  const endUtc = new Date(startUtc.getTime() + 24 * 3600000 - 1);
  return { startUtc, endUtc };
}

// Format tanggal dari komponen LOKAL (WIB) — bukan toISOString (UTC),
// agar rentang "hari ini" tidak tergeser 1 hari mundur.
function fmtLocalDate(d) {
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${d.getFullYear()}-${m}-${day}`;
}

/**
 * Hitung overtime per terapis pada rentang tanggal, bersumber dari DATA BOOKING.
 *
 * Definisi overtime:
 *   - Waktu kerja aktual terapis per hari = akhir treatment TERAKHIR (max end_at)
 *     dari booking non-batal (berjalan/lunas/selesai) pada hari itu.
 *   - Patokan = jam selesai shift normal terapis (lihat SHIFT_END_MINUTES).
 *   - Overtime (menit) = kelebihan waktu kerja aktual di atas jam selesai shift.
 *     Kalau terapis tidak punya shift -> overtime tidak bisa dihitung (dibuat 0
 *     dan ditandai shift = null).
 */
export async function getOvertimeReport(startDate, endDate) {
  const { data: therapists, error: terr } = await supabase
    .from('therapists')
    .select('id, name, shift');
  if (terr) throw terr;
  const therapistById = Object.fromEntries((therapists || []).map((t) => [t.id, t]));

  // Ambil semua booking dalam rentang (semua outlet) — sekali query per hari.
  const allBookings = [];
  for (let d = new Date(startDate + 'T00:00:00'); d <= new Date(endDate + 'T00:00:00'); d.setDate(d.getDate() + 1)) {
    const dateStr = fmtLocalDate(d);
    try {
      const { startUtc, endUtc } = wibDayBoundsUtc(dateStr);
      const { data, error } = await supabase
        .from('bookings')
        .select('id, outlet_id, therapist_id, therapist_name, treatment_name, treatment_price, commission_percent, start_at, end_at, status, booking_source')
        .gte('start_at', startUtc.getTime())
        .lte('start_at', endUtc.getTime());
      if (error) throw error;
      allBookings.push(...(data || []).map((r) => ({ ...r, date: dateStr })));
    } catch (e) {
      // lewati hari error, lanjut hari berikutnya
      console.warn('overtime fetch error', dateStr, e);
    }
  }

  // Kunci: therapist_id + date
  const rows = {};
  allBookings.forEach((b) => {
    // Hanya booking yang berlaku (bukan batal)
    if (b.status === 'batal' || b.status === 'batal_sebagian') return;
    if (!b.therapist_id || !b.date) return;
    // Oncall tidak dihitung lembur (komisi berbeda)
    if (b.booking_source === 'oncall') return;
    const key = `${b.therapist_id}|${b.date}`;
    if (!rows[key]) {
      rows[key] = {
        therapistId: b.therapist_id,
        therapistName: b.therapist_name,
        date: b.date,
        outletId: b.outlet_id,
        treatmentCount: 0,
        maxEndAt: null
      };
    }
    rows[key].treatmentCount += 1;
    if (b.end_at != null && (rows[key].maxEndAt == null || Number(b.end_at) > rows[key].maxEndAt)) {
      rows[key].maxEndAt = Number(b.end_at);
    }
  });

  const adjustments = await getOvertimeAdjustments(startDate, endDate);

  const result = Object.values(rows).map((row) => {
    const therapist = therapistById[row.therapistId] || null;
    const shift = therapist ? therapist.shift : null;
    const shiftEndMin = shift ? SHIFT_END_MINUTES[shift] : null;

    let overtimeMinutes = 0;
    if (shiftEndMin != null && row.maxEndAt != null) {
      const shiftEndMs = wibDayShiftEndMs(row.date, shiftEndMin);
      overtimeMinutes = Math.max(0, toMinutes(row.maxEndAt - shiftEndMs));
    }

    // Penyesuaian manual MENIMPA nilai otomatis (0 = boleh).
    const adjKey = `${row.therapistId}|${row.date}`;
    const adj = adjustments[adjKey];
    let corrected = false;
    if (adj) {
      overtimeMinutes = adj.adjustedMinutes;
      corrected = true;
    }

    return {
      therapistId: row.therapistId,
      therapistName: row.therapistName,
      date: row.date,
      outletId: row.outletId,
      outletName: OUTLETS.find((o) => o.id === row.outletId)?.name || row.outletId || '-',
      treatmentCount: row.treatmentCount,
      shift,
      overtimeMinutes,
      maxEndAt: row.maxEndAt,
      corrected,
      correctionReason: adj ? adj.reason : ''
    };
  });

  result.sort((a, b) => (a.date === b.date ? a.therapistName.localeCompare(b.therapistName) : a.date.localeCompare(b.date)));
  return result;
}

// Jam selesai shift pada tanggal tertentu (WIB) dalam epoch ms.
function wibDayShiftEndMs(dateStr, shiftEndMin) {
  const [y, m, d] = dateStr.split('-').map(Number);
  // jam selesai shift dalam WIB -> konversi ke UTC ms, lalu tambah offset WIB
  const endLocal = new Date(Date.UTC(y, m - 1, d, Math.floor(shiftEndMin / 60), shiftEndMin % 60, 0));
  return endLocal.getTime() - 7 * 3600000;
}

/**
 * Agregasi overtime otomatis (dari data booking) per karyawan pada rentang tanggal.
 * Return: { [employeeId]: { employeeName, totalOvertimeMinutes, daysCount } }
 */
export async function getOvertimeByEmployee(startDate, endDate) {
  const rows = await getOvertimeReport(startDate, endDate);
  const byEmployee = {};
  rows.forEach((r) => {
    if (!byEmployee[r.therapistId]) {
      byEmployee[r.therapistId] = { employeeName: r.therapistName, totalOvertimeMinutes: 0, daysCount: 0 };
    }
    byEmployee[r.therapistId].totalOvertimeMinutes += r.overtimeMinutes;
    if (r.overtimeMinutes > 0) byEmployee[r.therapistId].daysCount += 1;
  });
  return byEmployee;
}
