// The Settings screen lives in widgets/settings_view.dart (it uses the real
// AppSettings API: themeMode, haptics, autoplayNext, previewSound). This file
// only re-exports it, so an old import of 'settings_view.dart' keeps working
// and there is a single SettingsView in the project.
export 'widgets/settings_view.dart';
