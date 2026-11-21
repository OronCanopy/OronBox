import 'coded_error.dart';

class PlatformCapabilityError implements CodedError {
  const PlatformCapabilityError(this.message);

  @override
  String get code => 'platform_capability_unavailable';

  @override
  final String message;

  @override
  Object? get details => null;

  @override
  String toString() => '$code: $message';
}
