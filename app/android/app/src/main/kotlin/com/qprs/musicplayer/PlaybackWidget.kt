package com.qprs.musicplayer

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.widget.RemoteViews

/**
 * 小部件的形状：一行还是两行。
 *
 * 只有这两种——2×1 与 4×1 长相一样、2×2 与 4×2 长相一样，宽度交给 RemoteViews
 * 自己撑开。做成四个布局只会多几份要同步维护的 XML。
 */
internal enum class WidgetShape { Row, Card }

/**
 * 高度（dp）到了这里就放得下两行：封面 + 歌名 + 一排五个按钮。
 *
 * 110dp 就是 Android 文档里「两格」的最小高度（`70n - 30`），2×2 / 4×2 正好卡在这儿。
 */
internal const val CARD_MIN_HEIGHT_DP = 110

/**
 * 按**实际高度**挑布局。
 *
 * 为什么不看「用户当初挑的是哪一档」：小部件加进来之后是可以拉大拉小的，
 * 2×1 被拉成 2×2 就该长成卡片式；反过来把 4×2 压成一行，也应该缩成一行式。
 */
internal fun widgetShape(minHeightDp: Int): WidgetShape =
    if (minHeightDp >= CARD_MIN_HEIGHT_DP) WidgetShape.Card else WidgetShape.Row

/**
 * 桌面小部件的公共实现：拉状态、画图、挂点击。
 *
 * 四个尺寸（2×1 / 2×2 / 4×1 / 4×2）共用这一份代码，见文件末尾那四个子类。
 *
 * 数据全来自 Rust（[PlaybackBridge]），**不经过 Flutter**：用户把 App 从任务列表
 * 划掉之后小部件照样得显示、照样得能按。按钮点下去送到 [PlaybackService]，
 * 与通知栏上那几个按钮走的是**同一组动作**，于是「按一下的效果」只有一份实现。
 *
 * 已知边界：进程被系统回收之后 Rust 引擎也没了，这时小部件退化成「QIMP」
 * 且按键无效——和通知栏一样，播放器本身没在运行时，确实没有东西可控制。
 */
abstract class PlaybackWidgetProvider : AppWidgetProvider() {

    /**
     * 拿不到实际尺寸时的兜底形状（info XML 里的 `initialLayout` 说了算）。
     *
     * 用属性而不是构造参数：`WidgetShape` 是 `internal` 的，而 provider 必须是
     * public（系统按类名实例化），构造参数会把 internal 类型暴露到 public 签名上。
     */
    internal open val defaultShape: WidgetShape = WidgetShape.Row

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { id -> renderWidget(context, manager, id, defaultShape) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: android.os.Bundle,
    ) {
        // 用户拉大拉小之后会走这里：形状可能要从一行变成两行。
        renderWidget(context, manager, id, defaultShape)
    }
}

/** 2×1：封面 + 歌名 + 上一曲 · 播放 · 下一曲。 */
class MusicWidget2x1 : PlaybackWidgetProvider()

/** 4×1：同上，只是更宽。 */
class MusicWidget4x1 : PlaybackWidgetProvider()

/** 2×2：封面 + 歌名 + 随机 · 上一曲 · 播放 · 下一曲 · 循环。 */
class MusicWidget2x2 : PlaybackWidgetProvider() {
    override val defaultShape: WidgetShape get() = WidgetShape.Card
}

/** 4×2：同上，只是更宽。 */
class MusicWidget4x2 : PlaybackWidgetProvider() {
    override val defaultShape: WidgetShape get() = WidgetShape.Card
}

// ---------------------------------------------------------------------------
// 刷新与绘制
//
// 都写成文件级函数而不是成员：刷新是从 [PlaybackService] 发起的，那一刻并没有
// provider 实例（provider 由系统按需创建），拿组件名找到 id 之后直接画就行。
// ---------------------------------------------------------------------------

/** 四个尺寸各自的接收者；刷新时一个都不能落下。 */
private val WIDGET_PROVIDERS = listOf(
    MusicWidget2x1::class.java,
    MusicWidget4x1::class.java,
    MusicWidget2x2::class.java,
    MusicWidget4x2::class.java,
)

/** 封面的缓存（同一首不重复解图），见 [widgetArtwork]。 */
private val artworkLock = Any()
private var cachedArtworkTrackId = -1L
private var cachedArtwork: Bitmap? = null

