"""Scenario tests for lisp/hatso_vezerlo.lisp and lisp/elso_vezerlo.lisp.

Run:  python3 -m unittest discover -s tests -v
"""
import os
import unittest

from lbm_sim import Interp, Blocked, xiaomi_frame, check_xiaomi_crc

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAR = os.path.join(ROOT, "lisp", "hatso_vezerlo.lisp")
FRONT = os.path.join(ROOT, "lisp", "elso_vezerlo.lisp")

IDLE = 0x2C      # ~0.57 V, under adc-v1-start (0.8 V) -> 0.0
FULL = 0xA0      # ~2.07 V, over adc-v1-end (2.0 V) -> 1.0
STEP = 0.02


class Rear:
    def __init__(self):
        self.i = Interp()
        self.v = self.i.vesc
        self.i.load(REAR)
        self.i.call("init")
        self.v.tx.clear()
        self.thr = IDLE
        self.brk = IDLE

    def feed(self, frame_bytes):
        self.v.rx.extend(frame_bytes)
        try:
            self.i.call("rx-loop")
        except Blocked:
            pass

    def lever_frame(self, cmd=0x65):
        self.feed(xiaomi_frame(0x20, cmd, 0x00, [0x04, self.thr, self.brk, 0x00, 0x00]))

    def step(self, n=1, frames=True):
        """n control cycles of 20 ms, with a dash frame before each one."""
        for _ in range(n):
            if frames:
                self.lever_frame()
            self.i.call("control-step")
            self.v.now += STEP

    def kmh(self, value):
        self.v.speed_ms = value / 3.6

    def g(self, name):
        return self.i.get(name)

    def last_dash(self):
        n = len(self.v.tx)
        self.v.now += 0.05
        self.lever_frame(cmd=0x64)
        return self.v.tx[-1] if len(self.v.tx) > n else None

    def boot_p1(self):
        self.step(int(2.3 / STEP))

    def boot_p2(self):
        self.thr = FULL
        self.step(int(1.0 / STEP))


class ProtocolTests(unittest.TestCase):
    def test_lever_frame_overrides_adc_and_gets_dash_reply(self):
        r = Rear()
        r.thr, r.brk = 0x50, 0x60
        r.lever_frame(cmd=0x65)
        self.assertAlmostEqual(r.v.override[0], 0x50 / 77.27, places=4)
        self.assertAlmostEqual(r.v.override[1], 0x60 / 77.27, places=4)
        self.assertEqual(len(r.v.tx), 1, "no 0x64 seen yet, so 0x65 is answered")
        f = list(r.v.tx[0])
        self.assertEqual(f[:6], [0x55, 0xAA, 0x08, 0x21, 0x64, 0x00])
        self.assertTrue(check_xiaomi_crc(f))
        self.assertEqual(f[6], 1)    # D mode
        self.assertEqual(f[7], 50)   # battery %
        self.assertEqual(f[8], 0)    # light off
        self.assertEqual(f[10], 0)   # speed

    def test_only_0x64_answered_once_dash_sends_it(self):
        r = Rear()
        r.lever_frame(cmd=0x64)
        self.assertEqual(len(r.v.tx), 1)
        r.v.now += 0.05
        r.lever_frame(cmd=0x65)
        self.assertEqual(len(r.v.tx), 1, "0x65 must not be answered while 0x64 arrives")
        r.v.now += 0.05
        r.lever_frame(cmd=0x64)
        self.assertEqual(len(r.v.tx), 2)

    def test_reply_rate_limited(self):
        r = Rear()
        r.lever_frame(cmd=0x64)
        r.lever_frame(cmd=0x64)
        self.assertEqual(len(r.v.tx), 1)

    def test_own_echo_bad_crc_and_garbage_ignored(self):
        r = Rear()
        echo = xiaomi_frame(0x21, 0x64, 0x00, [1, 50, 0, 0, 0, 0])
        r.feed(echo)
        self.assertEqual(r.v.tx, [])
        self.assertEqual(r.v.override[0], 0.0)
        bad = xiaomi_frame(0x20, 0x65, 0x00, [0x04, 0x90, 0x2C, 0, 0])
        bad[-1] ^= 0xFF
        r.feed(bad)
        self.assertEqual(r.v.override[0], 0.0)
        r.thr = 0x70
        r.feed([0x00, 0x55, 0x13, 0xAA, 0x55])  # junk, also a lone 0x55
        r.lever_frame()
        self.assertAlmostEqual(r.v.override[0], 0x70 / 77.27, places=4)

    def test_app_read_frame_levers_one_byte_later(self):
        r = Rear()
        r.feed(xiaomi_frame(0x20, 0x61, 0xB0, [0x20, 0x02, 0x80, 0x40, 0x00]))
        self.assertAlmostEqual(r.v.override[0], 0x80 / 77.27, places=4)
        self.assertAlmostEqual(r.v.override[1], 0x40 / 77.27, places=4)

    def test_rx_buffer_large_enough_for_longest_frame(self):
        r = Rear()
        r.feed(xiaomi_frame(0x20, 0x01, 0x10, list(range(56))))  # len 58
        r.lever_frame()
        self.assertAlmostEqual(r.v.override[0], IDLE / 77.27, places=4)


