import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shared_preferences/shared_preferences.dart';

// Powiadomienia
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    final lightBg = const Color(0xFFF4F1FF); // lekki fiolet
    final seed = Colors.indigo;
    return MaterialApp(
      title: 'Mój owoc',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        scaffoldBackgroundColor: lightBg,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class Session {
  final DateTime start;
  final DateTime end;
  Session({required this.start, required this.end});
  int get minutes => end.difference(start).inMinutes;

  Map<String, dynamic> toJson() =>
      {'s': start.toIso8601String(), 'e': end.toIso8601String()};
  factory Session.fromJson(Map<String, dynamic> j) =>
      Session(start: DateTime.parse(j['s']), end: DateTime.parse(j['e']));
}

class Store {
  static const _kSessions = 'sessions_v1';
  static const _kCurrentStart = 'current_start_v1';
  static const _kGoalHours = 'goal_hours_v1';
  static const _kReminderScheduled = 'reminder_scheduled_v1';
  static const _kReminderHHMM = 'reminder_hhmm_v1'; // np. "20:00"

  Future<List<Session>> loadSessions() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kSessions);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return list.map((m) => Session.fromJson(m)).toList();
  }

  Future<void> saveSessions(List<Session> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kSessions,
      jsonEncode(items.map((e) => e.toJson()).toList()),
    );
  }

  Future<DateTime?> loadCurrentStart() async {
    final p = await SharedPreferences.getInstance();
    final iso = p.getString(_kCurrentStart);
    if (iso == null) return null;
    try {
      return DateTime.parse(iso);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCurrentStart(DateTime? dt) async {
    final p = await SharedPreferences.getInstance();
    if (dt == null) {
      await p.remove(_kCurrentStart);
    } else {
      await p.setString(_kCurrentStart, dt.toIso8601String());
    }
  }

  Future<int> loadGoalHours() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kGoalHours) ?? 30;
  }

  Future<void> saveGoalHours(int hours) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kGoalHours, hours);
  }

  Future<bool> getReminderFlag() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kReminderScheduled) ?? false;
  }

  Future<void> setReminderFlag(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kReminderScheduled, v);
  }

  Future<String> loadReminderHHMM() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kReminderHHMM) ?? '20:00';
  }

  Future<void> saveReminderHHMM(String hhmm) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kReminderHHMM, hhmm);
  }
}

// ---------- Powiadomienia ----------
class Notify {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');

    // Wymagania nowszej wtyczki na Windows: appName, AUMID i GUID
    const windowsInit = WindowsInitializationSettings(
      appName: 'Mój owoc',
      appUserModelId: 'pl.wowo.moj_owoc',
      guid: 'b7b5d2c3-3a4e-4f6c-8d2a-8c9a1f3e6a01',
    );

    const iOSInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iOSInit,
      windows: windowsInit,
    );
    await _plugin.initialize(initSettings);
  }

  static Future<void> cancelAll() => _plugin.cancelAll();

  static Future<void> scheduleDailyFromTomorrow({
    required int hour,
    required int minute,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'moj_owoc_reminder',
      'Przypomnienia',
      channelDescription: 'Codzienne przypomnienie o służbie',
      importance: Importance.max,
      priority: Priority.high,
    );
    const notifDetails = NotificationDetails(android: androidDetails);

    final now = tz.TZDateTime.now(tz.local);
    final todayAt = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    final first = todayAt.add(const Duration(days: 1)); // od jutra

    await _plugin.zonedSchedule(
      2000,
      'Mój owoc',
      'Przypomnienie o służbie (cel miesięczny czeka 🙂)',
      first,
      notifDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'reminder',
    );
  }
}

