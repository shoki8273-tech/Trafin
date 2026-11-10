import 'dart:math' as math;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'i18n.dart';
import 'pdf_export.dart';
import 'persistence.dart';
import 'extras.dart';
import 'currency_rates.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStore.init();
  ensureBusinessBooks();
  runSchedules();
  runApp(const TrafinApp());
}

// ───────────────────────── Helper & data dummy ─────────────────────────

/// Semua saldo/jurnal disimpan dalam mata uang dasar, tidak pernah dikalikan
/// saat pengguna hanya mengganti mata uang tampilan.
/// Kurs tampilan: 1 satuan mata uang dasar = displayFxRate satuan tampilan.
num toDisplayMoney(num stored) => stored * displayFxRate.value;
num toStoredMoney(num displayed) => displayed / displayFxRate.value;

String rp(num v) {
  final dec = decimals.value;
  final shown = toDisplayMoney(v);
  final fixed = shown.abs().toStringAsFixed(dec);
  final parts = fixed.split('.');
  final digits = parts[0];
  final sep = thousandSep.value;
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(sep);
    b.write(digits[i]);
  }
  final decimalSep = sep == ',' ? '.' : ',';
  final body = dec > 0 && parts.length > 1 ? '$b$decimalSep${parts[1]}' : '$b';
  final sign = shown < 0 && double.parse(fixed) != 0 ? '-' : '';
  return symbolAfter.value ? '$sign$body ${currency.value}' : '$sign${currency.value}$body';
}

/// Nominal diketik dalam mata uang tampilan. Pemisah ribuan boleh muncul
/// berkali-kali; hanya angka yang dihitung. Pecahan mengikuti pemisah desimal
/// yang berbeda dari pemisah ribuan supaya 30.000 tidak terbaca sebagai 30.
num parseFormattedAmount(String text, {int? fractionDigits}) {
  final raw = text.trim();
  if (raw.isEmpty) return 0;
  final precision = fractionDigits ?? decimals.value;
  final decimalMarker = thousandSep.value == ',' ? '.' : ',';
  final decimalAt = precision > 0 ? raw.lastIndexOf(decimalMarker) : -1;
  final wholePart = (decimalAt < 0 ? raw : raw.substring(0, decimalAt))
      .replaceAll(RegExp(r'[^0-9]'), '');
  final fractionalPart = decimalAt < 0 ? '' : raw.substring(decimalAt + 1)
      .replaceAll(RegExp(r'[^0-9]'), '');
  if (wholePart.isEmpty && fractionalPart.isEmpty) return 0;
  final whole = num.tryParse(wholePart.isEmpty ? '0' : wholePart) ?? 0;
  if (precision <= 0 || fractionalPart.isEmpty) return whole;
  final fraction = fractionalPart.substring(0, math.min(precision, fractionalPart.length));
  return whole + (int.tryParse(fraction) ?? 0) / math.pow(10, fraction.length);
}

num parseMoney(String text) => toStoredMoney(parseFormattedAmount(text));

// ───────────────────────── Pengaturan (global) ─────────────────────────

/// Tampilan bawaan saat instalasi: terang dengan aksen ungu.
/// ThemeMode.system dipakai sebagai ID preset 'Default' agar data tema versi lama
/// (yang menyimpan indeks ThemeMode) tetap bisa dimuat tanpa migrasi destruktif.
const Color defaultTrafinThemeColor = Color(0xFF7B5CF0);
final themeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
final seedColor = ValueNotifier<Color>(defaultTrafinThemeColor);

/// Default bukan lagi 'ikuti sistem HP', tetapi preset tampilan bawaan Trafin.
ThemeMode get effectiveTrafinThemeMode =>
    themeMode.value == ThemeMode.system ? ThemeMode.light : themeMode.value;

void restoreDefaultTrafinTheme() {
  seedColor.value = defaultTrafinThemeColor;
  themeMode.value = ThemeMode.system;
}

void selectTrafinThemeColor(Color nextColor) {
  seedColor.value = nextColor;
  if (themeMode.value == ThemeMode.system) themeMode.value = ThemeMode.light;
}

final userName = ValueNotifier<String>('');
final companyName = ValueNotifier<String>('');
final showIndicator = ValueNotifier<bool>(true);
final currency = ValueNotifier<String>('Rp');
final currencyCode = ValueNotifier<String>('IDR');
/// Di-upgrade dari data lama: defaultnya mata uang terpilih saat migrasi.
/// Catatan: versi lama tidak menyimpan mata uang tiap transaksi.
final baseCurrencyCode = ValueNotifier<String>('IDR');
/// Kurs bersifat indikatif, disimpan untuk memulihkan tampilan saat offline.
final displayFxRate = ValueNotifier<double>(1.0);
final displayFxUpdated = ValueNotifier<String>('');
final displayFxSource = ValueNotifier<String>('');
final symbolAfter = ValueNotifier<bool>(false);
final thousandSep = ValueNotifier<String>('.');
final dateFormat = ValueNotifier<int>(0); // 0 = 29 Okt, 1 = 29/10/2026
final decimals = ValueNotifier<int>(0); // 0 = tanpa desimal, 2 = dua digit
final startDay = ValueNotifier<int>(1); // awal periode akuntansi/bulanan
final pin = ValueNotifier<String?>(null);
final locked = ValueNotifier<bool>(false);
final customExpenseCats = ValueNotifier<List<String>>([]);
final customIncomeCats = ValueNotifier<List<String>>([]);

// Periode yang sedang dipakai pada laporan perusahaan.
final companyReportPeriod = ValueNotifier<DateTime>(periodOf(DateTime.now()));

/// True sementara app sengaja keluar ke latar belakang (mis. dialog bagikan PDF).
bool skipLock = false;

String bulanTahun([DateTime? d]) {
  final x = d ?? DateTime.now();
  return tr('my', {'m': tr('m${x.month}'), 'y': x.year});
}

DateTime periodOf(DateTime d) {
  final st = startDay.value;
  return d.day >= st ? DateTime(d.year, d.month) : DateTime(d.year, d.month - 1);
}

String periodLabel(DateTime p) {
  final st = startDay.value;
  if (st == 1) return bulanTahun(p);
  return '${dateLabel(DateTime(p.year, p.month, st))} – ${dateLabel(DateTime(p.year, p.month + 1, st - 1))}';
}

class Tx {
  final String title, cat, wallet;
  final DateTime when;
  final num amt;
  final bool income;
  final IconData icon;
  const Tx(this.title, this.cat, this.when, this.amt, this.income, this.icon, [this.wallet = '']);
  String get date => dateLabel(when);
}

final txs = ValueNotifier<List<Tx>>([]);

class Goal {
  final String name, deadline;
  final num saved, target;
  final IconData icon;
  const Goal(this.name, this.saved, this.target, this.deadline, this.icon);
}

final goals = ValueNotifier<List<Goal>>([]);

class Acc {
  final String code, name, type;
  final num bal;
  const Acc(this.code, this.name, this.type, this.bal);
}

const accTypes = ['Aset', 'Liabilitas', 'Ekuitas', 'Pendapatan', 'Beban'];

final accounts = ValueNotifier<List<Acc>>([
  Acc('1-101', 'Kas', 'Aset', 0),
  Acc('1-102', 'Bank BCA', 'Aset', 0),
  Acc('1-201', 'Piutang Usaha', 'Aset', 0),
  Acc('1-301', 'Persediaan', 'Aset', 0),
  Acc('1-501', 'Peralatan (neto)', 'Aset', 0),
  Acc('2-101', 'Utang Usaha', 'Liabilitas', 0),
  Acc('2-201', 'Utang Bank', 'Liabilitas', 0),
  Acc('3-101', 'Modal Saham', 'Ekuitas', 0),
  Acc('3-201', 'Laba Ditahan', 'Ekuitas', 0),
  Acc('4-101', 'Penjualan', 'Pendapatan', 0),
  Acc('4-201', 'Pendapatan Lain', 'Pendapatan', 0),
  Acc('5-101', 'Harga Pokok Penjualan', 'Beban', 0),
  Acc('5-201', 'Beban Gaji', 'Beban', 0),
  Acc('5-301', 'Beban Sewa', 'Beban', 0),
  Acc('5-401', 'Beban Listrik & Air', 'Beban', 0),
  Acc('5-901', 'Beban Lain-lain', 'Beban', 0),
]);

List<Acc> starterAccounts() => const [
      Acc('1-101', 'Kas', 'Aset', 0),
      Acc('1-102', 'Bank BCA', 'Aset', 0),
      Acc('1-201', 'Piutang Usaha', 'Aset', 0),
      Acc('1-301', 'Persediaan', 'Aset', 0),
      Acc('1-501', 'Peralatan (neto)', 'Aset', 0),
      Acc('2-101', 'Utang Usaha', 'Liabilitas', 0),
      Acc('2-201', 'Utang Bank', 'Liabilitas', 0),
      Acc('3-101', 'Modal Saham', 'Ekuitas', 0),
      Acc('3-201', 'Laba Ditahan', 'Ekuitas', 0),
      Acc('4-101', 'Penjualan', 'Pendapatan', 0),
      Acc('4-201', 'Pendapatan Lain', 'Pendapatan', 0),
      Acc('5-101', 'Harga Pokok Penjualan', 'Beban', 0),
      Acc('5-201', 'Beban Gaji', 'Beban', 0),
      Acc('5-301', 'Beban Sewa', 'Beban', 0),
      Acc('5-401', 'Beban Listrik & Air', 'Beban', 0),
      Acc('5-901', 'Beban Lain-lain', 'Beban', 0),
    ];

List<Acc> byType(String t) => accounts.value.where((a) => a.type == t).toList();
num sumType(String t) => byType(t).fold<num>(0, (s, a) => s + a.bal);
num get laba => sumType('Pendapatan') - sumType('Beban');

class Journal {
  final DateTime when;
  final String desc;
  final List<(String, num, num)> lines; // (akun, debit, kredit)
  const Journal(this.when, this.desc, this.lines);
  String get date => dateLabel(when);
}

final journals = ValueNotifier<List<Journal>>([]);

class BizContact {
  final String id, name, kind, phone, note;
  const BizContact(this.id, this.name, this.kind, this.phone, this.note);
}

class BizInvoice {
  final String id, number, contactName, status; // open | paid | void
  final num amount;
  final DateTime issued, due;
  const BizInvoice(this.id, this.number, this.contactName, this.amount, this.issued, this.due, this.status);
  BizInvoice copyWith({String? status}) => BizInvoice(id, number, contactName, amount, issued, due, status ?? this.status);
}

class StockItem {
  final String id, name, sku;
  final num qty, cost, price, minQty;
  const StockItem(this.id, this.name, this.sku, this.qty, this.cost, this.price, this.minQty);
  StockItem copyWith({num? qty, num? cost, num? price, num? minQty}) =>
      StockItem(id, name, sku, qty ?? this.qty, cost ?? this.cost, price ?? this.price, minQty ?? this.minQty);
}

final businessContacts = ValueNotifier<List<BizContact>>([]);
final businessInvoices = ValueNotifier<List<BizInvoice>>([]);
final stockItems = ValueNotifier<List<StockItem>>([]);
final closedBusinessPeriods = ValueNotifier<List<String>>([]);
final monthlyChecklistDone = ValueNotifier<List<String>>([]);

String newBizEntityId(String prefix) => '${prefix}_${DateTime.now().microsecondsSinceEpoch}';
String companyPeriodKey(DateTime d) {
  final p = periodOf(d);
  return '${p.year}-${p.month.toString().padLeft(2, '0')}';
}
String companyPeriodAnchorKey(DateTime p) => '${p.year}-${p.month.toString().padLeft(2, '0')}';
bool isCompanyPeriodClosed(DateTime d) => closedBusinessPeriods.value.contains(companyPeriodKey(d));
bool isCompanyPeriodAnchorClosed(DateTime p) => closedBusinessPeriods.value.contains(companyPeriodAnchorKey(p));

class BusinessBook {
  final String id, name;
  final List<Acc> accounts;
  final List<Journal> journals;
  final List<BizContact> contacts;
  final List<BizInvoice> invoices;
  final List<StockItem> stock;
  final List<String> closedPeriods;
  final List<String> checklistDone;
  final DateTime createdAt;

  const BusinessBook(
    this.id,
    this.name,
    this.accounts,
    this.journals,
    this.createdAt, {
    this.contacts = const [],
    this.invoices = const [],
    this.stock = const [],
    this.closedPeriods = const [],
    this.checklistDone = const [],
  });

  BusinessBook copyWith({
    String? name,
    List<Acc>? accounts,
    List<Journal>? journals,
    List<BizContact>? contacts,
    List<BizInvoice>? invoices,
    List<StockItem>? stock,
    List<String>? closedPeriods,
    List<String>? checklistDone,
  }) =>
      BusinessBook(
        id,
        name ?? this.name,
        accounts ?? this.accounts,
        journals ?? this.journals,
        createdAt,
        contacts: contacts ?? this.contacts,
        invoices: invoices ?? this.invoices,
        stock: stock ?? this.stock,
        closedPeriods: closedPeriods ?? this.closedPeriods,
        checklistDone: checklistDone ?? this.checklistDone,
      );
}

final businessBooks = ValueNotifier<List<BusinessBook>>([]);
final activeBusinessBookId = ValueNotifier<String>('');
bool _switchingBusinessBook = false;

String newBusinessBookId() => 'book_${DateTime.now().microsecondsSinceEpoch}';

BusinessBook? get activeBusinessBook {
  final id = activeBusinessBookId.value;
  for (final b in businessBooks.value) {
    if (b.id == id) return b;
  }
  return null;
}

void ensureBusinessBooks() {
  if (businessBooks.value.isEmpty) {
    final name = companyName.value.trim().isEmpty ? 'Bisnis Utama' : companyName.value.trim();
    final b = BusinessBook(
      newBusinessBookId(),
      name,
      List<Acc>.from(accounts.value),
      List<Journal>.from(journals.value),
      DateTime.now(),
      contacts: List<BizContact>.from(businessContacts.value),
      invoices: List<BizInvoice>.from(businessInvoices.value),
      stock: List<StockItem>.from(stockItems.value),
      closedPeriods: List<String>.from(closedBusinessPeriods.value),
      checklistDone: List<String>.from(monthlyChecklistDone.value),
    );
    businessBooks.value = [b];
    activeBusinessBookId.value = b.id;
    companyName.value = b.name;
    return;
  }
  if (!businessBooks.value.any((b) => b.id == activeBusinessBookId.value)) {
    activeBusinessBookId.value = businessBooks.value.first.id;
  }
  loadBusinessBookState(activeBusinessBookId.value);
}

void restoreBusinessBooks(List<BusinessBook> books, String? activeId) {
  if (books.isEmpty) return;
  _switchingBusinessBook = true;
  businessBooks.value = books;
  activeBusinessBookId.value =
      activeId != null && books.any((b) => b.id == activeId) ? activeId : books.first.id;
  final b = books.firstWhere((x) => x.id == activeBusinessBookId.value);
  accounts.value = List<Acc>.from(b.accounts);
  journals.value = List<Journal>.from(b.journals);
  businessContacts.value = List<BizContact>.from(b.contacts);
  businessInvoices.value = List<BizInvoice>.from(b.invoices);
  stockItems.value = List<StockItem>.from(b.stock);
  closedBusinessPeriods.value = List<String>.from(b.closedPeriods);
  monthlyChecklistDone.value = List<String>.from(b.checklistDone);
  companyName.value = b.name;
  _switchingBusinessBook = false;
}

void loadBusinessBookState(String id) {
  final matches = businessBooks.value.where((b) => b.id == id);
  if (matches.isEmpty) return;
  final b = matches.first;
  _switchingBusinessBook = true;
  accounts.value = List<Acc>.from(b.accounts);
  journals.value = List<Journal>.from(b.journals);
  businessContacts.value = List<BizContact>.from(b.contacts);
  businessInvoices.value = List<BizInvoice>.from(b.invoices);
  stockItems.value = List<StockItem>.from(b.stock);
  closedBusinessPeriods.value = List<String>.from(b.closedPeriods);
  monthlyChecklistDone.value = List<String>.from(b.checklistDone);
  activeBusinessBookId.value = id;
  companyName.value = b.name;
  companyReportPeriod.value = periodOf(DateTime.now());
  _switchingBusinessBook = false;
}

void syncActiveBusinessBook({String? name}) {
  if (_switchingBusinessBook || businessBooks.value.isEmpty) return;
  final id = activeBusinessBookId.value;
  businessBooks.value = [
    for (final b in businessBooks.value)
      if (b.id == id)
        b.copyWith(
          name: name ?? b.name,
          accounts: List<Acc>.from(accounts.value),
          journals: List<Journal>.from(journals.value),
          contacts: List<BizContact>.from(businessContacts.value),
          invoices: List<BizInvoice>.from(businessInvoices.value),
          stock: List<StockItem>.from(stockItems.value),
          closedPeriods: List<String>.from(closedBusinessPeriods.value),
          checklistDone: List<String>.from(monthlyChecklistDone.value),
        )
      else
        b,
  ];
  if (name != null) companyName.value = name;
}

void switchBusinessBook(String id) {
  if (id == activeBusinessBookId.value) return;
  syncActiveBusinessBook();
  loadBusinessBookState(id);
}

void createBusinessBook(String name) {
  final clean = name.trim();
  if (clean.isEmpty) return;
  syncActiveBusinessBook();
  final b = BusinessBook(newBusinessBookId(), clean, starterAccounts(), const [], DateTime.now());
  businessBooks.value = [...businessBooks.value, b];
  loadBusinessBookState(b.id);
}

void renameActiveBusinessBook(String name) {
  final clean = name.trim();
  if (clean.isEmpty) return;
  syncActiveBusinessBook(name: clean);
}

bool deleteBusinessBook(String id) {
  if (businessBooks.value.length <= 1) return false;
  final wasActive = activeBusinessBookId.value == id;
  businessBooks.value = businessBooks.value.where((b) => b.id != id).toList();
  if (wasActive) loadBusinessBookState(businessBooks.value.first.id);
  return true;
}

/// Terapkan (dir = 1) atau batalkan (dir = -1) efek sebuah jurnal ke saldo akun.
void applyJournal(Journal j, int dir) {
  accounts.value = [
    for (final a in accounts.value)
      Acc(
        a.code,
        a.name,
        a.type,
        a.bal +
            dir *
                j.lines.fold<num>(0, (s, l) {
                  if (l.$1 != a.name) return s;
                  final sign = (a.type == 'Aset' || a.type == 'Beban') ? 1 : -1;
                  return s + sign * (l.$2 - l.$3);
                }),
      ),
  ];
  syncActiveBusinessBook();
}

// ───────────────────────── App & shell ─────────────────────────

class TrafinApp extends StatefulWidget {
  const TrafinApp({super.key});

  @override
  State<TrafinApp> createState() => _TrafinAppState();
}

