import 'package:flutter/material.dart';

import '../../../../core/widgets/app_shared_widgets.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    required this.onSubmitted,
    required this.hintText,
    required this.tooltip,
    required this.clearTooltip,
    this.onCleared,
    this.initialText = '',
    this.compact = false,
    this.requestFocusOnClear = true,
    super.key,
  });

  final ValueChanged<String> onSubmitted;
  final String hintText;
  final String tooltip;
  final String clearTooltip;
  final VoidCallback? onCleared;
  final String initialText;
  final bool compact;
  final bool requestFocusOnClear;

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  bool _hadText = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _hadText = _controller.text.isNotEmpty;
    _controller.addListener(_handleTextChanged);
  }

  void _handleTextChanged() {
    final hasText = _controller.text.isNotEmpty;
    if (_hadText && !hasText) {
      widget.onCleared?.call();
    }
    _hadText = hasText;
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_handleTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void submit() => widget.onSubmitted(_controller.text);

    void clear() {
      _controller.clear();
      if (widget.requestFocusOnClear) {
        _focusNode.requestFocus();
      }
    }

    final hasText = _controller.text.isNotEmpty;

    return AppSurfaceInput(
      key: const ValueKey('search-input-surface'),
      blur: !widget.compact,
      child: SizedBox(
        width: double.infinity,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => submit(),
          decoration: InputDecoration(
            hintText: widget.hintText,
            isDense: widget.compact,
            contentPadding: widget.compact
                ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
                : null,
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasText)
                  IconButton(
                    key: const ValueKey('search-clear-button'),
                    tooltip: widget.clearTooltip,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: clear,
                  ),
                IconButton(
                  tooltip: widget.tooltip,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  onPressed: submit,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