/**
 * 刷新桌面上所有的播放小部件。
 *
 * [PlaybackService] 那边状态一变就调它（切歌、播放 / 暂停、随机、循环）。
 * 服务不在的时候没人调，也就没人白刷——每次刷新都要读一次封面。
 */
internal fun updatePlaybackWidgets(context: Context) {
    val manager = AppWidgetManager.getInstance(context) ?: return
    WIDGET_PROVIDERS.forEach { provider ->
        val ids = manager.getAppWidgetIds(ComponentName(context, provider))
        ids.forEach { id -> renderWidget(context, manager, id, WidgetShape.Row) }
    }
}

/** 画一个小部件：先定形状，再挂内容，最后交给系统。 */
private fun renderWidget(
    context: Context,
    manager: AppWidgetManager,
    id: Int,
    fallback: WidgetShape,
) {
    val minHeight = manager
        .getAppWidgetOptions(id)
        .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
    val minWidth = manager
        .getAppWidgetOptions(id)
        .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
    val shape = shapeFor(manager, id, fallback, minHeight)
    // 每次都要新 inflate 一份 RemoteViews：几块小部件共用一份的话，
    // 系统会按最后一次的尺寸把所有的都重画。
    val views = RemoteViews(context.packageName, layoutOf(shape))
    bindWidget(context, views, shape, minWidth, minHeight)
    manager.updateAppWidget(id, views)
}

/**
 * 布局：**实际尺寸**优先，拿不到就用这个尺寸档的默认形状
 * （info XML 里的 `initialLayout`，也就是用户挑的那一档）。
 */
private fun shapeFor(
    manager: AppWidgetManager,
    id: Int,
    fallback: WidgetShape,
    minHeight: Int,
): WidgetShape {
    if (minHeight > 0) return widgetShape(minHeight)
    return when (manager.getAppWidgetInfo(id)?.initialLayout) {
        R.layout.widget_card -> WidgetShape.Card
        R.layout.widget_row -> WidgetShape.Row
        else -> fallback
    }
}

private fun layoutOf(shape: WidgetShape): Int =
    if (shape == WidgetShape.Card) R.layout.widget_card else R.layout.widget_row

/** 把当前的播放状态画进 [views]：封面、歌名、按钮图标与点击、还有用户设的外观。 */
private fun bindWidget(
    context: Context,
    views: RemoteViews,
    shape: WidgetShape,
    widgetWidthDp: Int,
    widgetHeightDp: Int,
) {
    val ready = PlaybackBridge.engineReady()
    val playing = ready && PlaybackBridge.stateCode() == PlaybackBridge.STATE_PLAYING

    views.setTextViewText(R.id.widget_title, widgetTitle(context, ready))
    views.setTextColor(R.id.widget_title, WidgetSettings.titleColor(context))
    views.setImageViewResource(
        R.id.widget_toggle,
        if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play,
    )

    val artwork = widgetArtwork(ready)
    if (artwork != null) {
        views.setImageViewBitmap(R.id.widget_art, artwork)
    } else {
        views.setImageViewResource(R.id.widget_art, R.drawable.ic_widget_note)
    }
    applyCoverSize(context, views, shape, widgetWidthDp, widgetHeightDp)

    // 整块也能点：进 App（哪里在播、放的是什么由界面自己去查）。子按钮的点击优先。
    views.setOnClickPendingIntent(R.id.widget_root, contentPendingIntent(context))
    views.setOnClickPendingIntent(
        R.id.widget_previous,
        servicePendingIntent(context, PlaybackService.ACTION_PREVIOUS, REQUEST_PREVIOUS),
    )
    views.setOnClickPendingIntent(
        R.id.widget_toggle,
        servicePendingIntent(context, PlaybackService.ACTION_TOGGLE, REQUEST_TOGGLE),
    )
    views.setOnClickPendingIntent(
        R.id.widget_next,
        servicePendingIntent(context, PlaybackService.ACTION_NEXT, REQUEST_NEXT),
    )
    // 右上角那颗齿轮：改成自己的样子（封面大小 / 按钮颜色 / 标题颜色）。
    views.setOnClickPendingIntent(R.id.widget_settings, settingsPendingIntent(context))

    // 随机 / 循环只在两行的布局里；一行式布局没有这两个 id，下面这些调用是空操作。
    views.setImageViewResource(R.id.widget_shuffle, R.drawable.ic_widget_shuffle)
    views.setImageViewResource(R.id.widget_repeat, repeatIcon(ready))
    views.setOnClickPendingIntent(
        R.id.widget_shuffle,
        servicePendingIntent(context, PlaybackService.ACTION_TOGGLE_SHUFFLE, REQUEST_SHUFFLE),
    )
    views.setOnClickPendingIntent(
        R.id.widget_repeat,
        servicePendingIntent(context, PlaybackService.ACTION_CYCLE_REPEAT, REQUEST_REPEAT),
    )

    applyButtonAppearance(context, views, ready)
}