class _TrafinAppState extends State<TrafinApp> with WidgetsBindingObserver {
  bool acc = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) => systemLocaleTick.value++;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) runSchedules();
    final away = state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (away) unawaited(AppStore.saveNow());
    if (away && !skipLock && pin.value != null) locked.value = true;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          themeMode,
          seedColor,
          currency,
          currencyCode,
          displayFxRate,
          symbolAfter,
          thousandSep,
          decimals,
          dateFormat,
          startDay,
          appLocale,
          systemLocaleTick,
        ]),
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Trafin',
          locale: appLocaleOrNull,
          supportedLocales: supportedLocales,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: buildTheme(seedColor.value, Brightness.light),
          darkTheme: buildTheme(seedColor.value, Brightness.dark),
          themeMode: effectiveTrafinThemeMode,
          builder: (context, child) => Stack(
            fit: StackFit.expand,
            children: [
              child ?? const SizedBox.shrink(),
              ValueListenableBuilder<bool>(
                valueListenable: locked,
                builder: (c, on, _) => on
                    ? Positioned.fill(
                        child: Overlay(
                          initialEntries: [
                            OverlayEntry(builder: (_) => const LockScreen()),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
          home: Shell(
            acc: acc,
            onMode: (v) => setState(() => acc = v),
          ),
        ),
      );
}

ThemeData buildTheme(Color seed, Brightness b) {
  final cs = ColorScheme.fromSeed(seedColor: seed, brightness: b);
  final light = b == Brightness.light;
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    scaffoldBackgroundColor: light
        ? Color.alphaBlend(seed.withValues(alpha: .07), Colors.white)
        : Color.alphaBlend(seed.withValues(alpha: .14), const Color(0xFF1B1822)),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
            (st) => st.contains(WidgetState.selected) ? cs.onPrimaryContainer : cs.onSurface),
        backgroundColor: WidgetStateProperty.resolveWith(
            (st) => st.contains(WidgetState.selected) ? cs.primaryContainer : Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: cs.outline)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: light ? Colors.white : Color.alphaBlend(seed.withValues(alpha: .2), const Color(0xFF26222F)),
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
  );
}

class Shell extends StatefulWidget {
  final bool acc;
  final ValueChanged<bool> onMode;
  const Shell({super.key, required this.acc, required this.onMode});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int i = 0;

  @override
  Widget build(BuildContext context) {
    final acc = widget.acc;
    final cs = Theme.of(context).colorScheme;
    final pages = acc
        ? const [AccSummary(), JournalPage(), AccountsPage(), ReportsPage()]
        : const [HomePage(), TxPage(), MonthlyReportPage(), SavingsPage()];
    final dests = acc
        ? const [
            ('Ringkasan', Icons.space_dashboard_outlined),
            ('Jurnal', Icons.menu_book_outlined),
            ('Akun', Icons.account_tree_outlined),
            ('Laporan', Icons.assessment_outlined),
          ]
        : const [
            ('Home', Icons.home_outlined),
            ('Riwayat', Icons.receipt_long_outlined),
            ('Laporan', Icons.pie_chart_outline),
            ('Target', Icons.flag_outlined),
          ];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        actions: [
          // Mode pribadi: ekspor riwayat transaksi.
          if (i == 1 && !acc)
            IconButton(
              icon: const Icon(Icons.table_view_outlined),
              tooltip: tr('Ekspor ke Excel/CSV'),
              onPressed: () => exportTransactionsCsv(context),
            ),
          if (acc)
            IconButton(
              icon: const Icon(Icons.library_books_outlined),
              tooltip: tr('Buku Bisnis'),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BusinessBooksPage())),
            ),
          // Mode perusahaan: ekspor paket data akuntansi lengkap ke CSV yang bisa dibuka di Excel.
          if (acc)
            IconButton(
              icon: const Icon(Icons.table_view_outlined),
              tooltip: tr('Ekspor akuntansi ke Excel/CSV'),
              onPressed: () => exportCompanyAccountingCsv(context),
            ),
        ],
        title: Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.account_balance_wallet_outlined, size: 18, color: cs.onPrimary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              const Tr('Trafin', style: TextStyle(fontWeight: FontWeight.bold)),
              if (acc)
                ValueListenableBuilder<String>(
                  valueListenable: companyName,
                  builder: (context, n, _) => Text(
                    n.isEmpty ? tr('Bisnis Utama') : n,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
            ]),
          ),
        ]),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: false, icon: Icon(Icons.person_outline), label: Tr('Pribadi')),
                  ButtonSegment(value: true, icon: Icon(Icons.business_outlined), label: Tr('Perusahaan')),
                ],
                selected: {acc},
                onSelectionChanged: (s) {
                  setState(() => i = 0);
                  widget.onMode(s.first);
                },
              ),
            ),
          ),
        ),
      ),
      drawer: Drawer(
        child: ListView(padding: EdgeInsets.zero, children: [
          Container(
            padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 24, 20, 20),
            color: cs.primary,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.account_balance_wallet_outlined, size: 36, color: cs.onPrimary),
              const SizedBox(height: 12),
              Tr('Trafin', style: TextStyle(color: cs.onPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
              ValueListenableBuilder<String>(
                valueListenable: userName,
                builder: (c, n, _) => Text(n.isEmpty ? tr(acc ? 'Mode perusahaan' : 'Mode pribadi') : n,
                    style: TextStyle(color: cs.onPrimary.withValues(alpha: .85))),
              ),
              if (acc)
                ValueListenableBuilder<String>(
                  valueListenable: companyName,
                  builder: (c, n, _) => Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(n.isEmpty ? tr('Bisnis Utama') : n,
                        style: TextStyle(color: cs.onPrimary.withValues(alpha: .72), fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
            ]),
          ),
          for (var k = 0; k < dests.length; k++)
            ListTile(
              leading: Icon(dests[k].$2),
              title: Tr(dests[k].$1),
              selected: i == k,
              onTap: () {
                Navigator.pop(context);
                setState(() => i = k);
              },
            ),
          const Divider(),
          if (!acc) ...[
            for (final it in <(IconData, String, Widget)>[
              (Icons.donut_large_outlined, 'Anggaran', const BudgetPage()),
              (Icons.timer_outlined, 'Hutang', const DebtPage()),
              (Icons.account_balance_outlined, 'Rekening', const WalletPage()),
              (Icons.calendar_month_outlined, 'Kalender', const CalendarPage()),
              (Icons.autorenew, 'Transaksi terjadwal', const ScheduledPage()),
            ])
              ListTile(
                leading: Icon(it.$1),
                title: Tr(it.$2),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => it.$3));
                },
              ),
            const Divider(),
          ],
          if (acc) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
              child: Text(tr('PUSAT BISNIS'), style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.1)),
            ),
            for (final it in <(IconData, String, Widget)>[
              (Icons.business_center_outlined, 'Pusat Bisnis', const BusinessHubPage()),
              (Icons.receipt_long_outlined, 'Faktur & Piutang', const BusinessInvoicesPage()),
              (Icons.people_alt_outlined, 'Pelanggan & Pemasok', const BusinessContactsPage()),
              (Icons.inventory_2_outlined, 'Produk & Stok', const BusinessStockPage()),
            ])
              ListTile(
                leading: Icon(it.$1),
                title: Tr(it.$2),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => it.$3));
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Text(tr('ANALISIS & KONTROL'), style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.1)),
            ),
            for (final it in <(IconData, String, Widget)>[
              (Icons.insights_outlined, 'Analisis Bisnis', const BusinessAnalyticsPage()),
              (Icons.lock_clock_outlined, 'Kontrol Periode', const PeriodControlPage()),
              (Icons.fact_check_outlined, 'Checklist Bulanan', const MonthlyChecklistPage()),
            ])
              ListTile(
                leading: Icon(it.$1),
                title: Tr(it.$2),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(context, MaterialPageRoute(builder: (_) => it.$3));
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
              child: Text(tr('BELAJAR'), style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.1)),
            ),
            ListTile(
              leading: const Icon(Icons.school_outlined),
              title: const Tr('Jurnal Dibimbing'),
              onTap: () { Navigator.pop(context); showForm(context, const JournalForm()); },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Tr('Kamus Akuntansi'),
              onTap: () { Navigator.pop(context); Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountingGlossaryPage())); },
            ),
            const Divider(),
          ],
          ListTile(
            leading: const Icon(Icons.currency_exchange),
            title: const Tr('Kurs mata uang'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const RatesPage()));
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Tr('Pengaturan'),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsPage()));
            },
          ),
        ]),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          currency,
          symbolAfter,
          thousandSep,
          decimals,
          dateFormat,
          startDay,
          appLocale,
          systemLocaleTick,
        ]),
        builder: (context, _) => IndexedStack(
          index: i,
          children: pages,
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        shape: const CircleBorder(),
        tooltip: tr(acc ? 'Jurnal baru' : 'Catat transaksi'),
        onPressed: () => showForm(context, acc ? const JournalForm() : const TxForm()),
        child: const Icon(Icons.add, size: 30),
      ),
      bottomNavigationBar: BottomAppBar(
        color: Theme.of(context).brightness == Brightness.light ? Colors.white : Color.alphaBlend(cs.primary.withValues(alpha: .12), const Color(0xFF26222F)),
        surfaceTintColor: Colors.transparent,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        height: 64,
        padding: EdgeInsets.zero,
        child: Row(children: [
          for (var k = 0; k < dests.length; k++) ...[
            if (k == 2) const SizedBox(width: 72),
            Expanded(
              child: NavItem(dests[k].$2, dests[k].$1, i == k, () => setState(() => i = k)),
            ),
          ],
        ]),
      ),
    );
  }
}

class NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const NavItem(this.icon, this.label, this.selected, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = selected ? cs.primary : cs.onSurface.withValues(alpha: .8);
    return InkWell(
      onTap: onTap,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, color: color),
        const SizedBox(height: 2),
        Tr(label, style: TextStyle(fontSize: 11, color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
      ]),
    );
  }
}


class BusinessBooksPage extends StatelessWidget {
  const BusinessBooksPage({super.key});

  Future<void> _nameDialog(BuildContext context, {BusinessBook? book}) async {
    final c = TextEditingController(text: book?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Tr(book == null ? 'Buku Bisnis baru' : 'Ubah nama Buku Bisnis'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: deco('Nama bisnis'),
          onSubmitted: (v) => Navigator.pop(d, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Tr('Batal')),
          FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Tr('Simpan')),
        ],
      ),
    );
    c.dispose();
    if (result == null || result.trim().isEmpty) return;
    if (book == null) {
      createBusinessBook(result);
    } else {
      if (book.id != activeBusinessBookId.value) switchBusinessBook(book.id);
      renameActiveBusinessBook(result);
    }
  }

  Future<void> _delete(BuildContext context, BusinessBook book) async {
    if (businessBooks.value.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Minimal harus ada satu Buku Bisnis.')));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Tr('Hapus Buku Bisnis?'),
        content: Text(tr('Semua jurnal dan akun di "{name}" akan dihapus dari aplikasi.', {'name': book.name})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Tr('Batal')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Tr('Hapus')),
        ],
      ),
    );
    if (ok == true) deleteBusinessBook(book.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Buku Bisnis')),
        body: ListenableBuilder(
          listenable: Listenable.merge([businessBooks, activeBusinessBookId]),
          builder: (context, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
            children: [
              pageHeader(context, 'Buku Bisnis', 'Buku baru', Icons.add, () => _nameDialog(context)),
              const SizedBox(height: 4),
              Tr(
                'Setiap buku menyimpan akun, saldo, dan jurnalnya sendiri. Cocok jika kamu mengelola lebih dari satu usaha.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              for (final b in businessBooks.value)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Icon(b.id == activeBusinessBookId.value ? Icons.check : Icons.business_outlined),
                    ),
                    title: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(tr('{n} jurnal • dibuat {d}', {'n': b.journals.length, 'd': dateFull(b.createdAt)})),
                    selected: b.id == activeBusinessBookId.value,
                    onTap: () {
                      switchBusinessBook(b.id);
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(SnackBar(content: Text(tr('Beralih ke {name}', {'name': b.name}))));
                    },
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'rename') _nameDialog(context, book: b);
                        if (v == 'delete') _delete(context, b);
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Row(children: [Icon(Icons.edit_outlined), SizedBox(width: 10), Tr('Ubah nama')])),
                        PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline), SizedBox(width: 10), Tr('Hapus')])),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

// ───────────────────────── Form ─────────────────────────

void showForm(BuildContext c, Widget form) => showModalBottomSheet(
      context: c,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: form,
      ),
    );

InputDecoration deco(String label, {String? err, bool money = false}) => InputDecoration(
      labelText: tr(label),
      errorText: err == null ? null : tr(err),
      prefixText: money && !symbolAfter.value ? '${currency.value} ' : null,
      suffixText: money && symbolAfter.value ? ' ${currency.value}' : null,
      border: const OutlineInputBorder(),
    );

/// Menambahkan pemisah ribuan selagi mengetik: 30000 -> 30.000.
/// Kursor dikembalikan ke posisi digit yang sama sehingga mengedit di tengah
/// angka tidak membuat caret selalu melompat ke ujung.
class MoneyGroupingInputFormatter extends TextInputFormatter {
  final String groupSeparator;
  final bool allowDecimals;
  const MoneyGroupingInputFormatter(this.groupSeparator, {this.allowDecimals = false});

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    // Tunggu proses IME/composition agar tidak mengganggu keyboard pengguna.
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) return newValue;
    final incoming = newValue.text;
    if (incoming.isEmpty) return const TextEditingValue();
    final decimalSeparator = groupSeparator == ',' ? '.' : ',';
    final cut = allowDecimals ? incoming.indexOf(decimalSeparator) : -1;
    final wholeEnd = cut < 0 ? incoming.length : cut;
    final wholeSource = incoming.substring(0, wholeEnd);
    final wholeDigits = wholeSource.replaceAll(RegExp(r'[^0-9]'), '');
    final fractionDigits = cut < 0 ? '' : incoming.substring(cut + 1)
        .replaceAll(RegExp(r'[^0-9]'), '');
    final fraction = fractionDigits.substring(0, math.min(2, fractionDigits.length));
    final grouped = StringBuffer();
    for (var i = 0; i < wholeDigits.length; i++) {
      if (i > 0 && (wholeDigits.length - i) % 3 == 0) grouped.write(groupSeparator);
      grouped.write(wholeDigits[i]);
    }
    final integerText = wholeDigits.isEmpty && cut >= 0 ? '0' : grouped.toString();
    final result = cut < 0 ? integerText : '$integerText$decimalSeparator$fraction';
    final caret = newValue.selection.extentOffset.clamp(0, incoming.length).toInt();
    int resultCaret;
    if (caret <= wholeEnd) {
      final digitCount = incoming.substring(0, caret).replaceAll(RegExp(r'[^0-9]'), '').length;
      resultCaret = 0;
      var count = 0;
      for (var i = 0; i < integerText.length && count < digitCount; i++) {
        if (RegExp(r'[0-9]').hasMatch(integerText[i])) count++;
        resultCaret = i + 1;
      }
    } else {
      final fracCaret = incoming.substring(cut + 1, caret)
          .replaceAll(RegExp(r'[^0-9]'), '').length;
      resultCaret = integerText.length + 1 + math.min(fracCaret, fraction.length);
    }
    return TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: resultCaret.clamp(0, result.length).toInt()),
      composing: TextRange.empty,
    );
  }
}

Widget moneyField(TextEditingController c, String label, String? err) => ListenableBuilder(
      listenable: Listenable.merge([currency, decimals, thousandSep]),
      builder: (context, _) {
        final d = decimals.value;
        return TextField(
          controller: c,
          keyboardType: TextInputType.numberWithOptions(decimal: d > 0),
          inputFormatters: [MoneyGroupingInputFormatter(thousandSep.value, allowDecimals: d > 0)],
          decoration: deco(label, err: err, money: true),
        );
      },
    );

Widget formBody(BuildContext c, String title, List<Widget> kids, VoidCallback onSave) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Tr(title, style: Theme.of(c).textTheme.titleLarge),
        const SizedBox(height: 16),
        for (final k in kids) ...[k, const SizedBox(height: 12)],
        FilledButton(onPressed: onSave, child: const Tr('Simpan')),
      ],
    );

Color tone(BuildContext c, MaterialColor m) =>
    Theme.of(c).brightness == Brightness.dark ? m.shade200 : m.shade700;

String dateLabel([DateTime? at]) {
  final d = at ?? DateTime.now();
  if (dateFormat.value == 1) {
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }
  return tr('dm', {'d': d.day, 'm': tr('s${d.month}')});
}

String dateFull(DateTime d) => dateFormat.value == 1
    ? '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}'
    : '${dateLabel(d)} ${d.year}';

IconData iconFor(String cat) =>
    const {
      'Makanan': Icons.restaurant_outlined,
      'Transport': Icons.directions_car_outlined,
      'Tagihan': Icons.bolt_outlined,
      'Belanja': Icons.shopping_basket_outlined,
      'Hiburan': Icons.movie_outlined,
      'Gaji': Icons.payments_outlined,
      'Sampingan': Icons.work_outline,
      'Hadiah': Icons.card_giftcard_outlined,
    }[cat] ??
    Icons.category_outlined;

class TxForm extends StatefulWidget {
  const TxForm({super.key});
  @override
  State<TxForm> createState() => _TxFormState();
}

class _TxFormState extends State<TxForm> {
  bool income = false;
  String? cat, amtErr, catErr;
  DateTime when = DateTime.now();
  String wallet = wallets.value.isEmpty ? '' : wallets.value.first.name;
  final amt = TextEditingController();
  final note = TextEditingController();

  @override
  void dispose() {
    amt.dispose();
    note.dispose();
    super.dispose();
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: when,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
    );
    if (d != null && mounted) setState(() => when = d);
  }

  void save() {
    final n = parseMoney(amt.text);
    final c = cat;
    setState(() {
      amtErr = n <= 0 ? 'Isi nominal lebih dari 0' : null;
      catErr = c == null ? 'Pilih kategori' : null;
    });
    if (n <= 0 || c == null) return;
    final title = note.text.trim().isEmpty ? c : note.text.trim();
    txs.value = [Tx(title, c, when, n, income, iconFor(c), wallet), ...txs.value]..sort((a, b) => b.when.compareTo(a.when));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => formBody(context, 'Catat transaksi', [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.arrow_upward), label: Tr('Pengeluaran')),
            ButtonSegment(value: true, icon: Icon(Icons.arrow_downward), label: Tr('Pemasukan')),
          ],
          selected: {income},
          onSelectionChanged: (s) => setState(() {
            income = s.first;
            cat = null;
          }),
        ),
        moneyField(amt, 'Nominal', amtErr),
        CategoryField(
          key: ValueKey(income),
          income: income,
          value: cat,
          error: catErr,
          onChanged: (v) => setState(() {
            cat = v;
            catErr = null;
          }),
        ),
        if (wallets.value.isNotEmpty)
          DropdownButtonFormField<String>(
            value: wallet,
            decoration: deco('Rekening'),
            items: [for (final w in wallets.value) DropdownMenuItem(value: w.name, child: Text(tr(w.name)))],
            onChanged: (v) => setState(() => wallet = v ?? wallet),
          ),
        OutlinedButton.icon(
          onPressed: pickDate,
          icon: const Icon(Icons.event_outlined),
          label: Text(tr('Tanggal: {d}', {'d': dateFull(when)})),
        ),
        TextField(controller: note, decoration: deco('Catatan (opsional)')),
      ], save);
}

class GoalForm extends StatefulWidget {
  const GoalForm({super.key});
  @override
  State<GoalForm> createState() => _GoalFormState();
}

class _GoalFormState extends State<GoalForm> {
  final name = TextEditingController();
  final target = TextEditingController();
  final deadline = TextEditingController();
  String? nameErr, targetErr;

  @override
  void dispose() {
    name.dispose();
    target.dispose();
    deadline.dispose();
    super.dispose();
  }

  void save() {
    final n = parseMoney(target.text);
    final nm = name.text.trim();
    setState(() {
      nameErr = nm.isEmpty ? 'Isi nama target' : null;
      targetErr = n <= 0 ? 'Isi nominal lebih dari 0' : null;
    });
    if (nm.isEmpty || n <= 0) return;
    goals.value = [...goals.value, Goal(nm, 0, n, deadline.text.trim(), Icons.flag_outlined)];
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => formBody(context, 'Target tabungan baru', [
        TextField(controller: name, decoration: deco('Nama target', err: nameErr)),
        moneyField(target, 'Nominal target', targetErr),
        TextField(controller: deadline, decoration: deco('Tenggat (opsional, mis. Des 2026)')),
      ], save);
}

class DepositForm extends StatefulWidget {
  final Goal goal;
  const DepositForm(this.goal, {super.key});
  @override
  State<DepositForm> createState() => _DepositFormState();
}

class _DepositFormState extends State<DepositForm> {
  final amt = TextEditingController();
  String? err;

  @override
  void dispose() {
    amt.dispose();
    super.dispose();
  }

  void save() {
    final n = parseMoney(amt.text);
    if (n <= 0) {
      setState(() => err = 'Isi nominal lebih dari 0');
      return;
    }
    final g = widget.goal;
    goals.value = [
      for (final x in goals.value) x == g ? Goal(g.name, g.saved + n, g.target, g.deadline, g.icon) : x,
    ];
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) =>
      formBody(context, tr('Setor ke {name}', {'name': widget.goal.name}), [moneyField(amt, 'Nominal setoran', err)], save);
}

class JournalForm extends StatefulWidget {
  const JournalForm({super.key});
  @override
  State<JournalForm> createState() => _JournalFormState();
}

class _JournalFormState extends State<JournalForm> {
  final desc = TextEditingController();
  final amt = TextEditingController();
  String? debit, credit, amtErr, accErr;
  bool guided = true;
  String preset = 'sale';
  DateTime when = DateTime.now();

  static const presetLabels = <String, String>{
    'sale': 'Penjualan tunai',
    'expense': 'Bayar beban',
    'capital': 'Setoran modal pemilik',
    'inventory': 'Beli persediaan tunai',
    'equipment': 'Beli peralatan tunai',
    'loan': 'Terima pinjaman bank',
    'receivable': 'Terima pembayaran piutang',
    'payable': 'Bayar utang usaha',
  };

  @override
  void initState() {
    super.initState();
    _applyPreset();
  }

  @override
  void dispose() {
    desc.dispose();
    amt.dispose();
    super.dispose();
  }

  bool _has(String name) => accounts.value.any((a) => a.name == name);

  String? _firstOfType(String type) {
    for (final a in accounts.value) {
      if (a.type == type) return a.name;
    }
    return null;
  }

  void _applyPreset() {
    String? d, c;
    switch (preset) {
      case 'sale':
        d = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        c = _has('Penjualan') ? 'Penjualan' : _firstOfType('Pendapatan');
        break;
      case 'expense':
        d = _has('Beban Lain-lain') ? 'Beban Lain-lain' : _firstOfType('Beban');
        c = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        break;
      case 'capital':
        d = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        c = _has('Modal Saham') ? 'Modal Saham' : _firstOfType('Ekuitas');
        break;
      case 'inventory':
        d = _has('Persediaan') ? 'Persediaan' : _firstOfType('Aset');
        c = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        break;
      case 'equipment':
        d = _has('Peralatan (neto)') ? 'Peralatan (neto)' : _firstOfType('Aset');
        c = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        break;
      case 'loan':
        d = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        c = _has('Utang Bank') ? 'Utang Bank' : _firstOfType('Liabilitas');
        break;
      case 'receivable':
        d = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        c = _has('Piutang Usaha') ? 'Piutang Usaha' : _firstOfType('Aset');
        break;
      case 'payable':
        d = _has('Utang Usaha') ? 'Utang Usaha' : _firstOfType('Liabilitas');
        c = _has('Kas') ? 'Kas' : _firstOfType('Aset');
        break;
    }
    debit = d;
    credit = c;
    desc.text = tr(presetLabels[preset] ?? 'Transaksi');
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: when,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (d != null && mounted) setState(() => when = d);
  }

  Acc? _account(String? name) {
    if (name == null) return null;
    for (final a in accounts.value) {
      if (a.name == name) return a;
    }
    return null;
  }

  String _normalSide(Acc? a) {
    if (a == null) return '';
    return (a.type == 'Aset' || a.type == 'Beban')
        ? tr('{type} normalnya bertambah di Debit', {'type': tr(a.type)})
        : tr('{type} normalnya bertambah di Kredit', {'type': tr(a.type)});
  }

  void save() {
    final n = parseMoney(amt.text);
    final d = debit, c = credit;
    if (isCompanyPeriodClosed(when)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Periode tanggal jurnal ini sudah dikunci. Buka kembali periode untuk mengubah pembukuan.')));
      return;
    }
    setState(() {
      amtErr = n <= 0 ? 'Isi nominal lebih dari 0' : null;
      accErr = (d == null || c == null)
          ? 'Pilih akun debit dan kredit'
          : d == c
              ? 'Akun debit dan kredit harus berbeda'
              : null;
    });
    if (n <= 0 || d == null || c == null || d == c) return;
    final j = Journal(
      DateTime(when.year, when.month, when.day),
      desc.text.trim().isEmpty ? 'Transaksi' : desc.text.trim(),
      [(d, n, 0), (c, 0, n)],
    );
    journals.value = [j, ...journals.value]..sort((a, b) => b.when.compareTo(a.when));
    applyJournal(j, 1);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final a in accounts.value) DropdownMenuItem(value: a.name, child: Text('${a.code}  ${tr(a.name)}')),
    ];
    return formBody(context, 'Jurnal baru', [
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: true, icon: Icon(Icons.school_outlined), label: Tr('Dibimbing')),
            ButtonSegment(value: false, icon: Icon(Icons.tune), label: Tr('Manual')),
          ],
          selected: {guided},
          onSelectionChanged: (v) => setState(() => guided = v.first),
        ),
      ),
      if (guided)
        DropdownButtonFormField<String>(
          value: preset,
          decoration: deco('Jenis transaksi'),
          items: [
            for (final e in presetLabels.entries) DropdownMenuItem(value: e.key, child: Text(tr(e.value))),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              preset = v;
              _applyPreset();
              accErr = null;
            });
          },
        ),
      TextField(controller: desc, decoration: deco('Keterangan')),
      DropdownButtonFormField<String>(
        value: debit,
        isExpanded: true,
        decoration: deco(guided ? 'Debit • akun yang menerima sisi debit' : 'Akun debit', err: accErr),
        items: items,
        onChanged: (v) => setState(() {
          debit = v;
          accErr = null;
        }),
      ),
      if (guided && debit != null)
        Text(_normalSide(_account(debit)), style: Theme.of(context).textTheme.bodySmall),
      DropdownButtonFormField<String>(
        value: credit,
        isExpanded: true,
        decoration: deco(guided ? 'Kredit • akun yang menerima sisi kredit' : 'Akun kredit'),
        items: items,
        onChanged: (v) => setState(() {
          credit = v;
          accErr = null;
        }),
      ),
      if (guided && credit != null)
        Text(_normalSide(_account(credit)), style: Theme.of(context).textTheme.bodySmall),
      moneyField(amt, 'Nominal', amtErr),
      OutlinedButton.icon(
        onPressed: pickDate,
        icon: const Icon(Icons.event_outlined),
        label: Text(tr('Tanggal: {d}', {'d': dateFull(when)})),
      ),
      if (guided)
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lightbulb_outline),
              const SizedBox(width: 10),
              Expanded(
                child: Tr(
                  'Trafin selalu mencatat jumlah Debit = Kredit. Ini menjaga persamaan Aset = Liabilitas + Ekuitas tetap konsisten.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ]),
          ),
        ),
    ], save);
  }
}

