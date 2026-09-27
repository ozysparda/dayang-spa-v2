import { SHIFTS } from './constants';

/**
 * Hitung status jadwal shift terapis berdasarkan jam saat ini (waktu lokal).
 * - Shift SP1: aktif 11:00-14:00 dan 17:00-22:00, jeda 14:00-17:00
 * - Shift SP2: aktif 12:00-15:00 dan 18:00-23:00, jeda 15:00-18:00
 * - Shift SP : aktif 11:00-15:00 dan 18:00-23:00, jeda 15:00-18:00
 * - Shift Malam / 15: aktif 15:00-23:00, tidak ada jeda di tengah
 * - Shift ST: aktif 11:00-17:00
 * Di luar rentang itu dianggap "di luar jam kerja".
 * Return: 'aktif' | 'jeda' | 'diluar_jam' | null (kalau tidak ada shift di-set)
 */
export function getShiftWindowStatus(shift, now = new Date()) {
  if (!shift) return null;
  const minutes = now.getHours() * 60 + now.getMinutes();
  const t = (h, m = 0) => h * 60 + m;

  if (shift === SHIFTS.SP1) {
    if (minutes >= t(11) && minutes < t(14)) return 'aktif';
    if (minutes >= t(14) && minutes < t(17)) return 'jeda';
    if (minutes >= t(17) && minutes < t(22)) return 'aktif';
    return 'diluar_jam';
  }

  if (shift === SHIFTS.SP2) {
    if (minutes >= t(12) && minutes < t(15)) return 'aktif';
    if (minutes >= t(15) && minutes < t(18)) return 'jeda';
    if (minutes >= t(18) && minutes < t(23)) return 'aktif';
    return 'diluar_jam';
  }

  if (shift === SHIFTS.SP) {
    if (minutes >= t(11) && minutes < t(15)) return 'aktif';
    if (minutes >= t(15) && minutes < t(18)) return 'jeda';
    if (minutes >= t(18) && minutes < t(23)) return 'aktif';
    return 'diluar_jam';
  }

  if (shift === SHIFTS.MALAM || shift === SHIFTS.T15) {
    if (minutes >= t(15) && minutes < t(23)) return 'aktif';
    return 'diluar_jam';
  }

  if (shift === SHIFTS.T11) {
    if (minutes >= t(11) && minutes < t(23)) return 'aktif';
    return 'diluar_jam';
  }

  if (shift === SHIFTS.ST) {
    if (minutes >= t(11) && minutes < t(17)) return 'aktif';
    return 'diluar_jam';
  }

  return null;
}

export const SHIFT_WINDOW_LABEL = {
  aktif: 'Jam kerja',
  jeda: 'Jeda shift (break)',
  diluar_jam: 'Di luar jam kerja'
};
