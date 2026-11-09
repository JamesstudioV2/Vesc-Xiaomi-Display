# VESC – Xiaomi M365 PRO 2 kijelző projekt

Ez a fájl a projekt állapotjegyzete. Minden Claude Code munkamenet automatikusan beolvassa.
**Minden munkamenet végén frissíteni, commitolni és pusholni kell**, mert a felhős gép törlődik.

## Cél
Xiaomi M365 PRO 2 kijelző egy dual motoros VESC rendszeren, LispBM scripttel.

**Ez az `Advanced-Balance` ág** (a felhasználó „Advanced Balance”-nek hívta, a git nem enged szóközt):
a `Balance` ágból indult, de a régi balansz mód (gáz + fék 1 s) helyett az **Advanced Balance** van benne.
A `main` és a `Balance` ágon nincs benne. Valódi rolleren még nincs kipróbálva.

## Hardver és döntések (rögzítve)
- Firmware: **VESC 7.00** mindkét vezérlőn.
- Kijelző: Xiaomi M365 PRO 2 BLE, a **hátsó** vezérlő COMM portján, half-duplex UART a TX lábon (115200).
- Kijelző gomb: **a kijelzőben** (eredeti helyén), a zöld vezeték a COMM **RX** lábán, **470 Ω** felhúzóval 3,3 V-ra,
  lenyomva GND. Digitális olvasás (`gpio-read`, `button-pin` = `'pin-rx`), pergésmentesítés: 3 minta le, 2 minta fel.
- **ADC1: szabad** (10 kΩ-mal GND-re ajánlott, hogy indításkor ne lebegjen).
- App to Use: csak `ADC` (UART-os appnál a `uart-start` véglegesen No App-ra állítja).
- Bluetooth: a kijelző BLE-je **nem** használható VESC Tool-hoz. Javaslat: VESC Express a CAN-en (kész modul, vagy
  DIY ESP32-S3 + SN65HVD230, a `S3 N16R8` / `S3 FH4R2` target CAN-je GPIO16 TX / GPIO17 RX). README: „Bluetooth (VESC Tool)”.
- Féklámpa: **PPM** láb → N-FET. Alapból folyamatosan ég, fékezéskor villog.
- Első lámpa: **ADC2** láb → N-FET, a gombbal kapcsolható.
- Gáz/fék: a kijelzőről → `app-adc-override` → ADC app (VESC Tool-ban hangolható). Control Type: Current No Reverse Brake ADC2.
- Dual: a hátsó ADC app „Multiple VESCs over CAN”, az első vezérlőn `elso_vezerlo.lisp`, saját CAN SID protokoll (0x4D0 parancs, 0x4D1 ack).
- Profilok: P1 (alap, „rendőr”) = csak hátsó motor, 3 km/h berúgás, ECO 6 km/h/100 W, S 25 km/h/500 W.
  P2 (bekapcsoláskor nyomva tartott gáz) = mindkét motor, nincs berúgás, S korlátlan, D korlátlan sebesség 60% fázisárammal, álló helyzetben akku % a kijelzőn.
- **Becsült, a felhasználó által nem megadott értékek:** P1 D = 20 km/h/300 W, P2 ECO = 25 km/h/50%, P1-ben az első motor fék nélkül, módsorrend D→S→ECO, hosszú gombnyomásnak nincs funkciója, induló mód D.

