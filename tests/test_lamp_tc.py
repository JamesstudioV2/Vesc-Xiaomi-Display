"""Lámpa (kijelző + első vezérlő) és kipörgésgátló tesztek.

Run:  python3 -m unittest discover -s tests -v
"""
import unittest

from lbm_sim import Interp
from test_scripts import Rear, REAR, FRONT, STEP, FULL, IDLE


class Link:
    """Hátsó + első vezérlő a CAN-en összekötve (a hátsó parancsa az első
    on-cmd-jébe, az első visszajelzése a hátsó on-front-ack-jába megy)."""

    def __init__(self, p2=True):
        self.r = Rear()
        self.f = Interp()
        self.fv = self.f.vesc
        self.f.load(FRONT)
        self.f.call("init")
        self.r.v.can_devs = [12]
        self.rsent = 0
        self.fsent = 0
        if p2:
            self.r.thr = FULL
            self.step(int(1.0 / STEP))
            self.r.thr = IDLE
            self.step(int(0.5 / STEP))
        else:
            self.step(int(2.3 / STEP))

    def pump(self):
        for sid, data in self.r.v.can_tx[self.rsent:]:
            if sid == 0x4D0:
                self.f.call("on-cmd", bytearray(data))
        self.rsent = len(self.r.v.can_tx)
        for sid, data in self.fv.can_tx[self.fsent:]:
            if sid == 0x4D1:
                self.r.i.call("on-front-ack", sid, bytearray(data))
        self.fsent = len(self.fv.can_tx)

    def step(self, n=1):
        for _ in range(n):
            self.r.step(1)
            self.fv.now = self.r.v.now
            self.pump()

    def speeds(self, front_kmh, rear_kmh):
        """Új keréksebességek; az első friss visszajelzést küld (a mérés 50 Hz-es)."""
        self.fv.speed_ms = front_kmh / 3.6
        self.r.v.speed_ms = rear_kmh / 3.6
        self.f.call("send-ack")
        self.pump()

    def front_scale(self):
        """Az utolsó parancs áram %-a (mód x kipörgésgátló)."""
        frames = [d for sid, d in self.r.v.can_tx if sid == 0x4D0]
        return frames[-1][2]


class DashLightTests(unittest.TestCase):
    def test_dash_light_field_uses_stock_value(self):
        r = Rear()
        r.boot_p1()
        self.assertEqual(r.last_dash()[8], 0, "off")
        r.i.set("light", True)
        self.assertEqual(r.last_dash()[8], 100, "on: 0x64 like the stock controller (bit 6 = lamp)")
        self.assertEqual(r.last_dash()[8] & 0x40, 0x40)

    def test_dash_light_value_is_configurable(self):
        r = Rear()
        r.i.set("dash-light-value", 1)
        r.boot_p1()
        r.i.set("light", True)
        self.assertEqual(r.last_dash()[8], 1)


class FrontLampTests(unittest.TestCase):
    def test_ack_reports_lamp_pin_version_and_speed(self):
        L = Link(p2=False)
        L.fv.speed_ms = -12.3 / 3.6
        L.r.i.set("light", True)
        L.step(6)
        self.assertEqual(L.fv.out("pin-ppm"), 1, "front PPM drives the lamp MOSFET")
        ack = [d for sid, d in L.fv.can_tx if sid == 0x4D1][-1]
        self.assertEqual(len(ack), 8)
        self.assertEqual(ack[4] & 1, 1, "lamp command")
        self.assertEqual(ack[4] & 4, 4, "pin read back high")
        self.assertEqual(ack[5], 2, "script version")
        self.assertTrue(L.r.g("front-lamp"))
        self.assertEqual(L.r.g("front-pin"), 1)
        self.assertEqual(L.r.g("front-version"), 2)
        self.assertAlmostEqual(L.r.g("front-speed"), -12.3, places=5)

    def test_front_fault_reported(self):
        L = Link(p2=False)
        L.fv.fault = 4
        L.step(6)
        self.assertEqual(L.r.g("front-fault"), 4)

    def test_old_front_script_shows_error_60(self):
        r = Rear()
        r.v.can_devs = [12]
        r.boot_p1()
        for _ in range(int(3.0 / STEP)):
            r.step(1)
            r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, 0, 100]))  # 1-es verzió: 3 bájt
        self.assertEqual(r.g("front-version"), 1)
        self.assertTrue(r.g("front-old"))
        self.assertEqual(r.last_dash()[11], 60, "old front script: lamp and TC cannot work")

    def test_current_front_script_no_error(self):
        L = Link(p2=False)
        L.step(int(5.0 / STEP))
        self.assertFalse(L.r.g("front-old"))
        self.assertFalse(L.r.g("front-warn"))
        self.assertEqual(L.r.last_dash()[11], 0)

    def test_front_lamp_test_overrides_command_and_restores(self):
        f = Interp()
        f.load(FRONT)
        f.call("init")
        fv = f.vesc
        f.call("on-cmd", bytearray([0xA5, 3, 100, 0x27, 0x10, 0x3A, 0x98, 2]))  # lámpa KI
        f.set("lamp-test", True)
        f.call("on-cmd", bytearray([0xA5, 3 | 4, 100, 0x27, 0x10, 0x3A, 0x98, 2]))
        self.assertEqual(fv.out("pin-ppm"), 0, "the command does not touch the pin during the test")
        f.set("lamp-test", None)
        f.call("lampa-teszt")
        self.assertEqual(fv.out("pin-ppm"), 1, "after the test the commanded state (ON) is restored")
        self.assertIsNone(f.get("lamp-test"))
        text = " ".join(str(a) for p in fv.printed for a in p)
        self.assertIn("BE  (lab = 1)", text)
        self.assertIn("KI  (lab = 0)", text)

    def test_rear_lamp_test_runs_and_flags_old_front(self):
        r = Rear()
        r.boot_p1()
        r.i.call("lampa-teszt")
        text = " ".join(str(a) for p in r.v.printed for a in p)
        self.assertIn("REGI", text)
        self.assertIsNone(r.g("light"), "the original state is restored")


