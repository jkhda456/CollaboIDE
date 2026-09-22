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
  String get tabViewers => 'Viewers';

  @override
  String get tabWeb => 'Web';

  @override
  String get tabPrompt => 'Prompt';

  @override
  String get tabAppearance => 'Appearance';

  @override
  String get tabAbout => 'About';

  @override
  String aboutVersion(String version, String build) {
    return 'Version $version (build $build)';
  }

  @override
  String get openSourceTitle => 'Open source';

  @override
  String get openSourceIntro =>
      'Built with these open-source components. See the full licenses below.';

  @override
  String get viewLicenses => 'View all open-source licenses';

  @override
  String get systemPromptDesc =>
      'System prompt sent at the start of every conversation (execution strategy). Leave empty to use the default.';

  @override
  String get usePreAssessment => 'Use pre-assessment';

  @override
  String get usePreAssessmentDesc =>
      'Before replying, a sub-agent reviews your latest request and adds a one-line note on whether it should be delegated.';

  @override
  String get useProjectState => 'Send project state';

  @override
  String get useProjectStateDesc =>
      'Give the agent a short summary of the folder structure and the files tools have changed, so it does not redo work that is already done (length-limited).';

  @override
  String get usePlanMemory => 'Use plan memory';

  @override
  String get usePlanMemoryDesc =>
      'Keep the goal and plan in the project\'s .collabo/PLAYBOOK.md and send it with every turn, so the plan survives when the conversation is summarised or trimmed. Opens three tools to the agent: goal, plan and notes.';

  @override
  String get useSupervisor => 'Use supervisor';

  @override
  String get useSupervisorDesc =>
      'Detect going in circles (the same tool or the same error repeated, rounds with no progress) and step in with stronger nudges, ending by asking you. Also sends the agent back if it tries to finish with plan steps still open.';

  @override
  String get planCard => 'Plan';

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
  String get navWebSearch => 'Web Search';

  @override
  String get conversation => 'Conversation';

  @override
  String get closeProject => 'Close project';

  @override
  String get recentProjectsTitle => 'Recent projects';

  @override
  String get projectBusy => 'Working';

  @override
  String get closeBusyProjectTitle => 'This project is still working';

  @override
  String closeBusyProjectBody(String name) {
    return '$name has a generation in progress. Closing it stops that work. Other open projects are not affected.';
  }

  @override
  String get browserBack => 'Back';

  @override
  String get browserForward => 'Forward';

  @override
  String get browserReload => 'Reload';

  @override
  String get browserStop => 'Stop loading';

  @override
  String get browserNewTab => 'New tab';

  @override
  String get browserCloseTab => 'Close tab';

  @override
  String get browserCloseAll => 'Close all tabs';

  @override
  String get browserCloseAgentTabs => 'Close the agent\'s tabs';

  @override
  String get browserAddressHint => 'Search, or enter an address';

  @override
  String get browserEmpty => 'No browser tab is open';

  @override
  String get browserUnsupported =>
      'The web browser is not available on this platform yet.';

  @override
  String get searchEngine => 'Search engine';

  @override
  String get searchEngineDesc =>
      'Used by the agent\'s web_search tool and by the address bar above the browser. Engines are defined in the Python module collabo_web.py, so more can be added there.';

  @override
  String get browserUserAgent => 'Browser User-Agent';

  @override
  String get browserUserAgentDesc =>
      'Leave empty to use the platform default, which is what an ordinary browser sends and works best with sites that block automation. Applies to tabs opened from now on.';

  @override
  String get browserUserAgentHint => 'Platform default';

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
  String get activityTitleNative => 'Tool calls';

  @override
  String get activityEmptyNative => 'No tool calls yet.';

  @override
  String get activitySelectHint =>
      'Select a call to see its arguments and full result.';

  @override
  String get activityArgs => 'Arguments';

  @override
  String get activityResult => 'Result';

  @override
  String get activityClear => 'Clear';

  @override
  String get activityScopeMain => 'main';

  @override
  String get activityScopeSub => 'sub-agent';

  @override
  String get activityScopeVerify => 'verify';

  @override
  String get activityScopeDelegate => 'delegate';

  @override
  String get copy => 'Copy';

  @override
  String get procTitle => 'Processes';

  @override
  String get procEmpty => 'No background processes.';

  @override
  String get procSelectHint => 'Select a process to view its output.';

  @override
  String get procStatusRunning => 'Running';

  @override
  String procStatusExited(int code) {
    return 'Exited ($code)';
  }

  @override
  String get procStatusKilled => 'Stopped';

  @override
  String get procStop => 'Stop';

  @override
  String get procInputHint => 'Send input to stdin…';

  @override
  String get procSend => 'Send';

  @override
  String get procStdout => 'stdout';

  @override
  String get procStderr => 'stderr';

  @override
  String get procTerminal => 'Terminal';

  @override
  String get procTerminalInputHint => 'Type into the terminal…';

  @override
  String get procNoPty =>
      'No pseudo-terminal is available, so interactive programs will not work in this session.';

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
  String get presetLabel => 'Preset';

  @override
  String get presetNameLabel => 'Preset name';

  @override
  String get addPreset => 'Add preset';

  @override
  String get deletePreset => 'Delete preset';

  @override
  String get newPresetName => 'New preset';

  @override
  String get defaultBadge => 'default';

  @override
  String get setAsDefault => 'Set as default';

  @override
  String get isDefaultPreset => 'Default preset';

  @override
  String get renamePreset => 'Rename preset';

  @override
  String get selectPreset => 'Select preset';

  @override
  String get connectionMethod => 'Connection';

  @override
  String get openaiCompatible => 'OpenAI-compatible API';

  @override
  String get openaiPrompted => 'OpenAI-compatible (forced prompt)';

  @override
  String get modelLabel => 'Model';

  @override
  String get multimodalSupport => 'Multimodal support';

  @override
  String get multimodalSupportDesc =>
      'Enable to attach images to messages with the + button. Use only with a vision-capable model.';

  @override
  String get parseTextToolCalls => 'Parse tool calls from text';

  @override
  String get parseTextToolCallsDesc =>
      'For non-standard servers that leak tool calls as body text (e.g. some MLX/local backends) instead of the tool_calls field. Off by default; standard OpenAI-compatible servers don\'t need it.';

  @override
  String get reasoningEffort => 'Attach reasoning effort option';

  @override
  String get reasoningEffortDesc =>
      '\"Don\'t attach\" omits reasoning_effort from the request; none/low/high are sent as-is (none disables reasoning). Use only with models/servers that support it, e.g. llama.cpp.';

  @override
  String get reasoningEffortOff => 'Don\'t attach';

  @override
  String get firstResponseTimeout => 'First response (prefill) timeout';

  @override
  String get firstResponseTimeoutDesc =>
      'Applies only until the first response arrives. Defaults to 0 (no limit), because during prefill the server sends nothing, so a clock cannot tell \'working hard\' from \'dead connection\'. You can still stop at any time.';

  @override
  String get secondsUnit => 'sec';

  @override
  String get tokensUnit => 'tokens';

  @override
  String get noLimit => 'no limit';

  @override
  String get responseTokenBudget => 'Token budget per response';

  @override
  String get responseTokenBudgetDesc =>
      'Sets the time limit as \'long enough to produce this many tokens\'. The real limit is budget ÷ speed, so a slower model automatically gets more time. A model stuck repeating itself burns the budget regardless of speed, so it always gets caught. 0 means no limit.';

  @override
  String get tokPerSec => 'Processing speed (tok/s)';

  @override
  String get tokPerSecDesc =>
      'Leave empty and the app measures it from real responses. A value here wins over the measurement. Current limit for this connection';

  @override
  String get tokPerSecAuto =>
      'Empty = measure automatically (assumes 100 tok/s until then)';

  @override
  String tokPerSecMeasured(String tps) {
    return 'Measured: $tps tok/s';
  }

  @override
  String get testConnection => 'Test connection';

  @override
  String get showKey => 'Show key';

  @override
  String get hideKey => 'Hide key';

  @override
  String get useDefaultModel => 'Use default model';

  @override
  String get toolSubagentLabel => 'Sub-agent (run_subagent)';

  @override
  String get toolVerifyLabel => 'Verify (verify_work)';

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
  String get extractPending => 'Extracting…';

  @override
  String get viewTools => 'View tools';

  @override
  String get toolToggleDesc =>
      'Unchecked tools are never passed to the agent. The entry stays, so you can turn it back on any time.';

  @override
  String get toolListLoading => 'Reading the tool list…';

  @override
  String get toolNativeFixed => 'Run by the app · always on';

  @override
  String get viewersDesc =>
      'Extend the file viewer (bottom right) with a JS file. Added viewers show up in the viewer\'s mode dropdown right away.';

  @override
  String get viewerRulesTitle => 'File type assignment';

  @override
  String get viewerRulesDesc =>
      'Choose which extensions each viewer handles. A viewer with extensions is used automatically for those files only; leaving the field empty makes it a fallback for files no viewer claims. Unchecking turns the viewer off entirely (built-in ones too). When several viewers claim the same extension the one higher in this list wins — drag the handle to reorder.';

  @override
  String get viewerOrderReset => 'Reset order';

  @override
  String get viewerReorderTooltip => 'Drag to reorder';

  @override
  String get viewerUserFilesTitle => 'User viewer files';

  @override
  String get viewerExampleDesc =>
      'An example viewer bundled with the app. Adding it registers it as a user viewer; copy it to start your own.';

  @override
  String get viewerBuiltinBadge => 'built-in';

  @override
  String get viewerUserBadge => 'user';

  @override
  String get viewersWaiting => 'Loading the viewer list…';

  @override
  String get viewersNeedProject =>
      'Open a project once and the viewer list will appear here.';

  @override
  String get addViewer => 'Add viewer';

  @override
  String get addViewerFile => 'A single JS file';

  @override
  String get addViewerFileDesc => 'A .js file containing one viewer';

  @override
  String get addViewerFolder => 'A folder (viewer.json)';

  @override
  String get addViewerFolderDesc =>
      'A viewer made of several files or WASM. The folder must contain viewer.json';

  @override
  String get viewersEmpty =>
      'No viewers added. Only the built-in ones are used.';

  @override
  String get viewSource => 'View source';

  @override
  String get viewerFileMissing => 'File not found';

  @override
  String get viewerReadFailed => 'Could not read the file.';

  @override
  String get toolRuntime => 'Tool runtime';

  @override
  String get toolRuntimeSandbox => 'Sandbox';

  @override
  String get toolRuntimeSystem => 'System Python';

  @override
  String get toolRuntimeSandboxDesc =>
      'Tools run in an isolated Linux (WebAssembly) machine that sees only the project folder. Programs on this computer (git, node…) are not available there.';

  @override
  String get toolRuntimeSystemDesc =>
      'Tools run directly on this computer with the Python selected below, and can use every program and file it can reach.';

  @override
  String get sandboxUnavailable =>
      'This app has no sandbox runtime for this platform. Tools cannot run until you switch to System Python.';

  @override
  String get sandboxIdle => 'Starts when a tool first runs';

  @override
  String get sandboxStarting => 'Starting the sandbox…';

  @override
  String get sandboxRunning => 'Sandbox running';

  @override
  String sandboxFailed(String error) {
    return 'Sandbox error: $error';
  }

  @override
  String get navSandboxes => 'Sandboxes';

  @override
  String navSandboxesRunning(int count) {
    return '$count running';
  }

  @override
  String get sandboxNoProjects =>
      'No project is open. Each open project gets its own sandbox here.';

  @override
  String get sandboxSystemMode =>
      'Tools are set to run with System Python. You can switch to the sandbox in Settings → Tools.';

  @override
  String get sandboxStart => 'Start';

  @override
  String get sandboxRestart => 'Restart';

  @override
  String get sandboxStop => 'Stop';

  @override
  String get sandboxStopTitle => 'Stop the sandbox';

  @override
  String get sandboxStopBody =>
      'Stopping the sandbox ends every command and terminal running in it. Files in the project folder stay as they are.';

  @override
  String get sandboxConsole => 'Console';

  @override
  String get sandboxNetwork => 'Network';

  @override
  String get sandboxConsoleHint => 'Command for the root shell';

  @override
  String get sandboxNotRunning =>
      'The sandbox is off. Start it to use its root shell.';

  @override
  String get sandboxNetworkEmpty => 'No network access yet.';

  @override
  String get sandboxMountRo => 'read-only';

  @override
  String sandboxUptime(String since) {
    return 'Running since $since';
  }

  @override
  String get newFile => 'New file';

  @override
  String get newFolder => 'New folder';

  @override
  String get rename => 'Rename';

  @override
  String get delete => 'Delete';

  @override
  String get deleteWarn =>
      'This cannot be undone (it does not go to the trash).';

  @override
  String get deleteFolderWarn =>
      'The folder and everything in it will be removed. This cannot be undone.';

  @override
  String get copyPath => 'Copy full path';

  @override
  String get openWith => 'Open with default app';

  @override
  String get openInExplorer => 'Open in file explorer';

  @override
  String get openPlaybook => 'Open the plan file (.collabo/PLAYBOOK.md)';

  @override
  String get fileSearchPlaceholder => 'Search file names…';

  @override
  String get fileSearchTitle => 'Search file names';

  @override
  String get contentSearchTitle => 'Search file content';

  @override
  String get contentSearchPlaceholder => 'Search file content…';

  @override
  String get fileNone => 'No file selected';

  @override
  String get copySelection => 'Copy selection';

  @override
  String get fullscreenTitle => 'Fullscreen';

  @override
  String get fullscreenExitTitle => 'Exit fullscreen';

  @override
  String get folderEmpty => '(empty folder)';

  @override
  String get noResults => 'No results';

  @override
  String get treeLoading => 'Loading…';

  @override
  String get viewerModeTitle => 'View as';

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
  String get usePerProjectVenv => 'Use per-project virtual environment (venv)';

  @override
  String get usePerProjectVenvDesc =>
      'Creates a dedicated venv under the project\'s .collabo/venv from the selected interpreter, and runs pip/tools inside it. Recommended on macOS/Linux, where installing into the system Python is often blocked (PEP 668) or needs root.';

  @override
  String get venvNoProject =>
      'A dedicated venv is created automatically when you open a project.';

  @override
  String get venvCreating => 'Creating virtual environment…';

  @override
  String get venvReady => 'Virtual environment ready.';

  @override
  String get venvNotCreated => 'Not created yet.';

  @override
  String get venvFailed => 'Failed to create the virtual environment.';

  @override
  String get venvCreate => 'Create';

  @override
  String get venvRecreate => 'Recreate';

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
