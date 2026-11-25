"""Lámpa (kijelző + első vezérlő) és kipörgésgátló tesztek.

Run:  python3 -m unittest discover -s tests -v
"""
import unittest

from lbm_sim import Interp
from test_scripts import Rear, REAR, FRONT, STEP, FULL, IDLE


class Link:
    """Hátsó + első vezérlő a CAN-en összekötve (a hátsó parancsa az első
    on-cmd-jébe, az első visszajelzése a hátsó on-front-ack-jába megy)."""

    def __init__(self, p2=True, lamp_on_front=False):
        self.r = Rear()
        if lamp_on_front:
            self.r.i.set("headlight-on-front", True)
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
        L = Link(p2=False, lamp_on_front=True)
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
        r.i.set("headlight-on-front", True)
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

    def test_rear_spin_is_not_limited(self):
        L = Link()
        L.r.i.set("speedmode", 4)  # S: 100%
        L.r.i.call("apply-mode")
        L.speeds(20.0, 30.0)       # a hátsó 10 km/h-val gyorsabb
        L.step(5)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 1.0, "the TC never touches the rear")
        self.assertEqual(L.front_scale(), 100, "the slower front wheel keeps full drive")
        self.assertNotIn("tc-rear", L.r.i.g.vars)

    def test_front_partly_reduced(self):
        L = Link()
        L.r.i.set("speedmode", 4)
        L.r.i.call("apply-mode")
        L.speeds(24.0, 20.0)       # az első 4 km/h-val gyorsabb: 2 km/h a slip fölött
        L.step(3)
        self.assertEqual(L.front_scale(), 33)
        self.assertAlmostEqual(L.fv.conf["l-current-max-scale"], 0.33, places=2)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 1.0)

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
        L.speeds(24.0, 20.0)
        L.step(3)
        self.assertEqual(L.front_scale(), 20, "60% x 0.33")
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6)

    def test_within_allowed_slip_no_intervention(self):
        L = Link()
        L.speeds(20.0, 21.9)
        L.step(5)
        self.assertEqual(L.r.v.conf["l-current-max-scale"], 0.6)
        self.assertEqual(L.front_scale(), 60)

    def test_slip_is_tunable(self):
        L = Link()
        L.r.i.set("tc-slip", 5.0)
        L.speeds(24.0, 20.0)
        L.step(3)
        self.assertEqual(L.front_scale(), 60)

    def test_recovery_is_gradual(self):
        L = Link()
        L.speeds(30.0, 20.0)
        L.step(3)
        self.assertEqual(L.front_scale(), 0)
        L.speeds(25.0, 25.0)
        L.step(5)                  # 0.1 s a 0.3 s-os visszaállásból
        sc = L.front_scale()
        self.assertGreater(sc, 0)
        self.assertLess(sc, 60)
        L.step(15)
        self.assertEqual(L.front_scale(), 60)

    def test_rolling_backwards_mirrors(self):
        L = Link()
        L.speeds(-24.0, -20.0)     # hátrafelé: az első forog gyorsabban
        L.step(3)
        self.assertEqual(L.front_scale(), 20)

    def test_not_in_profile1(self):
        L = Link(p2=False)
        L.speeds(20.0, 10.0)
        L.step(5)
        self.assertFalse(L.r.i.call("tc-active"))
        self.assertEqual(L.r.g("tc-front"), 1.0)

    def test_inactive_without_fresh_front_speed(self):
        L = Link()
        for _ in range(15):        # az első nem válaszol (0,3 s)
            L.r.step(1)
        L.fv.speed_ms = 20.0 / 3.6
        L.r.v.speed_ms = 10.0 / 3.6
        L.r.step(5)
        self.assertFalse(L.r.i.call("tc-active"))
        self.assertEqual(L.r.g("tc-front"), 1.0)

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
        L.speeds(20.0, 10.0)
        L.step(3)
        self.assertEqual(L.front_scale(), 60, "off: no intervention")
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
        i.vesc.newer_fw = True          # 2026 júniusa utáni 7.00: ismeri az adc-tc-t
        i.vesc.conf["adc-tc"] = 1
        i.load(REAR)
        i.call("boot")
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


def printed(v):
    return " ".join(str(a) for p in v.printed for a in p)


