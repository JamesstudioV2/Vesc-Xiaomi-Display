"""Balansz mód tesztjei (lisp/hatso_vezerlo.lisp, Balance ág).

A szimulátor a valódi Lisp kódot futtatja. A zárt hurkú teszt egy egyszerű
fizikai modellt (inga a hátsó tengely körül + agymotor) köt a szabályzóra.
Ez a modell durva közelítés: a jelek irányát és a stabilitás nagyságrendjét
ellenőrzi, a valódi hangolást nem váltja ki.

Run:  python3 -m unittest discover -s tests -v
"""
import math
import unittest

from test_scripts import Rear, IDLE, FULL, STEP


def angle(r, deg, roll=0.0):
    r.v.imu_rpy = [math.radians(roll), math.radians(deg), 0.0]


def tick(r, n=1):
    """n darab 10 ms-os lépés: balansz szál 100 Hz, vezérlő + kijelző 50 Hz."""
    for _ in range(n):
        if r.k % 2 == 0:
            r.lever_frame()
            r.i.call("control-step")
        r.i.call("balance-tick")
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
    return r


def rear_balancing(start_angle=20.0):
    r = rear_p2()
    angle(r, start_angle)
    r.thr = r.brk = FULL
    tick(r, secs(1.1))
    assert r.g("bal-state") == "on", r.g("bal-state")
    r.brk = IDLE  # a fék elengedése aktiválás után
    tick(r, secs(0.1))
    return r


class ActivationTests(unittest.TestCase):
    def test_activates_in_profile2(self):
        r = rear_p2()
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(0.9))
        self.assertEqual(r.g("bal-state"), "arming")
        tick(r, secs(0.2))
        self.assertEqual(r.g("bal-state"), "on")
        self.assertTrue(r.v.output_disabled, "ADC app off: the script drives the rear motor")
        self.assertAlmostEqual(r.g("bal-setpoint"), 20.0)
        self.assertEqual(r.v.conf["l-current-max-scale"], 1.0)
        self.assertAlmostEqual(r.v.conf["max-speed"], 40 / 3.6)
        tick(r, secs(0.2))
        sid, data = r.v.can_tx[-1]
        self.assertEqual(data[1], 0, "front motor disabled while balancing")
        self.assertEqual(sum(f[9] for f in r.v.tx[-30:]), 2, "two beeps")

    def test_needs_a_full_second(self):
        r = rear_p2()
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(0.8))
        r.brk = IDLE
        tick(r, secs(0.5))
        self.assertEqual(r.g("bal-state"), "off")

    def test_not_in_profile1(self):
        r = Rear()
        r.k = 0
        angle(r, 0.0)
        r.boot_p1()
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.5))
        self.assertEqual(r.g("bal-state"), "off")

    def test_only_from_standstill(self):
        r = rear_p2()
        angle(r, 20.0)
        r.kmh(3.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.5))
        self.assertEqual(r.g("bal-state"), "off")

    def test_angle_window(self):
        for a in (5.0, 40.0):
            r = rear_p2()
            angle(r, a)
            r.thr = r.brk = FULL
            tick(r, secs(1.5))
            self.assertEqual(r.g("bal-state"), "off", a)

    def test_roll_limit(self):
        r = rear_p2()
        angle(r, 20.0, roll=35.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.5))
        self.assertEqual(r.g("bal-state"), "off")

    def test_needs_imu(self):
        r = rear_p2()
        r.v.imu_acc = [0.0, 0.0, 0.0]
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.5))
        self.assertEqual(r.g("bal-state"), "off")

    def test_axis_invert_and_offset(self):
        r = rear_p2()
        r.i.set("balance-axis", 0)
        r.i.set("balance-invert", True)
        r.i.set("balance-level-offset", -3.0)
        r.v.imu_rpy = [math.radians(-17.0), 0.0, 0.0]  # roll tengely, fordított előjel
        tick(r, 1)
        self.assertAlmostEqual(r.g("bal-angle"), 20.0, places=3)


