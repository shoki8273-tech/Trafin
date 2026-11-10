import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'i18n.dart';
import 'extras.dart';
import 'main.dart';

// ───────────────────────── PIN ─────────────────────────
//
// [pin].value menyimpan "salt:hash" (SHA-256), bukan PIN-nya. PIN 4 digit tetap
// mudah ditebak bila penyimpanan perangkat bocor, jadi ini perlindungan dasar,
// bukan enkripsi data.

String _newSalt() {
  final r = math.Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String hashPin(String pinText, [String? salt]) {
  final s = salt ?? _newSalt();
  final h = sha256.convert(utf8.encode('$s:$pinText')).toString();
  return '$s:$h';
}

bool verifyPin(String entered) {
  final stored = pin.value;
  if (stored == null) return true;
  final i = stored.indexOf(':');
  if (i < 0) return false;
  return hashPin(entered, stored.substring(0, i)) == stored;
}

// ───────────────────────── Penyimpanan data ─────────────────────────

const _kData = 'mb_data_v1';
const _kPin = 'mb_pin_v1';
const _secure = FlutterSecureStorage();

class AppStore {
  static SharedPreferences? _prefs;
  static Timer? _timer;
  static bool _ready = false;

  static List<Listenable> get _watched => [
        txs, goals, accounts, journals, wallets, budgets, debts,
        themeMode, seedColor, userName, companyName, showIndicator, currency, currencyCode,
        symbolAfter, thousandSep, decimals, dateFormat, startDay, appLocale, schedules,
         baseCurrencyCode, displayFxRate, displayFxUpdated, displayFxSource,
        customExpenseCats, customIncomeCats, businessBooks, activeBusinessBookId,
      ];

  /// Muat data tersimpan lalu mulai menyimpan otomatis setiap ada perubahan.
  static Future<void> init() async {
    detach();
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      _prefs = null;
      debugPrint('SharedPreferences tidak tersedia: $e');
    }
    _load();
    await _loadPin();
    for (final l in _watched) {
      l.addListener(_schedule);
    }
    pin.addListener(_savePin);
    _ready = true;
    locked.value = pin.value != null;
  }

  /// Hentikan penyimpanan otomatis (dipakai di test).
  static void detach() {
    _ready = false;
    _timer?.cancel();
    _timer = null;
    for (final l in _watched) {
      l.removeListener(_schedule);
    }
    pin.removeListener(_savePin);
  }

  static void _schedule() {
    if (!_ready) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () => unawaited(saveNow()));
  }

  static Future<void> saveNow() async {
    _timer?.cancel();
    _timer = null;
    final p = _prefs;
    if (p == null) return;
    try {
      await p.setString(_kData, jsonEncode(_toJson()));
    } catch (e) {
      debugPrint('Gagal menyimpan data: $e');
    }
  }

  static Map<String, dynamic> toJson() => _toJson();

  static Map<String, dynamic> _toJson() => {
        'v': 1,
        'settings': {
          'theme': themeMode.value.index,
          'seed': seedColor.value.toARGB32(),
          'user': userName.value,
          'company': companyName.value,
          'indicator': showIndicator.value,
          'currency': currency.value,
          'currencyCode': currencyCode.value,
          'baseCurrencyCode': baseCurrencyCode.value,
          'displayFxRate': displayFxRate.value,
          'displayFxUpdated': displayFxUpdated.value,
          'displayFxSource': displayFxSource.value,
          'symbolAfter': symbolAfter.value,
          'sep': thousandSep.value,
          'decimals': decimals.value,
          'dateFormat': dateFormat.value,
          'startDay': startDay.value,
          'locale': appLocale.value,
          'customCats': customExpenseCats.value,
          'customIncomeCats': customIncomeCats.value,
        },
        'txs': [
          for (final t in txs.value)
            {'title': t.title, 'cat': t.cat, 'wallet': t.wallet, 'when': t.when.toIso8601String(), 'amt': t.amt, 'income': t.income},
        ],
        'goals': [
          for (final g in goals.value) {'name': g.name, 'saved': g.saved, 'target': g.target, 'deadline': g.deadline},
        ],
        'accounts': [
          for (final a in accounts.value) {'code': a.code, 'name': a.name, 'type': a.type, 'bal': a.bal},
        ],
        'journals': [
          for (final j in journals.value)
            {
              'when': j.when.toIso8601String(),
              'desc': j.desc,
              'lines': [
                for (final l in j.lines) [l.$1, l.$2, l.$3],
              ],
            },
        ],
        'wallets': [
          for (final w in wallets.value) {'name': w.name, 'type': w.type, 'start': w.start},
        ],
        'budgets': [
          for (final b in budgets.value) {'cat': b.cat, 'limit': b.limit},
        ],
        'debts': [
          for (final d in debts.value)
            {'who': d.who, 'amt': d.amt, 'mine': d.mine, 'due': d.due?.toIso8601String(), 'paid': d.paid},
        ],
        'schedules': [
          for (final s in schedules.value)
            {
              'title': s.title,
              'cat': s.cat,
              'wallet': s.wallet,
              'freq': s.freq,
              'amt': s.amt,
              'income': s.income,
              'next': s.next.toIso8601String(),
              'anchor': s.anchor,
            },
        ],
        'activeBusinessBookId': activeBusinessBookId.value,
        'businessBooks': [
          for (final b in businessBooks.value)
            {
              'id': b.id,
              'name': b.name,
              'createdAt': b.createdAt.toIso8601String(),
              'accounts': [
                for (final a in b.accounts) {'code': a.code, 'name': a.name, 'type': a.type, 'bal': a.bal},
              ],
              'journals': [
                for (final j in b.journals)
                  {
                    'when': j.when.toIso8601String(),
                    'desc': j.desc,
                    'lines': [
                      for (final l in j.lines) [l.$1, l.$2, l.$3],
                    ],
                  },
              ],
              'contacts': [
                for (final c in b.contacts)
                  {'id': c.id, 'name': c.name, 'kind': c.kind, 'phone': c.phone, 'note': c.note},
              ],
              'invoices': [
                for (final i in b.invoices)
                  {
                    'id': i.id,
                    'number': i.number,
                    'contactName': i.contactName,
                    'amount': i.amount,
                    'issued': i.issued.toIso8601String(),
                    'due': i.due.toIso8601String(),
                    'status': i.status,
                  },
              ],
              'stock': [
                for (final x in b.stock)
                  {'id': x.id, 'name': x.name, 'sku': x.sku, 'qty': x.qty, 'cost': x.cost, 'price': x.price, 'minQty': x.minQty},
              ],
              'closedPeriods': b.closedPeriods,
              'checklistDone': b.checklistDone,
            },
        ],
      };

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) {
    final v = m[k];
    if (v is! List) return const [];
    return [
      for (final e in v)
        if (e is Map) e.cast<String, dynamic>(),
    ];
  }

  static void _load() {
    final raw = _prefs?.getString(_kData);
    if (raw == null) return;
    final Map<String, dynamic> m;
    try {
      m = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (e) {
      // Data rusak: simpan salinannya agar tidak tertimpa, lalu mulai dari kosong.
      debugPrint('Data tersimpan rusak: $e');
      _prefs?.setString('${_kData}_corrupt', raw);
      return;
    }
    fromJson(m);
  }

  /// Terapkan data (dari penyimpanan atau impor) ke state aplikasi.
  /// Tiap bagian dibaca terpisah supaya satu bagian rusak tidak menghilangkan yang lain.
  static void fromJson(Map<String, dynamic> m) {
    try {
      final s = (m['settings'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
      final th = s['theme'];
      if (th is int && th >= 0 && th < ThemeMode.values.length) themeMode.value = ThemeMode.values[th];
      final seed = s['seed'];
      // Indeks ThemeMode.system sekarang dipakai untuk preset Default Trafin.
      // Normalisasi data lama agar label Default selalu benar-benar bawaan.
      if (themeMode.value == ThemeMode.system) {
        seedColor.value = defaultTrafinThemeColor;
      } else if (seed is int) {
        seedColor.value = Color(seed);
      }
      if (s['user'] is String) userName.value = s['user'] as String;
      if (s['company'] is String) companyName.value = s['company'] as String;
      if (s['indicator'] is bool) showIndicator.value = s['indicator'] as bool;
      if (s['currency'] is String) currency.value = s['currency'] as String;
      if (s['currencyCode'] is String) currencyCode.value = s['currencyCode'] as String;
      // Data lama tidak menyimpan denominasi transaksi. Anggap seluruh nominal
      // lama menggunakan mata uang yang sedang dipilih pada saat migrasi.
      baseCurrencyCode.value = s['baseCurrencyCode'] is String
          ? s['baseCurrencyCode'] as String : currencyCode.value;
      final storedFx = s['displayFxRate'];
      displayFxRate.value = storedFx is num && storedFx > 0 && storedFx.toDouble().isFinite
          ? storedFx.toDouble() : 1.0;
      displayFxUpdated.value = s['displayFxUpdated'] is String ? s['displayFxUpdated'] as String : '';
      displayFxSource.value = s['displayFxSource'] is String ? s['displayFxSource'] as String : '';
      if (baseCurrencyCode.value == currencyCode.value) displayFxRate.value = 1.0;
      if (s['symbolAfter'] is bool) symbolAfter.value = s['symbolAfter'] as bool;
      final sep = s['sep'];
      if (sep == '.' || sep == ',' || sep == ' ') thousandSep.value = sep as String;
      final dc = s['decimals'];
      if (dc == 0 || dc == 2) decimals.value = dc as int;
      final df = s['dateFormat'];
      if (df == 0 || df == 1) dateFormat.value = df as int;
      final sd = s['startDay'];
      if (sd is int && sd >= 1 && sd <= 28) startDay.value = sd;
      final loc = s['locale'];
      appLocale.value = (loc is String && appLangs.any((l) => l.code == loc)) ? loc : null;
      customExpenseCats.value =
          s['customCats'] is List ? (s['customCats'] as List).whereType<String>().toList() : <String>[];
      customIncomeCats.value =
          s['customIncomeCats'] is List ? (s['customIncomeCats'] as List).whereType<String>().toList() : <String>[];
    } catch (e) {
      debugPrint('Pengaturan rusak: $e');
    }
    try {
      txs.value = [
        for (final e in _list(m, 'txs'))
          Tx(e['title'] as String, e['cat'] as String, DateTime.parse(e['when'] as String), e['amt'] as num, e['income'] as bool,
              iconFor(e['cat'] as String), (e['wallet'] as String?) ?? ''),
      ]..sort((a, b) => b.when.compareTo(a.when));
    } catch (e) {
      debugPrint('Transaksi rusak: $e');
    }
    try {
      goals.value = [
        for (final e in _list(m, 'goals'))
          Goal(e['name'] as String, e['saved'] as num, e['target'] as num, (e['deadline'] as String?) ?? '', Icons.flag_outlined),
      ];
    } catch (e) {
      debugPrint('Target rusak: $e');
    }
    try {
      final accs = [
        for (final e in _list(m, 'accounts')) Acc(e['code'] as String, e['name'] as String, e['type'] as String, e['bal'] as num),
      ];
      if (accs.isNotEmpty) accounts.value = accs;
    } catch (e) {
      debugPrint('Akun rusak: $e');
    }
    try {
      journals.value = [
        for (final e in _list(m, 'journals'))
          Journal(DateTime.parse(e['when'] as String), e['desc'] as String, [
            for (final l in (e['lines'] as List)) ((l as List)[0] as String, l[1] as num, l[2] as num),
          ]),
      ];
    } catch (e) {
      debugPrint('Jurnal rusak: $e');
    }
    try {
      final books = <BusinessBook>[];
      for (final e in _list(m, 'businessBooks')) {
        final rawAccounts = e['accounts'];
        final rawJournals = e['journals'];
        final accs = <Acc>[];
        final js = <Journal>[];

        if (rawAccounts is List) {
          for (final raw in rawAccounts) {
            if (raw is! Map) continue;
            final a = raw.cast<String, dynamic>();
            accs.add(Acc(
              a['code'] as String,
              a['name'] as String,
              a['type'] as String,
              a['bal'] as num,
            ));
          }
        }

        if (rawJournals is List) {
          for (final raw in rawJournals) {
            if (raw is! Map) continue;
            final j = raw.cast<String, dynamic>();
            final lines = <(String, num, num)>[];
            final rawLines = j['lines'];
            if (rawLines is List) {
              for (final l0 in rawLines) {
                if (l0 is List && l0.length >= 3) {
                  lines.add((l0[0] as String, l0[1] as num, l0[2] as num));
                }
              }
            }
            js.add(Journal(DateTime.parse(j['when'] as String), j['desc'] as String, lines));
          }
        }

        final contacts = <BizContact>[];
        final rawContacts = e['contacts'];
        if (rawContacts is List) {
          for (final raw in rawContacts) {
            if (raw is! Map) continue;
            final c = raw.cast<String, dynamic>();
            contacts.add(BizContact(
              (c['id'] as String?) ?? newBizEntityId('contact'),
              (c['name'] as String?) ?? '',
              (c['kind'] as String?) ?? 'Pelanggan',
              (c['phone'] as String?) ?? '',
              (c['note'] as String?) ?? '',
            ));
          }
        }

        final invoices = <BizInvoice>[];
        final rawInvoices = e['invoices'];
        if (rawInvoices is List) {
          for (final raw in rawInvoices) {
            if (raw is! Map) continue;
            final i = raw.cast<String, dynamic>();
            final issued = DateTime.tryParse((i['issued'] as String?) ?? '') ?? DateTime.now();
            invoices.add(BizInvoice(
              (i['id'] as String?) ?? newBizEntityId('invoice'),
              (i['number'] as String?) ?? '',
              (i['contactName'] as String?) ?? '',
              (i['amount'] as num?) ?? 0,
              issued,
              DateTime.tryParse((i['due'] as String?) ?? '') ?? issued,
              (i['status'] as String?) ?? 'open',
            ));
          }
        }

        final stock = <StockItem>[];
        final rawStock = e['stock'];
        if (rawStock is List) {
          for (final raw in rawStock) {
            if (raw is! Map) continue;
            final x = raw.cast<String, dynamic>();
            stock.add(StockItem(
              (x['id'] as String?) ?? newBizEntityId('stock'),
              (x['name'] as String?) ?? '',
              (x['sku'] as String?) ?? '',
              (x['qty'] as num?) ?? 0,
              (x['cost'] as num?) ?? 0,
              (x['price'] as num?) ?? 0,
              (x['minQty'] as num?) ?? 0,
            ));
          }
        }

        final closedPeriods = e['closedPeriods'] is List
            ? (e['closedPeriods'] as List).whereType<String>().toList()
            : <String>[];
        final checklistDone = e['checklistDone'] is List
            ? (e['checklistDone'] as List).whereType<String>().toList()
            : <String>[];

        if (accs.isEmpty) accs.addAll(starterAccounts());
        final rawName = e['name'];
        final bookName = rawName is String && rawName.trim().isNotEmpty ? rawName.trim() : 'Bisnis';
        final rawCreated = e['createdAt'];
        books.add(BusinessBook(
          e['id'] as String,
          bookName,
          accs,
          js,
          DateTime.tryParse(rawCreated is String ? rawCreated : '') ?? DateTime.now(),
          contacts: contacts,
          invoices: invoices,
          stock: stock,
          closedPeriods: closedPeriods,
          checklistDone: checklistDone,
        ));
      }
      if (books.isNotEmpty) {
        restoreBusinessBooks(books, m['activeBusinessBookId'] as String?);
      } else if (!m.containsKey('businessBooks')) {
        // Migrasi format lama: akun+jurnal perusahaan lama menjadi satu Buku Bisnis.
        final legacy = BusinessBook(
          newBusinessBookId(),
          companyName.value.trim().isEmpty ? 'Bisnis Utama' : companyName.value.trim(),
          List<Acc>.from(accounts.value),
          List<Journal>.from(journals.value),
          DateTime.now(),
        );
        restoreBusinessBooks([legacy], legacy.id);
      }
    } catch (e) {
      debugPrint('Buku Bisnis rusak: $e');
    }
    try {
      final ws = [
        for (final e in _list(m, 'wallets')) Wallet(e['name'] as String, e['type'] as String, e['start'] as num),
      ];
      if (m.containsKey('wallets')) wallets.value = ws;
    } catch (e) {
      debugPrint('Rekening rusak: $e');
    }
    try {
      budgets.value = [
        for (final e in _list(m, 'budgets')) Budget(e['cat'] as String, e['limit'] as num),
      ];
    } catch (e) {
      debugPrint('Anggaran rusak: $e');
    }
    try {
      debts.value = [
        for (final e in _list(m, 'debts'))
          Debt(e['who'] as String, e['amt'] as num, e['mine'] as bool, e['due'] == null ? null : DateTime.parse(e['due'] as String),
              e['paid'] as bool),
      ];
    } catch (e) {
      debugPrint('Hutang rusak: $e');
    }
    try {
      schedules.value = [
        for (final e in _list(m, 'schedules'))
          Sched(e['title'] as String, e['cat'] as String, (e['wallet'] as String?) ?? '', e['freq'] as String, e['amt'] as num,
              e['income'] as bool, DateTime.parse(e['next'] as String), e['anchor'] as int),
      ];
    } catch (e) {
      debugPrint('Jadwal rusak: $e');
    }
  }

  // PIN disimpan di secure storage (Keychain/Keystore). Bila platform tidak
  // mendukungnya (mis. macOS tanpa entitlement), jatuh ke SharedPreferences.
  static Future<void> _loadPin() async {
    String? v;
    try {
      v = await _secure.read(key: _kPin);
    } catch (e) {
      debugPrint('Secure storage tidak tersedia: $e');
    }
    v ??= _prefs?.getString(_kPin);
    pin.value = (v != null && v.contains(':')) ? v : null;
  }

  static Future<void> _savePin() async {
    final v = pin.value;
    var secureOk = true;
    try {
      if (v == null) {
        await _secure.delete(key: _kPin);
      } else {
        await _secure.write(key: _kPin, value: v);
      }
    } catch (e) {
      secureOk = false;
      debugPrint('Secure storage gagal, memakai cadangan: $e');
    }
    final p = _prefs;
    if (p == null) return;
    if (secureOk || v == null) {
      await p.remove(_kPin);
    } else {
      await p.setString(_kPin, v);
    }
  }
}
