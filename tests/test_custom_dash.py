"""Az egyedi kijelző-firmware (M365_Display_Costum_BLE) támogatása a hátsó scriptben:
HELLO / HELLO_ACK felismerés, LED felülírás (kipörgésgátló jelzés), stílus, név,
VESC Tool alagút (cmds-proc + event-cmds-data-tx) kredittel.

Futtatás: python3 -m unittest discover -s tests -v
"""
import unittest

from lbm_sim import LString, check_xiaomi_crc, xiaomi_frame
from test_scripts import IDLE, Rear


def ext_frames(r, sub=None, since=0):
    out = []
    for f in r.v.ext_tx[since:]:
        f = list(f)
        assert check_xiaomi_crc(f), f
        assert f[:2] == [0x55, 0xAA] and f[3] == 0x21 and f[4] == 0x7A, f
        assert f[2] == len(f) - 6, "len = payload + 2"
        if sub is None or f[5] == sub:
            out.append(f)
    return out


def payload(f):
    return f[6:-2]


class Dash:
    """Az egyedi kijelző (a firmware viselkedése) a busz túloldalán."""

    def __init__(self, r):
        self.r = r

    def frame(self, sub, extra=(), thr=IDLE, brk=IDLE):
        self.r.feed(xiaomi_frame(0x20, 0x7A, sub, [0x04, thr, brk, 0, 0] + list(extra)))

    def hello_ack(self, major=1, minor=0):
        self.frame(0x81, [1, major, minor, 0xFF, 0x00])

    def status(self, ble=1, mode=2, credit=1000):
        self.frame(0x82, [ble, mode, credit & 0xFF, credit >> 8])

    def tunnel_up(self, data=b'', credit=1000):
        self.frame(0xA0, [credit & 0xFF, credit >> 8] + list(data))

    def poll(self, cmd=0x65):
        self.r.feed(xiaomi_frame(0x20, cmd, 0x00, [0x04, IDLE, IDLE, 0, 0]))


def custom_rear(**settings):
    r = Rear()
    for k, v in settings.items():
        r.i.set(k, v)
    d = Dash(r)
    r.v.now += 0.05
    d.poll(0x64)                 # a 0x64-re: állapot + HELLO
    d.hello_ack()
    r.v.now += 0.05
    return r, d


class HelloTests(unittest.TestCase):
    def test_hello_after_status_once_per_second(self):
        r = Rear()
        d = Dash(r)
        d.poll(0x64)
        self.assertEqual(len(r.v.tx), 1, "the stock status reply is unchanged")
        h = ext_frames(r, 0x01)
        self.assertEqual(len(h), 1)
        self.assertEqual(payload(h[0]), [1, 0])
        self.assertEqual(r.v.tx_all.index(r.v.ext_tx[0]), 1, "HELLO comes after the status frame")
        for _ in range(10):          # 0.5 s: no new HELLO
            r.v.now += 0.05
            d.poll(0x64)
        self.assertEqual(len(ext_frames(r, 0x01)), 1)
        r.v.now += 0.6
        d.poll(0x64)
        self.assertEqual(len(ext_frames(r, 0x01)), 2)
        d.poll(0x65)
        self.assertEqual(len(ext_frames(r, 0x01)), 2, "HELLO only after a 0x64")

    def test_no_hello_when_disabled(self):
        r = Rear()
        r.i.set("dash-ext", None)
        Dash(r).poll(0x64)
        self.assertEqual(r.v.ext_tx, [])

    def test_hello_ack_marks_custom_dash(self):
        r, d = custom_rear()
        self.assertTrue(r.g("dash-custom"))
        self.assertEqual(r.g("dash-fw"), 10)
        self.assertTrue(any("felismerve" in str(p) for p in r.v.printed))

    def test_ext_frames_carry_levers(self):
        r, d = custom_rear()
        d.frame(0x82, [1, 2, 0, 4], thr=0x80, brk=0x40)
        self.assertAlmostEqual(r.v.override[0], 0x80 / 77.27, places=4)
        self.assertAlmostEqual(r.v.override[1], 0x40 / 77.27, places=4)

    def test_status_frame(self):
        r, d = custom_rear()
        d.status(ble=1, mode=2, credit=777)
        self.assertEqual((r.g("dash-ble"), r.g("dash-ble-mode"), r.g("dash-credit")), (1, 2, 777))

    def test_custom_dash_forgotten_after_silence(self):
        r, d = custom_rear()
        r.step(int(6.0 / 0.02), frames=True)        # csak gyári keretek jönnek
        self.assertFalse(r.g("dash-custom"))

    def test_one_ext_frame_per_dash_frame(self):
        r, d = custom_rear(**{"ble-name": LString("Roller")})
        n = len(r.v.ext_tx)
        d.poll(0x65)
        self.assertEqual(len(r.v.ext_tx), n + 1)
        d.poll(0x65)
        self.assertLessEqual(len(r.v.ext_tx), n + 2)


