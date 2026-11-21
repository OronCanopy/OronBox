part of 'plugin_ui_tree.dart';

class _Text extends StatelessWidget {
  const _Text({required this.props});
  final Map<String, Object?> props;

  @override
  Widget build(BuildContext context) {
    final value = props['value']?.toString() ?? '';
    final align = switch (props['align']?.toString()) {
      'center' => TextAlign.center,
      'end' => TextAlign.end,
      _ => TextAlign.start,
    };
    final maxLines = _int(props, 'maxLines');
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Text(
        value,
        textAlign: align,
        maxLines: maxLines,
        overflow: maxLines != null ? TextOverflow.ellipsis : null,
      ),
    );
  }
}

class _Html extends StatelessWidget {
  const _Html({required this.props});
  final Map<String, Object?> props;

  @override
  Widget build(BuildContext context) {
    final html = props['value']?.toString() ?? '';
    return Padding(
      padding: _parseEdgeInsets(props),
      child: CommunityHtmlContent(html: html),
    );
  }
}

class _Image extends StatefulWidget {
  const _Image({required this.props, required this.styles});
  final Map<String, Object?> props;
  final Map<String, Object?> styles;

  @override
  State<_Image> createState() => _ImageState();
}

class _ImageState extends State<_Image> {
  String? _source;
  Uint8List? _bytes;
  bool _svg = false;

  @override
  Widget build(BuildContext context) {
    final props = widget.props;
    final styles = widget.styles;
    final encoded =
        props['data']?.toString() ??
        props['src']?.toString() ??
        props['value']?.toString() ??
        '';
    final width = _toDouble(styles['width']) ?? _num(props, 'width');
    final height = _toDouble(styles['height']) ?? _num(props, 'height');
    final radius = _num(props, 'radius') ?? 0;
    if (encoded.isEmpty) return const SizedBox.shrink();
    if (_source != encoded) {
      _source = encoded;
      try {
        final data = encoded.startsWith('data:')
            ? UriData.parse(encoded)
            : null;
        _bytes = data?.contentAsBytes() ?? base64Decode(encoded);
        _svg = data?.mimeType.toLowerCase() == 'image/svg+xml';
      } on FormatException {
        _bytes = null;
      }
    }
    final bytes = _bytes;
    if (bytes == null) return const SizedBox.shrink();
    final fit = switch (props['fit']?.toString()) {
      'contain' => BoxFit.contain,
      'fill' => BoxFit.fill,
      'fitWidth' => BoxFit.fitWidth,
      'fitHeight' => BoxFit.fitHeight,
      'none' => BoxFit.none,
      'scaleDown' => BoxFit.scaleDown,
      'cover' => BoxFit.cover,
      _ => BoxFit.contain,
    };
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Align(
        widthFactor: 1,
        heightFactor: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: _svg
              ? SvgPicture.memory(
                  bytes,
                  width: width,
                  height: height ?? width ?? 64,
                  fit: fit,
                  errorBuilder: (_, _, _) =>
                      const Icon(Icons.broken_image_outlined),
                )
              : Image.memory(
                  bytes,
                  width: width,
                  height: height ?? width ?? 64,
                  fit: fit,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
        ),
      ),
    );
  }
}

class _Svg extends StatelessWidget {
  const _Svg({required this.props, this.content});
  final Map<String, Object?> props;
  final String? content;

  @override
  Widget build(BuildContext context) {
    final source =
        props['data']?.toString() ??
        props['value']?.toString() ??
        content ??
        '';
    if (source.trim().isEmpty) return const SizedBox.shrink();
    final width = _num(props, 'width');
    final height = _num(props, 'height') ?? width ?? 24;
    return Padding(
      padding: _parseEdgeInsets(props),
      child: SvgPicture.string(
        source,
        width: width,
        height: height,
        fit: BoxFit.contain,
        colorFilter: ColorFilter.mode(
          IconTheme.of(context).color ??
              Theme.of(context).colorScheme.onSurface,
          BlendMode.srcIn,
        ),
        placeholderBuilder: (_) => SizedBox(width: width, height: height),
        errorBuilder: (_, _, _) => SizedBox(
          width: width,
          height: height,
          child: const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder({required this.type});
  final String type;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: Center(
        child: Icon(type == 'AUDIO' ? Icons.audiotrack : Icons.videocam),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.props, required this.child});
  final Map<String, Object?> props;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final count = _int(props, 'count');
    final text =
        props['text']?.toString() ??
        props['value']?.toString() ??
        props['label']?.toString();
    final labelWidget = count != null
        ? Text(count > 99 ? '99+' : count.toString())
        : (text != null && text.isNotEmpty ? Text(text) : null);

    if (child is SizedBox) {
      final s = child as SizedBox;
      if (s.width == 0.0 && s.height == 0.0) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: labelWidget ?? const SizedBox.shrink(),
        );
      }
    }
    return Badge(label: labelWidget, child: child);
  }
}

class _CircularProgress extends StatelessWidget {
  const _CircularProgress({required this.props});
  final Map<String, Object?> props;

  @override
  Widget build(BuildContext context) {
    final size = _num(props, 'size');
    return Padding(
      padding: _parseEdgeInsets(props),
      child: Center(
        child: SizedBox(
          width: size,
          height: size,
          child: const CircularProgressIndicator(),
        ),
      ),
    );
  }
}

class _LinearProgress extends StatelessWidget {
  const _LinearProgress({required this.props});
  final Map<String, Object?> props;

  @override
  Widget build(BuildContext context) {
    final value = double.tryParse(props['value']?.toString() ?? '') ?? 0;
    final max = double.tryParse(props['max']?.toString() ?? '') ?? 1;
    return Padding(
      padding: _parseEdgeInsets(props),
      child: LinearProgressIndicator(value: max > 0 ? value / max : 0),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code({required this.props, this.content, required this.styles});
  final Map<String, Object?> props;
  final String? content;
  final Map<String, Object?> styles;

  @override
  Widget build(BuildContext context) {
    final text = content ?? props['value']?.toString() ?? '';
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
    );
  }
}
