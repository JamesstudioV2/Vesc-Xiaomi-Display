# VESC – Xiaomi M365 PRO 2 kijelző projekt

Ez a fájl a projekt állapotjegyzete. Minden Claude Code munkamenet automatikusan beolvassa.
**Minden munkamenet végén frissíteni, commitolni és pusholni kell**, mert a felhős gép törlődik.

## Cél
Xiaomi M365 PRO 2 kijelző egy dual motoros VESC rendszeren, LispBM scripttel.

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
- Első lámpa: az **első vezérlő PPM lábán** → N-FET (`headlight-on-front` t). A hátsó a CAN parancs flags 2-es
  bitjével kapcsolja (`elso_vezerlo.lisp`: `light-pin`, üzenetkiesésnél az utolsó állapot marad). A hátsó ADC2-n
  nem működött (a felhasználó jelezte; valószínű ok: az ADC bemenet védő/szűrő köre a lapon).
  `headlight-on-front nil` = régi ADC2-es mód. Minden ágon (main, Balance, Advanced-Balance).
- Kijelző lámpája: a lámpa mezőbe **100 (0x64)** megy (`dash-light-value`), a 6-os bit kapcsolja a kijelző saját
  lámpáját (lucidnx). Az 1-es érték csak az ikont gyújtotta ki (ez volt a „csak az ikon jelenik meg” hiba).
- CAN visszajelzés (0x4D1) **2-es verzió**, 8 bájt: A5, flags, áram %, VESC hibakód, állapot (bit0 lámpa parancs,
  bit1 BNO friss, bit2 lámpa láb visszaolvasva), script-verzió (2), első sebesség (i16, 0,1 km/h). A hátsó
  `front-min-version` 2-t vár, régi első scriptnél a kijelzőn **60**-as hiba. Konzol: `(lampa-teszt)` mindkét
  vezérlőn, `(tc-teszt)` a hátsón, `(bno)` az elsőn.
- Kipörgésgátló (minden ágon egységesen): csak 2-es profilban, induláskor be, **3 kattintás** = be/ki + 3 sípolás.
  `tc-slip` 2 km/h engedélyezett különbség, `tc-range` 3 km/h alatt 0-ig, `tc-recover` 0,3 s visszaállás. A gyorsabb
  kerék `l-current-max-scale`-jét csökkenti (hátsó helyben, első a CAN parancs áram %-ában; ez a VESC „instant”
  conf-útja). Az ADC app saját TC-jét induláskor kikapcsolja (app-paraméter `conf-set` menet közben a Safe Start
  miatt elvenné a gázt, ld. referencia-elemzés). 2-es profilban a parancs 50 Hz-en megy. Sípolások között
  legalább 0,15 s (`beep-spacing`). 4+ kattintás: nincs funkció.
- BNO085 (a felhasználó „BMO085”-öt írt, a „COM2” portra kötötte): a VESC Tool nem ismeri. Feltételezés: a COM1 a
  hátsó, a COM2 az **első vezérlő COMM portja** (a 7.00-s Lisp csak a COMM portot éri el UART-ként, a második
  BLE/permanent UART lábait egyáltalán nem). Meghajtó az `elso_vezerlo.lisp`-ben: I2C SHTP (SDA = RX, SCL = TX,
  cím 0x4A/0x4B, soft reset, hirdetés kiolvasása, game rotation vector 0x08 100 Hz) vagy UART-RVC; roll/pitch/yaw
  CAN SID **0x4D2**-n (i16, 0,01°). `bno-enabled` main-en nil, a balansz ágakon t. Valódi szenzoron nincs kipróbálva.
- Gáz/fék: a kijelzőről → `app-adc-override` → ADC app (VESC Tool-ban hangolható). Control Type: Current No Reverse Brake ADC2.
- Dual: a hátsó ADC app „Multiple VESCs over CAN”, az első vezérlőn `elso_vezerlo.lisp`, saját CAN SID protokoll (0x4D0 parancs, 0x4D1 ack).
- Profilok: P1 (alap, „rendőr”) = csak hátsó motor, 3 km/h berúgás, ECO 6 km/h/100 W, S 25 km/h/500 W.
  P2 (bekapcsoláskor nyomva tartott gáz) = mindkét motor, nincs berúgás, S korlátlan, D korlátlan sebesség 60% fázisárammal, álló helyzetben akku % a kijelzőn.
