// Fitur tambahan: transaksi terjadwal, cadangan data, kurs & konversi mata uang.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:path_provider/path_provider.dart'; // <-- BARU
import 'package:share_plus/share_plus.dart'; // <-- BARU

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'main.dart';
import 'persistence.dart';
import 'currency_rates.dart';

// ───────────────────────── Transaksi terjadwal ─────────────────────────

class Sched {
  final String title, cat, wallet, freq; // freq: daily | weekly | monthly
  final num amt;
  final bool income;
  final DateTime next;
  final int anchor; // tanggal dalam bulan untuk jadwal bulanan
  const Sched(this.title, this.cat, this.wallet, this.freq, this.amt, this.income, this.next, this.anchor);
  Sched withNext(DateTime n) => Sched(title, cat, wallet, freq, amt, income, n, anchor);
}

final schedules = ValueNotifier<List<Sched>>([]);

const _freqLabel = {'daily': 'Harian', 'weekly': 'Mingguan', 'monthly': 'Bulanan'};

DateTime _advance(Sched s) {
  final n = s.next;
  switch (s.freq) {
    case 'daily':
      return DateTime(n.year, n.month, n.day + 1);
    case 'weekly':
      return DateTime(n.year, n.month, n.day + 7);
    default:
      final lastDay = DateTime(n.year, n.month + 2, 0).day; // hari terakhir bulan depan
      return DateTime(n.year, n.month + 1, math.min(s.anchor, lastDay));
  }
}

/// Buat transaksi untuk semua jadwal yang sudah jatuh tempo, lalu majukan tanggalnya.
void runSchedules() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final added = <Tx>[];
  final updated = <Sched>[];
  var changed = false;
  for (final s0 in schedules.value) {
    var s = s0;
    var guard = 0;
    while (!s.next.isAfter(today) && guard < 400) {
      added.add(Tx(s.title, s.cat, s.next, s.amt, s.income, iconFor(s.cat), s.wallet));
      s = s.withNext(_advance(s));
      guard++;
    }
    if (!identical(s, s0)) changed = true;
    updated.add(s);
  }
  if (!changed) return;
  schedules.value = updated;
  txs.value = [...added, ...txs.value]..sort((a, b) => b.when.compareTo(a.when));
}

class ScheduledPage extends StatelessWidget {
  const ScheduledPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Transaksi terjadwal')),
        body: ValueListenableBuilder<List<Sched>>(
          valueListenable: schedules,
          builder: (context, list, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            pageHeader(context, tr('Transaksi terjadwal'), tr('Jadwal baru'), Icons.add, () => showForm(context, const SchedForm())),
            const SizedBox(height: 4),
            Text(tr('Transaksi dibuat otomatis saat aplikasi dibuka pada tanggal jatuh tempo.'),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (list.isEmpty)
              const EmptyState(
                title: 'Belum ada transaksi terjadwal',
                hint: 'Cocok untuk gaji, cicilan, atau langganan bulanan',
                icon: Icons.autorenew,
              )
            else
              for (final s in list)
                SwipeDelete<Sched>(
                  store: schedules,
                  item: s,
                  label: s.title,
                  child: Card(
                    margin: EdgeInsets.zero,
                    child: ListTile(
                      leading: CircleAvatar(child: Icon(iconFor(s.cat))),
                      title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${tr(_freqLabel[s.freq] ?? s.freq)} • ${tr('Berikutnya')} ${dateFull(s.next)}'),
                      trailing: Text(
                        '${s.income ? '+' : '-'}${rp(s.amt)}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: tone(context, s.income ? Colors.green : Colors.red)),
                      ),
                    ),
                  ),
                ),
          ]),
        ),
      );
}

class SchedForm extends StatefulWidget {
  const SchedForm({super.key});
  @override
  State<SchedForm> createState() => _SchedFormState();
}

class _SchedFormState extends State<SchedForm> {
  final title = TextEditingController();
  final amt = TextEditingController();
  bool income = false;
  String freq = 'monthly';
  String? cat, titleErr, amtErr, catErr;
  DateTime start = DateTime.now();
  String wallet = wallets.value.isEmpty ? '' : wallets.value.first.name;

  @override
  void dispose() {
    title.dispose();
    amt.dispose();
    super.dispose();
  }

