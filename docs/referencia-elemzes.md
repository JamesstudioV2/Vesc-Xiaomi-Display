# Referenciaprojektek elemzése

Állapot: 2026-11-09. Mindegyik projekt LispBM scripttel köti a Xiaomi vagy
Ninebot BLE kijelzőt egy VESC-hez. A közös ős az
[m365fw/vesc_m365_dash](https://github.com/m365fw/vesc_m365_dash) (Netzpfuscher,
1zuna).

## A három megadott repó

### A-Emile/vesc_m365_dash (2023, VESC 6.0)
- Az eredeti, egyszerű változat: `m365_dash.lisp`, `g30_dash.lisp`, valamint
  `m365_dash_awd.lisp` két motorhoz.
- **Gáz és fék:** a scriptben kalibrált értékből közvetlenül `set-current-rel` és
  `set-brake-rel`. A VESC ADC appját nem használja, ezért a VESC Tool-ban nem
  lehet hangolni.
- **Gomb:** a kijelző zöld vezetéke a VESC **RX** lábán, 1 kΩ-os felhúzóval
  3,3 V-ra. A kijelző adatvonala half-duplex módban a TX-en.
- **Módok:** dupla nyomással D/ECO/S, ezek `conf-set 'max-speed`, `'l-watt-max`,
  `'l-current-max-scale` értékek. Titkos mód gáz+fék+dupla nyomással.
- **AWD:** a második vezérlőnek `canset-current-rel`, a korlátokat `can-cmd`
  szöveges paranccsal küldi át (másodpercenként legfeljebb 2 parancs).
- **Gyenge pontok:** a keretolvasás 3 bájtos blokkokban szinkronizál és egy
  bájttal többet olvas, ezért elcsúszhat. A CRC-ből kimarad a payload utolsó
  bájtja. Minden érvényes keretre válaszol.

### PierreDisplayDash/vesc_displaydash (2024, VESC 6.02 / 6.05)
- Az A-Emile fork továbbfejlesztése. A 6.05-ös változat már **„Software ADC”**:
  `app-adc-detach` + `app-adc-override`, tehát a gáz és a fék az ADC appon megy
  át, és a VESC Tool-ban kalibrálható.
- A `lib_code_server` csomaggal (`rcode-run`) állítja a CAN-es vezérlők
  korlátait.
- Plusz egy „DisplayDash” keret (`0x55AA 0x0EDD`) egy külön kijelzőalkalmazáshoz.

### 1zun4/vesc_scooter_support (v2.1, 2026-08, **VESC 7.00**)
- VESC Tool csomag (`.vescpkg`) QML felülettel. A beállításokat EEPROM-ban
  tárolja, és egy kód kezeli a G30, az M365/1S/PRO2 és a Slave modellt.
- Software ADC (raw/77.2 → 0–3,3 V az ADC appba), indulási sebesség
  `app-disable-output`-tal, zár mód riasztóval (giroszkóp + `foc-play-tone`),
  idle kijelzés (akku/hőfok/feszültség/trip), mph.
- Dual: a slave-en a `code-server` fut, a master `rcode-run`-nal küldi a
  `conf-set` parancsokat.
- `@const-start` / `image-save`: a kód flash-ből fut, gyorsan bootol.
- A README alapján az ADC app beállításai: App = ADC, Use Filter, Safe Start,
  ADC Mapping a kijelzőn keresztül.
- A TODO-listáján ott a „Rear light and brake light output”. Ezt a mi
  scriptünk megcsinálja.

## Hasonló projektek

### lucidnx/Scooter_Dashboard_Support (2026-10, VESC 7.00)
Az 1zun4 csomag legkiforrottabb továbbfejlesztése. Több fontos protokollrészlet
innen származik:
- **Bájtonként csúszó fejléc-szinkron** a 3 bájtos blokkok helyett. A Xiaomi
  keretben a CRC a `len` bájttól a payload végéig mindent összead.
- **A gáz és a fék a 0x64 és 0x65 keretben is benne van** (4. és 5. bájt), app
  olvasásnál (0x61) eggyel arrébb.
- **A gyári vezérlő csak a 0x64-re válaszol.** A válaszok közt legalább 50 ms
  telik el.
- Az éledő kijelző mindkét karra **0x0a**-t küld, ezt nem szabad valós értéknek
  venni.
- **Watchdog:** az override-ot csak friss keretre írja, így ha a kijelző
  elhallgat, a VESC saját timeout-ja állítja le a motort.
- Hátsó/féklámpa a servo lábon PWM-mel (halvány hátsó lámpa, fékezéskor teljes
  vagy villogó fény), fényszóró-feszültségesés-kompenzáció és app-támogatás
  (NineDash, m365 Tools).

### DDev247/vesc-m365 (2025)
- Az m365fw fork kísérleti BMS-kommunikációval és QML műszerfallal. Lámpákra a
  SWD lábakat (`pin-swdio`, `pin-swclk`) használja kimenetként.

