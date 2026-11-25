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
- Első (külső) lámpa: **a hátsó vezérlő SWD csatlakozójának SWCLK lábán** → N-FET (2026-11-23, a felhasználó kérése:
  `headlight-on-front nil`, `headlight-pin 'pin-swclk`; az SWCLK-t a processzor induláskor lehúzza, így bootoláskor
  nem villan fel). 2026-11-23 (5): ugyanaz a jel az **SWDIO**-n is (`headlight-pin2 'pin-swdio`, nil = ki), mert a
  felhasználónál az SWCLK-ra kötve sem ment; `headlight-mode` `'pin-mode-out` (alap) vagy `'pin-mode-od` (1 kΩ 5V-ra,
  5 V-os gate; PA13/PA14 5 V-tűrő). Előtte: hátsó ADC2 (nem működött, az ADC bemenet védőköre), majd az első vezérlő PPM lába (nem
  működött, valószínű nyáksérülés). Opció: `headlight-on-front t` = az első PPM lábán, CAN flags bit2, az első
  `light-pin`. A `'pin-ppm` a 75_100_V2 / MKSESC V2 lapokon PB6 (TIM4 CH1). Minden ágon.
- Kijelző lámpája: a lámpa mezőbe **100 (0x64)** megy (`dash-light-value`), a 6-os bit kapcsolja a kijelző saját
  lámpáját (lucidnx). Az 1-es érték csak az ikont gyújtotta ki (ez volt a „csak az ikon jelenik meg” hiba).
  A 0x64 a gyári vezérlő értéke (camcamfresh, Arduino-fórum: „0x64 = on”); a Koxx3 SmartESC m365 0/1-et küld.
  A kijelző lámpája a kijelző tápjáról (VESC 5V) ég (gyári M365-ön ~4,1 V jön fel). A felhasználónál 100-zal
  sem ég (2026-11-23): `(ikon-teszt)` 7. (64) / 9. (100) lépés, ha egyiknél sem: táp / lámpa bekötés.
- Kipörgésgátló jelzése: bekapcsolt TC-nél (2-es profil) a **Bluetooth ikon** (a felhasználó kérése, 2026-11-23).
  A BT ikon bitje sehol nincs dokumentálva (a gyári kijelzőn a saját BLE modulja kapcsolja), ezért konfigurálható:
  `tc-icon-field` (alap 2 = lámpa mező) + `tc-icon-bit` (alap 2) = **becslés**. `(ikon-teszt)`: 14 lépés, 3 s,
  a lépés száma a sebesség helyén: lámpa mező 1,2,4,…,128,100,255 (csere), mód mező +8,+32,+64,+128 (hozzáadva);
  teszt közben a TC jelzés szünetel.
- CAN visszajelzés (0x4D1) **2-es verzió**, 8 bájt: A5, flags, áram %, VESC hibakód, állapot (bit0 lámpa parancs,
  bit1 BNO friss, bit2 lámpa láb visszaolvasva), script-verzió (2), első sebesség (i16, 0,1 km/h). A hátsó
  `front-min-version` 2-t vár, régi első scriptnél a kijelzőn **60**-as hiba. Konzol: `(lampa-teszt)` mindkét
  vezérlőn, `(tc-teszt)` a hátsón, `(bno)` az elsőn.
- Kipörgésgátló (minden ágon egységesen): csak 2-es profilban, induláskor be, **3 kattintás** = be/ki + 3 sípolás.
  **Csak az első kereket korlátozza a hátsóhoz képest, a hátsóba nem avatkozik bele** (2026-11-23, a felhasználó
  kérése; nincs `tc-rear`). `tc-slip` 2 km/h (ennyivel lehet gyorsabb az első), `tc-range` 3 km/h alatt 0-ig,
  `tc-recover` 0,3 s visszaállás. Az első vezérlő `l-current-max-scale`-jét csökkenti (a CAN parancs áram %-a;
  ez a VESC „instant” conf-útja). Az ADC app saját TC-jét induláskor kikapcsolja (app-paraméter `conf-set` menet közben a Safe Start
  miatt elvenné a gázt, ld. referencia-elemzés). 2-es profilban a parancs 50 Hz-en megy. Sípolások között
  legalább 0,15 s (`beep-spacing`). 4+ kattintás: nincs funkció.
