export const OUTLETS = [
  { id: 'DR', name: 'Dream' },
  { id: 'RR', name: 'Rere' },
  { id: 'DP', name: 'Dayang Putri' },
  { id: 'D1', name: 'Dayang 1' },
  { id: 'D2', name: 'Dayang 2' },
  { id: 'Y', name: 'Yulis' }
];

export const OIL_TYPES = [
  'Relaxing', 'Refreshing', 'Herbal', 'Hot Oil', 'Cem-Ceman', 'Aromatic Oil', 'Aloevera Cream'
];
export const OIL_SIZES = ['Kecil', 'Besar']; // Kecil = 10ml, Besar = 30ml

export const FOOT_PRODUCTS = ['Foot Cream', 'FM'];

export const TREATMENT_CATEGORIES = ['Massage', 'Nail', 'Body Care', 'Waxing', 'Hair Treatment'];

/** Apakah treatment ini Foot Massage (pakai produk Foot Cream / FM)? */
export function isFootMassage(t) {
  if (!t) return false;
  return String(t.name || '').toLowerCase().includes('foot massage');
}

/** Pilihan produk/minyak yang muncul saat memilih sebuah treatment.
 *  Foot Massage difokuskan pada Foot Cream / FM, yang lain pakai body oil biasa. */
export function oilChoicesFor(t) {
  return isFootMassage(t) ? FOOT_PRODUCTS : OIL_TYPES;
}

/** Apakah sebuah treatment memakai minyak/produk? Prioritas:
 *  1. Foot Massage -> true (pakai Foot Cream / FM)
 *  2. field `usesOil` di data treatment (kalau ada/terisi)
 *  3. fallback: kategori Massage yang pakai minyak */
export function treatmentUsesOil(t) {
  if (!t) return false;
  if (isFootMassage(t)) return true;
  if (t.usesOil !== undefined) return !!t.usesOil;
  return t.category === 'Massage';
}

export const PAYMENT_METHODS = { CASH: 'cash', CARDLESS: 'cardless' };
export const PAYMENT_METHOD_LABEL = { cash: 'Cash', cardless: 'Cardless' };

export const ONCALL_PACKAGES = [
  {
    id: 'MAMBO',
    name: 'Mambo',
    hotelCommission: 100000,
    durations: [
      { minutes: 60, price: 350000 },
      { minutes: 90, price: 500000 }
    ]
  },
  {
    id: 'NIYAMA',
    name: 'Niyama & Racotage',
    hotelCommission: 50000,
    durations: [
      { minutes: 60, price: 300000 },
      { minutes: 90, price: 450000 }
    ]
  },
  {
    id: 'LAIN',
    name: 'Lainnya (harga baru)',
    hotelCommission: 50000,
    durations: [
      { minutes: 60, price: 400000 },
      { minutes: 90, price: 600000 }
    ]
  }
];

export const DEFAULT_ONCALL_COMMISSION_PCT = 30;

export const SHIFTS = { SP: 'sp', SP1: 'sp1', SP2: 'sp2', MALAM: 'malam', ST: 'st', T15: '15', T11: '11' };
export const SHIFT_LABEL = {
  sp: 'Shift SP (Split)',
  sp1: 'Shift SP1 (11-14, 17-22)',
  sp2: 'Shift SP2 (12-15, 18-23)',
  malam: 'Shift Malam',
  '15': 'Shift 15 (15-23)',
  '11': 'Shift 11 (11-23)',
  st: 'Shift ST (Short Time)'
};
export const SHIFT_SHORT_CODE = { sp: 'Sp', sp1: 'Sp¹', sp2: 'Sp²', malam: '15', '15': '15', '11': '11', st: 'St' };

export const STAFF_ROLES = {
  SENIOR_TERAPIS: 'senior_terapis',
  KASIR: 'kasir_staff',
  TERAPIS: 'terapis',
  TRAINING_TERAPIS: 'training_terapis',
  TRAINING_BARU: 'training_baru'
};

export const THERAPIST_STATUS = {
  FREE: 'free',
  LIBUR: 'libur',
  AMBIL_TAMU: 'ambil_tamu',
  BREAK: 'break'
};

export const ATTENDANCE_TYPES = {
  HADIR: 'hadir',
  SAKIT: 'sakit',
  IZIN: 'izin',
  TELAT: 'telat',
  ALPHA: 'alpha',
  LEMBUR: 'lembur' // overtime
};