// ───────────────────────── Mode keuangan ─────────────────────────

class Heading extends StatelessWidget {
  final String text;
  const Heading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Tr(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
      );
}

class TxTile extends StatelessWidget {
  final Tx t;
  const TxTile(this.t, {super.key});
  @override
  Widget build(BuildContext context) {
    final color = tone(context, t.income ? Colors.green : Colors.red);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: .12),
        child: Icon(t.icon, color: color),
      ),
      title: Text(t.title == t.cat ? tr(t.cat) : t.title),
      subtitle: Text('${tr(t.cat)} • ${t.date}${t.wallet.isEmpty ? '' : ' • ${tr(t.wallet)}'}'),
      trailing: Text('${t.income ? '+' : '-'}${rp(t.amt)}',
          style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([txs, wallets]),
        builder: (context, _) => _body(context, txs.value),
      );

  Widget _body(BuildContext context, List<Tx> list) {
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final cur = periodOf(now);
    final month = list.where((t) => periodOf(t.when) == cur);
    final inc = month.where((t) => t.income).fold<num>(0, (s, t) => s + t.amt);
    final exp = month.where((t) => !t.income).fold<num>(0, (s, t) => s + t.amt);
    final saldo = totalBalance(list);
    final pct = inc > 0 ? (exp / inc * 100).round() : null;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
      ValueListenableBuilder<String>(
        valueListenable: userName,
        builder: (c, n, _) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.trim().isEmpty ? 'Halo!' : 'Halo, ${n.trim()}!',
                style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('Yuk kelola keuanganmu lebih baik.',
                style: Theme.of(c).textTheme.bodyMedium),
          ]),
        ),
      ),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [cs.primary, Color.lerp(cs.primary, cs.tertiary, .6)!],
          ),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: cs.onPrimary.withValues(alpha: .18), borderRadius: BorderRadius.circular(20)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.account_balance_wallet_outlined, size: 14, color: cs.onPrimary),
                const SizedBox(width: 6),
                Tr('Trafin', style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
              ]),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(periodLabel(cur), textAlign: TextAlign.end, maxLines: 2,
                style: TextStyle(color: cs.onPrimary.withValues(alpha: .85), fontSize: 12))),
          ]),
          const SizedBox(height: 16),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Tr('Saldo bersih', style: TextStyle(color: cs.onPrimary.withValues(alpha: .8))),
                const SizedBox(height: 4),
                FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text(rp(saldo),
                      style: TextStyle(color: cs.onPrimary, fontSize: 32, fontWeight: FontWeight.bold)),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(flex: 4, child: _HomeWalletPreview(transactions: list)),
          ]),
        ]),
      ),
      const Heading('Bulan ini'),
      Row(children: [
        Expanded(child: StatCard('Pemasukan', rp(inc), tone(context, Colors.green), Icons.south_west)),
        const SizedBox(width: 12),
        Expanded(child: StatCard('Pengeluaran', rp(exp), tone(context, Colors.red), Icons.north_east)),
      ]),
      if (pct != null)
        ValueListenableBuilder<bool>(
          valueListenable: showIndicator,
          builder: (c, on, _) => on
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: cs.inverseSurface, borderRadius: BorderRadius.circular(16)),
                    child: Row(children: [
                      Icon(Icons.info_outline, color: cs.onInverseSurface),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(tr('{pct}% pemasukan bulan ini sudah terpakai', {'pct': pct}),
                            style: TextStyle(color: cs.onInverseSurface, fontWeight: FontWeight.w600)),
                      ),
                    ]),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      const Heading('Target tabungan'),
      ValueListenableBuilder<List<Goal>>(
        valueListenable: goals,
        builder: (c, gs, _) => gs.isEmpty ? const Tr('Belum ada target tabungan') : GoalCard(gs.first),
      ),
      const Heading('Transaksi terakhir'),
      if (list.isEmpty) const EmptyState() else for (final t in list.take(5)) TxTile(t),
    ]);
  }
}

/// Semua rekening menggunakan nama yang dibuat pengguna. Jika lebih dari tiga,
/// daftar dapat digulir tanpa meninggalkan beranda.
class _HomeWalletPreview extends StatelessWidget {
  final List<Tx> transactions;
  const _HomeWalletPreview({required this.transactions});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = wallets.value;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.onPrimary.withValues(alpha: .11),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WalletPage())),
          child: Row(children: [
            Expanded(child: Text('Rekening', style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.w600))),
            Icon(Icons.open_in_new, size: 14, color: cs.onPrimary),
          ]),
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          Text('Belum ada rekening', style: TextStyle(color: cs.onPrimary, fontSize: 11))
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: items.length,
              itemBuilder: (context, index) {
                final w = items[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(w.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.onPrimary.withValues(alpha: .87), fontSize: 11)),
                    Text(rp(walletBalance(w, transactions)), maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: cs.onPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
                  ]),
                );
              },
            ),
          ),
        if (unassignedWalletTransactions(transactions).isNotEmpty) ...[
          const SizedBox(height: 7),
          Text('Tanpa rekening aktif', style: TextStyle(color: cs.onPrimary.withValues(alpha: .87), fontSize: 11)),
          Text(rp(unassignedWalletBalance(transactions)),
              style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      ]),
    );
  }
}

class StatCard extends StatelessWidget {
  final String label, value;
  final Color color;
  final IconData icon;
  const StatCard(this.label, this.value, this.color, this.icon, {super.key});
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: 6), Tr(label)]),
            const SizedBox(height: 6),
            Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      );
}

class TxPage extends StatefulWidget {
  const TxPage({super.key});
  @override
  State<TxPage> createState() => _TxPageState();
}

class _TxPageState extends State<TxPage> {
  int f = 0; // 0 semua, 1 masuk, 2 keluar
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Tx>>(
        valueListenable: txs,
        builder: (context, all, _) {
          final list = all.where((t) => f == 0 || (f == 1) == t.income).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            Wrap(spacing: 8, children: [
              for (final e in const ['Semua', 'Pemasukan', 'Pengeluaran'].asMap().entries)
                ChoiceChip(label: Tr(e.value), selected: f == e.key, onSelected: (_) => setState(() => f = e.key)),
            ]),
            const SizedBox(height: 12),
            Tr('Geser ke kiri untuk menghapus satu transaksi', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            if (list.isEmpty)
              const EmptyState()
            else
              for (final t in list) SwipeDelete<Tx>(store: txs, item: t, label: t.title, gap: 0, radius: 0, child: TxTile(t)),
          ]);
        },
      );
}

/// Batasi jendela Urungkan hingga tiga detik, termasuk pada perangkat
/// dengan pembaca layar (Snackbar dengan action biasanya bisa menetap).
final Map<ScaffoldMessengerState, int> _undoSnackGeneration = {};

void removeWithUndo<T>(
  BuildContext context,
  ValueNotifier<List<T>> store,
  T item,
  String label, {
  VoidCallback? onRemoved,
  VoidCallback? onRestored,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final idx = store.value.indexOf(item);
  if (idx < 0) return;
  store.value = [...store.value]..remove(item);
  onRemoved?.call();

  final generation = (_undoSnackGeneration[messenger] ?? 0) + 1;
  _undoSnackGeneration[messenger] = generation;
  messenger.removeCurrentSnackBar();
  final notice = messenger.showSnackBar(SnackBar(
    duration: const Duration(seconds: 3),
    content: Text(tr('"{label}" dihapus', {'label': label})),
    action: SnackBarAction(
      label: tr('Urungkan'),
      onPressed: () {
        if (_undoSnackGeneration[messenger] != generation) return;
        _undoSnackGeneration.remove(messenger);
        if (store.value.contains(item)) return;
        final at = idx.clamp(0, store.value.length).toInt();
        store.value = [...store.value]..insert(at, item);
        onRestored?.call();
      },
    ),
  ));
  Timer(const Duration(seconds: 3), () {
    if (_undoSnackGeneration[messenger] != generation) return;
    _undoSnackGeneration.remove(messenger);
    if (messenger.mounted) notice.close();
  });
}

/// Geser ke kiri untuk menghapus satu item (bisa diurungkan).
class SwipeDelete<T> extends StatelessWidget {
  final ValueNotifier<List<T>> store;
  final T item;
  final String label;
  final Widget child;
  final double gap, radius;
  final VoidCallback? onRemoved, onRestored;
  final ConfirmDismissCallback? confirmDismiss;
  const SwipeDelete({
    super.key,
    required this.store,
    required this.item,
    required this.label,
    required this.child,
    this.gap = 12,
    this.radius = 12,
    this.onRemoved,
    this.onRestored,
    this.confirmDismiss,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: gap),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Dismissible(
            key: ObjectKey(item),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red.shade700,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete_outline, color: Colors.white),
            ),
            confirmDismiss: confirmDismiss,
            onDismissed: (_) => removeWithUndo(context, store, item, label, onRemoved: onRemoved, onRestored: onRestored),
            child: child,
          ),
        ),
      );
}

class EmptyState extends StatelessWidget {
  final String title, hint;
  final IconData icon;
  const EmptyState({
    super.key,
    this.title = 'Belum ada transaksi',
    this.hint = 'Tekan tombol + untuk menambah transaksi pertama',
    this.icon = Icons.receipt_long_outlined,
  });
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Column(children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Tr(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Tr(hint, textAlign: TextAlign.center),
          ]),
        ),
      );
}

class GoalCard extends StatelessWidget {
  final Goal g;
  const GoalCard(this.g, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = g.saved / g.target;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(child: Icon(g.icon)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                Text(g.deadline.isEmpty ? tr('Tanpa tenggat') : tr('Tenggat {d}', {'d': g.deadline}), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            Text('${(p * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 14),
          LinearProgressIndicator(value: (p > 1 ? 1 : p).toDouble(), minHeight: 10, borderRadius: BorderRadius.circular(8)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(tr('{a} dari {b}', {'a': rp(g.saved), 'b': rp(g.target)})),
            TextButton.icon(
              onPressed: () => showForm(context, DepositForm(g)),
              icon: const Icon(Icons.add, size: 18),
              label: const Tr('Setor'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class SavingsPage extends StatelessWidget {
  const SavingsPage({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Goal>>(
        valueListenable: goals,
        builder: (context, list, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
          Row(children: [
            Expanded(child: Tr('Target tabungan', style: Theme.of(context).textTheme.titleLarge)),
            FilledButton.tonalIcon(
              onPressed: () => showForm(context, const GoalForm()),
              icon: const Icon(Icons.flag_outlined),
              label: const Tr('Target baru'),
            ),
          ]),
          const SizedBox(height: 16),
          if (list.isEmpty)
            const EmptyState(
              title: 'Belum ada target tabungan',
              hint: 'Tekan Target baru untuk membuat target',
              icon: Icons.savings_outlined,
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Tr('Geser ke kiri untuk menghapus target yang batal', style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final g in list) SwipeDelete<Goal>(store: goals, item: g, label: g.name, child: GoalCard(g)),
          ],
        ]),
      );
}

class DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final Color track;
  final double progress;
  DonutPainter(this.values, this.colors, this.track, this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2;
    final stroke = r * 0.3;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r - stroke / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total == 0) {
      canvas.drawArc(rect, 0, math.pi * 2, false, p..color = track);
      return;
    }
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2 * progress;
      final gap = values.length > 1 ? 0.03 : 0.0;
      canvas.drawArc(rect, start, math.max(sweep - gap, 0.001), false, p..color = colors[i % colors.length]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant DonutPainter old) => true;
}


class SixMonthComparisonCard extends StatelessWidget {
  final List<Tx> all;
  const SixMonthComparisonCard(this.all, {super.key});

  @override
  Widget build(BuildContext context) {
    final current = periodOf(DateTime.now());
    final periods = [for (var i = 5; i >= 0; i--) DateTime(current.year, current.month - i)];
    final incomes = <num>[];
    final expenses = <num>[];
    for (final p in periods) {
      incomes.add(all.where((t) => t.income && periodOf(t.when) == p).fold<num>(0, (a, t) => a + t.amt));
      expenses.add(all.where((t) => !t.income && periodOf(t.when) == p).fold<num>(0, (a, t) => a + t.amt));
    }
    final values = [...incomes, ...expenses];
    final maxValue = values.isEmpty ? 0 : values.reduce(math.max);
    final incomeColor = tone(context, Colors.green);
    final expenseColor = tone(context, Colors.red);

    Widget bar(num value, Color color, double maxHeight) {
      final h = maxValue == 0 ? 0.0 : (value / maxValue * maxHeight).clamp(0, maxHeight).toDouble();
      return Tooltip(
        message: rp(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          height: value > 0 ? math.max(4, h) : 2,
          decoration: BoxDecoration(
            color: value > 0 ? color : color.withValues(alpha: .16),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Tr('Pemasukan vs pengeluaran • 6 bulan terakhir',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const Icon(Icons.bar_chart_outlined),
          ]),
          const SizedBox(height: 4),
          Tr('Sentuh batang untuk melihat nominal.', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 14),
          SizedBox(
            height: 150,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < periods.length; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, c) => Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            Expanded(child: bar(incomes[i], incomeColor, c.maxHeight)),
                            const SizedBox(width: 3),
                            Expanded(child: bar(expenses[i], expenseColor, c.maxHeight)),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(tr('s${periods[i].month}'), style: const TextStyle(fontSize: 11)),
                    ]),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: incomeColor, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            const Tr('Pemasukan', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 18),
            Container(width: 10, height: 10, decoration: BoxDecoration(color: expenseColor, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            const Tr('Pengeluaran', style: TextStyle(fontSize: 12)),
          ]),
        ]),
      ),
    );
  }
}

class MonthlyReportPage extends StatefulWidget {
  const MonthlyReportPage({super.key});
  @override
  State<MonthlyReportPage> createState() => _MonthlyReportPageState();
}

class _MonthlyReportPageState extends State<MonthlyReportPage> {
  static const palette = [
    Color(0xFF22C55E),
    Color(0xFFEC4899),
    Color(0xFFF97316),
    Color(0xFF3B82F6),
    Color(0xFFEAB308),
    Color(0xFF8B5CF6),
    Color(0xFF14B8A6),
    Color(0xFFEF4444),
  ];
  DateTime month = periodOf(DateTime.now());
  bool income = false;

  void shift(int d) => setState(() => month = DateTime(month.year, month.month + d));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ValueListenableBuilder<List<Tx>>(
      valueListenable: txs,
      builder: (context, all, _) {
        final list = all.where((t) => periodOf(t.when) == month && t.income == income).toList();
        final byCat = <String, num>{};
        for (final t in list) {
          byCat[t.cat] = (byCat[t.cat] ?? 0) + t.amt;
        }
        final entries = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
        final total = list.fold<num>(0, (s, t) => s + t.amt);
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
          Tr('Laporan bulanan', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Card(
            child: Row(children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => shift(-1)),
              Expanded(
                child: Center(child: Text(periodLabel(month), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
              ),
              IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => shift(1)),
            ]),
          ),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Tr('Pengeluaran')),
                ButtonSegment(value: true, label: Tr('Pemasukan')),
              ],
              selected: {income},
              onSelectionChanged: (s) => setState(() => income = s.first),
            ),
          ),
          const SizedBox(height: 12),
          SixMonthComparisonCard(all),
          Card(
            child: SizedBox(
              height: 240,
              child: Stack(alignment: Alignment.center, children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey('${month.year}-${month.month}-$income-${list.length}'),
                      tween: Tween(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.easeOutCubic,
                      builder: (c, v, _) => CustomPaint(
                        painter: DonutPainter(
                          [for (final e in entries) e.value.toDouble()],
                          palette,
                          cs.outlineVariant.withValues(alpha: .4),
                          v,
                        ),
                      ),
                    ),
                  ),
                ),
                Column(mainAxisSize: MainAxisSize.min, children: [
                  Tr(income ? 'Total pemasukan' : 'Total pengeluaran', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 2),
                  Text(rp(total), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ]),
              ]),
            ),
          ),
          Heading(income ? 'Semua pemasukan' : 'Semua pengeluaran'),
          if (entries.isEmpty)
            const EmptyState(
              title: 'Belum ada data bulan ini',
              hint: 'Catat transaksi dengan tombol + atau pilih bulan lain',
              icon: Icons.pie_chart_outline,
            )
          else
            for (var i = 0; i < entries.length; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(children: [
                    Row(children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(color: palette[i % palette.length], shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(tr(entries[i].key), style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(rp(entries[i].value), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: LinearProgressIndicator(
                          value: (entries[i].value / total).toDouble(),
                          minHeight: 6,
                          color: palette[i % palette.length],
                          backgroundColor: palette[i % palette.length].withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${(entries[i].value / total * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ]),
                ),
              ),
        ]);
      },
    );
  }
}

/// Pemilih tema adaptif: tiap opsi menggunakan lebar alaminya.
/// Berbeda dari SegmentedButton yang membagi lebar sama rata, Wrap akan
/// memindahkan satu *opsi utuh* ke baris berikutnya jika ruang tidak cukup.
/// Dengan begitu label seperti "Default" tidak pecah menjadi "Defaul" / "t".
class TrafinThemeSelector extends StatelessWidget {
  const TrafinThemeSelector({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => ListenableBuilder(
          listenable: themeMode,
          builder: (context, _) => Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in const <(ThemeMode, String, IconData)>[
                (ThemeMode.light, 'Terang', Icons.light_mode_outlined),
                (ThemeMode.dark, 'Gelap', Icons.dark_mode_outlined),
                (ThemeMode.system, 'Default', Icons.restart_alt),
              ])
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                  child: ChoiceChip(
                    avatar: Icon(option.$3, size: 18),
                    label: Tr(option.$2),
                    selected: themeMode.value == option.$1,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    onSelected: (selected) {
                      if (!selected) return;
                      if (option.$1 == ThemeMode.system) {
                        restoreDefaultTrafinTheme();
                      } else {
                        themeMode.value = option.$1;
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      );
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const swatches = [
    ('Ungu', Color(0xFF7B5CF0)),
    ('Biru', Color(0xFF2F6BFF)),
    ('Hijau', Color(0xFF00A98F)),
    ('Pink', Color(0xFFE0457B)),
    ('Oranye', Color(0xFFF57C00)),
  ];
  final nameC = TextEditingController(text: userName.value);
  final compC = TextEditingController(text: companyName.value);

  @override
  void dispose() {
    nameC.dispose();
    compC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Pengaturan')),
        body: ListenableBuilder(
          listenable: Listenable.merge([themeMode, seedColor, showIndicator, currency, currencyCode, displayFxRate, symbolAfter, thousandSep, dateFormat, startDay, pin, appLocale, systemLocaleTick]),
          builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            const Heading('Pengaturan dasar'),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.language),
                  title: const Tr('Bahasa'),
                  subtitle: Text(langLabel()),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LanguagePage())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Tr('Mata uang'),
                  subtitle: Text('${currencyCode.value} (${currency.value}) • ${tr(symbolAfter.value ? 'simbol di belakang' : 'simbol di depan')} • ${rp(1234567)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showForm(context, const CurrencySheet()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.event_outlined),
                  title: const Tr('Tanggal'),
                  subtitle: Text(tr('Format {f} • periode mulai tanggal {d}', {'f': dateFull(DateTime.now()), 'd': startDay.value})),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showForm(context, const DateSheet()),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Tr('Keamanan'),
                  subtitle: Tr(pin.value == null ? 'Kunci PIN nonaktif' : 'Kunci PIN aktif'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityPage())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Tr('Cadangan data'),
                  subtitle: const Tr('Salin dan pulihkan seluruh datamu'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupPage())),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.school_outlined),
                  title: const Tr('Tutorial Trafin'),
                  subtitle: const Tr('Panduan fitur, langkah pemakaian, dan contoh sederhana'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TrafinTutorialPage())),
                ),
              ]),
            ),
            const Heading('Tampilan'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Tr('Mode tema', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const TrafinThemeSelector(),
                  const SizedBox(height: 7),
                  Text('Default mengembalikan tema terang dan warna ungu bawaan Trafin. Pengaturan ini tidak mengubah data keuangan.',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 20),
                  const Tr('Warna tema', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 16, runSpacing: 12, children: [
                    for (final sw in swatches)
                      GestureDetector(
                        onTap: () => selectTrafinThemeColor(sw.$2),
                        child: Column(children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: sw.$2,
                            child: seedColor.value == sw.$2 ? const Icon(Icons.check, color: Colors.white) : null,
                          ),
                          const SizedBox(height: 4),
                          Tr(sw.$1, style: const TextStyle(fontSize: 12)),
                        ]),
                      ),
                  ]),
                ]),
              ),
            ),
            const Heading('Profil'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  TextField(controller: nameC, decoration: deco('Nama kamu'), onChanged: (v) => userName.value = v.trim()),
                  const SizedBox(height: 12),
                  TextField(
                    controller: compC,
                    decoration: deco('Nama perusahaan / Buku Bisnis aktif'),
                    onChanged: (v) {
                      final clean = v.trim();
                      if (clean.isNotEmpty) renameActiveBusinessBook(clean);
                    },
                  ),
                ]),
              ),
            ),
            const Heading('Beranda'),
            Card(
              child: SwitchListTile(
                title: const Tr('Indikator pengeluaran'),
                subtitle: const Tr('Tampilkan persen pemasukan bulan ini yang sudah terpakai'),
                value: showIndicator.value,
                onChanged: (v) => showIndicator.value = v,
              ),
            ),
            const Heading('Tentang'),
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline),
                title: Tr('Trafin'),
                subtitle: Tr('Versi 1.0.0'),
              ),
            ),
          ]),
        ),
      );
}

// ───────────────────────── Tutorial pemakaian Trafin ─────────────────────────