// ---------- UI ----------
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final store = Store();

  List<Session> _sessions = [];
  DateTime? _currentStart;
  Timer? _ticker;
  int _goalHours = 30;
  String _reminderHHMM = '20:00';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await Notify.init();

    final s = await store.loadSessions();
    final start = await store.loadCurrentStart();
    final goal = await store.loadGoalHours();
    final hhmm = await store.loadReminderHHMM();

    setState(() {
      _sessions = s;
      _currentStart = start;
      _goalHours = goal;
      _reminderHHMM = hhmm;
    });

    if (_currentStart != null) {
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    }

    if (!await store.getReminderFlag()) {
      final parts = _reminderHHMM.split(':');
      await Notify.scheduleDailyFromTomorrow(
        hour: int.parse(parts[0]),
        minute: int.parse(parts[1]),
      );
      await store.setReminderFlag(true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ustawiono przypomnienie $_reminderHHMM (od jutra).')),
        );
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _start() async {
    final now = DateTime.now();
    setState(() => _currentStart = now);
    await store.saveCurrentStart(now);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  Future<void> _stop() async {
    if (_currentStart == null) return;
    final end = DateTime.now();
    final mins = end.difference(_currentStart!).inMinutes;
    final start = _currentStart!;
    setState(() => _currentStart = null);
    await store.saveCurrentStart(null);
    if (mins <= 0) return;
    final updated = [..._sessions, Session(start: start, end: end)];
    setState(() => _sessions = updated);
    await store.saveSessions(updated);
    _ticker?.cancel();
    _ticker = null;
  }

  int _minutesThisMonth({DateTime? forMonth}) {
    final ref = forMonth ?? DateTime.now();
    final mStart = DateTime(ref.year, ref.month, 1);
    final mEnd = (ref.month == 12)
        ? DateTime(ref.year + 1, 1, 1)
        : DateTime(ref.year, ref.month + 1, 1);
    int sum = 0;
    for (final s in _sessions) {
      final st = s.start.isBefore(mStart) ? mStart : s.start;
      final en = s.end.isAfter(mEnd) ? mEnd : s.end;
      if (en.isAfter(st)) sum += en.difference(st).inMinutes;
    }
    if (_currentStart != null && forMonth == null) {
      final st = _currentStart!.isBefore(mStart) ? mStart : _currentStart!;
      final en = DateTime.now().isAfter(mEnd) ? mEnd : DateTime.now();
      if (en.isAfter(st)) sum += en.difference(st).inMinutes;
    }
    return sum;
  }

  int _daysRemainingFromTomorrow() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    final nextMonth = (now.month == 12)
        ? DateTime(now.year + 1, 1, 1)
        : DateTime(now.year, now.month + 1, 1);
    final d = nextMonth.difference(tomorrow).inDays;
    return d < 0 ? 0 : d;
  }

  int get _goalMinutes => _goalHours * 60;
  int get _remainingMinutes {
    final r = _goalMinutes - _minutesThisMonth();
    return r > 0 ? r : 0;
  }
  int get _dailyNeeded {
    final rem = _remainingMinutes;
    if (rem == 0) return 0;
    final days = _daysRemainingFromTomorrow();
    if (days <= 0) return rem;
    return (rem / days).ceil();
  }

  String _fmtHM(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  String _fmtHMS(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _exportCsvAll() {
    final buf = StringBuffer()..writeln('start,end,duration_min');
    for (final s in _sessions) {
      buf.writeln('${s.start.toIso8601String()},${s.end.toIso8601String()},${s.minutes}');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Eksport CSV skopiowany do schowka.')),
    );
  }

  Future<void> _manualAdd() async {
    final res = await showDialog<_ManualAddResult>(
      context: context,
      builder: (_) => const _ManualAddDialog(),
    );
    if (res == null) return;

    final now = DateTime.now();
    final isToday = res.date.year == now.year &&
        res.date.month == now.month &&
        res.date.day == now.day;

    final DateTime end = isToday
        ? now
        : DateTime(res.date.year, res.date.month, res.date.day, 23, 59);

    final start = end.subtract(Duration(minutes: res.durationMinutes));

    final updated = [..._sessions, Session(start: start, end: end)];
    setState(() => _sessions = updated);
    await store.saveSessions(updated);
  }

  String _plMonth(int m) => const [
        'styczeń','luty','marzec','kwiecień','maj','czerwiec',
        'lipiec','sierpień','wrzesień','październik','listopad','grudzień'
      ][m - 1];

  Color _dailyColor(int minutes) {
    if (minutes <= 60) return Colors.green;
    if (minutes <= 90) return Colors.orange;
    return Colors.red;
  }

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HistoryPage(
        sessions: _sessions,
        monthNow: DateTime.now(),
        onChanged: (updated) async {
          setState(() => _sessions = updated);
          await store.saveSessions(updated);
        },
      ),
    ));
  }


  Future<void> _openSettings() async {
    final res = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SettingsPage(initialHHMM: _reminderHHMM),
      ),
    );
    if (res != null && res != _reminderHHMM) {
      // zapisz, przeplanuj od jutra
      await store.saveReminderHHMM(res);
      setState(() => _reminderHHMM = res);

      final parts = res.split(':');
      await Notify.cancelAll();
      await Notify.scheduleDailyFromTomorrow(
        hour: int.parse(parts[0]),
        minute: int.parse(parts[1]),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ustawiono przypomnienie $res (od jutra).')),
        );
      }
      await store.setReminderFlag(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _minutesThisMonth();
    final rem = _remainingMinutes;
    final daily = _dailyNeeded;
    final live = _currentStart == null
        ? Duration.zero
        : DateTime.now().difference(_currentStart!);

    final navy = const Color(0xFF0D47A1);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mój owoc'),
        actions: [
          IconButton(
            tooltip: 'Historia',
            onPressed: _openHistory,
            icon: const Icon(Icons.history),
          ),
          IconButton(
            tooltip: 'Ustawienia',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Pasek z aktualnym miesiącem
              Row(
                children: [
                  const Icon(Icons.calendar_month),
                  const SizedBox(width: 8),
                  Text(
                    '${_plMonth(DateTime.now().month)} ${DateTime.now().year}',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      const Icon(Icons.notifications, size: 18),
                      const SizedBox(width: 6),
                      Text(_reminderHHMM),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // ---- PASEK LICZB: większy kontrast + obramowanie ----
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.light
                      ? const Color(0xFFDED8FF) // ciemniejszy fiolet (większy kontrast)
                      : Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Theme.of(context).brightness == Brightness.light
                        ? const Color(0xFFB9B0FF)
                        : Colors.white24,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.07),
                      blurRadius: 14,
                      offset: const Offset(0, 7),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _Stat(
                      label: 'Suma w miesiącu',
                      value: _fmtHM(total),
                      icon: Icons.schedule,
                      valueColor: navy,
                      bold: true,
                    ),
                    const SizedBox(height: 8),
                    _Stat(
                      label: 'Do końca',
                      value: _fmtHM(rem),
                      icon: Icons.flag,
                      valueColor: navy,
                      bold: true,
                    ),
                    const SizedBox(height: 8),
                    _Stat(
                      label: 'Ile dziennie (od jutra)',
                      value: _fmtHM(daily),
                      icon: Icons.calendar_today,
                      valueColor: _dailyColor(daily),
                      bold: true,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _currentStart == null ? 'Gotowy' : _fmtHMS(live),
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 200,
                        height: 200,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(24),
                            backgroundColor:
                                _currentStart == null ? Colors.green : Colors.red,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: _currentStart == null ? _start : _stop,
                          child: Text(
                            _currentStart == null ? 'Start' : 'Stop',
                            style: const TextStyle(
                                fontSize: 28, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Przyciski
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _exportCsvAll,
                      icon: const Icon(Icons.file_download),
                      label: const Text('Eksport CSV'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _manualAdd,
                      icon: const Icon(Icons.add),
                      label: const Text('Dodaj ręcznie'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final Color? valueColor;
  final bool bold;
  const _Stat({
    required this.label,
    required this.value,
    this.icon,
    this.valueColor,
    this.bold = false,
  });
  @override
  Widget build(BuildContext context) {
    final valueStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
          color: valueColor,
          fontWeight: bold ? FontWeight.w700 : null,
        );
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Row(children: [
        if (icon != null) Icon(icon, size: 20),
        if (icon != null) const SizedBox(width: 8),
        Text(label, style: Theme.of(context).textTheme.titleMedium),
      ]),
      Text(value, style: valueStyle),
    ]);
  }
}

// -------- Historia (dni > 0 + suma + eksport CSV miesiąca) --------
class HistoryPage extends StatefulWidget {
  final List<Session> sessions;
  final DateTime monthNow;
  final ValueChanged<List<Session>> onChanged;
  const HistoryPage({
    super.key,
    required this.sessions,
    required this.monthNow,
    required this.onChanged,
  });

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late DateTime _cursor;
  late List<Session> _sessions; // lokalna kopia do modyfikacji

  @override
  void initState() {
    super.initState();
    _cursor = DateTime(widget.monthNow.year, widget.monthNow.month);
    _sessions = [...widget.sessions];
  }

  String _plMonth(int m) => const [
        'styczeń','luty','marzec','kwiecień','maj','czerwiec',
        'lipiec','sierpień','wrzesień','październik','listopad','grudzień'
      ][m - 1];

  (DateTime start, DateTime end) _monthRange() {
    final start = DateTime(_cursor.year, _cursor.month, 1);
    final end = (_cursor.month == 12)
        ? DateTime(_cursor.year + 1, 1, 1)
        : DateTime(_cursor.year, _cursor.month + 1, 1);
    return (start, end);
  }

  List<_DayRow> _buildDayRows() {
    final (start, end) = _monthRange();
    final map = <DateTime, int>{};

    for (final s in _sessions) {
      var st = s.start.isBefore(start) ? start : s.start;
      var en = s.end.isAfter(end) ? end : s.end;
      if (!en.isAfter(st)) continue;

      DateTime cursor = DateTime(st.year, st.month, st.day);
      while (cursor.isBefore(en)) {
        final dayEnd = DateTime(cursor.year, cursor.month, cursor.day, 23, 59, 59);
        final chunkEnd = en.isBefore(dayEnd) ? en : dayEnd;
        final chunkStart = st.isAfter(cursor) ? st : cursor;
        final mins = chunkEnd.difference(chunkStart).inMinutes;
        if (mins > 0) {
          final key = DateTime(cursor.year, cursor.month, cursor.day);
          map[key] = (map[key] ?? 0) + mins;
        }
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      }
    }

    final rows = <_DayRow>[];
    for (var d = start; d.isBefore(end); d = DateTime(d.year, d.month, d.day + 1)) {
      final mins = map[DateTime(d.year, d.month, d.day)] ?? 0;
      if (mins > 0) {
        rows.add(_DayRow(date: d, minutes: mins)); // tylko > 0
      }
    }
    return rows;
  }

  String _fmtHM(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  Future<void> _openDay(DateTime day) async {
    final updated = await Navigator.of(context).push<List<Session>>(
      MaterialPageRoute(
        builder: (_) => DayDetailPage(
          allSessions: _sessions,
          day: day,
        ),
      ),
    );
    if (updated != null) {
      setState(() => _sessions = updated);
      widget.onChanged(updated); // zapis i powiadomienie Home
    }
  }

  Future<void> _exportMonthCsv() async {
    final (mStart, mEnd) = _monthRange();
    final buf = StringBuffer()..writeln('date,start,end,duration_min');
    for (final s in _sessions) {
      final st = s.start.isBefore(mStart) ? mStart : s.start;
      final en = s.end.isAfter(mEnd) ? mEnd : s.end;
      if (!en.isAfter(st)) continue;
      final day = DateTime(st.year, st.month, st.day);
      final dateStr =
          '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
      buf.writeln('$dateStr,${st.toIso8601String()},${en.toIso8601String()},${en.difference(st).inMinutes}');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSV miesiąca skopiowany do schowka.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _buildDayRows();
    final monthSum = rows.fold<int>(0, (a, b) => a + b.minutes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Historia'),
        actions: [
          IconButton(
            tooltip: 'Eksport CSV (bieżący miesiąc)',
            onPressed: _exportMonthCsv,
            icon: const Icon(Icons.file_download),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Poprzedni miesiąc',
                  onPressed: () => setState(() {
                    _cursor = DateTime(_cursor.year, _cursor.month - 1);
                  }),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_plMonth(_cursor.month)} ${_cursor.year}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Następny miesiąc',
                  onPressed: () => setState(() {
                    _cursor = DateTime(_cursor.year, _cursor.month + 1);
                  }),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text('Suma: ${_fmtHM(monthSum)}',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),

            if (rows.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    'Brak wpisów w tym miesiącu',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final dateStr =
                        '${r.date.year}-${r.date.month.toString().padLeft(2, '0')}-${r.date.day.toString().padLeft(2, '0')}';
                    return ListTile(
                      dense: true,
                      title: Text(dateStr),
                      trailing: Text(
                        _fmtHM(r.minutes),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      onTap: () => _openDay(r.date), // << wejście do edycji dnia
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DayRow {
  final DateTime date;
  final int minutes;
  _DayRow({required this.date, required this.minutes});
}

class DayDetailPage extends StatefulWidget {
  final List<Session> allSessions;
  final DateTime day;
  const DayDetailPage({super.key, required this.allSessions, required this.day});

  @override
  State<DayDetailPage> createState() => _DayDetailPageState();
}

class _DayDetailPageState extends State<DayDetailPage> {
  late List<Session> _sessions;

  DateTime get _dayStart => DateTime(widget.day.year, widget.day.month, widget.day.day);
  DateTime get _dayEnd   => DateTime(widget.day.year, widget.day.month, widget.day.day, 23, 59, 59);

  @override
  void initState() {
    super.initState();
    _sessions = [...widget.allSessions];
  }

  List<int> _indexesForDay() {
    final idx = <int>[];
    for (int i = 0; i < _sessions.length; i++) {
      final s = _sessions[i];
      if (s.end.isBefore(_dayStart) || s.start.isAfter(_dayEnd)) continue;
      idx.add(i);
    }
    return idx;
  }

  String _fmt(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String _fmtDur(int mins) => '${(mins ~/ 60).toString().padLeft(2, '0')}:${(mins % 60).toString().padLeft(2, '0')}';

  Future<void> _edit(int globalIndex) async {
    final s = _sessions[globalIndex];
    final res = await showDialog<_EditSessionResult>(
      context: context,
      builder: (_) => _EditSessionDialog(initial: s, day: widget.day),
    );
    if (res == null) return;

    setState(() {
      _sessions[globalIndex] = Session(start: res.start, end: res.end);
    });
  }

  Future<void> _delete(int globalIndex) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Usunąć wpis?'),
        content: const Text('Tej operacji nie można cofnąć.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Usuń')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _sessions.removeAt(globalIndex);
      });
    }
  }

  int _sumMinutesForDay() {
    int sum = 0;
    for (final i in _indexesForDay()) {
      final s = _sessions[i];
      final st = s.start.isBefore(_dayStart) ? _dayStart : s.start;
      final en = s.end.isAfter(_dayEnd) ? _dayEnd : s.end;
      if (en.isAfter(st)) sum += en.difference(st).inMinutes;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final idxs = _indexesForDay();

    return Scaffold(
      appBar: AppBar(
        title: Text('Dzień: ${widget.day.year}-${widget.day.month.toString().padLeft(2,'0')}-${widget.day.day.toString().padLeft(2,'0')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop<List<Session>>(context, _sessions),
            child: const Text('Zapisz', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Text('Suma dnia: ${_fmtDur(_sumMinutesForDay())}',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            const SizedBox(height: 8),
            if (idxs.isEmpty)
              Expanded(child: Center(child: Text('Brak wpisów w tym dniu')))
            else
              Expanded(
                child: ListView.separated(
                  itemCount: idxs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final gi = idxs[i]; // globalny indeks w całej liście
                    final s = _sessions[gi];
                    final dur = s.minutes;
                    return Dismissible(
                      key: ValueKey('${s.start.toIso8601String()}_${s.end.toIso8601String()}_$i'),
                      background: Container(color: Colors.red, alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left:16), child: const Icon(Icons.delete, color: Colors.white)),
                      secondaryBackground: Container(color: Colors.red, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right:16), child: const Icon(Icons.delete, color: Colors.white)),
                      onDismissed: (_) => _delete(gi),
                      confirmDismiss: (_) async { await _delete(gi); return false; }, // sterujemy ręcznie
                      child: ListTile(
                        title: Text('${_fmt(s.start)} – ${_fmt(s.end)}'),
                        subtitle: Text('Czas: ${_fmtDur(dur)}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.edit),
                          onPressed: () => _edit(gi),
                          tooltip: 'Edytuj',
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EditSessionResult {
  final DateTime start;
  final DateTime end;
  _EditSessionResult(this.start, this.end);
}

class _EditSessionDialog extends StatefulWidget {
  final Session initial;
  final DateTime day;
  const _EditSessionDialog({super.key, required this.initial, required this.day});

  @override
  State<_EditSessionDialog> createState() => _EditSessionDialogState();
}

class _EditSessionDialogState extends State<_EditSessionDialog> {
  late TimeOfDay _start;
  late TimeOfDay _end;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _start = TimeOfDay(hour: widget.initial.start.hour, minute: widget.initial.start.minute);
    _end   = TimeOfDay(hour: widget.initial.end.hour,   minute: widget.initial.end.minute);
  }

  DateTime _combine(DateTime day, TimeOfDay t) =>
      DateTime(day.year, day.month, day.day, t.hour, t.minute);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edytuj wpis'),
      content: Form(
        key: _formKey,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Start'),
            subtitle: Text('${_start.hour.toString().padLeft(2,'0')}:${_start.minute.toString().padLeft(2,'0')}'),
            trailing: const Icon(Icons.access_time),
            onTap: () async {
              final p = await showTimePicker(context: context, initialTime: _start);
              if (p != null) setState(() => _start = p);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Koniec'),
            subtitle: Text('${_end.hour.toString().padLeft(2,'0')}:${_end.minute.toString().padLeft(2,'0')}'),
            trailing: const Icon(Icons.access_time),
            onTap: () async {
              final p = await showTimePicker(context: context, initialTime: _end);
              if (p != null) setState(() => _end = p);
            },
          ),
          const SizedBox(height: 8),
          const Text('Uwaga: edycja dotyczy tylko tego wpisu.'),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anuluj')),
        FilledButton(
          onPressed: () {
            final start = _combine(widget.day, _start);
            final end   = _combine(widget.day, _end);
            if (!end.isAfter(start)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Koniec musi być po starcie.')),
              );
              return;
            }
            Navigator.pop(context, _EditSessionResult(start, end));
          },
          child: const Text('Zapisz'),
        ),
      ],
    );
  }
}

// -------- Ustawienia (godzina przypomnienia) --------
class SettingsPage extends StatefulWidget {
  final String initialHHMM;
  const SettingsPage({super.key, required this.initialHHMM});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TimeOfDay _time;

  @override
  void initState() {
    super.initState();
    final parts = widget.initialHHMM.split(':');
    _time = TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
  }

  @override
  Widget build(BuildContext context) {
    String fmt(TimeOfDay t) =>
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: const Text('Ustawienia')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Przypomnienie', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Godzina przypomnienia'),
              subtitle: Text(fmt(_time)),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _time,
                );
                if (picked != null) setState(() => _time = picked);
              },
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.pop<String>(context, fmt(_time));
                    },
                    child: const Text('Zapisz'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -------- Dialogi --------

class _GoalDialog extends StatefulWidget {
  final int initial;
  const _GoalDialog({required this.initial});
  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late double _value;
  @override
  void initState() {
    super.initState();
    _value = widget.initial.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cel miesięczny (h)'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Slider(
          value: _value,
          min: 10,
          max: 80,
          divisions: 70,
          label: '${_value.round()} h',
          onChanged: (v) => setState(() => _value = v),
        ),
        Text('${_value.round()} h'),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anuluj')),
        FilledButton(
          onPressed: () => Navigator.pop<int>(context, _value.round()),
          child: const Text('Zapisz'),
        ),
      ],
    );
  }
}

class _ManualAddResult {
  final DateTime date;
  final int durationMinutes;
  _ManualAddResult({
    required this.date,
    required this.durationMinutes,
  });
}

class _ManualAddDialog extends StatefulWidget {
  const _ManualAddDialog();
  @override
  State<_ManualAddDialog> createState() => _ManualAddDialogState();
}

class _ManualAddDialogState extends State<_ManualAddDialog> {
  DateTime _date = DateTime.now();
  final _formKey = GlobalKey<FormState>();
  final _durCtrl = TextEditingController(text: '1:00'); // HH:MM

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Dodaj ręcznie'),
      content: Form(
        key: _formKey,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text('Data: ${_fmt(_date)}')),
            TextButton(
              onPressed: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(_date.year - 2),
                  lastDate: DateTime(_date.year + 2),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: const Text('Zmień'),
            ),
          ]),
          const SizedBox(height: 8),
          TextFormField(
            controller: _durCtrl,
            keyboardType: TextInputType.datetime,
            decoration: const InputDecoration(labelText: 'Czas trwania (HH:MM)'),
            validator: (v) {
              final txt = (v ?? '').trim();
              final re = RegExp(r'^\s*(\d{1,3})(?::([0-5]?\d))?\s*$'); // H lub H:MM
              final m = re.firstMatch(txt);
              if (m == null) return 'Podaj czas jako H:MM (np. 1:30)';
              final h = int.parse(m.group(1)!);
              final mm = int.parse(m.group(2) ?? '0');
              if (h == 0 && mm == 0) return 'Czas musi być > 0';
              return null;
            },
          ),
          const SizedBox(height: 6),
          const Text(
            'Jeśli data = dziś → koniec = teraz.\nJeśli inna data → koniec = 23:59.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Anuluj')),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState?.validate() != true) return;
            final re = RegExp(r'^\s*(\d{1,3})(?::([0-5]?\d))?\s*$');
            final m = re.firstMatch(_durCtrl.text.trim())!;
            final h = int.parse(m.group(1)!);
            final mm = int.parse(m.group(2) ?? '0');
            final totalMin = h * 60 + mm;

            final res = _ManualAddResult(
              date: _date,
              durationMinutes: totalMin,
            );
            Navigator.pop(context, res);
          },
          child: const Text('Dodaj'),
        ),
      ],
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