class StyleNameTests(unittest.TestCase):
    def test_name_then_style_keepalive(self):
        r, d = custom_rear(**{"ble-name": LString("Roller-VESC"), "speed-color": 1})
        d.poll()
        names = ext_frames(r, 0x17)
        self.assertEqual(len(names), 1)
        self.assertEqual(bytes(payload(names[0])), b"Roller-VESC")
        d.poll()
        st = ext_frames(r, 0x13)
        self.assertEqual(len(st), 1)
        self.assertEqual(payload(st[0]), [1, 1, 0], "speed red, error red, charge white")
        for _ in range(10):
            r.v.now += 0.05
            d.poll()
        self.assertEqual(len(ext_frames(r, 0x13)), 1, "keepalive only once per second")
        r.v.now += 0.6
        d.poll()
        self.assertEqual(len(ext_frames(r, 0x13)), 2)

    def test_no_name_by_default(self):
        r, d = custom_rear()
        for _ in range(3):
            d.poll()
        self.assertEqual(ext_frames(r, 0x17), [])

    def test_dash_text_one_shot(self):
        r, d = custom_rear()
        d.poll()                                   # a stílus/életjel előbb megy
        r.i.run('(dash-text "P2" 1 20)')
        for _ in range(4):                         # a felülírás és az életjel előbb mehet
            d.poll()
        t = ext_frames(r, 0x12)
        self.assertEqual(len(t), 1)
        self.assertEqual(payload(t[0]), [20, 0, 1, ord("P"), ord("2")])
        d.poll()
        self.assertEqual(len(ext_frames(r, 0x12)), 1, "sent once")


class TcLedTests(unittest.TestCase):
    def setUp(self):
        self.r, self.d = custom_rear()
        self.r.boot_p2()
        self.d.poll()

    def seg_frames(self, since=0):
        return [payload(f) for f in ext_frames(self.r, 0x10, since)]

    def test_tc_led_on_in_profile2(self):
        self.assertTrue(self.r.g("tc-on"))
        segs = self.seg_frames()
        self.assertTrue(segs)
        p = segs[-1]
        self.assertEqual(len(p), 19)
        self.assertEqual(p[0], 15, "ttl 1.5 s, refreshed")
        self.assertEqual(p[1:7], [0, 0, 0, 0, 0, 64], "Bluetooth icon on")
        self.assertEqual(p[7:13], [0] * 6)
        self.assertEqual(p[13:19], [0] * 6)

    def test_refreshed_every_half_second(self):
        self.r.v.now += 0.6
        self.d.poll()                            # most frissült
        n = len(self.seg_frames())
        for _ in range(5):
            self.r.v.now += 0.05
            self.d.poll()
        self.assertEqual(len(self.seg_frames()), n)
        self.r.v.now += 0.3
        self.d.poll()
        self.assertEqual(len(self.seg_frames()), n + 1)

    def test_blinks_while_intervening(self):
        self.r.i.set("tc-front", 0.5)
        self.d.poll()
        p = self.seg_frames()[-1]
        self.assertEqual(p[1:7], [0] * 6)
        self.assertEqual(p[13:19], [0, 0, 0, 0, 0, 64], "blinking while TC cuts the front")

    def test_cleared_when_switched_off(self):
        self.r.i.call("tc-toggle")
        self.d.poll()
        p = self.seg_frames()[-1]
        self.assertEqual(p[0], 0, "ttl 0 = clear")
        n = len(self.seg_frames())
        self.r.v.now += 1.0
        self.d.poll()
        self.assertEqual(len(self.seg_frames()), n, "nothing to refresh")

    def test_led_is_configurable(self):
        self.r.i.set("tc-seg-byte", 4)
        self.r.i.set("tc-seg-bit", 128)
        self.r.v.now += 0.6
        self.d.poll()
        self.assertEqual(self.seg_frames()[-1][1:7], [0, 0, 0, 0, 128, 0])
        self.r.i.set("tc-seg-byte", -1)
        self.d.poll()
        self.assertEqual(self.seg_frames()[-1][0], 0, "disabled -> cleared")

    def test_led_test_lights_one_led_only(self):
        self.r.i.set("dash-seg-test", 13)       # 1. bájt, 5. bit
        self.d.poll()
        p = self.seg_frames()[-1]
        self.assertEqual(p[1:7], [0, 32, 0, 0, 0, 0])
        self.assertEqual(p[7:13], [0xFF] * 6, "every other LED off")

    def test_led_teszt_runs(self):
        self.r.i.call("led-teszt")
        self.assertEqual(self.r.g("dash-seg-test"), -1)
        self.assertGreaterEqual(len(self.r.v.printed), 48)