class ProfileTests(unittest.TestCase):
    def test_init_state(self):
        r = Rear()
        self.assertTrue(r.v.output_disabled)
        self.assertEqual(r.v.detached, (3, 1))
        self.assertEqual(r.v.uart_started, (115200, "half-duplex"))
        self.assertEqual(r.v.gpio["pin-ppm"], 1, "tail light on from boot")
        self.assertEqual(r.v.gpio["pin-adc2"], 0, "headlight off at boot")
        self.assertEqual(r.v.gpio_mode["pin-adc1"], "pin-mode-analog")
        self.assertAlmostEqual(r.v.conf["max-speed"], 20 / 3.6)  # P1 D until decided

    def test_no_throttle_selects_profile1(self):
        r = Rear()
        r.step(int(1.5 / STEP))
        self.assertEqual(r.g("profile"), 0)
        self.assertTrue(r.v.output_disabled)
        r.step(int(0.8 / STEP))
        self.assertEqual(r.g("profile"), 1)
        self.assertEqual(r.g("state"), "run")
        self.assertFalse(r.v.output_disabled)
        self.assertAlmostEqual(r.v.conf["max-speed"], 20 / 3.6)
        self.assertEqual(r.v.conf["l-watt-max"], 300.0)
        self.assertEqual(r.v.conf["l-current-max-scale"], 1.0)

    def test_dash_boot_frames_do_not_start_window(self):
        r = Rear()
        r.thr = r.brk = 0x0A  # dash still booting
        r.step(int(3.0 / STEP))
        self.assertEqual(r.g("profile"), 0, "window starts at first real lever value")
        r.thr = r.brk = IDLE
        r.step(int(2.3 / STEP))
        self.assertEqual(r.g("profile"), 1)

    def test_no_dash_falls_back_to_profile1(self):
        r = Rear()
        r.step(int(6.5 / STEP), frames=False)
        self.assertEqual(r.g("profile"), 1)

    def test_throttle_held_selects_profile2_and_waits_for_release(self):
        r = Rear()
        r.thr = FULL
        r.step(int(0.4 / STEP))
        self.assertEqual(r.g("profile"), 0, "must be held 0.5 s")
        r.step(int(0.3 / STEP))
        self.assertEqual(r.g("profile"), 2)
        self.assertEqual(r.g("state"), "release")
        self.assertTrue(r.v.output_disabled, "no output while throttle still held")
        r.step(int(1.0 / STEP))
        self.assertEqual(sum(f[9] for f in r.v.tx), 2, "two beeps for profile 2")
        self.assertTrue(r.v.output_disabled)
        r.thr = IDLE
        r.step(int(0.5 / STEP))
        self.assertEqual(r.g("state"), "run")
        self.assertFalse(r.v.output_disabled)

    def test_short_throttle_blip_is_not_profile2(self):
        r = Rear()
        r.thr = FULL
        r.step(int(0.3 / STEP))
        r.thr = IDLE
        r.step(2)
        r.thr = FULL
        r.step(int(0.3 / STEP))
        r.thr = IDLE
        r.step(int(2.0 / STEP))
        self.assertEqual(r.g("profile"), 1)

    def test_profile2_limits_and_front_frame(self):
        r = Rear()
        r.boot_p2()
        self.assertAlmostEqual(r.v.conf["max-speed"], 1000 / 3.6)
        self.assertEqual(r.v.conf["l-current-max-scale"], 0.6)  # D: 60 %
        self.assertEqual(r.v.conf["l-watt-max"], 1500000.0)
        sid, data = r.v.can_tx[-1]
        self.assertEqual(sid, 0x4D0)
        self.assertEqual(list(data), [0xA5, 3, 60, 10000 >> 8, 10000 & 0xFF,
                                      15000 >> 8, 15000 & 0xFF, 2])