class TractionTests(unittest.TestCase):
    def test_on_by_default(self):
        L = Link()
        self.assertTrue(L.r.g("tc-on"))
        self.assertTrue(L.r.i.call("tc-active"))

    def test_rear_spin_reduces_rear_drive(self):
        L = Link()
        L.r.i.set("speedmode", 4)  # S: 100%
        L.r.i.call("apply-mode")
        L.speeds(20.0, 24.0)       # hátsó 4 km/h-val gyorsabb: 2 km/h a slip fölött
        L.step(3)
        self.assertAlmostEqual(L.r.v.conf["l-current-max-scale"], 0.33, places=2)
        self.assertEqual(L.front_scale(), 100, "the slower (front) wheel keeps full drive")

    def test_front_spin_reduces_front_drive(self):
        L = Link()
        L.r.i.set("speedmode", 4)
        L.r.i.call("apply-mode")
        L.speeds(30.0, 20.0)       # első 10 km/h-val gyorsabb: hajtás 0
        L.step(3)
        self.assertEqual(L.front_scale(), 0)
        self.assertEqual(L.fv.conf["l-current-max-scale"], 0.0, "applied on the front ESC")
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 1.0)

    def test_scaled_with_mode(self):
        L = Link()                 # D: 60% fázisáram
        L.speeds(20.0, 24.0)
        L.step(3)
        self.assertAlmostEqual(L.r.v.conf["l-current-max-scale"], 0.2, places=2)

    def test_within_allowed_slip_no_intervention(self):
        L = Link()
        L.speeds(20.0, 21.9)
        L.step(5)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6)
        self.assertEqual(L.front_scale(), 60)

    def test_slip_is_tunable(self):
        L = Link()
        L.r.i.set("tc-slip", 5.0)
        L.speeds(20.0, 24.0)
        L.step(3)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6)

    def test_recovery_is_gradual(self):
        L = Link()
        L.speeds(20.0, 30.0)
        L.step(3)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.0)
        L.speeds(25.0, 25.0)
        L.step(5)                  # 0.1 s a 0.3 s-os visszaállásból
        s = L.r.v.conf["l-current-max-scale"]
        self.assertGreater(s, 0.0)
        self.assertLess(s, 0.6)
        L.step(15)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6)

    def test_rolling_backwards_mirrors(self):
        L = Link()
        L.speeds(-20.0, -24.0)     # hátrafelé: a hátsó forog gyorsabban
        L.step(3)
        self.assertAlmostEqual(L.r.v.conf["l-current-max-scale"], 0.2, places=2)

    def test_not_in_profile1(self):
        L = Link(p2=False)
        L.speeds(10.0, 20.0)
        L.step(5)
        self.assertFalse(L.r.i.call("tc-active"))
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 1.0)

    def test_inactive_without_fresh_front_speed(self):
        L = Link()
        for _ in range(15):        # az első nem válaszol (0,3 s)
            L.r.step(1)
        L.fv.speed_ms = 10.0 / 3.6
        L.r.v.speed_ms = 20.0 / 3.6
        L.r.step(5)
        self.assertFalse(L.r.i.call("tc-active"))
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6)

    def test_old_front_gives_no_speed_so_no_tc(self):
        r = Rear()
        r.boot_p2()
        r.v.speed_ms = 30 / 3.6
        for _ in range(10):
            r.step(1)
            r.i.call("on-front-ack", 0x4D1, bytearray([0xA5, 3, 60]))
        self.assertFalse(r.i.call("tc-active"))