class TunnelTests(unittest.TestCase):
    def test_cmds_started_at_boot(self):
        r = Rear()
        self.assertTrue(r.v.cmds_started)
        self.assertTrue(r.g("cmds-started"))
        self.assertIn(("event-cmds-data-tx",), [tuple(str(x) for x in e) for e in r.v.events])

    def test_cmds_not_started_when_disabled(self):
        r = Rear.__new__(Rear)
        from lbm_sim import Interp
        from test_scripts import REAR
        r.i = Interp()
        r.v = r.i.vesc
        r.i.load(REAR)
        r.i.set("ble-vesc-tool", None)
        r.i.call("boot")
        self.assertFalse(r.v.cmds_started)
        self.assertIsNone(r.g("tun-buf"))

    def test_start_failure_keeps_everything_else(self):
        from lbm_sim import Interp
        from test_scripts import REAR
        i = Interp()
        i.vesc.cmds_fail = True
        i.load(REAR)
        i.call("boot")
        self.assertFalse(i.get("cmds-started"))
        i.vesc.rx.extend(xiaomi_frame(0x20, 0x64, 0x00, [0x06, IDLE, IDLE, 0, 0, 0x90, 0]))
        try:
            i.call("rx-loop")
        except Exception:
            pass
        self.assertEqual(len(i.vesc.tx), 1, "the dash is still answered")

    def test_up_goes_to_cmds_proc(self):
        r, d = custom_rear()
        req = bytes([0x02, 0x01, 0x00, 0x00, 0x00, 0x03])
        d.tunnel_up(req, credit=900)
        self.assertEqual(bytes(r.v.cmds_in), req)
        self.assertEqual(r.g("dash-credit"), 900)
        self.assertGreaterEqual(r.v.freed, 1, "the temporary array is freed")

    def test_long_up_frame(self):
        r, d = custom_rear()
        data = bytes(range(200))
        d.tunnel_up(data)
        self.assertEqual(bytes(r.v.cmds_in), data, "frames up to len 255 are read")

    def test_down_chunks_credit_and_wraparound(self):
        r, d = custom_rear()
        d.poll()
        d.poll()                                  # a stílus előbb megy
        d.status(credit=250)
        answer = bytes((i * 7) & 0xFF for i in range(1400))
        got = bytearray()
        r.i.call("tun-push", bytearray(answer[:700]))
        r.i.call("tun-push", bytearray(answer[700:]))
        self.assertEqual(r.i.call("tun-used"), 1400)
        for _ in range(3):
            d.poll()
        downs = ext_frames(r, 0x20)
        self.assertEqual([len(payload(f)) for f in downs], [100, 100, 50], "<= 100 bytes, <= credit")
        d.poll()
        self.assertEqual(len(ext_frames(r, 0x20)), 3, "credit used up: wait")
        for k in range(30):
            d.tunnel_up(b'', credit=1000)         # a kijelző új kreditet jelent
            if r.i.call("tun-used") == 0:
                break
        for f in ext_frames(r, 0x20):
            got.extend(payload(f))
        self.assertEqual(bytes(got), answer)
        # a gyűrű többször körbeért
        r.i.call("tun-push", bytearray(answer))
        for k in range(30):
            d.tunnel_up(b'', credit=1000)
        got = bytearray()
        for f in ext_frames(r, 0x20)[len(ext_frames(r, 0x20)) - 14:]:
            got.extend(payload(f))
        self.assertEqual(bytes(got), answer)

    def test_overflow_drops_whole_reply(self):
        r, d = custom_rear()
        size = r.g("tun-size")
        r.i.call("tun-push", bytearray(size - 100))
        r.i.call("tun-push", bytearray(200))
        self.assertEqual(r.i.call("tun-used"), size - 100)

    def test_no_down_without_custom_dash(self):
        r = Rear()
        r.i.call("tun-push", bytearray(b"\x02\x01\x00"))
        Dash(r).poll(0x64)
        self.assertEqual(ext_frames(r, 0x20), [])


if __name__ == "__main__":
    unittest.main()
