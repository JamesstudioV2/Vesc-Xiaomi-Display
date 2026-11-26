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
- Bluetooth: a **gyári** kijelző BLE-je nem használható VESC Tool-hoz (VESC Express a CAN-en, README).
  **Az egyedi kijelző-firmware-rel igen** (2026-11-25, [M365_Display_Costum_BLE](https://github.com/JamesstudioV2/M365_Display_Costum_BLE)):
  a kijelző a NUS-on kapott VESC bájtfolyamot TUNNEL_UP bővítő keretben küldi, a hátsó script `cmds-proc`-kal
  adja a VESC parancsfeldolgozójának, a válasz (`event-cmds-data-tx`, a `can-event-loop` kapja) egy gyűrűbe
  (`tun-buf`, 1536 B) megy, és TUNNEL_DOWN keretekben (≤ 100 B, ≤ a kijelző kreditje) jut vissza.
  A 7.00 `cmds-proc` szinkron dolgozik fel, a parancs külön szálon fut, futás közben az újat eldobja.
  Lisp feltöltés ezen az úton nem megy (a script viszi a kapcsolatot).
- Egyedi kijelző (csak a main alapú ágon, 2026-11-25): felismerés HELLO (0x64 válasz után, 1/s) →
  HELLO_ACK; bővítő keretek `cmd 0x7A`, kijelzőkeretenként legfeljebb egy (`dx-reply`): név, LED felülírás
  (TC jelzés `tc-seg-byte`/`tc-seg-bit`, alap BT ikon, beavatkozáskor villog; `(led-teszt)`), életjel/STYLE
  (`speed-color`) 1/s, egyszeri parancs (`dash-text`), alagút. A kijelző 0x7A keretei gáz/fék keretek is
  (`lever-input 4`). 5 s csend → `dash-custom` nil. A gyári BLE129 a bővítő kereteket figyelmen kívül hagyja
  (a kijelző repójában emulátorral ellenőrizve). `ext-` névszabály miatt a segédfüggvények `dx-` előtagúak.
- Féklámpa: **PPM** láb → N-FET. Alapból folyamatosan ég, fékezéskor villog.
- Első (külső) lámpa: **a hátsó vezérlő SWD csatlakozójának SWCLK lábán** → N-FET (2026-11-23, a felhasználó kérése:
  `headlight-on-front nil`, `headlight-pin 'pin-swclk`; az SWCLK-t a processzor induláskor lehúzza, így bootoláskor
  nem villan fel). 2026-11-23 (5): ugyanaz a jel az **SWDIO**-n is (`headlight-pin2 'pin-swdio`, nil = ki), mert a
  felhasználónál az SWCLK-ra kötve sem ment; `headlight-mode` `'pin-mode-out` (alap) vagy `'pin-mode-od` (1 kΩ 5V-ra,
  5 V-os gate; PA13/PA14 5 V-tűrő). Előtte: hátsó ADC2 (nem működött, az ADC bemenet védőköre), majd az első vezérlő PPM lába (nem
  működött). **Megerősítve (2026-11-25): a hátsó SWD csatlakozón működik**, gázadásra sem villog. A felhasználó
  kérésére az **első vezérlőből minden lámpás rész törölve** (`light-pin`, `front-light`, `lamp-test`, az első
  `(lampa-teszt)`, `conf-try`), a hátsóból a `headlight-on-front` opció és a `front-lamp`/`front-pin` is. Az első
  script egy lábhoz sem nyúl. Minden ágon.
- Kijelző lámpája: a lámpa mezőbe **100 (0x64)** megy (`dash-light-value`). **A gyári BLE129 visszafejtése
  (2026-11-25): bármely nem nulla érték** bekapcsolja a kijelző lámpakimenetét (P0.03), az ikont, és 7-ről 2-re
  veszi a fényerőt; a „6-os bit” (lucidnx) a BLE129-re nem igaz. Az 1-es érték csak az ikont gyújtotta ki (ez volt a „csak az ikon jelenik meg” hiba).
  A 0x64 a gyári vezérlő értéke (camcamfresh, Arduino-fórum: „0x64 = on”); a Koxx3 SmartESC m365 0/1-et küld.
  A kijelző lámpája a kijelző tápjáról (VESC 5V) ég (gyári M365-ön ~4,1 V jön fel). A felhasználónál 100-zal
  sem ég (2026-11-23): `(ikon-teszt)` 7. (64) / 9. (100) lépés, ha egyiknél sem: táp / lámpa bekötés.
- Kipörgésgátló jelzése: a felhasználó a **Bluetooth ikont** kérte (2026-11-23), de az **nem vezérelhető**: az
  `(ikon-teszt)` egyik lépése sem gyújtotta ki (a felhasználó, 2026-11-25; a gyári kijelzőn a saját BLE modulja
  kapcsolja). A lámpa mező bármely nem nulla értéke a **lámpa ikont** gyújtja ki (a 2-es bit alapérték elvette a
  lámpa ikont: „egyszeri nyomásra nem működik a lámpa ikon”). Ezért `tc-icon-field -1` (nincs jelzés) az alap,
  konfigurálható (`tc-icon-field`/`tc-icon-bit`); a felhasználó választhat ikont. `(ikon-teszt)`: 14 lépés, 3 s,
  a lépés száma a sebesség helyén: lámpa mező 1,2,4,…,128,100,255 (csere), mód mező +8,+32,+64,+128 (hozzáadva);
  teszt közben a TC (és az AB lakat) jelzés szünetel.
- CAN visszajelzés (0x4D1) **2-es verzió**, 8 bájt: A5, flags, áram %, VESC hibakód, állapot (bit1 BNO friss; a
  bit0/bit2 a korábbi első lámpáé, 2026-11-25 óta mindig 0), script-verzió (2), első sebesség (i16, 0,1 km/h). A
  parancs (0x4D0) flags 2-es bitje sem használt. A formátum nem változott, ezért a verzió 2 maradt. A hátsó
  `front-min-version` 2-t vár, régi első scriptnél a kijelzőn **60**-as hiba. Konzol: `(lampa-teszt)`,
  `(ikon-teszt)`, `(tc-teszt)` a hátsón, `(bno)` az elsőn.
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
  (trap + alapérték) használhat. A 7.00 az **elkapott hibát is kiírja** („Error (trapped): eval_error ... bound to:
  adc-tc ... Parameter not recognized”, `eval_cps.c` `error_ctx_base`, a felhasználó képernyőképe 2026-11-26), ezért a
  `conf-try` / `conf-set-try` a hívás idejére `(hide-trapped-error)` ... `(show-trapped-error)`-t használ, és a nem
  ismert nevet a `conf-missing` listában megjegyzi (a Balance/AB `refresh-gate` 0,5 s-onként kérdezné az
  `adc-v2-*`-t). A szimulátor `trapped_log`-ja azt gyűjti, ami a konzolra kerülne; teszt: kiadott 7.00-n üres. A `tools/fw7_00_symbols.txt` a kiadott 7.00-ból van generálva, a szimulátor
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
- **Könyvtári kód előtöltése (flash-kép):** a 7.00 a `looprange`, `loopwhile`, `loopforeach`, `str-merge`, `abs`
  (és a többi `lbm_dyn_lib.c` nevet) az első használatkor szövegből tölti be, és az új paraméterneveket
  (`it`, `start`, `cnd`, ...) a flash-képbe írja (`store_symbol_name_flash`). A képbe mentett írási mutatót csak az
  `image-save`, a REPL-parancs indulása és a main vége menti; a futás közbeni írás után egy újraindítás elavult
  mutatót hagy, és a következő új név írása **„Attempted to write to const heap at N, but it is already
  occupied”** + `read_error` (`Current: ~CHANNEL~`, a sor/oszlop a könyvtári szövegben) hibával leállítja a szálat
  (a felhasználó első vezérlője, `(lampa-teszt)`, `looprange` → `it`, Line 1 Column 29, 2026-11-25). Ezért mindkét
  script az `(image-save)` előtt egyszer meghívja őket. Az ellenőrző és a szimulátor (`DYN_LIB`, `image_saved`)
  hibát ad, ha egy ilyen név először az image-save után futna. Helyreállítás a VESC-en: a script újrafeltöltése
  (a `COMM_LISP_ERASE_CODE` a képet is törli). Elgépelt REPL-név + azonnali kikapcsolás ugyanezt okozhatja.
- **SWD lábak induláskor (firmware):** `hwconf/board.h` minden láb ODR-jét 1-re állítja, a PA13/PA14 lebeg (nincs
  pull); a `main.c` `should_reset_config()` a PA14-et (SWCLK) rövid ideig kimenetként hajtja, és ha a HALL2 követi,
  **törli a beállításokat** (HALL2–SWCLK jumper). Ezért a script előbb `gpio-write`, utána `gpio-configure`
  (különben egy pillanatra magas), és a gate-re 10 kΩ lehúzó kell. A felhasználó „induláskor felvillan” jelzése
  ebből jön; ez nem bizonyítja, hogy a MOSFET 3,3 V-tal nyit (a lebegő gate magasabbra is töltődhet).
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
  A szimulátor `uart-write`-ja a bővítő kereteket (cmd 0x7A) a `v.ext_tx`-be, a többit a `v.tx`-be teszi
  (`v.tx_all`: mind); `bufcpy`, `free`, `mod`, `cmds-start-stop`, `cmds-proc` (`v.cmds_in`); a string bájttömb
  lezáró 0-val. `tests/test_custom_dash.py`: az egyedi kijelző támogatása (25 teszt).
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

- 2026-11-23 (5): Felhasználói jelzés: SWCLK-ra kötve sem ég a külső lámpa (a MOSFET modult kipróbálta, jó), és a
  kijelző lámpája sem. Újra átnézve: a kiadott 7.00 `gpio-configure` közvetlen `palSetPadMode(GPIOA, 14)`, a script
  logikája rendben, a 75_100 hwconf nem használja a PA13/PA14-et. Három különböző láb (ADC2, első PPM, SWCLK) is
  hibás volt, ami közös (hardveres) okra utal: 3,3 V-tal ki nem nyitó MOSFET, rossz csatlakozóláb, GND. Ezért:
  jel mindkét SWD lábon, nyitott drain opció, `(lampa-teszt)` 6x 2 s + sípolás + mindkét láb + részletes EREDMENY,
  `(ikon-teszt)` (kijelző lámpa érték és BT ikon keresése), Bluetooth ikon = TC jelzés. A szimulátor a firmware
  lábneveit/módjait ellenőrzi, nyitott drain + felhúzó + zárlat modell, `sym2str`. 120 teszt a main-en, 158 a
  Balance ágon (balansz közben a TC nem avatkozik be, a Bluetooth ikon a kapcsoló állását mutatja).

- 2026-11-25: A felhasználó képernyőképe: az új hátsó script (AB) betöltése `read_error`, 1460. sor 29. oszlop: a
  `(lampa-teszt)` egyik `EREDMENY` szövege 387 bájtos volt, a 7.00-s olvasó 256-ot enged (mindhárom ágon ugyanez).
  Javítva: több rövid `print`; az ellenőrző és a szimulátor olvasója 256 bájt fölött hibát ad (a régi scriptre
  pontosan a felhasználó sor/oszlop hibáját adja). A felhasználó jelzése: „az SWCLK-ra kötve minden indulásnál
  felvillan a lámpa”, és a gyári (kijelző) lámpa sem ég. Ok a villanásra: board.h ODR=1 + lebegő SWD lábak +
  `should_reset_config()` + a régi init sorrendje (előbb kimenet, utána 0). Javítva: előbb `gpio-write`, utána
  `gpio-configure` (hátsó lámpa lábak, féklámpa, első `light-pin`); a szimulátor a board.h ODR=1-et és a hajtott
  szintek naplóját (`pin_log`) modellezi, teszt: induláskor a lámpa lába nem megy magasra. 126 teszt a main-en,
  164 a Balance ágon.

- 2026-11-25 (2): A felhasználó: az első vezérlő `(lampa-teszt)`-je „Attempted to write to const heap at 4580, but it
  is already occupied”, read_error, CTX 1552, `~CHANNEL~`, Line 1 Column 29 hibával áll le (az első sor kiírása után).
  Ok: a `looprange` futás közbeni betöltése (ld. „Könyvtári kód előtöltése”). Javítva mindkét scriptben, minden
  ágon; ellenőrző + szimulátor szabály, tesztek. „Egyszeri nyomásra nem működik a lámpa ikon, mert a
  kipörgésgátlóra vált” = a TC jelzés (lámpa mező 2-es bit) elvette a lámpa ikont; „az ikontesztel nem indult be a
  bluetooth ikon” → a TC jelzés alapból ki. Nyitott: „gázadásra a lámpa villog” (melyik lámpa? féklámpa = hamis
  fékjel? külső lámpa = gombzaj vagy táp?), a kijelző lámpája az ikon-tesztben, melyik ikon jelezze a TC-t.
  Tesztek: 129 a main-en, 167 a Balance ágon.

- 2026-11-25 (3): A felhasználó: a lámpát a hátsó vezérlő SWD csatlakozójára téve **gond nélkül működik**, és
  gázadásra sem villog (az előző „gázadásra villog” jelzés egy korábbi bekötéssel volt). Kérés: az első
  vezérlőről a lámpás részek törlése, README ennek megfelelően. Kész (ld. fent); a tesztek közül az első
  vezérlős lámpa tesztjei törölve, helyettük: az első egy lábhoz sem nyúl, a hátsó nem küld lámpa bitet.
  119 teszt a main-en, 157 a Balance ágon. A rajzon „Külső lámpa” (nem „Első lámpa”).

- 2026-11-26: A felhasználó képernyőképe (AB hátsó, 1555 soros script, a CAN eszközlista: mindkét vezérlő
  **75 100 V2**): „Error (trapped): eval_error, CTX 408 main-u, bound to: adc-tc, In: conf-get, Between row 1554
  and 1555, Parameter not recognized”. Ártalmatlan (elkapott hiba, a script fut tovább), de a felhasználó hibának
  látta, és a Balance/AB ágon a fékkar-kalibráció (`adc-v2-*`) miatt 0,5 s-onként ismétlődött volna. Javítva:
  `conf-try` / `conf-set-try` csendes + nem ismert név megjegyzése (minden ágon). README: mit jelent az üzenet.
  Tesztek: 122 a main-en, 160 a Balance ágon.

- 2026-11-25 (4): A felhasználó kérésére egyedi kijelző-firmware készült a
  [M365_Display_Costum_BLE](https://github.com/JamesstudioV2/M365_Display_Costum_BLE) repóba (nRF51822 + S130,
  gyári BLE129 visszafejtve, emulátorban tesztelve, valódi hardveren még nem). A hátsó script (ezen az ágon)
  felismeri és használja: TC jelzés a BT ikonon (villog beavatkozáskor), `speed-color`, `ble-name`, VESC Tool a
  kijelző Bluetooth-án (`cmds-proc` alagút), `(led-teszt)`, `(szin-teszt)`, `(dash-text ...)`. A kijelző repójában
  3 végponttól végpontig teszt köti össze a lefordított firmware-t ezzel a scripttel. 144 teszt itt.
  A Balance / Advanced-Balance ágakra még nincs átvezetve.

- 2026-11-26: A felhasználó: a felírt egyedi kijelző-firmware (1.0) nem kommunikál a Lisp kóddal.
  **A hiba a kijelző firmware-ében volt, nem itt:** a gyári kijelző-firmware minden keret előtt a busz
  vezetékére (P0.15) teszi az UART TX-et, az 1.0 végig a P0.20-on adott, így a VESC semmit nem kapott.
  A kijelző repójában javítva (**1.1**, `(status)`: `kijelzo egyedi fw 11`); az ottani emulátor busza
  azóta lábhelyes. Itt nem kellett változtatni (a protokoll ugyanaz).

## Következő lépések
0. Egyedi kijelző-firmware **1.1** felírása ST-Linkkel (a kijelző repó README), `(status)` → `keretek` nő,
   `kijelzo egyedi fw 11`,
   `(led-teszt)`, `(szin-teszt)`, VESC Tool Bluetooth-on. Utána a Balance/AB ágak támogatása.
1. Kijelző lámpája: az `(ikon-teszt)` melyik lépésénél gyullad ki (ha egyiknél sem: táp / bekötés; a gyári
   BLE129 bármely nem nulla értékre kapcsolja), és melyik ikon jelezze a kipörgésgátlót (gyári kijelzőn a
   Bluetooth nem vezérelhető, egyedi firmware-rel igen). Kipörgésgátló hangolása (`tc-slip`, `tc-range`).
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
