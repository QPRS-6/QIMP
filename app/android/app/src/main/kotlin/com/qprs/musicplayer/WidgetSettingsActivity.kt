package com.qprs.musicplayer

import android.app.Activity
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * 小部件右上角齿轮点进来的设置页：封面大小、按钮颜色、标题颜色，**带实时预览**。
 *
 * 为什么是原生页面而不是 Flutter 里的一页：小部件属于平台侧，用户点齿轮时
 * Flutter 引擎可能压根没起来（App 已被划掉）；为改个颜色把整个引擎拉起来的代价不对等。
 *
 * 三个约定：
 * 1. **改完立刻生效**（没有「保存」按钮）：每一处改动都写进 [WidgetSettings]，
 *    然后重画预览 + 桌面上所有小部件（[updatePlaybackWidgets]）。用户不用猜存了没。
 * 2. **预览就是那份布局本尊**：直接把 `widget_card.xml` inflate 进预览框，
 *    而不是照着它再画一遍——照着画，早晚会和真的长不一样。
 * 3. 颜色**预设 + R/G/B 滑块**并存：预设解决最常用的那几个色，滑块解决
 *    「我就要壁纸上那个色」；只有预设会觉得被限制，只有滑块则调个白色要滑三下。
 */
class WidgetSettingsActivity : Activity() {

    private lateinit var coverValue: TextView
    private lateinit var coverSeek: SeekBar
    private lateinit var buttonEditor: ColorEditor
    private lateinit var titleEditor: ColorEditor