  Future<void> pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: start,
      firstDate: DateTime(2020),
      lastDate: DateTime(DateTime.now().year + 5, 12, 31),
    );
    if (d != null && mounted) setState(() => start = d);
  }

  void save() {
    final n = parseMoney(amt.text);
    final c = cat;
    final t = title.text.trim();
    setState(() {
      titleErr = t.isEmpty ? 'Isi judul' : null;
      amtErr = n <= 0 ? 'Isi nominal lebih dari 0' : null;
      catErr = c == null ? 'Pilih kategori' : null;
    });
    if (t.isEmpty || n <= 0 || c == null) return;
    final d = DateTime(start.year, start.month, start.day);
    schedules.value = [...schedules.value, Sched(t, c, wallet, freq, n, income, d, d.day)];
    runSchedules();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => formBody(context, 'Jadwal baru', [
        TextField(controller: title, decoration: deco('Judul (mis. Gaji, Cicilan)', err: titleErr)),
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
            items: [for (final w in wallets.value) DropdownMenuItem(value: w.name, child: Text(w.name))],
            onChanged: (v) => setState(() => wallet = v ?? wallet),
          ),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            for (final e in _freqLabel.entries) ButtonSegment(value: e.key, label: Text(tr(e.value))),
          ],
          selected: {freq},
          onSelectionChanged: (s) => setState(() => freq = s.first),
        ),
        OutlinedButton.icon(
          onPressed: pickDate,
          icon: const Icon(Icons.event_outlined),
          label: Text('${tr('Mulai')}: ${dateFull(start)}'),
        ),
      ], save);
}

// ───────────────────────── Cadangan data ─────────────────────────

Map<String, dynamic>? _parseBackup(String text) {
  try {
    final x = jsonDecode(text.trim());
    if (x is Map && x['v'] == 1) return x.cast<String, dynamic>();
  } catch (_) {}
  return null;
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  final c = TextEditingController();
  String? err;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));

  Future<void> copy() async {
    final text = jsonEncode(AppStore.toJson());
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast(tr('Cadangan disalin ({n} karakter)', {'n': text.length}));
  }

  Future<void> paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text;
    if (t != null && mounted) {
      setState(() {
        c.text = t;
        err = null;
      });
    }
  }

  Future<void> restore() async {
    final m = _parseBackup(c.text);
    if (m == null) {
      setState(() => err = 'Data cadangan tidak valid');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Tr('Pulihkan data?'),
        content: const Tr('Semua data saat ini akan diganti dengan data dari cadangan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Tr('Batal')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Tr('Pulihkan')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppStore.fromJson(m);
    runSchedules();
    await AppStore.saveNow();
    if (!mounted) return;
    setState(() {
      c.clear();
      err = null;
    });
    _toast(tr('Data berhasil dipulihkan'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Cadangan data')),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Tr('Salin cadangan', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 4),
                Tr('Menyalin seluruh datamu sebagai teks. Tempel dan simpan di catatan atau pesan ke dirimu sendiri. PIN tidak ikut disalin.',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: copy, icon: const Icon(Icons.copy_outlined), label: const Tr('Salin cadangan')),
              ]),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Tr('Pulihkan dari cadangan', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const SizedBox(height: 12),
                TextField(
                  controller: c,
                  minLines: 4,
                  maxLines: 6,
                  onChanged: (_) => setState(() => err = null),
                  decoration: deco('Tempel teks cadangan di sini', err: err),
                ),
                const SizedBox(height: 12),
                Row(children: [
                  OutlinedButton.icon(onPressed: paste, icon: const Icon(Icons.content_paste_outlined), label: const Tr('Tempel')),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(onPressed: c.text.trim().isEmpty ? null : restore, child: const Tr('Pulihkan')),
                  ),
                ]),
              ]),
            ),
          ),
        ]),
      );
}

// ───────────────────────── Kurs & konversi ─────────────────────────

const _zeroDecimals = {'IDR', 'JPY', 'KRW', 'VND', 'CLP', 'PYG', 'UGX', 'RWF', 'XAF', 'XOF', 'XPF', 'KMF', 'GNF', 'DJF', 'BIF'};

String _fmtIn(double v, String code) {
  final dec = _zeroDecimals.contains(code) ? 0 : 2;
  final parts = v.abs().toStringAsFixed(dec).split('.');
  final s = parts[0];
  final sep = thousandSep.value;
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(sep);
    b.write(s[i]);
  }
  final dsep = sep == ',' ? '.' : ',';
  final body = dec > 0 ? '$b$dsep${parts[1]}' : '$b';
  final sym = curByCode(code).symbol;
  return symbolAfter.value ? '$body $sym' : '$sym$body';
}

