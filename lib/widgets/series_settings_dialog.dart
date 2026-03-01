import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../i18n/strings.g.dart';
import '../models/download_models.dart';
import '../services/plex_client.dart';
import '../widgets/focusable_list_tile.dart';

class SeriesSettingsDialog extends StatefulWidget {
  final String title;
  final String serverId;
  final String ratingKey;
  final SeriesDownloadSettings? initialSettings;

  const SeriesSettingsDialog({
    super.key,
    required this.title,
    required this.serverId,
    required this.ratingKey,
    this.initialSettings,
  });

  static Future<SeriesDownloadSettings?> show(
    BuildContext context, {
    required String title,
    required String serverId,
    required String ratingKey,
    SeriesDownloadSettings? initialSettings,
  }) {
    return showDialog<SeriesDownloadSettings>(
      context: context,
      builder: (context) => SeriesSettingsDialog(
        title: title,
        serverId: serverId,
        ratingKey: ratingKey,
        initialSettings: initialSettings,
      ),
    );
  }

  @override
  State<SeriesSettingsDialog> createState() => _SeriesSettingsDialogState();
}

class _SeriesSettingsDialogState extends State<SeriesSettingsDialog> {
  String? _transcodeQuality;
  bool _downloadNewEpisodes = false;
  bool _downloadNewSeasons = false;
  int _maxEpisodes = 0;
  int _retentionDays = 0;

  late final TextEditingController _maxEpisodesController;
  late final TextEditingController _retentionDaysController;

  @override
  void initState() {
    super.initState();
    final s = widget.initialSettings;
    if (s != null) {
      _transcodeQuality = s.transcodeQuality;
      _downloadNewEpisodes = s.downloadNewEpisodes;
      _downloadNewSeasons = s.downloadNewSeasons;
      _maxEpisodes = s.maxEpisodes;
      _retentionDays = s.retentionDays;
    }
    _maxEpisodesController = TextEditingController(text: _maxEpisodes > 0 ? '$_maxEpisodes' : '');
    _retentionDaysController = TextEditingController(text: _retentionDays > 0 ? '$_retentionDays' : '');
  }

  @override
  void dispose() {
    _maxEpisodesController.dispose();
    _retentionDaysController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quality section
          _buildSectionHeader(t.downloads.qualityLabel),
          _buildQualityOptions(),
          const SizedBox(height: 16),
          // Episodes & seasons section
          _buildSectionHeader(t.downloads.episodesLabel),
          _buildEpisodesSection(),
          const SizedBox(height: 16),
          // Retention section
          _buildSectionHeader(t.downloads.retentionLabel),
          _buildRetentionSection(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _onDownloadPressed,
          child: Text(t.downloads.downloadNow),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }

  Widget _buildQualityOptions() {
    final presetKeys = PlexClient.transcodePresets.keys.toList();
    return RadioGroup<String?>(
      groupValue: _transcodeQuality,
      onChanged: (v) => setState(() => _transcodeQuality = v),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FocusableRadioListTile<String?>(
            title: Text(t.downloads.qualityOriginal),
            value: null,
            dense: true,
            autofocus: true,
          ),
          ...presetKeys.map((key) => FocusableRadioListTile<String?>(
                title: Text(key),
                value: key,
                dense: true,
              )),
        ],
      ),
    );
  }

  Widget _buildEpisodesSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FocusableSwitchListTile(
          title: Text(t.downloads.downloadNewEpisodes),
          value: _downloadNewEpisodes,
          onChanged: (v) => setState(() {
            _downloadNewEpisodes = v;
            if (v && _maxEpisodes == 0) {
              _maxEpisodes = 1;
              _maxEpisodesController.text = '1';
            }
          }),
          dense: true,
        ),
        FocusableSwitchListTile(
          title: Text(t.downloads.downloadNewSeasons),
          value: _downloadNewSeasons,
          onChanged: (v) => setState(() => _downloadNewSeasons = v),
          dense: true,
        ),
        TextFormField(
          controller: _maxEpisodesController,
          decoration: InputDecoration(
            labelText: t.downloads.maxEpisodesLabel,
            hintText: t.downloads.unlimitedHint,
          ),
          enabled: _downloadNewEpisodes,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (v) {
            final parsed = int.tryParse(v) ?? 0;
            setState(() => _maxEpisodes = parsed);
          },
        ),
      ],
    );
  }

  Widget _buildRetentionSection() {
    return TextFormField(
      controller: _retentionDaysController,
      decoration: InputDecoration(
        labelText: t.downloads.retentionDaysLabel,
        hintText: t.downloads.unlimitedHint,
      ),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (v) {
        final parsed = int.tryParse(v) ?? 0;
        setState(() => _retentionDays = parsed);
      },
    );
  }

  void _onDownloadPressed() {
    final settings = SeriesDownloadSettings.defaults(
      serverId: widget.serverId,
      ratingKey: widget.ratingKey,
    ).copyWith(
      transcodeQuality: _transcodeQuality,
      clearTranscodeQuality: _transcodeQuality == null,
      downloadNewEpisodes: _downloadNewEpisodes,
      downloadNewSeasons: _downloadNewSeasons,
      maxEpisodes: _maxEpisodes,
      retentionDays: _retentionDays,
    );
    Navigator.pop(context, settings);
  }
}
