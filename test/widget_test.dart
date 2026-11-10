import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_buddy/i18n.dart';
import 'package:money_buddy/l10n/translations.dart';
import 'package:money_buddy/main.dart';
import 'package:money_buddy/persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

void resetState() {
  txs.value = [];
  goals.value = [];
  journals.value = [];
  budgets.value = [];
  debts.value = [];
  wallets.value = [const Wallet('Tunai', 'Tunai', 0)];
  pin.value = null;
  locked.value = false;
  appLocale.value = 'id';
  currency.value = 'Rp';
  symbolAfter.value = false;
  thousandSep.value = '.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetState();
  });
  tearDown(AppStore.detach);

  test('rp memformat angka dengan pemisah ribuan dan simbol', () {
    expect(rp(1234567), 'Rp1.234.567');
    expect(rp(-5000), '-Rp5.000');
    symbolAfter.value = true;
    expect(rp(1000), '1.000 Rp');
  });

  test('jurnal mengubah saldo akun dan bisa dibatalkan', () {
    final j = Journal(DateTime(2026, 1, 5), 'Setor modal', [('Kas', 1000, 0), ('Modal Saham', 0, 1000)]);
    applyJournal(j, 1);
    expect(sumType('Aset'), 1000);
    expect(sumType('Ekuitas'), 1000);
    applyJournal(j, -1);
    expect(sumType('Aset'), 0);
    expect(sumType('Ekuitas'), 0);
  });

  test('saldo total memasukkan saldo awal rekening', () {
    wallets.value = [const Wallet('Tunai', 'Tunai', 100000)];
    final list = [Tx('Gaji', 'Gaji', DateTime(2026, 1, 1), 500000, true, Icons.payments_outlined, 'Tunai')];
    expect(totalBalance(list), 600000);
  });

  test('periode bulanan mengikuti tanggal mulai', () {
    startDay.value = 25;
    expect(periodOf(DateTime(2026, 3, 24)), DateTime(2026, 2));
    expect(periodOf(DateTime(2026, 3, 25)), DateTime(2026, 3));
    startDay.value = 1;
  });

  test('PIN disimpan sebagai hash dan diverifikasi', () {
    pin.value = hashPin('1234');
    expect(pin.value!.contains('1234'), isFalse);
    expect(verifyPin('1234'), isTrue);
    expect(verifyPin('4321'), isFalse);
  });

  test('semua bahasa punya kunci yang sama dengan Inggris', () {
    final en = translations['en']!.keys.toSet();
    for (final l in appLangs) {
      if (l.code == 'id') continue;
      expect(translations[l.code], isNotNull, reason: l.code);
      expect(translations[l.code]!.keys.toSet(), en, reason: l.code);
    }
  });

  test('tr() memakai bahasa aktif dan jatuh ke kunci bila belum ada', () {
    appLocale.value = 'en';
    expect(tr('Simpan'), 'Save');
    expect(tr('Halo, {n}', {'n': 'Ani'}), 'Hello, Ani');
    appLocale.value = 'id';
    expect(tr('Simpan'), 'Simpan');
    expect(tr('m1'), 'Januari');
    expect(tr('teks yang tidak ada'), 'teks yang tidak ada');
  });

  test('data tersimpan lalu dimuat kembali', () async {
    await AppStore.init();
    txs.value = [Tx('Kopi', 'Makanan', DateTime(2026, 2, 3), 25000, false, Icons.restaurant_outlined, 'Tunai')];
    goals.value = [const Goal('Laptop', 100, 1000, 'Des 2026', Icons.flag_outlined)];
    appLocale.value = 'fr';
    await AppStore.saveNow();
    AppStore.detach();

    resetState();
    expect(txs.value, isEmpty);
    await AppStore.init();
    expect(txs.value.single.title, 'Kopi');
    expect(txs.value.single.amt, 25000);
    expect(goals.value.single.name, 'Laptop');
    expect(appLocale.value, 'fr');
  });

  testWidgets('aplikasi tampil dan bisa ganti bahasa', (tester) async {
    await tester.pumpWidget(const MoneyBuddyApp());
    await tester.pumpAndSettle();
    expect(find.text('Money Buddy'), findsWidgets);
    expect(find.text('Pribadi'), findsOneWidget);

    appLocale.value = 'en';
    await tester.pumpAndSettle();
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Pribadi'), findsNothing);
  });
}