    /** 预览里的控件，来自 widget_card 那一份布局。 */
    private lateinit var previewTitle: TextView
    private lateinit var previewArt: ImageView
    private val previewButtons = mutableListOf<ImageView>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_widget_settings)

        inflatePreview()

        buttonEditor = ColorEditor(
            findViewById(R.id.button_color_editor),
            WidgetSettings.buttonColor(this),
        ) { color ->
            WidgetSettings.saveButtonColor(this, color)
            markChips(R.id.button_colors, color)
            applyAppearance()
        }
        titleEditor = ColorEditor(
            findViewById(R.id.title_color_editor),
            WidgetSettings.titleColor(this),
        ) { color ->
            WidgetSettings.saveTitleColor(this, color)
            markChips(R.id.title_colors, color)
            applyAppearance()
        }
        fillChips(R.id.button_colors) { color ->
            WidgetSettings.saveButtonColor(this, color)
            buttonEditor.setColor(color)
            markChips(R.id.button_colors, color)
            applyAppearance()
        }
        fillChips(R.id.title_colors) { color ->
            WidgetSettings.saveTitleColor(this, color)
            titleEditor.setColor(color)
            markChips(R.id.title_colors, color)
            applyAppearance()
        }
        setUpCoverSlider()

        findViewById<View>(R.id.reset).setOnClickListener {
            WidgetSettings.reset(this)
            coverSeek.progress = progressOf(WidgetSettings.coverPercent(this))
            buttonEditor.setColor(WidgetSettings.buttonColor(this))
            titleEditor.setColor(WidgetSettings.titleColor(this))
            markChips(R.id.button_colors, WidgetSettings.buttonColor(this))
            markChips(R.id.title_colors, WidgetSettings.titleColor(this))
            applyAppearance()
        }
        applyAppearance()
    }

    /**
     * 把真正的小部件布局 inflate 进预览框。
     *
     * 预览用**卡片式**那一份：封面、歌名、整排按钮它都摆全了，要看的就这三样。
     * 歌名换成一行示例文字——预览里写着「ro.qprs.musicplayer」只会让人以为改错了东西。
     */
    private fun inflatePreview() {
        val container = findViewById<FrameLayout>(R.id.preview)
        layoutInflater.inflate(R.layout.widget_card, container, true)
        previewTitle = container.findViewById(R.id.widget_title)
        previewTitle.text = getString(R.string.widget_settings_preview_track)
        previewArt = container.findViewById(R.id.widget_art)
        PREVIEW_BUTTON_IDS.forEach { id ->
            container.findViewById<ImageView>(id)?.let(previewButtons::add)
        }
    }

    /**
     * 预览跟着设置走。
     *
     * 封面大小用的是**和桌面上同一个** [coverSizeDp]：预览里量已经布局完的真实像素，
     * 桌面上量不到就按启动器报的尺寸估算。两边同一个公式，预览才不会骗人。
     */
    private fun refreshPreview() {
        previewTitle.setTextColor(WidgetSettings.titleColor(this))
        // 用 imageTintList 而不是 setColorFilter：后者在 API 29 起就废弃了。
        val tint = ColorStateList.valueOf(WidgetSettings.buttonColor(this))
        previewButtons.forEach { it.imageTintList = tint }

        val boxWidth = previewArt.width
        val boxHeight = previewArt.height
        if (boxWidth <= 0 || boxHeight <= 0) {
            // 第一次进来还没量过：等这一轮布局做完再算。
            previewArt.post { refreshPreview() }
            return
        }
        val density = resources.displayMetrics.density
        val widthDp = (boxWidth / density).roundToInt()
        val heightDp = (boxHeight / density).roundToInt()
        val size = coverSizeDp(WidgetSettings.coverPercent(this), widthDp, heightDp)
        val horizontal = dp(((widthDp - size) / 2f).roundToInt().coerceAtLeast(0))
        val vertical = dp(((heightDp - size) / 2f).roundToInt().coerceAtLeast(0))
        previewArt.setPadding(horizontal, vertical, horizontal, vertical)
    }

    // -----------------------------------------------------------------------
    // 封面大小
    // -----------------------------------------------------------------------

    private fun setUpCoverSlider() {
        // SeekBar 只认 0..max 的整数，所以把百分比平移一下（默认 100% 落在中间偏左）。
        coverSeek = findViewById(R.id.cover_seek)
        coverValue = findViewById(R.id.cover_value)
        coverSeek.max = WidgetSettings.MAX_COVER_PERCENT - WidgetSettings.MIN_COVER_PERCENT
        coverSeek.progress = progressOf(WidgetSettings.coverPercent(this))
        coverValue.text = getString(R.string.widget_settings_percent, percentOf(coverSeek.progress))
        coverSeek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                val percent = percentOf(progress)
                coverValue.text = getString(R.string.widget_settings_percent, percent)
                if (!fromUser) return
                // 拖动过程中就存下来并重画：手指还按着就能看到预览在变。
                WidgetSettings.saveCoverPercent(this@WidgetSettingsActivity, percent)
                applyAppearance()
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) = Unit

            override fun onStopTrackingTouch(seekBar: SeekBar?) = Unit
        })
    }

    private fun progressOf(percent: Int): Int =
        (percent - WidgetSettings.MIN_COVER_PERCENT).coerceIn(0, coverSeek.max)

    private fun percentOf(progress: Int): Int =
        (progress + WidgetSettings.MIN_COVER_PERCENT)
            .coerceIn(WidgetSettings.MIN_COVER_PERCENT, WidgetSettings.MAX_COVER_PERCENT)

    // -----------------------------------------------------------------------
    // 颜色
    // -----------------------------------------------------------------------

    /** 一行预设色块：点一下就用这个色，当前那个加描边。 */
    private fun fillChips(rowId: Int, onPick: (Int) -> Unit) {
        val row = findViewById<LinearLayout>(rowId)
        val current = currentColor(rowId)
        row.removeAllViews()
        COLOR_CHOICES.forEach { (color, name) ->
            val chip = View(this).apply {
                tag = color
                layoutParams = LinearLayout.LayoutParams(dp(32), dp(32)).apply { marginEnd = dp(8) }
                contentDescription = name
                setOnClickListener { onPick(color) }
            }
            row.addView(chip)
        }
        markChips(rowId, current)
    }

    private fun markChips(rowId: Int, current: Int) {
        findViewById<LinearLayout>(rowId).children().forEach { chip ->
            val color = chip.tag as Int
            chip.background = chipDrawable(color, selected = color == current)
        }
    }

    private fun currentColor(rowId: Int): Int =
        if (rowId == R.id.button_colors) WidgetSettings.buttonColor(this) else WidgetSettings.titleColor(this)

    /** 圆形色块；选中的加一圈主题色描边。 */
    private fun chipDrawable(color: Int, selected: Boolean): GradientDrawable = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        // 未选中也留一圈很淡的边，免得白色块贴在白色页面背景上看不见边界。
        setStroke(if (selected) dp(3) else dp(1), if (selected) ACCENT else 0x33000000)
    }

    /**
     * 一个颜色的编辑器：色块 + `#RRGGBB` + R/G/B 三条滑块。
     *
     * 容器由调用方给、内容由代码填——六条滑块写进 XML 只会变成两大段几乎一样的块，
     * 改一处就得记住改两处。
     */
    private inner class ColorEditor(
        parent: LinearLayout,
        initial: Int,
        private val onChanged: (Int) -> Unit,
    ) {
        private val swatch = View(this@WidgetSettingsActivity)
        private val hexLabel = TextView(this@WidgetSettingsActivity)
        private val values = IntArray(3)
        private val bars = arrayOfNulls<SeekBar>(3)
        private val numbers = arrayOfNulls<TextView>(3)

        /**
         * 回填滑块时不要把「变化」再抛回去，否则会绕圈：
         * 回填 → 触发变化 → 保存 → 又回填。
         */
        private var syncing = false

        init {
            val head = LinearLayout(this@WidgetSettingsActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(10), 0, 0)
            }
            head.addView(swatch, LinearLayout.LayoutParams(dp(28), dp(28)))
            hexLabel.apply {
                setTextSize(13f)
                setPadding(dp(10), 0, 0, 0)
                setTextColor(0xFF888888.toInt())
            }
            head.addView(hexLabel)
            parent.addView(head)

            for (channel in 0..2) {
                val row = LinearLayout(this@WidgetSettingsActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                }
                row.addView(
                    TextView(this@WidgetSettingsActivity).apply {
                        text = CHANNELS[channel]
                        width = dp(16)
                        setTextColor(0xFF888888.toInt())
                    },
                )

                val bar = SeekBar(this@WidgetSettingsActivity).apply { max = 255 }
                bar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                    override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                        values[channel] = progress
                        numbers[channel]?.text = progress.toString()
                        showSwatch()
                        if (fromUser && !syncing) onChanged(color())
                    }

                    override fun onStartTrackingTouch(seekBar: SeekBar?) = Unit

                    override fun onStopTrackingTouch(seekBar: SeekBar?) = Unit
                })
                bars[channel] = bar
                row.addView(bar, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))

                numbers[channel] = TextView(this@WidgetSettingsActivity).apply {
                    width = dp(34)
                    gravity = Gravity.END
                    setTextColor(0xFF888888.toInt())
                }
                row.addView(numbers[channel])

                parent.addView(row)
            }
            setColor(initial)
        }

        /** 回填（初值、点预设、恢复默认都走这里），**不**回调。 */
        fun setColor(color: Int) {
            syncing = true
            values[0] = Color.red(color)
            values[1] = Color.green(color)
            values[2] = Color.blue(color)
            for (channel in 0..2) {
                bars[channel]?.progress = values[channel]
                numbers[channel]?.text = values[channel].toString()
            }
            syncing = false
            showSwatch()
        }

        private fun color(): Int = Color.rgb(values[0], values[1], values[2])

        private fun showSwatch() {
            swatch.background = chipDrawable(color(), selected = false).apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(6).toFloat()
            }
            hexLabel.text = String.format("#%02X%02X%02X", values[0], values[1], values[2])
        }
    }

    // -----------------------------------------------------------------------

    /** 外观变了：先把预览画好，再让桌面上所有小部件重画一遍。 */
    private fun applyAppearance() {
        refreshPreview()
        updatePlaybackWidgets(this)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private fun LinearLayout.children(): List<View> = (0 until childCount).map { getChildAt(it) }

    private companion object {
        /** 主题色，与 App 里那个 teal 种子色一致。 */
        val ACCENT = Color.parseColor("#FF4DB6AC")

        /** RGB 三条滑块的字母：通用，不用翻译。 */
        val CHANNELS = listOf("R", "G", "B")

        /** 可选的按钮 / 标题颜色。第一个是默认的白色。 */
        val COLOR_CHOICES = listOf(
            Color.WHITE to "白色",
            Color.BLACK to "黑色",
            Color.parseColor("#FF4DB6AC") to "青色",
            Color.parseColor("#FFEF5350") to "红色",
            Color.parseColor("#FFFFB300") to "橙色",
            Color.parseColor("#FF42A5F5") to "蓝色",
            Color.parseColor("#FFAB47BC") to "紫色",
            Color.parseColor("#FF9E9E9E") to "灰色",
        )

        /** 预览里要跟着染色的按钮（随机 · 上一曲 · 播放 · 下一曲 · 循环 · 齿轮）。 */
        val PREVIEW_BUTTON_IDS = listOf(
            R.id.widget_shuffle,
            R.id.widget_previous,
            R.id.widget_toggle,
            R.id.widget_next,
            R.id.widget_repeat,
            R.id.widget_settings,
        )
    }
}
