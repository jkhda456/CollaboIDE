// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Collabo IDE';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get tabModel => 'Model';

  @override
  String get tabTools => 'Tools';

  @override
  String get tabPrompt => 'Prompt';

  @override
  String get tabAppearance => 'Appearance';

  @override
  String get systemPromptDesc =>
      'System prompt sent at the start of every conversation (execution strategy). Leave empty to use the default.';

  @override
  String get usePreAssessment => 'Use pre-assessment';

  @override
  String get usePreAssessmentDesc =>
      'Before replying, a sub-agent reviews your latest request and adds a one-line note on whether it should be delegated.';

  @override
  String get resetDefault => 'Reset to default';

  @override
  String get close => 'Close';

  @override
  String get cancel => 'Cancel';

  @override
  String get create => 'Create';

  @override
  String get add => 'Add';

  @override
  String get remove => 'Remove';

  @override
  String get save => 'Save';

  @override
  String get saved => 'Saved';

  @override
  String get selectButton => 'Select';

  @override
  String get theme => 'Theme';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get themeSystem => 'Follow system';

  @override
  String get language => 'Language';

  @override
  String get languageSystem => 'System';

  @override
  String get navNewProject => 'New Project';

  @override
  String get navOpenProject => 'Open Project';

  @override
  String get noProjectTitle => 'No project is open';

  @override
  String get startNewProject => 'Start a new project';

  @override
  String get navSettings => 'Settings';

  @override
  String get navCollapse => 'Collapse';

  @override
  String get activityTitle => 'Activity';

  @override
  String activityRunningLabel(int count) {
    return 'Running ($count)';
  }

  @override
  String activityRunningTooltip(int count) {
    return 'Running processes: $count';
  }

  @override
  String get activityIdleTooltip => 'No running processes';

  @override
  String get newProjectTitle => 'New Project';

  @override
  String get selectParentPath => 'Select a parent folder';

  @override
  String get selectPath => 'Select folder';

  @override
  String get projectNameLabel => 'Project name (folder name)';

  @override
  String createLocation(String path) {
    return 'Location: $path';
  }

  @override
  String get pathExists =>
      'A project (folder) with the same name already exists.';

  @override
  String createFailed(String error) {
    return 'Failed to create folder: $error';
  }

  @override
  String get nameEmpty => 'Enter a name.';

  @override
  String get nameInvalidChars =>
      'Contains invalid characters: < > : \" / \\ | ? *';

  @override
  String get nameInvalidName => 'Invalid name.';

  @override
  String get nameTrailingDot => 'Name cannot end with a dot (.) or space.';

  @override
  String get nameReserved => 'Reserved names cannot be used.';

  @override
  String get connectionMethod => 'Connection';

  @override
  String get openaiCompatible => 'OpenAI-compatible API';

  @override
  String get modelLabel => 'Model';

  @override
  String get testConnection => 'Test connection';

  @override
  String get toolsDescription =>
      'Tools the LLM calls via function calling. The base is fixed; you can add a general Python script (--help auto-parse) or an MCP server.';

  @override
  String get addTool => 'Add tool';

  @override
  String get addToolCli => 'General Python script';

  @override
  String get addToolCliDesc => 'Auto-generate tool JSON by analyzing --help';

  @override
  String get addToolMcp => 'MCP tool';

  @override
  String get addToolMcpDesc =>
      'Control an MCP server with bundled Python to add tools';

  @override
  String get mcpAddTitle => 'Add MCP tool';

  @override
  String get mcpCommand => 'Server command';

  @override
  String get mcpCommandHint => 'e.g. npx or python';

  @override
  String get mcpArgs => 'Arguments (space-separated)';

  @override
  String get mcpArgsHint => 'e.g. -y @modelcontextprotocol/server-filesystem .';

  @override
  String get nameOptional => 'Name (optional)';

  @override
  String get toolInspect => 'Inspect tools';

  @override
  String get pythonNotReadyInspect =>
      'Python is not ready. Select an interpreter and try again.';

  @override
  String get toolInfoFailed => 'Could not get tool info.';

  @override
  String toolsCount(String name, int count) {
    return '$name tools ($count)';
  }

  @override
  String get baseModuleLabel => 'collabo_base (base)';

  @override
  String get extractPending => 'Extracting…';

  @override
  String get viewTools => 'View tools';

  @override
  String get pythonEnv => 'Python environment';

  @override
  String get statusCheck => 'Check status';

  @override
  String get pythonSettings => 'Python settings';

  @override
  String get pythonNotSetTitle => 'Python not set';

  @override
  String get pythonNotSetBody =>
      'Select an interpreter in \"Python settings\" first.';

  @override
  String get pythonCheckTitle => 'Python environment check';

  @override
  String get selectPythonPrompt => 'Select the Python interpreter to use.';

  @override
  String get notSelected => 'Not selected';

  @override
  String get selectPython => 'Select Python';

  @override
  String get pythonVerified => 'Verified';

  @override
  String get pythonMissing => 'No interpreter at that path.';

  @override
  String get pythonMissingQuestion => 'No Python? ';

  @override
  String get downloadFromPythonOrg => 'Download from python.org';

  @override
  String get allFiles => 'All files';

  @override
  String get console => 'Console';

  @override
  String get consoleStarting => 'Starting…';

  @override
  String get consoleInputHint => 'Type and press Enter (e.g. y / n)';

  @override
  String get consoleEnded => 'Process has ended';

  @override
  String consoleProcessExited(int code) {
    return '[process exited: $code]';
  }

  @override
  String consoleExecFailed(String error) {
    return 'Execution failed: $error';
  }

  @override
  String get webviewUnsupported =>
      'The WebView backend for this platform is not connected yet.';

  @override
  String webviewInitFailed(String error) {
    return 'WebView initialization failed\n$error';
  }

  @override
  String get webviewRuntimeMissing =>
      'Microsoft Edge WebView2 Runtime is required to display this view.\nInstall it and restart the app.';

  @override
  String get webviewRuntimeDownload => 'Download WebView2 Runtime';

  @override
  String get noOpenProject => 'No project open';

  @override
  String get wizardTitle => 'Initial setup';

  @override
  String get wizardIntro =>
      'Let\'s get Collabo IDE ready. You can change any of this later in Settings.';

  @override
  String wizardStep(int current, int total) {
    return 'Step $current / $total';
  }

  @override
  String get next => 'Next';

  @override
  String get back => 'Back';

  @override
  String get finish => 'Finish';

  @override
  String get skipSetup => 'Skip';
}
