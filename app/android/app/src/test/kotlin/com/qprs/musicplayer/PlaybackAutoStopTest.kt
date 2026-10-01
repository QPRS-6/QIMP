// 「音量归零 / 蓝牙断开自动暂停」的判定部分：全是纯函数，不碰 Android 运行时，
// 所以在宿主机上就能跑（`cd app/android && ./gradlew :app:testDebugUnitTest`）。
//
// 为什么值得给这几行逻辑写测试：规则写反了照样编得过、照样装得上，
// 而真机上得插拔真耳机才看得出来——等发现时用户已经被外放吵到了。
package com.qprs.musicplayer
import android.media.AudioDeviceInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackAutoStopTest {

    // 设备类型取成短名字，用例读起来更像在说人话。
    private val a2dp = AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
    private val sco = AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    private val bleHeadset = AudioDeviceInfo.TYPE_BLE_HEADSET
    private val speaker = AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
    private val wired = AudioDeviceInfo.TYPE_WIRED_HEADPHONES
    private val usb = AudioDeviceInfo.TYPE_USB_HEADSET

    @Test
    fun `音量归零才暂停`() {
        assertTrue(shouldPauseOnVolume(0))
        assertFalse(shouldPauseOnVolume(1))
        assertFalse(shouldPauseOnVolume(94))
    }

    @Test
    fun `读不到音量时不能当成静音`() {
        // 读失败给的是负数哨兵；这里要是判成「静音」，用户正听着歌就会被莫名暂停。
        assertFalse(shouldPauseOnVolume(-1))
        assertFalse(shouldPauseOnVolume(Int.MIN_VALUE))
    }

    @Test
    fun `蓝牙输出断开后就该暂停`() {
        assertTrue(bluetoothOutputGone(listOf(a2dp), listOf(speaker)))
        assertTrue(bluetoothOutputGone(listOf(bleHeadset), listOf(speaker, wired)))
    }

    @Test
    fun `走掉的是有线耳机时不归这条规则管`() {
        // 有线耳机拔出由 ACTION_AUDIO_BECOMING_NOISY 那条广播负责，这里别抢活。
        assertFalse(bluetoothOutputGone(listOf(wired), listOf(speaker)))
    }

    @Test
    fun `还有别的蓝牙输出连着就不算蓝牙断了`() {
        // 手机同时接着耳机与音箱：只走了一个，声音还有地方去。
        assertFalse(bluetoothOutputGone(listOf(a2dp), listOf(speaker, sco)))
    }

    @Test
    fun `一次走掉多个设备时只看有没有蓝牙输出`() {
        assertTrue(bluetoothOutputGone(listOf(usb, a2dp), listOf(speaker)))
        // 反过来：全是非蓝牙设备（比如拔了 USB 声卡）就不该停。
        assertFalse(bluetoothOutputGone(listOf(usb, wired), listOf(speaker)))
    }

    @Test
    fun `哪些类型算蓝牙输出`() {
        assertTrue(isBluetoothOutput(a2dp))
        assertTrue(isBluetoothOutput(sco))
        assertTrue(isBluetoothOutput(bleHeadset))
        assertFalse(isBluetoothOutput(speaker))
        assertFalse(isBluetoothOutput(wired))
        assertFalse(isBluetoothOutput(usb))
        assertFalse(isBluetoothOutput(AudioDeviceInfo.TYPE_HDMI))
    }
}
