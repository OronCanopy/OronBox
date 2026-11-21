import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

const deviceMaintenanceInterval = Duration(minutes: 15);

final deviceMaintenanceTickProvider = StreamProvider.autoDispose<int>(
  (ref) => Stream.periodic(deviceMaintenanceInterval, (tick) => tick),
);
