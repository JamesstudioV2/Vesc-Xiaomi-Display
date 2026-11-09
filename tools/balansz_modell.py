#!/usr/bin/env python3
"""Durva modell az Advanced Balance szögkorlátjának becsléséhez.

Inga a hátsó tengely körül: a versenyző + roller súlypontja L magasan, phi
szöggel a függőlegestől (+ = előre). A roller szöge theta = theta_b - phi,
ahol theta_b az a szög, amelynél a súlypont pont a hátsó tengely fölött van
(balanszpont). A hátsó agymotor nyomatéka (Kt * áram) gyorsítja a rollert,
ez emeli az elejét. A vezérlés ugyanaz, mint a Lisp kódban: a hátsó áram
min(gáz * Imax, korlát), ahol korlát = Kp * (célszög - szög) - Kd * szögsebesség,
áramváltozás-korlát, hátramenet csak 3 km/h-ig.

Nincs benne: gumicsúszás, a versenyző mozgása (csak egy kezdeti felrántás),
az IMU gyorsulás miatti szöghibája, akkufeszültség-esés. A valódi hangolást
nem váltja ki, csak a nagyságrendet és az irányt mutatja.

Futtatás:  python3 tools/balansz_modell.py
"""
import math

G = 9.81


def run(kt=0.5, kp=10.0, kd=1.5, theta_b=12.0, target=10.0, imax=60.0, slew=1000.0,
        limiter=True, T=6.0, th0=0.0, w0=0.0, v0=0.0, m=105.0, L=1.0, r=0.125,
        engage=3.0, rev=3.0):
    phi = math.radians(theta_b - th0)
    w = math.radians(-w0)
    v = v0 / 3.6
    i = rate = 0.0
    prev = None
    t = 0.0
    dt = 0.01
    sub = 20
    h = dt / sub
    pwr = 0.0
    maxth = -99.0
    while t < T:
        th = theta_b - math.degrees(phi)
        if prev is None:
            prev = th
        rate += 0.3 * ((th - prev) / dt - rate)
        prev = th
        pwr = min(1.0, pwr + dt / 0.3)  # teljes gáz 0,3 s rámpával
        lim = (kp * (target - th) - kd * rate) if (limiter and th > engage) else 1e9
        if lim < 0 and v * 3.6 < -rev:
            lim = 0.0
        want = min(pwr * imax, lim)
        i += max(-slew * dt, min(slew * dt, want - i))
        for _ in range(sub):
            tau = kt * i
            a = tau / (r * m)
            acc = (G / L) * math.sin(phi) - (a / L) * math.cos(phi) - tau / (m * L * L)
            if theta_b - math.degrees(phi) <= 0.0 and acc > 0:  # az első kerék a földön
                w = 0.0
                phi = math.radians(theta_b)
            else:
                w += acc * h
                phi += w * h
            v += a * h
        t += dt
        th = theta_b - math.degrees(phi)
        maxth = max(maxth, th)
        if th > 60:
            return "ÁTFORDUL (%.2f s)" % t
    return "OK, legnagyobb szög %.1f° (cél %.0f°)" % (maxth, target)


def main():
    print("Balanszpont 12°, célszög 10°, teljes gáz, 60 A\n")
    print("korlát nélkül                 :", run(limiter=False))
    for kt in (0.3, 0.5, 0.8, 1.2):
        print("Kt %.1f Nm/A                  :" % kt, run(kt=kt))
    print("15 km/h, felrántás 60°/s      :", run(th0=8, w0=60, v0=15))
    print("15 km/h, felrántás 80°/s      :", run(th0=8, w0=80, v0=15))
    print("állva, felrántás 30°/s        :", run(th0=8, w0=30))
    print("célszög a balanszpont mögött  :", run(target=20))
    print("400 A/s áramváltozással, Kt1.2:", run(kt=1.2, slew=400))


if __name__ == "__main__":
    main()
