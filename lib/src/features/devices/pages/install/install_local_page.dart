import 'dart:async';

import 'package:oronbox/src/core/storage/managed_temporary_files.dart';
import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';
import 'package:oronbox/src/app/utils/error_localization.dart';
import 'package:oronbox/src/app/utils/picked_file.dart';
import 'package:oronbox/src/app/widgets/page_container.dart';
import 'package:oronbox/src/app/widgets/smooth_linear_progress_indicator.dart';
import 'package:oronbox/src/app/widgets/sys_app_bar.dart';
import 'package:oronbox/src/core/constants/style_constants.dart';
import 'package:oronbox/src/features/resources/services/resource_install_service.dart';
import 'package:oronbox/src/features/resources/widgets/resource_install_confirmation.dart';

class InstallLocalPage extends ConsumerStatefulWidget {
  const InstallLocalPage({super.key, required this.type});

  final InstallType type;

  @override
  ConsumerState<InstallLocalPage> createState() => _InstallLocalPageState();
}

enum InstallType { app, watchface, canopus }

class _InstallLocalPageState extends ConsumerState<InstallLocalPage> {
  String? _fileName;
  XFile? _file;
  int? _fileSize;
  bool _installing = false;
  double _progress = 0;
  String? _error;

  Future<void> _pickFile() async {
    final file = await pickFileData(
      // Package contents are authoritative. Extensions are often renamed and
      // must not prevent a valid package from being selected.
      type: FileType.any,
      loadBytes: shouldLoadPickedFileData,
    );
    final selected = file?.xFile;
    if (file == null || selected == null) return;
    final selectedSize = await selected.length();

    if (!mounted) {
      await ManagedTemporaryFiles.releaseImport(selected.path);
      return;
    }
    final previous = _file;
    setState(() {
      _fileName = file.name;
      _file = selected;
      _fileSize = selectedSize;
      _error = null;
      _progress = 0;
    });
    if (previous != null) {
      await ManagedTemporaryFiles.releaseImport(previous.path);
    }
    await _confirmAndEnqueue();
  }

  LocalDeviceInstallType get _selectedType => switch (widget.type) {
    InstallType.app => LocalDeviceInstallType.app,
    InstallType.watchface => LocalDeviceInstallType.watchface,
    InstallType.canopus => LocalDeviceInstallType.canopus,
  };

  Future<void> _install() async {
    final file = _file;
    final fileName = _fileName;
    if (file == null || fileName == null) return;
    try {
      setState(() => _installing = true);
      final enqueued = await confirmAndEnqueueResourceFile(
        context: context,
        ref: ref,
        selectedType: _selectedType,
        file: file,
        retainSource: true,
      );
      if (!mounted) return;
      if (enqueued) {
        context.pop();
      } else {
        setState(() => _installing = false);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _installing = false;
          _error = localizedErrorMessage(AppLocalizations.of(context)!, error);
        });
      }
    }
  }

  Future<void> _confirmAndEnqueue() => _install();

  @override
  void dispose() {
    final file = _file;
    if (file != null) unawaited(ManagedTemporaryFiles.releaseImport(file.path));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = switch (widget.type) {
      InstallType.app => l10n.deviceFeaturesInstallApp,
      InstallType.watchface => l10n.deviceFeaturesInstallWatchface,
      InstallType.canopus => l10n.deviceFeaturesInstallModule,
    };

    return Scaffold(
      appBar: SysAppBar(secondary: true, title: Text(title)),
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          PageContainer(
            padding: const EdgeInsets.fromLTRB(
              StyleConstants.pagePadding,
              8,
              StyleConstants.pagePadding,
              0,
            ),
            child: Column(
              children: [
                SectionCard(
                  margin: EdgeInsets.zero,
                  padding: EdgeInsets.zero,
                  child: InkWell(
                    onTap: _installing ? null : _pickFile,
                    borderRadius: BorderRadius.circular(
                      StyleConstants.cardRadius,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Icon(
                            _file == null
                                ? Icons.upload_file
                                : Icons.description,
                            size: 48,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _fileName ?? l10n.installTapToSelectFile,
                            style: Theme.of(context).textTheme.titleMedium,
                            textAlign: TextAlign.center,
                          ),
                          if (_fileSize != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                '${(_fileSize! / 1024).toStringAsFixed(1)} KB',
                                style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    localizedErrorMessage(l10n, _error),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_installing) ...[
                  const SizedBox(height: 24),
                  SmoothLinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                  ),
                  const SizedBox(height: 8),
                  Text('${(_progress * 100).toStringAsFixed(0)}%'),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _file != null && !_installing ? _install : null,
                  child: Text(l10n.install),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