class KickStartTests(unittest.TestCase):
    def test_profile1_needs_3kmh_kick(self):
        r = Rear()
        r.boot_p1()
        r.thr = FULL
        r.step(5)
        self.assertAlmostEqual(r.v.override[0], 0.8, msg="throttle held at ADC start voltage")
        self.assertEqual(r.v.decoded(0), 0.0)
        r.kmh(2.5)
        r.step(5)
        self.assertEqual(r.v.decoded(0), 0.0)
        r.kmh(3.2)
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], FULL / 77.27, places=4)
        r.kmh(1.5)
        r.step(5)
        self.assertAlmostEqual(r.v.override[0], FULL / 77.27, places=4, msg="stays engaged above 1 km/h")
        r.kmh(0.5)
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], 0.8)

    def test_brake_never_gated(self):
        r = Rear()
        r.boot_p1()
        r.brk = FULL
        r.step(2)
        self.assertAlmostEqual(r.v.override[1], FULL / 77.27, places=4)

    def test_released_throttle_passes_through_when_gated(self):
        r = Rear()
        r.boot_p1()
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], IDLE / 77.27, places=4)

    def test_inverted_calibration_gates_the_other_way(self):
        r = Rear()
        r.v.conf["adc-v1-start"], r.v.conf["adc-v1-end"] = 2.0, 0.8
        r.i.call("refresh-gate")
        r.thr = 0x9C  # released lever is at the high end when inverted
        r.boot_p1()
        self.assertEqual(r.g("profile"), 1)
        r.thr = 0x20  # low voltage = full throttle when inverted
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], 2.0)

    def test_profile2_no_kick_needed(self):
        r = Rear()
        r.boot_p2()
        r.thr = IDLE
        r.step(int(0.5 / STEP))
        r.thr = FULL
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], FULL / 77.27, places=4)