class LampDiagnosisTests(unittest.TestCase):
    """A két (lampa-teszt) a végén kiírja, mire lehet következtetni."""

    def front(self):
        f = Interp()
        f.load(FRONT)
        f.call("init")
        return f

    def test_front_healthy_pin(self):
        f = self.front()
        f.call("lampa-teszt")
        self.assertIn("EREDMENY: a vezerlo laba rendben kapcsol", printed(f.vesc))
        self.assertIn("App to Use: 0", printed(f.vesc))

    def test_front_pin_stuck_low(self):
        f = self.front()
        f.vesc.gpio_in["pin-ppm"] = 0       # zárlatos gate vagy sérült láb: mindig 0
        f.call("lampa-teszt")
        self.assertIn("bekapcsolva sem megy magasra", printed(f.vesc))

    def test_front_warns_about_ppm_app(self):
        f = self.front()
        f.vesc.conf["app-to-use"] = 1
        f.call("lampa-teszt")
        self.assertIn("PPM app fut", printed(f.vesc))

    def cosim(self, L, pump=True):
        """A teszt alatti alvás közben a két vezérlő valóban fut és kommunikál."""
        def sleep(secs):
            for _ in range(max(1, int(round(secs / STEP)))):
                if pump:
                    L.step(1)
                else:
                    L.r.step(1)
            return True
        L.r.i.builtins["sleep"] = sleep

    def test_rear_verdict_healthy(self):
        L = Link(p2=False, lamp_on_front=True)
        self.cosim(L)
        L.r.i.call("lampa-teszt")
        text = printed(L.r.v)
        self.assertIn("Elso script verzio: 2 (rendben)", text)
        self.assertIn("lab 1, elso vezerlo parancs BE", text)
        self.assertIn("EREDMENY: a parancs eljut, az elso vezerlo PPM laba kapcsol", text)
        self.assertIsNone(L.r.g("light"), "the original state is restored")

    def test_rear_verdict_front_pin_stuck_low(self):
        L = Link(p2=False, lamp_on_front=True)
        L.fv.gpio_in["pin-ppm"] = 0
        self.cosim(L)
        L.r.i.call("lampa-teszt")
        self.assertIn("nem megy magasra", printed(L.r.v))

    def test_rear_verdict_front_silent(self):
        L = Link(p2=False, lamp_on_front=True)
        self.cosim(L, pump=False)
        L.r.v.now += 2.0
        L.r.i.call("lampa-teszt")
        self.assertIn("EREDMENY: az elso vezerlo nem koveti", printed(L.r.v))

    def test_headlight_on_rear_swd_pin(self):
        r = Rear()
        r.i.set("headlight-on-front", None)
        r.i.set("headlight-pin", __import__("lbm_sim").Symbol("pin-swdio"))
        r.i.call("boot")
        r.boot_p1()
        r.i.set("light", True)
        r.step(2)
        self.assertEqual(r.v.out("pin-swdio"), 1)
        self.assertNotIn("pin-adc2", r.v.gpio_mode)



