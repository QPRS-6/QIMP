// 通知栏封面「缩到多大」的判定：纯函数，不碰 Android 运行时，宿主机上就能跑
// （`cd app/android && ./gradlew :app:testDebugUnitTest`）。
//
// 为什么值得测：这张图的尺寸算错不会崩，只会在某些手机上表现为
// 「通知栏没有封面」或者「通知干脆不显示」——`TransactionTooLargeException`
// 只在真机上、只有大封面时才出现，等用户报上来就太晚了。
package com.qprs.musicplayer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ArtworkTest {

    @Test
    fun `横图按长边缩到上限`() {
        // 1600×1200 → 长边 1600 缩到 512，高按比例走。
        assertEquals(512 to 384, artworkTargetSize(1600, 1200))
    }

    @Test
    fun `竖图也按长边算，不是只缩宽度`() {
        // 1200×1600：只缩宽度的话高度会留在 1600，照样能把 Parcel 撑爆。
        assertEquals(384 to 512, artworkTargetSize(1200, 1600))
    }

    @Test
    fun `正方形图缩到上限`() {
        assertEquals(512 to 512, artworkTargetSize(1400, 1400))
    }

    @Test
    fun `本来就够小的图不缩`() {
        // 返回 null 表示「不用缩」：省掉一次没必要的内存拷贝。
        assertNull(artworkTargetSize(300, 300))
        assertNull(artworkTargetSize(512, 512))
    }

    @Test
    fun `极小或非法的尺寸不缩`() {
        assertNull(artworkTargetSize(0, 100))
        assertNull(artworkTargetSize(100, -1))
        assertNull(artworkTargetSize(100, 100, max = 0))
    }

    @Test
    fun `缩到再小也要留至少一个像素`() {
        // 极端长条图（比如 2000×1）缩完高度会算成 0，Bitmap 直接抛异常。
        assertEquals(512 to 1, artworkTargetSize(2000, 1))
    }
}
