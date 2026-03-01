import '../database/app_database.dart';
import '../utils/formatters.dart';
import 'package:drift/drift.dart';

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
  partial, // Some episodes downloaded, but not all (for shows/seasons)
}

class DownloadProgress {
  final String globalKey;
  final DownloadStatus status;
  final int progress; // 0-100
  final int downloadedBytes;
  final int totalBytes;
  final double speed; // bytes per second
  final String? errorMessage;
  final String? currentFile; // What's being downloaded (video, subtitles, artwork)

  // Thumbnail path (populated after artwork download completes)
  final String? thumbPath;

  // Whether this progress update represents transcoding (server-side) rather than downloading
  final bool isTranscoding;

  const DownloadProgress({
    required this.globalKey,
    required this.status,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speed = 0,
    this.errorMessage,
    this.currentFile,
    this.thumbPath,
    this.isTranscoding = false,
  });

  double get progressPercent => progress / 100.0;

  String get speedFormatted => ByteFormatter.formatSpeed(speed);
  String get downloadedFormatted => ByteFormatter.formatBytes(downloadedBytes);
  String get totalFormatted => ByteFormatter.formatBytes(totalBytes);

  Duration? get estimatedTimeRemaining {
    if (speed <= 0 || totalBytes <= 0) return null;
    final remainingBytes = totalBytes - downloadedBytes;
    if (remainingBytes <= 0) return Duration.zero;
    return Duration(seconds: (remainingBytes / speed).round());
  }

  /// Check if this progress update includes artwork paths
  bool get hasArtworkPaths => thumbPath != null;

  DownloadProgress copyWith({
    String? globalKey,
    DownloadStatus? status,
    int? progress,
    int? downloadedBytes,
    int? totalBytes,
    double? speed,
    String? errorMessage,
    String? currentFile,
    String? thumbPath,
    bool? isTranscoding,
  }) {
    return DownloadProgress(
      globalKey: globalKey ?? this.globalKey,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speed: speed ?? this.speed,
      errorMessage: errorMessage ?? this.errorMessage,
      currentFile: currentFile ?? this.currentFile,
      thumbPath: thumbPath ?? this.thumbPath,
      isTranscoding: isTranscoding ?? this.isTranscoding,
    );
  }
}

class DeletionProgress {
  final String globalKey;
  final String itemTitle;
  final int currentItem;
  final int totalItems;
  final String? currentOperation;

  const DeletionProgress({
    required this.globalKey,
    required this.itemTitle,
    required this.currentItem,
    required this.totalItems,
    this.currentOperation,
  });

  double get progressPercent => totalItems > 0 ? (currentItem / totalItems) : 0.0;

  int get progressPercentInt => (progressPercent * 100).round();

  bool get isComplete => currentItem >= totalItems;

  DeletionProgress copyWith({
    String? globalKey,
    String? itemTitle,
    int? currentItem,
    int? totalItems,
    String? currentOperation,
  }) {
    return DeletionProgress(
      globalKey: globalKey ?? this.globalKey,
      itemTitle: itemTitle ?? this.itemTitle,
      currentItem: currentItem ?? this.currentItem,
      totalItems: totalItems ?? this.totalItems,
      currentOperation: currentOperation ?? this.currentOperation,
    );
  }

  @override
  String toString() {
    return 'DeletionProgress(globalKey: $globalKey, itemTitle: $itemTitle, '
        'currentItem: $currentItem, totalItems: $totalItems, '
        'progressPercent: $progressPercentInt%)';
  }
}

class SeriesDownloadSettings {
  final String serverId;
  final String ratingKey;
  final String? transcodeQuality;
  final bool downloadNewEpisodes;
  final bool downloadNewSeasons;
  final int maxEpisodes;
  final int retentionDays;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SeriesDownloadSettings({
    required this.serverId,
    required this.ratingKey,
    this.transcodeQuality,
    required this.downloadNewEpisodes,
    required this.downloadNewSeasons,
    required this.maxEpisodes,
    required this.retentionDays,
    required this.createdAt,
    required this.updatedAt,
  });

  String get globalKey => '$serverId:$ratingKey';

  bool get hasRetentionPolicy => retentionDays > 0;

  bool get hasEpisodeLimit => maxEpisodes > 0;

  bool get isConfigured =>
      downloadNewEpisodes || downloadNewSeasons || transcodeQuality != null || hasRetentionPolicy || hasEpisodeLimit;

  SeriesDownloadSettings copyWith({
    String? serverId,
    String? ratingKey,
    String? transcodeQuality,
    bool clearTranscodeQuality = false,
    bool? downloadNewEpisodes,
    bool? downloadNewSeasons,
    int? maxEpisodes,
    int? retentionDays,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SeriesDownloadSettings(
      serverId: serverId ?? this.serverId,
      ratingKey: ratingKey ?? this.ratingKey,
      transcodeQuality: clearTranscodeQuality ? null : (transcodeQuality ?? this.transcodeQuality),
      downloadNewEpisodes: downloadNewEpisodes ?? this.downloadNewEpisodes,
      downloadNewSeasons: downloadNewSeasons ?? this.downloadNewSeasons,
      maxEpisodes: maxEpisodes ?? this.maxEpisodes,
      retentionDays: retentionDays ?? this.retentionDays,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory SeriesDownloadSettings.defaults({required String serverId, required String ratingKey}) {
    final now = DateTime.now();
    return SeriesDownloadSettings(
      serverId: serverId,
      ratingKey: ratingKey,
      downloadNewEpisodes: false,
      downloadNewSeasons: false,
      maxEpisodes: 0,
      retentionDays: 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  static SeriesDownloadSettings fromDriftItem(DownloadSeriesSettingsItem item) {
    return SeriesDownloadSettings(
      serverId: item.serverId,
      ratingKey: item.ratingKey,
      transcodeQuality: item.transcodeQuality,
      downloadNewEpisodes: item.downloadNewEpisodes,
      downloadNewSeasons: item.downloadNewSeasons,
      maxEpisodes: item.maxEpisodes,
      retentionDays: item.retentionDays,
      createdAt: DateTime.fromMillisecondsSinceEpoch(item.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(item.updatedAt),
    );
  }

  DownloadSeriesSettingsCompanion toDriftCompanion() {
    return DownloadSeriesSettingsCompanion(
      serverId: Value(serverId),
      ratingKey: Value(ratingKey),
      transcodeQuality: Value(transcodeQuality),
      downloadNewEpisodes: Value(downloadNewEpisodes),
      downloadNewSeasons: Value(downloadNewSeasons),
      maxEpisodes: Value(maxEpisodes),
      retentionDays: Value(retentionDays),
      createdAt: Value(createdAt.millisecondsSinceEpoch),
      updatedAt: Value(updatedAt.millisecondsSinceEpoch),
    );
  }
}
