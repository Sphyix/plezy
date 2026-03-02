import 'dart:async';
import 'dart:io';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:plezy/utils/content_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/download_models.dart';
import '../models/plex_metadata.dart';
import '../services/download_manager_service.dart';
import '../services/download_storage_service.dart';
import '../services/plex_api_cache.dart';
import '../services/plex_client.dart';
import '../i18n/strings.g.dart';
import '../utils/app_logger.dart';
import '../utils/global_key_utils.dart';

/// Holds Plex thumb path reference for downloaded artwork.
/// The actual file path is computed from the hash of serverId + thumb path.
class DownloadedArtwork {
  /// The Plex thumb path (e.g., /library/metadata/12345/thumb/1234567890)
  final String? thumbPath;

  const DownloadedArtwork({this.thumbPath});

  /// Get the local file path for this artwork
  String? getLocalPath(DownloadStorageService storage, String serverId) {
    if (thumbPath == null) return null;
    return storage.getArtworkPathSync(serverId, thumbPath!);
  }
}

/// Provider for managing download state and operations.
class DownloadProvider extends ChangeNotifier {
  final DownloadManagerService _downloadManager;
  StreamSubscription<DownloadProgress>? _progressSubscription;
  StreamSubscription<DeletionProgress>? _deletionProgressSubscription;
  late final Future<void> _initFuture;

  // Track download progress by globalKey (serverId:ratingKey)
  final Map<String, DownloadProgress> _downloads = {};

  // Store metadata for display
  final Map<String, PlexMetadata> _metadata = {};

  // Store Plex thumb paths for offline display (actual file path computed from hash)
  final Map<String, DownloadedArtwork> _artworkPaths = {};

  // Track items currently being queued (building download queue)
  final Set<String> _queueing = {};

  // Track items currently being deleted with progress
  final Map<String, DeletionProgress> _deletionProgress = {};

  // Track total episode counts for shows/seasons (for partial download detection)
  // Key: globalKey (serverId:ratingKey), Value: total episode count
  final Map<String, int> _totalEpisodeCounts = {};

  // Per-series download settings (keyed by globalKey: serverId:ratingKey)
  final Map<String, SeriesDownloadSettings> _seriesSettings = {};

  // Per-show mutex for refresh operations — prevents duplicate concurrent refreshes
  final _showRefreshCompleters = <String, Completer<void>>{};

  // Pending retention trims detected at startup (non-null = dialog should be shown)
  List<RetentionTrimResult>? _pendingRetentionTrims;

  // Aggregate retention trim progress (non-null = trim in progress, UI should show progress dialog)
  DeletionProgress? _retentionTrimProgress;
  DeletionProgress? get retentionTrimProgress => _retentionTrimProgress;

  // Storage error state (set when storage is unavailable)
  String? _storageError;
  String? get storageError => _storageError;

  DownloadProvider({required DownloadManagerService downloadManager}) : _downloadManager = downloadManager {
    // Listen to progress updates from the download manager
    _progressSubscription = _downloadManager.progressStream.listen(_onProgressUpdate);

    // Listen to deletion progress updates
    _deletionProgressSubscription = _downloadManager.deletionProgressStream.listen(_onDeletionProgressUpdate);

    // Load persisted downloads from database
    _initFuture = _loadPersistedDownloads();
  }

  /// Ensures persisted downloads have been loaded from disk.
  Future<void> ensureInitialized() => _initFuture;

  /// Clear storage error state
  void clearStorageError() {
    _storageError = null;
    notifyListeners();
  }

  // Series download settings accessors
  Map<String, SeriesDownloadSettings> get seriesSettings => Map.unmodifiable(_seriesSettings);

  SeriesDownloadSettings? getSeriesSettingsForShow(String globalKey) => _seriesSettings[globalKey];

  Future<void> saveSeriesSettings(SeriesDownloadSettings settings) async {
    final companion = settings.toDriftCompanion();
    await _downloadManager.database.saveSeriesSettings(companion);
    _seriesSettings[settings.globalKey] = settings;
    notifyListeners();
  }

  Future<void> deleteSeriesSettings(String globalKey) async {
    final parsed = parseGlobalKey(globalKey);
    if (parsed != null) {
      await _downloadManager.database.deleteSeriesSettings(parsed.serverId, parsed.ratingKey);
    }
    _seriesSettings.remove(globalKey);
    notifyListeners();
  }

  bool isSeriesConfigured(String globalKey) {
    final settings = _seriesSettings[globalKey];
    return settings != null && settings.isConfigured;
  }

  // Retention trim accessors
  List<RetentionTrimResult>? get pendingRetentionTrims => _pendingRetentionTrims;

  void clearPendingRetentionTrims() {
    _pendingRetentionTrims = null;
    notifyListeners();
  }

  void _clearRetentionTrimProgress() {
    _retentionTrimProgress = null;
    notifyListeners();
  }

  /// Requeue pending downloads for a series after quality settings change.
  /// Only affects queued/paused/failed downloads — completed downloads are NOT touched.
  Future<void> requeueDownloadsForSeries(String settingsGlobalKey, PlexClient client) async {
    final parsed = parseGlobalKey(settingsGlobalKey);
    if (parsed == null) return;

    // Find all downloads belonging to this series that are in requeueable states
    final toRequeue = <String, PlexMetadata>{};
    for (final entry in _downloads.entries) {
      final status = entry.value.status;
      if (status != DownloadStatus.queued && status != DownloadStatus.paused && status != DownloadStatus.failed) {
        continue;
      }
      final meta = _metadata[entry.key];
      if (meta == null) continue;

      // Check if this download belongs to the series
      if (meta.type == 'episode' && meta.grandparentRatingKey == parsed.ratingKey && meta.serverId == parsed.serverId) {
        toRequeue[entry.key] = meta;
      } else if (meta.type == 'movie' && entry.key == settingsGlobalKey) {
        toRequeue[entry.key] = meta;
      }
    }

    if (toRequeue.isEmpty) return;

    // Cancel all matching downloads
    for (final globalKey in toRequeue.keys) {
      await _downloadManager.cancelDownload(globalKey);
      _downloads.remove(globalKey);
    }

    // Re-queue with updated settings (which are already persisted in _seriesSettings).
    // Use lightweight path: metadata is already in _metadata so skip server re-fetch,
    // and defer notifyListeners() to a single call at the end.
    for (final entry in toRequeue.entries) {
      _downloads[entry.key] = DownloadProgress(globalKey: entry.key, status: DownloadStatus.queued);
      final transcodeQuality = _resolveTranscodeQuality(entry.key);
      await _downloadManager.queueDownload(
        metadata: entry.value,
        client: client,
        transcodeQuality: transcodeQuality,
      );
    }

    notifyListeners();
  }