class RearLampPinTests(unittest.TestCase):
    """A külső lámpa a hátsó vezérlő SWD csatlakozójának SWCLK lábán."""

    def cosim_rear(self, r):
        def sleep(secs):
            for _ in range(max(1, int(round(secs / STEP)))):
                r.step(1)
            return True
        r.i.builtins["sleep"] = sleep

    def test_rear_lamp_test_healthy(self):
        r = Rear()
        r.boot_p1()
        self.cosim_rear(r)
        r.i.call("lampa-teszt")
        text = printed(r.v)
        self.assertIn("SWCLK", text)
        self.assertIn("lampa BE -> lab 1, masik lab 1", text)
        self.assertIn("EREDMENY: SWCLK rendben kapcsol, SWDIO rendben kapcsol", text)
        self.assertIn("A vezerlo oldala jo", text)
        self.assertIsNone(r.g("light"), "the original state is restored")

    def test_rear_lamp_test_pin_stuck_low(self):
        r = Rear()
        r.boot_p1()
        r.v.gpio_in["pin-swclk"] = 0
        self.cosim_rear(r)
        r.i.call("lampa-teszt")
        self.assertIn("bekapcsolva sem megy magasra", printed(r.v))

    def test_pin_restored_after_app_restart(self):
        r = Rear()
        r.boot_p1()
        r.v.gpio_mode["pin-swclk"] = "pin-mode-in"
        r.step(int(0.6 / STEP))
        self.assertEqual(r.v.gpio_mode["pin-swclk"], "pin-mode-out")

    def test_both_swd_pins_carry_the_lamp(self):
        r = Rear()
        r.boot_p1()
        self.assertEqual(r.v.gpio_mode["pin-swclk"], "pin-mode-out")
        self.assertEqual(r.v.gpio_mode["pin-swdio"], "pin-mode-out")
        self.assertEqual((r.v.out("pin-swclk"), r.v.out("pin-swdio")), (0, 0))
        r.i.set("light", True)
        r.step(1)
        self.assertEqual((r.v.out("pin-swclk"), r.v.out("pin-swdio")), (1, 1))
        r.i.set("light", None)
        r.step(1)
        self.assertEqual((r.v.out("pin-swclk"), r.v.out("pin-swdio")), (0, 0))

    def test_second_pin_can_be_disabled(self):
        r = Rear()                       # (a konstruktor már az alapértékkel indította)
        r.i.set("headlight-pin2", None)
        r.v.gpio_mode.pop("pin-swdio")
        r.i.call("boot")
        r.boot_p1()
        r.i.set("light", True)
        r.step(int(0.6 / STEP))
        self.assertEqual(r.v.out("pin-swclk"), 1)
        self.assertNotIn("pin-swdio", r.v.gpio_mode)

    def test_lamp_on_swdio_only_still_found(self):
        """A vezeték valójában az SWDIO-n van, az SWCLK-t (pl. zárlat) 0-n tartja valami."""
        r = Rear()
        r.boot_p1()
        r.v.gpio_short.add("pin-swclk")
        self.cosim_rear(r)
        r.i.call("lampa-teszt")
        text = printed(r.v)
        self.assertIn("EREDMENY: SWCLK bekapcsolva sem megy magasra, SWDIO rendben kapcsol", text)
        self.assertIn("A vezerlo oldala jo", text)

    def test_lamp_test_beeps_at_each_on(self):
        r = Rear()
        r.boot_p1()
        self.cosim_rear(r)
        start = len(r.v.tx)
        r.i.call("lampa-teszt")
        beeps = sum(1 for f in r.v.tx[start:] if f[9] == 1)
        self.assertEqual(beeps, 6)
        lights = [f[8] for f in r.v.tx[start:]]
        self.assertIn(100, lights, "the dash lamp blinks with it")
        self.assertIn(0, lights)

    def test_open_drain_with_pullup(self):
        r = Rear()
        r.i.set("headlight-mode", __import__("lbm_sim").Symbol("pin-mode-od"))
        r.i.call("boot")
        r.v.od_pullup.update({"pin-swclk", "pin-swdio"})
        r.boot_p1()
        self.assertEqual(r.v.gpio_mode["pin-swclk"], "pin-mode-od")
        r.i.set("light", True)
        r.step(1)
        self.assertEqual(r.v.out("pin-swclk"), 1, "released, the 5 V pull-up lifts it")
        r.i.set("light", None)
        r.step(1)
        self.assertEqual(r.v.out("pin-swclk"), 0)

    def test_open_drain_without_pullup_is_reported(self):
        r = Rear()
        r.i.set("headlight-mode", __import__("lbm_sim").Symbol("pin-mode-od"))
        r.i.call("boot")
        r.boot_p1()
        self.cosim_rear(r)
        r.i.call("lampa-teszt")
        text = printed(r.v)
        self.assertIn("bekapcsolva sem megy magasra", text)
        self.assertIn("Nyitott drain modban", text)


