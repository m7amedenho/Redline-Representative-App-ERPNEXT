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
  // 1. Replace block line breaks first so paragraph separation is preserved
  final withBreaks = input.replaceAll(_blockBreakPattern, '\n');
  
  // 2. Remove all HTML tags BEFORE unescaping HTML entities!
  // This prevents attributes like data-value="&lt;a ... &gt; ... " from
  // having their &gt; unescaped into '>' which causes the tag regex to end early.
  final withoutTags = withBreaks.replaceAll(_tagPattern, '');
  
  // 3. Unescape HTML entities on the clean text content
  final unescaped = withoutTags
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('\ufeff', '')
      .replaceAll('\u200b', '');
  
  return unescaped
      .replaceAll(_whitespacePattern, ' ')
      .replaceAll(_blankLinesPattern, '\n\n')
      .trim();
}
