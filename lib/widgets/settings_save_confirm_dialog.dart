import 'package:flutter/material.dart';
import '../i18n/strings.g.dart';
import '../models/download_models.dart';

class SettingsSaveConfirmDialog extends StatelessWidget {
  final SeriesDownloadSettings oldSettings;
  final SeriesDownloadSettings newSettings;

  const SettingsSaveConfirmDialog({
    super.key,
    required this.oldSettings,
    required this.newSettings,
  });

  static Future<bool?> show(
    BuildContext context, {
    required SeriesDownloadSettings oldSettings,
    required SeriesDownloadSettings newSettings,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => SettingsSaveConfirmDialog(
        oldSettings: oldSettings,
        newSettings: newSettings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final changes = _buildChanges();
    return AlertDialog(
      title: Text(t.downloads.confirmChangesTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: changes,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(t.downloads.confirmSave),
        ),
      ],
    );
  }

  List<Widget> _buildChanges() {
    final widgets = <Widget>[];

    // Quality change with adaptive warning
    if (oldSettings.transcodeQuality != newSettings.transcodeQuality) {
      widgets.add(_buildQualityWarning());
    }

    // Episode toggle change
    if (oldSettings.downloadNewEpisodes != newSettings.downloadNewEpisodes) {
      widgets.add(_buildChangeItem(
        newSettings.downloadNewEpisodes ? t.downloads.changeEpisodesOn : t.downloads.changeEpisodesOff,
      ));
    }

    // Seasons toggle change
    if (oldSettings.downloadNewSeasons != newSettings.downloadNewSeasons) {
      widgets.add(_buildChangeItem(
        newSettings.downloadNewSeasons ? t.downloads.changeSeasonsOn : t.downloads.changeSeasonsOff,
      ));
    }

    // Max episodes change
    if (oldSettings.maxEpisodes != newSettings.maxEpisodes) {
      widgets.add(_buildChangeItem(
        t.downloads.changeMaxEpisodes(value: newSettings.maxEpisodes == 0 ? t.downloads.unlimitedHint : '${newSettings.maxEpisodes}'),
      ));
    }

    // Retention days change
    if (oldSettings.retentionDays != newSettings.retentionDays) {
      widgets.add(_buildChangeItem(
        t.downloads.changeRetentionDays(value: newSettings.retentionDays == 0 ? t.downloads.unlimitedHint : '${newSettings.retentionDays}'),
      ));
    }

    return widgets;
  }

  Widget _buildQualityWarning() {
    final oldQ = oldSettings.transcodeQuality;
    final newQ = newSettings.transcodeQuality;

    String warning;
    if (oldQ == null && newQ != null) {
      // Original → Transcode
      warning = t.downloads.qualityWarningToTranscode(quality: newQ);
    } else if (oldQ != null && newQ == null) {
      // Transcode → Original
      warning = t.downloads.qualityWarningToOriginal;
    } else {
      // Transcode → Different Transcode
      warning = t.downloads.qualityWarningChanged(oldQuality: oldQ!, newQuality: newQ!);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(warning, style: const TextStyle(fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildChangeItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('• $text'),
    );
  }
}