class TcIconTests(unittest.TestCase):
    """Bekapcsolt kipörgésgátló (2-es profil): Bluetooth ikon bit a kijelzőnek."""

    def p2(self):
        r = Rear()
        r.boot_p2()
        r.thr = IDLE
        r.step(int(0.5 / STEP))
        self.assertEqual(r.g("profile"), 2)
        return r

    def test_icon_when_tc_on_in_p2(self):
        r = self.p2()
        self.assertTrue(r.g("tc-on"))
        self.assertEqual(r.last_dash()[8], 2, "lamp off, TC icon bit")
        r.i.set("light", True)
        self.assertEqual(r.last_dash()[8], 102, "lamp value + TC icon bit")

    def test_icon_follows_the_3_click_toggle(self):
        r = self.p2()
        r.i.call("tc-toggle")
        self.assertIsNone(r.g("tc-on"))
        self.assertEqual(r.last_dash()[8], 0)
        r.i.call("tc-toggle")
        self.assertEqual(r.last_dash()[8], 2)

    def test_no_icon_in_p1(self):
        r = Rear()
        r.boot_p1()
        self.assertTrue(r.g("tc-on"))
        f = r.last_dash()
        self.assertEqual(f[8], 0)
        self.assertEqual(f[6], 1)

    def test_icon_field_and_bit_configurable(self):
        r = self.p2()
        r.i.set("tc-icon-field", 0)
        r.i.set("tc-icon-bit", 8)
        f = r.last_dash()
        self.assertEqual(f[6], 1 + 8, "D mode + bit 8 in the mode byte")
        self.assertEqual(f[8], 0)
        r.i.set("tc-icon-field", -1)
        f = r.last_dash()
        self.assertEqual((f[6], f[8]), (1, 0), "-1 = no indicator")


class IconTestTests(unittest.TestCase):
    """(ikon-teszt): lépésenként egy érték a kijelzőnek, a lépés száma a sebesség helyén."""

    def run_test(self, r):
        seen = []

        def sleep(secs):
            seen.append(bytes(r.last_dash()))
            r.step(1)
            return True
        r.i.builtins["sleep"] = sleep
        r.i.call("ikon-teszt")
        return seen

    def test_steps(self):
        r = Rear()
        r.boot_p1()
        seen = self.run_test(r)
        self.assertEqual(len(seen), 14)
        self.assertEqual([f[10] for f in seen], list(range(1, 15)), "step number as the speed")
        self.assertEqual([f[8] for f in seen[:10]], [1, 2, 4, 8, 16, 32, 64, 128, 100, 255])
        self.assertEqual([f[6] for f in seen[10:]], [1 + 8, 1 + 32, 1 + 64, 1 + 128],
                         "mode bits are added to the D mode")
        self.assertEqual(r.g("dash-test-field"), -1)
        f = r.last_dash()
        self.assertEqual((f[6], f[8], f[10]), (1, 0, 0), "back to normal")
        self.assertIn("BT ikon: tc-icon-field 2, tc-icon-bit 2", printed(r.v))

    def test_tc_icon_suppressed_during_test(self):
        r = Rear()
        r.boot_p2()
        r.thr = IDLE
        r.step(int(0.5 / STEP))
        seen = self.run_test(r)
        self.assertEqual([f[8] for f in seen[10:]], [0, 0, 0, 0], "no TC bit while testing")
        self.assertEqual(r.last_dash()[8], 2, "TC icon back after the test")


class BootGlitchTests(unittest.TestCase):
    """A board.h induláskor minden láb kimeneti regiszterét 1-re állítja: a lámpa lába
    ne menjen magasra, mire a script 0-t ír (a felhasználó indulási villanást látott)."""

    def test_lamp_pins_never_high_at_boot(self):
        r = Rear()
        r.boot_p1()
        for pin in ("pin-swclk", "pin-swdio"):
            levels = [lvl for (_, p, lvl) in r.v.pin_log if p == pin]
            self.assertEqual(levels, [0], pin)

    def test_wrong_order_would_glitch(self):
        """A szimulátor észreveszi a hibás sorrendet (kimenet előbb, szint utána)."""
        i = Interp()
        i.run("(gpio-configure 'pin-swclk 'pin-mode-out)")
        i.run("(gpio-write 'pin-swclk 0)")
        self.assertEqual([lvl for (_, p, lvl) in i.vesc.pin_log if p == "pin-swclk"], [1, 0])

    def test_front_lamp_pin_never_high_at_boot(self):
        f = Interp()
        f.load(FRONT)
        f.call("init")
        self.assertEqual([lvl for (_, p, lvl) in f.vesc.pin_log if p == "pin-ppm"], [0])
