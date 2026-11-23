# VESC – Xiaomi M365 PRO 2 kijelző projekt

Ez a fájl a projekt állapotjegyzete. Minden Claude Code munkamenet automatikusan beolvassa.
**Minden munkamenet végén frissíteni, commitolni és pusholni kell**, mert a felhős gép törlődik.

## Cél
Xiaomi M365 PRO 2 kijelző egy dual motoros VESC rendszeren, LispBM scripttel.

**Ez a `Balance` ág:** a `main` + a kísérleti **balansz mód** (egykerekes indulás a hátsó keréken).
A `main` ágon nincs benne. Valódi rolleren még nincs kipróbálva.

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
  **Megerősítve (2026-11-18):** a felhasználó a BNO085-öt az első vezérlő **COM1** portjára kötötte, **I2C**-n. A lapokon
  COM1 = COMM (UART3, `'pin-rx`/`'pin-tx`, a hátsón ezen a kijelző), COM2 = a második (BLE/permanent UART) port.
  A keresés felváltva próbálja a két SDA/SCL sorrendet (`bno-swap`), az I2C 100 kHz (`bno-i2c-rate`), a `(bno)`
  szöveges tippet is ad.
- **Balance ág, IMU:** `imu-source 'bno085` (alap) = az első vezérlő BNO085-je CAN-en (0x4D2, `on-imu-frame`),
  a szögsebesség a mintasorszámokból (`imu-period` 0,01 s), 0,1 s-nál régebbi adat = nincs IMU (balansz nem
  indul / `imu` okkal kilép). `'vesc` = a VESC belső IMU-ja (a régi tesztek ezzel futnak). Balansz alatt a
  kipörgésgátló nem aktív, az `apply-scale`/`apply-mode-limits` nem nyúl a balansz korlátaihoz.
- **Firmware alapvonal: a KIADOTT 7.00** (bldc 26af694 „Release 7.00”, 2026-05-15). A release_7_00 ág később kapott
  paramétereket (`adc-v2-start/end` 2026-06-09, `adc-tc` 2026-06-13), ezekre a kiadott firmware `conf-get`-je
  „Parameter not recognized” hibát dob, ami a hívó szálat leállítja. Ilyet csak `conf-try` / `conf-set-try`
  (trap + alapérték) használhat. A `tools/fw7_00_symbols.txt` a kiadott 7.00-ból van generálva, a szimulátor
  (`NEWER_PARAMS`) alapból a kiadottat utánozza, és UART-indítás nélkül nem enged UART-ot.
- **Névszabály:** `ext-` kezdetű nevet TILOS definiálni (def/defun/var/paraméter): a LispBM olvasó minden ilyen
  szimbólumot a kiterjesztés-táblába tesz (natív könyvtáraknak), és a definiálás betöltéskor „Cannot redefine
  built-in” hibával leállítja az egész scriptet. A `tools/lisp_check.py` és a szimulátor ezt (és a beépített nevek
  felüldefiniálását, a `@const-start` utáni felső szintű `def`-et) hibának jelzi.
- Indulás: `boot` = `init` (motorkimenet tiltás, féklámpa, pufferek, **kijelző UART + rx szál elsőként**) + `init-rest`
  (ADC TC, gáz-kalibráció, mód, CAN), mindkettő `trap`-ben, hiba esetén `hiba-init...` a konzolon.
  Balance ágon: a fékkar kalibrációja (`adc-v2-*`) `conf-try`-jal, a kiadott firmware-en a gázkaré (`adc-v1-*`)
  a tartalék; a balansz szál az `init-rest` végén indul.
- Gáz/fék: a kijelzőről → `app-adc-override` → ADC app (VESC Tool-ban hangolható). Control Type: Current No Reverse Brake ADC2.
- Dual: a hátsó ADC app „Multiple VESCs over CAN”, az első vezérlőn `elso_vezerlo.lisp`, saját CAN SID protokoll (0x4D0 parancs, 0x4D1 ack).
- Profilok: P1 (alap, „rendőr”) = csak hátsó motor, 3 km/h berúgás, ECO 6 km/h/100 W, S 25 km/h/500 W.
  P2 (bekapcsoláskor nyomva tartott gáz) = mindkét motor, nincs berúgás, S korlátlan, D korlátlan sebesség 60% fázisárammal, álló helyzetben akku % a kijelzőn.
- **Becsült, a felhasználó által nem megadott értékek:** P1 D = 20 km/h/300 W, P2 ECO = 25 km/h/50%, P1-ben az első motor fék nélkül, módsorrend D→S→ECO, hosszú gombnyomásnak nincs funkciója, induló mód D.

## Balansz mód (Balance ág) – döntések
- Csak 2-es profilban, `state` = 'run, álló helyzetben (< 1 km/h), szög 10–35° (roll < 30°), IMU adat van,
  gáz ÉS fék ≥ 0,9 egyszerre 1,0 s-ig, és a legutóbbi kilépés óta eltelt 2 s (cooldown).
- Bekapcsoláskor: ADC app kimenet tiltva (`app-disable-output -1`), a hátsó motort a script `set-current`-tel vezérli
  egy saját szálon 100 Hz-en (`balance-thread`). Az első motor flags = 0 (CAN üzenet), és ADC parancsot sem kap.
  Az `l-current-max-scale` 1,0, a `max-speed` = balansz-korlát + 10 km/h; kilépéskor `apply-mode-limits` visszaállítja.
- Szabályzó: PD (Ki = 0 alapból), célszög = a bekapcsoláskori szög. Kp 8 A/fok, Kd 1,0, 40 A, 400 A/s, 0,3 s felfutás.
  Hiba + = az eleje lejjebb van → pozitív áram (gyorsít). A deriváltat a szög numerikus deriváltjából számolja (LP 0,3).
