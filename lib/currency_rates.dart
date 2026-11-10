/// Sumber kurs untuk aplikasi. Data kurs indikatif, bukan kurs transaksi bank.
/// Menggunakan penyimpanan lokal agar konversi tetap bisa dibuka saat offline.
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class CurrencyRateData {
  final Map<String, double> rates;
  final String updated;
  final DateTime fetched;
  final String source;
  final bool isStale;

  const CurrencyRateData(this.rates, this.updated, this.fetched, this.source, {this.isStale = false});

  CurrencyRateData asOffline() => CurrencyRateData(rates, updated, fetched, source, isStale: true);
}

class CurrencyQuote {
  final double rate;
  final CurrencyRateData data;
  const CurrencyQuote(this.rate, this.data);
}

const _cacheKey = 'mb_exchange_rates_v2';
const _freshAge = Duration(hours: 6);
final Map<String, CurrencyRateData> _memoryCache = {};
bool _loadedDisk = false;

Future<void> _readDiskCache() async {
  if (_loadedDisk) return;
  _loadedDisk = true;
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cacheKey);
    if (raw == null) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    for (final entry in decoded.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final o = entry.value as Map;
      final ratesRaw = o['rates'];
      final fetched = DateTime.tryParse('${o['fetched'] ?? ''}');
      if (ratesRaw is! Map || fetched == null) continue;
      final rates = <String, double>{};
      for (final e in ratesRaw.entries) {
        if (e.key is String && e.value is num) {
          final v = (e.value as num).toDouble();
          if (v > 0 && v.isFinite) rates[(e.key as String).toUpperCase()] = v;
        }
      }
      if (rates.isNotEmpty) {
        _memoryCache[entry.key as String] = CurrencyRateData(
          rates, '${o['updated'] ?? ''}', fetched, '${o['source'] ?? 'Cache lokal'}');
      }
    }
  } catch (_) {
    // Cache rusak/tidak tersedia bukan alasan untuk menghentikan permintaan online.
  }
}

Future<void> _writeDiskCache() async {
  try {
    final json = <String, dynamic>{};
    for (final entry in _memoryCache.entries) {
      final v = entry.value;
      json[entry.key] = {
        'rates': v.rates,
        'updated': v.updated,
        'source': v.source,
        'fetched': v.fetched.toIso8601String(),
      };
    }
    await (await SharedPreferences.getInstance()).setString(_cacheKey, jsonEncode(json));
  } catch (_) {
    // Kurs dari jaringan tetap dapat dipakai walaupun cache gagal ditulis.
  }
}

Future<dynamic> _httpJson(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 7);
  try {
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 9));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
    return jsonDecode(body);
  } finally {
    client.close(force: true);
  }
}

Map<String, double> _cleanRates(Map raw, String base) {
  final result = <String, double>{base: 1};
  for (final e in raw.entries) {
    if (e.key is! String || e.value is! num) continue;
    final v = (e.value as num).toDouble();
    if (v.isFinite && v > 0) result[(e.key as String).toUpperCase()] = v;
  }
  return result;
}

Future<CurrencyRateData> _fromErApi(String base) async {
  final o = await _httpJson(Uri.parse('https://open.er-api.com/v6/latest/$base'));
  if (o is! Map || o['result'] != 'success' || o['rates'] is! Map) {
    throw const FormatException('Respons ExchangeRate-API tidak valid');
  }
  final rates = _cleanRates(o['rates'] as Map, base);
  if (rates.length <= 1) throw const FormatException('Tidak ada kurs dari ExchangeRate-API');
  return CurrencyRateData(rates, '${o['time_last_update_utc'] ?? ''}', DateTime.now(), 'ExchangeRate-API');
}

