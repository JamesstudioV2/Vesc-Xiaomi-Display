"""Advanced Balance tesztjei (lisp/hatso_vezerlo.lisp, Advanced-Balance ág).

A szimulátor a valódi Lisp kódot futtatja. A zárt hurkú teszt egy egyszerű
fizikai modellt (inga a hátsó tengely körül + agymotor) köt a vezérlésre: a
szögkorlát nélkül a teljes gázos emelés átfordul, vele a célszög körül marad.
A modell durva közelítés, a valódi hangolást nem váltja ki.

Run:  python3 -m unittest discover -s tests -v
"""
import math
import unittest

from test_scripts import Rear, IDLE, FULL, STEP

HALF = 0x6A  # ~1.37 V -> ~48 % gáz


def angle(r, deg, roll=0.0):
    r.v.imu_rpy = [math.radians(roll), math.radians(deg), 0.0]


def tick(r, n=1):
    """n darab 10 ms-os lépés: AB szál 100 Hz, vezérlő + kijelző 50 Hz."""
    for _ in range(n):
        if r.k % 2 == 0:
            r.lever_frame()
            r.i.call("control-step")
        r.i.call("ab-tick")
        r.v.now += 0.01
        r.k += 1


def secs(t):
    return int(round(t / 0.01))


def rear_p2():
    r = Rear()
    r.k = 0
    angle(r, 0.0)
    r.boot_p2()
    r.thr = IDLE
    r.step(int(0.5 / STEP))
    assert r.g("profile") == 2 and r.g("state") == "run"
    r.i.set("speedmode", 4)  # S mód: 100 % fázisáram -> 60 A a tesztekben
    r.i.call("apply-mode")
    r.i.set("front-can-id", 12)  # első vezérlő (a figyelmeztetés a can-list-devs-től függ)
    return r


def double_press(r):
    for _ in range(2):
        r.v.gpio_in["pin-rx"] = 0
        tick(r, 8)
        r.v.gpio_in["pin-rx"] = 1
        tick(r, 6)
    tick(r, secs(0.6))


def ab_on(r=None):
    r = r or rear_p2()
    r.brk = FULL
    double_press(r)
    assert r.g("ab-on"), "AB did not turn on"
    r.brk = IDLE
    tick(r, secs(0.3))
    return r


def last_can(r, kind):
    cmds = [c for c in r.v.can_cmds if c[0] == kind]
    return cmds[-1] if cmds else None


class ToggleTests(unittest.TestCase):
    def test_off_by_default(self):
        r = rear_p2()
        self.assertEqual(r.g("ab-on"), None)
        self.assertFalse(r.v.output_disabled)

    def test_brake_plus_double_press_turns_on(self):
        r = rear_p2()
        r.brk = FULL
        n = len(r.v.tx)
        double_press(r)
        self.assertTrue(r.g("ab-on"))
        self.assertTrue(r.v.output_disabled, "the script drives both motors")
        self.assertGreaterEqual(sum(f[9] for f in r.v.tx[n:]), 2, "two beeps")
        f = r.last_dash()
        self.assertEqual(f[6] & 32, 32, "lock icon (LOCK bit)")
        self.assertEqual(f[6] & 7, 4, "speed mode bits kept")
        self.assertEqual(f[11], 0, "no error code")
        self.assertEqual(r.g("speedmode"), 4, "no mode change")

    def test_double_press_without_brake_changes_mode(self):
        r = rear_p2()
        double_press(r)
        self.assertEqual(r.g("ab-on"), None)
        self.assertEqual(r.g("speedmode"), 2, "S -> ECO")

    def test_same_gesture_turns_off(self):
        r = ab_on()
        r.brk = FULL
        double_press(r)
        self.assertEqual(r.g("ab-on"), None)
        self.assertEqual(r.g("ab-reason"), "kikapcsolva")
        self.assertFalse(r.v.output_disabled, "back to the ADC app")
        f = r.last_dash()
        self.assertEqual(f[6] & 32, 0, "lock icon off")
        self.assertEqual(f[11], 0)

    def test_refused_in_profile1(self):
        r = Rear()
        r.k = 0
        angle(r, 0.0)
        r.boot_p1()
        r.brk = FULL
        n = len(r.v.tx)
        double_press(r)
        self.assertEqual(r.g("ab-on"), None)
        self.assertGreaterEqual(sum(f[9] for f in r.v.tx[n:]), 3)

    def test_refused_without_imu(self):
        r = rear_p2()
        r.v.imu_acc = [0.0, 0.0, 0.0]
        r.brk = FULL
        double_press(r)
        self.assertEqual(r.g("ab-on"), None)

    def test_off_after_reboot(self):
        r = ab_on()
        r2 = rear_p2()  # új indulás
        self.assertEqual(r2.g("ab-on"), None)

    def test_brake_handover_without_dip(self):
        r = rear_p2()
        r.brk = FULL
        r.v.gpio_in["pin-rx"] = 0
        tick(r, 8)
        r.v.gpio_in["pin-rx"] = 1
        tick(r, 6)
        r.v.gpio_in["pin-rx"] = 0
        tick(r, 8)
        r.v.gpio_in["pin-rx"] = 1
        while not r.g("ab-on"):
            tick(r, 1)
        tick(r, 1)
        self.assertAlmostEqual(r.v.motor_brake, 1.0, places=3, msg="full brake right away")


