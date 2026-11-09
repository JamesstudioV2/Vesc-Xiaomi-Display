#!/usr/bin/env python3
"""Durva modell a balansz mód (egykerekezés) erősítéseinek becsléséhez.

Inga a hátsó tengely körül: a versenyző + roller súlypontja L magasan, phi
szöggel a függőlegestől (+ = előre, az eleje esik). A hátsó agymotor nyomatéka
(Kt * áram) gyorsítja a rollert, ez a gyorsulás és a motor reakciónyomatéka
emeli az elejét. A szabályzó ugyanaz, mint a Lisp kódban: PD, 100 Hz, áram-
korlát, áramváltozás-korlát, indításkor felfutás.

Nincs benne: gumicsúszás, a versenyző mozgása (csak egy 0,3 s-os lökés), az
IMU gyorsulás miatti szöghibája, akkufeszültség-esés. A valódi hangolást nem
váltja ki, csak a nagyságrendet mutatja.

Futtatás:  python3 tools/balansz_modell.py
"""
import math

G = 9.81


def run(kt, kp, kd, delay_steps=1, m=105.0, L=1.0, r=0.125, imax=40.0, slew=400.0,
        dt=0.01, T=8.0, push=60.0):
    phi = math.radians(2.0)
    w = v = i = 0.0
    hist = [phi] * (delay_steps + 1)
    rate = 0.0
    prev = None
    t = 0.0
    tail = []
    sub = 20
    h = dt / sub
    while t < T:
        meas = math.degrees(hist[0])  # hiba = phi, ha a célszög a balanszpont
        if prev is None:
            prev = meas
        rate += 0.3 * ((meas - prev) / dt - rate)
        prev = meas
        out = (kp * meas + kd * rate) * min(1.0, t / 0.3)
        out = max(-imax, min(imax, out))
        i += max(-slew * dt, min(slew * dt, out - i))
        for _ in range(sub):
            tau = kt * i
            a = tau / (r * m)
            dist = push if 1.0 < t < 1.3 else 0.0
            acc = (G / L) * math.sin(phi) - (a / L) * math.cos(phi) \
                - tau / (m * L * L) + dist / (m * L * L)
            w += acc * h
            phi += w * h
            v += a * h
        hist.pop(0)
        hist.append(phi)
        t += dt
        if t > T - 2:
            tail.append(math.degrees(phi))
        if abs(math.degrees(phi)) > 30:
            return "ESIK"
    return "OK (%.2f° lengés)" % (max(tail) - min(tail))


def main():
    print("Kt = a motor nyomatékállandója (Nm/A), késl. = mérés + szabályzó késése")
    for kt in (0.3, 0.5, 0.8, 1.2):
        for delay in (1, 3):
            row = []
            for kp, kd in ((6, 0.5), (8, 1.0), (12, 0.8), (20, 0.5)):
                row.append("kp %d / kd %.1f: %s" % (kp, kd, run(kt, kp, kd, delay)))
            print("Kt %.1f, késl. %d0 ms | %s" % (kt, delay, " | ".join(row)))


if __name__ == "__main__":
    main()