class ControlTests(unittest.TestCase):
    def test_direction(self):
        r = rear_balancing(20.0)
        tick(r, secs(0.4))  # a ramp-in után
        angle(r, 15.0)      # az eleje lejjebb került
        tick(r, secs(0.3))
        self.assertGreater(r.v.motor_current, 10.0, "front dropping -> accelerate")
        angle(r, 25.0)      # az eleje feljebb van
        tick(r, secs(0.3))
        self.assertLess(r.v.motor_current, -10.0, "front too high -> brake")

    def test_d_term_reacts_to_falling_front(self):
        r = rear_balancing(20.0)
        tick(r, secs(0.5))
        static = r.v.motor_current
        for k in range(5):  # gyorsan esik az eleje
            angle(r, 20.0 - 0.5 * (k + 1))
            tick(r, 1)
        self.assertGreater(r.v.motor_current, static + 2.0)

    def test_ramp_in_and_slew(self):
        r = rear_p2()
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.05))
        self.assertEqual(r.g("bal-state"), "on")
        angle(r, 10.0)  # nagy hiba rögtön az indulás után
        r.v.motor_log.clear()
        tick(r, secs(0.6))
        currents = [c for _, c in r.v.motor_log]
        steps = [abs(b - a) for a, b in zip(currents, currents[1:])]
        self.assertLessEqual(max(steps), 4.0 + 1e-6, "400 A/s at 100 Hz")
        self.assertLessEqual(max(abs(c) for c in currents), 40.0 + 1e-6)
        self.assertLess(currents[0], 5.0, "starts gently")

    def test_mode_change_blocked_light_allowed(self):
        r = rear_balancing(20.0)
        mode = r.g("speedmode")
        for _ in range(2):
            r.v.gpio_in["pin-rx"] = 0
            tick(r, 8)
            r.v.gpio_in["pin-rx"] = 1
            tick(r, 6)
        tick(r, secs(0.6))
        self.assertEqual(r.g("speedmode"), mode)
        self.assertEqual(r.v.conf["l-current-max-scale"], 1.0)
        r.v.gpio_in["pin-rx"] = 0
        tick(r, 8)
        r.v.gpio_in["pin-rx"] = 1
        tick(r, secs(0.6))
        self.assertTrue(r.g("light"))
        self.assertEqual(r.g("bal-state"), "on")

    def test_brake_light_blinks_when_controller_brakes(self):
        r = rear_balancing(20.0)
        tick(r, secs(0.4))
        angle(r, 28.0)
        seen = []
        for _ in range(secs(0.8)):
            tick(r, 1)
            seen.append(r.v.out("pin-ppm"))
        self.assertIn(0, seen)
        self.assertIn(1, seen)


class ExitTests(unittest.TestCase):
    def assert_exit(self, r, reason):
        self.assertEqual(r.g("bal-state"), "off")
        self.assertEqual(r.g("bal-reason"), reason)
        self.assertEqual(r.v.motor_current, 0.0)
        self.assertFalse(r.v.output_disabled, "back to the ADC app, the brake works")

    def test_throttle_release_exits_then_cooldown(self):
        r = rear_balancing(20.0)
        r.thr = IDLE
        tick(r, 3)
        self.assert_exit(r, "gaz-elengedve")
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.5))
        self.assertNotEqual(r.g("bal-state"), "on", "2 s cooldown")
        tick(r, secs(1.7))
        self.assertEqual(r.g("bal-state"), "on", "after the cooldown it works again")

    def test_brake_pulled_again_exits(self):
        r = rear_balancing(20.0)
        tick(r, secs(0.5))
        self.assertEqual(r.g("bal-state"), "on")
        r.brk = FULL
        tick(r, 3)
        self.assert_exit(r, "fek")

    def test_brake_never_released_exits(self):
        r = rear_p2()
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick(r, secs(1.1))
        self.assertEqual(r.g("bal-state"), "on")
        tick(r, secs(2.1))
        self.assert_exit(r, "fek-nincs-elengedve")

    def test_safety_exits(self):
        cases = [
            ("leszallt", lambda r: angle(r, 3.0)),
            ("tul-nagy-szog", lambda r: angle(r, 55.0)),
            ("oldaldoles", lambda r: angle(r, 20.0, roll=35.0)),
            ("hatramenet", lambda r: r.kmh(-4.0)),
            ("vezerlo-hiba", lambda r: setattr(r.v, "fault", 5)),
            ("imu", lambda r: setattr(r.v, "imu_acc", [0.0, 0.0, 0.0])),
        ]
        for reason, make in cases:
            r = rear_balancing(20.0)
            make(r)
            tick(r, 3)
            self.assert_exit(r, reason)

    def test_dash_silence_exits(self):
        r = rear_balancing(20.0)
        for _ in range(secs(0.5)):  # nincs kijelzőkeret
            r.i.call("balance-tick")
            r.v.now += 0.01
        self.assertEqual(r.g("bal-state"), "off")
        self.assertEqual(r.g("bal-reason"), "nincs-kijelzo")

    def test_speed_limit_lowers_front_beeps_but_keeps_balancing(self):
        r = rear_balancing(20.0)
        tick(r, secs(0.4))
        r.kmh(31.0)
        n = len(r.v.tx)
        tick(r, 2)
        self.assertEqual(r.g("bal-state"), "limit")
        tick(r, secs(2.0))
        self.assertAlmostEqual(r.g("bal-setpoint"), 10.0, places=3, msg="20 - 10 deg, not to zero")
        self.assertEqual(r.g("bal-state"), "limit", "still balancing")
        self.assertGreaterEqual(sum(f[9] for f in r.v.tx[n:]), 3, "beeps while over the limit")
        r.kmh(27.0)
        tick(r, secs(1.0))
        self.assertEqual(r.g("bal-state"), "on")
        self.assertAlmostEqual(r.g("bal-setpoint"), 20.0, places=3, msg="back to the start angle")

    def test_limit_floor_angle(self):
        r = rear_balancing(12.0)
        r.kmh(31.0)
        tick(r, secs(2.0))
        self.assertAlmostEqual(r.g("bal-setpoint"), 8.0, places=3)

    def test_too_fast_hard_exit(self):
        r = rear_balancing(20.0)
        r.kmh(34.0)
        tick(r, 3)
        self.assertEqual(r.g("bal-state"), "limit")
        r.kmh(36.0)
        tick(r, 3)
        self.assert_exit(r, "tul-gyors")

    def test_throttle_hold_is_70_percent(self):
        r = rear_balancing(20.0)
        r.thr = 0x70  # ~1.45 V -> ~54 %
        tick(r, 3)
        self.assert_exit(r, "gaz-elengedve")

    def test_throttle_locked_after_exit_until_released(self):
        r = rear_balancing(20.0)
        angle(r, 55.0)  # biztonsági kilépés, a gáz még nyomva
        tick(r, 3)
        self.assertEqual(r.g("bal-state"), "off")
        tick(r, 4)
        self.assertAlmostEqual(r.v.override[0], 0.8, msg="throttle held at ADC start voltage")
        r.brk = FULL
        tick(r, 4)
        self.assertAlmostEqual(r.v.override[1], FULL / 77.27, places=4, msg="brake works")
        r.brk = IDLE
        r.thr = IDLE
        tick(r, 4)
        r.thr = FULL
        tick(r, 4)
        self.assertAlmostEqual(r.v.override[0], FULL / 77.27, places=4, msg="released once -> free again")

    def test_front_restored_and_no_false_warning(self):
        def tick_ack(r, n, flags):
            for _ in range(n):
                tick(r, 1)
                r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, flags, 0]))

        r = Rear()
        r.k = 0
        r.v.can_devs = [12]
        angle(r, 0.0)
        r.boot_p2()
        r.thr = IDLE
        r.step(int(4.0 / STEP))
        angle(r, 20.0)
        r.thr = r.brk = FULL
        tick_ack(r, secs(1.1), 3)
        self.assertEqual(r.g("bal-state"), "on")
        r.brk = IDLE
        # az első vezérlő még a régi állapotot jelzi vissza: 1 s türelmi idő
        tick_ack(r, secs(0.6), 3)
        self.assertFalse(r.g("front-warn"), "no warning right after the flags change")
        tick_ack(r, secs(1.0), 3)
        self.assertTrue(r.g("front-warn"), "a lasting mismatch is reported")
        tick_ack(r, secs(0.6), 0)
        self.assertFalse(r.g("front-warn"))
        r.thr = IDLE
        tick_ack(r, secs(0.3), 0)
        self.assertEqual(r.g("bal-state"), "off")
        self.assertEqual(r.v.can_tx[-1][1][1], 3, "front drives again in profile 2")


