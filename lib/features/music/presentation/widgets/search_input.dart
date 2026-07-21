import 'package:flutter/material.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    required this.onSubmitted,
    required this.hintText,
    required this.tooltip,
    super.key,
  });

  final ValueChanged<String> onSubmitted;
  final String hintText;
  final String tooltip;

  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: TextField(
        controller: _controller,
        textInputAction: TextInputAction.search,
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: IconButton(
            tooltip: widget.tooltip,
            icon: const Icon(Icons.arrow_forward_rounded),
            onPressed: () => widget.onSubmitted(_controller.text),
          ),
        ),
      ),
    );
  }
}
