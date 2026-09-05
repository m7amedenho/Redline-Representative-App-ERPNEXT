/// Frappe returns some fields (Notification Log's `subject`, Comment's
/// `content`) as raw HTML from its rich-text editor/templates. Rendering
/// that as real HTML would need a new dependency (webview or an HTML
/// widget package); stripping tags for plain-text display is simpler and
/// safer for a first pass.
final _tagPattern = RegExp(r'<[^>]*>');
final _blockBreakPattern = RegExp(
  r'</(p|div|li|br|h[1-6])\s*>',
  caseSensitive: false,
);
final _whitespacePattern = RegExp(r'[ \t]+');
final _blankLinesPattern = RegExp(r'\n{3,}');

String stripHtml(String input) {
  final unescaped = input
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  
  final withBreaks = unescaped.replaceAll(_blockBreakPattern, '\n');
  final withoutTags = withBreaks.replaceAll(_tagPattern, '');
  
  return withoutTags
      .replaceAll(_whitespacePattern, ' ')
      .replaceAll(_blankLinesPattern, '\n\n')
      .trim();
}