- Kilépés: gáz < 0,7 (70%, a felhasználó kérése); a fék újbóli behúzása (> 0,3, a felengedése után); a fék 2 s-on belül nincs elengedve; a szög < 4°
  (leszállt); > 50°; roll > 30°; hátramenet > 3 km/h; > 35 km/h (`balance-cutoff-speed`); nincs kijelzőkeret 0,3 s; VESC hiba; nincs IMU adat;
  script hiba. 30 km/h fölött 'limit: 0,5 s-onként sípol, a célszög 15°/s-mal csökken, legfeljebb 10°-kal
  (min. 8°), NEM teszi le; 28 km/h alatt vissza 'on, a célszög visszaáll. VESC `max-speed` = 35 + 5 km/h.
- Kilépés után: ADC app vissza (a fék működik), a gáz `bal-thr-lock`-kal fogva, amíg el nem engedik (`thr-lvl` < 0,05).
- `thr-lvl`/`brk-lvl`: a nyers kijelzőértékből, a VESC Tool ADC kalibrációja szerint, a gázfogástól függetlenül.
- Balansz alatt a módváltás tiltva, a lámpa kapcsolható. A féklámpa villog, ha az áram < −5 A.
- Az első vezérlő flag-váltása után 1 s türelmi idő van a 50-es hibakód előtt (`front-flags-time`).
- REPL: `(szog)` a tengely/előjel/vízszint beállításához; `(status)` utolsó sora a balansz állapota.
- `tools/balansz_modell.py`: a modell, amiből az alapértékek jöttek. `tests/test_balance.py`: 24 teszt, benne zárt hurkú
  teszt a modellel (Kt 0,3/0,5/0,8 tartja; rossz előjellel leesik).

## Fájlok
- `lisp/hatso_vezerlo.lisp`: fő script (kijelző, gomb, lámpák, profilok, berúgás, első vezérlő vezérlése).
- `lisp/elso_vezerlo.lisp`: az első vezérlő scriptje (korlátok CAN-ről, failsafe tiltás).
- `README.md`: magyar felhasználói leírás (bekötés, VESC Tool beállítás, próba).
- `docs/referencia-elemzes.md`: a referenciaprojektek elemzése, protokoll, 7.00-s firmware tudnivalók.
- `docs/bekotes.svg`: bekötési rajz.
- `tools/lisp_check.py` + `tools/fw7_00_symbols.txt`: statikus ellenőrző (`python3 tools/lisp_check.py lisp/*.lisp`).
- `tests/lbm_sim.py` + `tests/test_scripts.py`: LispBM-részhalmaz szimulátor és tesztek (`python3 -m unittest discover -s tests`).
  `tests/test_lamp_tc.py` (lámpa, kipörgésgátló, két vezérlő CAN-en összekötve), `tests/test_bno085.py` (BNO085).
  `tests/test_balance_bno.py` (Balance ág: BNO085 szög CAN-en, TC balansz közben).

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

- 2026-11-09: **Balance ág** létrehozva: balansz mód (egykerekes indulás), részletek fent. 67 teszt átmegy.
  Módosítva (felhasználói kérés): gázkitartás 70%, 30 km/h-nál sípolás + lejjebb engedés (nem nullára), kilépés 35-nél.
  69 teszt átmegy. A felhasználónak irányteszt kell felemelt hátsó kerékkel (README „Első próbák”), utána óvatos hangolás.
- 2026-11-14: Felhasználói jelzés: a lámpa MOSFET a hátsó **ADC2**-n nem kapcsol, a PPM (féklámpa) működik.
  A hiba hardveres (az ADC bemenet védő/szűrő köre). A lámpa átkerült az **első vezérlő PPM lábára** (CAN flags bit2)
  a `main`-en, és átvezetve ide is (balansz alatt is kapcsolható, a front-flags 0 mellett is megy a bit2).

- 2026-11-18: `main` beolvasztva (lámpa 0x64, visszajelzés v2, 60-as hiba, kipörgésgátló 3 kattintással, BNO085
  meghajtó az első scriptben). Itt: BNO085 a balansz szöge (`imu-source`), balansz alatt nincs TC és nincs
  mód-korlát írás. Az első script `bno-first` javítása (azonnali első keresés) a main-re is átkerül. 123 teszt átmegy.

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

- 2026-11-23 (3): A kijelző működik, a külső lámpa továbbra sem (nyáksérülés sem kizárt). Kód átnézve, helyes;
  az első PPM láb (PB6) ugyanaz, mint a hátsón a működő féklámpáé. Mindkét `(lampa-teszt)` `EREDMENY:` sort ír,
  README mérési táblázat, tartalék láb: első `light-pin 'pin-swdio` vagy hátsó `headlight-pin` (main-ből átvéve).

- 2026-11-23 (4): A main-ből: a külső lámpa a hátsó vezérlő SWD csatlakozójának SWCLK lábán (alapérték,
  `headlight-pin 'pin-swclk`), a kipörgésgátló csak az első kereket korlátozza (nincs `tc-rear`; balansz alatt
  továbbra sem aktív, a balansz korlátait nem írja).

## Következő lépések
1. Lámpa: visszajelzés kell az új scriptekkel (mindkét vezérlőre fel kell tölteni!), ha nem megy:
   `(lampa-teszt)` kimenete a hátsón és az elsőn. Kipörgésgátló hangolása (`tc-slip`, `tc-range`).
   BNO085: az első vezérlő COM1-én, I2C-n (a felhasználó átkötötte). Kell: a `(bno)` kimenete az első vezérlőn és a
   `(szog)` a hátsón, utána a `balance-axis`/`-invert`/`-level-offset` beállítása.
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