class _TrafinTutorialTopic {
  final String area, title, purpose, warning;
  final IconData icon;
  final List<String> steps;
  const _TrafinTutorialTopic(this.area, this.title, this.purpose,
      this.steps, this.warning, this.icon);
}

/// Panduan menyesuaikan kemampuan nyata aplikasi, bukan janji fitur yang
/// belum ada. Disimpan sebagai konten statis agar tersedia tanpa internet.
const _trafinTutorialTopics = <_TrafinTutorialTopic>[
  _TrafinTutorialTopic('Pribadi', 'Beranda & saldo',
      'Ringkasan pemasukan, pengeluaran, saldo keseluruhan, dan saldo tiap rekening.',
      ['Buka tab Home.', 'Periksa saldo bersih dan rincian rekening pada kartu di bagian atas.',
       'Sentuh judul Rekening untuk melihat daftar lengkap.'],
      'Total saldo dihitung dari saldo awal dan transaksi. Jika ada transaksi dari rekening yang telah terhapus, nilai itu tetap dihitung sebagai saldo tanpa rekening aktif.', Icons.home_outlined),
  _TrafinTutorialTopic('Pribadi', 'Mencatat transaksi',
      'Menyimpan uang masuk atau keluar beserta tanggal, kategori, dan rekening.',
      ['Tekan tombol + di bawah.', 'Pilih Pemasukan atau Pengeluaran.',
       'Isi nominal, kategori, rekening, dan catatan jika diperlukan.', 'Tekan Simpan dan lihat hasilnya di Riwayat.'],
      'Nilai yang diketik mengikuti mata uang yang dipilih. Titik atau koma ribuan hanya untuk memudahkan membaca nominal.', Icons.add_circle_outline),
  _TrafinTutorialTopic('Pribadi', 'Kategori buatan sendiri',
      'Membuat kategori seperti Angkot ke sekolah, Jajan, atau Freelance.',
      ['Buka form transaksi, lalu tekan + di sebelah Kategori.',
       'Tulis nama kategori dan tambah sebanyak yang diperlukan.',
       'Kategori tersebut dapat dipilih lagi dan muncul di laporan.'],
      'Menghapus kategori buatan tidak menghapus transaksi yang sudah tercatat di dalamnya.', Icons.category_outlined),
  _TrafinTutorialTopic('Pribadi', 'Rekening Tunai, Bank, dan E-Wallet',
      'Memisahkan saldo menurut tempat uang disimpan, termasuk rekening dengan nama bebas.',
      ['Buka menu garis tiga, lalu Rekening.', 'Tekan Rekening baru.',
       'Isi nama, jenis, dan saldo awal.', 'Saat mencatat transaksi, pilih rekening yang benar.'],
      'Rekening yang masih memiliki transaksi atau jadwal tidak dapat langsung dihapus supaya saldo tidak hilang diam-diam.', Icons.account_balance_outlined),
  _TrafinTutorialTopic('Pribadi', 'Anggaran bulanan',
      'Membatasi pengeluaran menurut kategori agar pengeluaran dapat dipantau.',
      ['Buka menu Anggaran.', 'Pilih Anggaran baru, tentukan kategori dan nominal batas.',
       'Lihat indikator terpakai, sisa, atau jumlah yang melebihi batas.'],
      'Anggaran adalah batas pemantauan, bukan saldo rekening dan tidak memindahkan uang.', Icons.donut_large_outlined),
  _TrafinTutorialTopic('Pribadi', 'Hutang & piutang pribadi',
      'Mencatat siapa yang berutang kepada kamu atau kepada siapa kamu berutang.',
      ['Buka Hutang di menu.', 'Pilih Saya berutang atau Piutang saya.',
       'Catat orang, nominal, dan tanggal jatuh tempo.', 'Gunakan Tandai lunas ketika selesai.'],
      'Tandai lunas hanya mengubah status catatan. Jika uang benar-benar keluar atau masuk, catat juga transaksinya secara terpisah.', Icons.people_outline),
  _TrafinTutorialTopic('Pribadi', 'Target tabungan',
      'Memantau kemajuan menuju tujuan seperti laptop, perjalanan, atau dana darurat.',
      ['Buka tab Target.', 'Tekan tombol untuk membuat target dan isi jumlahnya.',
       'Gunakan Setor untuk menaikkan jumlah yang tercatat sebagai tabungan.'],
      'Setor ke Target hanya menambah progress target; tidak otomatis memindahkan saldo antar-rekening.', Icons.flag_outlined),
  _TrafinTutorialTopic('Pribadi', 'Transaksi terjadwal',
      'Membuat catatan rutin untuk gaji, langganan, atau biaya bulanan.',
      ['Buka Transaksi terjadwal dari menu.', 'Tambah judul, nominal, rekening, kategori, tanggal, dan frekuensi.',
       'Periksa tanggal Berikutnya untuk jadwal berikut.'],
      'Transaksi jatuh tempo diproses saat aplikasi dibuka atau kembali aktif, bukan melalui layanan latar belakang terus-menerus.', Icons.autorenew),
  _TrafinTutorialTopic('Pribadi', 'Kalender & laporan',
      'Melihat transaksi per tanggal, distribusi kategori, serta perbandingan enam periode.',
      ['Buka Kalender untuk memilih tanggal dan melihat aktivitas hari itu.',
       'Buka tab Laporan untuk donut chart kategori.',
       'Lihat diagram batang untuk membandingkan Pemasukan dan Pengeluaran enam bulan.'],
      'Data laporan mengikuti transaksi yang dimasukkan dan periode yang dipilih.', Icons.insert_chart_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Memulai mode Perusahaan',
      'Memisahkan pencatatan bisnis dari keuangan pribadi.',
      ['Pilih Perusahaan pada sakelar di bagian atas aplikasi.',
       'Tekan ikon Buku Bisnis pada pojok kanan atas untuk membuat atau mengganti usaha.',
       'Gunakan tab Ringkasan, Jurnal, Akun, dan Laporan untuk mengelola bisnis.'],
      'Buku Bisnis berbeda menyimpan akun, jurnal, stok, faktur, dan pelanggan secara terpisah.', Icons.business_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Jurnal dibimbing',
      'Membantu pemula mencatat debit dan kredit dalam jumlah yang sama.',
      ['Masuk mode Perusahaan lalu buka menu Jurnal Dibimbing atau tombol +.',
       'Pilih preset transaksi, misalnya Penjualan Tunai atau Bayar Beban.',
       'Periksa akun Debit dan Kredit, lalu simpan.'],
      'Debit dan kredit harus seimbang. Pastikan jenis transaksi dan akun benar, bukan sekadar jumlah debit = kredit.', Icons.school_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Daftar akun bisnis',
      'Mengelola akun Aset, Liabilitas, Ekuitas, Pendapatan, dan Beban.',
      ['Buka tab Akun di mode Perusahaan.', 'Tekan Akun baru, lalu tentukan nama, tipe, dan kode akun.',
       'Catat penambahan atau pengurangan saldo menggunakan jurnal.'],
      'Akun yang sudah memiliki saldo atau dipakai dalam jurnal dilindungi dari penghapusan.', Icons.account_tree_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Faktur & piutang',
      'Mencatat tagihan pelanggan dan penerimaan pembayarannya.',
      ['Tambahkan pelanggan terlebih dahulu di Pelanggan & Pemasok.',
       'Buka Faktur & Piutang lalu buat faktur, pilih pelanggan, nominal, dan jatuh tempo.',
       'Saat dibayar, tekan Tandai dibayar.'],
      'Pembuatan faktur membuat jurnal Debit Piutang/Kredit Penjualan; pelunasan membuat Debit Kas/Kredit Piutang. Pembayaran sebagian belum didukung.', Icons.receipt_long_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Pelanggan & pemasok',
      'Menyimpan informasi pihak yang melakukan transaksi dengan bisnis.',
      ['Buka Pelanggan & Pemasok melalui menu perusahaan.',
       'Tambah nama, tipe, kontak, dan catatan.', 'Gunakan pelanggan tersebut saat membuat faktur.'],
      'Nama kontak dengan tipe yang sama tidak boleh duplikat. Kontak yang masih dipakai faktur aktif tidak dapat dihapus.', Icons.people_alt_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Produk & stok',
      'Menyimpan SKU, harga jual, biaya satuan, stok, dan ambang stok minimum.',
      ['Buka Produk & Stok.', 'Buat produk dengan nama dan jumlah stok yang valid.',
       'Ketuk produk untuk menyesuaikan jumlah stok.'],
      'Stok tidak otomatis memposting jurnal Persediaan maupun Harga Pokok Penjualan. Catat transaksi akuntansinya secara terpisah.', Icons.inventory_2_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Pusat Bisnis & analisis',
      'Melihat piutang, stok menipis, kesehatan jurnal, omzet, beban, dan laba.',
      ['Buka Pusat Bisnis dari menu perusahaan untuk ringkasan operasional.',
       'Buka Analisis Bisnis untuk perbandingan pendapatan, beban, dan margin selama enam periode.'],
      'Angka berdasarkan data yang sudah dicatat. Periksa jurnal yang belum lengkap sebelum memakai laporan untuk keputusan penting.', Icons.insights_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Laporan keuangan & CALK',
      'Membaca Neraca, Laba Rugi, Arus Kas, Perubahan Ekuitas, dan catatan laporan.',
      ['Buka tab Laporan di mode Perusahaan.', 'Pilih periode lalu pilih jenis laporan.',
       'Buka CALK untuk melihat dasar penyusunan dan keterbatasan data.'],
      'Laporan bersifat alat pembelajaran dan pembukuan sederhana; periksa kebenaran klasifikasi dan rekonsiliasi sebelum dipakai secara resmi.', Icons.assessment_outlined),
  _TrafinTutorialTopic('Perusahaan', 'Kontrol periode & checklist',
      'Membantu menutup bulan dan mencegah perubahan jurnal setelah diperiksa.',
      ['Periksa dan cocokkan jurnal terlebih dahulu.', 'Isi Checklist Bulanan.',
       'Masuk Kontrol Periode lalu pilih Kunci periode.',
       'Jika perlu koreksi, buka kunci terlebih dahulu.'],
      'Periode terkunci menolak jurnal baru atau penghapusan jurnal. Mengubah tanggal awal periode dapat menggeser pembagian bulan laporan.', Icons.lock_clock_outlined),
  _TrafinTutorialTopic('Pengaturan', 'Tema Default, Terang, dan Gelap',
      'Mengatur penampilan aplikasi tanpa memengaruhi uang atau laporan.',
      ['Buka Pengaturan → Tampilan → Mode tema.',
       'Pilih Default untuk kembali ke tema terang dengan warna ungu bawaan.',
       'Pilih Terang atau Gelap untuk memakai mode tersebut dengan warna pilihanmu.'],
      'Default adalah preset tema Trafin, bukan pengaturan untuk mengikuti tampilan HP.', Icons.palette_outlined),
  _TrafinTutorialTopic('Pengaturan', 'Mata uang & kurs',
      'Menampilkan nilai dalam mata uang lain sambil menjaga catatan dasar tetap konsisten.',
      ['Buka Pengaturan → Mata uang.', 'Pilih mata uang tujuan dan tunggu kurs tersedia.',
       'Gunakan Perbarui kurs tampilan untuk meminta data terbaru.'],
      'Kurs bersifat indikatif, bergantung jaringan atau cache. Ubah mata uang tampilan tidak mengubah nominal dasar yang tersimpan.', Icons.currency_exchange),
  _TrafinTutorialTopic('Pengaturan', 'Profil & keamanan',
      'Mengatur sapaan di beranda dan PIN untuk membatasi akses langsung.',
      ['Buka Pengaturan → Profil untuk menulis namamu.',
       'Buka Pengaturan → Keamanan untuk mengaktifkan atau mengubah PIN.'],
      'PIN adalah perlindungan akses dasar; bukan enkripsi penuh semua data keuangan.', Icons.lock_outline),
  _TrafinTutorialTopic('Pengaturan', 'Cadangan, pemulihan & ekspor',
      'Melindungi data dan membawa catatan untuk dipakai di perangkat lain.',
      ['Buka Pengaturan → Cadangan data dan pilih Salin cadangan.',
       'Simpan teks cadangan di lokasi aman.', 'Jika diperlukan, tempel cadangan lalu Pulihkan.',
       'Gunakan ikon ekspor CSV dan opsi PDF untuk membuat laporan yang dapat dibagikan.'],
      'Pemulihan menggantikan data aktif. Buat cadangan baru sebelum mencoba impor, penghapusan, atau pembaruan aplikasi.', Icons.backup_outlined),
];

class TrafinTutorialPage extends StatefulWidget {
  const TrafinTutorialPage({super.key});
  @override
  State<TrafinTutorialPage> createState() => _TrafinTutorialPageState();
}

class _TrafinTutorialPageState extends State<TrafinTutorialPage> {
  final _search = TextEditingController();
  String _area = 'Semua';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _search.text.toLowerCase().trim();
    final topics = _trafinTutorialTopics.where((t) {
      final validArea = _area == 'Semua' || t.area == _area;
      final text = [t.title, t.purpose, t.warning, ...t.steps].join(' ').toLowerCase();
      return validArea && (q.isEmpty || text.contains(q));
    }).toList();

    return Scaffold(
      appBar: AppBar(title: const Tr('Tutorial Trafin')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 48), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.auto_stories_outlined, size: 28),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Tr('Kenali Trafin dari awal', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                const SizedBox(height: 5),
                Text('Mulai dari Rekening → Catat transaksi → Periksa laporan. Jika punya usaha, buat Buku Bisnis sebelum menambah jurnal.',
                    style: Theme.of(context).textTheme.bodySmall),
              ])),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Cari fitur atau cara penggunaan...',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final value in const ['Semua', 'Pribadi', 'Perusahaan', 'Pengaturan']) ...[
              ChoiceChip(
                label: Text(value),
                selected: value == _area,
                onSelected: (_) => setState(() => _area = value),
              ),
              const SizedBox(width: 8),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text('${topics.length} topik • ketuk judul untuk membaca langkahnya',
              style: Theme.of(context).textTheme.bodySmall),
        ),
        if (topics.isEmpty)
          const EmptyState(title: 'Topik tidak ditemukan',
              hint: 'Coba kata kunci lain atau pilih Semua', icon: Icons.search_off_outlined),
        for (final topic in topics)
          Card(
            child: ExpansionTile(
              key: PageStorageKey('trafin-tutorial-${topic.title}'),
              leading: CircleAvatar(child: Icon(topic.icon)),
              title: Text(tr(topic.title), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(topic.area, style: Theme.of(context).textTheme.bodySmall),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(topic.purpose),
                const SizedBox(height: 10),
                const Tr('Cara menggunakan', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                for (var i = 0; i < topic.steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${i + 1}. ', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Expanded(child: Text(topic.steps[i])),
                    ]),
                  ),
                const SizedBox(height: 8),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(topic.warning,
                      style: Theme.of(context).textTheme.bodySmall)),
                ]),
              ],
            ),
          ),
      ]),
    );
  }
}

// ───────────────────────── Fitur tambahan (mode pribadi) ─────────────────────────

const expenseCats = ['Makanan', 'Transport', 'Tagihan', 'Belanja', 'Hiburan', 'Lainnya'];
const incomeCats = ['Gaji', 'Sampingan', 'Hadiah', 'Lainnya'];

ValueNotifier<List<String>> customCatsFor(bool income) => income ? customIncomeCats : customExpenseCats;

List<String> categoriesFor(bool income) {
  final base = income ? incomeCats : expenseCats;
  final custom = customCatsFor(income).value;
  return [...base, ...custom];
}

Future<String?> showCategoryManager(BuildContext context, {required bool income}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryManagerSheet(income: income),
    );

class CategoryField extends StatelessWidget {
  final bool income;
  final String? value;
  final String? error;
  final ValueChanged<String?> onChanged;

  const CategoryField({
    super.key,
    required this.income,
    required this.value,
    required this.onChanged,
    this.error,
  });

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<String>>(
        valueListenable: customCatsFor(income),
        builder: (context, _, __) {
          final options = categoriesFor(income);
          if (value != null && !options.contains(value)) options.add(value!);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('${income ? 'in' : 'out'}-${value ?? ''}-${options.length}'),
                value: value,
                isExpanded: true,
                decoration: deco('Kategori', err: error),
                items: [
                  for (final o in options) DropdownMenuItem(value: o, child: Text(tr(o), overflow: TextOverflow.ellipsis)),
                ],
                onChanged: onChanged,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 56,
              width: 56,
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                onPressed: () async {
                  final picked = await showCategoryManager(context, income: income);
                  if (!context.mounted) return;
                  if (picked != null) {
                    onChanged(picked);
                  } else if (value != null && !categoriesFor(income).contains(value)) {
                    onChanged(null);
                  }
                },
                child: const Icon(Icons.add),
              ),
            ),
          ]);
        },
      );
}

class CategoryManagerSheet extends StatefulWidget {
  final bool income;
  const CategoryManagerSheet({super.key, required this.income});

  @override
  State<CategoryManagerSheet> createState() => _CategoryManagerSheetState();
}

class _CategoryManagerSheetState extends State<CategoryManagerSheet> {
  final name = TextEditingController();
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void add() {
    final clean = name.text.trim();
    final all = categoriesFor(widget.income);
    if (clean.isEmpty) {
      setState(() => error = 'Isi nama kategori');
      return;
    }
    if (all.any((x) => x.toLowerCase() == clean.toLowerCase())) {
      setState(() => error = 'Kategori sudah ada');
      return;
    }
    final store = customCatsFor(widget.income);
    store.value = [...store.value, clean];
    Navigator.pop(context, clean);
  }

  @override
  Widget build(BuildContext context) {
    final store = customCatsFor(widget.income);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(
          tr(widget.income ? 'Kelola kategori pemasukan' : 'Kelola kategori pengeluaran'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 6),
        Text(
          tr('Kategori buatanmu tersimpan dan otomatis ikut muncul di laporan/diagram. Menghapus kategori tidak menghapus transaksi lama.'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => add(),
              decoration: deco('Nama kategori baru', err: error),
              onChanged: (_) => setState(() => error = null),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(height: 56, child: FilledButton(onPressed: add, child: const Icon(Icons.add))),
        ]),
        const SizedBox(height: 12),
        ValueListenableBuilder<List<String>>(
          valueListenable: store,
          builder: (context, custom, _) => custom.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(tr('Belum ada kategori buatan sendiri.'), textAlign: TextAlign.center),
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final c in custom)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(child: Icon(iconFor(c))),
                          title: Text(c),
                          subtitle: const Tr('Kategori buatan sendiri'),
                          onTap: () => Navigator.pop(context, c),
                          trailing: IconButton(
                            tooltip: tr('Hapus'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => store.value = store.value.where((x) => x != c).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
      ]),
    );
  }
}

Widget pageHeader(BuildContext c, String title, String btn, IconData icon, VoidCallback onTap) => Row(children: [
      Expanded(child: Text(title, style: Theme.of(c).textTheme.titleLarge)),
      FilledButton.tonalIcon(onPressed: onTap, icon: Icon(icon), label: Text(btn)),
    ]);

// ── Rekening ──

class Wallet {
  final String name, type;
  final num start;
  const Wallet(this.name, this.type, this.start);
  IconData get icon => switch (type) {
        'Tunai' => Icons.payments_outlined,
        'Bank' => Icons.account_balance_outlined,
        'E-wallet' => Icons.phone_android_outlined,
        _ => Icons.account_balance_wallet_outlined,
      };
}

final wallets = ValueNotifier<List<Wallet>>([const Wallet('Tunai', 'Tunai', 0)]);

/// Saldo termasuk semua riwayat, bahkan transaksi lama dari rekening
/// yang sudah terhapus. Transaksi tidak boleh lenyap dari total diam-diam.
num totalBalance(List<Tx> list) =>
    wallets.value.fold<num>(0, (sum, w) => sum + w.start) +
    list.fold<num>(0, (sum, t) => sum + (t.income ? t.amt : -t.amt));

/// Nilai yang belum terasosiasi ke rekening aktif, ditampilkan terpisah.
List<Tx> unassignedWalletTransactions(List<Tx> list) {
  final names = wallets.value.map((w) => w.name).toSet();
  return list.where((t) =>
    (t.wallet.isEmpty && wallets.value.isEmpty) ||
    (t.wallet.isNotEmpty && !names.contains(t.wallet))).toList();
}

num unassignedWalletBalance(List<Tx> list) =>
    unassignedWalletTransactions(list).fold<num>(0, (sum, t) => sum + (t.income ? t.amt : -t.amt));

num walletBalance(Wallet w, List<Tx> list) =>
    w.start + list.where((t) => t.wallet == w.name ||
        (t.wallet.isEmpty && wallets.value.isNotEmpty && w.name == wallets.value.first.name))
        .fold<num>(0, (a, t) => a + (t.income ? t.amt : -t.amt));

class WalletPage extends StatelessWidget {
  const WalletPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Rekening')),
        body: ListenableBuilder(
          listenable: Listenable.merge([wallets, txs]),
          builder: (context, _) {
            final all = txs.value;
            final list = wallets.value;
            final total = totalBalance(all);
            final cs = Theme.of(context).colorScheme;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(24)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Tr('Total semua rekening', style: TextStyle(color: cs.onPrimaryContainer)),
                  const SizedBox(height: 4),
                  Text(rp(total), style: TextStyle(color: cs.onPrimaryContainer, fontSize: 28, fontWeight: FontWeight.bold)),
                ]),
              ),
              if (unassignedWalletTransactions(all).isNotEmpty)
                Card(child: ListTile(
                  leading: const Icon(Icons.warning_amber_outlined),
                  title: const Tr('Saldo transaksi tanpa rekening aktif'),
                  subtitle: const Tr('Ada transaksi dari rekening yang sudah tidak tersedia. Total tetap menghitungnya agar riwayat keuangan tidak hilang.'),
                  trailing: Text(rp(unassignedWalletBalance(all)), style: const TextStyle(fontWeight: FontWeight.w700)),
                )),
              const SizedBox(height: 16),
              pageHeader(context, 'Daftar rekening', 'Rekening baru', Icons.add, () => showForm(context, const WalletForm())),
              const SizedBox(height: 12),
              if (list.isEmpty)
                const EmptyState(
                  title: 'Belum ada rekening',
                  hint: 'Tekan Rekening baru untuk menambah',
                  icon: Icons.account_balance_outlined,
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tr('Geser ke kiri untuk menghapus rekening', style: Theme.of(context).textTheme.bodySmall),
                ),
                for (final w in list)
                  SwipeDelete<Wallet>(
                    store: wallets,
                    item: w,
                    label: w.name,
                    confirmDismiss: (_) async {
                      final isFirst = wallets.value.isNotEmpty && identical(wallets.value.first, w);
                      final hasTransactions = txs.value.any((t) =>
                          t.wallet == w.name || (isFirst && t.wallet.isEmpty));
                      final hasSchedule = schedules.value.any((t) => t.wallet == w.name ||
                          (isFirst && t.wallet.isEmpty));
                      if (hasTransactions || hasSchedule) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Tr('Rekening masih dipakai transaksi atau jadwal. Pindahkan/hapus catatannya sebelum menghapus rekening.'),
                          duration: Duration(seconds: 3),
                        ));
                        return false;
                      }
                      if (w.start == 0) return true;
                      final approved = await showDialog<bool>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: const Tr('Hapus rekening dengan saldo awal?'),
                          content: Text('Saldo awal ${rp(w.start)} akan hilang dari total setelah rekening dihapus.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Tr('Batal')),
                            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Tr('Hapus')),
                          ],
                        ),
                      );
                      return approved == true;
                    },
                    child: Card(
                      margin: EdgeInsets.zero,
                      child: ListTile(
                        leading: CircleAvatar(child: Icon(w.icon)),
                        title: Text(tr(w.name), style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(tr(w.type)),
                        trailing: Text(rp(walletBalance(w, all)), style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
              ],
            ]);
          },
        ),
      );
}