- **Becsült, a felhasználó által nem megadott értékek:** P1 D = 20 km/h/300 W, P2 ECO = 25 km/h/50%, P1-ben az első motor fék nélkül, módsorrend D→S→ECO, hosszú gombnyomásnak nincs funkciója, induló mód D.

## Fájlok
- `lisp/hatso_vezerlo.lisp`: fő script (kijelző, gomb, lámpák, profilok, berúgás, első vezérlő vezérlése).
- `lisp/elso_vezerlo.lisp`: az első vezérlő scriptje (korlátok CAN-ről, failsafe tiltás).
- `README.md`: magyar felhasználói leírás (bekötés, VESC Tool beállítás, próba).
- `docs/referencia-elemzes.md`: a referenciaprojektek elemzése, protokoll, 7.00-s firmware tudnivalók.
- `docs/bekotes.svg`: bekötési rajz.
- `tools/lisp_check.py` + `tools/fw7_00_symbols.txt`: statikus ellenőrző (`python3 tools/lisp_check.py lisp/*.lisp`).
- `tests/lbm_sim.py` + `tests/test_scripts.py`: LispBM-részhalmaz szimulátor és tesztek (`python3 -m unittest discover -s tests`).
  `tests/test_lamp_tc.py` (lámpa, kipörgésgátló, két vezérlő CAN-en összekötve), `tests/test_bno085.py` (BNO085).

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

- 2026-11-09: **`Balance` ág** létrehozva (csak ott!): kísérleti balansz mód, egykerekes indulás a hátsó keréken
  2-es profilban (gáz + fék 1 s, felemelt elejével, álló helyzetből; a hátsó motor PD-vel tartja a szöget).
  A részletek az ág `CLAUDE.md`-jében és README-jében vannak. A `main`-be még nincs beolvasztva.
- 2026-11-09: **`Advanced-Balance` ág** létrehozva (a Balance ágból, csak ott!): fék + 2x gomb kapcsolja 2-es
  profilban; a hátsó áram = min(gáz, szögkorlát a kézzel beírt célszög körül), fékezhet is; csavarkulcs ikon;
  laza kipörgésgátló az első és hátsó kerék között; lekapcsolás 60° oldalra/hátra. Részletek az ág fájljaiban.
  Megtalált, még nem javított eltérés: a lucidnx szerint a lámpa ikon a lámpa mező 6-os bitje (gyári 0x64), mi 1-et küldünk.
- 2026-11-14: Felhasználói jelzés: a lámpa MOSFET a hátsó **ADC2**-n nem kapcsol, a PPM (féklámpa) működik.
  Firmware szerint az ADC láb kimenetnek állítható (`gpio-configure`, csak app-újraindításkor/Lisp betöltéskor áll
  vissza analógra, amit 0,5 s-onként pótolunk), így a hiba hardveres (az ADC bemenet védő/szűrő köre). A `main`-en
  a lámpa átkerült az **első vezérlő PPM lábára** (CAN flags bit2). 50 teszt átmegy.

- 2026-11-18: Felhasználói jelzés: lámpa nem kapcsol (ikon igen, a kijelző lámpája és a külső lámpa nem).
  Javítva: lámpa érték 100 (0x64). A külső lámpa kódja helyes volt; a legvalószínűbb ok, hogy az első vezérlőn a
  régi script fut (az is nyugtáz, hiba nélkül). Mostantól a visszajelzés verziót és lámpaállapotot hordoz, régi
  első scriptnél 60-as hiba, `(lampa-teszt)` mindkét vezérlőn. Kipörgésgátló + BNO085 meghajtó (ld. fent).
  A szimulátor bővült (i16/u32, little-endian, assoc/acons, atan2/asin, I2C + szimulált BNO085 SHTP eszköz,
  EEPROM), az AB ág szimulátora a main alapja lett. 87 teszt átmegy.

## Következő lépések
1. Lámpa: visszajelzés kell az új scriptekkel (mindkét vezérlőre fel kell tölteni!), ha nem megy:
   `(lampa-teszt)` kimenete a hátsón és az elsőn. Kipörgésgátló hangolása (`tc-slip`, `tc-range`).
   BNO085: meg kell erősíteni, hogy a „COM2” az első vezérlő COMM portja, és I2C-n van-e bekötve.
   Gomb: működik-e az RX-es bekötéssel (ha nem: `(gomb-teszt)` kimenete).
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