Future<CurrencyRateData> _fromFrankfurter(String base) async {
  final o = await _httpJson(Uri.parse('https://api.frankfurter.dev/v2/rates?base=${base.toLowerCase()}'));
  if (o is! List) throw const FormatException('Respons Frankfurter tidak valid');
  final rates = <String, double>{base: 1};
  String updated = '';
  for (final row in o) {
    if (row is! Map || row['quote'] is! String || row['rate'] is! num) continue;
    final v = (row['rate'] as num).toDouble();
    if (!v.isFinite || v <= 0) continue;
    rates[(row['quote'] as String).toUpperCase()] = v;
    if (updated.isEmpty) updated = '${row['date'] ?? ''}';
  }
  if (rates.length <= 1) throw const FormatException('Tidak ada kurs dari Frankfurter');
  return CurrencyRateData(rates, updated, DateTime.now(), 'Frankfurter');
}

Future<CurrencyRateData> _fromCurrencyApiMirror(String base) async {
  final low = base.toLowerCase();
  final o = await _httpJson(Uri.parse('https://latest.currency-api.pages.dev/v1/currencies/$low.json'));
  if (o is! Map || o[low] is! Map) throw const FormatException('Respons mirror kurs tidak valid');
  final rates = _cleanRates(o[low] as Map, base);
  if (rates.length <= 1) throw const FormatException('Tidak ada kurs dari mirror');
  return CurrencyRateData(rates, '${o['date'] ?? ''}', DateTime.now(), 'Currency API mirror');
}

/// Coba 3 penyedia. Bila semuanya gagal, pakai cache terakhir dengan label offline.
/// Tidak pernah memakai kurs karangan atau 1:1 untuk dua mata uang berbeda.
Future<CurrencyRateData> loadRates(String base, {bool force = false}) async {
  base = base.toUpperCase();
  await _readDiskCache();
  final cached = _memoryCache[base];
  if (!force && cached != null &&
      DateTime.now().difference(cached.fetched) < _freshAge) {
    return cached;
  }

  final errors = <String>[];
  for (final provider in <Future<CurrencyRateData> Function(String)>[
    _fromErApi,
    _fromFrankfurter,
    _fromCurrencyApiMirror,
  ]) {
    try {
      final data = await provider(base);
      _memoryCache[base] = data;
      await _writeDiskCache();
      return data;
    } catch (e) {
      errors.add('$e');
    }
  }
  if (cached != null) {
    final offline = cached.asOffline();
    _memoryCache[base] = offline;
    return offline;
  }
  throw StateError('Semua penyedia kurs gagal. ${errors.join(' | ')}. '
      'Untuk Android, periksa izin INTERNET pada android/app/src/main/AndroidManifest.xml.');
}

/// Mengambil kurs dari mata uang dasar ke mata uang tujuan. Menggunakan kurs
/// kebalikan bila data basis tidak menyediakan pasangan tertentu.
Future<CurrencyQuote> getCurrencyQuote(String base, String target, {bool force = false}) async {
  base = base.toUpperCase();
  target = target.toUpperCase();
  if (base == target) {
    return CurrencyQuote(1, CurrencyRateData({base: 1}, '1:1 (mata uang sama)', DateTime.now(), 'Internal'));
  }
  CurrencyRateData? first;
  Object? firstError;
  try {
    first = await loadRates(base, force: force);
    final rate = first.rates[target];
    if (rate != null && rate > 0 && rate.isFinite) return CurrencyQuote(rate, first);
  } catch (e) {
    firstError = e;
  }
  // Jika sumber utama sama sekali tidak bisa diakses, jangan menunggu tiga
  // koneksi tambahan lagi hanya untuk mengulang kesalahan jaringan yang sama.
  if (first == null && firstError != null) throw firstError;
  try {
    final reverse = await loadRates(target, force: force);
    final r = reverse.rates[base];
    if (r != null && r > 0 && r.isFinite) return CurrencyQuote(1 / r, reverse);
  } catch (e) {
    firstError ??= e;
  }
  throw StateError('Pasangan $base/$target tidak tersedia. ${firstError ?? 'Periksa dukungan mata uang atau jaringan.'}');
}