class WalletForm extends StatefulWidget {
  const WalletForm({super.key});
  @override
  State<WalletForm> createState() => _WalletFormState();
}

class _WalletFormState extends State<WalletForm> {
  final name = TextEditingController();
  final start = TextEditingController();
  String type = 'Tunai';
  String? nameErr;

  @override
  void dispose() {
    name.dispose();
    start.dispose();
    super.dispose();
  }

  void save() {
    final nm = name.text.trim();
    final dup = wallets.value.any((w) => w.name.toLowerCase() == nm.toLowerCase());
    setState(() => nameErr = nm.isEmpty ? 'Isi nama rekening' : dup ? 'Nama rekening sudah ada' : null);
    if (nm.isEmpty || dup) return;
    wallets.value = [...wallets.value, Wallet(nm, type, parseMoney(start.text))];
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => formBody(context, 'Rekening baru', [
        TextField(controller: name, decoration: deco('Nama rekening', err: nameErr)),
        DropdownButtonFormField<String>(
          value: type,
          decoration: deco('Jenis'),
          items: [for (final t in const ['Tunai', 'Bank', 'E-wallet', 'Lainnya']) DropdownMenuItem(value: t, child: Text(tr(t)))],
          onChanged: (v) => setState(() => type = v ?? type),
        ),
        moneyField(start, 'Saldo awal (opsional)', null),
      ], save);
}

// ── Anggaran ──

class Budget {
  final String cat;
  final num limit;
  const Budget(this.cat, this.limit);
}

final budgets = ValueNotifier<List<Budget>>([]);

class BudgetPage extends StatelessWidget {
  const BudgetPage({super.key});

  Widget _card(BuildContext context, Budget b, num spent) {
    final cs = Theme.of(context).colorScheme;
    final p = b.limit == 0 ? 0.0 : (spent / b.limit).toDouble();
    final color = p >= 1
        ? tone(context, Colors.red)
        : p >= .8
            ? tone(context, Colors.orange)
            : cs.primary;
    final left = b.limit - spent;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CircleAvatar(child: Icon(iconFor(b.cat))),
            const SizedBox(width: 12),
            Expanded(child: Text(tr(b.cat), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
            Text('${(p * 100).round()}%', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: p > 1 ? 1.0 : p,
            minHeight: 10,
            color: color,
            backgroundColor: color.withValues(alpha: .15),
            borderRadius: BorderRadius.circular(8),
          ),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(tr('Terpakai {v}', {'v': rp(spent)})),
            Text(tr('Batas {v}', {'v': rp(b.limit)})),
          ]),
          const SizedBox(height: 4),
          Text(left >= 0 ? tr('Sisa {v}', {'v': rp(left)}) : tr('Melebihi {v}', {'v': rp(-left)}),
              style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Anggaran')),
        body: ListenableBuilder(
          listenable: Listenable.merge([budgets, txs]),
          builder: (context, _) {
            final cur = periodOf(DateTime.now());
            final list = budgets.value;
            num spentOf(Budget b) => txs.value
                .where((t) => !t.income && t.cat == b.cat && periodOf(t.when) == cur)
                .fold<num>(0, (a, t) => a + t.amt);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
              pageHeader(context, 'Anggaran bulanan', 'Anggaran baru', Icons.add, () => showForm(context, const BudgetForm())),
              const SizedBox(height: 4),
              Text(periodLabel(cur), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              if (list.isEmpty)
                const EmptyState(
                  title: 'Belum ada anggaran',
                  hint: 'Atur batas pengeluaran per kategori',
                  icon: Icons.donut_large_outlined,
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tr('Geser ke kiri untuk menghapus anggaran', style: Theme.of(context).textTheme.bodySmall),
                ),
                for (final b in list)
                  SwipeDelete<Budget>(store: budgets, item: b, label: tr(b.cat), child: _card(context, b, spentOf(b))),
              ],
            ]);
          },
        ),
      );
}

class BudgetForm extends StatefulWidget {
  const BudgetForm({super.key});
  @override
  State<BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<BudgetForm> {
  final limit = TextEditingController();
  String? cat, catErr, limitErr;

  @override
  void dispose() {
    limit.dispose();
    super.dispose();
  }

  void save() {
    final n = parseMoney(limit.text);
    final c = cat;
    final dup = c != null && budgets.value.any((b) => b.cat == c);
    setState(() {
      catErr = c == null ? 'Pilih kategori' : dup ? 'Anggaran kategori ini sudah ada' : null;
      limitErr = n <= 0 ? 'Isi batas lebih dari 0' : null;
    });
    if (c == null || dup || n <= 0) return;
    budgets.value = [...budgets.value, Budget(c, n)];
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => formBody(context, 'Anggaran baru', [
        CategoryField(
          income: false,
          value: cat,
          error: catErr,
          onChanged: (v) => setState(() {
            cat = v;
            catErr = null;
          }),
        ),
        moneyField(limit, 'Batas per periode', limitErr),
      ], save);
}

// ── Hutang ──

class Debt {
  final String who;
  final num amt;
  final bool mine, paid; // mine = saya berutang
  final DateTime? due;
  const Debt(this.who, this.amt, this.mine, this.due, this.paid);
}

final debts = ValueNotifier<List<Debt>>([]);

class DebtPage extends StatefulWidget {
  const DebtPage({super.key});
  @override
  State<DebtPage> createState() => _DebtPageState();
}

class _DebtPageState extends State<DebtPage> {
  bool mine = true;

  void toggle(Debt d) => debts.value = [
        for (final x in debts.value) x == d ? Debt(d.who, d.amt, d.mine, d.due, !d.paid) : x,
      ];

  Widget _card(BuildContext context, Debt d) {
    final due = d.due;
    final overdue = due != null && !d.paid && due.isBefore(DateTime.now());
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          CircleAvatar(child: Icon(d.paid ? Icons.check : Icons.person_outline)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.who,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: d.paid ? TextDecoration.lineThrough : null,
                  )),
              Text(
                d.paid ? tr('Lunas') : (due == null ? tr('Tanpa jatuh tempo') : tr('Jatuh tempo {d}', {'d': dateFull(due)})),
                style: TextStyle(fontSize: 12, color: overdue ? tone(context, Colors.red) : cs.onSurfaceVariant),
              ),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(rp(d.amt), style: const TextStyle(fontWeight: FontWeight.bold)),
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => toggle(d),
              child: Tr(d.paid ? 'Batal lunas' : 'Tandai lunas'),
            ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Hutang')),
        body: ValueListenableBuilder<List<Debt>>(
          valueListenable: debts,
          builder: (context, all, _) {
            final list = all.where((d) => d.mine == mine).toList();
            final open = list.where((d) => !d.paid).fold<num>(0, (a, d) => a + d.amt);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: true, label: Tr('Saya berutang')),
                    ButtonSegment(value: false, label: Tr('Piutang saya')),
                  ],
                  selected: {mine},
                  onSelectionChanged: (s) => setState(() => mine = s.first),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Tr(mine ? 'Total yang harus kamu bayar' : 'Total yang harus dibayar ke kamu'),
                    const SizedBox(height: 4),
                    Text(rp(open), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
              pageHeader(context, 'Daftar', 'Catat baru', Icons.add, () => showForm(context, DebtForm(mine))),
              const SizedBox(height: 12),
              if (list.isEmpty)
                const EmptyState(
                  title: 'Belum ada catatan',
                  hint: 'Tekan Catat baru untuk menambah',
                  icon: Icons.timer_outlined,
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Tr('Geser ke kiri untuk menghapus catatan', style: Theme.of(context).textTheme.bodySmall),
                ),
                for (final d in list) SwipeDelete<Debt>(store: debts, item: d, label: d.who, child: _card(context, d)),
              ],
            ]);
          },
        ),
      );
}

class DebtForm extends StatefulWidget {
  final bool mine;
  const DebtForm(this.mine, {super.key});
  @override
  State<DebtForm> createState() => _DebtFormState();
}

class _DebtFormState extends State<DebtForm> {
  late bool mine = widget.mine;
  final who = TextEditingController();
  final amt = TextEditingController();
  DateTime? due;
  String? whoErr, amtErr;

  @override
  void dispose() {
    who.dispose();
    amt.dispose();
    super.dispose();
  }

  Future<void> pickDue() async {
    final d = await showDatePicker(
      context: context,
      initialDate: due ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 5, 12, 31),
    );
    if (d != null && mounted) setState(() => due = d);
  }

  void save() {
    final n = parseMoney(amt.text);
    final nm = who.text.trim();
    setState(() {
      whoErr = nm.isEmpty ? 'Isi nama' : null;
      amtErr = n <= 0 ? 'Isi nominal lebih dari 0' : null;
    });
    if (nm.isEmpty || n <= 0) return;
    debts.value = [...debts.value, Debt(nm, n, mine, due, false)];
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final d = due;
    return formBody(context, 'Catat hutang', [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Tr('Saya berutang')),
          ButtonSegment(value: false, label: Tr('Piutang saya')),
        ],
        selected: {mine},
        onSelectionChanged: (s) => setState(() => mine = s.first),
      ),
      TextField(controller: who, decoration: deco(mine ? 'Berutang kepada' : 'Yang berutang', err: whoErr)),
      moneyField(amt, 'Nominal', amtErr),
      OutlinedButton.icon(
        onPressed: pickDue,
        icon: const Icon(Icons.event_outlined),
        label: Text(d == null ? tr('Jatuh tempo (opsional)') : tr('Jatuh tempo: {d}', {'d': dateFull(d)})),
      ),
    ], save);
  }
}

// ── Kalender ──

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime sel = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);

  bool same(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
  void shift(int d) => setState(() => month = DateTime(month.year, month.month + d));

  Widget _dot(Color c) => Container(
        width: 5,
        height: 5,
        margin: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Tr('Kalender')),
      body: ValueListenableBuilder<List<Tx>>(
        valueListenable: txs,
        builder: (context, all, _) {
          final lead = DateTime(month.year, month.month).weekday - 1;
          final days = DateTime(month.year, month.month + 1, 0).day;
          final today = DateTime.now();
          final dayTx = all.where((t) => same(t.when, sel)).toList();
          final inc = dayTx.where((t) => t.income).fold<num>(0, (a, t) => a + t.amt);
          final exp = dayTx.where((t) => !t.income).fold<num>(0, (a, t) => a + t.amt);
          Widget cell(int d) {
            final day = DateTime(month.year, month.month, d);
            final isSel = same(day, sel);
            final has = all.where((t) => same(t.when, day));
            final hasIn = has.any((t) => t.income);
            final hasOut = has.any((t) => !t.income);
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => sel = day),
              child: Container(
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: isSel ? cs.primary : null,
                  borderRadius: BorderRadius.circular(12),
                  border: same(day, today) && !isSel ? Border.all(color: cs.primary) : null,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('$d', style: TextStyle(color: isSel ? cs.onPrimary : null, fontWeight: same(day, today) ? FontWeight.bold : null)),
                  const SizedBox(height: 2),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    if (hasIn) _dot(isSel ? cs.onPrimary : tone(context, Colors.green)),
                    if (hasOut) _dot(isSel ? cs.onPrimary : tone(context, Colors.red)),
                    if (!hasIn && !hasOut) const SizedBox(height: 5),
                  ]),
                ]),
              ),
            );
          }

          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(children: [
                  Row(children: [
                    IconButton(icon: const Icon(Icons.chevron_left), onPressed: () => shift(-1)),
                    Expanded(
                      child: Center(
                        child: Text(bulanTahun(month), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.chevron_right), onPressed: () => shift(1)),
                  ]),
                  Row(children: [
                    for (var k = 1; k <= 7; k++)
                      Expanded(child: Center(child: Text(tr('w$k'), style: Theme.of(context).textTheme.bodySmall))),
                  ]),
                  const SizedBox(height: 4),
                  GridView.count(
                    crossAxisCount: 7,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      for (var k = 0; k < lead; k++) const SizedBox.shrink(),
                      for (var d = 1; d <= days; d++) cell(d),
                    ],
                  ),
                ]),
              ),
            ),
            Heading(dateFull(sel)),
            if (dayTx.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(tr('Masuk {a} • Keluar {b}', {'a': rp(inc), 'b': rp(exp)}), style: Theme.of(context).textTheme.bodySmall),
              ),
            if (dayTx.isEmpty)
              const EmptyState(title: 'Tidak ada transaksi', hint: 'Pilih tanggal lain atau catat dengan tombol +', icon: Icons.event_busy_outlined)
            else
              for (final t in dayTx) TxTile(t),
          ]);
        },
      ),
    );
  }
}

// ── Pengaturan: mata uang, tanggal, keamanan ──

class CurrencySheet extends StatelessWidget {
  const CurrencySheet({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([currency, currencyCode, displayFxRate, symbolAfter, thousandSep, decimals]),
        builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Tr('Mata uang', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(tr('Contoh: {v}', {'v': rp(1234567)})),
          const SizedBox(height: 8),
          Text('Nilai pembukuan disimpan dalam ${baseCurrencyCode.value}. '
              'Semua tampilan dan nominal baru menggunakan ${currencyCode.value} '
              'dengan kurs 1 ${baseCurrencyCode.value} = '
              '${displayFxRate.value.toStringAsPrecision(7)} ${currencyCode.value}.',
              style: Theme.of(context).textTheme.bodySmall),
          if (displayFxSource.value.isNotEmpty)
            Text('Sumber: ${displayFxSource.value} • ${displayFxUpdated.value}',
                style: Theme.of(context).textTheme.bodySmall),
          if (baseCurrencyCode.value != currencyCode.value) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Perbarui kurs tampilan'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  final quote = await getCurrencyQuote(baseCurrencyCode.value, currencyCode.value, force: true);
                  if (!context.mounted) return;
                  displayFxRate.value = quote.rate;
                  displayFxUpdated.value = quote.data.updated;
                  displayFxSource.value = quote.data.isStale
                      ? '${quote.data.source} (cache offline)' : quote.data.source;
                  messenger.showSnackBar(SnackBar(content: Text(quote.data.isStale
                      ? 'Belum bisa memperbarui. Kurs terakhir tetap dipakai.'
                      : 'Kurs tampilan berhasil diperbarui.')));
                } catch (e) {
                  if (context.mounted) {
                    messenger.showSnackBar(SnackBar(content: Text('Kurs gagal diperbarui: $e')));
                  }
                }
              },
            ),
          ],
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Text(flag(curByCode(currencyCode.value).cc), style: const TextStyle(fontSize: 28)),
              title: Text('${curByCode(currencyCode.value).name} (${currencyCode.value})'),
              subtitle: Text(curByCode(currencyCode.value).country),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CurrencyPickerPage())),
            ),
          ),
          const SizedBox(height: 16),
          const Tr('Posisi simbol', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Tr('Di depan')),
              ButtonSegment(value: true, label: Tr('Di belakang')),
            ],
            selected: {symbolAfter.value},
            onSelectionChanged: (v) => symbolAfter.value = v.first,
          ),
          const SizedBox(height: 16),
          const Tr('Pemisah ribuan', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: '.', label: Tr('Titik')),
              ButtonSegment(value: ',', label: Tr('Koma')),
              ButtonSegment(value: ' ', label: Tr('Spasi')),
            ],
            selected: {thousandSep.value},
            onSelectionChanged: (v) => thousandSep.value = v.first,
          ),
          const SizedBox(height: 16),
          const Tr('Angka desimal', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Tr('Tanpa desimal')),
              ButtonSegment(value: 2, label: Tr('2 digit')),
            ],
            selected: {decimals.value},
            onSelectionChanged: (v) => decimals.value = v.first,
          ),
        ]),
      );
}

class DateSheet extends StatelessWidget {
  const DateSheet({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([dateFormat, startDay]),
        builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Tr('Tanggal', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          const Tr('Format tanggal', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 0, label: Text(tr('dm', {'d': 29, 'm': tr('s10')}))),
              ButtonSegment(value: 1, label: Tr('29/10')),
            ],
            selected: {dateFormat.value},
            onSelectionChanged: (v) => dateFormat.value = v.first,
          ),
          const SizedBox(height: 16),
          const Tr('Awal periode bulanan', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            value: startDay.value,
            decoration: deco('Periode mulai tanggal'),
            items: [for (var d = 1; d <= 28; d++) DropdownMenuItem(value: d, child: Text(tr('Tanggal {d}', {'d': d})))],
            onChanged: (v) {
              if (v == null || v == startDay.value) return;
              // Mengubah tanggal awal periode menggeser jurnal ke kunci bulan
              // berbeda. Jangan izinkan sampai seluruh periode dibuka.
              final anyClosed = closedBusinessPeriods.value.isNotEmpty ||
                  businessBooks.value.any((b) => b.closedPeriods.isNotEmpty);
              if (anyClosed) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Tr('Buka semua periode terkunci di setiap Buku Bisnis sebelum mengubah tanggal awal periode.'),
                  duration: Duration(seconds: 4),
                ));
                return;
              }
              startDay.value = v;
              companyReportPeriod.value = periodOf(DateTime.now());
            },
          ),
          const SizedBox(height: 8),
          Text(tr('Periode sekarang: {p}', {'p': periodLabel(periodOf(DateTime.now()))}), style: Theme.of(context).textTheme.bodySmall),
        ]),
      );
}

class SecurityPage extends StatelessWidget {
  const SecurityPage({super.key});

  Future<void> ask(BuildContext context) async {
    final v = await showDialog<String>(context: context, builder: (_) => const PinDialog());
    if (v != null) pin.value = hashPin(v);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Keamanan')),
        body: ValueListenableBuilder<String?>(
          valueListenable: pin,
          builder: (context, p, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            Card(
              child: SwitchListTile(
                title: const Tr('Kunci aplikasi dengan PIN'),
                subtitle: const Tr('Aplikasi meminta PIN saat dibuka kembali dari latar belakang'),
                value: p != null,
                onChanged: (v) {
                  if (v) {
                    ask(context);
                  } else {
                    pin.value = null;
                    locked.value = false;
                  }
                },
              ),
            ),
            if (p != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.password_outlined),
                  title: const Tr('Ubah PIN'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => ask(context),
                ),
              ),
            Tr('PIN disimpan terenkripsi di perangkat. Jangan lupa PIN-mu: jika lupa, satu-satunya cara masuk lagi adalah memasang ulang aplikasi (data ikut terhapus).',
                style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );
}

class PinDialog extends StatefulWidget {
  const PinDialog({super.key});
  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  final c = TextEditingController();
  String? err;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Tr('Atur PIN'),
        content: TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          maxLength: 4,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: deco('PIN 4 digit', err: err),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Tr('Batal')),
          FilledButton(
            onPressed: () {
              if (c.text.length == 4) {
                Navigator.pop(context, c.text);
              } else {
                setState(() => err = 'PIN harus 4 digit');
              }
            },
            child: const Tr('Simpan'),
          ),
        ],
      );
}

class LockScreen extends StatefulWidget {
  const LockScreen({super.key});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final c = TextEditingController();
  String? err;
  int tries = 0;
  DateTime? blockedUntil;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void check(String v) {
    if (v.length < 4) return;
    final until = blockedUntil;
    if (until != null && DateTime.now().isBefore(until)) {
      c.clear();
      setState(() => err = 'Terlalu banyak percobaan. Coba lagi sebentar lagi.');
      return;
    }
    if (verifyPin(v)) {
      locked.value = false;
      return;
    }
    c.clear();
    tries++;
    if (tries >= 5) {
      tries = 0;
      blockedUntil = DateTime.now().add(const Duration(seconds: 30));
      setState(() => err = 'Terlalu banyak percobaan. Coba lagi sebentar lagi.');
    } else {
      setState(() => err = 'PIN salah');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.lock_outline, size: 48, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Tr('Trafin terkunci', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Tr('Masukkan PIN 4 digit'),
                const SizedBox(height: 24),
                TextField(
                  controller: c,
                  autofocus: true,
                  obscureText: true,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  maxLength: 4,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(counterText: '', errorText: err == null ? null : tr(err!), border: const OutlineInputBorder()),
                  onChanged: check,
                ),
              ]),
            ),
          ),
        ),
      );
}

// ── Daftar mata uang dunia ──

class Cur {
  final String code, symbol, name, country, cc;
  const Cur(this.code, this.symbol, this.name, this.country, this.cc);
}

