import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _ua =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

final _dio = Dio(BaseOptions(
  followRedirects: true,
  connectTimeout: const Duration(seconds: 20),
  receiveTimeout: const Duration(seconds: 60),
));

// يبحث عن روابط الفيديو في الصفحة الحالية
const _findJs = r'''(function(){var o=[];
document.querySelectorAll('video').forEach(function(v){
  var s=v.currentSrc||v.src||'';
  if(!s){var e=v.querySelector('source');if(e)s=e.src||'';}
  if(s)o.push(s);
});
try{performance.getEntriesByType('resource').forEach(function(r){
  var n=r.name;
  if(/\.(mp4|webm|m3u8)(\?|$)|mime_type=video/i.test(n))o.push(n);
});}catch(e){}
return JSON.stringify(o);})()''';

void main() => runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const Home()));

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;
  final pages = const [LinksPage(), PhonePage(), ShortsPage()];
  @override
  Widget build(BuildContext c) => Scaffold(
        body: IndexedStack(index: i, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => i = v),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.link), label: 'روابطي'),
            NavigationDestination(
                icon: Icon(Icons.phone_android), label: 'هاتفي'),
            NavigationDestination(
                icon: Icon(Icons.play_circle), label: 'شورتس'),
          ],
        ),
      );
}

// ---------- مشغل عمودي مشترك ----------
class Reel extends StatefulWidget {
  final Future<VideoPlayerController> Function() make;
  final Future<void> Function() onDownload;
  const Reel({super.key, required this.make, required this.onDownload});
  @override
  State<Reel> createState() => _ReelState();
}

class _ReelState extends State<Reel> {
  VideoPlayerController? c;
  bool busy = false;
  String? err;

  @override
  void initState() {
    super.initState();
    () async {
      try {
        final v = await widget.make();
        c = v;
        await v.initialize();
        v.setLooping(true);
        if (mounted) {
          setState(() {});
          v.play();
        }
      } catch (e) {
        if (mounted) setState(() => err = '$e');
      }
    }();
  }

  @override
  void dispose() {
    c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = c;
    if (err != null) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(err!, textAlign: TextAlign.center)));
    }
    if (v == null || !v.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(fit: StackFit.expand, children: [
      GestureDetector(
        onTap: () => setState(() => v.value.isPlaying ? v.pause() : v.play()),
        child: Center(
            child: AspectRatio(
                aspectRatio: v.value.aspectRatio, child: VideoPlayer(v))),
      ),
      Positioned(
        right: 16,
        bottom: 40,
        child: busy
            ? const CircularProgressIndicator()
            : IconButton.filled(
                icon: const Icon(Icons.download),
                onPressed: () async {
                  setState(() => busy = true);
                  try {
                    await widget.onDownload();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('تم الحفظ في المعرض')));
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('فشل التحميل: $e')));
                    }
                  }
                  if (mounted) setState(() => busy = false);
                },
              ),
      ),
    ]);
  }
}

// ---------- 1) روابطي (متصفح داخل التطبيق) ----------
class Shortcut {
  String name, url;
  Shortcut(this.name, this.url);
}

class LinksPage extends StatefulWidget {
  const LinksPage({super.key});
  @override
  State<LinksPage> createState() => _LinksPageState();
}

class _LinksPageState extends State<LinksPage> {
  final web = WebViewController();
  final addr = TextEditingController();
  final search = TextEditingController();
  bool browsing = false;
  bool busy = false;
  double? pct;
  int progress = 100;
  String url = '';
  List<Shortcut> sc = [
    Shortcut('Google', 'https://www.google.com'),
    Shortcut('TikTok', 'https://www.tiktok.com'),
    Shortcut('Facebook', 'https://m.facebook.com'),
    Shortcut('Instagram', 'https://www.instagram.com'),
    Shortcut('X', 'https://x.com'),
    Shortcut('YouTube', 'https://m.youtube.com'),
  ];