class ButtonTests(unittest.TestCase):
    def press(self, r, secs):
        r.v.adc[0] = 0.0
        r.step(max(1, int(secs / STEP)))
        r.v.adc[0] = 3.3
        r.step(1)

    def test_single_click_toggles_headlight(self):
        r = Rear()
        r.boot_p1()
        self.press(r, 0.1)
        r.step(int(0.5 / STEP))
        self.assertTrue(r.g("light"))
        self.assertEqual(r.v.gpio["pin-adc2"], 1)
        self.assertEqual(r.last_dash()[8], 1)
        self.press(r, 0.1)
        r.step(int(0.5 / STEP))
        self.assertEqual(r.v.gpio["pin-adc2"], 0)

    def test_double_click_cycles_modes(self):
        r = Rear()
        r.boot_p1()
        self.press(r, 0.08)
        r.step(3)
        self.press(r, 0.08)
        r.step(int(0.5 / STEP))
        self.assertEqual(r.g("speedmode"), 4)
        self.assertAlmostEqual(r.v.conf["max-speed"], 25 / 3.6)
        self.assertEqual(r.v.conf["l-watt-max"], 500.0)
        self.assertEqual(r.g("light"), None, "double click must not toggle the light")
        self.assertEqual(r.last_dash()[6], 4)
        for _ in range(2):
            self.press(r, 0.08)
            r.step(3)
        self.press(r, 0.08)
        r.step(int(0.5 / STEP))
        self.assertEqual(r.g("speedmode"), 2)
        self.assertAlmostEqual(r.v.conf["max-speed"], 6 / 3.6)
        self.assertEqual(r.v.conf["l-watt-max"], 100.0)
        for _ in range(2):
            self.press(r, 0.08)
            r.step(3)
        r.step(int(0.5 / STEP))
        self.assertEqual(r.g("speedmode"), 1)

    def test_long_press_does_nothing(self):
        r = Rear()
        r.boot_p1()
        self.press(r, 2.0)
        r.step(int(0.6 / STEP))
        self.assertEqual(r.g("light"), None)
        self.assertEqual(r.g("speedmode"), 1)

    def test_single_noise_sample_ignored(self):
        r = Rear()
        r.boot_p1()
        r.v.adc[0] = 0.0
        r.step(1)
        r.v.adc[0] = 3.3
        r.step(int(0.6 / STEP))
        self.assertEqual(r.g("light"), None)


class BrakeLightTests(unittest.TestCase):
    def test_steady_then_blinking_while_braking(self):
        r = Rear()
        r.boot_p1()
        self.assertEqual(r.v.gpio["pin-ppm"], 1)
        r.brk = FULL
        seen = []
        for _ in range(30):
            r.step(1)
            seen.append(r.v.gpio["pin-ppm"])
        self.assertEqual(seen[0], 0, "goes dark immediately so the change is visible")
        changes = sum(1 for a, b in zip(seen, seen[1:]) if a != b)
        self.assertGreaterEqual(changes, 4, seen)
        r.brk = IDLE
        r.step(2)
        self.assertEqual(r.v.gpio["pin-ppm"], 1)

    def test_stale_brake_does_not_blink(self):
        r = Rear()
        r.boot_p1()
        r.brk = FULL
        r.step(1)
        r.step(int(1.0 / STEP), frames=False)
        self.assertEqual(r.v.gpio["pin-ppm"], 1)


class DisplayTests(unittest.TestCase):
    def test_profile1_shows_speed(self):
        r = Rear()
        r.boot_p1()
        r.kmh(0.0)
        self.assertEqual(r.last_dash()[10], 0)
        r.kmh(18.6)
        self.assertEqual(r.last_dash()[10], 19)

    def test_profile2_shows_battery_at_standstill(self):
        r = Rear()
        r.boot_p2()
        r.v.batt = 0.83
        r.kmh(0.3)
        self.assertEqual(r.last_dash()[10], 83)
        r.kmh(12.0)
        self.assertEqual(r.last_dash()[10], 12)

    def test_battery_and_temperature_icon(self):
        r = Rear()
        r.boot_p1()
        r.v.batt = 1.2
        r.v.temp_fet = 85.0
        r.step(int(0.6 / STEP))
        f = r.last_dash()
        self.assertEqual(f[7], 100)
        self.assertEqual(f[6], 1 + 128)
        r.v.temp_fet = 40.0
        r.v.can_devs = [12]
        r.v.can_temp_mot[12] = 105.0
        r.step(int(0.6 / STEP))
        self.assertEqual(r.last_dash()[6], 1 + 128, "front motor temperature counts too")

    def test_startup_beeps(self):
        r = Rear()
        r.boot_p1()
        for _ in range(4):
            r.last_dash()
        self.assertEqual(sum(f[9] for f in r.v.tx), 1)
        r2 = Rear()
        r2.boot_p2()
        for _ in range(4):
            r2.last_dash()
        self.assertEqual(sum(f[9] for f in r2.v.tx), 2)

    def test_fault_and_front_warning_codes(self):
        r = Rear()
        r.v.can_devs = [12]
        r.boot_p1()
        r.step(int(3.0 / STEP))
        self.assertEqual(r.last_dash()[11], 50, "front ESC present but silent")
        ack = bytearray([0xA5, 0, 100])
        r.i.call("on-front-ack", 0x4D1, ack)
        r.step(int(0.6 / STEP))
        self.assertEqual(r.last_dash()[11], 0)
        r.v.fault = 2
        self.assertEqual(r.last_dash()[11], 2)