const _rawCurrencies = r'''AFN||Afghani|Afganistan|AF
ALL||Lek|Albania|AL
AMD||Dram|Armenia|AM
ANG|ƒ|Gulden Antilla Belanda|Curaçao dan Sint Maarten|CW
AOA||Kwanza|Angola|AO
ARS|AR$|Peso Argentina|Argentina|AR
AUD|A$|Dolar Australia|Australia|AU
AWG|ƒ|Florin Aruba|Aruba|AW
AZN|₼|Manat Azerbaijan|Azerbaijan|AZ
BAM|KM|Mark Konvertibel|Bosnia dan Herzegovina|BA
BBD|Bds$|Dolar Barbados|Barbados|BB
BDT|৳|Taka|Bangladesh|BD
BGN||Lev Bulgaria|Bulgaria|BG
BHD||Dinar Bahrain|Bahrain|BH
BIF||Franc Burundi|Burundi|BI
BMD|BD$|Dolar Bermuda|Bermuda|BM
BND|B$|Dolar Brunei|Brunei Darussalam|BN
BOB|Bs|Boliviano|Bolivia|BO
BRL|R$|Real Brasil|Brasil|BR
BSD|B$|Dolar Bahama|Bahama|BS
BTN||Ngultrum|Bhutan|BT
BWP||Pula|Botswana|BW
BYN||Rubel Belarus|Belarus|BY
BZD|BZ$|Dolar Belize|Belize|BZ
CAD|C$|Dolar Kanada|Kanada|CA
CDF||Franc Kongo|Republik Demokratik Kongo|CD
CHF||Franc Swiss|Swiss|CH
CLP|CL$|Peso Chile|Chile|CL
CNY|CN¥|Yuan Renminbi|Tiongkok|CN
COP|CO$|Peso Kolombia|Kolombia|CO
CRC|₡|Colon Kosta Rika|Kosta Rika|CR
CUP|₱|Peso Kuba|Kuba|CU
CVE||Escudo Tanjung Verde|Tanjung Verde|CV
CZK|Kč|Koruna Ceko|Republik Ceko|CZ
DJF||Franc Djibouti|Djibouti|DJ
DKK|kr|Krone Denmark|Denmark|DK
DOP|RD$|Peso Dominika|Republik Dominika|DO
DZD||Dinar Aljazair|Aljazair|DZ
EGP|E£|Pound Mesir|Mesir|EG
ERN||Nakfa|Eritrea|ER
ETB||Birr|Etiopia|ET
EUR|€|Euro|Zona Euro (Jerman, Prancis, Italia, dll.)|EU
FJD|FJ$|Dolar Fiji|Fiji|FJ
GBP|£|Pound Sterling|Inggris Raya|GB
GEL|₾|Lari|Georgia|GE
GHS|GH₵|Cedi|Ghana|GH
GMD||Dalasi|Gambia|GM
GNF||Franc Guinea|Guinea|GN
GTQ|Q|Quetzal|Guatemala|GT
GYD|G$|Dolar Guyana|Guyana|GY
HKD|HK$|Dolar Hong Kong|Hong Kong|HK
HNL|L|Lempira|Honduras|HN
HTG||Gourde|Haiti|HT
HUF|Ft|Forint|Hungaria|HU
IDR|Rp|Rupiah|Indonesia|ID
ILS|₪|Shekel Baru|Israel|IL
INR|₹|Rupee India|India|IN
IQD||Dinar Irak|Irak|IQ
IRR||Rial Iran|Iran|IR
ISK|kr|Krona Islandia|Islandia|IS
JMD|J$|Dolar Jamaika|Jamaika|JM
JOD||Dinar Yordania|Yordania|JO
JPY|¥|Yen|Jepang|JP
KES|KSh|Shilling Kenya|Kenya|KE
KGS||Som Kirgistan|Kirgistan|KG
KHR|៛|Riel|Kamboja|KH
KMF||Franc Komoro|Komoro|KM
KPW||Won Korea Utara|Korea Utara|KP
KRW|₩|Won|Korea Selatan|KR
KWD||Dinar Kuwait|Kuwait|KW
KYD||Dolar Kepulauan Cayman|Kepulauan Cayman|KY
KZT|₸|Tenge|Kazakhstan|KZ
LAK|₭|Kip|Laos|LA
LBP||Pound Lebanon|Lebanon|LB
LKR|Rs|Rupee Sri Lanka|Sri Lanka|LK
LRD||Dolar Liberia|Liberia|LR
LSL||Loti|Lesotho|LS
LYD||Dinar Libya|Libya|LY
MAD||Dirham Maroko|Maroko|MA
MDL||Leu Moldova|Moldova|MD
MGA||Ariary|Madagaskar|MG
MKD||Denar|Makedonia Utara|MK
MMK||Kyat|Myanmar|MM
MNT|₮|Tugrik|Mongolia|MN
MOP||Pataca|Makau|MO
MRU||Ouguiya|Mauritania|MR
MUR|₨|Rupee Mauritius|Mauritius|MU
MVR||Rufiyaa|Maladewa|MV
MWK||Kwacha Malawi|Malawi|MW
MXN|Mex$|Peso Meksiko|Meksiko|MX
MYR|RM|Ringgit|Malaysia|MY
MZN||Metical|Mozambik|MZ
NAD|N$|Dolar Namibia|Namibia|NA
NGN|₦|Naira|Nigeria|NG
NIO|C$|Cordoba|Nikaragua|NI
NOK|kr|Krone Norwegia|Norwegia|NO
NPR|Rs|Rupee Nepal|Nepal|NP
NZD|NZ$|Dolar Selandia Baru|Selandia Baru|NZ
OMR||Rial Oman|Oman|OM
PAB||Balboa|Panama|PA
PEN|S/|Sol|Peru|PE
PGK||Kina|Papua Nugini|PG
PHP|₱|Peso Filipina|Filipina|PH
PKR|Rs|Rupee Pakistan|Pakistan|PK
PLN|zł|Zloty|Polandia|PL
PYG|₲|Guarani|Paraguay|PY
QAR||Riyal Qatar|Qatar|QA
RON|lei|Leu Rumania|Rumania|RO
RSD||Dinar Serbia|Serbia|RS
RUB|₽|Rubel Rusia|Rusia|RU
RWF||Franc Rwanda|Rwanda|RW
SAR||Riyal Saudi|Arab Saudi|SA
SBD|SI$|Dolar Kepulauan Solomon|Kepulauan Solomon|SB
SCR||Rupee Seychelles|Seychelles|SC
SDG||Pound Sudan|Sudan|SD
SEK|kr|Krona Swedia|Swedia|SE
SGD|S$|Dolar Singapura|Singapura|SG
SLE||Leone|Sierra Leone|SL
SOS||Shilling Somalia|Somalia|SO
SRD||Dolar Suriname|Suriname|SR
SSP||Pound Sudan Selatan|Sudan Selatan|SS
STN||Dobra|Sao Tome dan Principe|ST
SYP||Pound Suriah|Suriah|SY
SZL||Lilangeni|Eswatini|SZ
THB|฿|Baht|Thailand|TH
TJS||Somoni|Tajikistan|TJ
TMT||Manat Turkmenistan|Turkmenistan|TM
TND||Dinar Tunisia|Tunisia|TN
TOP|T$|Pa'anga|Tonga|TO
TRY|₺|Lira Turki|Turki|TR
TTD|TT$|Dolar Trinidad dan Tobago|Trinidad dan Tobago|TT
TWD|NT$|Dolar Taiwan Baru|Taiwan|TW
TZS|TSh|Shilling Tanzania|Tanzania|TZ
UAH|₴|Hryvnia|Ukraina|UA
UGX|USh|Shilling Uganda|Uganda|UG
USD|$|Dolar Amerika Serikat|Amerika Serikat|US
UYU|$U|Peso Uruguay|Uruguay|UY
UZS||Som Uzbekistan|Uzbekistan|UZ
VES|Bs.S|Bolivar|Venezuela|VE
VND|₫|Dong|Vietnam|VN
VUV||Vatu|Vanuatu|VU
WST||Tala|Samoa|WS
XAF|FCFA|Franc CFA Afrika Tengah|Kamerun, Gabon, Chad, dll.|CM
XCD|EC$|Dolar Karibia Timur|Antigua, Grenada, St. Lucia, dll.|AG
XOF|CFA|Franc CFA Afrika Barat|Senegal, Pantai Gading, Mali, dll.|SN
XPF|₣|Franc CFP|Polinesia Prancis, Kaledonia Baru|PF
YER||Rial Yaman|Yaman|YE
ZAR|R|Rand|Afrika Selatan|ZA
ZMW|ZK|Kwacha Zambia|Zambia|ZM
ZWG||Zimbabwe Gold (ZiG)|Zimbabwe|ZW''';

final List<Cur> currencies = _rawCurrencies.split('\n').map((l) {
  final p = l.split('|');
  return Cur(p[0], p[1].isEmpty ? p[0] : p[1], p[2], p[3], p[4]);
}).toList();

Cur curByCode(String code) => currencies.firstWhere((c) => c.code == code, orElse: () => currencies.first);

String flag(String cc) =>
    cc.length != 2 ? '' : String.fromCharCodes(cc.toUpperCase().codeUnits.map((c) => 0x1F1E6 + c - 65));

const popularCodes = ['IDR', 'USD', 'EUR', 'SGD', 'MYR', 'JPY', 'GBP', 'AUD', 'SAR', 'CNY', 'KRW', 'THB'];

class CurrencyPickerPage extends StatefulWidget {
  const CurrencyPickerPage({super.key});
  @override
  State<CurrencyPickerPage> createState() => _CurrencyPickerPageState();
}

class _CurrencyPickerPageState extends State<CurrencyPickerPage> {
  String query = '';
  String? loadingCode;

  Future<void> chooseCurrency(Cur selected) async {
    if (loadingCode != null) return;
    if (selected.code == currencyCode.value) {
      Navigator.pop(context);
      return;
    }
    setState(() => loadingCode = selected.code);
    try {
      final quote = await getCurrencyQuote(baseCurrencyCode.value, selected.code);
      if (!quote.rate.isFinite || quote.rate <= 0) throw StateError('Nilai kurs tidak valid');
      if (!mounted) return;
      // Semuanya hanya mengubah representasi visual, bukan jurnal/riwayat.
      displayFxRate.value = quote.rate;
      displayFxUpdated.value = quote.data.updated;
      displayFxSource.value = quote.data.isStale ? '${quote.data.source} (cache offline)' : quote.data.source;
      currencyCode.value = selected.code;
      currency.value = selected.symbol;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      if (quote.data.isStale) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Menggunakan kurs tersimpan. Periksa tanggal kurs sebelum mengandalkan hasilnya.')));
      }
    } catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: const Text('Konversi mata uang gagal'),
          content: Text('Mata uang tidak diubah agar angka pembukuan tidak salah.\n\n$e\n\n'
              'Pastikan AndroidManifest.xml memiliki izin INTERNET.'),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('Tutup'))],
        ),
      );
    } finally {
      if (mounted) setState(() => loadingCode = null);
    }
  }


  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    bool match(Cur c) =>
        q.isEmpty || c.code.toLowerCase().contains(q) || c.name.toLowerCase().contains(q) || c.country.toLowerCase().contains(q);
    final rest = currencies.where(match).toList()..sort((a, b) => a.country.compareTo(b.country));
    final rows = <Object>[];
    if (q.isEmpty) {
      rows.add(tr('Populer'));
      rows.addAll(popularCodes.map(curByCode));
      rows.add(tr('Semua mata uang ({n})', {'n': currencies.length}));
    }
    rows.addAll(rest);
    return Scaffold(
      appBar: AppBar(title: const Tr('Pilih mata uang')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => query = v),
            decoration: InputDecoration(
              hintText: tr('Cari negara, mata uang, atau kode'),
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
            ),
          ),
        ),
        Expanded(
          child: rest.isEmpty
              ? const EmptyState(title: 'Tidak ditemukan', hint: 'Coba kata kunci lain', icon: Icons.search_off)
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    if (r is String) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                        child: Text(r, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      );
                    }
                    final c = r as Cur;
                    final sel = c.code == currencyCode.value;
                    return ListTile(
                      leading: Text(flag(c.cc), style: const TextStyle(fontSize: 28)),
                      title: Text('${c.name} • ${c.code}'),
                      subtitle: Text(c.country),
                      selected: sel,
                      trailing: loadingCode == c.code
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : sel
                              ? const Icon(Icons.check)
                              : Text(c.symbol, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      onTap: loadingCode == null ? () => chooseCurrency(c) : null,
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ───────────────────────── Pusat bisnis & alat perusahaan ─────────────────────────

void openCompanyTool(BuildContext context, Widget page) =>
    Navigator.push(context, MaterialPageRoute(builder: (_) => page));

Acc _ensureCompanyAccount(String code, String name, String type) {
  for (final a in accounts.value) {
    if (a.name == name) return a;
  }
  final a = Acc(code, name, type, 0);
  accounts.value = [...accounts.value, a];
  syncActiveBusinessBook();
  return a;
}

void _commitCompanyTools() => syncActiveBusinessBook();

class BusinessHubPage extends StatelessWidget {
  const BusinessHubPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          accounts,
          journals,
          businessInvoices,
          businessContacts,
          stockItems,
          closedBusinessPeriods,
          monthlyChecklistDone,
          companyReportPeriod,
          companyName,
        ]),
        builder: (context, _) {
          final p = companyReportPeriod.value;
          final revenue = reportPeriodRows('Pendapatan', p).fold<num>(0, (s, x) => s + x.$2);
          final expense = reportPeriodRows('Beban', p).fold<num>(0, (s, x) => s + x.$2);
          final profit = revenue - expense;
          final openInvoices = businessInvoices.value.where((x) => x.status == 'open').toList();
          final receivable = openInvoices.fold<num>(0, (s, x) => s + x.amount);
          final lowStock = stockItems.value.where((x) => x.qty <= x.minQty).length;
          final periodClosed = isCompanyPeriodAnchorClosed(p);
          final badJournals = journals.value.where((j) => journalInPeriod(j, p) && !journalBalanced(j)).length;

          Widget metric(String label, String value, IconData icon) => Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(icon, size: 20),
                      const SizedBox(height: 10),
                      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text(tr(label), style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ),
              );

          final tools = <(IconData, String, String, Widget)>[
            (Icons.receipt_long_outlined, 'Faktur & Piutang', 'Buat invoice, pantau jatuh tempo, dan catat pembayaran otomatis', const BusinessInvoicesPage()),
            (Icons.people_alt_outlined, 'Pelanggan & Pemasok', 'Simpan relasi bisnis per Buku Bisnis', const BusinessContactsPage()),
            (Icons.inventory_2_outlined, 'Produk & Stok', 'Katalog, harga, stok minimum, dan penyesuaian jumlah', const BusinessStockPage()),
            (Icons.insights_outlined, 'Analisis Bisnis', 'Bandingkan omzet, beban, dan laba enam periode', const BusinessAnalyticsPage()),
            (Icons.lock_clock_outlined, 'Kontrol Periode', 'Kunci bulan yang sudah selesai agar jurnal tidak berubah', const PeriodControlPage()),
            (Icons.fact_check_outlined, 'Checklist Bulanan', 'Rutinitas tutup bulan yang mudah diikuti pemula', const MonthlyChecklistPage()),
            (Icons.menu_book_outlined, 'Kamus Akuntansi', 'Istilah inti dengan penjelasan singkat dan praktis', const AccountingGlossaryPage()),
          ];

          return Scaffold(
            appBar: AppBar(title: const Tr('Pusat Bisnis')),
            body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
              Text(companyName.value.isEmpty ? tr('Bisnis Utama') : companyName.value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              Text(periodLabel(p), style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 14),
              Row(children: [metric('Pendapatan', rp(revenue), Icons.south_west), const SizedBox(width: 8), metric('Laba bersih', rp(profit), Icons.trending_up)]),
              Row(children: [metric('Piutang terbuka', rp(receivable), Icons.schedule_send_outlined), const SizedBox(width: 8), metric('Stok menipis', '$lowStock item', Icons.inventory_outlined)]),
              Card(
                child: ListTile(
                  leading: CircleAvatar(
                    child: Icon(periodClosed ? Icons.lock : badJournals == 0 ? Icons.verified_outlined : Icons.warning_amber_outlined),
                  ),
                  title: Tr(periodClosed ? 'Periode ini terkunci' : badJournals == 0 ? 'Pembukuan terlihat sehat' : 'Ada jurnal yang perlu diperiksa',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(periodClosed
                      ? tr('Jurnal pada periode ini dilindungi dari perubahan tidak sengaja.')
                      : badJournals == 0
                          ? tr('Semua jurnal pada periode aktif memiliki Debit = Kredit.')
                          : tr('{n} jurnal tidak seimbang.', {'n': badJournals})),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openCompanyTool(context, const PeriodControlPage()),
                ),
              ),
              const SizedBox(height: 6),
              const Tr('Alat bisnis', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              for (final t in tools)
                Card(
                  child: ListTile(
                    leading: CircleAvatar(child: Icon(t.$1)),
                    title: Tr(t.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Tr(t.$3),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openCompanyTool(context, t.$4),
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.lightbulb_outline),
                    const SizedBox(width: 10),
                    Expanded(child: Text(tr('Tip: faktur baru otomatis membuat Debit Piutang Usaha dan Kredit Penjualan. Saat dibayar, aplikasi membuat Debit Kas dan Kredit Piutang Usaha.'))),
                  ]),
                ),
              ),
            ]),
          );
        },
      );
}

class BusinessContactsPage extends StatelessWidget {
  const BusinessContactsPage({super.key});

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final note = TextEditingController();
    String kind = 'Pelanggan';
    await showDialog<void>(
      context: context,
      builder: (d) => StatefulBuilder(builder: (d, setState) => AlertDialog(
        title: const Tr('Kontak bisnis baru'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: deco('Nama')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: kind,
            decoration: deco('Jenis'),
            items: const [
              DropdownMenuItem(value: 'Pelanggan', child: Tr('Pelanggan')),
              DropdownMenuItem(value: 'Pemasok', child: Tr('Pemasok')),
            ],
            onChanged: (v) => setState(() => kind = v ?? kind),
          ),
          const SizedBox(height: 10),
          TextField(controller: phone, decoration: deco('Telepon / kontak')),
          const SizedBox(height: 10),
          TextField(controller: note, decoration: deco('Catatan'), maxLines: 2),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Tr('Batal')),
          FilledButton(onPressed: () {
            final n = name.text.trim();
            if (n.isEmpty) return;
            if (businessContacts.value.any((x) =>
                x.kind == kind && x.name.toLowerCase() == n.toLowerCase())) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Tr('Nama pelanggan atau pemasok sudah ada. Gunakan nama lain.'),
                duration: Duration(seconds: 3),
              ));
              return;
            }
            businessContacts.value = [...businessContacts.value, BizContact(newBizEntityId('contact'), n, kind, phone.text.trim(), note.text.trim())];
            _commitCompanyTools();
            Navigator.pop(d);
          }, child: const Tr('Simpan')),
        ],
      )),
    );
    name.dispose(); phone.dispose(); note.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Tr('Pelanggan & Pemasok')),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _add(context), icon: const Icon(Icons.add), label: const Tr('Tambah')),
    body: ValueListenableBuilder<List<BizContact>>(
      valueListenable: businessContacts,
      builder: (context, list, _) => list.isEmpty
          ? const EmptyState(title: 'Belum ada kontak bisnis', hint: 'Tambahkan pelanggan atau pemasok pertama', icon: Icons.people_alt_outlined)
          : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
              for (final c in list)
                Card(child: ListTile(
                  leading: CircleAvatar(child: Icon(c.kind == 'Pelanggan' ? Icons.person_outline : Icons.local_shipping_outlined)),
                  title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text([tr(c.kind), if (c.phone.isNotEmpty) c.phone, if (c.note.isNotEmpty) c.note].join(' • ')),
                  trailing: IconButton(
                    tooltip: tr('Hapus'), icon: const Icon(Icons.delete_outline),
                    onPressed: () {
                      final used = businessInvoices.value.any((i) => i.contactName == c.name && i.status != 'void');
                      if (used) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Kontak masih dipakai pada faktur dan tidak dapat dihapus.')));
                        return;
                      }
                      businessContacts.value = businessContacts.value.where((x) => x.id != c.id).toList();
                      _commitCompanyTools();
                    },
                  ),
                )),
            ]),
    ),
  );
}

class BusinessInvoicesPage extends StatelessWidget {
  const BusinessInvoicesPage({super.key});

  static Acc _ar() => _ensureCompanyAccount('1-201', 'Piutang Usaha', 'Aset');
  static Acc _sales() => _ensureCompanyAccount('4-101', 'Penjualan', 'Pendapatan');
  static Acc _cash() => _ensureCompanyAccount('1-101', 'Kas', 'Aset');

  static void _post(Journal j) {
    journals.value = [j, ...journals.value]..sort((a, b) => b.when.compareTo(a.when));
    applyJournal(j, 1);
  }

  Future<void> _newInvoice(BuildContext context) async {
    if (businessContacts.value.where((c) => c.kind == 'Pelanggan').isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Tambahkan minimal satu pelanggan terlebih dahulu.')));
      return;
    }
    final amt = TextEditingController();
    final customerNames = businessContacts.value
        .where((c) => c.kind == 'Pelanggan').map((c) => c.name).toSet().toList();
    String customer = customerNames.first;
    DateTime due = DateTime.now().add(const Duration(days: 14));
    await showDialog<void>(context: context, builder: (d) => StatefulBuilder(builder: (d, setState) => AlertDialog(
      title: const Tr('Faktur penjualan baru'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(
          value: customer,
          decoration: deco('Pelanggan'),
          items: [for (final customerName in customerNames)
            DropdownMenuItem(value: customerName, child: Text(customerName))],
          onChanged: (v) => setState(() => customer = v ?? customer),
        ),
        const SizedBox(height: 10),
        moneyField(amt, 'Nilai faktur', null),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final x = await showDatePicker(context: d, initialDate: due, firstDate: DateTime.now(), lastDate: DateTime(DateTime.now().year + 5));
            if (x != null) setState(() => due = x);
          },
          icon: const Icon(Icons.event_outlined), label: Text('${tr('Jatuh tempo')}: ${dateFull(due)}'),
        ),
        const SizedBox(height: 8),
        const Tr('Saat disimpan: Debit Piutang Usaha, Kredit Penjualan.', style: TextStyle(fontSize: 12)),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Tr('Batal')),
        FilledButton(onPressed: () {
          final n = parseMoney(amt.text);
          final now = DateTime.now();
          if (n <= 0) return;
          if (isCompanyPeriodClosed(now)) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Periode saat ini terkunci. Buka kembali periode untuk membuat faktur.')));
            return;
          }
          final ar = _ar(); final sales = _sales();
          final seq = (businessInvoices.value.length + 1).toString().padLeft(3, '0');
          final number = 'INV-${now.year}${now.month.toString().padLeft(2, '0')}-$seq';
          final inv = BizInvoice(newBizEntityId('invoice'), number, customer, n, now, due, 'open');
          businessInvoices.value = [inv, ...businessInvoices.value];
          _post(Journal(now, 'Faktur $number • $customer', [(ar.name, n, 0), (sales.name, 0, n)]));
          _commitCompanyTools();
          Navigator.pop(d);
        }, child: const Tr('Terbitkan')),
      ],
    )));
    amt.dispose();
  }

  void _pay(BuildContext context, BizInvoice i) {
    final now = DateTime.now();
    if (isCompanyPeriodClosed(now)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Periode saat ini terkunci.')));
      return;
    }
    final cash = _cash(); final ar = _ar();
    _post(Journal(now, 'Pembayaran faktur ${i.number} • ${i.contactName}', [(cash.name, i.amount, 0), (ar.name, 0, i.amount)]));
    businessInvoices.value = [for (final x in businessInvoices.value) x.id == i.id ? x.copyWith(status: 'paid') : x];
    _commitCompanyTools();
  }

  void _void(BuildContext context, BizInvoice i) {
    final now = DateTime.now();
    if (isCompanyPeriodClosed(now)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Periode saat ini terkunci.')));
      return;
    }
    final ar = _ar(); final sales = _sales();
    _post(Journal(now, 'Pembatalan faktur ${i.number} • ${i.contactName}', [(sales.name, i.amount, 0), (ar.name, 0, i.amount)]));
    businessInvoices.value = [for (final x in businessInvoices.value) x.id == i.id ? x.copyWith(status: 'void') : x];
    _commitCompanyTools();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Tr('Faktur & Piutang')),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _newInvoice(context), icon: const Icon(Icons.add), label: const Tr('Faktur baru')),
    body: ValueListenableBuilder<List<BizInvoice>>(
      valueListenable: businessInvoices,
      builder: (context, list, _) {
        final open = list.where((x) => x.status == 'open').fold<num>(0, (s, x) => s + x.amount);
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          Card(child: ListTile(leading: const Icon(Icons.account_balance_wallet_outlined), title: const Tr('Total piutang terbuka'), trailing: Text(rp(open), style: const TextStyle(fontWeight: FontWeight.w800)))),
          if (list.isEmpty)
            const EmptyState(title: 'Belum ada faktur', hint: 'Buat faktur pertama untuk mencatat piutang penjualan', icon: Icons.receipt_long_outlined)
          else
            for (final i in list)
              Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(i.number, style: const TextStyle(fontWeight: FontWeight.w800))),
                  Chip(label: Tr(i.status == 'paid' ? 'Lunas' : i.status == 'void' ? 'Batal' : DateTime.now().isAfter(i.due) ? 'Jatuh tempo' : 'Terbuka')),
                ]),
                Text(i.contactName),
                const SizedBox(height: 6),
                Text(rp(i.amount), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                Text('${tr('Terbit')} ${dateFull(i.issued)} • ${tr('Jatuh tempo')} ${dateFull(i.due)}', style: Theme.of(context).textTheme.bodySmall),
                if (i.status == 'open') ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: FilledButton.icon(onPressed: () => _pay(context, i), icon: const Icon(Icons.check), label: const Tr('Tandai dibayar'))),
                    const SizedBox(width: 8),
                    IconButton(tooltip: tr('Batalkan faktur'), onPressed: () => _void(context, i), icon: const Icon(Icons.block)),
                  ]),
                ],
              ]))),
        ]);
      },
    ),
  );
}