  /// Load all persisted downloads and metadata from the database/cache
  Future<void> _loadPersistedDownloads() async {
    try {
      // Wait for recovery to finish before loading state so that
      // interrupted "downloading" rows have been transitioned to "queued"
      await _downloadManager.recoveryFuture;

      // Clear existing data to prevent stale entries after deletions
      _downloads.clear();
      _artworkPaths.clear();
      _metadata.clear();
      _totalEpisodeCounts.clear();

      final storageService = DownloadStorageService.instance;
      final apiCache = PlexApiCache.instance;

      // Initialize artwork directory path for synchronous access
      await storageService.getArtworkDirectory();

      // Load all downloads from database
      final downloads = await _downloadManager.getAllDownloads();

      // Bulk-load all pinned metadata in a single query instead of per-item DB calls
      final allMetadata = await apiCache.getAllPinnedMetadata();

      for (final item in downloads) {
        _downloads[item.globalKey] = DownloadProgress(
          globalKey: item.globalKey,
          status: DownloadStatus.values[item.status],
          progress: item.progress,
          downloadedBytes: item.downloadedBytes,
          totalBytes: item.totalBytes ?? 0,
        );

        // Store Plex thumb path reference (file path computed from hash when needed)
        _artworkPaths[item.globalKey] = DownloadedArtwork(thumbPath: item.thumbPath);

        // Look up metadata from the bulk-loaded map (O(1) instead of DB query per item)
        // Falls back to individual query for any unpinned entries (e.g., legacy data)
        final metadata = allMetadata[item.globalKey] ?? await apiCache.getMetadata(item.serverId, item.ratingKey);
        if (metadata != null) {
          _metadata[item.globalKey] = metadata;

          // For episodes, also load parent (show and season) metadata from the same map
          if (metadata.isEpisode) {
            _loadParentMetadataFromMap(metadata, allMetadata);
          }
        }
      }

      // Load total episode counts from SharedPreferences
      await _loadTotalEpisodeCounts();

      // Load all series download settings from Drift
      final allSeriesSettings = await _downloadManager.database.getAllSeriesSettings();
      _seriesSettings.clear();
      for (final item in allSeriesSettings) {
        final settings = SeriesDownloadSettings.fromDriftItem(item);
        _seriesSettings[settings.globalKey] = settings;
      }

      appLogger.i(
        'Loaded ${_downloads.length} downloads, ${_metadata.length} metadata entries, '
        '${_totalEpisodeCounts.length} episode counts, and ${_seriesSettings.length} series settings',
      );
      notifyListeners();

      // Evaluate retention policies at startup for apps without auto-download configured
      final trims = await evaluateRetentionPolicies();
      if (trims.isNotEmpty) {
        _pendingRetentionTrims = trims;
        appLogger.i('Retention (startup): ${trims.length} shows have episodes exceeding limits');
        notifyListeners();
      }
    } catch (e) {
      appLogger.e('Failed to load persisted downloads', error: e);
    }
  }

