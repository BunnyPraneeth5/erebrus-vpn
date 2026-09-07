import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import 'browser_controller.dart';

/// A link the user long-pressed inside a WebView page.
class BrowserLinkHit {
  const BrowserLinkHit({required this.url, required this.label});

  final String url;
  final String label;
}

/// JavaScript injected on each page load to capture link long-presses and
/// forward them to the [kLinkContextMenuChannel] JavaScript channel.
const kLinkContextMenuChannel = 'ErebrusLink';

const kLinkContextMenuJs = '''
(function () {
  if (window.__erebrusLinkMenuInstalled) return;
  window.__erebrusLinkMenuInstalled = true;

  var LONG_PRESS_MS = 450;
  var suppressClickUntil = 0;
  var pressTimer = null;
  var pressAnchor = null;

  function findAnchor(node) {
    while (node) {
      if (node.nodeType === 1 && node.tagName === 'A' && node.href) return node;
      node = node.parentElement;
    }
    return null;
  }

  function payload(anchor) {
    var text = '';
    try { text = (anchor.innerText || anchor.textContent || '').trim(); } catch (e) {}
    return JSON.stringify({ url: anchor.href, text: text });
  }

  function post(anchor) {
    if (typeof ErebrusLink !== 'undefined' && ErebrusLink.postMessage) {
      ErebrusLink.postMessage(payload(anchor));
    }
  }

  function clearPress() {
    if (pressTimer) {
      clearTimeout(pressTimer);
      pressTimer = null;
    }
    pressAnchor = null;
  }

  document.addEventListener('click', function (e) {
    if (Date.now() < suppressClickUntil) {
      e.preventDefault();
      e.stopImmediatePropagation();
    }
  }, true);

  document.addEventListener('touchstart', function (e) {
    var anchor = findAnchor(e.target);
    if (!anchor) return;
    pressAnchor = anchor;
    if (pressTimer) clearTimeout(pressTimer);
    pressTimer = setTimeout(function () {
      if (!pressAnchor) return;
      suppressClickUntil = Date.now() + 900;
      post(pressAnchor);
      clearPress();
    }, LONG_PRESS_MS);
  }, { passive: true, capture: true });

  document.addEventListener('touchmove', clearPress, { passive: true, capture: true });
  document.addEventListener('touchend', clearPress, { passive: true, capture: true });
  document.addEventListener('touchcancel', clearPress, { passive: true, capture: true });

  document.addEventListener('contextmenu', function (e) {
    var anchor = findAnchor(e.target);
    if (!anchor) return;
    e.preventDefault();
    suppressClickUntil = Date.now() + 900;
    post(anchor);
  }, true);
})();
''';

BrowserLinkHit? parseBrowserLinkHit(String message) {
  try {
    final data = jsonDecode(message) as Map<String, dynamic>;
    final url = (data['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) return null;
    final label = (data['text'] as String?)?.trim() ?? '';
    return BrowserLinkHit(url: url, label: label);
  } catch (_) {
    return null;
  }
}

Future<void> showBrowserLinkContextMenu(
  BuildContext context,
  BrowserController controller,
  BrowserLinkHit hit,
) async {
  if (!BrowserController.isWebUrl(hit.url)) return;
  final label = hit.label.isNotEmpty ? hit.label : hit.url;
  controller.setRouteCovered(true);
  ModalRoute<dynamic>? menuRoute;

  try {
    await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.raised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    ),
    builder: (ctx) {
      menuRoute = ModalRoute.of(ctx);
      final maxHeight = MediaQuery.sizeOf(ctx).height * 0.82;

      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: grotesk(size: 16, weight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hit.url,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: mono(size: 11, color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: AppColors.strokeSoft),
                _LinkMenuTile(
                  icon: Icons.open_in_browser,
                  title: 'Open',
                  onTap: () {
                    Navigator.pop(ctx);
                    controller.openLink(hit.url);
                  },
                ),
                _LinkMenuTile(
                  icon: Icons.open_in_new,
                  title: 'Open in new tab',
                  onTap: () {
                    Navigator.pop(ctx);
                    controller.openInNewTab(hit.url);
                  },
                ),
                _LinkMenuTile(
                  icon: Icons.tab,
                  title: 'Open in background tab',
                  onTap: () {
                    Navigator.pop(ctx);
                    controller.openInBackgroundTab(hit.url);
                  },
                ),
                _LinkMenuTile(
                  icon: Icons.link,
                  title: 'Copy link',
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: hit.url));
                    if (context.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Link copied'), behavior: SnackBarBehavior.floating, backgroundColor: AppColors.surface3),
                      );
                    }
                  },
                ),
                if (hit.label.isNotEmpty)
                  _LinkMenuTile(
                    icon: Icons.short_text,
                    title: 'Copy link text',
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: hit.label));
                      if (context.mounted) Navigator.pop(ctx);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Link text copied'),
                            behavior: SnackBarBehavior.floating,
                            backgroundColor: AppColors.surface3,
                          ),
                        );
                      }
                    },
                  ),
                _LinkMenuTile(
                  icon: Icons.launch,
                  title: 'Open in external browser',
                  onTap: () async {
                    Navigator.pop(ctx);
                    final uri = Uri.tryParse(hit.url);
                    if (uri == null) return;
                    var launched = false;
                    try {
                      launched = await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    } catch (_) {
                      launched = false;
                    }
                    if (!launched && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Could not open the external browser'),
                          behavior: SnackBarBehavior.floating,
                          backgroundColor: AppColors.surface3,
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      );
    },
    );
  } finally {
    await menuRoute?.completed;
    if (context.mounted) {
      controller.setRouteCovered(ModalRoute.of(context)?.isCurrent == false);
    }
  }
}

class _LinkMenuTile extends StatelessWidget {
  const _LinkMenuTile({required this.icon, required this.title, required this.onTap});

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.textSecondary),
      title: Text(
        title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: grotesk(size: 15, weight: FontWeight.w600),
      ),
      onTap: onTap,
    );
  }
}