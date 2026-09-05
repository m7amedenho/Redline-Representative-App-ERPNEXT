import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const _docTypeTitles = {
  'Sales Invoice': 'فاتورة مبيعات',
  'Sales Order': 'أمر بيع',
  'Customer': 'بيانات عميل',
  'Payment Entry': 'إيصال استلام',
};

/// Builds the shareable PDF **on the device itself**, from the same
/// document data already fetched and shown on screen — not a round trip to
/// the server's print-format renderer. This is the direct fix for reps
/// reporting the PDF button as slow/unreliable on the real cellular
/// connections they work with in the field: there's no second network call
/// left to fail or drag.
///
/// Uses IBM Plex Sans Arabic — the exact same typeface already used across
/// the app's own UI in `app_theme.dart` — bundled as a local asset
/// (`assets/fonts/`) rather than fetched from Google's font CDN at
/// runtime: this whole feature exists so a rep can generate a PDF with NO
/// network dependency at all, so leaning on `printing`'s `PdfGoogleFonts`
/// (which downloads from fonts.gstatic.com on first use, and silently
/// falls back to a Latin-only Helvetica — confirmed live, every Arabic
/// glyph missing — if that download fails) would have quietly reintroduced
/// the exact kind of unreliable network dependency this was meant to
/// remove.
///
/// IMPORTANT: `pw.Document(theme: ...)` only supplies the font for text
/// that carries NO explicit [pw.TextStyle] at all — any `pw.TextStyle(...)`
/// that doesn't itself set `font:` silently falls back to the `pdf`
/// package's built-in base font, which has no Arabic glyphs. So every
/// [pw.TextStyle] below explicitly passes `regularFont` or `boldFont` —
/// never a bare/`const` style.
class PdfBuilderService {
  static Future<Uint8List> buildDocumentPdf({
    required String doctype,
    required String name,
    required Map<String, dynamic> doc,
  }) async {
    final regularFont = await _loadFont('assets/fonts/IBMPlexSansArabic-Regular.ttf');
    final boldFont = await _loadFont('assets/fonts/IBMPlexSansArabic-Bold.ttf');

    final pdfDoc = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );

    final title = _docTypeTitles[doctype] ?? doctype;
    final company = (doc['company'] as String?) ?? '';
    final partyName =
        (doc['customer_name'] ??
                doc['customer'] ??
                doc['party_name'] ??
                doc['party'] ??
                doc['customer_group'])
            ?.toString();
    final date =
        (doc['posting_date'] ?? doc['transaction_date'] ?? doc['creation'])
            ?.toString()
            .split(' ')
            .first;

    final items = doc['items'];
    final itemRows = items is List
        ? items.whereType<Map>().map((i) => Map<String, dynamic>.from(i)).toList()
        : <Map<String, dynamic>>[];