class BusinessStockPage extends StatelessWidget {
  const BusinessStockPage({super.key});

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController(); final sku = TextEditingController();
    final qty = TextEditingController(text: '0'); final cost = TextEditingController(text: '0');
    final price = TextEditingController(text: '0'); final minQty = TextEditingController(text: '0');
    await showDialog<void>(context: context, builder: (d) => AlertDialog(
      title: const Tr('Produk / stok baru'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: deco('Nama produk')),
        const SizedBox(height: 10), TextField(controller: sku, decoration: deco('SKU / kode')),
        const SizedBox(height: 10), TextField(controller: qty, keyboardType: TextInputType.number, decoration: deco('Stok awal')),
        const SizedBox(height: 10), moneyField(cost, 'Biaya per unit', null),
        const SizedBox(height: 10), moneyField(price, 'Harga jual', null),
        const SizedBox(height: 10), TextField(controller: minQty, keyboardType: TextInputType.number, decoration: deco('Batas stok minimum')),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Tr('Batal')),
        FilledButton(onPressed: () {
          final quantity = num.tryParse(qty.text.replaceAll(',', '.'));
          final minimum = num.tryParse(minQty.text.replaceAll(',', '.'));
          final cleanSku = sku.text.trim();
          final duplicate = cleanSku.isNotEmpty && stockItems.value.any((x) =>
              x.sku.toLowerCase() == cleanSku.toLowerCase());
          if (name.text.trim().isEmpty || quantity == null || minimum == null ||
              !quantity.isFinite || !minimum.isFinite || quantity < 0 || minimum < 0 || duplicate) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(duplicate ? 'SKU sudah dipakai oleh produk lain.'
                  : 'Isi nama dan jumlah stok yang valid (tidak negatif).'),
              duration: const Duration(seconds: 3),
            ));
            return;
          }
          stockItems.value = [...stockItems.value, StockItem(newBizEntityId('stock'), name.text.trim(), cleanSku, quantity, parseMoney(cost.text), parseMoney(price.text), minimum)];
          _commitCompanyTools(); Navigator.pop(d);
        }, child: const Tr('Simpan')),
      ],
    ));
    for (final c in [name, sku, qty, cost, price, minQty]) { c.dispose(); }
  }

  Future<void> _adjust(BuildContext context, StockItem x) async {
    final q = TextEditingController(text: '${x.qty}');
    await showDialog<void>(context: context, builder: (d) => AlertDialog(
      title: Text(tr('Sesuaikan stok {name}', {'name': x.name})),
      content: TextField(controller: q, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: deco('Jumlah stok terbaru')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Tr('Batal')),
        FilledButton(onPressed: () {
          final n = num.tryParse(q.text.replaceAll(',', '.'));
          if (n == null || n < 0) return;
          stockItems.value = [for (final s in stockItems.value) s.id == x.id ? s.copyWith(qty: n) : s];
          _commitCompanyTools(); Navigator.pop(d);
        }, child: const Tr('Simpan')),
      ],
    ));
    q.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Tr('Produk & Stok')),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _add(context), icon: const Icon(Icons.add), label: const Tr('Produk baru')),
    body: ValueListenableBuilder<List<StockItem>>(
      valueListenable: stockItems,
      builder: (context, list, _) {
        final value = list.fold<num>(0, (s, x) => s + x.qty * x.cost);
        final low = list.where((x) => x.qty <= x.minQty).length;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          Card(child: ListTile(leading: const Icon(Icons.inventory_2_outlined), title: Text('${list.length} ${tr('produk')} • $low ${tr('stok menipis')}'), subtitle: Text('${tr('Estimasi nilai biaya stok')}: ${rp(value)}'))),
          Card(child: Padding(padding: const EdgeInsets.all(12), child: Tr('Modul stok ini bersifat operasional. Penyesuaian jumlah stok tidak otomatis membuat jurnal agar pengguna tidak tanpa sengaja mengubah laporan keuangan.', style: Theme.of(context).textTheme.bodySmall))),
          if (list.isEmpty)
            const EmptyState(title: 'Belum ada produk', hint: 'Tambahkan produk atau barang pertama', icon: Icons.inventory_2_outlined)
          else
            for (final x in list)
              Card(child: ListTile(
                leading: CircleAvatar(child: Icon(x.qty <= x.minQty ? Icons.warning_amber : Icons.inventory_outlined)),
                title: Text(x.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${x.sku.isEmpty ? tr('Tanpa SKU') : x.sku} • ${tr('Biaya')} ${rp(x.cost)} • ${tr('Jual')} ${rp(x.price)}'),
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [Text('${x.qty}', style: const TextStyle(fontWeight: FontWeight.w800)), Text(tr('unit'), style: Theme.of(context).textTheme.bodySmall)]),
                onTap: () => _adjust(context, x),
                onLongPress: () { stockItems.value = stockItems.value.where((s) => s.id != x.id).toList(); _commitCompanyTools(); },
              )),
        ]);
      },
    ),
  );
}

class BusinessAnalyticsPage extends StatelessWidget {
  const BusinessAnalyticsPage({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([journals, accounts, companyReportPeriod]),
    builder: (context, _) {
      final end = companyReportPeriod.value;
      final periods = [for (var k = 5; k >= 0; k--) DateTime(end.year, end.month - k)];
      final rows = [
        for (final p in periods)
          (
            p,
            reportPeriodRows('Pendapatan', p).fold<num>(0, (s, x) => s + x.$2),
            reportPeriodRows('Beban', p).fold<num>(0, (s, x) => s + x.$2),
          )
      ];
      final maxV = rows.fold<double>(1.0, (m, x) => math.max(m, math.max(x.$2.abs().toDouble(), x.$3.abs().toDouble())));
      final current = rows.last;
      final profit = current.$2 - current.$3;
      final margin = current.$2 == 0 ? 0 : profit / current.$2 * 100;
      return Scaffold(
        appBar: AppBar(title: const Tr('Analisis Bisnis')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
          Card(child: ListTile(title: const Tr('Laba periode aktif'), trailing: Text(rp(profit), style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: Text('${tr('Margin laba')} ${margin.toStringAsFixed(1)}%'))),
          const SizedBox(height: 4),
          const Tr('Pemasukan vs Beban • 6 periode', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 10),
          Card(child: Padding(padding: const EdgeInsets.fromLTRB(14, 18, 14, 14), child: SizedBox(height: 230, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final r in rows)
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(width: 12, height: math.max(4.0, 170.0 * r.$2.abs().toDouble() / maxV), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(4))),
                  const SizedBox(width: 3),
                  Container(width: 12, height: math.max(4.0, 170.0 * r.$3.abs().toDouble() / maxV), decoration: BoxDecoration(color: Theme.of(context).colorScheme.tertiary, borderRadius: BorderRadius.circular(4))),
                ])),
                const SizedBox(height: 8), Text(tr('s${r.$1.month}'), style: Theme.of(context).textTheme.labelSmall),
              ])),
          ])))),
          Row(children: [
            Expanded(child: ListTile(dense: true, leading: Icon(Icons.square, color: Theme.of(context).colorScheme.primary, size: 16), title: const Tr('Pendapatan'))),
            Expanded(child: ListTile(dense: true, leading: Icon(Icons.square, color: Theme.of(context).colorScheme.tertiary, size: 16), title: const Tr('Beban'))),
          ]),
          for (final r in rows.reversed)
            Card(child: ListTile(
              title: Text(periodLabel(r.$1), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${tr('Pendapatan')} ${rp(r.$2)} • ${tr('Beban')} ${rp(r.$3)}'),
              trailing: Text(rp(r.$2 - r.$3), style: const TextStyle(fontWeight: FontWeight.w800)),
            )),
        ]),
      );
    },
  );
}

class PeriodControlPage extends StatelessWidget {
  const PeriodControlPage({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
    valueListenable: companyReportPeriod,
    builder: (context, p, _) => ValueListenableBuilder<List<String>>(
      valueListenable: closedBusinessPeriods,
      builder: (context, closed, _) {
        final key = companyPeriodAnchorKey(p);
        final locked = closed.contains(key);
        final periodJournals = journals.value.where((j) => journalInPeriod(j, p)).toList();
        final bad = periodJournals.where((j) => !journalBalanced(j)).length;
        return Scaffold(
          appBar: AppBar(title: const Tr('Kontrol Periode')),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            Card(child: Row(children: [
              IconButton(onPressed: () => companyReportPeriod.value = DateTime(p.year, p.month - 1), icon: const Icon(Icons.chevron_left)),
              Expanded(child: Center(child: Text(periodLabel(p), style: const TextStyle(fontWeight: FontWeight.w800)))),
              IconButton(onPressed: () => companyReportPeriod.value = DateTime(p.year, p.month + 1), icon: const Icon(Icons.chevron_right)),
            ])),
            Card(child: ListTile(
              leading: CircleAvatar(child: Icon(locked ? Icons.lock : Icons.lock_open)),
              title: Tr(locked ? 'Periode terkunci' : 'Periode masih terbuka', style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: Text(tr('{n} jurnal • {bad} perlu diperiksa', {'n': periodJournals.length, 'bad': bad})),
            )),
            FilledButton.icon(
              onPressed: () {
                if (!locked && bad > 0) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Tr('Perbaiki jurnal yang tidak seimbang sebelum mengunci periode.')));
                  return;
                }
                closedBusinessPeriods.value = locked ? closed.where((x) => x != key).toList() : [...closed, key];
                _commitCompanyTools();
              },
              icon: Icon(locked ? Icons.lock_open : Icons.lock),
              label: Tr(locked ? 'Buka kembali periode' : 'Kunci periode ini'),
            ),
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Tr('Apa yang terjadi saat dikunci?', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Tr('• Jurnal baru tidak dapat disimpan pada periode tersebut.\n• Jurnal lama pada periode tersebut tidak dapat dihapus dengan swipe.\n• Laporan tetap dapat dibuka dan diekspor.\n• Periode dapat dibuka kembali bila memang perlu koreksi.'),
            ]))),
          ]),
        );
      },
    ),
  );
}

class MonthlyChecklistPage extends StatelessWidget {
  const MonthlyChecklistPage({super.key});
  static const tasks = <(String, String)>[
    ('journal', 'Periksa semua jurnal dan pastikan Debit = Kredit'),
    ('bank', 'Cocokkan saldo Kas/Bank dengan catatan nyata'),
    ('receivable', 'Tinjau faktur dan piutang yang belum dibayar'),
    ('payable', 'Tinjau utang dan kewajiban yang jatuh tempo'),
    ('stock', 'Hitung stok fisik dan cek barang menipis'),
    ('report', 'Baca Neraca, Laba Rugi, Arus Kas, dan CALK'),
    ('backup', 'Buat cadangan data setelah bulan selesai'),
  ];

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
    valueListenable: companyReportPeriod,
    builder: (context, p, _) => ValueListenableBuilder<List<String>>(
      valueListenable: monthlyChecklistDone,
      builder: (context, done, _) {
        final pk = companyPeriodAnchorKey(p);
        bool checked(String id) => done.contains('$pk|$id');
        final completed = tasks.where((t) => checked(t.$1)).length;
        return Scaffold(
          appBar: AppBar(title: const Tr('Checklist Bulanan')),
          body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            Card(child: Row(children: [
              IconButton(onPressed: () => companyReportPeriod.value = DateTime(p.year, p.month - 1), icon: const Icon(Icons.chevron_left)),
              Expanded(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(periodLabel(p), style: const TextStyle(fontWeight: FontWeight.w800)), Text('$completed/${tasks.length} ${tr('selesai')}', style: Theme.of(context).textTheme.bodySmall)])),
              IconButton(onPressed: () => companyReportPeriod.value = DateTime(p.year, p.month + 1), icon: const Icon(Icons.chevron_right)),
            ])),
            LinearProgressIndicator(value: completed / tasks.length, minHeight: 8),
            const SizedBox(height: 14),
            Card(child: Column(children: [
              for (final t in tasks)
                CheckboxListTile(
                  value: checked(t.$1),
                  title: Tr(t.$2),
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: (v) {
                    final token = '$pk|${t.$1}';
                    monthlyChecklistDone.value = v == true ? {...done, token}.toList() : done.where((x) => x != token).toList();
                    _commitCompanyTools();
                  },
                ),
            ])),
          ]),
        );
      },
    ),
  );
}

class AccountingGlossaryPage extends StatelessWidget {
  const AccountingGlossaryPage({super.key});

  @override
  Widget build(BuildContext context) {
    const items = <(String, String)>[
      ('Debit', 'Sisi kiri jurnal. Aset dan beban umumnya bertambah di Debit.'),
      ('Kredit', 'Sisi kanan jurnal. Liabilitas, ekuitas, dan pendapatan umumnya bertambah di Kredit.'),
      ('Aset', 'Sumber daya yang dimiliki atau dikendalikan bisnis, misalnya kas, piutang, persediaan, dan peralatan.'),
      ('Liabilitas', 'Kewajiban bisnis kepada pihak lain, misalnya utang usaha atau pinjaman bank.'),
      ('Ekuitas', 'Hak pemilik atas aset setelah dikurangi liabilitas.'),
      ('Pendapatan', 'Nilai yang diperoleh dari kegiatan usaha dalam suatu periode.'),
      ('Beban', 'Pengorbanan ekonomi untuk menjalankan bisnis dan menghasilkan pendapatan.'),
      ('Piutang Usaha', 'Hak menagih pelanggan karena penjualan belum dibayar.'),
      ('Utang Usaha', 'Kewajiban kepada pemasok karena pembelian belum dibayar.'),
      ('Neraca', 'Laporan posisi Aset, Liabilitas, dan Ekuitas pada suatu tanggal.'),
      ('Laba Rugi', 'Laporan Pendapatan dikurangi Beban selama suatu periode.'),
      ('Arus Kas', 'Laporan pergerakan kas dari aktivitas operasi, investasi, dan pendanaan.'),
      ('CALK', 'Catatan atas laporan keuangan yang menjelaskan dasar, rincian, dan informasi penting di balik angka laporan.'),
    ];
    return Scaffold(
      appBar: AppBar(title: const Tr('Kamus Akuntansi')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Tr('Versi ringkas untuk belajar sambil menggunakan aplikasi. Istilah dibuat praktis dan tidak menggantikan buku teks atau standar akuntansi.', style: Theme.of(context).textTheme.bodySmall))),
        for (final x in items)
          Card(child: ExpansionTile(title: Tr(x.$1, style: const TextStyle(fontWeight: FontWeight.w800)), childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [Align(alignment: Alignment.centerLeft, child: Tr(x.$2))])),
      ]),
    );
  }
}


// ───────────────────────── Mode akuntansi ─────────────────────────

class AccSummary extends StatelessWidget {
  const AccSummary({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([accounts, journals, companyReportPeriod, companyName]),
        builder: (c, _) => _body(c),
      );

  Widget _body(BuildContext context) {
    final p = companyReportPeriod.value;
    final aset = reportRowsAt('Aset', p).fold<num>(0, (s, x) => s + x.$2);
    final liab = reportRowsAt('Liabilitas', p).fold<num>(0, (s, x) => s + x.$2);
    final equityBase = reportRowsAt('Ekuitas', p).fold<num>(0, (s, x) => s + x.$2);
    final cumulativeProfit = reportCumulativeProfit(p);
    final ekuitas = equityBase + cumulativeProfit;
    final pend = reportPeriodRows('Pendapatan', p).fold<num>(0, (s, x) => s + x.$2);
    final beban = reportPeriodRows('Beban', p).fold<num>(0, (s, x) => s + x.$2);
    final profit = pend - beban;
    final ok = nearlyEqual(aset, liab + ekuitas);
    final periodJournals = journals.value.where((j) => journalInPeriod(j, p)).toList();
    final unbalanced = periodJournals.where((j) => !journalBalanced(j)).length;

    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(companyName.value.isEmpty ? tr('Bisnis Utama') : companyName.value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(periodLabel(p), style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ]),
      const SizedBox(height: 8),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Tr(profit >= 0 ? 'Laba bersih periode' : 'Rugi bersih periode', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(rp(profit), style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Bar('Pendapatan periode', pend, math.max(pend, beban), Colors.green.shade600),
            const SizedBox(height: 10),
            Bar('Beban periode', beban, math.max(pend, beban), Colors.red.shade400),
          ]),
        ),
      ),
      const Heading('Posisi keuangan'),
      Row(children: [
        Expanded(child: StatCard('Aset', rp(aset), tone(context, Colors.indigo), Icons.inventory_2_outlined)),
        const SizedBox(width: 12),
        Expanded(child: StatCard('Liabilitas', rp(liab), tone(context, Colors.orange), Icons.request_quote_outlined)),
      ]),
      const SizedBox(height: 12),
      StatCard('Ekuitas', rp(ekuitas), tone(context, Colors.teal), Icons.account_balance_outlined),
      const Heading('Pemeriksaan cepat'),
      Card(
        child: Column(children: [
          ListTile(
            leading: Icon(ok ? Icons.check_circle : Icons.error_outline, color: ok ? Colors.green : Colors.red),
            title: Tr(ok ? 'Persamaan akuntansi seimbang' : 'Neraca tidak seimbang'),
            subtitle: const Tr('Aset = Liabilitas + Ekuitas'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(unbalanced == 0 ? Icons.check_circle_outline : Icons.warning_amber_outlined,
                color: unbalanced == 0 ? Colors.green : Colors.orange),
            title: Tr(unbalanced == 0 ? 'Semua jurnal periode seimbang' : 'Ada jurnal yang perlu diperiksa'),
            subtitle: Text(tr('{n} jurnal pada periode ini', {'n': periodJournals.length})),
          ),
        ]),
      ),
      const Heading('Jurnal terbaru'),
      if (journals.value.isEmpty)
        const EmptyState(title: 'Belum ada jurnal', hint: 'Tekan + untuk mulai mencatat transaksi bisnis', icon: Icons.menu_book_outlined)
      else
        for (final j in journals.value.take(2)) Padding(padding: const EdgeInsets.only(bottom: 12), child: JournalCard(j)),
    ]);
  }
}

class Bar extends StatelessWidget {
  final String label;
  final num v, max;
  final Color color;
  const Bar(this.label, this.v, this.max, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Tr(label), Text(rp(v))]),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: max == 0 ? 0 : (v / max).clamp(0, 1).toDouble(),
          minHeight: 8,
          color: color,
          borderRadius: BorderRadius.circular(6),
        ),
      ]);
}

class JournalCard extends StatelessWidget {
  final Journal j;
  const JournalCard(this.j, {super.key});
  Widget cell(num v) => SizedBox(
        width: 90,
        child: Text(v > 0 ? rp(v) : '', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12)),
      );
  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(j.date, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              Expanded(child: Text(tr(j.desc), style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            const Divider(height: 20),
            Row(children: [
              const Expanded(child: Tr('Akun', style: TextStyle(fontSize: 12))),
              const SizedBox(width: 90, child: Tr('Debit', textAlign: TextAlign.right, style: TextStyle(fontSize: 12))),
              const SizedBox(width: 90, child: Tr('Kredit', textAlign: TextAlign.right, style: TextStyle(fontSize: 12))),
            ]),
            const SizedBox(height: 6),
            for (final l in j.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Expanded(child: Padding(padding: EdgeInsets.only(left: l.$3 > 0 ? 16 : 0), child: Text(tr(l.$1)))),
                  cell(l.$2),
                  cell(l.$3),
                ]),
              ),
          ]),
        ),
      );
}

/// Jurnal yang berasal dari faktur harus tetap sejalan dengan status faktur.
/// Penghapusan manual akan memutus sinkronisasi piutang dan pembayaran.
bool isInvoiceLinkedJournal(Journal journal) {
  for (final inv in businessInvoices.value) {
    final suffix = '${inv.number} • ${inv.contactName}';
    if (journal.desc == 'Faktur $suffix' ||
        journal.desc == 'Pembayaran faktur $suffix' ||
        journal.desc == 'Pembatalan faktur $suffix') return true;
  }
  return false;
}

