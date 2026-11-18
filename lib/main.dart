import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const multicastAddress = '239.255.42.99';
const discoveryPort = 45454;
const tcpPort = 45455;
const appTitle = 'LocalLink';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LocalLinkApp());
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.time,
    this.isMine = false,
  });

  final String id;
  final String senderId;
  final String senderName;
  final String text;
  final DateTime time;
  final bool isMine;

  Map<String, dynamic> toJson() => {
        'id': id,
        'senderId': senderId,
        'senderName': senderName,
        'text': text,
        'time': time.toIso8601String(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j, String myId) =>
      ChatMessage(
        id: j['id'] as String,
        senderId: j['senderId'] as String,
        senderName: j['senderName'] as String,
        text: j['text'] as String,
        time: DateTime.parse(j['time'] as String),
        isMine: j['senderId'] == myId,
      );
}

class Peer {
  Peer({required this.id, required this.name, required this.ip, required this.port});
  final String id;
  String name;
  InternetAddress ip;
  int port;
  DateTime lastSeen = DateTime.now();
}

class LocalLinkService extends ChangeNotifier {
  LocalLinkService() {
    final r = Random.secure();
    deviceId = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static const _native = MethodChannel('locallink/network');
  late final String deviceId;
  String displayName = 'Guest';
  bool running = false;
  String? error;
  final Map<String, Peer> peers = {};
  final List<ChatMessage> messages = [];
  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _announceTimer;
  Timer? _cleanupTimer;
  Directory? _dataDir;
  File? _historyFile;
  StreamSubscription<RawSocketEvent>? _udpSub;
  final Set<String> _seenMessages = {};

  Future<void> start(String name) async {
    if (running) return;
    displayName = name.trim().isEmpty ? 'Guest' : name.trim().substring(0, min(24, name.trim().length));
    try {
      if (Platform.isAndroid) {
        await _native.invokeMethod('acquireMulticastLock');
      }
      _dataDir = await getApplicationSupportDirectory();
      await _dataDir!.create(recursive: true);
      _historyFile = File('${_dataDir!.path}${Platform.pathSeparator}messages.jsonl');
      await _loadHistory();

      _server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort, shared: true);
      _server!.listen(_handleIncomingSocket);

      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, discoveryPort,
          reuseAddress: true, reusePort: !Platform.isWindows);
      _udp!.joinMulticast(InternetAddress(multicastAddress));
      _udpSub = _udp!.listen(_handleUdp);

      running = true;
      error = null;
      _announce();
      _announceTimer = Timer.periodic(const Duration(seconds: 3), (_) => _announce());
      _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) => _removeStalePeers());
      notifyListeners();
    } catch (e) {
      error = e.toString();
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _cleanupTimer?.cancel();
    await _udpSub?.cancel();
    _udp?.close();
    await _server?.close();
    _udp = null;
    _server = null;
    running = false;
    peers.clear();
    if (Platform.isAndroid) {
      try { await _native.invokeMethod('releaseMulticastLock'); } catch (_) {}
    }
    notifyListeners();
  }

  void _announce() {
    if (!running || _udp == null) return;
    final packet = jsonEncode({
      'type': 'locallink_discovery',
      'id': deviceId,
      'name': displayName,
      'port': tcpPort,
      'version': 1,
    });
    _udp!.send(utf8.encode(packet), InternetAddress(multicastAddress), discoveryPort);
  }

  void _handleUdp(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _udp == null) return;
    final datagram = _udp!.receive();
    if (datagram == null) return;
    try {
      final j = jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      if (j['type'] != 'locallink_discovery' || j['id'] == deviceId) return;
      final id = j['id'] as String;
      final peer = peers.putIfAbsent(id, () => Peer(
        id: id,
        name: (j['name'] as String?) ?? 'Friend',
        ip: datagram.address,
        port: (j['port'] as num?)?.toInt() ?? tcpPort,
      ));
      peer.name = (j['name'] as String?) ?? peer.name;
      peer.ip = datagram.address;
      peer.port = (j['port'] as num?)?.toInt() ?? tcpPort;
      peer.lastSeen = DateTime.now();
      notifyListeners();
    } catch (_) {}
  }

  void _removeStalePeers() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 15));
    final old = peers.keys.where((k) => peers[k]!.lastSeen.isBefore(cutoff)).toList();
    for (final id in old) peers.remove(id);
    if (old.isNotEmpty) notifyListeners();
  }

  void _handleIncomingSocket(Socket socket) {
    socket.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      _receiveMessage(line);
    }, onError: (_) {}, onDone: () => socket.destroy());
  }

  Future<void> send(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    final msg = ChatMessage(
      id: '$deviceId-${DateTime.now().microsecondsSinceEpoch}',
      senderId: deviceId,
      senderName: displayName,
      text: clean,
      time: DateTime.now(),
      isMine: true,
    );
    await _addMessage(msg);
    final wire = jsonEncode({'type': 'chat', ...msg.toJson()}) + '\n';
    for (final peer in peers.values.toList()) {
      try {
        final socket = await Socket.connect(peer.ip, peer.port,
            timeout: const Duration(seconds: 2));
        socket.write(wire);
        await socket.flush();
        await socket.close();
      } catch (_) {
        // A peer may have left between its last discovery packet and this send.
      }
    }
  }

  Future<void> _receiveMessage(String line) async {
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['type'] != 'chat') return;
      final msg = ChatMessage.fromJson(j, deviceId);
      if (msg.senderId == deviceId || _seenMessages.contains(msg.id)) return;
      _seenMessages.add(msg.id);
      await _addMessage(msg);
    } catch (_) {}
  }

  Future<void> _addMessage(ChatMessage msg) async {
    messages.add(msg);
    messages.sort((a, b) => a.time.compareTo(b.time));
    if (_historyFile != null) {
      await _historyFile!.writeAsString('${jsonEncode(msg.toJson())}\n',
          mode: FileMode.append, flush: true);
    }
    notifyListeners();
  }

  Future<void> _loadHistory() async {
    if (_historyFile == null || !await _historyFile!.exists()) return;
    try {
      final lines = await _historyFile!.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        final msg = ChatMessage.fromJson(
            jsonDecode(line) as Map<String, dynamic>, deviceId);
        messages.add(msg);
        _seenMessages.add(msg.id);
      }
      messages.sort((a, b) => a.time.compareTo(b.time));
    } catch (_) {
      // Keep the app usable if an old/corrupt history file cannot be parsed.
    }
  }

  Future<void> clearHistory() async {
    messages.clear();
    _seenMessages.clear();
    if (_historyFile != null) await _historyFile!.writeAsString('');
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class LocalLinkApp extends StatelessWidget {
  const LocalLinkApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: appTitle,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0B111B),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7894FF), brightness: Brightness.dark),
      useMaterial3: true,
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: const Color(0xFF172235),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    ),
    home: const ChatPage(),
  );
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final service = LocalLinkService();
  final name = TextEditingController(text: 'Vikash');
  final message = TextEditingController();
  bool starting = false;

  @override
  void initState() {
    super.initState();
    service.addListener(_refresh);
  }

  void _refresh() { if (mounted) setState(() {}); }

  Future<void> _toggle() async {
    if (service.running) {
      await service.stop();
      return;
    }
    setState(() => starting = true);
    try {
      await service.start(name.text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start LocalLink: $e')));
    } finally {
      if (mounted) setState(() => starting = false);
    }
  }

  Future<void> _send() async {
    final text = message.text;
    message.clear();
    await service.send(text);
  }

  @override
  void dispose() {
    service.removeListener(_refresh);
    service.dispose();
    name.dispose();
    message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final online = service.running;
    return Scaffold(
      appBar: AppBar(
        title: const Row(children: [
          Icon(Icons.forum_rounded, color: Color(0xFF91A9FF)),
          SizedBox(width: 10),
          Text('LocalLink', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 14),
            child: Chip(
              avatar: Icon(Icons.circle, size: 9, color: online ? const Color(0xFF45D6A0) : Colors.grey),
              label: Text(online ? 'Scanning LAN' : 'Offline'),
            )),
        ],
      ),
      body: SafeArea(child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 10), child: Row(children: [
          Expanded(child: TextField(
            controller: name, enabled: !online,
            decoration: const InputDecoration(labelText: 'Your name', prefixIcon: Icon(Icons.person_outline)),
          )),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: starting ? null : _toggle,
            child: starting ? const SizedBox(width: 18,height:18,child:CircularProgressIndicator(strokeWidth:2))
              : Text(online ? 'Stop' : 'Go online'),
          ),
        ])),
        if (service.error != null)
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(service.error!, style: const TextStyle(color: Colors.redAccent))),
        SizedBox(height: 92, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(18, 5, 18, 8),
            child: Text('NEARBY FRIENDS  ·  ${service.peers.length} ONLINE',
              style: const TextStyle(fontSize: 11, letterSpacing: 1.2, color: Color(0xFF9AAAC0), fontWeight: FontWeight.bold))),
          Expanded(child: service.peers.isEmpty
            ? const Padding(padding: EdgeInsets.symmetric(horizontal: 18), child: Align(alignment: Alignment.centerLeft, child: Text('No friends discovered yet', style: TextStyle(color: Colors.white38))))
            : ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14),
              children: service.peers.values.map((p) => Padding(
                padding: const EdgeInsets.only(right: 9),
                child: Chip(avatar: CircleAvatar(child: Text(p.name.isEmpty ? '?' : p.name[0].toUpperCase())),
                  label: Text(p.name)),
              )).toList())),
        ])),
        const Divider(height: 1, color: Color(0xFF263449)),
        Expanded(child: service.messages.isEmpty
          ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.forum_outlined, size: 48, color: Colors.white24),
              SizedBox(height: 12),
              Text('Your local conversation starts here', style: TextStyle(color: Colors.white60)),
              SizedBox(height: 5),
              Text('Connect to the same Wi-Fi and go online', style: TextStyle(color: Colors.white30, fontSize: 12)),
            ]))
          : ListView.builder(
              padding: const EdgeInsets.all(14),
              itemCount: service.messages.length,
              itemBuilder: (context, i) {
                final m = service.messages[i];
                return Align(
                  alignment: m.isMine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .78),
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    decoration: BoxDecoration(
                      color: m.isMine ? const Color(0xFF405A9C) : const Color(0xFF1B293D),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(15), topRight: const Radius.circular(15),
                        bottomLeft: Radius.circular(m.isMine ? 15 : 4),
                        bottomRight: Radius.circular(m.isMine ? 4 : 15)),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (!m.isMine) Text(m.senderName, style: const TextStyle(color: Color(0xFFA8BCFF), fontSize: 11, fontWeight: FontWeight.bold)),
                      Text(m.text),
                      Align(alignment: Alignment.bottomRight, child: Text(
                        '${m.time.hour.toString().padLeft(2,'0')}:${m.time.minute.toString().padLeft(2,'0')}',
                        style: const TextStyle(color: Colors.white54, fontSize: 10))),
                    ]),
                  ),
                );
              })),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 12),
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF263449)))),
          child: Row(children: [
            Expanded(child: TextField(
              controller: message, enabled: online,
              minLines: 1, maxLines: 4,
              decoration: const InputDecoration(hintText: 'Message your local network…', contentPadding: EdgeInsets.symmetric(horizontal: 15, vertical: 12)),
              onSubmitted: (_) => _send(),
            )),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: online ? _send : null, icon: const Icon(Icons.send_rounded)),
          ]),
        ),
        Padding(padding: const EdgeInsets.only(bottom: 5),
          child: Text('Messages are stored on this device only  ·  ${service.messages.length} saved',
            style: const TextStyle(color: Colors.white30, fontSize: 10))),
      ])),
    );
  }
}
