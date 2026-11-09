"""Hibakód-kezelés tesztjei (lisp/hatso_vezerlo.lisp, Advanced-Balance ág).

Run:  python3 -m unittest discover -s tests -v
"""
import unittest

from test_scripts import Rear, IDLE, FULL, STEP
from test_advanced_balance import rear_p2, ab_on, tick, angle, secs, double_press

LOW = 5      # szakadás: a jel a tartomány alatt
HIGH = 250   # zárlat a tápra: a tartomány fölött

# VESC hibakód -> kijelző kód (README "Hibakódok")
EXPECTED = {
    0: 0, 1: 24, 2: 24, 3: 28, 4: 51, 5: 40, 6: 52, 7: 28, 8: 28, 9: 56, 10: 31,
    11: 18, 12: 18, 13: 18, 14: 26, 15: 11, 16: 12, 17: 13, 18: 54, 19: 28,
    20: 18, 21: 18, 22: 18, 23: 26, 24: 26, 25: 18, 26: 18, 27: 54, 28: 18,
    29: 55, 30: 18, 31: 53, 32: 53, 33: 53, 99: 69,
}


def code(r):
    f = r.last_dash()
    return f[11]


class LeverFaultTests(unittest.TestCase):
    def test_throttle_fault_14_disables_throttle_brake_still_works(self):
        r = rear_p2()
        r.thr = LOW
        r.step(int(0.5 / STEP))
        self.assertEqual(code(r), 14)
        self.assertAlmostEqual(r.v.override[0], 0.8, msg="throttle at ADC zero")
        r.brk = FULL
        r.step(2)
        self.assertAlmostEqual(r.v.override[1], FULL / 77.27, places=4, msg="brake works")
        self.assertTrue(any("HIBA 14" in str(p) for p in r.v.printed))

    def test_short_glitch_is_ignored(self):
        r = rear_p2()
        r.thr = LOW
        r.step(int(0.2 / STEP))
        r.thr = IDLE
        r.step(int(0.5 / STEP))
        self.assertEqual(code(r), 0)
        self.assertEqual(r.g("thr-fault"), None)

    def test_brake_fault_15_disables_brake_and_throttle(self):
        r = rear_p2()
        r.brk = HIGH
        r.step(int(0.5 / STEP))
        self.assertEqual(code(r), 15)
        self.assertEqual(r.v.override[1], 0.0, "no electric brake from a broken lever")
        r.thr = FULL
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], 0.8, msg="no throttle either")

    def test_both_16(self):
        r = rear_p2()
        r.thr = r.brk = LOW
        r.step(int(0.5 / STEP))
        self.assertEqual(code(r), 16)

    def test_recovery_needs_good_signal_hold_and_release(self):
        r = rear_p2()
        r.thr = HIGH
        r.step(int(0.5 / STEP))
        self.assertEqual(code(r), 14)
        r.thr = FULL  # jó jel, de a gáz nyomva
        r.step(int(1.2 / STEP))
        self.assertEqual(r.g("thr-fault"), None)
        self.assertAlmostEqual(r.v.override[0], 0.8, msg="still locked: throttle must be released")
        self.assertEqual(code(r), 14, "kept on the display for 3 s")
        r.step(int(3.2 / STEP))
        self.assertEqual(code(r), 0)
        r.thr = IDLE
        r.step(3)
        r.thr = FULL
        r.step(2)
        self.assertAlmostEqual(r.v.override[0], FULL / 77.27, places=4)

    def test_dash_boot_values_are_not_a_fault(self):
        r = Rear()
        r.thr = r.brk = 0x0A
        r.step(int(2.0 / STEP))
        self.assertEqual(code(r), 0)

    def test_shorted_throttle_at_boot_is_not_profile2(self):
        r = Rear()
        r.thr = HIGH
        r.step(int(4.0 / STEP))
        self.assertEqual(r.g("profile"), 1, "a broken throttle must not select profile 2")
        self.assertEqual(code(r), 14)

    def test_ab_toggle_refused_with_broken_brake(self):
        r = rear_p2()
        r.brk = HIGH
        r.step(int(0.5 / STEP))
        double_press(r)
        self.assertEqual(r.g("ab-on"), None)


class VescFaultTests(unittest.TestCase):
    def test_mapping_table(self):
        r = Rear()
        for f, c in EXPECTED.items():
            self.assertEqual(r.i.call("vesc-fault-code", f), c, "VESC %d" % f)

    def test_every_display_code_has_a_text(self):
        r = Rear()
        for c in set(EXPECTED.values()) | {10, 14, 15, 16, 50, 57, 58, 59}:
            text = r.i.call("error-text", c)
            if c != 69:
                self.assertNotEqual(text, "egyeb VESC hiba", c)

    def test_transient_fault_is_held_3s(self):
        r = Rear()
        r.boot_p1()
        r.v.fault = 4
        r.step(3)
        r.v.fault = 0
        r.step(int(2.0 / STEP))
        self.assertEqual(code(r), 51)
        r.step(int(1.5 / STEP))
        self.assertEqual(code(r), 0)

    def test_vesc_fault_has_priority(self):
        r = rear_p2()
        r.thr = LOW
        r.v.fault = 1
        r.step(int(0.5 / STEP))
        self.assertEqual(code(r), 24)
        r.v.fault = 0
        r.step(2)
        self.assertEqual(code(r), 14)

    def test_logged_once_with_vesc_number(self):
        r = Rear()
        r.boot_p1()
        r.v.fault = 14
        r.step(int(1.0 / STEP))
        lines = [str(p) for p in r.v.printed if "HIBA 26" in str(p)]
        self.assertEqual(len(lines), 1)
        self.assertIn("VESC hibakod 14", lines[0])

    def test_no_false_error_at_boot(self):
        r = Rear()
        r.boot_p1()
        self.assertEqual(code(r), 0)


class FrontAndBalanceTests(unittest.TestCase):
    def test_front_fault_57(self):
        r = rear_p2()
        r.v.can_devs = [12]
        for _ in range(10):
            r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, 3, 60, 6]))
            r.step(1)
        self.assertEqual(code(r), 57)

    def test_balance_cutoff_58_for_3s(self):
        r = ab_on()
        r.thr = FULL
        angle(r, 0.0, roll=61.0)
        tick(r, 3)
        angle(r, 0.0)
        r.thr = IDLE
        tick(r, secs(1.0))
        self.assertEqual(code(r), 58)
        tick(r, secs(2.5))
        self.assertEqual(code(r), 0)

    def test_switching_off_is_not_an_error(self):
        r = ab_on()
        r.brk = FULL
        double_press(r)
        self.assertEqual(r.g("ab-on"), None)
        self.assertEqual(code(r), 0)


class ReplTests(unittest.TestCase):
    def test_hibak_prints_history(self):
        r = rear_p2()
        r.thr = LOW
        r.step(int(0.5 / STEP))
        r.v.printed.clear()
        r.i.call("hibak")
        text = " ".join(str(a) for p in r.v.printed for a in p)
        self.assertIn("Aktiv: 14", text)
        self.assertIn("HIBAS", text)
        self.assertIn("14 - gazkar", text)


if __name__ == "__main__":
    unittest.main()