class JournalPage extends StatelessWidget {
  const JournalPage({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Journal>>(
        valueListenable: journals,
        builder: (context, list, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
          if (list.isEmpty)
            const EmptyState(
              title: 'Belum ada jurnal',
              hint: 'Tekan tombol + untuk mencatat jurnal pertama',
              icon: Icons.menu_book_outlined,
            )
          else ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Tr('Geser ke kiri untuk menghapus satu jurnal', style: Theme.of(context).textTheme.bodySmall),
            ),
            for (final j in list)
              if (isCompanyPeriodClosed(j.when) || isInvoiceLinkedJournal(j))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Stack(children: [
                    JournalCard(j),
                    Positioned(right: 12, top: 12,
                      child: Tooltip(
                        message: isCompanyPeriodClosed(j.when)
                            ? 'Periode ini terkunci'
                            : 'Jurnal faktur dikelola dari Faktur & Piutang',
                        child: Icon(isCompanyPeriodClosed(j.when) ? Icons.lock_outline : Icons.link, size: 18),
                      ),
                    ),
                  ]),
                )
              else
                SwipeDelete<Journal>(
                  store: journals,
                  item: j,
                  label: j.desc,
                  onRemoved: () => applyJournal(j, -1),
                  onRestored: () => applyJournal(j, 1),
                  child: JournalCard(j),
                ),
          ],
        ]),
      );
}

class AccountForm extends StatefulWidget {
  const AccountForm({super.key});
  @override
  State<AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends State<AccountForm> {
  final name = TextEditingController();
  final code = TextEditingController();
  String type = 'Aset';
  String? nameErr, codeErr;

  @override
  void initState() {
    super.initState();
    code.text = _suggestCode(type);
  }

  @override
  void dispose() {
    name.dispose();
    code.dispose();
    super.dispose();
  }

  String _suggestCode(String t) {
    final prefix = {'Aset': '1', 'Liabilitas': '2', 'Ekuitas': '3', 'Pendapatan': '4', 'Beban': '5'}[t] ?? '9';
    var max = 100;
    for (final a in accounts.value.where((a) => a.type == t)) {
      final parts = a.code.split('-');
      if (parts.length == 2) {
        final n = int.tryParse(parts.last);
        if (n != null && n > max) max = n;
      }
    }
    return '$prefix-${(max + 1).toString().padLeft(3, '0')}';
  }

  void save() {
    final nm = name.text.trim();
    final cd = code.text.trim();
    final sameName = accounts.value.any((a) => a.name.toLowerCase() == nm.toLowerCase());
    final sameCode = accounts.value.any((a) => a.code.toLowerCase() == cd.toLowerCase());
    setState(() {
      nameErr = nm.isEmpty ? 'Isi nama akun' : sameName ? 'Nama akun sudah ada' : null;
      codeErr = cd.isEmpty ? 'Isi kode akun' : sameCode ? 'Kode akun sudah ada' : null;
    });
    if (nm.isEmpty || cd.isEmpty || sameName || sameCode) return;
    accounts.value = [...accounts.value, Acc(cd, nm, type, 0)]..sort((a, b) => a.code.compareTo(b.code));
    syncActiveBusinessBook();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => formBody(context, 'Akun baru', [
        TextField(controller: name, decoration: deco('Nama akun', err: nameErr)),
        DropdownButtonFormField<String>(
          value: type,
          decoration: deco('Kelompok akun'),
          items: [for (final t in accTypes) DropdownMenuItem(value: t, child: Text(tr(t)))],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              type = v;
              code.text = _suggestCode(type);
              codeErr = null;
            });
          },
        ),
        TextField(controller: code, decoration: deco('Kode akun', err: codeErr)),
        Tr(
          'Saldo awal akun baru adalah 0. Masukkan perubahan saldo melalui jurnal agar jejak akuntansinya tetap jelas.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ], save);
}

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  Future<void> _delete(BuildContext context, Acc a) async {
    final used = journals.value.any((j) => j.lines.any((l) => l.$1 == a.name));
    if (a.bal != 0 || used) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Tr('Akun yang memiliki saldo atau pernah dipakai di jurnal tidak dapat dihapus.'),
        ));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Tr('Hapus akun?'),
        content: Text('${a.code} • ${a.name}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Tr('Batal')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Tr('Hapus')),
        ],
      ),
    );
    if (ok != true) return;
    accounts.value = accounts.value.where((x) => x != a).toList();
    syncActiveBusinessBook();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<Acc>>(
        valueListenable: accounts,
        builder: (c, _, __) => _list(c),
      );

  Widget _list(BuildContext context) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
        pageHeader(context, 'Daftar akun', 'Akun baru', Icons.add, () => showForm(context, const AccountForm())),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.school_outlined),
              const SizedBox(width: 10),
              Expanded(
                child: Tr(
                  'Panduan cepat: Aset & Beban normalnya bertambah di Debit. Liabilitas, Ekuitas & Pendapatan normalnya bertambah di Kredit.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ]),
          ),
        ),
        for (final t in accTypes) ...[
          Heading(t),
          Card(
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final a in byType(t))
                ListTile(
                  dense: true,
                  leading: SizedBox(width: 56, child: Text(a.code, style: const TextStyle(fontWeight: FontWeight.w600))),
                  title: Text(tr(a.name)),
                  subtitle: Text(
                    tr((a.type == 'Aset' || a.type == 'Beban') ? 'Saldo normal: Debit' : 'Saldo normal: Kredit'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(rp(a.bal)),
                    IconButton(
                      tooltip: tr('Hapus'),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _delete(context, a),
                    ),
                  ]),
                ),
            ]),
          ),
        ],
      ]);
}

// ───────────────────────── Laporan ─────────────────────────

class Sec {
  final String title, totalLabel;
  final List<(String, num)> rows;
  const Sec(this.title, this.rows, this.totalLabel);
  num get total => rows.fold<num>(0, (s, r) => s + r.$2);
}

// Saldo live saat ini. Dipakai oleh ringkasan dan kompatibilitas ekspor lama.
List<(String, num)> rowsOf(String t) => byType(t).map((a) => (a.name, a.bal)).toList();

DateTime accountingPeriodStart(DateTime p) => DateTime(p.year, p.month, startDay.value);
DateTime accountingPeriodEnd(DateTime p) => DateTime(p.year, p.month + 1, startDay.value);

bool journalInPeriod(Journal j, DateTime p) {
  final a = accountingPeriodStart(p);
  final b = accountingPeriodEnd(p);
  return !j.when.isBefore(a) && j.when.isBefore(b);
}

Acc? accountNamed(String name) {
  for (final a in accounts.value) {
    if (a.name == name) return a;
  }
  return null;
}

num journalEffectForAccount(Acc a, Journal j) {
  final sign = (a.type == 'Aset' || a.type == 'Beban') ? 1 : -1;
  return j.lines.fold<num>(0, (sum, l) {
    if (l.$1 != a.name) return sum;
    return sum + sign * (l.$2 - l.$3);
  });
}

/// Selisih ini mempertahankan data lama/import yang mungkin punya saldo akun
/// sebelum fitur periode diperkenalkan, tanpa mengarang jurnal baru.
num accountLegacyOpening(Acc a) =>
    a.bal - journals.value.fold<num>(0, (sum, j) => sum + journalEffectForAccount(a, j));

num accountBalanceBefore(Acc a, DateTime cutoff) {
  var value = accountLegacyOpening(a);
  for (final j in journals.value) {
    if (j.when.isBefore(cutoff)) value += journalEffectForAccount(a, j);
  }
  return value;
}

List<(String, num)> reportRowsAt(String type, DateTime p) {
  final end = accountingPeriodEnd(p);
  return [
    for (final a in accounts.value.where((a) => a.type == type)) (a.name, accountBalanceBefore(a, end)),
  ];
}

List<(String, num)> reportPeriodRows(String type, DateTime p) {
  final list = journals.value.where((j) => journalInPeriod(j, p));
  return [
    for (final a in accounts.value.where((a) => a.type == type))
      (a.name, list.fold<num>(0, (sum, j) => sum + journalEffectForAccount(a, j))),
  ];
}

num reportPeriodProfit(DateTime p) {
  final revenue = reportPeriodRows('Pendapatan', p).fold<num>(0, (s, x) => s + x.$2);
  final expense = reportPeriodRows('Beban', p).fold<num>(0, (s, x) => s + x.$2);
  return revenue - expense;
}

num reportCumulativeProfit(DateTime p) {
  final end = accountingPeriodEnd(p);
  num revenue = 0, expense = 0;
  for (final a in accounts.value) {
    if (a.type == 'Pendapatan') revenue += accountBalanceBefore(a, end);
    if (a.type == 'Beban') expense += accountBalanceBefore(a, end);
  }
  return revenue - expense;
}

bool nearlyEqual(num a, num b) => (a - b).abs() < 0.005;

bool journalBalanced(Journal j) {
  final debit = j.lines.fold<num>(0, (s, l) => s + l.$2);
  final credit = j.lines.fold<num>(0, (s, l) => s + l.$3);
  return nearlyEqual(debit, credit);
}

bool isCashAccount(Acc a) {
  if (a.type != 'Aset') return false;
  final n = a.name.toLowerCase();
  return n.contains('kas') || n.contains('cash') || n.contains('bank') || n.contains('rekening');
}

bool _isFixedAssetName(String name) {
  final n = name.toLowerCase();
  return n.contains('peralatan') ||
      n.contains('aset tetap') ||
      n.contains('kendaraan') ||
      n.contains('bangunan') ||
      n.contains('tanah') ||
      n.contains('investasi');
}

bool _isFinancingName(String name) {
  final n = name.toLowerCase();
  return n.contains('utang bank') ||
      n.contains('pinjaman') ||
      n.contains('loan') ||
      n.contains('modal') ||
      n.contains('dividen') ||
      n.contains('prive');
}

class CashFlowData {
  final num opening, operatingIn, operatingOut, investing, financing, ending;
  const CashFlowData(this.opening, this.operatingIn, this.operatingOut, this.investing, this.financing, this.ending);
  num get operatingNet => operatingIn + operatingOut;
  num get netChange => operatingNet + investing + financing;
}

CashFlowData buildCashFlow(DateTime p) {
  final begin = accountingPeriodStart(p);
  final end = accountingPeriodEnd(p);
  final cashAccounts = accounts.value.where(isCashAccount).toList();
  final cashNames = cashAccounts.map((a) => a.name).toSet();

  final opening = cashAccounts.fold<num>(0, (s, a) => s + accountBalanceBefore(a, begin));
  final ending = cashAccounts.fold<num>(0, (s, a) => s + accountBalanceBefore(a, end));

  num opIn = 0, opOut = 0, inv = 0, fin = 0;
  for (final j in journals.value.where((j) => journalInPeriod(j, p))) {
    for (final line in j.lines) {
      if (!cashNames.contains(line.$1)) continue;
      final nonCash = j.lines.where((x) => !cashNames.contains(x.$1)).toList();
      if (nonCash.isEmpty) continue; // transfer antar akun kas tidak mengubah arus kas total
      final other = accountNamed(nonCash.first.$1);
      final cashMove = line.$2 - line.$3; // debit kas = masuk, kredit kas = keluar
      if (other != null && other.type == 'Aset' && _isFixedAssetName(other.name)) {
        inv += cashMove;
      } else if (other != null &&
          (other.type == 'Ekuitas' || (other.type == 'Liabilitas' && _isFinancingName(other.name)))) {
        fin += cashMove;
      } else if (cashMove >= 0) {
        opIn += cashMove;
      } else {
        opOut += cashMove;
      }
    }
  }
  return CashFlowData(opening, opIn, opOut, inv, fin, ending);
}

class EquityChangeData {
  final num opening, ownerMovement, profit, ending;
  const EquityChangeData(this.opening, this.ownerMovement, this.profit, this.ending);
}

EquityChangeData buildEquityChange(DateTime p) {
  final begin = accountingPeriodStart(p);
  num openingBase = 0;
  for (final a in accounts.value) {
    if (a.type == 'Ekuitas' || a.type == 'Pendapatan' || a.type == 'Beban') {
      final v = accountBalanceBefore(a, begin);
      if (a.type == 'Beban') {
        openingBase -= v;
      } else {
        openingBase += v;
      }
    }
  }
  final ownerMovement = reportPeriodRows('Ekuitas', p).fold<num>(0, (s, x) => s + x.$2);
  final profit = reportPeriodProfit(p);
  return EquityChangeData(openingBase, ownerMovement, profit, openingBase + ownerMovement + profit);
}

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
        valueListenable: companyReportPeriod,
        builder: (context, p, _) {
          final items = <(IconData, String, String, Widget Function())>[
            (Icons.balance_outlined, 'Neraca', 'Posisi aset, liabilitas, dan ekuitas sampai akhir periode', () => neraca(p)),
            (Icons.trending_up, 'Laporan Laba Rugi', 'Pendapatan, beban, dan laba bersih khusus periode ini', () => labaRugi(p)),
            (Icons.water_drop_outlined, 'Laporan Arus Kas', 'Kas operasi, investasi, pendanaan, serta saldo awal/akhir', () => arusKas(p)),
            (Icons.stacked_bar_chart, 'Laporan Perubahan Ekuitas', 'Saldo awal, perubahan modal, laba, dan saldo akhir', () => perubahanEkuitas(p)),
            (Icons.description_outlined, 'CALK Ringkas', 'Catatan laporan, kebijakan perhitungan, dan pengecekan jurnal', () => CalkPage(p)),
          ];
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            ValueListenableBuilder<String>(
              valueListenable: companyName,
              builder: (c, n, _) => Text(
                n.isEmpty ? tr('Bisnis Utama') : n,
                style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Row(children: [
                IconButton(
                  tooltip: tr('Periode sebelumnya'),
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => companyReportPeriod.value = DateTime(p.year, p.month - 1),
                ),
                Expanded(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Tr('Periode laporan', style: TextStyle(fontSize: 12)),
                    Text(periodLabel(p), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
                IconButton(
                  tooltip: tr('Periode berikutnya'),
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => companyReportPeriod.value = DateTime(p.year, p.month + 1),
                ),
              ]),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.verified_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Tr(
                      'Laba rugi dihitung per periode. Neraca memakai saldo sampai akhir periode. Arus kas memakai saldo kas awal + perubahan periode = saldo kas akhir.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ]),
              ),
            ),
            for (final it in items)
              Card(
                child: ListTile(
                  leading: CircleAvatar(child: Icon(it.$1)),
                  title: Tr(it.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Tr(it.$3),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => it.$4())),
                ),
              ),
          ]);
        },
      );
}

class ReportPage extends StatelessWidget {
  final String title;
  final DateTime period;
  final List<Sec> sections;
  final Widget? footer;
  final List<(String, String)> summary;
  const ReportPage(this.title, this.period, this.sections, {super.key, this.footer, this.summary = const []});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Tr(title),
          actions: [
            IconButton(
              icon: const Icon(Icons.picture_as_pdf_outlined),
              tooltip: tr('Bagikan PDF'),
              onPressed: () {
                companyReportPeriod.value = period;
                exportReportPdf(context, title, sections, summary);
              },
            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
          Text(periodLabel(period), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 10),
          for (final s in sections)
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Tr(s.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 8),
                  for (final r in s.rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(child: Text(tr(r.$1))),
                        const SizedBox(width: 12),
                        Text(rp(r.$2)),
                      ]),
                    ),
                  const Divider(height: 20),
                  Row(children: [
                    Expanded(child: Tr(s.totalLabel, style: const TextStyle(fontWeight: FontWeight.bold))),
                    Text(rp(s.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                  ]),
                ]),
              ),
            ),
          if (footer != null) footer!,
        ]),
      );
}

Widget neraca(DateTime p) {
  final aset = Sec('Aset', reportRowsAt('Aset', p), 'Total aset');
  final liab = Sec('Liabilitas', reportRowsAt('Liabilitas', p), 'Total liabilitas');
  final accumulatedProfit = reportCumulativeProfit(p);
  final eku = Sec(
    'Ekuitas',
    [...reportRowsAt('Ekuitas', p), ('Akumulasi laba/rugi belum ditutup', accumulatedProfit)],
    'Total ekuitas',
  );
  final ok = nearlyEqual(aset.total, liab.total + eku.total);
  return ReportPage(
    'Neraca',
    p,
    [aset, liab, eku],
    summary: [(ok ? 'Seimbang' : 'Tidak seimbang', ''), ('Liabilitas + ekuitas', rp(liab.total + eku.total))],
    footer: ListTile(
      tileColor: (ok ? Colors.green : Colors.red).withValues(alpha: .1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(ok ? Icons.check_circle : Icons.error, color: ok ? Colors.green : Colors.red),
      title: Tr(ok ? 'Persamaan akuntansi seimbang' : 'Neraca tidak seimbang'),
      subtitle: Text(tr('Aset {a} • Liabilitas + Ekuitas {le}', {'a': rp(aset.total), 'le': rp(liab.total + eku.total)})),
    ),
  );
}

Widget labaRugi(DateTime p) {
  final revenue = Sec('Pendapatan', reportPeriodRows('Pendapatan', p), 'Total pendapatan');
  final expense = Sec('Beban', reportPeriodRows('Beban', p), 'Total beban');
  final profit = revenue.total - expense.total;
  return ReportPage(
    'Laporan Laba Rugi',
    p,
    [revenue, expense],
    summary: [('Laba bersih', rp(profit))],
    footer: Card(
      color: (profit >= 0 ? Colors.green : Colors.red).withValues(alpha: .12),
      child: ListTile(
        title: Tr(profit >= 0 ? 'Laba bersih' : 'Rugi bersih', style: const TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(rp(profit), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    ),
  );
}

Widget arusKas(DateTime p) {
  final cf = buildCashFlow(p);
  final reconciled = nearlyEqual(cf.opening + cf.netChange, cf.ending);
  return ReportPage(
    'Laporan Arus Kas',
    p,
    [
      Sec('Aktivitas operasi', [('Kas masuk operasi', cf.operatingIn), ('Kas keluar operasi', cf.operatingOut)], 'Kas bersih operasi'),
      Sec('Aktivitas investasi', [('Perolehan/pelepasan aset tetap', cf.investing)], 'Kas bersih investasi'),
      Sec('Aktivitas pendanaan', [('Pinjaman dan transaksi modal', cf.financing)], 'Kas bersih pendanaan'),
      Sec('Rekonsiliasi kas', [('Kas awal periode', cf.opening), ('Kenaikan/(penurunan) kas', cf.netChange)], 'Kas akhir terhitung'),
    ],
    summary: [('Saldo kas akhir', rp(cf.ending)), (reconciled ? 'Rekonsiliasi sesuai' : 'Perlu diperiksa', '')],
    footer: ListTile(
      tileColor: (reconciled ? Colors.green : Colors.orange).withValues(alpha: .1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(reconciled ? Icons.check_circle_outline : Icons.warning_amber_outlined),
      title: Tr(reconciled ? 'Kas awal + perubahan = kas akhir' : 'Ada selisih rekonsiliasi kas'),
      subtitle: Text(tr('Saldo kas akhir {v}', {'v': rp(cf.ending)})),
    ),
  );
}

Widget perubahanEkuitas(DateTime p) {
  final e = buildEquityChange(p);
  return ReportPage(
    'Laporan Perubahan Ekuitas',
    p,
    [
      Sec('Saldo awal', [('Ekuitas awal periode', e.opening)], 'Total saldo awal'),
      Sec(
        'Perubahan selama periode',
        [('Setoran/penarikan modal bersih', e.ownerMovement), ('Laba/(rugi) bersih periode', e.profit)],
        'Total perubahan',
      ),
    ],
    summary: [('Saldo akhir ekuitas', rp(e.ending))],
    footer: Card(
      color: Colors.green.withValues(alpha: .12),
      child: ListTile(
        title: const Tr('Saldo akhir ekuitas', style: TextStyle(fontWeight: FontWeight.bold)),
        trailing: Text(rp(e.ending), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      ),
    ),
  );
}

class CalkPage extends StatelessWidget {
  final DateTime period;
  const CalkPage(this.period, {super.key});

  @override
  Widget build(BuildContext context) {
    final periodJournals = journals.value.where((j) => journalInPeriod(j, period)).toList();
    final bad = periodJournals.where((j) => !journalBalanced(j)).toList();
    final revenue = reportPeriodRows('Pendapatan', period).where((x) => x.$2 != 0).toList()
      ..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
    final expense = reportPeriodRows('Beban', period).where((x) => x.$2 != 0).toList()
      ..sort((a, b) => b.$2.abs().compareTo(a.$2.abs()));
    final cf = buildCashFlow(period);

    Widget note(String title, String body, IconData icon) => Card(
          child: ListTile(
            isThreeLine: true,
            leading: CircleAvatar(child: Icon(icon)),
            title: Text(tr(title), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr(body)),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Tr('CALK Ringkas')),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
        Text(companyName.value.isEmpty ? tr('Bisnis Utama') : companyName.value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        Text(periodLabel(period), style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
        note(
          '1. Informasi umum',
          'CALK ini adalah catatan edukatif yang dibuat dari Buku Bisnis aktif. Mata uang mengikuti pengaturan aplikasi dan angka berasal dari jurnal yang dimasukkan pengguna.',
          Icons.business_outlined,
        ),
        note(
          '2. Dasar penyusunan',
          'Neraca memakai saldo sampai akhir periode. Laba rugi hanya memakai pendapatan dan beban pada periode terpilih. Saldo lama yang tidak memiliki jurnal diperlakukan sebagai saldo pembuka agar data lama tetap terbaca.',
          Icons.rule_outlined,
        ),
        note(
          '3. Kebijakan arus kas',
          'Kas dan bank dikenali dari akun aset yang namanya mengandung Kas, Cash, Bank, atau Rekening. Aset tetap diklasifikasikan sebagai investasi; pinjaman bank dan transaksi modal sebagai pendanaan; sisanya sebagai operasi.',
          Icons.water_drop_outlined,
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Tr('4. Pemeriksaan jurnal', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(tr('{n} jurnal pada periode ini', {'n': periodJournals.length})),
              Text(
                bad.isEmpty
                    ? tr('Semua jurnal seimbang: total Debit = total Kredit.')
                    : tr('{n} jurnal tidak seimbang dan perlu diperiksa.', {'n': bad.length}),
              ),
            ]),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Tr('5. Rincian penting periode', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (revenue.isEmpty && expense.isEmpty)
                const Tr('Belum ada pendapatan atau beban pada periode ini.')
              else ...[
                for (final x in revenue.take(3))
                  ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(tr(x.$1)), subtitle: const Tr('Pendapatan'), trailing: Text(rp(x.$2))),
                for (final x in expense.take(3))
                  ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(tr(x.$1)), subtitle: const Tr('Beban'), trailing: Text(rp(x.$2))),
              ],
              const Divider(),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Tr('Kas akhir periode'),
                trailing: Text(rp(cf.ending), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ),
        note(
          'Catatan penting',
          'Fitur ini membantu belajar dan menata pembukuan sederhana. Ia bukan pengganti penilaian akuntan, audit, perhitungan pajak, atau penerapan standar akuntansi yang memerlukan kebijakan dan pengungkapan lebih rinci.',
          Icons.info_outline,
        ),
      ]),
    );
  }
}