class FrontTests(unittest.TestCase):
    def setUp(self):
        self.f = Interp()
        self.fv = self.f.vesc
        self.f.load(FRONT)
        self.f.call("init")

    def test_disabled_at_boot(self):
        self.assertEqual(self.fv.conf["l-current-max-scale"], 0.0)
        self.assertEqual(self.fv.conf["l-current-min-scale"], 0.0)

    def test_rear_frames_drive_front_limits(self):
        r = Rear()
        r.boot_p2()
        sid, data = r.v.can_tx[-1]
        self.f.call("on-cmd", bytearray(data))
        self.assertAlmostEqual(self.fv.conf["l-current-max-scale"], 0.6)
        self.assertEqual(self.fv.conf["l-current-min-scale"], 1.0)
        self.assertAlmostEqual(self.fv.conf["max-speed"], r.v.conf["max-speed"], places=3)
        self.assertEqual(self.fv.conf["l-watt-max"], r.v.conf["l-watt-max"])
        sid, ack = self.fv.can_tx[-1]
        self.assertEqual(sid, 0x4D1)
        self.assertEqual(list(ack), [0xA5, 3, 60])

        r1 = Rear()
        r1.boot_p1()
        self.f.call("on-cmd", bytearray(r1.v.can_tx[-1][1]))
        self.assertEqual(self.fv.conf["l-current-max-scale"], 0.0, "P1: front drive off")
        self.assertEqual(self.fv.conf["l-current-min-scale"], 0.0, "P1: front brake off")

    def test_timeout_disables_front(self):
        self.f.call("on-cmd", bytearray([0xA5, 3, 100, 0x27, 0x10, 0x3A, 0x98, 2]))
        self.assertEqual(self.fv.conf["l-current-max-scale"], 1.0)
        self.fv.now += 0.5
        self.f.call("watchdog-step")
        self.assertEqual(self.fv.conf["l-current-max-scale"], 1.0)
        self.fv.now += 0.6
        self.f.call("watchdog-step")
        self.assertEqual(self.fv.conf["l-current-max-scale"], 0.0)
        self.assertEqual(self.fv.conf["l-current-min-scale"], 0.0)

    def test_conf_only_written_on_change(self):
        frame = bytearray([0xA5, 3, 100, 0x27, 0x10, 0x3A, 0x98, 2])
        self.f.call("on-cmd", frame)
        n = len(self.fv.conf_log)
        for _ in range(10):
            self.f.call("on-cmd", frame)
        self.assertEqual(len(self.fv.conf_log), n)

    def test_garbage_ignored(self):
        before = dict(self.fv.conf)
        self.f.call("on-cmd", bytearray([0x00, 3, 100, 0, 0, 0, 0, 0]))
        self.f.call("on-cmd", bytearray([0xA5, 3]))
        self.assertEqual(self.fv.conf, before)


class StatusTest(unittest.TestCase):
    def test_status_runs(self):
        r = Rear()
        r.boot_p1()
        r.i.call("status")
        self.assertTrue(r.v.printed)


if __name__ == "__main__":
    unittest.main()