- BNO085 (a felhasználó „BMO085”-öt írt, a „COM2” portra kötötte): a VESC Tool nem ismeri. Feltételezés: a COM1 a
  hátsó, a COM2 az **első vezérlő COMM portja** (a 7.00-s Lisp csak a COMM portot éri el UART-ként, a második
  BLE/permanent UART lábait egyáltalán nem). Meghajtó az `elso_vezerlo.lisp`-ben: I2C SHTP (SDA = RX, SCL = TX,
  cím 0x4A/0x4B, soft reset, hirdetés kiolvasása, game rotation vector 0x08 100 Hz) vagy UART-RVC; roll/pitch/yaw
  CAN SID **0x4D2**-n (i16, 0,01°). `bno-enabled` main-en nil, a balansz ágakon t. Valódi szenzoron nincs kipróbálva.
  **Megerősítve (2026-11-18):** a felhasználó a BNO085-öt az első vezérlő **COM1** portjára kötötte, **I2C**-n. A lapokon
  COM1 = COMM (UART3, `'pin-rx`/`'pin-tx`, a hátsón ezen a kijelző), COM2 = a második (BLE/permanent UART) port.
  A keresés felváltva próbálja a két SDA/SCL sorrendet (`bno-swap`), az I2C 100 kHz (`bno-i2c-rate`), a `(bno)`
  szöveges tippet is ad.
- **Firmware alapvonal: a KIADOTT 7.00** (bldc 26af694 „Release 7.00”, 2026-05-15). A release_7_00 ág később kapott
  paramétereket (`adc-v2-start/end` 2026-06-09, `adc-tc` 2026-06-13), ezekre a kiadott firmware `conf-get`-je
  „Parameter not recognized” hibát dob, ami a hívó szálat leállítja. Ilyet csak `conf-try` / `conf-set-try`
  (trap + alapérték) használhat. A `tools/fw7_00_symbols.txt` a kiadott 7.00-ból van generálva, a szimulátor
  (`NEWER_PARAMS`) alapból a kiadottat utánozza, és UART-indítás nélkül nem enged UART-ot.
- **Névszabály:** `ext-` kezdetű nevet TILOS definiálni (def/defun/var/paraméter): a LispBM olvasó minden ilyen
  szimbólumot a kiterjesztés-táblába tesz (natív könyvtáraknak), és a definiálás betöltéskor „Cannot redefine
  built-in” hibával leállítja az egész scriptet. A `tools/lisp_check.py` és a szimulátor ezt (és a beépített nevek
  felüldefiniálását, a `@const-start` utáni felső szintű `def`-et) hibának jelzi.
- **Szöveghossz-szabály:** egy szöveg (string) vagy szimbólum legfeljebb **256 bájt** lehet
  (`lispBM/include/tokpar.h`: `TOKENIZER_MAX_SYMBOL_AND_STRING_LENGTH 256`), a hosszabbnál a betöltés
  **`read_error`**-ral leáll (2026-11-25, a felhasználó képernyőképe: AB hátsó, 1460. sor 29. oszlop, 387 bájt).
  Hosszú konzolüzenet = több rövid `print`. Az ellenőrző és a szimulátor olvasója ezt is hibának jelzi.
  A teljes forrás (a VESC Tool kommentekkel együtt tölti fel) legfeljebb 128 KB (`flash_helper.c`,
  `LISP_MAX_SIZE`); 2026-11-25-én az AB hátsó script 76 KB, a main hátsó ~40 KB.
