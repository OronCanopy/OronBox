enum PluginBackgroundMode { forbidden, active, continuous }

class PluginHostSettings {
  const PluginHostSettings({
    this.enabled = true,
    this.background = PluginBackgroundMode.active,
    this.autoStart = false,
  });

  factory PluginHostSettings.fromJson(Map<String, Object?> json) =>
      PluginHostSettings(
        enabled: json['enabled'] != false,
        background: switch (json['background']) {
          true || 'continuous' => PluginBackgroundMode.continuous,
          false || 'forbidden' => PluginBackgroundMode.forbidden,
          _ => PluginBackgroundMode.active,
        },
        autoStart: json['autoStart'] == true,
      );

  final bool enabled;
  final PluginBackgroundMode background;
  final bool autoStart;

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'background': background.name,
    'autoStart': autoStart,
  };
}
