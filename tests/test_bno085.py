"""BNO085 (külső IMU) az első vezérlő COMM portján: I2C (SHTP) és UART-RVC.

Run:  python3 -m unittest discover -s tests -v
"""
import unittest

from lbm_sim import Interp, Symbol, Blocked, Bno085, rvc_frame, quat_from_euler
from test_scripts import FRONT

DT = 0.005  # a BNO szál alvása 10 ms-os mintavételnél


def front(dev=None, enabled=True, mode=None):
    f = Interp()
    f.load(FRONT)
    f.set("bno-enabled", True if enabled else None)
    if mode is not None:
        f.set("bno-mode", Symbol(mode))
    if dev is not None:
        f.vesc.i2c_dev = dev
    f.call("init")
    return f


def run(f, secs):
    for _ in range(int(round(secs / DT))):
        f.call("bno-step")
        f.vesc.now += DT


def run_until(f, state, secs):
    """Legfeljebb secs ideig fut, amíg a BNO állapota state nem lesz; az eltelt idő."""
    t = 0.0
    while t < secs and f.get("bno-state") != state:
        run(f, DT)
        t += DT
    return t


def imu_frames(f):
    return [d for sid, d in f.vesc.can_tx if sid == 0x4D2]


def decode(frame):
    def i16(o):
        return int.from_bytes(frame[o:o + 2], "big", signed=True) / 100.0
    return i16(0), i16(2), i16(4), frame[6], frame[7]