class DrivingTests(unittest.TestCase):
    def test_two_wheels_is_normal_throttle(self):
        r = ab_on()
        r.thr = FULL
        tick(r, secs(0.6))
        self.assertAlmostEqual(r.v.motor_current, 60.0, places=3, msg="full rear current")
        self.assertAlmostEqual(last_can(r, "current-rel")[2], 1.0, places=3, msg="front gets the same")

    def test_throttle_ramp_like_adc(self):
        r = ab_on()
        r.thr = FULL
        tick(r, secs(0.15))
        self.assertLess(r.v.motor_current, 40.0, "0.3 s ramp from VESC Tool")
        tick(r, secs(0.3))
        self.assertAlmostEqual(r.v.motor_current, 60.0, places=3)

    def test_brake_is_normal(self):
        r = ab_on()
        r.thr = FULL
        tick(r, secs(0.5))
        r.thr = IDLE
        r.brk = FULL
        tick(r, secs(0.7))  # mint az ADC app: 0-ig a csökkenő, onnan a növekvő rámpával
        self.assertAlmostEqual(r.v.motor_brake, 1.0, places=3)
        self.assertAlmostEqual(last_can(r, "brake-rel")[2], 1.0, places=3)

    def test_brake_light_on_limiter_braking(self):
        r = ab_on()
        r.kmh(10.0)
        angle(r, 30.0)
        seen = []
        for _ in range(secs(0.8)):
            tick(r, 1)
            seen.append(r.v.out("pin-ppm"))
        self.assertIn(0, seen)

    def test_no_speed_limit(self):
        r = ab_on()
        r.thr = FULL
        r.kmh(90.0)
        tick(r, secs(0.6))
        self.assertTrue(r.g("ab-on"))
        self.assertAlmostEqual(r.v.motor_current, 60.0, places=3)

    def test_dash_silence_no_drive_but_stays_on(self):
        r = ab_on()
        r.thr = FULL
        tick(r, secs(0.5))
        for _ in range(secs(0.6)):  # nincs kijelzőkeret
            r.i.call("ab-tick")
            r.v.now += 0.01
        self.assertTrue(r.g("ab-on"))
        self.assertLess(abs(r.v.motor_current or 0.0), 1.0)


