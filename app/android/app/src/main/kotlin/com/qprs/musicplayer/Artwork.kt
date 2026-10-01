package com.qprs.musicplayer

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import kotlin.math.roundToInt

/**
 * 播放通知 / 锁屏 / 车机上那张封面。
 *
 * 分成两半：
 * - [artworkTargetSize] 是**纯函数**（缩放尺寸怎么算），宿主机上就能测；
 * - [decodeArtwork] 把 Rust 给的原始字节解成 Bitmap，并按上限缩小。
 *
 * 为什么必须缩小：内嵌封面动辄 1400×1400，原图直接塞进 `MediaSession` 的元数据，
 * 系统那边每查一次都要走一次 Parcel，很容易撞上 `TransactionTooLargeException`
 * （现象是通知栏干脆不显示这首歌）。而通知上那张图只有几十 dp，
 * 缩到 [ARTWORK_MAX_PX] 看不出任何差别。
 */
internal const val ARTWORK_MAX_PX = 512

/**
 * 封面要缩成多大（长边 = [max]，等比）；**不需要缩**（本来就够小）或尺寸不合法时返回 null。
 *
 * 竖图按高算、横图按宽算：取的是长边，不然一边缩到位另一边就超了。
 */
internal fun artworkTargetSize(
    width: Int,
    height: Int,
    max: Int = ARTWORK_MAX_PX,
): Pair<Int, Int>? {
    if (width <= 0 || height <= 0 || max <= 0) return null
    val longest = maxOf(width, height)
    if (longest <= max) return null
    val scale = max.toDouble() / longest
    return (width * scale).roundToInt().coerceAtLeast(1) to
        (height * scale).roundToInt().coerceAtLeast(1)
}

/**
 * 封面字节 → Bitmap；没有封面（空数组）或解不出来时返回 `null`。
 *
 * 解不出来不算错误：内嵌的「封面」偶尔是坏数据或者根本不是图片，
 * 那种情况下通知应该照常显示，只是没有图。
 */
internal fun decodeArtwork(bytes: ByteArray?, max: Int = ARTWORK_MAX_PX): Bitmap? {
    if (bytes == null || bytes.isEmpty()) return null
    val decoded = runCatching {
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }.getOrNull() ?: return null

    val (width, height) = artworkTargetSize(decoded.width, decoded.height, max) ?: return decoded
    val scaled = runCatching {
        Bitmap.createScaledBitmap(decoded, width, height, true)
    }.getOrNull() ?: return decoded

    // 缩出来了就把原图还回去：那张大图留着纯占内存（一首歌几十 MB，换几首就吃紧了）。
    decoded.recycle()
    return scaled
}
