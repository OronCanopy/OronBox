import 'package:material_ui/material_ui.dart';
import 'package:oronbox/src/app/generated/app_localizations.dart';

/// Delegates for the application root.
///
/// Combines the generated Flutter application delegates (which provide Flutter's
/// native Material/Cupertino/Widgets localizations required by external packages
/// like flutter_markdown_plus) with Material UI's custom delegates.
const appLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  ...AppLocalizations.localizationsDelegates,
  ...GlobalMaterialLocalizations.delegates,
];