class TractionToggleTests(unittest.TestCase):
    def set_btn(self, r, pressed):
        r.v.gpio_in["pin-rx"] = 0 if pressed else 1

    def clicks(self, L, n):
        for _ in range(n):
            self.set_btn(L.r, True)
            L.step(4)
            self.set_btn(L.r, False)
            L.step(4)
        L.step(int(0.5 / STEP))

    def beeps(self, r, secs=1.5, since=None):
        """Sípolások a kijelzőkeretekben `since` óta (a kattintás közbeniek is)."""
        n = len(r.v.tx) if since is None else since
        for _ in range(int(secs / 0.05)):
            r.last_dash()
        return sum(f[9] for f in r.v.tx[n:])

    def test_three_clicks_toggle_with_three_beeps(self):
        L = Link()
        self.beeps(L.r)            # az induló sípolások
        n = len(L.r.v.tx)
        self.clicks(L, 3)
        self.assertIsNone(L.r.g("tc-on"))
        self.assertEqual(L.r.g("speedmode"), 1, "3 clicks is not a mode change")
        self.assertIsNone(L.r.g("light"))
        self.assertEqual(self.beeps(L.r, since=n), 3)
        L.speeds(10.0, 20.0)
        L.step(3)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6, "off: no intervention")
        n = len(L.r.v.tx)
        self.clicks(L, 3)
        self.assertTrue(L.r.g("tc-on"))
        self.assertEqual(self.beeps(L.r, since=n), 3)

    def test_beeps_are_spaced(self):
        L = Link()
        self.beeps(L.r)
        n = len(L.r.v.tx)
        self.clicks(L, 3)
        for _ in range(30):
            L.r.last_dash()
        frames = L.r.v.tx[n:]
        self.assertEqual(sum(f[9] for f in frames), 3)
        for a, b in zip(frames, frames[1:]):
            self.assertFalse(a[9] and b[9], "no two beep frames back to back")

    def test_not_available_in_profile1(self):
        L = Link(p2=False)
        self.beeps(L.r)
        n = len(L.r.v.tx)
        self.clicks(L, 3)
        self.assertTrue(L.r.g("tc-on"))
        self.assertEqual(L.r.g("speedmode"), 1)
        self.assertEqual(self.beeps(L.r, since=n), 0)

    def test_four_clicks_do_nothing(self):
        L = Link()
        self.beeps(L.r)
        n = len(L.r.v.tx)
        self.clicks(L, 4)
        self.assertTrue(L.r.g("tc-on"))
        self.assertEqual(L.r.g("speedmode"), 1)
        self.assertEqual(self.beeps(L.r, since=n), 0)


class TractionSetupTests(unittest.TestCase):
    def test_adc_app_tc_switched_off_at_boot(self):
        i = Interp()
        i.vesc.conf["adc-tc"] = 1
        i.load(REAR)
        i.call("init")
        self.assertEqual(i.vesc.conf["adc-tc"], 0)
        self.assertTrue(i.vesc.output_disabled, "switched while the output is still disabled")

    def test_adc_app_tc_left_alone_when_off(self):
        r = Rear()
        self.assertNotIn(("adc-tc", 0), r.v.conf_log)

    def test_front_commands_50hz_in_profile2(self):
        L = Link()
        n = len(L.r.v.can_tx)
        L.step(10)
        self.assertEqual(len(L.r.v.can_tx) - n, 10)
        L1 = Link(p2=False)
        n = len(L1.r.v.can_tx)
        L1.step(10)
        self.assertLessEqual(len(L1.r.v.can_tx) - n, 3)

    def test_status_and_tc_test_run(self):
        L = Link()
        L.r.i.call("status")
        L.r.i.call("tc-teszt")
        text = " ".join(str(a) for p in L.r.v.printed for a in p)
        self.assertIn("Kiporgesgatlo: BE", text)


if __name__ == "__main__":
    unittest.main()
