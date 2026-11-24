import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AuraOsAssistantApp());
}

// ============================================================================
// DOMAIN MODELS: CONFIG, INTENTS, TOOL CALLS, SAFETY GATES & AUDIT LOGS
// ============================================================================

enum AssistantVoiceState {
  idleWakeWordListening, // Listening passively for "Hey Aura"
  userSpeaking,          // Wake word triggered, capturing voice command
  aiReasoning,           // Parsing intents & building multi-step tool plan
  awaitingConfirmation,  // Paused at Safety Gate for sensitive action
  executingOsBridge,     // Running Android Accessibility / Intent steps
  assistantSpeaking,     // Warm conversational response + barge-in ready
}

enum RiskLevel { low, medium, high }

class AssistantBlueprintConfig {
  String assistantName;
  String wakeWord;
  String personaTone;
  String targetOsBridge;
  String languageMode;
  List<String> enabledApps;
  String privacyInferenceMode;
  String safetyPolicy;
  bool continuousWakeWord;

  AssistantBlueprintConfig({
    this.assistantName = 'Aura',
    this.wakeWord = 'Hey Aura',
    this.personaTone = 'Warm, Friendly & Proactive Companion',
    this.targetOsBridge = 'Android AccessibilityService + Intents',
    this.languageMode = 'English + Natural Multilingual Switch',
    List<String>? enabledApps,
    this.privacyInferenceMode = 'Hybrid (Offline Wake-Word + Cloud LLM)',
    this.safetyPolicy = 'Confirm Messages, Calls & File Deletions',
    this.continuousWakeWord = true,
  }) : enabledApps = enabledApps ??
            [
              'WhatsApp',
              'Phone & Contacts',
              'System Settings & Alarms',
              'Files & Storage',
              'Calendar & Reminders',
            ];
}

class OsToolStep {
  final String appName;
  final String packageName;
  final String toolName;
  final String executionLayer; // e.g., "Android Intent", "AccessibilityService UI Node", "System API"
  final Map<String, String> arguments;
  final RiskLevel riskLevel;
  final List<String> lowLevelTrace;

  const OsToolStep({
    required this.appName,
    required this.packageName,
    required this.toolName,
    required this.executionLayer,
    required this.arguments,
    required this.riskLevel,
    required this.lowLevelTrace,
  });
}

class PendingActionPlan {
  final String id;
  final String userUtterance;
  final String warmConfirmationPrompt;
  final String warmSuccessResponse;
  final List<OsToolStep> steps;
  final RiskLevel overallRisk;
  final DateTime createdAt;

  const PendingActionPlan({
    required this.id,
    required this.userUtterance,
    required this.warmConfirmationPrompt,
    required this.warmSuccessResponse,
    required this.steps,
    required this.overallRisk,
    required this.createdAt,
  });
}

class ChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final PendingActionPlan? attachedPlan;
  final String? statusBadge;

  const ChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.attachedPlan,
    this.statusBadge,
  });
}

class ActionAuditEntry {
  final String id;
  final DateTime timestamp;
  final String summary;
  final String targetApp;
  final String bridgeMethod;
  final RiskLevel riskLevel;
  final String outcome; // "Executed", "Cancelled by User", "Auto-Executed (Safe)"

  const ActionAuditEntry({
    required this.id,
    required this.timestamp,
    required this.summary,
    required this.targetApp,
    required this.bridgeMethod,
    required this.riskLevel,
    required this.outcome,
  });
}

// ============================================================================
// MAIN APPLICATION WIDGET
// ============================================================================

class AuraOsAssistantApp extends StatelessWidget {
  const AuraOsAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aura OS AI Assistant',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
          primary: const Color(0xFF9E7BFF),
          secondary: const Color(0xFF00E5FF),
          tertiary: const Color(0xFFFF8A65),
          surface: const Color(0xFF0F111A),
        ),
        scaffoldBackgroundColor: const Color(0xFF090B10),
        cardTheme: CardThemeData(
          color: const Color(0xFF151926),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
      home: const AssistantWorkspaceScreen(),
    );
  }
}

// ============================================================================
// MAIN WORKSPACE WITH 4 ARCHITECTURAL & INTERACTIVE TABS
// ============================================================================

class AssistantWorkspaceScreen extends StatefulWidget {
  const AssistantWorkspaceScreen({super.key});

  @override
  State<AssistantWorkspaceScreen> createState() =>
      _AssistantWorkspaceScreenState();
}

