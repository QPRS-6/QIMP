// 小部件「一行还是两行」的判定：纯函数，不碰 Android 运行时
// （`cd app/android && ./gradlew :app:testDebugUnitTest`）。
//
// 为什么值得测：这条线划错不会崩，只会让 2×2 的小部件长成一行式——
// 按钮挤在歌名下面、封面只剩一条缝，而这事只有真机上把四种尺寸都摆一遍才看得出来。
package com.qprs.musicplayer

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackWidgetTest {

    @Test
    fun `一格高是一行式`() {
        // 40dp 是文档里「一格」的最小高度。
        assertEquals(WidgetShape.Row, widgetShape(40))
    }

    @Test
    fun `两格高是卡片式`() {
        assertEquals(WidgetShape.Card, widgetShape(110))
    }

    @Test
    fun `门槛上下只差一 dp 也要分开`() {
        assertEquals(WidgetShape.Row, widgetShape(CARD_MIN_HEIGHT_DP - 1))
        assertEquals(WidgetShape.Card, widgetShape(CARD_MIN_HEIGHT_DP))
    }

    @Test
    fun `用户把一行拉高之后会变成卡片式`() {
        // 实际高度说了算：2×1 被拉成 2×2 就该长成两行。
        assertEquals(WidgetShape.Row, widgetShape(70))
        assertEquals(WidgetShape.Card, widgetShape(140))
    }

    @Test
    fun `拿不到尺寸时按一行式处理`() {
        assertEquals(WidgetShape.Row, widgetShape(0))
    }
}

/**
 * 封面大小的换算（[coverSizeDp]）：纯函数，宿主机上就能跑。
 *
 * 这条线算错的后果很具体：封面按比例长过头，下面的按钮被挤出小部件边界——
 * RemoteViews 溢出是直接裁掉，不报错，用户看到的就是「按钮怎么没了」。
 */
class WidgetCoverSizeTest {

    /** 设置页预览里的那个框子：宽 320dp、高 96dp（170dp 的框减掉歌名与按钮那两行）。 */
    private val previewBox = 320 to 96

    @Test
    fun `默认比例是可用空间的七成`() {
        // 较小的那一边是 96，它的 70% 是 67.2 → 67。
        assertEquals(67, coverSizeDp(100, previewBox.first, previewBox.second))
    }

    @Test
    fun `调到最小最大都能看出变化`() {
        assertEquals(40, coverSizeDp(WidgetSettings.MIN_COVER_PERCENT, 320, 96))
        assertEquals(96, coverSizeDp(WidgetSettings.MAX_COVER_PERCENT, 320, 96))
    }

    @Test
    fun `比例超出范围时按边界算`() {
        assertEquals(coverSizeDp(WidgetSettings.MAX_COVER_PERCENT, 320, 96), coverSizeDp(999, 320, 96))
        assertEquals(coverSizeDp(WidgetSettings.MIN_COVER_PERCENT, 320, 96), coverSizeDp(1, 320, 96))
    }

    @Test
    fun `绝不会超过可用空间`() {
        // 2×2 只给了 110dp 出头，扣掉歌名与按钮那两行只剩 36dp：封面必须让位给按钮。
        assertEquals(36, coverSizeDp(WidgetSettings.MAX_COVER_PERCENT, 200, 36))
    }

    @Test
    fun `框子量不出来时给 0，调用方保留 XML 默认样子`() {
        assertEquals(0, coverSizeDp(100, 0, 96))
        assertEquals(0, coverSizeDp(100, 320, 0))
    }

    @Test
    fun `可用空间比最小尺寸还小时不越界`() {
        // 极窄的小部件：宁可给一个很小的图，也不能算出负数或者超过可用空间。
        assertEquals(12, coverSizeDp(100, 12, 40, minDp = 24))
    }
}
