const resourceTaskCompletionDisplayDuration = Duration(seconds: 2);

enum ResourceTaskStatus { pending, downloading, installing, completed, failed }

enum ResourceTaskActivity { download, install }

ResourceTaskStatus resourceTaskStatusFromDaemon(
  String status, {
  required ResourceTaskActivity activity,
}) => switch (status) {
  'running' => switch (activity) {
    ResourceTaskActivity.download => ResourceTaskStatus.downloading,
    ResourceTaskActivity.install => ResourceTaskStatus.installing,
  },
  'completed' => ResourceTaskStatus.completed,
  'failed' || 'cancelled' => ResourceTaskStatus.failed,
  _ => ResourceTaskStatus.pending,
};