class ClosedLoopTests(unittest.TestCase):
    """Inga a hátsó tengely körül: phi = a súlypont szöge a függőlegestől (+ előre).
    A roller szöge theta = theta_b - phi, ahol theta_b a balanszpont szöge."""

    def simulate(self, kt=0.5, kp=None, seconds=5.0, push=60.0, phi0=0.0):
        r = rear_p2()
        if kp is not None:
            r.i.set("balance-kp", kp)
        m, L, rad, g = 105.0, 1.0, 0.125, 9.81
        theta_b = 20.0
        phi, w, v = math.radians(phi0), 0.0, 0.0
        angle(r, theta_b - phi0)
        r.thr = r.brk = FULL
        tick(r, secs(1.05))
        self.assertEqual(r.g("bal-state"), "on")
        r.brk = IDLE
        worst, t = 0.0, 0.0
        sub = 10
        for _ in range(secs(seconds)):
            i = r.v.motor_current or 0.0
            for _ in range(sub):
                h = 0.01 / sub
                tau = kt * i
                a = tau / (rad * m)
                dist = push if 1.0 < t < 1.3 else 0.0
                acc = (g / L) * math.sin(phi) - (a / L) * math.cos(phi) \
                    - tau / (m * L * L) + dist / (m * L * L)
                w += acc * h
                phi += w * h
                v += a * h
            t += 0.01
            th = theta_b - math.degrees(phi)
            angle(r, th)
            r.v.speed_ms = v
            tick(r, 1)
            if r.g("bal-state") != "on":
                return False, worst, r.g("bal-reason")
            worst = max(worst, abs(th - theta_b))
        return True, worst, None

    def test_default_gains_hold_the_angle(self):
        for kt in (0.3, 0.5, 0.8):
            held, worst, reason = self.simulate(kt=kt)
            self.assertTrue(held, "Kt=%.1f fell: %s" % (kt, reason))
            self.assertLess(worst, 8.0, "Kt=%.1f" % kt)

    def test_wrong_sign_falls(self):
        held, worst, reason = self.simulate(kp=-8.0, seconds=3.0, push=0.0, phi0=1.0)
        self.assertFalse(held, "a sign error must not look like it works")


if __name__ == "__main__":
    unittest.main()