    pdfDoc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(name, style: pw.TextStyle(font: boldFont, fontSize: 11)),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(title, style: pw.TextStyle(font: boldFont, fontSize: 18)),
                    if (company.isNotEmpty)
                      pw.Text(company, style: pw.TextStyle(font: regularFont, fontSize: 11)),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 6),
            pw.Divider(thickness: 1),
          ],
        ),
        footer: (context) => pw.Column(
          children: [
            pw.Divider(thickness: 0.5),
            pw.Text(
              'صفحة ${context.pageNumber} من ${context.pagesCount}',
              style: pw.TextStyle(font: regularFont, fontSize: 9, color: PdfColors.grey600),
            ),
          ],
        ),
        build: (context) => [
          pw.SizedBox(height: 8),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              if (date != null) _labelValue(regularFont, boldFont, 'التاريخ', date),
              if (partyName != null) _labelValue(regularFont, boldFont, 'العميل', partyName),
            ],
          ),
          pw.SizedBox(height: 18),
          if (itemRows.isNotEmpty) _itemsTable(regularFont, boldFont, itemRows),
          pw.SizedBox(height: 12),
          pw.Align(
            alignment: pw.Alignment.centerLeft,
            child: _totalsBlock(regularFont, boldFont, doc),
          ),
          if ((doc['terms'] as String?)?.trim().isNotEmpty ?? false) ...[
            pw.SizedBox(height: 18),
            pw.Text(
              'الشروط والأحكام',
              style: pw.TextStyle(font: boldFont, fontSize: 11),
            ),
            pw.SizedBox(height: 4),
            pw.Text(
              (doc['terms'] as String).replaceAll(RegExp(r'<[^>]*>'), '').trim(),
              style: pw.TextStyle(font: regularFont, fontSize: 9.5),
            ),
          ],
        ],
      ),
    );

    return pdfDoc.save();
  }

  /// Customer account statement — same on-device generation approach, built
  /// from the same rows already computed/shown on
  /// `CustomerStatementScreen` (each with `date`/`voucherType`/`voucherNo`/
  /// `debit`/`credit`/`balance`), so the exported PDF always matches
  /// exactly what the rep is looking at on screen.
  static Future<Uint8List> buildCustomerStatementPdf({
    required String customerLabel,
    required List<Map<String, dynamic>> rows,
    required num currentBalance,
  }) async {
    final regularFont = await _loadFont('assets/fonts/IBMPlexSansArabic-Regular.ttf');
    final boldFont = await _loadFont('assets/fonts/IBMPlexSansArabic-Bold.ttf');

    final pdfDoc = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );

    final headerStyle = pw.TextStyle(font: boldFont, fontSize: 10, color: PdfColors.white);
    final cellStyle = pw.TextStyle(font: regularFont, fontSize: 9.5);

    pdfDoc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        margin: const pw.EdgeInsets.all(28),
        header: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              'كشف حساب — $customerLabel',
              style: pw.TextStyle(font: boldFont, fontSize: 16),
            ),
            pw.SizedBox(height: 6),
            pw.Divider(thickness: 1),
          ],
        ),
        footer: (context) => pw.Column(
          children: [
            pw.Divider(thickness: 0.5),
            pw.Text(
              'صفحة ${context.pageNumber} من ${context.pagesCount}',
              style: pw.TextStyle(font: regularFont, fontSize: 9, color: PdfColors.grey600),
            ),
          ],
        ),
        build: (context) => [
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(
                  'المديونية الحالية',
                  style: pw.TextStyle(font: regularFont, fontSize: 10),
                ),
                pw.Text(
                  '${_fmt(currentBalance)} ج.م',
                  style: pw.TextStyle(font: boldFont, fontSize: 13),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(2),
              1: pw.FlexColumnWidth(3),
              2: pw.FlexColumnWidth(1.5),
              3: pw.FlexColumnWidth(1.5),
              4: pw.FlexColumnWidth(1.7),
            },
            children: [
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.grey800),
                children: [
                  _cell('الرصيد', headerStyle, pad: 6),
                  _cell('دائن', headerStyle, pad: 6),
                  _cell('مدين', headerStyle, pad: 6),
                  _cell('المستند', headerStyle, pad: 6),
                  _cell('التاريخ', headerStyle, pad: 6),
                ],
              ),
              ...rows.map((row) {
                final voucherType = (row['voucherType'] as String?) ?? '';
                final voucherNo = (row['voucherNo'] as String?) ?? '';
                final debit = (row['debit'] as num?) ?? 0;
                final credit = (row['credit'] as num?) ?? 0;
                final balance = (row['balance'] as num?) ?? 0;
                final date = (row['date'] as String?) ?? '';
                return pw.TableRow(
                  children: [
                    _cell(_fmt(balance), cellStyle, pad: 6),
                    _cell(credit > 0 ? _fmt(credit) : '—', cellStyle, pad: 6),
                    _cell(debit > 0 ? _fmt(debit) : '—', cellStyle, pad: 6),
                    _cell(
                      voucherType.isEmpty ? '—' : '$voucherType $voucherNo',
                      cellStyle,
                      pad: 6,
                    ),
                    _cell(date, cellStyle, pad: 6),
                  ],
                );
              }),
            ],
          ),
        ],
      ),
    );

    return pdfDoc.save();
  }

  static pw.Widget _labelValue(
    pw.Font regularFont,
    pw.Font boldFont,
    String label,
    String value,
  ) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(font: regularFont, fontSize: 9, color: PdfColors.grey600),
        ),
        pw.SizedBox(height: 2),
        pw.Text(value, style: pw.TextStyle(font: boldFont, fontSize: 11)),
      ],
    );
  }

  static pw.Widget _itemsTable(
    pw.Font regularFont,
    pw.Font boldFont,
    List<Map<String, dynamic>> rows,
  ) {
    final headerStyle = pw.TextStyle(font: boldFont, fontSize: 10, color: PdfColors.white);
    final cellStyle = pw.TextStyle(font: regularFont, fontSize: 9.5);

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(4),
        1: pw.FlexColumnWidth(1.3),
        2: pw.FlexColumnWidth(1.6),
        3: pw.FlexColumnWidth(1.8),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey800),
          children: [
            _cell('الإجمالي', headerStyle, pad: 6),
            _cell('السعر', headerStyle, pad: 6),
            _cell('الكمية', headerStyle, pad: 6),
            _cell('الصنف', headerStyle, pad: 6),
          ],
        ),
        ...rows.map((item) {
          final itemName = (item['item_name'] ?? item['item_code'] ?? '—').toString();
          final qty = item['qty'];
          final rate = item['rate'];
          final amount = item['amount'];
          return pw.TableRow(
            children: [
              _cell(_fmt(amount), cellStyle, pad: 6),
              _cell(_fmt(rate), cellStyle, pad: 6),
              _cell(_fmt(qty), cellStyle, pad: 6),
              _cell(itemName, cellStyle, pad: 6),
            ],
          );
        }),
      ],
    );
  }

  static pw.Widget _cell(String text, pw.TextStyle style, {double pad = 4}) {
    return pw.Padding(
      padding: pw.EdgeInsets.all(pad),
      child: pw.Text(text, style: style, textAlign: pw.TextAlign.right),
    );
  }

  static pw.Widget _totalsBlock(
    pw.Font regularFont,
    pw.Font boldFont,
    Map<String, dynamic> doc,
  ) {
    final netTotal = doc['net_total'];
    final discountAmount = doc['discount_amount'];
    final discountPercent = doc['additional_discount_percentage'];
    final grandTotal = doc['grand_total'];
    final outstanding = doc['outstanding_amount'];
    final paidAmount = doc['paid_amount'];

    final rows = <pw.Widget>[];
    void addRow(String label, dynamic value, {bool bold = false}) {
      if (value == null) return;
      final font = bold ? boldFont : regularFont;
      rows.add(
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                _fmt(value),
                style: pw.TextStyle(font: font, fontSize: bold ? 12 : 10),
              ),
              pw.Text(
                label,
                style: pw.TextStyle(
                  font: font,
                  fontSize: bold ? 12 : 10,
                  color: bold ? null : PdfColors.grey700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    addRow('الصافي', netTotal);
    if (discountAmount is num && discountAmount > 0) {
      addRow(
        (discountPercent is num && discountPercent > 0)
            ? 'الخصم ($discountPercent%)'
            : 'الخصم',
        discountAmount,
      );
    }
    addRow('الإجمالي النهائي', grandTotal, bold: true);
    if (paidAmount != null) addRow('المدفوع', paidAmount);
    if (outstanding is num && outstanding > 0) addRow('المتبقي', outstanding);

    return pw.Container(
      width: 220,
      alignment: pw.Alignment.centerRight,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  static Future<pw.Font> _loadFont(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return pw.Font.ttf(data);
  }

  static String _fmt(dynamic value) {
    if (value == null) return '—';
    if (value is num) return value.toStringAsFixed(2);
    return value.toString();
  }
}