class _AssistantWorkspaceScreenState extends State<AssistantWorkspaceScreen>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _osBridgeChannel =
      MethodChannel('com.aura.assistant/os_bridge');

  int _selectedTabIndex = 0;
  final AssistantBlueprintConfig _config = AssistantBlueprintConfig();
  AssistantVoiceState _voiceState = AssistantVoiceState.idleWakeWordListening;

  late final AnimationController _orbController;
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  PendingActionPlan? _activeConfirmationPlan;
  int _activeExecutionStepIndex = -1;
  String _liveExecutionTraceLine = '';
  Timer? _stateTimer;

  final List<ChatMessage> _messages = [];
  final List<ActionAuditEntry> _auditLogs = [];

  @override
  void initState() {
    super.initState();
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);

    _seedInitialGreeting();
  }

  void _seedInitialGreeting() {
    _messages.add(
      ChatMessage(
        id: 'welcome_1',
        isUser: false,
        text:
            "Hey there! I'm ${_config.assistantName}, your personal OS companion. "
            "Say \"${_config.wakeWord}\" or tap a voice scenario below. I can orchestrate deep tasks across WhatsApp, system settings, calls, and files—and I'll always confirm sensitive actions with you before acting.",
        timestamp: DateTime.now(),
        statusBadge: 'Wake-Word Active • "${_config.wakeWord}"',
      ),
    );
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _orbController.dispose();
    _inputController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent + 180,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  // --------------------------------------------------------------------------
  // VOICE & WAKE-WORD BARGE-IN SIMULATION
  // --------------------------------------------------------------------------

  void _triggerWakeWordOrBargeIn() {
    HapticFeedback.mediumImpact();
    _stateTimer?.cancel();

    // If assistant is currently speaking or waiting, allow immediate barge-in
    if (_voiceState == AssistantVoiceState.assistantSpeaking ||
        _voiceState == AssistantVoiceState.idleWakeWordListening) {
      setState(() {
        _voiceState = AssistantVoiceState.userSpeaking;
      });
    } else if (_voiceState == AssistantVoiceState.userSpeaking) {
      setState(() {
        _voiceState = AssistantVoiceState.idleWakeWordListening;
      });
    }
  }

  // --------------------------------------------------------------------------
  // AI BRAIN: MULTI-STEP INTENT PARSER & TOOL-CALL PLANNER
  // --------------------------------------------------------------------------

  void _handleUserCommand(String rawInput) {
    final trimmed = rawInput.trim();
    if (trimmed.isEmpty) return;
    _inputController.clear();
    _stateTimer?.cancel();

    // Strip wake word if user included it
    final cleanCommand = trimmed
        .replaceAll(
            RegExp('^${RegExp.escape(_config.wakeWord)}[,\\s]*',
                caseSensitive: false),
            '')
        .trim();

    setState(() {
      _messages.add(
        ChatMessage(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          isUser: true,
          text: trimmed,
          timestamp: DateTime.now(),
        ),
      );
      _voiceState = AssistantVoiceState.aiReasoning;
    });
    _scrollToBottom();

    // Simulate LLM Intent Parsing & Tool Planning latency
    _stateTimer = Timer(const Duration(milliseconds: 850), () {
      final plan = _buildMultiStepActionPlan(
          cleanCommand.isEmpty ? trimmed : cleanCommand);
      _processGeneratedPlan(plan);
    });
  }

  PendingActionPlan _buildMultiStepActionPlan(String utterance) {
    final lower = utterance.toLowerCase();
    final List<OsToolStep> steps = [];
    RiskLevel highestRisk = RiskLevel.low;

    // 1. Check for WhatsApp / Messaging intents
    if (lower.contains('whatsapp') ||
        lower.contains('message') ||
        lower.contains('text ')) {
      String recipient = 'Rahul';
      String messageBody = 'Please come to my house immediately!';

      // Extract custom friend name if provided: e.g. "message my friend Alex on whatsapp to..."
      final friendMatch = RegExp(
        r'(?:message|text)\s+(?:my\s+friend\s+)?([a-zA-Z]+)',
        caseSensitive: false,
      ).firstMatch(utterance);
      if (friendMatch != null && friendMatch.group(1) != null) {
        final candidate = friendMatch.group(1)!;
        if (!['on', 'to', 'in', 'my'].contains(candidate.toLowerCase())) {
          recipient =
              candidate[0].toUpperCase() + candidate.substring(1).toLowerCase();
        }
      }

      // Extract message payload after "to " or "saying " or "that "
      final bodyMatch = RegExp(
        r'(?:whatsapp|friend\s+[a-zA-Z]+)\s+(?:to|saying|that)\s+(.+)$',
        caseSensitive: false,
      ).firstMatch(utterance);
      if (bodyMatch != null && bodyMatch.group(1) != null) {
        final rawBody = bodyMatch.group(1)!.trim();
        messageBody =
            'Hey $recipient, ${rawBody[0].toLowerCase()}${rawBody.substring(1)}';
      }

      highestRisk = RiskLevel.high;
      steps.addAll([
        OsToolStep(
          appName: 'Contacts Resolver',
          packageName: 'com.android.providers.contacts',
          toolName: 'contacts.resolve_alias',
          executionLayer: 'Android ContactsContract Provider',
          arguments: {
            'query_name': recipient,
            'resolved_e164': '+91 98765 43210',
            'whatsapp_jid': '919876543210@s.whatsapp.net',
          },
          riskLevel: RiskLevel.low,
          lowLevelTrace: [
            'Querying ContactsContract.CommonDataKinds.Phone for "$recipient"...',
            'Matched contact "$recipient" (+91 98765 43210) with high confidence (0.99).',
          ],
        ),
        OsToolStep(
          appName: 'WhatsApp',
          packageName: 'com.whatsapp',
          toolName: 'whatsapp.send_direct_message',
          executionLayer: 'Android Intent + AccessibilityService UI Node',
          arguments: {
            'recipient': recipient,
            'phone': '+91 98765 43210',
            'draft_message': messageBody,
          },
          riskLevel: RiskLevel.high,
          lowLevelTrace: [
            'Dispatching Intent(ACTION_VIEW, "https://wa.me/919876543210")...',
            'AccessibilityService waiting for window: com.whatsapp/.Conversation',
            'Locating AccessibilityNodeInfo [viewId="com.whatsapp:id/entry"]...',
            'Injecting ACTION_SET_TEXT: "$messageBody"',
            'Performing ACTION_CLICK on node [viewId="com.whatsapp:id/send"]!',
          ],
        ),
      ]);
    }

    // 2. Check for Device Settings / DND / Wi-Fi / Alarm / Flashlight
    if (lower.contains('do not disturb') ||
        lower.contains('dnd') ||
        lower.contains('silent') ||
        lower.contains('alarm') ||
        lower.contains('brightness') ||
        lower.contains('wifi')) {
      steps.add(
        OsToolStep(
          appName: 'Android System Settings',
          packageName: 'com.android.settings',
          toolName: 'os.configure_device_state',
          executionLayer: 'Android NotificationManager & AlarmClock Intent',
          arguments: {
            'interruption_filter':
                lower.contains('alarm') ? 'ALARMS_ONLY' : 'PRIORITY_DND',
            'schedule_alarm': lower.contains('alarm') ? '07:00 AM' : 'unchanged',
          },
          riskLevel: RiskLevel.low,
          lowLevelTrace: [
            'Calling NotificationManager.setInterruptionFilter(INTERRUPTION_FILTER_PRIORITY)...',
            if (lower.contains('alarm'))
              'Dispatching AlarmClock.ACTION_SET_ALARM (EXTRA_HOUR=7, EXTRA_MINUTES=0, EXTRA_SKIP_UI=true)...',
            'System state verified via BroadcastReceiver.',
          ],
        ),
      );
    }

    // 3. Check for File Deletion / Cleanup
    if (lower.contains('delete') ||
        lower.contains('clean') ||
        lower.contains('downloads') ||
        lower.contains('files')) {
      highestRisk = RiskLevel.high;
      steps.add(
        OsToolStep(
          appName: 'File Manager',
          packageName: 'com.android.documentsui',
          toolName: 'storage.purge_files',
          executionLayer: 'Android MediaStore / Scoped Storage API',
          arguments: {
            'directory': '/storage/emulated/0/Download/temp_archives',
            'matched_files': '14 duplicate APK & cache files (412 MB)',
            'permanent_delete': 'true',
          },
          riskLevel: RiskLevel.high,
          lowLevelTrace: [
            'Scanning /storage/emulated/0/Download for stale temp archives...',
            'Found 14 files totaling 412 MB older than 30 days.',
            'Executing ContentResolver.delete() across 14 MediaStore URIs...',
          ],
        ),
      );
    }

    // 4. Check for Phone Call
    if (lower.contains('call ')) {
      highestRisk = RiskLevel.high;
      final String callee = lower.contains('mom') ? 'Mom' : 'Alex';
      steps.add(
        OsToolStep(
          appName: 'Phone Dialer',
          packageName: 'com.google.android.dialer',
          toolName: 'telecom.place_call',
          executionLayer: 'Android TelecomManager + Speakerphone Toggle',
          arguments: {
            'contact': callee,
            'number': '+91 98201 11223',
            'speakerphone': lower.contains('speaker') ? 'true' : 'false',
          },
          riskLevel: RiskLevel.high,
          lowLevelTrace: [
            'Resolving contact "$callee" -> +91 98201 11223',
            'Starting Intent(Intent.ACTION_CALL, Uri.parse("tel:+919820111223"))...',
            'AudioManager.setSpeakerphoneOn(true) applied.',
          ],
        ),
      );
    }

    // Fallback intelligent multi-app assistant task if no specific keyword matched
    if (steps.isEmpty) {
      final bool isSensitive =
          lower.contains('send') || lower.contains('pay') || lower.contains('remove');
      highestRisk = isSensitive ? RiskLevel.high : RiskLevel.low;
      steps.add(
        OsToolStep(
          appName: 'OS Orchestrator',
          packageName: 'com.aura.assistant.core',
          toolName: 'assistant.execute_contextual_workflow',
          executionLayer: _config.targetOsBridge,
          arguments: {
            'intent_summary': utterance,
            'persona_mode': _config.personaTone,
          },
          riskLevel: highestRisk,
          lowLevelTrace: [
            'Parsing semantic intent & checking active foreground app context...',
            'Executing workflow via ${_config.targetOsBridge}...',
            'Task completed with zero errors.',
          ],
        ),
      );
    }

    // Construct warm persona confirmation & completion strings
    String confirmPrompt;
    String successReply;

    final whatsappStep =
        steps.where((s) => s.packageName == 'com.whatsapp').firstOrNull;
    if (whatsappStep != null) {
      final recipient = whatsappStep.arguments['recipient'] ?? 'your friend';
      final draft = whatsappStep.arguments['draft_message'] ?? '';
      final extraNote = steps.length > 2
          ? ' and also configure your device settings'
          : '';
      confirmPrompt =
          "I've prepared your WhatsApp message to **$recipient**:\n\n"
          "\"$draft\"$extraNote.\n\n"
          "Since sending a live message is a sensitive action, please confirm—should I send it right now?";
      successReply =
          "All done! I opened WhatsApp via the OS bridge, typed your message to $recipient, and hit Send. Anything else you need?";
    } else if (highestRisk == RiskLevel.high) {
      final primaryStep = steps.first;
      confirmPrompt =
          "I'm ready to run **${primaryStep.toolName}** inside **${primaryStep.appName}** "
          "(${primaryStep.arguments.entries.map((e) => '${e.key}: ${e.value}').join(', ')}).\n\n"
          "Would you like me to go ahead and execute this now?";
      successReply =
          "Done! I've safely executed that action in ${primaryStep.appName} and logged it in your audit trail.";
    } else {
      confirmPrompt =
          "Executing safe OS adjustment (${steps.map((s) => s.toolName).join(' -> ')})...";
      successReply =
          "Taken care of! I updated your system settings right away since it's a safe, non-destructive action.";
    }

    return PendingActionPlan(
      id: 'plan_${DateTime.now().millisecondsSinceEpoch}',
      userUtterance: utterance,
      warmConfirmationPrompt: confirmPrompt,
      warmSuccessResponse: successReply,
      steps: steps,
      overallRisk: highestRisk,
      createdAt: DateTime.now(),
    );
  }

  void _processGeneratedPlan(PendingActionPlan plan) {
    final bool needsConfirmation = plan.overallRisk == RiskLevel.high ||
        _config.safetyPolicy == 'Always Confirm Every Action';

    if (needsConfirmation &&
        _config.safetyPolicy != 'Autonomous (Log Only, No Prompts)') {
      HapticFeedback.lightImpact();
      setState(() {
        _activeConfirmationPlan = plan;
        _voiceState = AssistantVoiceState.awaitingConfirmation;
        _messages.add(
          ChatMessage(
            id: 'confirm_${plan.id}',
            isUser: false,
            text: plan.warmConfirmationPrompt,
            timestamp: DateTime.now(),
            attachedPlan: plan,
            statusBadge: 'SAFETY GATE • CONFIRMATION REQUIRED',
          ),
        );
      });
      _scrollToBottom();
    } else {
      // Safe action: execute directly through the OS bridge
      _executeActionPlan(plan, autoApproved: true);
    }
  }

  // --------------------------------------------------------------------------
  // ACTION & OS BRIDGE EXECUTION ENGINE
  // --------------------------------------------------------------------------

  Future<void> _executeActionPlan(
    PendingActionPlan plan, {
    bool autoApproved = false,
  }) async {
    HapticFeedback.mediumImpact();
    setState(() {
      _activeConfirmationPlan = null;
      _voiceState = AssistantVoiceState.executingOsBridge;
      _activeExecutionStepIndex = 0;
    });

    // Step through each low-level trace line to show real-time OS bridge telemetry
    for (int i = 0; i < plan.steps.length; i++) {
      final step = plan.steps[i];
      setState(() {
        _activeExecutionStepIndex = i;
      });

      // Attempt optional native MethodChannel call if Kotlin handler is registered
      try {
        await _osBridgeChannel.invokeMethod('executeToolStep', {
          'packageName': step.packageName,
          'toolName': step.toolName,
          'arguments': step.arguments,
        });
      } on MissingPluginException {
        // Expected in pure Flutter mode without custom Kotlin AccessibilityService attached
      } catch (_) {}

      for (final traceLine in step.lowLevelTrace) {
        if (!mounted) return;
        setState(() {
          _liveExecutionTraceLine = '[${step.appName}] $traceLine';
        });
        await Future.delayed(const Duration(milliseconds: 520));
      }

      _auditLogs.insert(
        0,
        ActionAuditEntry(
          id: 'audit_${DateTime.now().microsecondsSinceEpoch}',
          timestamp: DateTime.now(),
          summary:
              '${step.toolName} (${step.arguments.values.take(2).join(" • ")})',
          targetApp: step.appName,
          bridgeMethod: step.executionLayer,
          riskLevel: step.riskLevel,
          outcome: autoApproved
              ? 'Auto-Executed (Low Risk)'
              : 'Confirmed & Executed',
        ),
      );
    }

    if (!mounted) return;
    setState(() {
      _activeExecutionStepIndex = -1;
      _liveExecutionTraceLine = '';
      _voiceState = AssistantVoiceState.assistantSpeaking;
      _messages.add(
        ChatMessage(
          id: 'done_${plan.id}',
          isUser: false,
          text: plan.warmSuccessResponse,
          timestamp: DateTime.now(),
          statusBadge: 'OS BRIDGE EXECUTED • ${plan.steps.length} STEP(S)',
        ),
      );
    });
    _scrollToBottom();

    // Return to continuous wake-word listening after assistant finishes speaking
    _stateTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_voiceState == AssistantVoiceState.assistantSpeaking) {
        setState(() {
          _voiceState = AssistantVoiceState.idleWakeWordListening;
        });
      }
    });
  }

  void _cancelPendingPlan(PendingActionPlan plan) {
    HapticFeedback.selectionClick();
    for (final step in plan.steps) {
      _auditLogs.insert(
        0,
        ActionAuditEntry(
          id: 'audit_cancel_${DateTime.now().microsecondsSinceEpoch}',
          timestamp: DateTime.now(),
          summary: '${step.toolName} aborted at Safety Gate',
          targetApp: step.appName,
          bridgeMethod: step.executionLayer,
          riskLevel: step.riskLevel,
          outcome: 'Cancelled by User',
        ),
      );
    }

    setState(() {
      _activeConfirmationPlan = null;
      _voiceState = AssistantVoiceState.idleWakeWordListening;
      _messages.add(
        ChatMessage(
          id: 'cancel_${plan.id}',
          isUser: false,
          text:
              "Got it—I cancelled that action and didn't touch ${plan.steps.map((s) => s.appName).toSet().join(' or ')}. Just let me know if you want to change the details!",
          timestamp: DateTime.now(),
          statusBadge: 'ACTION ABORTED SAFELY',
        ),
      );
    });
    _scrollToBottom();
  }

  // --------------------------------------------------------------------------
  // UI BUILDERS
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E111A),
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    colorScheme.primary,
                    colorScheme.secondary,
                  ],
                ),
              ),
              child: const Icon(Icons.graphic_eq_rounded,
                  color: Colors.black, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${_config.assistantName} OS Assistant',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.greenAccent.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          '"${_config.wakeWord}"',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.greenAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _config.targetOsBridge,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Architect Discovery Setup',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => setState(() => _selectedTabIndex = 1),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedTabIndex,
        children: [
          _buildVoiceAssistantTab(),
          _buildArchitectDiscoveryTab(),
          _buildSystemArchitectureTab(),
          _buildRoadmapAndAuditTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTabIndex,
        backgroundColor: const Color(0xFF0E111A),
        indicatorColor: colorScheme.primary.withValues(alpha: 0.22),
        onDestinationSelected: (index) {
          setState(() => _selectedTabIndex = index);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.mic_none_rounded),
            selectedIcon: Icon(Icons.mic_rounded),
            label: 'Voice OS',
          ),
          const NavigationDestination(
            icon: Icon(Icons.quiz_outlined),
            selectedIcon: Icon(Icons.quiz_rounded),
            label: '7 Questions',
          ),
          const NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            selectedIcon: Icon(Icons.account_tree_rounded),
            label: '4-Layer Arch',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _auditLogs.isNotEmpty,
              label: Text('${_auditLogs.length}'),
              child: const Icon(Icons.verified_user_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: _auditLogs.isNotEmpty,
              label: Text('${_auditLogs.length}'),
              child: const Icon(Icons.verified_user_rounded),
            ),
            label: 'Roadmap & Log',
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // TAB 1: LIVE VOICE ASSISTANT, MULTI-STEP TOOL PLANNER & SAFETY GATE
  // ==========================================================================

  Widget _buildVoiceAssistantTab() {
    return Column(
      children: [
        // Top Interactive Voice Orb & Wake-Word Status Banner
        _buildVoiceOrbHeader(),

        // Quick Voice Command Scenario Chips
        _buildScenarioChipsBar(),

        // Live OS Bridge Telemetry Ticker (Visible when executing steps)
        if (_voiceState == AssistantVoiceState.executingOsBridge &&
            _liveExecutionTraceLine.isNotEmpty)
          _buildLiveExecutionBanner(),

        // Conversation & Inline Safety Confirmation Gate Cards
        Expanded(
          child: ListView.builder(
            controller: _chatScrollController,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            itemCount: _messages.length,
            itemBuilder: (context, index) {
              return _buildChatMessageBubble(_messages[index]);
            },
          ),
        ),

        // Sticky Safety Gate Action Bar if a High-Risk Action is awaiting approval
        if (_activeConfirmationPlan != null)
          _buildStickySafetyConfirmationBar(_activeConfirmationPlan!),

        // Bottom Voice / Natural Input Bar
        _buildBottomVoiceInputBar(),
      ],
    );
  }

  Widget _buildVoiceOrbHeader() {
    final (String stateTitle, String stateSubtitle, Color stateColor) =
        switch (_voiceState) {
      AssistantVoiceState.idleWakeWordListening => (
          'Listening for "${_config.wakeWord}"...',
          'Tap the orb to speak or barge-in anytime',
          const Color(0xFF9E7BFF),
        ),
      AssistantVoiceState.userSpeaking => (
          'Listening to you...',
          'Speak naturally — multi-app instructions supported',
          const Color(0xFF00E5FF),
        ),
      AssistantVoiceState.aiReasoning => (
          '${_config.assistantName} is planning tool calls...',
          'Decomposing intents & checking safety permissions',
          const Color(0xFFFFB74D),
        ),
      AssistantVoiceState.awaitingConfirmation => (
          'Safety Gate: Waiting for your confirmation',
          'Say "Yes, send it" or tap Confirm below',
          const Color(0xFFFF6E40),
        ),
      AssistantVoiceState.executingOsBridge => (
          'Executing via Android OS Bridge...',
          'Driving AccessibilityService & system intents',
          const Color(0xFF00E676),
        ),
      AssistantVoiceState.assistantSpeaking => (
          '${_config.assistantName} is speaking...',
          'Tap orb to barge-in and interrupt immediately',
          const Color(0xFF7C4DFF),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF121622),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: _triggerWakeWordOrBargeIn,
            child: AnimatedBuilder(
              animation: _orbController,
              builder: (context, _) {
                final pulse = 0.88 + (_orbController.value * 0.24);
                return Container(
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: stateColor.withValues(alpha: 0.35 * pulse),
                        blurRadius: 22 * pulse,
                        spreadRadius: 2 * pulse,
                      ),
                    ],
                    gradient: RadialGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.9),
                        stateColor,
                        stateColor.withValues(alpha: 0.35),
                      ],
                    ),
                  ),
                  child: Icon(
                    _voiceState == AssistantVoiceState.userSpeaking
                        ? Icons.graphic_eq_rounded
                        : _voiceState ==
                                AssistantVoiceState.awaitingConfirmation
                            ? Icons.shield_rounded
                            : Icons.mic_rounded,
                    color: Colors.black87,
                    size: 26,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stateTitle,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: stateColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  stateSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: _config.continuousWakeWord,
            activeColor: stateColor,
            onChanged: (val) {
              setState(() => _config.continuousWakeWord = val);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildScenarioChipsBar() {
    final scenarios = [
      (
        'WhatsApp Urgent Message',
        '${_config.wakeWord}, message my friend Rahul on WhatsApp to come to my house immediately',
        Icons.chat_bubble_outline_rounded,
      ),
      (
        'Multi-App: WhatsApp + DND',
        'Message Priya on WhatsApp that I am in a focus session and turn on Do Not Disturb',
        Icons.auto_awesome_rounded,
      ),
      (
        'Safe OS: DND + 7 AM Alarm',
        'Turn on Do Not Disturb and set my morning alarm for 7 AM',
        Icons.alarm_rounded,
      ),
      (
        'High-Risk: Clean Downloads',
        'Delete old temporary archive files from my Downloads folder',
        Icons.cleaning_services,
      ),
      (
        'Call Mom on Speaker',
        'Call Mom on speakerphone right now',
        Icons.phone_in_talk_rounded,
      ),
    ];

    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        itemCount: scenarios.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = scenarios[index];
          return ActionChip(
            avatar: Icon(item.$3, size: 15, color: const Color(0xFF00E5FF)),
            label: Text(
              item.$1,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            backgroundColor: const Color(0xFF181D2C),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
            onPressed: () => _handleUserCommand(item.$2),
          );
        },
      ),
    );
  }

  Widget _buildLiveExecutionBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B241A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF00E676).withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: Color(0xFF00E676),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _liveExecutionTraceLine,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: Color(0xFF69F0AE),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatMessageBubble(ChatMessage msg) {
    final isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (msg.statusBadge != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 4, right: 4),
              child: Text(
                msg.statusBadge!,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: msg.statusBadge!.contains('SAFETY')
                      ? const Color(0xFFFF8A65)
                      : const Color(0xFF00E5FF),
                ),
              ),
            ),
          Container(
            constraints: const BoxConstraints(maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            decoration: BoxDecoration(
              color: isUser
                  ? const Color(0xFF5E35B1)
                  : const Color(0xFF171C2B),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isUser ? 18 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 18),
              ),
              border: Border.all(
                color: isUser
                    ? Colors.white.withValues(alpha: 0.14)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.text,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.42,
                    color: Colors.white,
                  ),
                ),
                if (msg.attachedPlan != null) ...[
                  const SizedBox(height: 12),
                  _buildInlineToolPlanInspector(msg.attachedPlan!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineToolPlanInspector(PendingActionPlan plan) {
    final isPending = _activeConfirmationPlan?.id == plan.id;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F131E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPending
              ? const Color(0xFFFF8A65).withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.09),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal_rounded,
                  size: 15, color: Color(0xFF00E5FF)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'OS Bridge Tool Plan (${plan.steps.length} step${plan.steps.length > 1 ? 's' : ''})',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF00E5FF),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: plan.overallRisk == RiskLevel.high
                      ? Colors.deepOrange.withValues(alpha: 0.22)
                      : Colors.green.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  plan.overallRisk == RiskLevel.high
                      ? 'HIGH RISK'
                      : 'SAFE',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: plan.overallRisk == RiskLevel.high
                        ? const Color(0xFFFF8A65)
                        : Colors.greenAccent,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 14, color: Colors.white12),
          for (int i = 0; i < plan.steps.length; i++) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}. ${plan.steps[i].toolName}  •  ${plan.steps[i].appName}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Layer: ${plan.steps[i].executionLayer}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...plan.steps[i].arguments.entries.map(
                    (entry) => Text(
                      '   • ${entry.key}: ${entry.value}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFFB39DDB),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (isPending) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00C853),
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => _executeActionPlan(plan),
                    icon: const Icon(Icons.check_circle_rounded, size: 17),
                    label: const Text(
                      'Confirm & Execute',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _cancelPendingPlan(plan),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStickySafetyConfirmationBar(PendingActionPlan plan) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF231417),
        border: Border(
          top: BorderSide(
              color: const Color(0xFFFF8A65).withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.gpp_maybe_rounded,
              color: Color(0xFFFF8A65), size: 22),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Safety Gate Active: Say "Confirm" or tap to approve execution.',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFFFFCCBC),
              ),
            ),
          ),
          TextButton(
            onPressed: () => _cancelPendingPlan(plan),
            child: const Text('Abort'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFF7043),
              foregroundColor: Colors.black,
            ),
            onPressed: () => _executeActionPlan(plan),
            child: const Text(
              'Approve',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomVoiceInputBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0E111A),
          border: Border(
            top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
        child: Row(
          children: [
            IconButton.filledTonal(
              tooltip: 'Trigger Wake-Word "${_config.wakeWord}"',
              onPressed: _triggerWakeWordOrBargeIn,
              icon: Icon(
                _voiceState == AssistantVoiceState.userSpeaking
                    ? Icons.mic_rounded
                    : Icons.mic_none_rounded,
                color: _voiceState == AssistantVoiceState.userSpeaking
                    ? const Color(0xFF00E5FF)
                    : Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _inputController,
                onSubmitted: (val) {
                  if (_activeConfirmationPlan != null &&
                      (val.toLowerCase().contains('yes') ||
                          val.toLowerCase().contains('confirm') ||
                          val.toLowerCase().contains('send'))) {
                    _inputController.clear();
                    _executeActionPlan(_activeConfirmationPlan!);
                  } else {
                    _handleUserCommand(val);
                  }
                },
                decoration: InputDecoration(
                  hintText:
                      'Say "${_config.wakeWord}, message Rahul on WhatsApp..."',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF171C2B),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: () => _handleUserCommand(_inputController.text),
              icon: const Icon(Icons.arrow_upward_rounded),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // TAB 2: SENIOR AI SYSTEMS ARCHITECT — 7 CLARIFYING QUESTIONS WIZARD
  // ==========================================================================

  Widget _buildArchitectDiscoveryTab() {
    final allApps = [
      'WhatsApp',
      'Phone & Contacts',
      'System Settings & Alarms',
      'Files & Storage',
      'Calendar & Reminders',
      'Gmail & Email',
      'Spotify & Media',
      'Google Maps & Rides',
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionBanner(
          icon: Icons.architecture_rounded,
          title: 'Senior AI Systems Architect: Discovery & Setup',
          subtitle:
              'Configure your answers to the 7 core architectural questions below. Changes immediately update your live assistant in Tab 1.',
        ),
        const SizedBox(height: 14),

        // Q1: Target OS & Execution Bridge
        _buildQuestionCard(
          number: 'Q1',
          question: 'What is your target OS & automation bridge architecture?',
          explanation:
              'Determines how tool calls are dispatched (Android AccessibilityService UI automation vs. Shizuku/ADB vs. Desktop UIAutomation).',
          child: DropdownButtonFormField<String>(
            value: _config.targetOsBridge,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'Android AccessibilityService + Intents',
                child: Text('Android AccessibilityService + Intents (Recommended)'),
              ),
              DropdownMenuItem(
                value: 'Android Power-User (Accessibility + Shizuku / ADB)',
                child: Text('Android Power-User (Accessibility + Shizuku / ADB)'),
              ),
              DropdownMenuItem(
                value: 'Cross-Platform (Android + Windows/macOS Desktop Agent)',
                child: Text('Cross-Platform (Android + Windows/macOS Desktop Agent)'),
              ),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _config.targetOsBridge = val);
            },
          ),
        ),

        // Q2: Assistant Name & Wake-Word
        _buildQuestionCard(
          number: 'Q2',
          question: 'What is your preferred Assistant Name & Wake-Word?',
          explanation:
              'Used by the on-device wake-word spotter (Porcupine / Sherpa-ONNX) to start continuous full-duplex conversation.',
          child: Wrap(
            spacing: 8,
            children: [
              ('Aura', 'Hey Aura'),
              ('Nova', 'Hey Nova'),
              ('Jarvis', 'Hey Jarvis'),
              ('Atlas', 'Hey Atlas'),
            ].map((pair) {
              final selected = _config.assistantName == pair.$1;
              return ChoiceChip(
                label: Text('${pair.$1} ("${pair.$2}")'),
                selected: selected,
                onSelected: (_) {
                  setState(() {
                    _config.assistantName = pair.$1;
                    _config.wakeWord = pair.$2;
                  });
                },
              );
            }).toList(),
          ),
        ),

        // Q3: Voice Persona & Conversational Tone
        _buildQuestionCard(
          number: 'Q3',
          question: 'What voice persona and tone should your companion use?',
          explanation:
              'Shapes the system prompt, proactive suggestions, and TTS prosody.',
          child: DropdownButtonFormField<String>(
            value: _config.personaTone,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'Warm, Friendly & Proactive Companion',
                child: Text('Warm, Friendly & Proactive Companion'),
              ),
              DropdownMenuItem(
                value: 'Crisp, Fast & Executive Chief-of-Staff',
                child: Text('Crisp, Fast & Executive Chief-of-Staff'),
              ),
              DropdownMenuItem(
                value: 'Playful, Witty & Conversational Friend',
                child: Text('Playful, Witty & Conversational Friend'),
              ),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _config.personaTone = val);
            },
          ),
        ),

        // Q4: Languages & Code-Switching
        _buildQuestionCard(
          number: 'Q4',
          question: 'Which languages and natural code-switching do you need?',
          explanation:
              'Configures multilingual STT transcription and contact name phonetic matching.',
          child: DropdownButtonFormField<String>(
            value: _config.languageMode,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'English + Natural Multilingual Switch',
                child: Text('English + Natural Multilingual / Hinglish Switch'),
              ),
              DropdownMenuItem(
                value: 'English Only (Ultra-Low Latency)',
                child: Text('English Only (Ultra-Low Latency)'),
              ),
              DropdownMenuItem(
                value: 'Multilingual Auto-Detect (ES / HI / FR / EN)',
                child: Text('Multilingual Auto-Detect (ES / HI / FR / EN)'),
              ),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _config.languageMode = val);
            },
          ),
        ),

        // Q5: Top Daily Apps to Control
        _buildQuestionCard(
          number: 'Q5',
          question: 'Which top daily apps should the OS Bridge control?',
          explanation:
              'Enables app-specific Accessibility node selectors and deep-link Intent schemas.',
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: allApps.map((app) {
              final isSelected = _config.enabledApps.contains(app);
              return FilterChip(
                label: Text(app, style: const TextStyle(fontSize: 12)),
                selected: isSelected,
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _config.enabledApps.add(app);
                    } else if (_config.enabledApps.length > 1) {
                      _config.enabledApps.remove(app);
                    }
                  });
                },
              );
            }).toList(),
          ),
        ),

        // Q6: Privacy & Offline vs. Cloud LLM Preferences
        _buildQuestionCard(
          number: 'Q6',
          question: 'What is your privacy & offline vs. cloud inference preference?',
          explanation:
              'Balances 100% on-device privacy against complex multi-step reasoning capability.',
          child: DropdownButtonFormField<String>(
            value: _config.privacyInferenceMode,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'Hybrid (Offline Wake-Word + Cloud LLM)',
                child: Text('Hybrid (Offline Wake-Word + Gemini 2.5 Flash Cloud)'),
              ),
              DropdownMenuItem(
                value: '100% On-Device Local (Sherpa STT + Quantized Gemma)',
                child: Text('100% On-Device Local (Sherpa STT + Quantized Gemma)'),
              ),
              DropdownMenuItem(
                value: 'Cloud Audio Duplex with Strict Local PII Redaction',
                child: Text('Cloud Audio Duplex with Strict Local PII Redaction'),
              ),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() => _config.privacyInferenceMode = val);
              }
            },
          ),
        ),

        // Q7: Safety & Confirmation Gate Strictness
        _buildQuestionCard(
          number: 'Q7',
          question: 'How strict should the Safety & Confirmation Gate be?',
          explanation:
              'Controls when the assistant pauses and asks for explicit voice/tap approval.',
          child: DropdownButtonFormField<String>(
            value: _config.safetyPolicy,
            isExpanded: true,
            items: const [
              DropdownMenuItem(
                value: 'Confirm Messages, Calls & File Deletions',
                child: Text('Confirm Messages, Calls & File Deletions (Balanced)'),
              ),
              DropdownMenuItem(
                value: 'Always Confirm Every Action',
                child: Text('Strict: Always Confirm Every Action'),
              ),
              DropdownMenuItem(
                value: 'Autonomous (Log Only, No Prompts)',
                child: Text('Autonomous: Execute Immediately & Log to Audit Trail'),
              ),
            ],
            onChanged: (val) {
              if (val != null) setState(() => _config.safetyPolicy = val);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildQuestionCard({
    required String number,
    required String question,
    required String explanation,
    required Widget child,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF9E7BFF).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    number,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF9E7BFF),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    question,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              explanation,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.62),
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  // ==========================================================================
  // TAB 3: 4-LAYER SYSTEM ARCHITECTURE & OS BRIDGE MATRIX
  // ==========================================================================

  Widget _buildSystemArchitectureTab() {
    final layers = [
      (
        'Layer 1: Voice & Wake-Word Layer',
        Icons.record_voice_over_rounded,
        const Color(0xFF00E5FF),
        [
          'Wake-Word Engine: Always-on low-power DSP/ONNX spotter (Porcupine or Sherpa-ONNX) running in an Android ForegroundService.',
          'VAD & Full-Duplex Barge-In: Silero VAD detects user speech within 40ms and immediately ducks/cancels active TTS playback.',
          'Streaming STT & Natural TTS: Low-latency streaming speech recognition paired with expressive neural voice synthesis.',
        ],
      ),
      (
        'Layer 2: AI Brain & Persona Layer',
        Icons.psychology_rounded,
        const Color(0xFF9E7BFF),
        [
          'Warm Companion Persona: System prompt tuned for natural, empathetic, concise voice responses rather than robotic CLI output.',
          'Entity & Episodic Memory: Resolves personal aliases ("Mom", "Rahul", "my house") using local SQLite + ContactsContract.',
          'Multi-Step Tool Planner: Decomposes compound utterances ("Message Rahul on WhatsApp and turn on DND") into an ordered DAG of JSON tool calls.',
        ],
      ),
      (
        'Layer 3: Action & OS Bridge Layer',
        Icons.integration_instructions_rounded,
        const Color(0xFF00E676),
        [
          'Web / AI Studio Prototype: Simulates intent graphs and triggers standard URI deep links (https://wa.me/phone?text=...).',
          'Native Android AccessibilityService: Inspects the live AccessibilityNodeInfo tree of 3rd-party apps (e.g., WhatsApp com.whatsapp:id/entry & com.whatsapp:id/send) to type and click Send autonomously.',
          'Privileged OS Bridge (Shizuku / Termux / ADB): Executes deep system toggles, file management, and background package tasks.',
        ],
      ),
      (
        'Layer 4: Safety & Permissions Layer',
        Icons.verified_user_rounded,
        const Color(0xFFFF8A65),
        [
          'Deterministic Risk Classifier: Tags every tool step as LOW (alarms/volume), MEDIUM (settings), or HIGH (sending messages, calls, deleting files).',
          'Conversational Confirmation Gate: Reads back exact recipient and message payload naturally before executing HIGH-risk steps.',
          'Immutable Audit Log & Kill-Switch: Records every OS bridge action with instant voice/tap abort capability.',
        ],
      ),
    ];

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionBanner(
          icon: Icons.account_tree_rounded,
          title: 'Modular 4-Layer System Architecture',
          subtitle:
              'Clean separation between Voice I/O, LLM Reasoning, Native OS Execution, and Deterministic Safety Gates.',
        ),
        const SizedBox(height: 14),
        for (final layer in layers)
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(layer.$2, color: layer.$3, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          layer.$1,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: layer.$3,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final point in layer.$4)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 7),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('• ',
                              style: TextStyle(
                                  color: layer.$3,
                                  fontWeight: FontWeight.bold)),
                          Expanded(
                            child: Text(
                              point,
                              style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'How WhatsApp Automation Works Across Environments',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF00E5FF),
                  ),
                ),
                const SizedBox(height: 10),
                _buildBridgeComparisonRow(
                  env: '1. Web / Sandbox Prototype',
                  capability:
                      'Parses intent, runs confirmation gate, and opens wa.me deep link pre-filled with text (user taps Send manually).',
                ),
                _buildBridgeComparisonRow(
                  env: '2. Native Android AccessibilityService',
                  capability:
                      'Opens WhatsApp chat via Intent, locates UI node "com.whatsapp:id/send", and clicks it automatically after user confirms.',
                ),
                _buildBridgeComparisonRow(
                  env: '3. Termux / ADB / Desktop Companion',
                  capability:
                      'Executes UIAutomator / input tap shell commands or bridges across desktop apps via local MCP server.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBridgeComparisonRow({
    required String env,
    required String capability,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            env,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            capability,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: 0.68),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // TAB 4: PHASED ROADMAP, FOLDER STRUCTURE & LIVE SAFETY AUDIT LOG
  // ==========================================================================

  Widget _buildRoadmapAndAuditTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionBanner(
          icon: Icons.map_rounded,
          title: 'Phased Implementation Roadmap & Audit Log',
          subtitle:
              'From interactive prototype (Phase 1) to native Android Accessibility bridge (Phase 2) and continuous memory (Phase 3).',
        ),
        const SizedBox(height: 14),
        _buildPhaseCard(
          phase: 'Phase 1: Interactive AI Studio & Flutter Prototype (Active)',
          status: 'COMPLETED IN THIS APP',
          color: const Color(0xFF00E676),
          deliverables: const [
            'Wake-word & voice state machine with barge-in interrupt support.',
            'Natural multi-step intent parser & JSON tool-call inspector.',
            'Conversational Safety Confirmation Gate for WhatsApp, Calls & File Deletions.',
          ],
        ),
        _buildPhaseCard(
          phase: 'Phase 2: Real Android Device Bridge (Accessibility + Intents)',
          status: 'NEXT MILESTONE',
          color: const Color(0xFF00E5FF),
          deliverables: const [
            'Bind Flutter MethodChannel ("com.aura.assistant/os_bridge") to Kotlin AuraAccessibilityService.',
            'Query ContactsContract for fuzzy contact name resolution.',
            'Automate UI node traversal inside WhatsApp, Settings, and Phone dialer.',
          ],
        ),
        _buildPhaseCard(
          phase: 'Phase 3: Deep Automation, Wake-Word Service & Episodic Memory',
          status: 'PRODUCTION',
          color: const Color(0xFF9E7BFF),
          deliverables: const [
            'Always-on Android ForegroundService running offline Porcupine / Sherpa-ONNX wake-word model.',
            'Persistent on-device vector & SQLite memory for personal routines and relationships.',
            'Cross-app workflow chaining with rollback/undo snapshots.',
          ],
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Live Safety & OS Action Audit Log',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            if (_auditLogs.isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(() => _auditLogs.clear()),
                icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                label: const Text('Clear'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_auditLogs.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'No OS actions executed yet. Try a voice scenario in the "Voice OS" tab to inspect real-time confirmation & execution logs here.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
          )
        else
          ..._auditLogs.map(
            (entry) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                dense: true,
                leading: Icon(
                  entry.outcome.contains('Cancelled')
                      ? Icons.cancel_outlined
                      : Icons.verified_rounded,
                  color: entry.outcome.contains('Cancelled')
                      ? Colors.orangeAccent
                      : const Color(0xFF00E676),
                ),
                title: Text(
                  entry.summary,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${entry.targetApp} • ${entry.bridgeMethod}\n${entry.outcome}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.65),
                  ),
                ),
                isThreeLine: true,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPhaseCard({
    required String phase,
    required String status,
    required Color color,
    required List<String> deliverables,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    phase,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final item in deliverables)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $item',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.78),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionBanner({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF7C4DFF).withValues(alpha: 0.25),
            const Color(0xFF00E5FF).withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: const Color(0xFF00E5FF), size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