- **SWD lábak induláskor (firmware):** `hwconf/board.h` minden láb ODR-jét 1-re állítja, a PA13/PA14 lebeg (nincs
  pull); a `main.c` `should_reset_config()` a PA14-et (SWCLK) rövid ideig kimenetként hajtja, és ha a HALL2 követi,
  **törli a beállításokat** (HALL2–SWCLK jumper). Ezért a script előbb `gpio-write`, utána `gpio-configure`
  (különben egy pillanatra magas), és a gate-re 10 kΩ lehúzó kell. A felhasználó „induláskor felvillan” jelzése
  ebből jön; ez nem bizonyítja, hogy a MOSFET 3,3 V-tal nyit (a lebegő gate magasabbra is töltődhet).
- Indulás: `boot` = `init` (motorkimenet tiltás, féklámpa, pufferek, **kijelző UART + rx szál elsőként**) + `init-rest`
  (ADC TC, gáz-kalibráció, mód, CAN), mindkettő `trap`-ben, hiba esetén `hiba-init...` a konzolon.
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
  A bekötési rajz javítva: a lámpa N-FET gate-vezetéke a hátsó VESC „CAN” feliratától indult (félrevezető, lehet,
  hogy ez is oka a hibának), most egyértelműen az első VESC PPM jelére megy; BNO085 is felkerült.
  Átvezetve: **Balance** (BNO085 a balansz szöge, balansz alatt nincs TC; 123 teszt) és **Advanced-Balance**
  (két kipörgésgátló AB módban: az általános 3x gombos + az eredeti laza AB-TC, külön hangolható; fék + 5x gomb álló
  helyzetben = célszög mentés EEPROM-ba, 5 sípolás + a kijelző mutatja, hiba 61; BNO085 a szög, IMU nélkül 62;
  161 teszt). Részletek az ágak CLAUDE.md-jében.

- 2026-11-23: Felhasználói jelzés: az új scriptekkel **a kijelző kommunikációja el sem indul** (main és AB is).
  Ok: az új `init` a kijelző UART előtt `(conf-get 'adc-tc)`-t hívott; a kiadott 7.00-s firmware ezt nem ismeri
  (2026-06-13-i commit), a hiba leállította az init-et (az AB/Balance ágakon az `adc-v2-*` ugyanígy, ezek ott már
  korábban is ott voltak, így azok az ágak a felhasználó firmware-én soha nem indultak el). Javítva: `conf-try`,
  `conf-set-try`, a kijelző UART elsőként indul, `boot` trap-pel; a szimbólumlista és a szimulátor a kiadott 7.00-t
  követi; regressziós teszt (a régi script a szimulátorban 0 kijelzőválaszt ad, az új rendben). 94 teszt a main-en.
  A VESC Tool-ban az ADC Traction Control legyen kikapcsolva (a kiadott firmware-en a script nem tudja).

- 2026-11-23 (2): A felhasználó képernyőképe (AB ág, hátsó): `Cannot redefine built-in` a `(define ext-roll ...)`
  sornál ("Parsing 63999 characters" = a legutóbbi AB hátsó script). Ok: az `ext-` előtag (ld. Névszabály).
  A Balance és az AB hátsó scriptjében `ext-roll/pitch/rate/cnt/time` -> `imu-...`, `bal-ext-rate` -> `bal-imu-rate`.
  A main-en nem volt ilyen név. Az ellenőrző és a szimulátor kiegészítve; a régi scriptek a szimulátorban
  ugyanazzal a hibával állnak meg, mint a valódi firmware-en.

- 2026-11-23 (3): A kijelző működik, a külső lámpa továbbra sem; a felhasználó nyáksérülést sem zár ki.
  Kód átnézve: az útvonal helyes, az első PPM láb ugyanaz (PB6), mint a hátsón a működő féklámpáé, a
  `gpio-configure` közvetlen `palSetPadMode`. Mindkét `(lampa-teszt)` most `EREDMENY:` sort ír (az első az App
  to Use-t is), a README mérési táblázatot kapott (PPM jel láb feszültsége), tartalék láb: első `light-pin
  'pin-swdio`, vagy hátsó `headlight-on-front nil` + `headlight-pin 'pin-swdio`. 103 teszt a main-en.