/**
 * 按钮与齿轮的颜色：用户选的那个色，**用颜色滤镜染**。
 *
 * 为什么这里敢用滤镜（而封面那边坚决不用）：滤镜是挂在**某个 view** 上的，
 * 每个按钮各有各的 id，所以染按钮永远不会染到封面。
 * 封面上那一张是照片，被染一下就是「滤镜脸」，那才是真出事。
 *
 * 随机 / 循环的开关状态用**透明度**区分（关 45%、开 100%）：
 * 两个状态共用同一个图标，颜色才能完全交给用户；用两套不同颜色的 drawable
 * 就没法再叠用户选的颜色了。
 */
private fun applyButtonAppearance(context: Context, views: RemoteViews, ready: Boolean) {
    val color = WidgetSettings.buttonColor(context)
    ACTION_BUTTON_IDS.forEach { id -> views.setInt(id, "setColorFilter", color) }
    views.setInt(R.id.widget_settings, "setColorFilter", color)

    val repeat = if (ready) PlaybackBridge.repeatCode() else PlaybackBridge.REPEAT_OFF
    val shuffleOn = ready && PlaybackBridge.shuffleOn()
    views.setInt(R.id.widget_shuffle, "setImageAlpha", alphaFor(shuffleOn))
    views.setInt(R.id.widget_repeat, "setImageAlpha", alphaFor(repeat != PlaybackBridge.REPEAT_OFF))
}

/**
 * 开关状态 → 图标透明度（0..255）。
 *
 * 设置页的预览也用这个值，不然「预览里是亮的、桌面上却是暗的」这种偏差最难查。
 */
internal fun alphaFor(on: Boolean): Int = if (on) 255 else 115

/**
 * 封面大小：把图**缩小到用户要的尺寸再居中**，而不是去改它的布局参数。
 *
 * 为什么不用 `setViewLayoutWidth/Height`：那两个方法带 gravity 参数、且是 API 31 才有的，
 * 而 RemoteViews 的动作是**在小部件宿主（启动器）进程里用反射执行的**——
 * 老启动器上压根找不到这个方法。`setViewPadding` 是十几年前就有的动作，谁上都认。
 *
 * 框子（见两个布局 XML）留足地方，图按 `fitCenter` 缩进「框子减去 padding」的内容区，
 * 于是「封面大小」= 框子边长 − 两边的 padding。想更大就更大：框子本来就比基准尺寸大一圈。
 */
private fun applyCoverSize(
    context: Context,
    views: RemoteViews,
    shape: WidgetShape,
    widgetWidthDp: Int,
    widgetHeightDp: Int,
) {
    val card = shape == WidgetShape.Card
    val boxWidth = if (card) widgetWidthDp else ROW_COVER_BOX_DP
    val boxHeight = if (card) {
        widgetHeightDp - CARD_CONTROLS_DP
    } else {
        widgetHeightDp - ROW_CONTROLS_DP
    }
    // 尺寸读不出来（刚添加、宿主还没回填）：保留 XML 里的默认样子。
    if (boxWidth <= 0 || boxHeight <= 0) return

    val size = coverSizeDp(WidgetSettings.coverPercent(context), boxWidth, boxHeight)
    val horizontal = ((boxWidth - size) / 2).coerceAtLeast(0)
    val vertical = ((boxHeight - size) / 2).coerceAtLeast(0)
    views.setViewPadding(R.id.widget_art, horizontal, vertical, horizontal, vertical)
}

