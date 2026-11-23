"""Advanced-Balance ág: a két kipörgésgátló AB módban, a 3x gombos kapcsolás,
a célszög mentése (fék + 5x) és a BNO085 szög.

Run:  python3 -m unittest discover -s tests -v
"""
import math
import unittest

from lbm_sim import Symbol
from test_scripts import IDLE, FULL
from test_advanced_balance import rear_p2, ab_on, tick, angle, secs, new_rear
from test_errors import code


def ack(r, front_kmh, flags=3, version=2):
    """Az első vezérlő visszajelzése (2-es verzió) a megadott sebességgel."""
    spd = int(round(front_kmh * 10)).to_bytes(2, "big", signed=True)
    r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, flags, 100, 0, 0, version]) + bytearray(spd))


def run(r, n, front_kmh=None):
    for _ in range(n):
        if front_kmh is not None:
            ack(r, front_kmh)
        tick(r, 1)


def clicks(r, n, front_kmh=None):
    for _ in range(n):
        r.v.gpio_in["pin-rx"] = 0
        run(r, 8, front_kmh)
        r.v.gpio_in["pin-rx"] = 1
        run(r, 6, front_kmh)
    run(r, secs(0.6), front_kmh)


def beeps_since(r, n):
    return sum(f[9] for f in r.v.tx[n:])


def imu_frame(roll, pitch, cnt):
    def i16(x):
        return list(int(round(x * 100)).to_bytes(2, "big", signed=True))
    return bytearray(i16(roll) + i16(pitch) + i16(0.0) + [1, cnt & 0xFF])


class AbTractionTests(unittest.TestCase):
    def test_rear_never_limited_in_ab_mode(self):
        r = ab_on()
        r.thr = FULL
        r.kmh(24.0)
        run(r, secs(1.0), front_kmh=10.0)     # a hátsó 14 km/h-val gyorsabb
        self.assertAlmostEqual(r.v.motor_current, 60.0, places=1, msg="full rear current")
        self.assertNotIn("tc-rear", r.i.g.vars)
        self.assertNotIn("ab-tc-rear", r.i.g.vars)
        frames = [d for sid, d in r.v.can_tx if sid == 0x4D0]
        self.assertEqual(frames[-1][2], 100, "the slower front wheel is not limited either")

    def test_front_lifted_both_tcs_hold_the_front_rear_only_angle_limited(self):
        r = ab_on()
        r.thr = FULL
        angle(r, 15.0)                         # eleje fent, az első kerék a levegőben pörög
        r.kmh(10.0)
        run(r, secs(1.0), front_kmh=25.0)
        kind, cid, rel = [c for c in r.v.can_cmds if c[0] == "current-rel"][-1]
        self.assertLess(rel, 0.05, "AB-TC cuts the airborne front wheel")
        frames = [d for sid, d in r.v.can_tx if sid == 0x4D0]
        self.assertEqual(frames[-1][2], 0, "the general TC cuts it on the front ESC too")
        # a hátsó áram: min(gáz 60 A, szögkorlát 10 A/fok x 5 fok = 50 A), TC nélkül
        self.assertAlmostEqual(r.v.motor_current, 50.0, delta=1.0)

    def test_ab_tc_keeps_front_from_overspinning_when_general_off(self):
        r = ab_on()
        clicks(r, 3, front_kmh=0.0)            # általános kipörgésgátló KI
        self.assertIsNone(r.g("tc-on"))
        self.assertTrue(r.g("ab-on"), "3 clicks do not touch the AB mode")
        r.thr = FULL
        angle(r, 15.0)
        r.kmh(10.0)
        run(r, secs(1.5), front_kmh=25.0)      # a levegőben pörgő első kerék
        kind, cid, rel = [c for c in r.v.can_cmds if c[0] == "current-rel"][-1]
        self.assertEqual(cid, 12)
        self.assertLess(rel, 0.05, "AB-TC still cuts the airborne front wheel")
        self.assertEqual(r.g("tc-front"), 1.0, "general TC is off")

    def test_general_front_factor_goes_through_front_scale(self):
        r = ab_on()
        r.thr = FULL
        r.kmh(20.0)
        run(r, secs(1.0), front_kmh=24.0)      # első 4 km/h-val gyorsabb
        frames = [d for sid, d in r.v.can_tx if sid == 0x4D0]
        self.assertLess(frames[-1][2], 40, "the front ESC scale carries the general TC")
        kind, cid, rel = [c for c in r.v.can_cmds if c[0] == "current-rel"][-1]
        self.assertGreater(rel, 0.5, "and the AB-TC alone is still mild")

    def test_rear_scale_and_imax_ignore_tc_in_ab_mode(self):
        r = rear_p2()
        r.thr = FULL
        r.kmh(20.0)
        run(r, 5, front_kmh=30.0)              # normál módban a TC csak az elsőt fogja
        self.assertEqual(r.v.conf["l-current-max-scale"], 1.0)
        frames = [d for sid, d in r.v.can_tx if sid == 0x4D0]
        self.assertEqual(frames[-1][2], 0)
        r.thr = IDLE
        r.kmh(0.0)
        r.brk = FULL
        clicks(r, 2, front_kmh=0.0)
        self.assertTrue(r.g("ab-on"))
        self.assertEqual(r.v.conf["l-current-max-scale"], 1.0, "AB scales the current itself")
        self.assertEqual(r.g("ab-imax"), 60.0, "from the mode scale, not the TC-lowered one")