- 2026-11-23 (4): A felhasználó kérésére: a külső lámpa a hátsó vezérlő SWD csatlakozójának SWCLK lábára került
  (alapérték), a hátsó `(lampa-teszt)` a helyi lábat is visszaolvassa és eredményt ír; a kipörgésgátló csak az első
  kereket korlátozza (minden ágon; az AB ágon az AB-kipörgésgátló is). Rajz, README frissítve. 108 teszt a main-en.

- 2026-11-23 (5): Felhasználói jelzés: SWCLK-ra kötve sem ég a külső lámpa (a MOSFET modult kipróbálta, jó), és a
  kijelző lámpája sem. Újra átnézve: a kiadott 7.00 `gpio-configure` közvetlen `palSetPadMode(GPIOA, 14)`, a script
  logikája rendben, a 75_100 hwconf nem használja a PA13/PA14-et. Három különböző láb (ADC2, első PPM, SWCLK) is
  hibás volt, ami közös (hardveres) okra utal: 3,3 V-tal ki nem nyitó MOSFET, rossz csatlakozóláb, GND. Ezért:
  jel mindkét SWD lábon, nyitott drain opció, `(lampa-teszt)` 6x 2 s + sípolás + mindkét láb + részletes EREDMENY,
  `(ikon-teszt)` (kijelző lámpa érték és BT ikon keresése), Bluetooth ikon = TC jelzés. A szimulátor a firmware
  lábneveit/módjait ellenőrzi, nyitott drain + felhúzó + zárlat modell, `sym2str`. 120 teszt a main-en.

- 2026-11-25: A felhasználó képernyőképe: az új hátsó script (AB) betöltése `read_error`, 1460. sor 29. oszlop: a
  `(lampa-teszt)` egyik `EREDMENY` szövege 387 bájtos volt, a 7.00-s olvasó 256-ot enged (mindhárom ágon ugyanez).
  Javítva: több rövid `print`; az ellenőrző és a szimulátor olvasója 256 bájt fölött hibát ad (a régi scriptre
  pontosan a felhasználó sor/oszlop hibáját adja). A felhasználó jelzése: „az SWCLK-ra kötve minden indulásnál
  felvillan a lámpa”, és a gyári (kijelző) lámpa sem ég. Ok a villanásra: board.h ODR=1 + lebegő SWD lábak +
  `should_reset_config()` + a régi init sorrendje (előbb kimenet, utána 0). Javítva: előbb `gpio-write`, utána
  `gpio-configure` (hátsó lámpa lábak, féklámpa, első `light-pin`); a szimulátor a board.h ODR=1-et és a hajtott
  szintek naplóját (`pin_log`) modellezi, teszt: induláskor a lámpa lába nem megy magasra. 126 teszt a main-en.

## Következő lépések
1. Lámpa (az új, betölthető scriptekkel): a hátsó `(lampa-teszt)` `EREDMENY:` sora, a gate–GND mért feszültség, és a csere-próba (a lámpa MOSFET
   jelvezetéke a PPM lábra: ha ott ég, a modul jó és a SWD bekötés a hibás). Kijelző lámpa és BT ikon:
   `(ikon-teszt)` — melyik lépésnél gyullad ki a lámpa, illetve a Bluetooth ikon (-> `dash-light-value`,
   `tc-icon-field`/`tc-icon-bit`). Kipörgésgátló hangolása (`tc-slip`, `tc-range`).
   BNO085: az első vezérlő COM1-én, I2C-n (a felhasználó átkötötte). Kell: a `(bno)` kimenete az első vezérlőn és a
   `(szog)` a hátsón (balansz ágak scriptjeivel), utána a `balance-axis`/`-invert`/`-level-offset` beállítása.
   AB: a célszög mentés (fék + 5x) és a két kipörgésgátló próbája felemelt kerékkel.
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
