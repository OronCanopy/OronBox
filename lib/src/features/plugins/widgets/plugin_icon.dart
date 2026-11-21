import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/theme/app_theme.dart';

class PluginIcon extends StatefulWidget {
  const PluginIcon({super.key, this.base64, this.path, required this.size});

  final String? base64;
  final String? path;
  final double size;

  @override
  State<PluginIcon> createState() => _PluginIconState();
}

class _PluginIconState extends State<PluginIcon> {
  ImageProvider? _image;

  @override
  void initState() {
    super.initState();
    _resolveImage();
  }

  @override
  void didUpdateWidget(PluginIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.base64 != widget.base64 || oldWidget.path != widget.path) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    _image = null;
    final data = widget.base64;
    if (data != null && data.isNotEmpty) {
      try {
        _image = MemoryImage(base64Decode(data));
        return;
      } on FormatException {
        // Invalid package artwork uses the standard plugin icon.
      }
    }
    final path = widget.path;
    if (!kIsWeb && path != null) _image = FileImage(File(path));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget fallback() => ColoredBox(
      color: theme.useMaterial3
          ? theme.colorScheme.secondaryContainer
          : context.appSelectionContainer,
      child: Icon(
        Icons.extension,
        color: theme.useMaterial3
            ? theme.colorScheme.onSecondaryContainer
            : context.appSelectionForeground,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.size * .22),
      child: SizedBox.square(
        dimension: widget.size,
        child: _image == null
            ? fallback()
            : Image(
                image: _image!,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stack) => fallback(),
              ),
      ),
    );
  }
}
