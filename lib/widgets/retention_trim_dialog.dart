import 'package:flutter/material.dart';
import '../i18n/strings.g.dart';
import '../models/download_models.dart';

/// Dialog shown before retention-triggered episode deletion.
/// Displays a per-show breakdown of episodes to be removed and requires user confirmation.
class RetentionTrimDialog extends StatelessWidget {
  final List<RetentionTrimResult> trims;

  const RetentionTrimDialog({super.key, required this.trims});

  /// Show the dialog and return true if user confirmed, false if cancelled.
  static Future<bool> show(BuildContext context, List<RetentionTrimResult> trims) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => RetentionTrimDialog(trims: trims),
    );
    return result ?? false;
  }

  int get _totalEpisodes => trims.fold(0, (sum, t) => sum + t.episodeCount);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dl = t.downloads;

    return AlertDialog(
      title: Text(dl.retentionTrimTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dl.retentionTrimMessage),
            const SizedBox(height: 12),
            ...trims.map(
              (trim) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  dl.retentionTrimShowEntry(title: trim.showTitle, count: trim.episodeCount),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              dl.retentionTrimTotal(count: _totalEpisodes),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(dl.retentionTrimCancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: colorScheme.error),
          child: Text(dl.retentionTrimConfirm),
        ),
      ],
    );
  }
}