class AbClickTests(unittest.TestCase):
    def test_brake_plus_three_clicks_is_tc_not_ab(self):
        r = rear_p2()
        r.brk = FULL
        n = len(r.v.tx)
        clicks(r, 3)
        self.assertIsNone(r.g("tc-on"))
        self.assertIsNone(r.g("ab-on"))
        run(r, secs(0.6))                      # a sípolások között beep-spacing szünet van
        self.assertEqual(beeps_since(r, n), 3)

    def test_three_clicks_without_brake(self):
        r = rear_p2()
        clicks(r, 3)
        self.assertIsNone(r.g("tc-on"))
        self.assertEqual(r.g("speedmode"), 4, "no mode change")

    def test_five_clicks_without_brake_do_nothing(self):
        r = rear_p2()
        angle(r, 22.0)
        clicks(r, 5)
        self.assertEqual(r.g("ab-target-angle"), 20.0)
        self.assertEqual(r.v.eeprom, {})


class TargetSaveTests(unittest.TestCase):
    def save(self, r, deg, kmh=0.0):
        angle(r, deg)
        r.kmh(kmh)
        r.brk = FULL
        n = len(r.v.tx)
        clicks(r, 5)
        return n

    def test_save_at_standstill(self):
        r = rear_p2()
        n = self.save(r, 22.4)
        self.assertAlmostEqual(r.g("ab-target-angle"), 22.4, places=3)
        self.assertAlmostEqual(r.v.eeprom[10], 22.4, places=3)
        self.assertEqual(r.v.eeprom_writes, 1)
        self.assertEqual(r.g("ab-target-source"), "eeprom")
        run(r, secs(1.0))
        self.assertEqual(beeps_since(r, n), 5)
        f = r.last_dash()
        self.assertEqual(f[10], 22, "the dash shows the saved angle")
        run(r, secs(2.0))
        self.assertNotEqual(r.last_dash()[10], 22, "then back to normal")

    def test_save_works_with_ab_on_and_is_used_live(self):
        r = ab_on()
        self.save(r, 25.0)
        self.assertTrue(r.g("ab-on"))
        self.assertAlmostEqual(r.g("ab-target-angle"), 25.0)
        r.brk = IDLE
        r.thr = FULL
        angle(r, 25.0)
        run(r, secs(0.5))
        self.assertAlmostEqual(r.g("ab-lim"), 0.0, delta=0.5, msg="limit is zero at the new target")

    def test_refused_while_moving(self):
        r = rear_p2()
        self.save(r, 22.0, kmh=5.0)
        self.assertEqual(r.g("ab-target-angle"), 20.0)
        self.assertEqual(r.v.eeprom, {})
        self.assertEqual(r.last_dash()[11], 61)

    def test_refused_out_of_range(self):
        for deg in (2.0, 50.0):
            r = rear_p2()
            self.save(r, deg)
            self.assertEqual(r.g("ab-target-angle"), 20.0, deg)
            self.assertEqual(r.v.eeprom, {})
            self.assertEqual(code(r), 61)

    def test_refused_without_imu(self):
        r = rear_p2()
        r.v.imu_acc = [0.0, 0.0, 0.0]
        self.save(r, 22.0)
        self.assertEqual(r.v.eeprom, {})
        self.assertEqual(code(r), 61)

    def test_loaded_at_boot(self):
        r = new_rear()
        r.v.eeprom[10] = 18.5
        r.i.call("boot")
        self.assertAlmostEqual(r.g("ab-target-angle"), 18.5)
        self.assertEqual(r.g("ab-target-source"), "eeprom")

    def test_invalid_or_cleared_value_ignored(self):
        for val in (-1.0, 80.0):
            r = new_rear()
            r.v.eeprom[10] = val
            r.i.call("boot")
            self.assertEqual(r.g("ab-target-angle"), 20.0)
            self.assertEqual(r.g("ab-target-source"), "kod")

    def test_clear_command(self):
        r = rear_p2()
        self.save(r, 22.0)
        r.i.call("celszog-torles")
        self.assertEqual(r.v.eeprom[10], -1.0)
        r2 = new_rear()
        r2.v.eeprom = dict(r.v.eeprom)
        r2.i.call("boot")
        self.assertEqual(r2.g("ab-target-angle"), 20.0)