  /// Load total episode counts from SharedPreferences
  Future<void> _loadTotalEpisodeCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('episode_count_'));

      for (final key in keys) {
        final globalKey = key.replaceFirst('episode_count_', '');
        final count = prefs.getInt(key);
        if (count != null) {
          _totalEpisodeCounts[globalKey] = count;
          appLogger.d('📂 Loaded episode count from SharedPrefs: $globalKey = $count');
        }
      }

      appLogger.i('📚 Loaded ${_totalEpisodeCounts.length} episode counts from SharedPreferences');
    } catch (e) {
      appLogger.w('Failed to load episode counts', error: e);
    }
  }

  /// Persist total episode count to SharedPreferences
  Future<void> _persistTotalEpisodeCount(String globalKey, int count) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('episode_count_$globalKey', count);
      appLogger.d('Persisted episode count for $globalKey: $count');
    } catch (e) {
      appLogger.w('Failed to persist episode count for $globalKey', error: e);
    }
  }

  /// Load parent (show and season) metadata from a pre-loaded map (no DB I/O).
  /// Used during bulk initialization to avoid per-item DB queries.
  void _loadParentMetadataFromMap(PlexMetadata episode, Map<String, PlexMetadata> allMetadata) {
    final serverId = episode.serverId;
    if (serverId == null) return;

    // Load show metadata
    final showRatingKey = episode.grandparentRatingKey;
    if (showRatingKey != null) {
      final showGlobalKey = buildGlobalKey(serverId, showRatingKey);
      if (!_metadata.containsKey(showGlobalKey)) {
        final showMetadata = allMetadata[showGlobalKey];
        if (showMetadata != null) {
          _metadata[showGlobalKey] = showMetadata;
          if (showMetadata.thumb != null) {
            _artworkPaths[showGlobalKey] = DownloadedArtwork(thumbPath: showMetadata.thumb);
          }
        }
      }
    }

    // Load season metadata
    final seasonRatingKey = episode.parentRatingKey;
    if (seasonRatingKey != null) {
      final seasonGlobalKey = buildGlobalKey(serverId, seasonRatingKey);
      if (!_metadata.containsKey(seasonGlobalKey)) {
        final seasonMetadata = allMetadata[seasonGlobalKey];
        if (seasonMetadata != null) {
          _metadata[seasonGlobalKey] = seasonMetadata;
          if (seasonMetadata.thumb != null) {
            _artworkPaths[seasonGlobalKey] = DownloadedArtwork(thumbPath: seasonMetadata.thumb);
          }
        }
      }
    }
  }

  void _onProgressUpdate(DownloadProgress progress) {
    appLogger.d('Progress update received: ${progress.globalKey} - ${progress.status} - ${progress.progress}%');

    _downloads[progress.globalKey] = progress;

    // Sync artwork paths when they are available
    if (progress.hasArtworkPaths) {
      _artworkPaths[progress.globalKey] = DownloadedArtwork(thumbPath: progress.thumbPath);
    }

    appLogger.d('Notifying listeners for ${progress.globalKey}');
    notifyListeners();
  }

  @override
  @override
  void dispose() {
    _progressSubscription?.cancel();
    _deletionProgressSubscription?.cancel();
    super.dispose();
  }

  /// All current download progress entries
  Map<String, DownloadProgress> get downloads => Map.unmodifiable(_downloads);

  /// All metadata for downloads
  Map<String, PlexMetadata> get metadata => Map.unmodifiable(_metadata);

  /// Get all queued/downloading items (for Queue tab)
  List<DownloadProgress> get queuedDownloads {
    return _downloads.values
        .where(
          (p) =>
              p.status == DownloadStatus.queued ||
              p.status == DownloadStatus.downloading ||
              p.status == DownloadStatus.paused,
        )
        .toList();
  }

  /// Get all completed downloads
  List<DownloadProgress> get completedDownloads {
    return _downloads.values.where((p) => p.status == DownloadStatus.completed).toList();
  }

  /// Get completed TV episode downloads (individual episodes)
  List<PlexMetadata> get downloadedEpisodes {
    return _metadata.entries
        .where((entry) {
          final progress = _downloads[entry.key];
          return progress?.status == DownloadStatus.completed && entry.value.type == 'episode';
        })
        .map((entry) => entry.value)
        .toList();
  }

  /// Get unique TV shows that have downloaded episodes
  /// Returns stored show metadata, or synthesizes from episode metadata as fallback
  List<PlexMetadata> get downloadedShows {
    final Map<String, PlexMetadata> shows = {};

    for (final entry in _metadata.entries) {
      final globalKey = entry.key;
      final meta = entry.value;
      final progress = _downloads[globalKey];

      if (progress?.status == DownloadStatus.completed && meta.type == 'episode') {
        final showRatingKey = meta.grandparentRatingKey;
        if (showRatingKey != null && !shows.containsKey(showRatingKey)) {
          // Try to get stored show metadata first
          final showGlobalKey = buildGlobalKey(meta.serverId!, showRatingKey);
          final storedShow = _metadata[showGlobalKey];

          if (storedShow != null && storedShow.type == 'show') {
            // Use stored show metadata (has year, summary, clearLogo)
            shows[showRatingKey] = storedShow;
          } else {
            // Fallback: synthesize from episode metadata (missing year, summary)
            shows[showRatingKey] = PlexMetadata(
              ratingKey: showRatingKey,
              key: '/library/metadata/$showRatingKey',
              type: 'show',
              title: meta.grandparentTitle ?? 'Unknown Show',
              thumb: meta.grandparentThumb,
              art: meta.grandparentArt,
              serverId: meta.serverId,
            );
          }
        }
      }
    }

    return shows.values.toList();
  }

  /// Get completed movie downloads
  List<PlexMetadata> get downloadedMovies {
    return _metadata.entries
        .where((entry) {
          final progress = _downloads[entry.key];
          return progress?.status == DownloadStatus.completed && entry.value.type == 'movie';
        })
        .map((entry) => entry.value)
        .toList();
  }

  /// Get metadata for a specific download
  PlexMetadata? getMetadata(String globalKey) => _metadata[globalKey];

  /// Get artwork paths for a specific download (for offline display)
  DownloadedArtwork? getArtworkPaths(String globalKey) => _artworkPaths[globalKey];

  /// Get local file path for any artwork type (thumb, art, clearLogo, etc.)
  /// Returns null if artwork directory isn't initialized or artworkPath is null
  String? getArtworkLocalPath(String serverId, String? artworkPath) {
    if (artworkPath == null) return null;
    return DownloadStorageService.instance.getArtworkPathSync(serverId, artworkPath);
  }

  /// Get downloaded episodes for a specific show (by grandparentRatingKey)
  List<PlexMetadata> getDownloadedEpisodesForShow(String showRatingKey) {
    return _metadata.entries
        .where((entry) {
          final progress = _downloads[entry.key];
          final meta = entry.value;
          return progress?.status == DownloadStatus.completed &&
              meta.type == 'episode' &&
              meta.grandparentRatingKey == showRatingKey;
        })
        .map((entry) => entry.value)
        .toList();
  }

  /// Get all episode downloads (any status) for a specific show
  List<DownloadProgress> _getEpisodeDownloadsForShow(String showRatingKey) {
    return _downloads.entries
        .where((entry) {
          final meta = _metadata[entry.key];
          return meta?.type == 'episode' && meta?.grandparentRatingKey == showRatingKey;
        })
        .map((entry) => entry.value)
        .toList();
  }

  /// Get all episode downloads (any status) for a specific season
  List<DownloadProgress> _getEpisodeDownloadsForSeason(String seasonRatingKey) {
    return _downloads.entries
        .where((entry) {
          final meta = _metadata[entry.key];
          return meta?.type == 'episode' && meta?.parentRatingKey == seasonRatingKey;
        })
        .map((entry) => entry.value)
        .toList();
  }

  /// Calculate aggregate progress for a show (based on all its episodes)
  /// Returns synthetic DownloadProgress with aggregated values
  DownloadProgress? getAggregateProgressForShow(String serverId, String showRatingKey) {
    return _calculateAggregateProgress(
      serverId: serverId,
      ratingKey: showRatingKey,
      episodes: _getEpisodeDownloadsForShow(showRatingKey),
      entityType: 'show',
    );
  }

  /// Calculate aggregate progress for a season (based on all its episodes)
  /// Returns synthetic DownloadProgress with aggregated values
  DownloadProgress? getAggregateProgressForSeason(String serverId, String seasonRatingKey) {
    return _calculateAggregateProgress(
      serverId: serverId,
      ratingKey: seasonRatingKey,
      episodes: _getEpisodeDownloadsForSeason(seasonRatingKey),
      entityType: 'season',
    );
  }

  /// Shared helper to calculate aggregate download progress for shows/seasons
  DownloadProgress? _calculateAggregateProgress({
    required String serverId,
    required String ratingKey,
    required List<DownloadProgress> episodes,
    required String entityType,
  }) {
    final globalKey = buildGlobalKey(serverId, ratingKey);

    // DIAGNOSTIC: Check all sources of episode count
    final meta = _metadata[globalKey];
    final metadataLeafCount = meta?.leafCount;
    final storedCount = _totalEpisodeCounts[globalKey];
    final downloadedCount = episodes.length;

    appLogger.d(
      '📊 Episode count sources for $entityType $ratingKey:\n'
      '  - Metadata leafCount: $metadataLeafCount\n'
      '  - Stored count: $storedCount\n'
      '  - Downloaded episodes: $downloadedCount\n'
      '  - Metadata exists: ${meta != null}\n'
      '  - Type: ${meta?.type}\n'
      '  - Title: ${meta?.title}',
    );

    // Get total episode count - Use metadata.leafCount as primary source
    int totalEpisodes;
    String countSource;

    if (metadataLeafCount != null && metadataLeafCount > 0) {
      totalEpisodes = metadataLeafCount;
      countSource = 'metadata.leafCount';
    } else if (storedCount != null && storedCount > 0) {
      totalEpisodes = storedCount;
      countSource = 'stored count (SharedPreferences)';
    } else {
      totalEpisodes = downloadedCount;
      countSource = 'downloaded episodes (fallback)';
    }

    appLogger.d('✅ Using totalEpisodes=$totalEpisodes from [$countSource] for $entityType $ratingKey');

    // If we have stored count but no downloads, check if it's a valid partial state
    if (totalEpisodes == 0 || (episodes.isEmpty && totalEpisodes > 0)) {
      appLogger.d('⚠️  No valid downloads for $entityType $ratingKey, returning null');
      return null;
    }

    // Calculate aggregate statistics
    int completedCount = 0;
    int downloadingCount = 0;
    int queuedCount = 0;
    int failedCount = 0;

    for (final ep in episodes) {
      switch (ep.status) {
        case DownloadStatus.completed:
          completedCount++;
        case DownloadStatus.downloading:
          downloadingCount++;
        case DownloadStatus.queued:
          queuedCount++;
        case DownloadStatus.failed:
          failedCount++;
        default:
          break;
      }
    }

    // Determine overall status
    final DownloadStatus overallStatus;
    if (completedCount == totalEpisodes) {
      overallStatus = DownloadStatus.completed;
    } else if (completedCount > 0 && downloadingCount == 0 && queuedCount == 0 && completedCount < totalEpisodes) {
      overallStatus = DownloadStatus.partial;
    } else if (downloadingCount > 0) {
      overallStatus = DownloadStatus.downloading;
    } else if (queuedCount > 0) {
      overallStatus = DownloadStatus.queued;
    } else if (failedCount > 0) {
      overallStatus = DownloadStatus.failed;
    } else {
      return null;
    }

    // Calculate overall progress percentage based on TOTAL episodes
    final int overallProgress = totalEpisodes > 0 ? ((completedCount * 100) / totalEpisodes).round() : 0;

    appLogger.d(
      'Aggregate progress for $entityType $ratingKey: $overallProgress% '
      '($completedCount completed, $downloadingCount downloading, '
      '$queuedCount queued of $totalEpisodes total) - Status: $overallStatus',
    );

    return DownloadProgress(
      globalKey: globalKey,
      status: overallStatus,
      progress: overallProgress,
      downloadedBytes: 0,
      totalBytes: 0,
      currentFile: '$completedCount/$totalEpisodes episodes',
    );
  }

  /// Whether there are any downloads (active or completed)
  bool get hasDownloads => _downloads.isNotEmpty;

  /// Whether there are any active downloads
  bool get hasActiveDownloads =>
      _downloads.values.any((p) => p.status == DownloadStatus.downloading || p.status == DownloadStatus.queued);

  /// Get download progress for a specific item
  /// For shows/seasons, returns aggregate progress of all child episodes
  /// For episodes/movies, returns direct progress
  DownloadProgress? getProgress(String globalKey) {
    // First check if we have direct progress (for episodes/movies)
    final directProgress = _downloads[globalKey];
    if (directProgress != null) {
      return directProgress;
    }

    // If no direct progress, check if this is a show or season
    // and calculate aggregate progress from episodes
    final parsed = parseGlobalKey(globalKey);
    if (parsed == null) return null;

    final serverId = parsed.serverId;
    final ratingKey = parsed.ratingKey;

    // Try to get metadata to determine type
    final meta = _metadata[globalKey];
    if (meta == null) {
      // No metadata stored yet, might be a show/season being queued
      // Check if any episodes exist for this as a parent
      final episodesAsShow = _getEpisodeDownloadsForShow(ratingKey);
      if (episodesAsShow.isNotEmpty) {
        return getAggregateProgressForShow(serverId, ratingKey);
      }

      final episodesAsSeason = _getEpisodeDownloadsForSeason(ratingKey);
      if (episodesAsSeason.isNotEmpty) {
        return getAggregateProgressForSeason(serverId, ratingKey);
      }

      return null;
    }

    // We have metadata, check type
    final type = meta.type.toLowerCase();
    if (type == 'show') {
      return getAggregateProgressForShow(serverId, ratingKey);
    } else if (type == 'season') {
      return getAggregateProgressForSeason(serverId, ratingKey);
    }

    return null;
  }

  /// Check if an item is downloaded
  /// For shows/seasons, checks if all episodes are downloaded
  bool isDownloaded(String globalKey) {
    final progress = getProgress(globalKey);
    return progress?.status == DownloadStatus.completed;
  }

  /// Check if an item is currently downloading
  /// For shows/seasons, checks if any episodes are downloading
  bool isDownloading(String globalKey) {
    final progress = getProgress(globalKey);
    return progress?.status == DownloadStatus.downloading;
  }

  /// Check if an item is in the queue
  /// For shows/seasons, checks if any episodes are queued
  bool isQueued(String globalKey) {
    final progress = getProgress(globalKey);
    return progress?.status == DownloadStatus.queued;
  }

  /// Check if an item is currently being queued (building download queue)
  bool isQueueing(String globalKey) => _queueing.contains(globalKey);

  /// Get the local video file path for a downloaded item
  /// Returns null if not downloaded or file doesn't exist
  Future<String?> getVideoFilePath(String globalKey) async {
    appLogger.d('getVideoFilePath called with globalKey: $globalKey');

    final downloadedItem = await _downloadManager.getDownloadedMedia(globalKey);
    if (downloadedItem == null) {
      appLogger.w('No downloaded item found for globalKey: $globalKey');
      return null;
    }
    if (downloadedItem.status != DownloadStatus.completed.index) {
      appLogger.w('Download not complete. Status: ${downloadedItem.status}');
      return null;
    }
    if (downloadedItem.videoFilePath == null) {
      appLogger.w('Video file path is null for globalKey: $globalKey');
      return null;
    }

    final storedPath = downloadedItem.videoFilePath!;
    final storageService = DownloadStorageService.instance;

    // SAF URIs (content://) are already valid - don't transform them
    if (storageService.isSafUri(storedPath)) {
      appLogger.d('Found SAF video path: $storedPath');
      return storedPath;
    }

    // Convert stored path (may be relative) to absolute path
    final absolutePath = await storageService.ensureAbsolutePath(storedPath);

    // Verify file exists
    final file = File(absolutePath);
    if (!await file.exists()) {
      appLogger.w('Offline video file not found: $absolutePath');
      return null;
    }
    return absolutePath;
  }

  /// Queue a download for a media item.
  /// For movies and episodes, queues directly.
  /// For shows and seasons, fetches all child episodes and queues them.
  /// Returns the number of items queued.
  Future<int> queueDownload(PlexMetadata metadata, PlexClient client) async {
    final globalKey = metadata.globalKey;

    // Check if downloads are blocked on cellular
    if (await DownloadManagerService.shouldBlockDownloadOnCellular()) {
      throw CellularDownloadBlockedException();
    }

    try {
      // Mark as queueing to show loading state in UI
      _queueing.add(globalKey);
      notifyListeners();

      final type = metadata.type.toLowerCase();

      if (type == 'movie' || type == 'episode') {
        // Direct download of a single item
        await _queueSingleDownload(metadata, client);
        return 1;
      } else if (type == 'show') {
        // Store show metadata so getProgress() can identify it as a show
        _metadata[globalKey] = metadata;

        // Download all episodes from all seasons
        return await _queueShowDownload(metadata, client);
      } else if (type == 'season') {
        // Store season metadata so getProgress() can identify it as a season
        _metadata[globalKey] = metadata;

        // Download all episodes in season
        return await _queueSeasonDownload(metadata, client);
      } else {
        throw Exception('Cannot download ${metadata.type}');
      }
    } on StorageUnavailableException {
      _storageError = t.downloads.storageUnavailable;
      notifyListeners();
      return 0;
    } finally {
      // Always remove from queueing set, even on error
      _queueing.remove(globalKey);
      notifyListeners();
    }
  }

  /// Queue a single movie or episode for download
  Future<void> _queueSingleDownload(PlexMetadata metadata, PlexClient client) async {
    final globalKey = metadata.globalKey;

    // Don't re-queue if already downloading or completed
    if (_downloads.containsKey(globalKey)) {
      final existing = _downloads[globalKey]!;
      if (existing.status == DownloadStatus.downloading || existing.status == DownloadStatus.completed) {
        return;
      }
    }

    // Always fetch full metadata before downloading.
    // Hub items may have summary but the cache at /library/metadata/$ratingKey
    // won't have the full API response (with Media/Part data needed for video URL)
    // unless getMetadataWithImages has been called.
    PlexMetadata metadataToStore = metadata;
    try {
      final fullMetadata = await client.getMetadataWithImages(metadata.ratingKey);
      if (fullMetadata != null) {
        metadataToStore = fullMetadata.copyWith(serverId: metadata.serverId, serverName: metadata.serverName);
      }
    } catch (e) {
      appLogger.w('Failed to fetch full metadata for ${metadata.ratingKey}, using partial', error: e);
    }

    // For episodes, also fetch and store show and season metadata for offline display
    if (metadataToStore.type == 'episode') {
      await _fetchAndStoreParentMetadata(metadataToStore, client);
    }

    // Store full metadata for display
    _metadata[globalKey] = metadataToStore;

    // Update local state immediately for UI feedback
    _downloads[globalKey] = DownloadProgress(globalKey: globalKey, status: DownloadStatus.queued);
    notifyListeners();

    // Resolve transcodeQuality from per-series download settings (Drift-backed)
    String? transcodeQuality;
    if (metadataToStore.type == 'episode') {
      final showKey = metadataToStore.grandparentRatingKey;
      if (showKey != null && metadataToStore.serverId != null) {
        final settingsGlobalKey = buildGlobalKey(metadataToStore.serverId!, showKey);
        transcodeQuality = _seriesSettings[settingsGlobalKey]?.transcodeQuality;
      }
    } else if (metadataToStore.type == 'movie' && metadataToStore.serverId != null) {
      final settingsGlobalKey = buildGlobalKey(metadataToStore.serverId!, metadataToStore.ratingKey);
      transcodeQuality = _seriesSettings[settingsGlobalKey]?.transcodeQuality;
    }

    // Actually trigger download via DownloadManagerService
    await _downloadManager.queueDownload(
      metadata: metadataToStore,
      client: client,
      transcodeQuality: transcodeQuality,
    );
  }

  /// Fetch and store show and season metadata for an episode
  /// Also downloads artwork for show and season
  Future<void> _fetchAndStoreParentMetadata(PlexMetadata episode, PlexClient client) async {
    final serverId = episode.serverId;
    if (serverId == null) return;
    final storageService = DownloadStorageService.instance;

    // Fetch and store show metadata if not already stored
    final showRatingKey = episode.grandparentRatingKey;
    if (showRatingKey != null) {
      final showGlobalKey = buildGlobalKey(serverId, showRatingKey);

      // Try to use existing metadata (set when queueing an entire show)
      PlexMetadata? showMetadata = _metadata[showGlobalKey];

      // If not already cached, fetch full metadata with images
      if (showMetadata == null) {
        try {
          showMetadata = await client.getMetadataWithImages(showRatingKey);
        } catch (e) {
          appLogger.w('Failed to fetch show metadata for $showRatingKey', error: e);
        }
      }

      if (showMetadata != null) {
        final showWithServer = showMetadata.copyWith(serverId: serverId);
        _metadata[showGlobalKey] = showWithServer;

        // Persist to database/API cache for offline usage
        await _downloadManager.saveMetadata(showWithServer);

        // Ensure show artwork is downloaded even if metadata already existed
        final thumbPath = showWithServer.thumb;
        final hasPoster = thumbPath != null && await storageService.artworkExists(serverId, thumbPath);
        if (!hasPoster) {
          await _downloadManager.downloadArtworkForMetadata(showWithServer, client);
          appLogger.d('Downloaded show artwork for $showGlobalKey');
        }

        // Store artwork reference in provider's map for offline display
        _artworkPaths[showGlobalKey] = DownloadedArtwork(thumbPath: thumbPath);
      }
    }

    // Fetch and store season metadata if not already stored
    final seasonRatingKey = episode.parentRatingKey;
    if (seasonRatingKey != null) {
      final seasonGlobalKey = buildGlobalKey(serverId, seasonRatingKey);
      PlexMetadata? seasonMetadata = _metadata[seasonGlobalKey];

      if (seasonMetadata == null) {
        try {
          seasonMetadata = await client.getMetadataWithImages(seasonRatingKey);
        } catch (e) {
          appLogger.w('Failed to fetch season metadata for $seasonRatingKey', error: e);
        }
      }

      if (seasonMetadata != null) {
        final seasonWithServer = seasonMetadata.copyWith(serverId: serverId);
        _metadata[seasonGlobalKey] = seasonWithServer;

        // Persist to database/API cache for offline usage
        await _downloadManager.saveMetadata(seasonWithServer);

        // Ensure season artwork is downloaded even if metadata already existed
        final thumbPath = seasonWithServer.thumb;
        final hasPoster = thumbPath != null && await storageService.artworkExists(serverId, thumbPath);
        if (!hasPoster) {
          await _downloadManager.downloadArtworkForMetadata(seasonWithServer, client);
          appLogger.d('Downloaded season artwork for $seasonGlobalKey');
        }

        // Store artwork reference in provider's map for offline display
        _artworkPaths[seasonGlobalKey] = DownloadedArtwork(thumbPath: thumbPath);
      }
    }
  }

  /// Queue all episodes from a TV show for download
  Future<int> _queueShowDownload(PlexMetadata show, PlexClient client) async {
    final globalKey = show.globalKey;
    int count = 0;
    final seasons = await client.getChildren(show.ratingKey);

    // Store total episode count from show metadata (leafCount)
    if (show.leafCount != null && show.leafCount! > 0) {
      _totalEpisodeCounts[globalKey] = show.leafCount!;
      await _persistTotalEpisodeCount(globalKey, show.leafCount!);
      appLogger.i(
        '💾 Stored episode count for show $globalKey: ${show.leafCount}\n'
        '  - Show title: ${show.title}\n'
        '  - Show type: ${show.type}\n'
        '  - Total stored counts: ${_totalEpisodeCounts.length}',
      );
    } else {
      appLogger.w(
        '⚠️  Show $globalKey has no leafCount! Cannot store episode count.\n'
        '  - Show title: ${show.title}\n'
        '  - Show type: ${show.type}\n'
        '  - leafCount value: ${show.leafCount}',
      );
    }

    for (final season in seasons) {
      if (season.type == 'season') {
        // Ensure season has serverId from parent show
        final seasonWithServer = season.serverId != null ? season : season.copyWith(serverId: show.serverId);
        count += await _queueSeasonDownload(seasonWithServer, client);
      }
    }

    return count;
  }

  /// Queue all episodes from a season for download
  Future<int> _queueSeasonDownload(PlexMetadata season, PlexClient client) async {
    final globalKey = season.globalKey;
    int count = 0;
    final episodes = await client.getChildren(season.ratingKey);

    // Store total episode count from season metadata (leafCount)
    if (season.leafCount != null && season.leafCount! > 0) {
      _totalEpisodeCounts[globalKey] = season.leafCount!;
      await _persistTotalEpisodeCount(globalKey, season.leafCount!);
      appLogger.i(
        '💾 Stored episode count for season $globalKey: ${season.leafCount}\n'
        '  - Season title: ${season.title}\n'
        '  - Season type: ${season.type}\n'
        '  - Total stored counts: ${_totalEpisodeCounts.length}',
      );
    } else {
      appLogger.w(
        '⚠️  Season $globalKey has no leafCount! Cannot store episode count.\n'
        '  - Season title: ${season.title}\n'
        '  - Season type: ${season.type}\n'
        '  - leafCount value: ${season.leafCount}',
      );
    }

    for (final episode in episodes) {
      if (episode.type == 'episode') {
        // Ensure episode has serverId from parent season
        final episodeWithServer = episode.serverId != null ? episode : episode.copyWith(serverId: season.serverId);
        await _queueSingleDownload(episodeWithServer, client);
        count++;
      }
    }

    return count;
  }

  /// Queue only the missing (not downloaded) episodes for a show/season
  /// Used for resuming partial downloads
  /// Returns the number of episodes queued
  Future<int> queueMissingEpisodes(PlexMetadata metadata, PlexClient client) async {
    final type = metadata.type.toLowerCase();

    if (type == 'show') {
      return await _queueMissingShowEpisodes(metadata, client);
    } else if (type == 'season') {
      return await _queueMissingSeasonEpisodes(metadata, client);
    } else {
      throw Exception('queueMissingEpisodes only supports shows/seasons');
    }
  }

  /// Queue missing episodes for a show
  Future<int> _queueMissingShowEpisodes(PlexMetadata show, PlexClient client) async {
    int queuedCount = 0;

    // Fetch all seasons
    final seasons = await client.getChildren(show.ratingKey);

    for (final season in seasons) {
      if (season.type == 'season') {
        final seasonWithServer = season.serverId != null ? season : season.copyWith(serverId: show.serverId);
        queuedCount += await _queueMissingSeasonEpisodes(seasonWithServer, client);
      }
    }

    appLogger.i('Queued $queuedCount missing episodes for show ${show.title}');
    return queuedCount;
  }

  /// Queue missing episodes for a season
  Future<int> _queueMissingSeasonEpisodes(PlexMetadata season, PlexClient client) async {
    int queuedCount = 0;

    // Fetch all episodes
    final episodes = await client.getChildren(season.ratingKey);

    for (final episode in episodes) {
      if (episode.type == 'episode') {
        final episodeWithServer = episode.serverId != null ? episode : episode.copyWith(serverId: season.serverId);

        final episodeGlobalKey = episodeWithServer.globalKey;

        // Only queue if NOT already downloaded or in progress
        final progress = _downloads[episodeGlobalKey];
        if (progress == null ||
            (progress.status != DownloadStatus.completed &&
                progress.status != DownloadStatus.downloading &&
                progress.status != DownloadStatus.queued)) {
          await _queueSingleDownload(episodeWithServer, client);
          queuedCount++;
          appLogger.d('Queued missing episode: ${episode.title} ($episodeGlobalKey)');
        }
      }
    }

    return queuedCount;
  }

  /// Get season globalKeys with existing downloads for a show.
  /// Used when downloadNewSeasons is OFF to restrict auto-download to tracked seasons.
  Set<String> _getDownloadedSeasonKeys(String showGlobalKey) {
    final parsed = parseGlobalKey(showGlobalKey);
    if (parsed == null) return {};

    final seasonKeys = <String>{};
    for (final entry in _downloads.entries) {
      // Only count active downloads (not failed/cancelled)
      if (entry.value.status == DownloadStatus.failed || entry.value.status == DownloadStatus.cancelled) continue;

      final episodeMeta = _metadata[entry.key];
      if (episodeMeta == null) continue;
      if (episodeMeta.serverId != parsed.serverId) continue;
      if (episodeMeta.grandparentRatingKey != parsed.ratingKey) continue;

      if (episodeMeta.parentRatingKey != null) {
        seasonKeys.add(buildGlobalKey(parsed.serverId, episodeMeta.parentRatingKey!));
      }
    }
    return seasonKeys;
  }

  /// Queue missing episodes only for seasons with existing downloads.
  /// Used when downloadNewSeasons is OFF but downloadNewEpisodes is ON.
  Future<int> _queueMissingEpisodesForTrackedSeasons(String showGlobalKey, PlexClient client) async {
    final trackedSeasonKeys = _getDownloadedSeasonKeys(showGlobalKey);
    if (trackedSeasonKeys.isEmpty) {
      appLogger.d('Auto-download: No tracked seasons for $showGlobalKey');
      return 0;
    }

    int totalQueued = 0;
    for (final seasonKey in trackedSeasonKeys) {
      var seasonMeta = _metadata[seasonKey];
      if (seasonMeta == null) {
        // Fallback: fetch season metadata from API when not in cache
        final parsedSeason = parseGlobalKey(seasonKey);
        if (parsedSeason != null) {
          try {
            final fetched = await client.getMetadataWithImages(parsedSeason.ratingKey);
            if (fetched != null) {
              seasonMeta = fetched.serverId != null ? fetched : fetched.copyWith(serverId: parsedSeason.serverId);
              _metadata[seasonKey] = seasonMeta;
            }
          } catch (e) {
            appLogger.w('Auto-download: Failed to fetch metadata for season $seasonKey', error: e);
          }
        }
      }
      if (seasonMeta == null) {
        appLogger.w('Auto-download: No metadata for tracked season $seasonKey, skipping');
        continue;
      }
      totalQueued += await _queueMissingSeasonEpisodes(seasonMeta, client);
    }
    return totalQueued;
  }

  /// Pause a download (works for both downloading and queued items)
  Future<void> pauseDownload(String globalKey) async {
    final progress = _downloads[globalKey];
    if (progress != null &&
        (progress.status == DownloadStatus.downloading || progress.status == DownloadStatus.queued)) {
      await _downloadManager.pauseDownload(globalKey);
    }
  }

  /// Resume a paused download
  Future<void> resumeDownload(String globalKey, PlexClient client) async {
    final progress = _downloads[globalKey];
    if (progress != null && progress.status == DownloadStatus.paused) {
      final transcodeQuality = _resolveTranscodeQuality(globalKey);
      await _downloadManager.resumeDownload(globalKey, client, transcodeQuality: transcodeQuality);
    }
  }

  /// Retry a failed download
  Future<void> retryDownload(String globalKey, PlexClient client) async {
    final progress = _downloads[globalKey];
    if (progress != null && progress.status == DownloadStatus.failed) {
      final transcodeQuality = _resolveTranscodeQuality(globalKey);
      await _downloadManager.retryDownload(globalKey, client, transcodeQuality: transcodeQuality);
    }
  }

  /// Resolve transcodeQuality for a download from per-series settings (Drift-backed).
  String? _resolveTranscodeQuality(String globalKey) {
    final metadata = _metadata[globalKey];
    if (metadata == null || metadata.serverId == null) return null;
    if (metadata.type == 'episode') {
      final showKey = metadata.grandparentRatingKey;
      if (showKey != null) {
        final settingsGlobalKey = buildGlobalKey(metadata.serverId!, showKey);
        return _seriesSettings[settingsGlobalKey]?.transcodeQuality;
      }
    } else if (metadata.type == 'movie') {
      final settingsGlobalKey = buildGlobalKey(metadata.serverId!, metadata.ratingKey);
      return _seriesSettings[settingsGlobalKey]?.transcodeQuality;
    }
    return null;
  }

  /// Cancel a download
  Future<void> cancelDownload(String globalKey) async {
    final progress = _downloads[globalKey];
    if (progress != null) {
      await _downloadManager.cancelDownload(globalKey);
      _downloads.remove(globalKey);
      _metadata.remove(globalKey);
      notifyListeners();
    }
  }

  /// Delete a downloaded item
  Future<void> deleteDownload(String globalKey) async {
    try {
      // Check if this is a show/season and clean up episode count
      final meta = _metadata[globalKey];
      if (meta?.type == 'show' || meta?.type == 'season') {
        final removedCount = _totalEpisodeCounts.remove(globalKey);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('episode_count_$globalKey');
        appLogger.i(
          '🗑️  Removed episode count for $globalKey\n'
          '  - Removed count value: $removedCount\n'
          '  - Metadata type: ${meta?.type}\n'
          '  - Metadata title: ${meta?.title}\n'
          '  - Remaining stored counts: ${_totalEpisodeCounts.length}',
        );
      }

      // Start deletion (progress will be tracked via stream)
      await _downloadManager.deleteDownload(globalKey);

      // Remove from local state
      _downloads.remove(globalKey);
      _metadata.remove(globalKey);
      _artworkPaths.remove(globalKey);

      notifyListeners();
    } on StorageUnavailableException {
      _storageError = t.downloads.storageUnavailable;
      notifyListeners();
    } catch (e) {
      // Remove from deletion tracking on error
      _deletionProgress.remove(globalKey);
      notifyListeners();
      rethrow;
    }
  }

  /// Handle deletion progress updates
  void _onDeletionProgressUpdate(DeletionProgress progress) {
    if (progress.isComplete) {
      // Deletion complete - remove from tracking
      _deletionProgress.remove(progress.globalKey);
    } else {
      // Update progress
      _deletionProgress[progress.globalKey] = progress;
    }
    notifyListeners();
  }

  /// Check if an item is being deleted
  bool isDeleting(String globalKey) => _deletionProgress.containsKey(globalKey);

  /// Get deletion progress for an item
  DeletionProgress? getDeletionProgress(String globalKey) => _deletionProgress[globalKey];

  /// Get all items currently being deleted
  UnmodifiableMapView<String, DeletionProgress> get deletionProgress => UnmodifiableMapView(_deletionProgress);

  /// Refresh the downloads list from database
  Future<void> refresh() async {
    await _loadPersistedDownloads();
  }

  /// Resume queued downloads that were interrupted by app kill.
  /// Call after a PlexClient becomes available (e.g. after server connect on launch).
  void resumeQueuedDownloads(PlexClient client) {
    _downloadManager.resumeQueuedDownloads(client);
  }

  /// Per-show mutex: prevents duplicate concurrent refresh operations for the same show.
  /// If a refresh is already in-flight for [globalKey], waiting callers await the existing
  /// Completer instead of starting a new one. The entry is removed in a finally block (AC #3).
  Future<void> _withShowRefreshMutex(String globalKey, Future<void> Function() fn) async {
    final existing = _showRefreshCompleters[globalKey];
    if (existing != null) {
      // Another caller is refreshing this show — await it without propagating its error
      try {
        await existing.future;
      } catch (_) {
        // Swallow: we didn't initiate this operation
      }
      return;
    }

    final completer = Completer<void>();
    _showRefreshCompleters[globalKey] = completer;

    try {
      await fn();
      completer.complete();
    } catch (e) {
      completer.completeError(e);
      rethrow;
    } finally {
      _showRefreshCompleters.remove(globalKey);
    }
  }

  /// Auto-download new episodes for shows with [downloadNewEpisodes] enabled.
  /// Call fire-and-forget after server connection on app startup (do NOT await).
  /// All configured shows are refreshed in parallel for fast startup (AC #1).
  Future<void> autoDownloadNewEpisodes({
    required Map<String, PlexClient> onlineClients,
  }) async {
    if (onlineClients.isEmpty) return;

    final autoDownloadSettings = _seriesSettings.values.where((s) => s.downloadNewEpisodes).toList();
    if (autoDownloadSettings.isEmpty) return;

    appLogger.i('Auto-download: Checking ${autoDownloadSettings.length} configured series');

    final futures = <Future<void>>[];

    for (final settings in autoDownloadSettings) {
      final parsed = parseGlobalKey(settings.globalKey);
      if (parsed == null) continue;

      final client = onlineClients[parsed.serverId];
      if (client == null) continue; // Server offline — skip

      final showMetadata = _metadata[settings.globalKey];
      if (showMetadata == null) {
        appLogger.w('Auto-download: No metadata for ${settings.globalKey}, skipping');
        continue;
      }

      futures.add(
        _withShowRefreshMutex(settings.globalKey, () async {
          int queued;
          if (settings.downloadNewSeasons) {
            appLogger.d('Auto-download: ${showMetadata.title} - all seasons mode');
            queued = await queueMissingEpisodes(showMetadata, client);
          } else {
            appLogger.d('Auto-download: ${showMetadata.title} - tracked seasons only mode');
            queued = await _queueMissingEpisodesForTrackedSeasons(settings.globalKey, client);
          }
          if (queued > 0) {
            appLogger.i('Auto-download: Queued $queued new episodes for ${showMetadata.title}');
          }
        }).catchError((Object e) {
          appLogger.w('Auto-download failed for ${showMetadata.title}', error: e);
        }),
      );
    }

    await Future.wait(futures);
    appLogger.i('Auto-download: Complete');

    // Evaluate retention policies after auto-download completes
    // Skip if already pending from startup evaluation (avoids redundant DB queries)
    if (_pendingRetentionTrims == null) {
      final trims = await evaluateRetentionPolicies();
      if (trims.isNotEmpty) {
        _pendingRetentionTrims = trims;
        appLogger.i('Retention: ${trims.length} shows have episodes exceeding limits');
        notifyListeners();
      }
    }
  }

  /// Evaluate retention policies for all series with limits configured.
  /// Returns a list of [RetentionTrimResult] for shows with episodes exceeding their limits.
  Future<List<RetentionTrimResult>> evaluateRetentionPolicies() async {
    final results = <RetentionTrimResult>[];
    final now = DateTime.now().millisecondsSinceEpoch;

    for (final settings in _seriesSettings.values) {
      if (!settings.hasRetentionPolicy && !settings.hasEpisodeLimit) continue;

      final parsed = parseGlobalKey(settings.globalKey);
      if (parsed == null) continue;

      // Query DB for all episodes of this show, then scope by serverId for multi-server safety
      final allEpisodes = await _downloadManager.database.getEpisodesByShow(parsed.ratingKey);
      final scoped = allEpisodes.where((e) => e.serverId == parsed.serverId).toList();
      final completed = scoped.where((e) => e.status == DownloadStatus.completed.index).toList();

      if (completed.isEmpty) continue;

      // Sort: watched episodes first (oldest→newest), then unwatched (oldest→newest)
      completed.sort((a, b) {
        final aWatched = _isWatchedOrInProgress(a.globalKey);
        final bWatched = _isWatchedOrInProgress(b.globalKey);
        if (aWatched != bWatched) return aWatched ? -1 : 1;
        final aTime = a.downloadedAt ?? 0;
        final bTime = b.downloadedAt ?? 0;
        return aTime.compareTo(bTime);
      });

      final violations = <String>{};

      // Apply retentionDays: episodes older than limit (skip null downloadedAt)
      if (settings.hasRetentionPolicy) {
        final cutoff = now - settings.retentionDays * 86400000;
        for (final episode in completed) {
          if (episode.downloadedAt != null && episode.downloadedAt! < cutoff) {
            violations.add(episode.globalKey);
          }
        }
      }

      // Apply maxEpisodes: oldest episodes beyond limit (treat null downloadedAt as epoch 0)
      if (settings.hasEpisodeLimit && completed.length > settings.maxEpisodes) {
        final excess = completed.length - settings.maxEpisodes;
        for (var i = 0; i < excess; i++) {
          violations.add(completed[i].globalKey);
        }
      }

      if (violations.isEmpty) continue;

      // Preserve trim priority order from sorted list
      final orderedKeys = completed.map((e) => e.globalKey).where(violations.contains).toList();

      // Look up show title from metadata
      final showMeta = _metadata[settings.globalKey];
      final showTitle = showMeta?.title ?? settings.ratingKey;

      results.add(
        RetentionTrimResult(
          showGlobalKey: settings.globalKey,
          showTitle: showTitle,
          episodeGlobalKeys: orderedKeys,
          totalEpisodesForShow: completed.length,
        ),
      );
    }

    return results;
  }

  bool _isWatchedOrInProgress(String episodeGlobalKey) {
    final meta = _metadata[episodeGlobalKey];
    if (meta == null) return false;
    final isWatched = meta.viewCount != null && meta.viewCount! > 0;
    final isInProgress =
        meta.viewOffset != null && meta.duration != null && meta.viewOffset! > 0 && meta.viewOffset! < meta.duration!;
    return isWatched || isInProgress;
  }

  /// Execute retention trim: delete all episodes identified by [trims].
  /// Settings are preserved — only episode records are removed (AC #3).
  Future<void> executeRetentionTrim(List<RetentionTrimResult> trims) async {
    final totalEpisodes = trims.fold<int>(0, (sum, t) => sum + t.episodeCount);
    int deletedCount = 0;

    for (final trim in trims) {
      for (final episodeKey in trim.episodeGlobalKeys) {
        _retentionTrimProgress = DeletionProgress(
          globalKey: 'retention-trim',
          itemTitle: trim.showTitle,
          currentItem: deletedCount,
          totalItems: totalEpisodes,
        );
        notifyListeners();

        try {
          await deleteDownload(episodeKey);
        } catch (e) {
          appLogger.w('Retention trim: failed to delete $episodeKey', error: e);
        }
        deletedCount++;
      }
    }

    // Emit completion state for UI to detect
    _retentionTrimProgress = DeletionProgress(
      globalKey: 'retention-trim',
      itemTitle: '',
      currentItem: totalEpisodes,
      totalItems: totalEpisodes,
    );
    notifyListeners();

    _pendingRetentionTrims = null;
    _clearRetentionTrimProgress();
  }

  /// Refresh only metadata from API cache (after watch state sync).
  ///
  /// This is more lightweight than full refresh() - only updates metadata
  /// without reloading download progress from database.
  Future<void> refreshMetadataFromCache() async {
    final apiCache = PlexApiCache.instance;
    int updatedCount = 0;

    for (final globalKey in _metadata.keys.toList()) {
      final parsed = parseGlobalKey(globalKey);
      if (parsed == null) continue;

      final serverId = parsed.serverId;
      final ratingKey = parsed.ratingKey;

      try {
        final metadata = await apiCache.getMetadata(serverId, ratingKey);
        if (metadata != null) {
          _metadata[globalKey] = metadata;
          updatedCount++;
        }
      } catch (e) {
        appLogger.d('Failed to refresh metadata for $globalKey: $e');
      }
    }

    if (updatedCount > 0) {
      appLogger.i('Refreshed metadata from cache for $updatedCount items');
      notifyListeners();
    }
  }
}

/// Exception thrown when download is blocked due to cellular-only setting
class CellularDownloadBlockedException implements Exception {
  final String message = 'Downloads are disabled on cellular data';

  @override
  String toString() => message;
}
