import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'i18n.dart';
import 'main.dart';

// Laporan digambar dengan Canvas Flutter lalu dibungkus ke PDF sebagai gambar.
// Dengan begitu semua aksara (Arab, Mandarin, Hindi, Thai, ...) dan arah tulis
// kanan-ke-kiri tampil benar tanpa perlu menyertakan font ke dalam PDF.
// Konsekuensinya teks di PDF berupa gambar (tidak bisa diseleksi/dicari).

class _Rendered {
  final Uint8List bytes;
  final int w, h;
  const _Rendered(this.bytes, this.w, this.h);
}

Future<_Rendered> _renderReport(String title, List<Sec> sections, List<(String, String)> summary) async {
  const double width = 600, pad = 32, scale = 2.5;
  const ink = Color(0xFF1B1B1F);
  final rtl = activeLang == 'ar';
  final dir = rtl ? TextDirection.rtl : TextDirection.ltr;
  final accent = seedColor.value;
  const full = width - pad * 2;

  TextPainter tp(String text, {double size = 14, bool bold = false, Color color = ink, double maxWidth = full}) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color),
      ),
      textDirection: dir,
    );
    p.layout(maxWidth: maxWidth);
    return p;
  }

  final ops = <void Function(Canvas)>[];
  var y = pad;

  void single(TextPainter p, {double gap = 6}) {
    final top = y;
    ops.add((c) => p.paint(c, Offset(rtl ? width - pad - p.width : pad, top)));
    y += p.height + gap;
  }

  void row(String l, String r, {bool bold = false}) {
    final a = tp(l, bold: bold, maxWidth: full * 0.62);
    final b = tp(r, bold: bold);
    final top = y;
    ops.add((c) {
      a.paint(c, Offset(rtl ? width - pad - a.width : pad, top));
      b.paint(c, Offset(rtl ? pad : width - pad - b.width, top));
    });
    y += math.max(a.height, b.height) + 8;
  }

  void rule() {
    final ly = y + 2;
    ops.add((c) => c.drawLine(
          Offset(pad, ly),
          Offset(width - pad, ly),
          Paint()
            ..color = const Color(0xFFCCCCCC)
            ..strokeWidth = 1,
        ));
    y += 12;
  }

  single(tp(tr(title), size: 22, bold: true, color: accent), gap: 4);
  final who = companyName.value.isEmpty ? 'Trafin' : companyName.value;
  single(tp('$who • ${tr('Per {p}', {'p': periodLabel(companyReportPeriod.value)})}', size: 12, color: const Color(0xFF666666)), gap: 18);

  for (final s in sections) {
    single(tp(tr(s.title), size: 16, bold: true), gap: 8);
    for (final r in s.rows) {
      row(tr(r.$1), rp(r.$2));
    }
    rule();
    row(tr(s.totalLabel), rp(s.total), bold: true);
    y += 10;
  }
  if (summary.isNotEmpty) {
    rule();
    for (final e in summary) {
      row(tr(e.$1), e.$2, bold: true);
    }
  }

  final total = y + pad;
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.scale(scale);
  canvas.drawRect(Rect.fromLTWH(0, 0, width, total), Paint()..color = const Color(0xFFFFFFFF));
  for (final op in ops) {
    op(canvas);
  }
  final image = await rec.endRecording().toImage((width * scale).ceil(), (total * scale).ceil());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw Exception('render failed');
  return _Rendered(data.buffer.asUint8List(), image.width, image.height);
}

Future<void> exportReportPdf(BuildContext context, String title, List<Sec> sections, List<(String, String)> summary) async {
  final messenger = ScaffoldMessenger.of(context);
  // Dialog bagikan membuat app masuk ke latar belakang; jangan kunci PIN karenanya.
  skipLock = true;
  try {
    final r = await _renderReport(title, sections, summary);
    final w = PdfPageFormat.a4.width;
    final h = w * r.h / r.w;
    final img = pw.MemoryImage(r.bytes);
    final doc = pw.Document(title: tr(title));
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat(w, h),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Image(img, fit: pw.BoxFit.fill),
    ));
    final name = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    await Printing.sharePdf(bytes: await doc.save(), filename: '${name.isEmpty ? 'laporan' : name}.pdf');
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(tr('Gagal membuat PDF: {e}', {'e': e}))));
  } finally {
    Future.delayed(const Duration(seconds: 3), () => skipLock = false);
  }
}