/**
 * 循环图标：关（同样的箭头，只是暗）/ 全部 / 单曲（多一个「1」）。
 *
 * 关与开的区别交给透明度，所以这里只需要分「要不要那个 1」。
 */
private fun repeatIcon(ready: Boolean): Int {
    if (ready && PlaybackBridge.repeatCode() == PlaybackBridge.REPEAT_ONE) {
        return R.drawable.ic_widget_repeat_one
    }
    return R.drawable.ic_widget_repeat
}

/** 标题：与通知栏同一套兜底话术（什么都没在放时显示应用名）。 */
private fun widgetTitle(context: Context, ready: Boolean): String {
    val title = if (ready) PlaybackBridge.trackTitle().orEmpty() else ""
    return when {
        title.isNotBlank() -> title
        ready && PlaybackBridge.trackId() > 0 -> context.getString(R.string.widget_unknown_track)
        else -> context.getString(R.string.app_name)
    }
}

/**
 * 当前曲目的封面；没有封面、引擎没起来、图坏了都返回 `null`（界面用占位图）。
 *
 * 按曲目 id 缓存一份：刷新小部件是常事（切歌、暂停、改随机 / 循环都会走一遍），
 * 每次都读盘 + 解码太亏；曲目没变就一直是同一张图。
 */
private fun widgetArtwork(ready: Boolean): Bitmap? {
    val trackId = if (ready) PlaybackBridge.trackId() else 0L
    synchronized(artworkLock) {
        if (trackId == cachedArtworkTrackId) return cachedArtwork
        val bitmap = runCatching { decodeArtwork(PlaybackBridge.coverBytes()) }.getOrNull()
        cachedArtworkTrackId = trackId
        cachedArtwork = bitmap
        return bitmap
    }
}

/** 点整块进 App。 */
private fun contentPendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
    context,
    REQUEST_CONTENT,
    Intent(context, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
)

/**
 * 右上角齿轮 → 小部件设置页。
 *
 * 它是个**原生**页面（不是 Flutter 里的某一页）：用户点齿轮时 Flutter 引擎可能压根
 * 没起来，而这一页只做三件小事，不该为此把整个引擎拉起来。
 */
private fun settingsPendingIntent(context: Context): PendingIntent = PendingIntent.getActivity(
    context,
    REQUEST_SETTINGS,
    Intent(context, WidgetSettingsActivity::class.java)
        .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
)

/**
 * 按钮 → 播放服务。与通知栏按钮用的是同一组 ACTION，
 * 所以「上一曲 / 播放暂停 / 下一曲」的含义只定义了一次。
 *
 * 用 `getService` 而不是 `getBroadcast`：服务被叫醒之后会顺手刷新通知与小部件，
 * 状态更新就还是只有服务一个出口。
 *
 * 请求码必须各不相同：PendingIntent 的复用是按 (requestCode, intent 的 action, ...)
 * 匹配的，共用请求码会让两个按钮指向同一个 PendingIntent。
 */
private fun servicePendingIntent(
    context: Context,
    action: String,
    requestCode: Int,
): PendingIntent = PendingIntent.getService(
    context,
    requestCode,
    Intent(context, PlaybackService::class.java).setAction(action),
    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
)

private const val REQUEST_CONTENT = 100
private const val REQUEST_PREVIOUS = 101
private const val REQUEST_TOGGLE = 102
private const val REQUEST_NEXT = 103
private const val REQUEST_SHUFFLE = 104
private const val REQUEST_REPEAT = 105
private const val REQUEST_SETTINGS = 106

/** 一排控制按钮的 id：统一染色用，加按钮时记得也加到这里。 */
private val ACTION_BUTTON_IDS = listOf(
    R.id.widget_previous,
    R.id.widget_toggle,
    R.id.widget_next,
    R.id.widget_shuffle,
    R.id.widget_repeat,
)

/** 一行式布局里封面那个框有多宽：留出余量，用户才能把封面调得比默认更大。 */
private const val ROW_COVER_BOX_DP = 62

/** 一行式布局里封面之外的固定开销：上下边距（见 widget_row.xml）。 */
private const val ROW_CONTROLS_DP = 6

/** 卡片式布局里，封面之外的固定开销：歌名 + 44dp 的按钮行 + 边距。 */
private const val CARD_CONTROLS_DP = 74
