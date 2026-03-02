import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/focusable_button.dart';
import '../focus/focusable_wrapper.dart';
import '../i18n/strings.g.dart';
import '../models/download_models.dart';
import '../services/plex_client.dart';
import '../widgets/focusable_list_tile.dart';
import '../widgets/settings_save_confirm_dialog.dart';

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

  bool _episodesExpanded = true; // matches initiallyExpanded: true
  bool _retentionExpanded = false; // matches initiallyExpanded: false

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
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quality section (always visible, not collapsible)
            _buildSectionHeader(t.downloads.qualityLabel),
            _buildQualityOptions(),
            const SizedBox(height: 8),
            // Episodes & seasons section (collapsible)
            ExpansionTile(
              title: Text(t.downloads.episodesLabel),
              initiallyExpanded: true,
              onExpansionChanged: (expanded) => setState(() => _episodesExpanded = expanded),
              children: [
                ExcludeFocus(
                  excluding: !_episodesExpanded,
                  child: Column(children: _buildEpisodesChildren()),
                ),
              ],
            ),
            // Retention section (collapsible, initially collapsed)
            ExpansionTile(
              title: Text(t.downloads.retentionLabel),
              initiallyExpanded: false,
              onExpansionChanged: (expanded) => setState(() => _retentionExpanded = expanded),
              children: [
                ExcludeFocus(
                  excluding: !_retentionExpanded,
                  child: Column(children: _buildRetentionChildren()),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FocusableButton(
          onPressed: () => Navigator.pop(context, null),
          child: TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
        ),
        FocusableButton(
          onPressed: _onDownloadPressed,
          child: FilledButton(
            onPressed: _onDownloadPressed,
            child: Text(widget.initialSettings != null ? t.downloads.save : t.downloads.downloadNow),
          ),
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

  List<Widget> _buildEpisodesChildren() {
    return [
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
      ExcludeFocus(
        excluding: !_downloadNewEpisodes,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FocusableWrapper(
            borderRadius: 8.0,
            useBackgroundFocus: true,
            disableScale: true,
            child: TextFormField(
              controller: _maxEpisodesController,
              decoration: InputDecoration(
                labelText: t.downloads.maxEpisodesLabel,
                hintText: t.downloads.unlimitedHint,
              ),
              enabled: _downloadNewEpisodes,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onTap: () {
                if (_maxEpisodes == 0) {
                  setState(() {
                    _maxEpisodes = 1;
                    _maxEpisodesController.text = '1';
                  });
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _maxEpisodesController.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
                  });
                }
              },
              onChanged: (v) {
                final parsed = int.tryParse(v) ?? 0;
                if (parsed > 0 && v != '$parsed') {
                  _maxEpisodesController.text = '$parsed';
                  _maxEpisodesController.selection = TextSelection.collapsed(offset: '$parsed'.length);
                }
                setState(() => _maxEpisodes = parsed);
              },
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildRetentionChildren() {
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: FocusableWrapper(
          borderRadius: 8.0,
          useBackgroundFocus: true,
          disableScale: true,
          child: TextFormField(
            controller: _retentionDaysController,
            decoration: InputDecoration(
              labelText: t.downloads.retentionDaysLabel,
              hintText: t.downloads.unlimitedHint,
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onTap: () {
              if (_retentionDays == 0) {
                setState(() {
                  _retentionDays = 1;
                  _retentionDaysController.text = '1';
                });
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _retentionDaysController.selection = const TextSelection(baseOffset: 0, extentOffset: 1);
                });
              }
            },
            onChanged: (v) {
              final parsed = int.tryParse(v) ?? 0;
              if (parsed > 0 && v != '$parsed') {
                _retentionDaysController.text = '$parsed';
                _retentionDaysController.selection = TextSelection.collapsed(offset: '$parsed'.length);
              }
              setState(() => _retentionDays = parsed);
            },
          ),
        ),
      ),
    ];
  }

  void _onDownloadPressed() async {
    // Auto-correction: if downloadNewEpisodes is ON but no meaningful episode option is set, correct to OFF (FR27)
    // Use a local variable to avoid mutating State — the UI switch must stay consistent if user cancels.
    final downloadNewEpisodes = (_downloadNewEpisodes && _maxEpisodes == 0 && !_downloadNewSeasons) ? false : _downloadNewEpisodes;

    final newSettings = SeriesDownloadSettings.defaults(
      serverId: widget.serverId,
      ratingKey: widget.ratingKey,
    ).copyWith(
      transcodeQuality: _transcodeQuality,
      clearTranscodeQuality: _transcodeQuality == null,
      downloadNewEpisodes: downloadNewEpisodes,
      downloadNewSeasons: _downloadNewSeasons,
      maxEpisodes: _maxEpisodes,
      retentionDays: _retentionDays,
    );

    // First-time flow: no confirmation needed
    if (widget.initialSettings == null) {
      Navigator.pop(context, newSettings);
      return;
    }

    // Edit mode: check for changes
    if (!_hasChanges(widget.initialSettings!, newSettings)) {
      Navigator.pop(context, null);
      return;
    }

    // Show confirmation dialog
    final confirmed = await SettingsSaveConfirmDialog.show(
      context,
      oldSettings: widget.initialSettings!,
      newSettings: newSettings,
    );
    if (!mounted) return;

    if (confirmed == true) {
      Navigator.pop(context, newSettings);
    }
    // If cancelled, stay in dialog (don't pop)
  }

  bool _hasChanges(SeriesDownloadSettings old, SeriesDownloadSettings new_) {
    return old.transcodeQuality != new_.transcodeQuality ||
        old.downloadNewEpisodes != new_.downloadNewEpisodes ||
        old.downloadNewSeasons != new_.downloadNewSeasons ||
        old.maxEpisodes != new_.maxEpisodes ||
        old.retentionDays != new_.retentionDays;
  }
}