### Egyebek (Ninebot G30)
tonymillion/VescNinebotDash, CRZX1337/g30-vesc-dash,
aka13-404/VESC_Ninebot_G30_lisp: ugyanez Ninebot protokollal (`5A A5` fejléc).

## A Xiaomi kijelzőprotokoll (115200 baud, half-duplex, egy vezeték)

```
55 AA | len | addr | cmd | arg | payload (len-2 bájt) | crc_lo crc_hi
crc = (len + addr + cmd + arg + payload bájtok összege) XOR 0xFFFF
```

| Irány | addr | cmd | Tartalom |
|---|---|---|---|
| kijelző → ESC | 0x20 | 0x65 / 0x64 | payload[1] = gáz, payload[2] = fék (nyers 0–255) |
| kijelző → ESC | 0x20 | 0x61 | app olvasás, gáz/fék eggyel arrébb |
| ESC → kijelző | 0x21 | 0x64 | 6 bájt: mód, akku %, lámpa, sípolás, sebesség, hibakód |

Az ESC → kijelző mód bájt bitjei: 1 = D, 2 = ECO, 4 = S, 8 = töltés,
16 = kikapcsolva, 32 = zár, 64 = mph, 128 = hőfok ikon.

## Amiben a mi rendszerünk eltér

| Téma | Referenciák | Ez a projekt |
|---|---|---|
| Gomb | RX láb (1 kΩ felhúzó), `gpio-read`, 3 mintás többségi döntés | ugyanígy az RX lábon, **470 Ω** felhúzóval. 3 mintás lenyomás, 2 mintás felengedés, egy pergés nem bont ketté egy nyomást. A gomb lába paraméter (`button-pin`) |
| Féklámpa | nincs (lucidnx: PWM) | **PPM láb GPIO**: állandóan ég, fékezéskor 5 Hz-en villog |
| Első lámpa | csak ikon | **ADC2 láb GPIO** + ikon |
| Profilváltás | gomb-kombináció menet közben | **bekapcsoláskor nyomva tartott gáz** → 2-es profil, utána a gáz elengedéséig nincs kimenet |
| Berúgás | `app-disable-output` (a fék is kiesik) | a gázt az ADC app start-feszültségére fogja, **a fék végig működik**, és az ADC rámpa is érvényes marad |
| Dual motor | `rcode-run` (code server csomag) vagy `can-cmd` | saját 8 bájtos CAN SID üzenet 10 Hz-en + visszaigazolás. Az első vezérlő **alapból tiltva van**, és 1 s csend után újra tiltja magát |
| Álló kijelzés | beállítható idle mód | 2-es profilban akku %, 1-es profilban sebesség |

## Firmware 7.00 tudnivalók (a forráskódból ellenőrizve)

- `uart-read-bytes` a firmware-ben Lispben van megírva: 4 ms-onként újrapróbál,
  és az olvasott bájtok után **egy 0-t is ír a pufferbe**, ezért a puffer legyen
  legalább 1 bájttal hosszabb.
- `uart-start ... 'half-duplex` csak a TX lábat állítja UART-ra, az RX-hez nem
  nyúl, így az RX szabadon használható gombnak. Ha az App `UART`, `PPM and UART`
  vagy `ADC and UART`, a `uart-start` véglegesen `No App`-ra állítja át (eltárolja!).
- Az appokat (és ezzel az ADC/PPM lábak módját) a firmware csak akkor indítja
  újra, ha az *App to Use* vagy a *Servo Output* beállítás megváltozik:
  `app_adc_start` analógra állítja az ADC lábakat, `pwm_servo_stop` bemenetre a
  PPM lábat.
- `app-adc-detach 3 1`: mindkét ADC és a gombok leválasztva. 6.05 óta a
  leválasztott ADC app nem nullázza magától a timeout-ot, ezért az override-ot
  folyamatosan küldeni kell. Ez egyben biztonsági funkció.
- Az ADC app tartomány-ellenőrzése (`adc-v1-min`/`max`) az override értékre is
  vonatkozik. Ha a gáz feszültsége tartományon kívül van, nincs kimenet.
- `get-adc-decoded` az ADC app kalibrációja szerint 0–1, akkor is, ha a kimenet
  le van tiltva.
- `conf-set 'max-speed` → `l_max_erpm`. A korlát fölött a motoráram-limit 0 lesz,
  a motor kifut, nem fékez (kivéve, ha az *Overspeed* hiba be van kapcsolva).
- A `conf-set` menet közben is azonnal érvényes. Az egyszerű korlátoknál
  (sebesség, watt, áram-szorzó) nem konfigurálja újra a motorvezérlést.
- `mc_interface_set_current_rel` a `lo_current_max` értékkel skáláz
  (= `l-current-max` × `l-current-max-scale`), ezért az első motor
  `l-current-max-scale 0`-val CAN-ről sem hajt.
