package com.qprs.musicplayer

import android.content.Context
import kotlin.math.roundToInt

/**
 * 小部件的外观设置：封面大小、按钮颜色、标题颜色。
 *
 * **全局一份**，不是每块小部件一套：桌面上摆两块的人多半是想要它们长得一样，
 * 按 id 存反而要解释「这块和那块为什么不一样」。设置写在 `SharedPreferences` 里
 * （是应用私有目录，备份/清理跟着 App 走）。
 */
internal object WidgetSettings {
    private const val FILE = "playback_widget"

    private const val KEY_COVER_PERCENT = "cover_percent"
    private const val KEY_BUTTON_COLOR = "button_color"
    private const val KEY_TITLE_COLOR = "title_color"

    /** 默认封面大小（100% = 可用空间的 [COVER_FRACTION_AT_FULL]）。 */
    const val DEFAULT_COVER_PERCENT = 100

    /** 默认颜色：白色。小部件背景是透明的，白色 + 暗影在大多数壁纸上都看得清。 */
    const val DEFAULT_COLOR = 0xFFFFFFFF.toInt()

    /** 封面大小的可调范围（百分比）。 */
    const val MIN_COVER_PERCENT = 60
    const val MAX_COVER_PERCENT = 160

    /**
     * 100% 时封面占「可用空间」的比例。
     *
     * 为什么不是「100% 就铺满」：100% 铺满的话，用户把滑块往上推就再也没变化了
     * ——看起来像坏了。留三成余量，60%..160% 全程都能看出变化。
     */
    const val COVER_FRACTION_AT_FULL = 0.7f

    fun coverPercent(context: Context): Int =
        prefs(context).getInt(KEY_COVER_PERCENT, DEFAULT_COVER_PERCENT)
            .coerceIn(MIN_COVER_PERCENT, MAX_COVER_PERCENT)

    fun buttonColor(context: Context): Int =
        prefs(context).getInt(KEY_BUTTON_COLOR, DEFAULT_COLOR)

    fun titleColor(context: Context): Int =
        prefs(context).getInt(KEY_TITLE_COLOR, DEFAULT_COLOR)

    fun saveCoverPercent(context: Context, percent: Int) {
        prefs(context).edit()
            .putInt(KEY_COVER_PERCENT, percent.coerceIn(MIN_COVER_PERCENT, MAX_COVER_PERCENT))
            .apply()
    }

    fun saveButtonColor(context: Context, color: Int) {
        prefs(context).edit().putInt(KEY_BUTTON_COLOR, color).apply()
    }

    fun saveTitleColor(context: Context, color: Int) {
        prefs(context).edit().putInt(KEY_TITLE_COLOR, color).apply()
    }

    /** 恢复默认：封面 100%、按钮与标题都回到白色。 */
    fun reset(context: Context) {
        prefs(context).edit()
            .putInt(KEY_COVER_PERCENT, DEFAULT_COVER_PERCENT)
            .putInt(KEY_BUTTON_COLOR, DEFAULT_COLOR)
            .putInt(KEY_TITLE_COLOR, DEFAULT_COLOR)
            .apply()
    }

    private fun prefs(context: Context) = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
}

/**
 * 封面边长（dp）= 可用空间的较小边 × 比例。**纯函数**，宿主机上就能跑（见单测）。
 *
 * 「可用空间」由调用方给：桌面上是「框子减掉歌名与按钮那一排」之后剩下的地方，
 * 设置页的预览里就是那个框子本身。两边用同一个函数、同一个比例，
 * 预览才不会骗人。
 *
 * 上限死死夹在可用空间里：小部件的尺寸是启动器给的（2×2 可能只有 110dp 出头），
 * 封面按比例长过头就会把下面那排按钮顶出边界——而 RemoteViews 溢出是直接裁掉，
 * 不报错，用户看到的是「按钮没了」。
 */
internal fun coverSizeDp(
    percent: Int,
    boxWidthDp: Int,
    boxHeightDp: Int,
    minDp: Int = 20,
): Int {
    val box = minOf(boxWidthDp, boxHeightDp).coerceAtLeast(0)
    val ratio = percent.coerceIn(WidgetSettings.MIN_COVER_PERCENT, WidgetSettings.MAX_COVER_PERCENT) /
        100f * WidgetSettings.COVER_FRACTION_AT_FULL
    return (box * ratio).roundToInt().coerceIn(minDp.coerceAtMost(box), box)
}