## Advanced Balance (Advanced-Balance ág) – döntések
- Csak 2-es profilban, `state` = 'run. **Be/ki: fékkar ≥ 0,5 + 2x gombnyomás** (fék nélkül a 2x továbbra is
  módváltás). Induláskor mindig ki (`ab-on` nil). Be: 2 sípolás; ki: 1; elutasítva/lekapcsolva: 3.
  Bekapcsolva a **lakat ikon** világít (a felhasználó kérésére a csavarkulcs helyett): mód bájt |= 32 (LOCK),
  a sebességmód bitjei, a sebesség és az akku megmaradnak (`ab-icon-mode` 'bit, `ab-icon-field` 0, `ab-icon-bit` 32).
  A kapcsolást a gomb csak kéri (`ab-toggle-req`), az AB szál hajtja végre, hogy a motorparancsok ne keveredjenek.
- Bekapcsolva az ADC app kimenete tiltva, a script vezérli **mindkét motort** 100 Hz-en (`ab-thread`):
  - gáz/fék: `get-adc-decoded` (VESC Tool kalibráció) → gáz − fék → holtjáték (`adc-thr-hyst`) →
    `throttle-curve` (`ab-throttle-exp`, a VESC Tool görbéje nem olvasható) → rámpa (`adc-ramp-time-pos/neg`,
    ugyanaz a logika, mint az ADC appban). Bekapcsoláskor rámpa nélkül veszi át (a fék nem gyengül).
  - fék (pwr < 0): `set-brake-rel` hátul, `canset-brake-rel` elöl → teljesen normál fék.
  - gáz (pwr ≥ 0): hátsó áram = min(pwr × Imax × tc-hátsó, korlát), slew 1000 A/s, `set-current`;
    első: `canset-current-rel` pwr × tc-első. Imax = `l-current-max` × `l-current-max-scale` (a mód szerint).
  - korlát (csak ha a szög > `ab-engage-angle` 3°): Kp 10 × (célszög − szög) − Kd 1,5 × szögsebesség (A).
    Negatív = fékez. Hátrafelé csak `ab-max-reverse` 3 km/h-ig (a modellben enélkül elszabadult a tolatás).
  - célszög: `ab-target-angle` (alap 20°), a kódban kézzel. Abszolút IMU-szög → emelkedőn is számít (doksiban).
  - kipörgésgátló: a gyorsabb kerék hajtása `ab-tc-slip` 3 km/h fölött csökken, + `ab-tc-range` 5 km/h-nál 0,
    szűrés `ab-tc-filter` 0,2. `canget-speed` a hátsó kerékadataival számol (azonos kerekek kellenek).
  - első vezérlő ID: `front-can-id` vagy az első a `can-list-devs`-ből.
- Lekapcsolás (motorok elengednek, AB ki, gázzár a felengedésig): roll > 60°, szög > 60° (hátra) vagy < −60°
  (előre, a felhasználó csak oldalra/hátra kérte, de baleset esetén ez is), nincs IMU adat. Sebességkorlát NINCS.
  Nincs kijelzőkeret → nincs gáz/fék, de az AB bekapcsolva marad.
- Az `(ikon-teszt)` végigkapcsolja a jelölt biteket (elsőként a lakatot), ha a kijelzőn mást kellene választani.
- Felfedezett eltérés (még nincs javítva egyik ágon sem): a lucidnx mérései szerint a lámpa mező a gyári
  vezérlőtől 0x64 (6-os bit), a mi kódunk 1-et küld; a D módot a gyári 0-val jelzi, mi 1-gyel. Visszajelzés kell.
- Modell (`tools/balansz_modell.py`): Kp 10 / Kd 1,5 / 1000 A/s mellett 0,3–1,2 Nm/A-nél megfogja a teljes gázos
  emelést és a menet közbeni 80°/s-os felrántást; 400 A/s-mal erős motornál túllendült/átfordult.
  Balanszpont mögötti célszögnél átfordul (fizikai korlát, doksiban).
- `tests/test_advanced_balance.py`: 35 teszt, benne zárt hurkú: korlát nélkül átfordul → 60°-nál lekapcsol;
  korláttal 10°-os célnál < 15°; 15 km/h-s 60°/s felrántás < 30°.

## Hibakódok (Advanced-Balance ág) – döntések
- A kijelző hibakód mezője (`err-shown`) a vezérlőszálban (`update-error`, 50 Hz) számolódik. Prioritás: VESC hiba →
  16/14/15 kar hiba → 57 első vezérlő hibája → 50 első nem válaszol → 58 AB lekapcsolás → 59 script hiba.
  Minden kód legalább `error-hold-time` 3 s-ig kint marad. Új hibánál konzol: `HIBA nn: ...`, előzmény (utolsó 8).
- Kar hiba: a nyers kijelzőérték < `lever-raw-min` 16 vagy > `lever-raw-max` 235 0,3 s-ig (a még éledő kijelző 0x0a-ja
  és az első 1 s nem számít). Ilyenkor nincs gáz (override = ADC start), hibás féknél fék sincs (0 V), gázzár a
  felengedésig; megszűnés 1 s jó jel után. 14 gáz, 15 fék, 16 mindkettő (közös táp). Hibás gázzal a P2 nem kapcsolható
  (a felhasználói teszt egy tápra zárlatos gázkarnál P2-t választott, javítva), hibás fékkel az AB sem.
- VESC hibák fordítása (`vesc-fault-code`): 1,2→24; 3,7,8,19→28; 4→51; 5→40; 6→52; 9→56; 10→31; 14,23,24→26;
  15/16/17→11/12/13; 18,27→54; 29→55; 31–33→53; enkóder (11–13,20–22,25,26,28,30)→18; egyéb→69. Táblázat: README „Hibakódok”.
- Az első vezérlő a visszajelzés 4. bájtjában küldi a saját `get-fault`-ját (a régi 3 bájtos ack-kal is működik) → 57.
- REPL: `(hibak)`. Tesztek: `tests/test_errors.py` (18).

## Fájlok
- `lisp/hatso_vezerlo.lisp`: fő script (kijelző, gomb, lámpák, profilok, berúgás, első vezérlő vezérlése).
- `lisp/elso_vezerlo.lisp`: az első vezérlő scriptje (korlátok CAN-ről, failsafe tiltás).
- `README.md`: magyar felhasználói leírás (bekötés, VESC Tool beállítás, próba).
- `docs/referencia-elemzes.md`: a referenciaprojektek elemzése, protokoll, 7.00-s firmware tudnivalók.
- `docs/bekotes.svg`: bekötési rajz.
- `tools/lisp_check.py` + `tools/fw7_00_symbols.txt`: statikus ellenőrző (`python3 tools/lisp_check.py lisp/*.lisp`).
- `tests/lbm_sim.py` + `tests/test_scripts.py` + `tests/test_advanced_balance.py` + `tests/test_errors.py`: szimulátor és tesztek
  (`python3 -m unittest discover -s tests`).
- `tools/balansz_modell.py`: az Advanced Balance szögkorlátjának modellje.

## Állapot
- 2026-11-09: Repó létrehozva. A korábbi beszélgetés kódja elveszett, újrakezdés.
- 2026-11-09: Referenciák elemezve (A-Emile, PierreDisplayDash, 1zun4 v2.1 [7.00], lucidnx [7.00], DDev247).
  Első teljes változat megírva mindkét vezérlőre. A statikus ellenőrzés és 35 szimulátoros teszt átment.
  **Valódi hardveren még nincs kipróbálva.**
- 2026-11-09: Felhasználói jelzés: **a gomb nem működik** (ADC1, felhúzva 3,3 V-ra, nyomásra GND).
  Valószínű ok: a fix 1,0 V-os küszöb. A kijelző terheli a zöld vezetéket, így gyenge felhúzóval
  (a README korábban 1–10 kΩ-ot írt) a nyugalmi szint 1 V alá esik, és a gomb „mindig lenyomva” állapotba kerül.
  Javítva: tanult nyugalmi szint + relatív küszöb + hiszterézis, 3/2 mintás pergésmentesítés, beragadás-
  újratanulás, `(gomb-teszt)` és gombnapló a konzolon, 1 kΩ felhúzó a doksiban.
  Közben javítva: az ADC app újraindulása (App beállítás írása) analógra állítja az ADC2-t, így elveszett
  a lámpakimenet. Mostantól 0,5 s-onként újra beállítjuk. A vezérlőciklus `trap`-pel védve, hiba esetén kiír és fut tovább.
  47 teszt átmegy. Az új gombtesztek a régi kóddal elbuktak (a diagnózist ez igazolja).
  **A felhasználó visszajelzése még kell:** `(gomb-teszt)` kimenete / működik-e.
- 2026-11-09: A felhasználó a gombot **visszakötötte a kijelzőbe** (mint a referenciákban): a zöld vezeték
  lenyomásra GND, 470 Ω felhúzó, ADC1 szabad. A kód át lett írva digitális RX-olvasásra (az analóg tanuló logika
  törölve). Az RX-et a `uart-start` után állítjuk be bemenetre, és 0,5 s-onként a kimenetekkel együtt újra beállítjuk.
  A doksi és a rajz frissítve. A firmware-ből ellenőrizve: a half-duplex `uart-start` nem nyúl az RX-hez, az appok
  csak az App típus vagy a Servo Output változásakor indulnak újra. 43 teszt átmegy.
- 2026-11-09: Kérdés: a kijelző Bluetooth-a használható-e VESC Tool-hoz (ha igen, `BLE` ágon kellett volna megírni).
  **Nem**, ezért nem készült BLE ág. Ellenőrizve: a VESC Tool (`bleuart.cpp`) NUS-t hirdető eszközt keres
  (Windows alatt mindet listázza), és nyers VESC-csomagokat küld rajta. A Xiaomi kijelző zárt firmware-e csak
  Xiaomi-kereteket közvetít, átalakítva (lucidnx: az app 0x01-es olvasását 0x61-ként, karadatokkal adja tovább),
  és kb. 3 kérés/s ütemben. PC-s híddal elvben átcsempészhető lenne, de lassú és csak PC-ről menne, ezért nem javasolt.
  A README kapott egy „Bluetooth (VESC Tool)” szakaszt a VESC Express ajánlással. Opcionális bővítésként felajánlva:
  Xiaomi-kompatibilis appok (pl. m365 Tools) támogatása a kijelző BLE-jén (adatok, lámpa, mód; VESC-beállítást nem tud).

- 2026-11-09: **Balance ág** létrehozva: balansz mód (egykerekes indulás). 67 teszt átmegy.
  Módosítva (felhasználói kérés): gázkitartás 70%, 30 km/h-nál sípolás + lejjebb engedés (nem nullára), kilépés 35-nél.
  69 teszt átmegy.
- 2026-11-09: **Advanced-Balance ág** létrehozva a Balance ágból (részletek fent). 78 teszt átmegy.
  A felhasználónak: (szog), irányteszt felemelt hátsó kerékkel.
- 2026-11-09: Advanced-Balance: lakat ikon a csavarkulcs helyett; hibakód-rendszer (14/15/16 kar hibák, VESC hibák
  gyári/saját kódokra, első vezérlő hibája, 3 s tartás, `(hibak)`), táblázat a README-ben. 97 teszt átmegy.

## Következő lépések
1. Gomb: visszajelzés kell, működik-e az RX-es bekötéssel (ha nem: `(gomb-teszt)` kimenete).
2. Hardveres próba felemelt kerékkel (README „Első próba” lista), visszajelzés a felhasználótól.
3. A becsült értékek (P1 D, P2 ECO, P1 első fék) megerősítése vagy javítása.
4. Lehetséges bővítések: halvány hátsó lámpa PWM-mel (`pwm-start` a PPM lábon), tempomat, zár mód, BMS,
   Xiaomi-app támogatás a kijelző BLE-jén (lucidnx mintájára), ha a felhasználó kéri.

## Munkaszabályok
- A kommunikáció magyarul folyik.
- A LispBM API-t a VESC 7.00 forrásából kell ellenőrizni (vedderb/bldc, `release_7_00` ág, `lispBM/README.md`, `lispBM/lispif_vesc_extensions.c`).
- Minden Lisp módosítás után futtatni kell a `tools/lisp_check.py`-t és a teszteket.
- A LispBM REPL fordítását (külső kód) a környezet tiltja, ezért a saját Python szimulátort kell használni.
- Munka végén: ez a fájl frissül, majd `git commit` + `git push`.