class RatesPage extends StatefulWidget {
  const RatesPage({super.key});
  @override
  State<RatesPage> createState() => _RatesPageState();
}

class _RatesPageState extends State<RatesPage> {
  String from = currencyCode.value;
  late String to = from == 'USD' ? 'IDR' : 'USD';
  final amt = TextEditingController(text: '1');
  late Future<CurrencyQuote> fut = getCurrencyQuote(from, to);

  @override
  void dispose() {
    amt.dispose();
    super.dispose();
  }

  Future<void> pick(bool isFrom) async {
    final c = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => PickCurrencyPage(selected: isFrom ? from : to)),
    );
    if (c == null || !mounted) return;
    setState(() {
      if (isFrom) {
        from = c;
      } else {
        to = c;
      }
      fut = getCurrencyQuote(from, to);
    });
  }

  void swap() => setState(() {
        final t = from;
        from = to;
        to = t;
        fut = getCurrencyQuote(from, to);
      });

  Widget _row(String code, VoidCallback onTap) {
    final x = curByCode(code);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Text(flag(x.cc), style: const TextStyle(fontSize: 28)),
      title: Text('${x.name} • ${x.code}'),
      subtitle: Text(x.country),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final value = parseFormattedAmount(amt.text, fractionDigits: 2).toDouble();
    return Scaffold(
      appBar: AppBar(
        title: const Tr('Kurs mata uang'),
        actions: [
          IconButton(
            tooltip: tr('Perbarui'),
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => fut = getCurrencyQuote(from, to, force: true)),
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              TextField(
                controller: amt,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [MoneyGroupingInputFormatter(thousandSep.value, allowDecimals: true)],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: tr('Jumlah'), border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              _row(from, () => pick(true)),
            ]),
          ),
        ),
        Center(
          child: IconButton.filledTonal(
            tooltip: tr('Tukar'),
            icon: const Icon(Icons.swap_vert),
            onPressed: swap,
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<CurrencyQuote>(
              future: fut,
              builder: (context, snap) {
                final rate = snap.data?.rate;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _row(to, () => pick(false)),
                  const Divider(),
                  if (snap.connectionState != ConnectionState.done)
                    const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: LinearProgressIndicator())
                  else if (snap.hasError || rate == null) ...[
                    Row(children: [
                      Icon(Icons.wifi_off_outlined, color: cs.error),
                      const SizedBox(width: 8),
                      Expanded(child: Tr('Kurs tidak dapat dimuat. Periksa koneksi internet lalu coba lagi.', style: TextStyle(color: cs.error))),
                    ]),
                    const SizedBox(height: 8),
                    if (snap.hasError)
                      SelectableText('${snap.error}', style: Theme.of(context).textTheme.bodySmall),
                    if (!snap.hasError && rate == null)
                      Text('Kurs $from ke $to tidak tersedia dari sumber ini.', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => setState(() => fut = getCurrencyQuote(from, to, force: true)),
                      child: const Tr('Coba lagi'),
                    ),
                  ] else ...[
                    Text(_fmtIn(value * rate, to), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text('1 $from = ${rate.toStringAsFixed(rate < 1 ? 6 : 4)} $to', style: Theme.of(context).textTheme.bodyMedium),
                    if (snap.data!.data.isStale)
                      Text('Mode offline: memakai kurs terakhir yang tersimpan.',
                          style: TextStyle(color: cs.error, fontWeight: FontWeight.w600)),
                    Text('Sumber: ${snap.data!.data.source}', style: Theme.of(context).textTheme.bodySmall),
                    if (snap.data!.data.updated.isNotEmpty)
                      Text('${tr('Diperbarui')}: ${snap.data!.data.updated}', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ]);
              },
            ),
          ),
        ),
        Text(
          '${tr('Kurs bersifat indikatif dan diperbarui sekali sehari.')}\n${tr('Sumber')}: ExchangeRate-API, Frankfurter, dan Currency API mirror.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ]),
    );
  }
}

/// Pemilih mata uang yang mengembalikan kodenya (tidak mengubah mata uang tampilan aplikasi).
class PickCurrencyPage extends StatefulWidget {
  final String selected;
  const PickCurrencyPage({super.key, required this.selected});
  @override
  State<PickCurrencyPage> createState() => _PickCurrencyPageState();
}