class LimiterTests(unittest.TestCase):
    def setUp(self):
        self.r = ab_on()
        self.r.thr = FULL
        self.r.kmh(10.0)
        tick(self.r, secs(0.5))

    def test_takes_throttle_away_near_target(self):
        r = self.r
        angle(r, 15.0)
        tick(r, secs(0.5))
        self.assertAlmostEqual(r.v.motor_current, 50.0, delta=1.0, msg="10 A/deg * 5 deg")
        angle(r, 20.0)
        tick(r, secs(0.5))
        self.assertAlmostEqual(r.v.motor_current, 0.0, delta=1.0)
        self.assertGreater(last_can(r, "current-rel")[2], 0.9, "the front is not limited")

    def test_brakes_above_target(self):
        r = self.r
        angle(r, 24.0)
        tick(r, secs(0.5))
        self.assertAlmostEqual(r.v.motor_current, -40.0, delta=1.0)

    def test_brakes_even_without_throttle(self):
        r = self.r
        r.thr = IDLE
        angle(r, 25.0)
        tick(r, secs(0.5))
        self.assertLess(r.v.motor_current, -30.0)

    def test_never_adds_throttle(self):
        r = self.r
        r.thr = HALF
        angle(r, 10.0)
        tick(r, secs(0.6))
        self.assertLess(r.v.motor_current, 32.0, "min(throttle, limit): half throttle stays half")

    def test_reverse_limited(self):
        r = self.r
        angle(r, 25.0)
        r.kmh(-4.0)
        tick(r, secs(0.3))
        self.assertGreaterEqual(r.v.motor_current, 0.0)
        r.kmh(-2.0)
        tick(r, secs(0.3))
        self.assertLess(r.v.motor_current, 0.0, "small reverse is allowed")

    def test_two_wheels_ignored_even_with_rate(self):
        r = self.r
        for k in range(10):  # 2,5°-ig gyors billegés (zökkenő)
            angle(r, 0.25 * k)
            tick(r, 1)
        self.assertAlmostEqual(r.v.motor_current, 60.0, places=3)

    def test_d_term_anticipates_fast_rise(self):
        r = self.r
        angle(r, 12.0)
        tick(r, secs(0.5))
        static = r.v.motor_current
        for k in range(5):
            angle(r, 12.0 + 0.6 * (k + 1))  # 60 fok/s emelkedés
            tick(r, 1)
        self.assertLess(r.v.motor_current, static - 20.0)

    def test_slew_limit(self):
        r = self.r
        r.v.motor_log.clear()
        angle(r, 30.0)
        tick(r, secs(0.3))
        cur = [c for _, c in r.v.motor_log]
        steps = [abs(b - a) for a, b in zip(cur, cur[1:])]
        self.assertLessEqual(max(steps), 10.0 + 1e-6, "1000 A/s at 100 Hz")


class CutoffTests(unittest.TestCase):
    def assert_cut(self, r, reason):
        self.assertEqual(r.g("ab-on"), None)
        self.assertEqual(r.g("ab-reason"), reason)
        self.assertEqual(r.v.motor_current, 0.0)
        self.assertEqual(last_can(r, "current")[2], 0.0)
        self.assertFalse(r.v.output_disabled)

    def test_roll_60(self):
        r = rear_p2()
        r.v.can_devs = [12]
        ab_on(r)
        r.thr = FULL
        angle(r, 0.0, roll=59.0)
        tick(r, 3)
        self.assertTrue(r.g("ab-on"))
        angle(r, 0.0, roll=61.0)
        tick(r, 3)
        self.assert_cut(r, "oldaldoles")

    def test_pitch_back_60(self):
        r = rear_p2()
        r.v.can_devs = [12]
        ab_on(r)
        r.thr = FULL
        angle(r, 59.0)
        tick(r, 3)
        self.assertTrue(r.g("ab-on"))
        angle(r, 61.0)
        tick(r, 3)
        self.assert_cut(r, "hatradoles")

    def test_throttle_locked_after_cutoff(self):
        r = ab_on()
        r.thr = FULL
        tick(r, secs(0.4))
        angle(r, 61.0)
        tick(r, 3)
        angle(r, 0.0)
        tick(r, 4)
        self.assertAlmostEqual(r.v.override[0], 0.8, msg="throttle held until released")
        r.thr = IDLE
        tick(r, 4)
        r.thr = FULL
        tick(r, 4)
        self.assertAlmostEqual(r.v.override[0], FULL / 77.27, places=4)

    def test_imu_lost_turns_off(self):
        r = ab_on()
        r.v.imu_acc = [0.0, 0.0, 0.0]
        tick(r, 3)
        self.assertEqual(r.g("ab-on"), None)
        self.assertEqual(r.g("ab-reason"), "imu")


