import 'package:flutter/material.dart';

import 'mpv.dart';
import 'platform.dart';

/// Windows only: the picture of the shared player as a Flutter texture, behind every screen. Android draws it on a native
/// surface behind Flutter; here the screens that want to show video (the player, the live TV guide's corner picture) are
/// transparent in the same way, and this layer sits under the whole Navigator (main.dart), so nothing else had to change.
/// Black while nothing plays; the picture keeps its shape (letterbox); a mini rectangle (live TV guide) moves and shrinks it.
class PekVideoSurface extends StatelessWidget {
  const PekVideoSurface({super.key});

  @override
  Widget build(BuildContext context) {
    if (!PekPlatform.videoAsTexture) return const SizedBox.shrink();
    final player = PekPlayer.shared;
    return ValueListenableBuilder<int?>(
      valueListenable: player.surfaceId,
      builder: (_, id, __) {
        if (id == null) return const SizedBox.shrink();
        return ValueListenableBuilder<Rect?>(
          valueListenable: player.miniRect,
          builder: (_, mini, __) => ValueListenableBuilder<Size>(
            valueListenable: player.videoSize,
            builder: (_, size, __) {
              final ratio = (size.width > 0 && size.height > 0) ? size.width / size.height : 16 / 9;
              final picture = ColoredBox(color: Colors.black, child: Center(child: AspectRatio(aspectRatio: ratio, child: Texture(textureId: id, filterQuality: FilterQuality.medium))));
              if (mini == null) return Positioned.fill(child: picture);
              return Positioned(left: mini.left, top: mini.top, width: mini.width, height: mini.height, child: picture);
            },
          ),
        );
      },
    );
  }
}