class _PickCurrencyPageState extends State<PickCurrencyPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    bool match(Cur c) =>
        q.isEmpty || c.code.toLowerCase().contains(q) || c.name.toLowerCase().contains(q) || c.country.toLowerCase().contains(q);
    final rest = currencies.where(match).toList()..sort((a, b) => a.country.compareTo(b.country));
    final rows = <Object>[];
    if (q.isEmpty) {
      rows.add('Populer');
      rows.addAll(popularCodes.map(curByCode));
      rows.add('Semua mata uang');
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
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final r = rows[i];
              if (r is String) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(tr(r), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                );
              }
              final c = r as Cur;
              final sel = c.code == widget.selected;
              return ListTile(
                leading: Text(flag(c.cc), style: const TextStyle(fontSize: 28)),
                title: Text('${c.name} • ${c.code}'),
                subtitle: Text(c.country),
                selected: sel,
                trailing: sel ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, c.code),
              );
            },
          ),
        ),
      ]),
    );
  }
}

String _csvCell(Object? value) {
  final text = (value ?? '').toString().replaceAll('"', '""');
  if (text.contains(',') || text.contains('"') || text.contains('\n') || text.contains('\r')) {
    return '"$text"';
  }
  return text;
}

String _toCsv(List<List<Object?>> rows) => rows.map((row) => row.map(_csvCell).join(',')).join('\r\n');

Future<void> exportTransactionsCsv(BuildContext context) async {
  final rows = <List<Object?>>[
    ['Tanggal', 'Kategori', 'Judul', 'Nominal (${currencyCode.value})', 'Tipe', 'Rekening'],
  ];

  final data = txs.value.toList()..sort((a, b) => b.when.compareTo(a.when));

  for (final t in data) {
    rows.add([
      t.when.toIso8601String().split('T').first,
      tr(t.cat),
      t.title == t.cat ? tr(t.cat) : t.title,
      toDisplayMoney(t.amt),
      t.income ? 'Pemasukan' : 'Pengeluaran',
      t.wallet.isEmpty ? 'Umum' : t.wallet,
    ]);
  }

  // BOM membuat karakter non-ASCII lebih aman saat CSV dibuka di Excel.
  final csvData = '\uFEFF${_toCsv(rows)}';
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/laporan_transaksi.csv';
  final file = File(path);
  await file.writeAsString(csvData, flush: true);

  skipLock = true;
  try {
    await Share.shareXFiles(
      [XFile(path)],
      text: 'Laporan Transaksi Keuangan',
    );
  } finally {
    Future.delayed(const Duration(seconds: 3), () => skipLock = false);
  }
}

