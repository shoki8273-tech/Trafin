# Trafin

Catat keuangan pribadi dan akuntansi perusahaan (Flutter).

## Menjalankan
```
flutter pub get
flutter run
flutter test
```

## Fitur
- Mode **Pribadi**: transaksi, rekening, anggaran, hutang/piutang, kalender, target tabungan, laporan donut.
- Mode **Perusahaan**: jurnal, daftar akun, Neraca, Laba Rugi, Arus Kas, Perubahan Ekuitas (bisa dibagikan sebagai PDF).
- Data tersimpan otomatis di perangkat (`lib/persistence.dart`).
- Kunci PIN (hash SHA-256 + salt, disimpan di Keychain/Keystore).
- 16 bahasa: Indonesia, English, Melayu, 中文, 日本語, 한국어, العربية (RTL), हिन्दी, Español, Français, Deutsch, Português, Русский, Türkçe, Tiếng Việt, ไทย.

## Struktur
- `lib/main.dart` – UI dan logika utama
- `lib/i18n.dart` – `tr()`, widget `Tr`, daftar bahasa, halaman pilih bahasa
- `lib/l10n/*.dart` – terjemahan (**dihasilkan otomatis**, jangan diedit tangan)
- `lib/persistence.dart` – simpan/muat data, hash PIN
- `lib/pdf_export.dart` – ekspor laporan ke PDF
- `tools/l10n/` – sumber terjemahan + skrip pembuat file Dart

## Menambah / mengubah terjemahan
Kunci terjemahan = teks Indonesia di kode (mis. `tr('Simpan')`, `const Tr('Simpan')`).
1. Teks baru: tambahkan di `tools/l10n/master_src.py` (daftar `N`, beserta padanan Inggris).
2. `python3 tools/l10n/master_src.py tools/l10n/master.txt`
3. Tambahkan baris `N|terjemahan` di `tools/l10n/trans/<kode>.txt` untuk tiap bahasa.
4. `python3 tools/l10n/validate.py en ms zh ja ko ar hi es fr de pt ru tr vi th` (cek nomor & placeholder)
5. `python3 tools/l10n/gen_dart.py lib/l10n`

Bahasa baru: buat `trans/<kode>.txt`, tambahkan kode di `langs` pada `gen_dart.py`, dan tambahkan `AppLang` di `lib/i18n.dart`.
Teks yang belum diterjemahkan otomatis tampil dalam bahasa Inggris.

## Catatan
- Nama mata uang/negara di daftar mata uang masih berbahasa Indonesia.
- PDF dibuat sebagai gambar (agar semua aksara tampil benar), jadi teksnya tidak bisa diseleksi.
- Nominal masih bilangan bulat (belum mendukung sen).
- `assets/icon.png` belum ada; dibutuhkan jika menjalankan `dart run flutter_launcher_icons`.