  @override
  void initState() {
    super.initState();
    web
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) {
          final s = Uri.tryParse(r.url)?.scheme ?? '';
          return (s == 'http' || s == 'https' || s == 'about' || s == 'data')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onPageStarted: (u) {
          if (mounted) {
            setState(() {
              url = u;
              addr.text = u;
            });
          }
        },
        onProgress: (p) {
          if (mounted) setState(() => progress = p);
        },
        onPageFinished: (u) {
          if (mounted) {
            setState(() {
              url = u;
              addr.text = u;
              progress = 100;
            });
          }
        },
      ));
    _load();
  }

  // ---- حفظ الاختصارات في ملف ----
  Future<File> _file() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/shortcuts.json');

  Future<void> _load() async {
    try {
      final f = await _file();
      if (await f.exists()) {
        final l = jsonDecode(await f.readAsString()) as List;
        sc = l.map((e) => Shortcut('${e['n']}', '${e['u']}')).toList();
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      await (await _file()).writeAsString(
          jsonEncode(sc.map((e) => {'n': e.name, 'u': e.url}).toList()));
    } catch (_) {}
  }

  void _msg(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // ---- التنقل ----
  void open(String input) {
    final t = input.trim();
    if (t.isEmpty) return;
    Uri u;
    try {
      if (RegExp(r'^[a-z]+://', caseSensitive: false).hasMatch(t)) {
        u = Uri.parse(t);
      } else if (!t.contains(' ') && t.contains('.')) {
        u = Uri.parse('https://$t');
      } else {
        u = Uri.parse(
            'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}');
      }
    } catch (_) {
      u = Uri.parse(
          'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}');
    }
    FocusScope.of(context).unfocus();
    setState(() => browsing = true);
    web.loadRequest(u);
  }

  void goHome() {
    web.loadHtmlString('<html></html>');
    setState(() => browsing = false);
  }

  Future<void> back() async {
    if (await web.canGoBack()) {
      web.goBack();
    } else {
      goHome();
    }
  }

  // ---- التحميل ----
  Future<Object?> _js(String code) async {
    try {
      final r = await web.runJavaScriptReturningResult(code);
      dynamic d = jsonDecode(r.toString());
      if (d is String) {
        try {
          d = jsonDecode(d);
        } catch (_) {}
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _pick(List<String> l) => showModalBottomSheet<String>(
        context: context,
        builder: (d) => ListView(children: [
          const ListTile(title: Text('اختر الفيديو')),
          ...l.map((e) {
            final u = Uri.tryParse(e) ?? Uri();
            return ListTile(
              leading: const Icon(Icons.movie),
              title: Text(u.host),
              subtitle:
                  Text(u.path, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(d, e),
            );
          }),
        ]),
      );

  Future<void> grab() async {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.contains('youtube.com') || host.contains('youtu.be')) {
      _msg('تحميل فيديوهات يوتيوب غير متاح');
      return;
    }
    final d = await _js(_findJs);
    final all = <String>{};
    if (d is List) {
      for (final e in d) {
        all.add('$e');
      }
    }
    final http = all.where((e) => e.startsWith('http')).toList();
    final good = http
        .where((e) => !e.toLowerCase().contains('.m3u8'))
        .toList()
        .reversed
        .take(8)
        .toList();
    if (good.isEmpty) {
      _msg(http.isNotEmpty
          ? 'هذا بث مجزأ (m3u8) ولا يمكن تحميله مباشرة'
          : 'لم أجد فيديو قابلاً للتحميل. شغّل الفيديو أولاً ثم اضغط تحميل');
      return;
    }
    final v = good.length == 1 ? good.first : await _pick(good);
    if (v == null) return;
    await _download(v);
  }

  Future<void> _download(String v) async {
    final cookie = await _js('document.cookie');
    final p =
        '${(await getTemporaryDirectory()).path}/${DateTime.now().millisecondsSinceEpoch}.mp4';
    setState(() {
      busy = true;
      pct = null;
    });
    try {
      await _dio.download(
        v,
        p,
        options: Options(headers: {
          'User-Agent': _ua,
          'Referer': url,
          if (cookie is String && cookie.isNotEmpty) 'Cookie': cookie,
        }),
        onReceiveProgress: (a, b) {
          if (b > 0 && mounted) setState(() => pct = a / b);
        },
      );
      await Gal.putVideo(p);
      _msg('تم الحفظ في المعرض');
    } catch (e) {
      _msg('فشل التحميل: $e');
    }
    if (mounted) setState(() => busy = false);
  }

  // ---- الاختصارات ----
  Future<void> addShortcut() async {
    final n = TextEditingController();
    final u = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('إضافة اختصار'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: n, decoration: const InputDecoration(hintText: 'الاسم')),
          TextField(
              controller: u,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(hintText: 'الرابط')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('إضافة')),
        ],
      ),
    );
    if (ok == true && u.text.trim().isNotEmpty) {
      var link = u.text.trim();
      if (!link.contains('://')) link = 'https://$link';
      final name = n.text.trim().isEmpty
          ? (Uri.tryParse(link)?.host ?? link)
          : n.text.trim();
      setState(() => sc.add(Shortcut(name, link)));
      _save();
    }
  }

  Future<void> removeShortcut(Shortcut s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('حذف ${s.name}؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('إلغاء')),
          TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => sc.remove(s));
      _save();
    }
  }

  Widget tile(Shortcut s) {
    final host = Uri.tryParse(s.url)?.host ?? '';
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => open(s.url),
      onLongPress: () => removeShortcut(s),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 60,
          height: 60,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Image.network(
            'https://www.google.com/s2/favicons?domain=$host&sz=128',
            errorBuilder: (_, __, ___) => Center(
                child: Text(s.name.isEmpty ? '?' : s.name[0].toUpperCase(),
                    style: const TextStyle(
                        color: Colors.black,
                        fontSize: 24,
                        fontWeight: FontWeight.bold))),
          ),
        ),
        const SizedBox(height: 6),
        Text(s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Widget addTile() => InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: addShortcut,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
                color: Colors.white12, borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.add, size: 30),
          ),
          const SizedBox(height: 6),
          const Text('إضافة', style: TextStyle(fontSize: 12)),
        ]),
      );

  Widget _home() => Container(
        decoration: const BoxDecoration(
            gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF0B3B4A), Color(0xFF101820)])),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const SizedBox(height: 40),
          const Center(
              child: Text('روابطي',
                  style: TextStyle(fontSize: 38, fontWeight: FontWeight.w800))),
          const SizedBox(height: 28),
          TextField(
            controller: search,
            textInputAction: TextInputAction.go,
            onSubmitted: (v) {
              open(v);
              search.clear();
            },
            decoration: InputDecoration(
              hintText: 'ابحث في Google أو الصق رابطاً',
              filled: true,
              fillColor: Colors.white12,
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 28),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 18,
            crossAxisSpacing: 8,
            childAspectRatio: 0.85,
            children: [...sc.map(tile), addTile()],
          ),
        ]),
      );

  Widget _browser() => Column(children: [
        Row(children: [
          IconButton(icon: const Icon(Icons.arrow_back), onPressed: back),
          Expanded(
            child: TextField(
              controller: addr,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: open,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.white12,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          IconButton(icon: const Icon(Icons.home), onPressed: goHome),
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: () => web.reload()),
        ]),
        if (progress < 100) LinearProgressIndicator(value: progress / 100),
        Expanded(
          child: Stack(children: [
            WebViewWidget(controller: web),
            Positioned(
              right: 16,
              bottom: 24,
              child: busy
                  ? Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(
                          color: Colors.black54, shape: BoxShape.circle),
                      child: Center(child: CircularProgressIndicator(value: pct)),
                    )
                  : FloatingActionButton(
                      heroTag: null,
                      onPressed: grab,
                      child: const Icon(Icons.download),
                    ),
            ),
          ]),
        ),
      ]);

  @override
  Widget build(BuildContext c) => SafeArea(
        child: IndexedStack(
            index: browsing ? 1 : 0, children: [_home(), _browser()]),
      );
}