/// Ekspor seluruh data akuntansi perusahaan ke satu CSV yang dapat dibuka di Excel.
/// Bagian yang diekspor: ringkasan, daftar akun, jurnal umum, laporan utama,
/// CALK, faktur/piutang, pelanggan/pemasok, produk/stok, dan kontrol periode.
Future<void> exportCompanyAccountingCsv(BuildContext context) async {
  syncActiveBusinessBook();

  final rows = <List<Object?>>[];

  void blank() => rows.add(const []);
  void section(String title) {
    if (rows.isNotEmpty) blank();
    rows.add([title]);
  }

  final now = DateTime.now();
  final p = companyReportPeriod.value;
  final company = companyName.value.trim().isEmpty ? 'Bisnis Utama' : companyName.value.trim();

  num totalRows(List<(String, num)> values) => values.fold<num>(0, (s, x) => s + x.$2);
  num showAmount(num amount) => toDisplayMoney(amount);

  final assetRows = reportRowsAt('Aset', p);
  final liabilityRows = reportRowsAt('Liabilitas', p);
  final equityRows = reportRowsAt('Ekuitas', p);
  final accumulatedProfit = reportCumulativeProfit(p);
  final revenueRows = reportPeriodRows('Pendapatan', p);
  final expenseRows = reportPeriodRows('Beban', p);

  final aset = totalRows(assetRows);
  final liabilitas = totalRows(liabilityRows);
  final ekuitasDasar = totalRows(equityRows);
  final pendapatan = totalRows(revenueRows);
  final beban = totalRows(expenseRows);
  final labaBersih = pendapatan - beban;
  final ekuitasAkhir = ekuitasDasar + accumulatedProfit;
  final balanceOk = nearlyEqual(aset, liabilitas + ekuitasAkhir);

  rows.add(['LAPORAN AKUNTANSI PERUSAHAAN']);
  rows.add(['Buku Bisnis', company]);
  rows.add(['Periode', periodLabel(p)]);
  rows.add(['Diekspor', now.toIso8601String()]);
  rows.add(['Mata uang tampilan', currencyCode.value]);
  rows.add(['Mata uang dasar pembukuan', baseCurrencyCode.value]);
  rows.add(['Kurs 1 dasar ke tampilan', displayFxRate.value]);
  rows.add(['Tanggal/sumber kurs', '${displayFxUpdated.value} • ${displayFxSource.value}']);

  section('RINGKASAN');
  rows.add(['Pos', 'Nilai']);
  rows.add(['Aset sampai akhir periode', showAmount(aset)]);
  rows.add(['Liabilitas sampai akhir periode', showAmount(liabilitas)]);
  rows.add(['Ekuitas akun', showAmount(ekuitasDasar)]);
  rows.add(['Akumulasi laba/rugi belum ditutup', showAmount(accumulatedProfit)]);
  rows.add(['Pendapatan periode', showAmount(pendapatan)]);
  rows.add(['Beban periode', showAmount(beban)]);
  rows.add(['Laba/(rugi) bersih periode', showAmount(labaBersih)]);
  rows.add(['Status neraca', balanceOk ? 'Seimbang' : 'Tidak seimbang']);

  section('DAFTAR AKUN');
  rows.add(['Kode', 'Nama akun', 'Tipe', 'Saldo live']);
  final accountData = accounts.value.toList()..sort((a, b) => a.code.compareTo(b.code));
  for (final a in accountData) {
    rows.add([a.code, tr(a.name), tr(a.type), showAmount(a.bal)]);
  }

  section('JURNAL UMUM - PERIODE TERPILIH');
  rows.add(['Tanggal', 'Keterangan', 'Akun', 'Debit', 'Kredit']);
  final journalData = journals.value.where((j) => journalInPeriod(j, p)).toList()
    ..sort((a, b) => a.when.compareTo(b.when));
  for (final j in journalData) {
    for (final line in j.lines) {
      rows.add([
        j.when.toIso8601String().split('T').first,
        tr(j.desc),
        tr(line.$1),
        line.$2 == 0 ? '' : showAmount(line.$2),
        line.$3 == 0 ? '' : showAmount(line.$3),
      ]);
    }
  }

  void addStatementSection(String title, List<Sec> sections, {List<List<Object?>> summary = const []}) {
    section(title);
    for (final s in sections) {
      rows.add([tr(s.title)]);
      rows.add(['Pos', 'Nilai']);
      for (final r in s.rows) {
        rows.add([tr(r.$1), showAmount(r.$2)]);
      }
      rows.add([tr(s.totalLabel), showAmount(s.total)]);
      blank();
    }
    if (summary.isNotEmpty) rows.addAll(summary);
  }

  final neracaAset = Sec('Aset', assetRows, 'Total aset');
  final neracaLiab = Sec('Liabilitas', liabilityRows, 'Total liabilitas');
  final neracaEku = Sec(
    'Ekuitas',
    [...equityRows, ('Akumulasi laba/rugi belum ditutup', accumulatedProfit)],
    'Total ekuitas',
  );
  addStatementSection(
    'NERACA',
    [neracaAset, neracaLiab, neracaEku],
    summary: [
      ['Liabilitas + ekuitas', showAmount(neracaLiab.total + neracaEku.total)],
      ['Status', balanceOk ? 'Seimbang' : 'Tidak seimbang'],
    ],
  );

  addStatementSection(
    'LAPORAN LABA RUGI',
    [
      Sec('Pendapatan', revenueRows, 'Total pendapatan'),
      Sec('Beban', expenseRows, 'Total beban'),
    ],
    summary: [
      ['Laba/(rugi) bersih', showAmount(labaBersih)],
    ],
  );

  final cf = buildCashFlow(p);
  addStatementSection(
    'LAPORAN ARUS KAS',
    [
      Sec('Aktivitas operasi', [('Kas masuk operasi', cf.operatingIn), ('Kas keluar operasi', cf.operatingOut)], 'Kas bersih operasi'),
      Sec('Aktivitas investasi', [('Perolehan/pelepasan aset tetap', cf.investing)], 'Kas bersih investasi'),
      Sec('Aktivitas pendanaan', [('Pinjaman dan transaksi modal', cf.financing)], 'Kas bersih pendanaan'),
      Sec('Rekonsiliasi kas', [('Kas awal periode', cf.opening), ('Kenaikan/(penurunan) kas', cf.netChange)], 'Kas akhir terhitung'),
    ],
    summary: [
      ['Saldo kas akhir', showAmount(cf.ending)],
      ['Rekonsiliasi', nearlyEqual(cf.opening + cf.netChange, cf.ending) ? 'Sesuai' : 'Perlu diperiksa'],
    ],
  );

  final eq = buildEquityChange(p);
  addStatementSection(
    'LAPORAN PERUBAHAN EKUITAS',
    [
      Sec('Saldo awal', [('Ekuitas awal periode', eq.opening)], 'Total saldo awal'),
      Sec(
        'Perubahan selama periode',
        [('Setoran/penarikan modal bersih', eq.ownerMovement), ('Laba/(rugi) bersih periode', eq.profit)],
        'Total perubahan',
      ),
    ],
    summary: [
      ['Saldo akhir ekuitas', showAmount(eq.ending)],
    ],
  );

  section('FAKTUR & PIUTANG');
  rows.add(['Nomor', 'Pelanggan', 'Terbit', 'Jatuh tempo', 'Status', 'Nilai']);
  for (final i in businessInvoices.value) {
    rows.add([i.number, i.contactName, i.issued.toIso8601String().split('T').first, i.due.toIso8601String().split('T').first, i.status, showAmount(i.amount)]);
  }

  section('PELANGGAN & PEMASOK');
  rows.add(['Nama', 'Jenis', 'Kontak', 'Catatan']);
  for (final c in businessContacts.value) {
    rows.add([c.name, c.kind, c.phone, c.note]);
  }

  section('PRODUK & STOK');
  rows.add(['Produk', 'SKU', 'Jumlah', 'Biaya/unit', 'Harga jual', 'Stok minimum', 'Nilai biaya']);
  for (final x in stockItems.value) {
    rows.add([x.name, x.sku, x.qty, showAmount(x.cost), showAmount(x.price), x.minQty, showAmount(x.qty * x.cost)]);
  }

  section('KONTROL PERIODE');
  rows.add(['Periode', 'Status']);
  final key = companyPeriodAnchorKey(p);
  rows.add([key, closedBusinessPeriods.value.contains(key) ? 'Terkunci' : 'Terbuka']);

  section('CALK RINGKAS');
  rows.add(['Catatan', 'Keterangan']);
  rows.add([
    'Informasi umum',
    'CALK edukatif untuk Buku Bisnis "$company", periode ${periodLabel(p)}, mata uang ${currencyCode.value}.'
  ]);
  rows.add([
    'Dasar penyusunan',
    'Neraca memakai saldo sampai akhir periode. Laba rugi memakai pendapatan dan beban dalam periode terpilih.'
  ]);
  rows.add([
    'Saldo lama',
    'Saldo akun lama yang tidak memiliki jurnal diperlakukan sebagai saldo pembuka agar kompatibel dengan data versi sebelumnya.'
  ]);
  rows.add([
    'Arus kas',
    'Akun kas/bank dikenali dari akun aset bernama Kas/Cash/Bank/Rekening; aset tetap = investasi; pinjaman bank/modal = pendanaan; lainnya = operasi.'
  ]);
  final unbalanced = journalData.where((j) => !journalBalanced(j)).length;
  rows.add(['Kontrol jurnal', unbalanced == 0 ? 'Semua jurnal periode seimbang.' : '$unbalanced jurnal tidak seimbang.']);
  rows.add(['Konversi tampilan', 'Semua nominal CSV menggunakan ${currencyCode.value}; data asli disimpan dalam ${baseCurrencyCode.value}. Kurs dari ${displayFxSource.value}, tanggal ${displayFxUpdated.value}.']);
  rows.add([
    'Batasan',
    'Fitur ini untuk pembukuan sederhana dan pembelajaran; bukan pengganti audit, pajak, atau penerapan standar akuntansi profesional secara lengkap.'
  ]);

  final csvData = '\uFEFF${_toCsv(rows)}';
  final dir = await getTemporaryDirectory();
  final safeCompany = company
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final path = '${dir.path}/akuntansi_${safeCompany.isEmpty ? 'perusahaan' : safeCompany}.csv';
  final file = File(path);
  await file.writeAsString(csvData, flush: true);

  skipLock = true;
  try {
    await Share.shareXFiles(
      [XFile(path)],
      text: 'Laporan Akuntansi Perusahaan - $company (${periodLabel(p)})',
    );
  } finally {
    Future.delayed(const Duration(seconds: 3), () => skipLock = false);
  }
}