class AbBnoAndErrorTests(unittest.TestCase):
    def test_ab_with_bno085_angle(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        cnt = 0
        for _ in range(10):
            cnt += 1
            r.i.call("on-imu-frame", imu_frame(0.0, 0.0, cnt))
            tick(r, 1)
        r.brk = FULL
        for _ in range(4):
            for st in (0, 1):
                r.v.gpio_in["pin-rx"] = st
                for _ in range(7):
                    cnt += 1
                    r.i.call("on-imu-frame", imu_frame(0.0, 0.0, cnt))
                    tick(r, 1)
            if r.g("btn-clicks") >= 2:
                break
        for _ in range(secs(0.6)):
            cnt += 1
            r.i.call("on-imu-frame", imu_frame(0.0, 0.0, cnt))
            tick(r, 1)
        self.assertTrue(r.g("ab-on"))
        self.assertTrue(r.g("bal-imu-ok"))
        tick(r, secs(0.2))                     # a BNO elhallgat
        self.assertIsNone(r.g("ab-on"))
        self.assertEqual(r.g("ab-reason"), "imu")

    def test_ab_refused_without_bno_shows_62(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        r.brk = FULL
        n = len(r.v.tx)
        clicks(r, 2)
        self.assertIsNone(r.g("ab-on"))
        self.assertEqual(code(r), 62)

    def test_old_front_script_is_error_60(self):
        r = rear_p2()
        r.v.can_devs = [12]
        for _ in range(secs(5.0)):
            r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, 3, 100, 0]))  # 1-es verzió
            tick(r, 1)
        self.assertTrue(r.g("front-old"))
        self.assertEqual(code(r), 60)

    def test_old_front_fault_byte_still_read(self):
        r = rear_p2()
        r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, 3, 100, 6]))
        self.assertEqual(r.g("front-fault"), 6)


if __name__ == "__main__":
    unittest.main()


class AbFirmwareCompatTests(unittest.TestCase):
    def test_release_firmware_brake_threshold_from_throttle_calibration(self):
        r = rear_p2()                           # kiadott 7.00: nincs adc-v2-* a Lispben
        self.assertEqual(r.g("brk-start"), r.v.conf["adc-v1-start"])
        self.assertEqual(r.g("brk-end"), r.v.conf["adc-v1-end"])
        r.brk = FULL
        clicks(r, 2)
        self.assertTrue(r.g("ab-on"), "brake + 2 clicks still works")

    def test_target_angle_loaded_and_ab_thread_ready_after_boot(self):
        r = new_rear()
        r.v.eeprom[10] = 21.0
        r.i.call("boot")
        self.assertAlmostEqual(r.g("ab-target-angle"), 21.0)
        self.assertEqual(r.v.uart_started, (115200, "half-duplex"))



class SingleImuTests(unittest.TestCase):
    """Egyetlen IMU: a BNO085 az első vezérlő COM1 portján, a vezérlőkben nincs IMU."""

    def no_internal_imu(self, r):
        def boom():
            raise AssertionError("the internal IMU must not be read in BNO085 mode")
        r.i.builtins["get-imu-rpy"] = boom
        r.i.builtins["get-imu-acc"] = boom

    def test_ab_runs_on_bno_alone(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        self.no_internal_imu(r)
        cnt = 0
        def feed(n, pitch=0.0):
            nonlocal cnt
            for _ in range(n):
                cnt += 1
                r.i.call("on-imu-frame", imu_frame(0.0, pitch, cnt))
                tick(r, 1)
        feed(10)
        r.brk = FULL
        for _ in range(2):
            r.v.gpio_in["pin-rx"] = 0
            feed(8)
            r.v.gpio_in["pin-rx"] = 1
            feed(6)
        feed(secs(0.6))
        self.assertTrue(r.g("ab-on"))
        r.brk = IDLE
        r.thr = FULL
        feed(secs(0.5), pitch=25.0)            # a célszög (20) fölött: fékez
        self.assertLess(r.v.motor_current, 0.0)
        self.assertGreater(r.g("imu-frames"), 50)
        r.i.call("szog")                       # a belső IMU-t nem kérdezi

    def test_hint_front_silent(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        r.i.set("front-version", 0)
        self.assertIn("nem valaszol", r.i.call("imu-hint"))

    def test_hint_front_sees_bno_but_no_frames(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        ack(r, 0.0)
        r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, 3, 100, 0, 2, 2, 0, 0]))  # bit1: BNO friss
        self.assertTrue(r.g("front-bno"))
        self.assertIn("imu-sid", r.i.call("imu-hint"))

    def test_hint_front_without_bno(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        ack(r, 0.0)
        self.assertIn("nem latja a BNO085-ot", r.i.call("imu-hint"))

    def test_startup_warning_once(self):
        r = rear_p2()
        r.i.set("imu-source", Symbol("bno085"))
        for _ in range(int(10.0 / 0.02)):
            r.step(1)
        text = " ".join(str(a) for p in r.v.printed for a in p)
        self.assertEqual(text.count("FIGYELEM: nincs IMU adat"), 1)
