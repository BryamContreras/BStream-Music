import 'package:flutter/material.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    required this.onSubmitted,
    required this.hintText,
    required this.tooltip,
    required this.clearTooltip,
    this.onCleared,
    super.key,
  });

  final ValueChanged<String> onSubmitted;
  final String hintText;
  final String tooltip;
  final String clearTooltip;
  final VoidCallback? onCleared;

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  final _controller = TextEditingController();
  bool _hadText = false;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void submit() => widget.onSubmitted(_controller.text);

    void clear() {
      _controller.clear();
    }

    final hasText = _controller.text.isNotEmpty;

    return SizedBox(
      width: double.infinity,
      child: TextField(
        controller: _controller,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => submit(),
        decoration: InputDecoration(
          hintText: widget.hintText,
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
    );
  }
}
