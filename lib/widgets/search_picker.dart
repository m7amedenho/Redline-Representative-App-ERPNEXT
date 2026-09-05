import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'loading_indicator.dart';

/// A record shown in [showSearchPicker]'s results list.
class PickedRecord {
  const PickedRecord({required this.name, required this.label, this.subtitle});

  /// The DocType record's `name` (its ID) — what gets sent back to the API.
  final String name;

  /// Primary display text.
  final String label;

  final String? subtitle;
}

/// Full-screen searchable picker used for Customer/Item/Vehicle selection
/// across the Sales Order/Invoice/Payment/Vehicle Log screens. [search] is
/// called (debounced) with the current query — callers decide what
/// DocType/fields to search via [ErpService.getList].
///
/// [actionsBuilder], when given, renders extra AppBar actions (e.g. a
/// territory-filter gear icon) — it's handed this picker screen's own
/// `BuildContext` (so a nested `showSearchPicker` call pushes correctly)
/// and a `refresh` callback to re-run the current search after an action
/// changes some filter state the caller's [search] closure reads. The
/// filter value itself isn't plumbed through here — it lives in a local
/// variable in the caller's own method, shared by both closures the way
/// Dart closures naturally share captured variables.
Future<PickedRecord?> showSearchPicker({
  required BuildContext context,
  required String title,
  required Future<List<PickedRecord>> Function(String query) search,
  String hintText = 'ابحث بالاسم...',
  List<Widget> Function(BuildContext context, VoidCallback refresh)?
  actionsBuilder,
}) {
  return Navigator.of(context).push<PickedRecord>(
    MaterialPageRoute(
      builder: (context) => _SearchPickerScreen(
        title: title,
        search: search,
        hintText: hintText,
        actionsBuilder: actionsBuilder,
      ),
    ),
  );
}

class _SearchPickerScreen extends StatefulWidget {
  const _SearchPickerScreen({
    required this.title,
    required this.search,
    required this.hintText,
    this.actionsBuilder,
  });

  final String title;
  final Future<List<PickedRecord>> Function(String query) search;
  final String hintText;
  final List<Widget> Function(BuildContext context, VoidCallback refresh)?
  actionsBuilder;

  @override
  State<_SearchPickerScreen> createState() => _SearchPickerScreenState();
}

class _SearchPickerScreenState extends State<_SearchPickerScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<PickedRecord> _results = [];
  bool _loading = false;
  String? _error;
  bool _searchedOnce = false;

  @override
  void initState() {
    super.initState();
    _runSearch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _runSearch(query),
    );
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.search(query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
        _searchedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _searchedOnce = true;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.lightGray,
      appBar: AppBar(
        title: Text(widget.title),
        actions: widget.actionsBuilder?.call(
          context,
          () => _runSearch(_controller.text),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: widget.hintText,
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && !_searchedOnce) {
      return const LoadingIndicator();
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                color: AppColors.accent,
                size: 18,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _error!,
                  style: const TextStyle(color: AppColors.accent),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_results.isEmpty) {
      return const Center(
        child: Text(
          'لا توجد نتائج',
          style: TextStyle(color: AppColors.midGray),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: _results.length,
      separatorBuilder: (context, i) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final record = _results[i];
        return Material(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () => Navigator.of(context).pop(record),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  if (record.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      record.subtitle!,
                      style: const TextStyle(
                        color: AppColors.midGray,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