class TractionTests(unittest.TestCase):
    def test_front_spinning_faster_is_reduced(self):
        r = ab_on()
        r.thr = FULL
        r.kmh(10.0)
        r.v.can_speed = {12: 18.0 / 3.6}  # az első 8 km/h-val gyorsabb (levegőben)
        r.v.can_devs = [12]
        tick(r, secs(1.0))
        self.assertEqual(r.g("ab-front-id"), 12)
        self.assertLess(last_can(r, "current-rel")[2], 0.05)
        self.assertAlmostEqual(r.v.motor_current, 60.0, places=1, msg="rear not touched")

    def test_rear_spinning_faster_is_reduced(self):
        r = ab_on()
        r.thr = FULL
        r.kmh(16.0)
        r.v.can_speed = {12: 10.0 / 3.6}
        r.v.can_devs = [12]
        tick(r, secs(1.0))
        self.assertLess(r.v.motor_current, 25.0)

    def test_small_difference_is_ignored(self):
        r = ab_on()
        r.thr = FULL
        r.kmh(10.0)
        r.v.can_speed = {12: 12.5 / 3.6}
        r.v.can_devs = [12]
        tick(r, secs(1.0))
        self.assertAlmostEqual(last_can(r, "current-rel")[2], 1.0, places=2)


class IconTests(unittest.TestCase):
    def test_other_bit_configurable(self):
        r = rear_p2()
        r.i.set("ab-icon-field", 2)
        r.i.set("ab-icon-bit", 64)
        ab_on(r)
        f = r.last_dash()
        self.assertEqual(f[8] & 64, 64)
        self.assertEqual(f[6] & 32, 0)

    def test_icon_can_be_disabled(self):
        r = rear_p2()
        r.i.set("ab-icon-mode", None)
        ab_on(r)
        self.assertEqual(r.last_dash()[6] & 32, 0)

    def test_real_fault_wins(self):
        r = ab_on()
        r.v.fault = 5
        tick(r, 4)
        f = r.last_dash()
        self.assertEqual(f[11], 40, "VESC FET overtemp -> 40")
        self.assertEqual(f[6] & 32, 32, "lock icon stays")

    def test_ikon_teszt(self):
        r = rear_p2()
        r.i.call("ikon-teszt")
        self.assertEqual(r.g("icon-test-field"), -1)
        self.assertGreaterEqual(len(r.v.printed), 12)


class ClosedLoopTests(unittest.TestCase):
    """Inga a hátsó tengely körül: phi = a súlypont szöge a függőlegestől (+ előre).
    A roller szöge theta = theta_b - phi (theta_b: a balanszpont szöge)."""

    def simulate(self, engage=3.0, theta_b=12.0, target=10.0, kt=0.5, th0=0.0, w0=0.0, v0=0.0,
                 seconds=5.0):
        r = rear_p2()
        r.i.set("ab-target-angle", target)
        r.i.set("ab-engage-angle", engage)
        r.v.conf["l-current-max"] = 60.0
        ab_on(r)
        m, L, rad, g = 105.0, 1.0, 0.125, 9.81
        phi, w, v = math.radians(theta_b - th0), math.radians(-w0), v0 / 3.6
        r.thr = FULL
        worst = -99.0
        for _ in range(secs(seconds)):
            i = r.v.motor_current
            if i is None:
                i = -(r.v.motor_brake or 0.0) * 60.0
            sub = 10
            for _ in range(sub):
                h = 0.01 / sub
                tau = kt * i
                a = tau / (rad * m)
                acc = (g / L) * math.sin(phi) - (a / L) * math.cos(phi) - tau / (m * L * L)
                if theta_b - math.degrees(phi) <= 0.0 and acc > 0:  # az első kerék a földön
                    w, phi = 0.0, math.radians(theta_b)
                else:
                    w += acc * h
                    phi += w * h
                v += a * h
            th = theta_b - math.degrees(phi)
            angle(r, th)
            r.v.speed_ms = v
            tick(r, 1)
            worst = max(worst, th)
            if not r.g("ab-on"):
                return worst, r.g("ab-reason")
        return worst, None

    def test_without_limit_it_flips_and_cuts_off(self):
        worst, reason = self.simulate(engage=90.0)
        self.assertEqual(reason, "hatradoles")

    def test_with_limit_full_throttle_wheelie_holds(self):
        for kt in (0.5, 0.8):
            worst, reason = self.simulate(kt=kt)
            self.assertIsNone(reason, "Kt=%.1f" % kt)
            self.assertLess(worst, 15.0, "Kt=%.1f: target 10 deg" % kt)

    def test_yank_at_speed_is_caught(self):
        worst, reason = self.simulate(th0=8.0, w0=60.0, v0=15.0)
        self.assertIsNone(reason)
        self.assertLess(worst, 30.0)


if __name__ == "__main__":
    unittest.main()
