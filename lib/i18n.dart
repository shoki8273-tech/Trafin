import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'l10n/translations.dart';

// ───────────────────────── Bahasa ─────────────────────────
//
// Kunci terjemahan = teks Indonesia aslinya (mis. tr('Simpan')). Kunci khusus
// seperti 'm1' (bulan), 's1' (bulan singkat), 'w1' (hari) ada di tiap bahasa.
// Bahasa baru: tambahkan satu entri di [appLangs] dan satu file di lib/l10n/,
// lalu daftarkan di lib/l10n/translations.dart. Kunci yang belum diterjemahkan
// otomatis jatuh ke Inggris, lalu Indonesia.

class AppLang {
  final String code, native;
  const AppLang(this.code, this.native);
}

const appLangs = <AppLang>[
  AppLang('id', 'Bahasa Indonesia'),
  AppLang('en', 'English'),
  AppLang('ms', 'Bahasa Melayu'),
  AppLang('zh', '中文（简体）'),
  AppLang('ja', '日本語'),
  AppLang('ko', '한국어'),
  AppLang('ar', 'العربية'),
  AppLang('hi', 'हिन्दी'),
  AppLang('es', 'Español'),
  AppLang('fr', 'Français'),
  AppLang('de', 'Deutsch'),
  AppLang('pt', 'Português'),
  AppLang('ru', 'Русский'),
  AppLang('tr', 'Türkçe'),
  AppLang('vi', 'Tiếng Việt'),
  AppLang('th', 'ไทย'),
];

/// null = ikuti bahasa sistem.
final appLocale = ValueNotifier<String?>(null);

/// Dinaikkan saat bahasa sistem berubah (agar UI ikut diperbarui).
final systemLocaleTick = ValueNotifier<int>(0);

final Listenable _langChanged = Listenable.merge([appLocale, systemLocaleTick]);
Listenable get langChanged => _langChanged;

String get systemLang => ui.PlatformDispatcher.instance.locale.languageCode;

/// Kode bahasa yang sedang dipakai aplikasi (selalu salah satu dari [appLangs]).
String get activeLang {
  final c = appLocale.value;
  if (c != null && appLangs.any((l) => l.code == c)) return c;
  final sys = systemLang;
  return appLangs.any((l) => l.code == sys) ? sys : 'en';
}

String nativeNameOf(String code) => appLangs.firstWhere((l) => l.code == code, orElse: () => appLangs[1]).native;

String langLabel() {
  final c = appLocale.value;
  if (c == null) return '${tr('Ikuti bahasa sistem')} (${nativeNameOf(activeLang)})';
  return nativeNameOf(c);
}

Locale? get appLocaleOrNull {
  final c = appLocale.value;
  return c == null ? null : Locale(c);
}

/// Inggris di urutan pertama: dipakai Flutter bila bahasa sistem tidak didukung.
final List<Locale> supportedLocales = [
  const Locale('en'),
  for (final l in appLangs)
    if (l.code != 'en') Locale(l.code),
];

/// Terjemahkan [key]. Placeholder berbentuk {nama} diganti dari [args].
String tr(String key, [Map<String, Object?>? args]) {
  final lang = activeLang;
  var out = translations[lang]?[key] ??
      (lang == 'id' ? null : translations['en']?[key]) ??
      translations['id']?[key] ??
      key;
  if (args != null) {
    for (final e in args.entries) {
      out = out.replaceAll('{${e.key}}', '${e.value}');
    }
  }
  return out;
}

/// Seperti [Text], tetapi teksnya diterjemahkan dan ikut berubah saat bahasa diganti
/// (juga untuk widget yang `const`).
class Tr extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  const Tr(this.text, {super.key, this.style, this.textAlign, this.maxLines, this.overflow});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: langChanged,
        builder: (context, _) => Text(tr(text), style: style, textAlign: textAlign, maxLines: maxLines, overflow: overflow),
      );
}

class LanguagePage extends StatelessWidget {
  const LanguagePage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Tr('Bahasa')),
        body: ListenableBuilder(
          listenable: langChanged,
          builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 48), children: [
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.phone_android_outlined),
                  title: const Tr('Ikuti bahasa sistem'),
                  subtitle: Text(nativeNameOf(activeLang)),
                  trailing: appLocale.value == null ? const Icon(Icons.check) : null,
                  selected: appLocale.value == null,
                  onTap: () => appLocale.value = null,
                ),
                for (final l in appLangs) ...[
                  const Divider(height: 1),
                  ListTile(
                    title: Text(l.native),
                    trailing: appLocale.value == l.code ? const Icon(Icons.check) : null,
                    selected: appLocale.value == l.code,
                    onTap: () => appLocale.value = l.code,
                  ),
                ],
              ]),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Tr(
                'Nama mata uang dan negara di daftar mata uang masih memakai bahasa Indonesia.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ]),
        ),
      );
}
