"""Balansz ág: a BNO085 szöge az első vezérlőtől (CAN 0x4D2), és a
kipörgésgátló viselkedése balansz közben.

Run:  python3 -m unittest discover -s tests -v
"""
import unittest

from lbm_sim import Interp, Symbol, Bno085, quat_from_euler
from test_scripts import Rear, FRONT, IDLE, FULL, STEP
from test_balance import tick, secs
from test_lamp_tc import Link


def imu_frame(roll, pitch, cnt, status=1):
    def i16(x):
        return list(int(round(x * 100)).to_bytes(2, "big", signed=True))
    return bytearray(i16(roll) + i16(pitch) + i16(0.0) + [status, cnt & 0xFF])


class Feeder:
    """100 Hz-es BNO085 minták a hátsó CAN kezelőjébe."""

    def __init__(self, r):
        self.r = r
        self.cnt = 0
        self.pitch = 0.0
        self.roll = 0.0

    def send(self):
        self.cnt += 1
        self.r.i.call("on-imu-frame", imu_frame(self.roll, self.pitch, self.cnt))

    def tick(self, n=1):
        for _ in range(n):
            self.send()
            tick(self.r, 1)


def rear_p2_bno():
    r = Rear()
    r.k = 0
    fd = Feeder(r)
    r.boot_p2()
    r.thr = IDLE
    r.step(int(0.5 / STEP))
    return r, fd


class BnoSourceTests(unittest.TestCase):
    def test_default_source_is_bno085(self):
        r = Rear()
        self.assertEqual(r.g("imu-source"), "bno085")

    def test_angle_and_rate_from_frames(self):
        r = Rear()
        r.i.call("on-imu-frame", imu_frame(1.0, 10.0, 1))
        r.v.now += 0.013   # a beérkezés ideje ingadozik
        r.i.call("on-imu-frame", imu_frame(1.0, 10.5, 2))
        r.i.call("read-imu")
        self.assertAlmostEqual(r.g("bal-angle"), 10.5)
        self.assertAlmostEqual(r.g("bal-roll"), 1.0)
        self.assertAlmostEqual(r.g("bal-ext-rate"), 50.0, msg="0.5 deg per 10 ms sample")
        self.assertTrue(r.g("bal-imu-ok"))

    def test_missed_sample_counts(self):
        r = Rear()
        r.i.call("on-imu-frame", imu_frame(0.0, 10.0, 7))
        r.i.call("on-imu-frame", imu_frame(0.0, 11.0, 9))   # a 8-as elveszett
        r.i.call("read-imu")
        self.assertAlmostEqual(r.g("bal-ext-rate"), 50.0)

    def test_invert_offset_and_axis(self):
        r = Rear()
        r.i.set("balance-axis", 0)
        r.i.set("balance-invert", True)
        r.i.set("balance-level-offset", 2.0)
        r.i.call("on-imu-frame", imu_frame(-18.0, 3.0, 1))
        r.i.call("on-imu-frame", imu_frame(-19.0, 3.0, 2))
        r.i.call("read-imu")
        self.assertAlmostEqual(r.g("bal-angle"), 17.0)
        self.assertAlmostEqual(r.g("bal-roll"), 3.0)
        self.assertAlmostEqual(r.g("bal-ext-rate"), 100.0)

    def test_invalid_status_ignored(self):
        r = Rear()
        r.i.call("on-imu-frame", imu_frame(0.0, 30.0, 1, status=0))
        r.i.call("read-imu")
        self.assertIsNone(r.g("bal-imu-ok"))

    def test_stale_data_is_no_imu(self):
        r = Rear()
        r.i.call("on-imu-frame", imu_frame(0.0, 20.0, 1))
        r.v.now += 0.15
        r.i.call("read-imu")
        self.assertIsNone(r.g("bal-imu-ok"))

    def test_activates_and_stops_when_bno_goes_silent(self):
        r, fd = rear_p2_bno()
        fd.pitch = 20.0
        fd.tick(5)
        r.thr = r.brk = FULL
        fd.tick(secs(1.1))
        self.assertEqual(r.g("bal-state"), "on")
        r.brk = IDLE
        fd.tick(secs(0.2))
        self.assertEqual(r.g("bal-state"), "on")
        tick(r, secs(0.2))           # nincs több minta
        self.assertEqual(r.g("bal-state"), "off")
        self.assertEqual(r.g("bal-reason"), "imu")

    def test_rate_drives_d_term(self):
        r, fd = rear_p2_bno()
        fd.pitch = 20.0
        fd.tick(5)
        r.thr = r.brk = FULL
        fd.tick(secs(1.1))
        r.brk = IDLE
        fd.tick(secs(0.5))
        base = r.g("bal-current")
        for _ in range(10):          # gyorsan emelkedik az eleje: fékezzen
            fd.pitch += 0.3
            fd.tick(1)
        self.assertGreater(r.g("bal-rate"), 15.0)
        self.assertLess(r.g("bal-current"), base)

    def test_end_to_end_from_front_bno(self):
        dev = Bno085()
        f = Interp()
        f.load(FRONT)
        f.vesc.i2c_dev = dev
        f.call("init")
        for _ in range(240):
            f.call("bno-step")
            f.vesc.now += 0.005
        r = Rear()
        dev.report(*quat_from_euler(0.5, 22.0, 90.0))
        f.call("bno-step")
        sid, data = f.vesc.can_tx[-1]
        self.assertEqual(sid, 0x4D2)
        r.i.call("on-imu-frame", bytearray(data))
        r.i.call("read-imu")
        self.assertAlmostEqual(r.g("bal-angle"), 22.0, delta=0.05)
        self.assertAlmostEqual(r.g("bal-roll"), 0.5, delta=0.05)


class BalanceTractionTests(unittest.TestCase):
    def test_tc_off_while_balancing_and_scale_kept(self):
        L = Link()
        r = L.r
        r.k = 0
        fd = Feeder(r)
        fd.pitch = 20.0
        fd.tick(5)
        r.thr = r.brk = FULL
        for _ in range(secs(1.1)):
            fd.send()
            tick(r, 1)
            L.fv.now = r.v.now
            L.pump()
        self.assertEqual(r.g("bal-state"), "on")
        L.speeds(0.0, 6.0)           # a hátsó forog, az első áll (egykerekezés)
        for _ in range(20):
            fd.send()
            tick(r, 1)
            L.fv.now = r.v.now
            L.pump()
        self.assertFalse(r.i.call("tc-active"))
        self.assertEqual(r.v.conf["l-current-max-scale"], 1.0, "balance keeps full current")
        self.assertEqual(r.g("tc-rear"), 1.0)


if __name__ == "__main__":
    unittest.main()


class BrakeCalibrationFallbackTests(unittest.TestCase):
    def test_release_firmware_uses_throttle_calibration(self):
        r = Rear()                              # kiadott 7.00: nincs adc-v2-* a Lispben
        r.v.conf["adc-v1-start"] = 0.9
        r.v.conf["adc-v1-end"] = 2.1
        r.i.call("refresh-gate")
        self.assertEqual(r.g("brk-start"), 0.9)
        self.assertEqual(r.g("brk-end"), 2.1)

    def test_newer_firmware_uses_brake_calibration(self):
        r = Rear()
        r.v.newer_fw = True
        r.v.conf["adc-v2-start"] = 0.7
        r.v.conf["adc-v2-end"] = 1.9
        r.i.call("refresh-gate")
        self.assertEqual(r.g("brk-start"), 0.7)
        self.assertEqual(r.g("brk-end"), 1.9)