class BnoI2cTests(unittest.TestCase):
    def test_disabled_by_default_on_main(self):
        f = Interp()
        f.load(FRONT)
        f.call("init")
        self.assertIsNone(f.get("bno-enabled"))
        self.assertIsNone(f.vesc.i2c, "no I2C on the COMM pins unless enabled")
        self.assertNotEqual(f.vesc.gpio_mode.get("pin-rx"), "i2c")

    def test_startup_sequence(self):
        dev = Bno085(0x4A)
        f = front(dev)
        run(f, 0.02)
        self.assertEqual(f.vesc.i2c, ("rate-100k", "pin-rx", "pin-tx"), "SDA = RX, SCL = TX, 100 kHz")
        self.assertEqual(f.get("bno-addr"), 0x4A)
        self.assertEqual(dev.resets, 1, "soft reset first")
        run(f, 1.0)
        self.assertEqual(f.get("bno-state"), "run")
        self.assertEqual(dev.feature, (0x08, 10000), "game rotation vector, 100 Hz")
        self.assertEqual(dev.queue, [], "advertisement and boot messages read out")
        self.assertIsNone(dev.cur, "no half-read packet left")
        feat = dev.writes[-1]
        self.assertEqual(list(feat[:4]), [21, 0, 2, 0], "SHTP header: length 21, control channel")

    def test_angles_sent_on_can(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)
        dev.report(*quat_from_euler(10.0, 25.0, -40.0))
        run(f, 0.01)
        frames = imu_frames(f)
        self.assertEqual(len(frames), 1)
        roll, pitch, yaw, status, cnt = decode(frames[0])
        self.assertAlmostEqual(roll, 10.0, delta=0.05)
        self.assertAlmostEqual(pitch, 25.0, delta=0.05)
        self.assertAlmostEqual(yaw, -40.0, delta=0.05)
        self.assertEqual(status, 1)
        self.assertEqual(cnt, 1)
        self.assertAlmostEqual(f.get("bno-pitch"), 25.0, delta=0.05)

    def test_ack_reports_fresh_imu(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)
        dev.report(*quat_from_euler(0.0, 5.0, 0.0))
        run(f, 0.01)
        f.call("on-cmd", bytearray([0xA5, 3, 100, 0x27, 0x10, 0x3A, 0x98, 2]))
        self.assertEqual(f.vesc.can_tx[-1][1][4] & 2, 2)
        f.vesc.now += 0.5
        f.call("on-cmd", bytearray([0xA5, 3, 100, 0x27, 0x10, 0x3A, 0x98, 2]))
        self.assertEqual(f.vesc.can_tx[-1][1][4] & 2, 0, "stale after 0.2 s")

    def test_several_reports_in_one_packet(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)

        def q14(v):
            return list(int(round(v * 16384)).to_bytes(2, "little", signed=True))
        cargo = [0xFB, 0, 0, 0, 0]
        for p in (5.0, 6.0, 7.0):
            x, y, z, w = quat_from_euler(0.0, p, 0.0)
            cargo += [0x08, 0, 3, 0] + q14(x) + q14(y) + q14(z) + q14(w)
        dev.queue.append(dev.packet(3, cargo))
        run(f, 0.01)
        self.assertEqual(f.get("bno-count"), 3)
        self.assertAlmostEqual(f.get("bno-pitch"), 7.0, delta=0.05)

    def test_rotation_vector_report_also_accepted(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)
        dev.report(*quat_from_euler(0.0, -12.0, 0.0), rid=0x05)
        run(f, 0.01)
        self.assertAlmostEqual(f.get("bno-pitch"), -12.0, delta=0.05)

    def test_long_report_packet_is_skipped_cleanly(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)
        dev.queue.append(dev.packet(3, [0x00] * 300))   # ismeretlen, hosszú
        dev.report(*quat_from_euler(0.0, 3.0, 0.0))
        run(f, 0.02)
        self.assertAlmostEqual(f.get("bno-pitch"), 3.0, delta=0.05)

    def test_swapped_sda_scl_is_found(self):
        dev = Bno085(0x4A, pins=("pin-tx", "pin-rx"))   # SDA a TX-en, SCL az RX-en
        f = front(dev)
        run(f, 0.02)
        self.assertEqual(f.get("bno-addr"), -1, "not found with the normal order")
        run(f, 1.0)
        self.assertEqual(f.get("bno-addr"), 0x4A)
        self.assertTrue(f.get("bno-swap"))
        self.assertEqual(f.vesc.i2c, ("rate-100k", "pin-tx", "pin-rx"))
        run(f, 1.0)
        self.assertEqual(f.get("bno-state"), "run")
        dev.report(*quat_from_euler(0.0, 12.0, 0.0))
        run(f, 0.01)
        self.assertAlmostEqual(f.get("bno-pitch"), 12.0, delta=0.05)
        text = " ".join(str(a) for p in f.vesc.printed for a in p)
        self.assertIn("felcserelve", text)

    def test_swap_order_kept_after_restart(self):
        dev = Bno085(0x4A, pins=("pin-tx", "pin-rx"))
        f = front(dev)
        run(f, 2.2)
        self.assertEqual(f.get("bno-state"), "run")
        run(f, 1.1)                 # nincs minta: újraindítás
        self.assertEqual(f.get("bno-restarts"), 1)
        t = run_until(f, "run", 3.5)
        self.assertLess(t, 1.95, "found again at the first try (the working order is kept)")
        self.assertTrue(f.get("bno-swap"))
        self.assertEqual(dev.resets, 2)

    def test_status_hint_when_missing(self):
        f = front(None)
        run(f, 1.5)
        f.call("bno")
        text = " ".join(str(a) for p in f.vesc.printed for a in p)
        self.assertIn("Nem talalhato", text)

    def test_address_0x4b(self):
        dev = Bno085(0x4B)
        f = front(dev)
        run(f, 1.2)
        self.assertEqual(f.get("bno-addr"), 0x4B)
        self.assertEqual(f.get("bno-state"), "run")

    def test_missing_sensor_keeps_retrying(self):
        f = front(None)
        run(f, 3.0)
        self.assertEqual(f.get("bno-state"), "detect")
        self.assertEqual(f.get("bno-addr"), -1)
        self.assertEqual(imu_frames(f), [])
        dev = Bno085()
        f.vesc.i2c_dev = dev   # később bedugva
        t = run_until(f, "run", 3.5)
        self.assertEqual(f.get("bno-state"), "run")
        self.assertLess(t, 3.0, "a keresés a két lábsorrendet váltogatva is hamar megtalálja")
        self.assertEqual(dev.feature, (0x08, 10000))

    def test_restart_when_reports_stop(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)
        dev.report(*quat_from_euler(0.0, 1.0, 0.0))
        run(f, 0.5)
        self.assertEqual(dev.resets, 1)
        run(f, 1.0)                 # 1 s-nál tovább nincs minta
        self.assertEqual(f.get("bno-restarts"), 1)
        run(f, 1.5)
        self.assertEqual(dev.resets, 2, "found again and reset")
        self.assertEqual(f.get("bno-state"), "run")

    def test_bno_status_prints(self):
        dev = Bno085()
        f = front(dev)
        run(f, 1.2)
        f.call("bno")
        self.assertTrue(f.vesc.printed)


class BnoRvcTests(unittest.TestCase):
    def feed(self, f, data):
        f.vesc.rx.extend(data)
        try:
            f.call("rvc-loop")
        except Blocked:
            pass

    def test_rvc_frames(self):
        f = front(None, mode="rvc")
        self.assertEqual(f.vesc.uart_started, (115200,), "full duplex: RX receives")
        self.assertIsNone(f.vesc.i2c)
        self.feed(f, [0x13, 0x00] + rvc_frame(7, -40.0, 25.0, 10.0))
        frames = imu_frames(f)
        self.assertEqual(len(frames), 1)
        roll, pitch, yaw, status, cnt = decode(frames[0])
        self.assertAlmostEqual(roll, 10.0)
        self.assertAlmostEqual(pitch, 25.0)
        self.assertAlmostEqual(yaw, -40.0)

    def test_rvc_bad_checksum_ignored(self):
        f = front(None, mode="rvc")
        bad = rvc_frame(1, 0.0, 30.0, 0.0)
        bad[-1] ^= 0x55
        self.feed(f, bad + rvc_frame(2, 0.0, 31.0, 0.0))
        frames = imu_frames(f)
        self.assertEqual(len(frames), 1)
        self.assertAlmostEqual(decode(frames[0])[1], 31.0)


if __name__ == "__main__":
    unittest.main()
