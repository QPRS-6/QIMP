import 'package:flutter/material.dart';
import 'package:musicplayer/src/theme_settings.dart';

/// 可选的底色预设：`(名字, 颜色)`，第一项是 `null` = 出厂主题。
///
/// 为什么预设和滑块都要：只有预设会觉得被限制，只有滑块则调个纯白要滑三下
/// （桌面小部件那个设置页也是这个搭配）。名字不只是写给人看——
/// 它还当 `tooltip`，也是无障碍读出来的东西、测试里用来点的那一下。
const List<(String, Color?)> kBackgroundPresets = <(String, Color?)>[
  ('默认', null),
  ('纯白', Color(0xFFFFFFFF)),
  ('米白', Color(0xFFF4F1EA)),
  ('浅灰', Color(0xFFE8EAED)),
  ('纯黑', Color(0xFF000000)),
  ('深灰', Color(0xFF1F1F1F)),
  ('深蓝', Color(0xFF0E1B2A)),
  ('墨绿', Color(0xFF10221B)),
  ('酒红', Color(0xFF2A1218)),
  ('雾紫', Color(0xFF1E1B2E)),
];

/// 主页右上角那颗「编辑主题」。
///
/// 入口和页面放在一个文件里：图标、提示语、点开去哪儿，改的时候只有一处要动。
class ThemeButton extends StatelessWidget {
  const ThemeButton({super.key, required this.settings});

  final ThemeSettings settings;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '编辑主题',
      icon: const Icon(Icons.palette_outlined),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ThemePage(settings: settings)),
      ),
    );
  }
}

/// 「编辑主题」页：目前只有一项——背景颜色。
///
/// 改一下**立刻生效、立刻落盘**，没有「保存」按钮：一是照桌面小部件那个设置页的
/// 做法（改完立刻重画），二是省得用户改完盯着屏幕猜「保存了没有」。
///
/// 这一页本身就是预览：页面自己也长在新底色上，不像小部件那样得另设一个预览框
/// ——照着真界面再画一遍的预览，早晚会和真的长不一样。
class ThemePage extends StatefulWidget {
  const ThemePage({super.key, required this.settings});

  final ThemeSettings settings;

  @override
  State<ThemePage> createState() => _ThemePageState();
}

class _ThemePageState extends State<ThemePage> {
  /// 正在编辑的颜色；`null` = 出厂主题。
  ///
  /// 单独留一份是为了滑块：「恢复默认」之后滑块得从出厂那个色重新起步，
  /// 而设置里存的是 `null`，滑块可没有「null 度」。
  Color? _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.settings.background;
  }

  /// 滑块该显示的那个色：没改过时给的是出厂主题的页面底（M3 里就是 `surface`），
  /// 于是从「默认」直接拖滑块也有个像样的起点。
  Color get _sliderColor => _draft ?? defaultAppTheme().colorScheme.surface;

  /// 点预设 / 恢复默认。
  void _pick(Color? color) {
    setState(() => _draft = color);
    widget.settings.setBackground(color);
  }

  /// 滑块在动：界面立刻跟着变，松手那一下才落盘（见 [ThemeSettings.setBackground]）。
  void _drag(Color color, {required bool done}) {
    setState(() => _draft = color);
    widget.settings.setBackground(color, save: done);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _sliderColor;
    final red = (color.r * 255).round();
    final green = (color.g * 255).round();
    final blue = (color.b * 255).round();

    return Scaffold(
      appBar: AppBar(title: const Text('编辑主题')),
      // 内容可能比一屏长（小屏上三路滑块 + 十个色块），所以能滚。
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('背景颜色', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '点一个色块，或者用下面的滑块自己调。改完立刻生效，下次打开还是这个色'
            '——你现在看到的这一页就是效果。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final preset in kBackgroundPresets) _swatch(preset, theme),
            ],
          ),
          const SizedBox(height: 28),
          Text('自己调', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '拖动时立刻能看到效果，松手才记下来（拖一次写几十遍文件没必要）。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          _channel('红', red, (v) => Color.fromARGB(255, v, green, blue)),
          _channel('绿', green, (v) => Color.fromARGB(255, red, v, blue)),
          _channel('蓝', blue, (v) => Color.fromARGB(255, red, green, v)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '当前：${hexOf(color)}${_draft == null ? '（默认）' : ''}',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              TextButton.icon(
                // 已经是默认了就没什么可恢复的，按钮灰着。
                onPressed: _draft == null ? null : () => _pick(null),
                icon: const Icon(Icons.restart_alt),
                label: const Text('恢复默认'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 一个底色色块。选中的那个加一个对勾——「当前用的是哪个」必须一眼看出来，
  /// 光靠一圈描边在小屏上太不明显。
  Widget _swatch((String, Color?) preset, ThemeData theme) {
    final (name, color) = preset;
    // 「默认」那张要用出厂主题的底来画（不然画不出来），但它的**值**是 null。
    final shown = color ?? defaultAppTheme().colorScheme.surface;
    final selected = _draft == color;
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: () => _pick(color),
        customBorder: const CircleBorder(),
        child: Ink(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: shown,
            shape: BoxShape.circle,
            // 纯白与近白在浅色主题下必须还能看出边界。
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: selected
              ? Icon(Icons.check, size: 22, color: contrastInk(shown))
              : null,
        ),
      ),
    );
  }

  /// 一路滑块（红 / 绿 / 蓝），右边跟着显示 0-255 的数字。
  Widget _channel(String label, int value, Color Function(int v) apply) {
    return Row(
      children: [
        SizedBox(width: 28, child: Text(label)),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            max: 255,
            // 255 档 = 一档一个整数，滑到的就是最终写进文件的那个值。
            divisions: 255,
            label: '$value',
            onChanged: (v) => _drag(apply(v.round()), done: false),
            onChangeEnd: (v) => _drag(apply(v.round()), done: true),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text('$value', textAlign: TextAlign.end),
        ),
      ],
    );
  }
}