// ---------- 2) هاتفي ----------
class PhonePage extends StatefulWidget {
  const PhonePage({super.key});
  @override
  State<PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<PhonePage> {
  List<AssetEntity> items = [];
  String? msg = 'جاري التحميل...';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) {
      setState(() => msg = 'لازم تسمح بالوصول للفيديوهات');
      return;
    }
    final paths = await PhotoManager.getAssetPathList(
        type: RequestType.video, onlyAll: true);
    if (paths.isEmpty) {
      setState(() => msg = 'لا توجد فيديوهات');
      return;
    }
    final total = await paths.first.assetCountAsync;
    final all = await paths.first.getAssetListRange(start: 0, end: total);
    setState(() {
      items = all;
      msg = null;
    });
  }

  @override
  Widget build(BuildContext c) {
    if (msg != null) return Center(child: Text(msg!));
    return PageView.builder(
      scrollDirection: Axis.vertical,
      itemCount: items.length,
      itemBuilder: (_, k) => Reel(
        key: ValueKey(items[k].id),
        make: () async =>
            VideoPlayerController.file((await items[k].file) as File),
        onDownload: () async {
          final f = await items[k].file;
          await Gal.putVideo(f!.path);
        },
      ),
    );
  }
}

// ---------- 3) شورتس يوتيوب (داخل التطبيق) ----------
class ShortsPage extends StatefulWidget {
  const ShortsPage({super.key});
  @override
  State<ShortsPage> createState() => _ShortsPageState();
}

class _ShortsPageState extends State<ShortsPage> {
  final field = TextEditingController();
  late final WebViewController web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setUserAgent(_ua)
    ..loadRequest(Uri.parse('https://m.youtube.com/shorts'));

  void open() {
    final t = field.text.trim();
    final m = RegExp(r'(?:shorts/|v=|youtu\.be/)([\w-]{11})').firstMatch(t);
    final id = m?.group(1) ?? (t.length == 11 ? t : null);
    if (id != null) {
      web.loadRequest(Uri.parse('https://m.youtube.com/shorts/$id'));
    }
    field.clear();
  }

  @override
  Widget build(BuildContext c) => SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: field,
                      decoration: const InputDecoration(
                          hintText: 'رابط شورتس معيّن (اختياري)'))),
              IconButton(icon: const Icon(Icons.play_arrow), onPressed: open),
            ]),
          ),
          Expanded(child: WebViewWidget(controller: web)),
        ]),
      );
}
