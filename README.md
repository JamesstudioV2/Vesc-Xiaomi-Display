# Vesc-Xiaomi-Display

Xiaomi M365 **PRO 2** kijelző VESC vezérlőhöz (firmware **7.00**), két motorral
(első és hátsó vezérlő CAN-buszon). A kijelző a hátsó vezérlő COMM portjára
csatlakozik. A kijelzőt, a gázt, a féket, a lámpákat és a profilokat egy LispBM
script kezeli.

| Fájl | Hova kerül |
|---|---|
| [`lisp/hatso_vezerlo.lisp`](lisp/hatso_vezerlo.lisp) | hátsó (fő) vezérlő, erre van kötve a kijelző |
| [`lisp/elso_vezerlo.lisp`](lisp/elso_vezerlo.lisp) | első vezérlő (CAN slave) |
| [`docs/referencia-elemzes.md`](docs/referencia-elemzes.md) | a hasonló projektek elemzése, protokoll-leírás |
| [`tests/`](tests/) | szimulátoros tesztek (a script logikája PC-n futtatva) |
| [`tools/lisp_check.py`](tools/lisp_check.py) | statikus ellenőrző a 7.00-s firmware függvénylistája alapján |
| [`tools/balansz_modell.py`](tools/balansz_modell.py) | durva fizikai modell az Advanced Balance szögkorlátjának becsléséhez |

> **Ez az `Advanced-Balance` ág.** A `main` ághoz képest az **Advanced Balance**
> ([leírás lent](#advanced-balance-kísérleti)) van benne: egy szögkorlát, ami
> egykerekezésnél nem engedi átfordulni a rollert. **Kísérleti**, valódi rolleren
> még nincs kipróbálva.

> ⚠️ **Saját felelősségre.** Egy hibás beállítás vagy bekötés váratlan gyorsulást
> vagy fékvesztést okozhat. Az első próbákat mindig **felemelt kerékkel** végezd.
> A 2-es profil (korlátlan sebesség) közúton a legtöbb helyen nem használható
> legálisan.

## Funkciók

| | 1-es profil („rendőr mód”) | 2-es profil |
|---|---|---|
| Aktiválás | alapértelmezett | bekapcsoláskor **nyomva tartott gázkar** (2 sípolás) |
| Motorok | csak a hátsó | mindkettő |
| Indulás | **3 km/h-s berúgás** kell | bármikor |
| ECO | 6 km/h, 100 W | 25 km/h, 50% fázisáram ¹ |
| D | 20 km/h, 300 W ¹ | korlátlan sebesség, **60% fázisáram** |
| S | 25 km/h, 500 W | korlátlan |
| Kijelző álló helyzetben | sebesség (0) | **akku %** |

¹ Ezt az értéket nem adtad meg, ezért becsült értéket írtam be. A
`hatso_vezerlo.lisp` elején egy sorban átírható (`p1-drive`, `p2-eco`).

A „korlátlan” 1000 km/h-s és 1 500 000 W-os korlátot jelent. Ilyenkor a VESC
Tool-ban beállított motoráram- és akkuáram-limitek maradnak érvényben.

**Kijelző gomb (a kijelzőben, zöld vezeték → RX):**
- 1x nyomás: első lámpa ki/be (az első vezérlő PPM kimenete + lámpa ikon).
- 2x gyors nyomás: módváltás **D → S → ECO → D**, 1 sípolással.
- Hosszú (1,5 s-nál hosszabb) nyomás: nincs funkciója.

**Féklámpa (PPM kimenet):** folyamatosan világít. Fékezéskor azonnal kialszik,
majd 5 Hz-cel villog, amíg a fékkar be van húzva.

**Kijelzőn:** sebesség (km/h), akku töltöttség, mód (ECO/D/S), hőfok ikon
(vezérlő ≥ 80 °C vagy motor ≥ 100 °C, mindkét vezérlőt figyeli), lámpa ikon és
hibakód.

**Gáz és fék:** a kijelző nyers gáz- és fékértékét a script az **ADC app**
bemenetére küldi (`app-adc-override`). Így a tartomány, a holtjáték, a
gázgörbe, a rámpák és a vezérlési mód a VESC Tool-ban hangolható (App Settings →
ADC), a script módosítása nélkül.

**Biztonság:**
- A profil eldöntéséig (kb. 2 s a kijelző indulása után) nincs motorkimenet.
- A 2-es profilban addig nincs kimenet, amíg el nem engeded a gázt.
- Ha a kijelző elhallgat (kábelhiba), a VESC saját timeout-ja leállítja a motort,
  mert a script csak friss kijelzőkeretre küld gázértéket.
- Ha az első vezérlő 1 másodpercig nem kap üzenetet a hátsótól, letiltja a saját
  motorját.

## Bekötés

![Bekötési rajz](docs/bekotes.svg)

**Hátsó vezérlő, COMM port:**

| Kijelző vezeték | VESC láb | Megjegyzés |
|---|---|---|
| piros | 5V | a kijelző tápja |
| fekete | GND | |
| sárga (adat) | **TX** | half-duplex, csak a TX lábat használja |
| zöld (gomb) | **RX** | **470 Ω** felhúzó ellenállás az RX és a **3.3V** közé. A gomb a kijelzőben van, lenyomva a kijelző GND-re húzza ezt a vezetéket. Opcionálisan 1 µF kondenzátor az RX és a GND közé. |

**ADC1:** szabad. Ajánlott egy 10 kΩ-os ellenállással GND-re kötni, hogy
induláskor, a script elindulása előtt az ADC app ne lebegő bemenetet olvasson
(ld. [Safe Start](#hátsó-vezérlő-app-settings)).

**Kimenetek** (3,3 V-os logikai jel, N-csatornás MOSFET-tel):

| Vezérlő, láb | Fogyasztó |
|---|---|
| hátsó, PPM jel (servo) | féklámpa MOSFET gate |
| **első**, PPM jel (servo) | első lámpa MOSFET gate (a hátsó CAN-en kapcsolja) |

**Miért nem az ADC2-n van a lámpa?** A firmware engedi az ADC lábat
kimenetnek állítani (`gpio-configure`), és a script ezt csinálta is. Sok VESC
lapon viszont az ADC bemenetek elé védő- és szűrőkör kerül (soros ellenállás,
osztó vagy lehúzó ellenállás, kondenzátor), hogy 5 V-os gázkart is el lehessen
viselni. Ezen keresztül a láb nem tud elég feszültséget vagy áramot adni egy
MOSFET gate-jének. A PPM láb közvetlenebbül megy a processzorra, a hátsón ez
működik is, ezért a lámpa az első vezérlő ugyanilyen PPM lábára került. Ha
mégis a hátsó ADC2-t szeretnéd: `(def headlight-on-front nil)`, és mérd meg a
lábon a ~3,3 V-ot bekapcsolt lámpánál.

**Miért ilyen kicsi (470 Ω) a felhúzó?** A kijelző a zöld vezetéket
nyugalmi állapotban is terheli. Az eredeti projektek 1 kΩ-ot használnak, és a
„véletlenszerű” gombolvasást 470 Ω-mal szüntették meg. Lenyomáskor 470 Ω-on
~7 mA folyik, ez a 3.3V lábnak nem gond. Az 1 µF-os kondenzátor a
fantomnyomásokat szűri.

Tanácsok a kimenetekhez:
- **Logikai szintű** N-FET kell (pl. AO3400, IRLZ44N, IRLML6344), amelyik 3,3 V
  gate-feszültségnél teljesen kinyit. „Sima” IRFZ44N-nel melegedni fog.
- Tegyél 10–100 kΩ-os **gate–GND lehúzó ellenállást**, hogy a lámpa ne
  villanjon fel, amíg a VESC bootol.
- Ha induktív a terhelés (relé), szabadonfutó diódát is tegyél mellé.
- Ha a lámpa a kijelzővel közös 5 V-ról kap tápot, a feszültségesés elhúzhatja
  a gáz- és fékértéket. Ilyenkor külön tápról járasd a lámpát.

**Első vezérlő:** csak CAN (CAN-H, CAN-L, GND) a hátsóval, és motor/akku.

## VESC Tool beállítások

Mindkét vezérlőn **7.00**-s firmware fusson, eltérő CAN ID-vel, azonos CAN
sebességgel.

### Mindkét vezérlőn (Motor Settings)
1. Motor setup wizard (FOC). A kerékátmérő és a póluspár legyen pontos, mert ebből
   számolódik a sebesség és a km/h-korlát.
2. **General → Battery:** a cellaszám és az akkutípus legyen helyes, mert ebből
   számolja a VESC a töltöttséget (%).
3. **General → Advanced → Additional faults:** az *Overspeed* hiba legyen
   **kikapcsolva**. A módváltás menet közben is lejjebb teheti a sebességkorlátot,
   és bekapcsolt overspeed hibánál a VESC ilyenkor leállna. Kikapcsolt hibánál a
   korlát fölött a motor csak kifut, nem fékez.
4. Motor hőmérséklet-szenzor, ha van.
5. **Berúgás-érzékelés:** a 3 km/h-s berúgást a script a hátsó motor
   sebességéből látja, amikor a motor még nem kap áramot. **Hall-szenzoros**
   motornál ez biztosan működik. Szenzor nélküli módban csak olyan
   vezérlőn, amelyik méri a fázisfeszültséget (phase filter). Ha a `(status)` szerint
   kézzel pörgetett keréknél 0 km/h látszik, használd a Hall-szenzorokat.

### Hátsó vezérlő (App Settings)
1. **General → App to Use:** `ADC`. Az UART appot a script úgyis leállítja.
2. **ADC → General:**
   - Control Type: **`Current No Reverse Brake ADC2`** (az app 1-es csatornája
     a gáz, a 2-es a fék, mindkettőt a script tölti a kijelzőről, nem a lábakról)
   - Use Filter: `True`
   - Safe Start: `Regular` (**fontos**, ld. lent)
   - Multiple VESCs Over CAN: **`True`** (ezzel kapja az első motor a gázt és a féket)
   - Traction Control: `False`
3. **ADC → Mapping:** kalibráld a gázt és a féket a kijelzőn keresztül
   (ld. a következő pontot).
4. Itt hangolható minden más is: Throttle Curve, Ramp Time Pos/Neg, holtjáték
   (Hysteresis).

**Gáz- és fékkalibráció:** az **1-es profilban** álló helyzetben a script a
berúgás miatt visszafogja a gázt, ezért a VESC Tool ott nem látja a teljes
kitérést. A kalibrációhoz kapcsold be a rollert **a gázkart nyomva tartva**
(2-es profil, 2 sípolás), engedd el a gázt, és utána futtasd az ADC Mapping-et.
Felemelt kerékkel csináld!

**Miért kell a Safe Start:** amíg a script el nem indul, az ADC app a fizikai
ADC1 és ADC2 lábat olvassa. Az ADC1 most szabad, és ha lebeg, akármit mutathat.
A Safe Start csak akkor enged kimenetet, ha a gáz előtte egy ideig nulla volt.
Az ADC1 10 kΩ-os GND-re kötése ezt a kockázatot is megszünteti.

**Az App to Use csak `ADC` lehet.** Ha `ADC and UART` (vagy bármelyik UART-os
app) van beállítva, a script UART-indítása a firmware-ben véglegesen
`No App`-ra állítja át, és akkor a gáz egyáltalán nem működik.

### Első vezérlő
- **App to Use:** `No App`. A parancsokat a hátsó ADC app küldi CAN-en.
- **Servo Output:** kikapcsolva, mert a PPM lábat a lámpa kapcsolja.
- A CAN státuszüzenetek maradjanak bekapcsolva (alapértelmezés), mert ebből látja
  a hátsó vezérlő az első hőmérsékletét és azt, hogy jelen van.

## Feltöltés

1. Hátsó vezérlő: VESC Tool → **VESC Dev Tools → Lisp**, nyisd meg vagy másold be a
   `lisp/hatso_vezerlo.lisp` tartalmát, majd **Upload**. A script ezután minden
   bekapcsoláskor magától indul.
2. Első vezérlő: VESC Tool-ban a CAN-eszközök közül válaszd az első vezérlőt
   (a hátsón keresztül, CAN forward), és ugyanígy töltsd fel az
   `lisp/elso_vezerlo.lisp`-t.
3. Ha a hátsó script `front-cmd-sid` / `front-ack-sid` értékét módosítod, az
   elsőben is ugyanazt állítsd be (`cmd-sid` / `ack-sid`).

Ha nincs első vezérlő, a hátsó script elején legyen `(def front-enabled nil)`.

## Hibakeresés

A Lisp konzolban (REPL) a `(status)` parancs kiírja a profilt, az állapotot, a
módot, a sebességet, a nyers és a kalibrált gáz-/fékértéket, a gomb lábának
állapotát (1 = felengedve, 0 = lenyomva), az észlelt lenyomások számát és az
első vezérlő válaszát.

Ha a VESC Tool-ban az App típusát vagy a Servo Output beállítást megváltoztatod,
a firmware újraindítja az appokat, és közben a lámpák és a gomb lábait is
átállítja. A script ezeket fél másodpercen belül visszaállítja.

### A gomb nem működik

1. Csatlakozz a hátsó vezérlőhöz, és nyisd meg a **VESC Dev Tools → Lisp**
   konzolt. Bekapcsoláskor kiírja: `Profil: 1, gomb lab: 1 (1 = felengedve)`.
2. Írd be: `(gomb-teszt)`, és 5 másodpercig nyomogasd a gombot. A script
   0,2 s-onként kiírja a gomb lábának állapotát (`lab = 1`, lenyomva
   `lab = 0  LENYOMVA`), a végén pedig az észlelt lenyomások számát.
3. Minden lenyomásnál és felengedésnél megjelenik egy `gomb le` / `gomb fel`
   sor, utána a művelet: `1x -> lampa BE`, `2x -> mod S`.

| Amit látsz | Ok, teendő |
|---|---|
| mindig `lab = 0` | a zöld vezeték folyamatosan GND-n van, vagy nincs felhúzás: ellenőrizd a 470 Ω-ot és a 3.3V-ot, és hogy tényleg az RX lábon van-e |
| mindig `lab = 1`, nyomásra sem változik | a gomb nem ezt a vezetéket húzza le, vagy a zöld vezeték nem az RX-en van: mérd meg multiméterrel nyomás közben |
| van `gomb le`/`fel`, de nincs művelet | túl hosszú (1,5 s fölötti) a nyomás, vagy 0,4 s-nál lassabb a dupla nyomás |
| `1x -> lampa BE` megjelenik, a kijelzőn a lámpa ikon is, de a lámpa nem ég | fut-e az első vezérlőn az új `elso_vezerlo.lisp`, és bekapcsolt lámpánál ~3,3 V van-e az első vezérlő PPM lábán |
| egyáltalán nincs kiírás, `(status)` sem megy | nem fut a script: töltsd fel újra, és nézd meg a hibaüzenetet |

Ha a konzolon `hiba-control-step` jelenik meg, másold ki és küldd el: a script
hiba esetén is fut tovább, de a hibát jelezni kell.

A kijelzőn megjelenő hibakódok jelentése a [Hibakódok](#hibakódok) fejezetben van.

## Hibakódok

A kijelző a hibakódot ugyanúgy mutatja, mint a gyári vezérlőnél. Ahol van
gyári Xiaomi megfelelő, a script azt a kódot küldi (pl. 14 = gázkar,
15 = fékkar). A VESC saját hibáit is ilyen kódokra fordítja, a gyári listában
nem szereplő hibák 50 fölötti saját kódot kapnak.

- Egy hiba **legalább 3 másodpercig** látszik (`error-hold-time`), akkor is, ha
  közben megszűnt. Így a pillanatnyi hibák is leolvashatók.
- Ha egyszerre több hiba van, a legfontosabb látszik: VESC hiba → kar hiba →
  első vezérlő → események.
- Minden új hiba megjelenik a **Lisp konzolon** is (`HIBA 14: gazkar jele
  hibas ...`, VESC hibánál a VESC kód számával).
- A konzolban a **`(hibak)`** parancs kiírja az aktív hibát, a karok nyers
  jelét és az utolsó 8 hibát (mikor volt).

| Kód | Jelentés | Forrás | Mit nézz meg |
|---|---|---|---|
| 10 | A kijelző nem kap választ a vezérlőtől | a kijelző saját kódja | UART bekötés (sárga → TX), fut-e a script, App to Use = ADC |
| 11 / 12 / 13 | 1. / 2. / 3. áramérzékelő offset hiba | VESC 15 / 16 / 17 | a vezérlő áramérzékelője; motor nélkül is jön? |
| **14** | **Gázkar jele hibás** (szakadás vagy zárlat) | script | gázkar csatlakozója és kábele a kijelzőben, `(hibak)` nyers értéke |
| **15** | **Fékkar jele hibás** (szakadás vagy zárlat) | script | fékkar csatlakozója és kábele a kijelzőben |
| **16** | **Gáz- és fékkar egyszerre hibás** | script | a karok közös tápja / GND-je a kijelzőben, a kijelző kábele |
| 18 | Motor enkóder / pozíciószenzor hiba | VESC 11–13, 20–22, 25, 26, 28, 30 | szenzor kábel, Sensor Mode beállítás |
| 24 | Akkufeszültség túl magas vagy túl alacsony | VESC 1, 2 | akku töltöttség, a feszültséghatárok a VESC Tool-ban |
| 26 | Flash / konfiguráció sérült | VESC 14, 23, 24 | írd újra a konfigurációt, firmware újratöltés |
| 28 | Kapuvezérlő (DRV) / MOSFET hiba | VESC 3, 7, 8, 19 | a vezérlő hardvere, motor fáziskábelek zárlata |
| 31 | A vezérlő újraindult (watchdog) | VESC 10 | firmware/script lefagyás, tápellátás |
| 40 | Vezérlő (FET) túlmelegedés | VESC 5 | hűtés, áramkorlátok |
| 50 | Az első vezérlő nem válaszol | script | CAN kábel, fut-e rajta az `elso_vezerlo.lisp` |
| 51 | Túláram | VESC 4 | motor detektálás, áramkorlátok, fázisok |
| 52 | Motor túlmelegedés | VESC 6 | motor hőmérséklet-szenzor, áramkorlátok |
| 53 | Túlpörgés hiba | VESC 31, 32, 33 | General → Advanced → Additional faults (legyen kikapcsolva) |
| 54 | Kiegyensúlyozatlan fázisáram / fázisszűrő hiba | VESC 18, 27 | motor fáziskábelek, csatlakozók |
| 55 | 5V / 3.3V kimenet hiba | VESC 29 | zárlat a COMM csatlakozón (kijelző, lámpa MOSFET bekötése) |
| 56 | MCU tápfeszültség alacsony | VESC 9 | a vezérlő tápellátása |
| 57 | Az első vezérlő hibát jelez | az első vezérlő | csatlakozz az első vezérlőhöz a VESC Tool-ban (CAN), nézd meg a hibáját |
| 58 | Az Advanced Balance lekapcsolt | script | borulás (60°) vagy nincs IMU adat, ld. `(status)` utolsó kilépés |
| 59 | Script hiba | script | a Lisp konzol `hiba-...` sora |
| 69 | Egyéb VESC hiba | VESC (más) | a konzol kiírja a VESC hibakód számát |

**Kar hibák (14 / 15 / 16):** a kijelző a karok jelét 0–255 közötti értékként
küldi. Ép karnál ez kb. 40 (elengedve) és 200 (tövig) között van. Ha a jel
0,3 másodpercig a `lever-raw-min` (16) alatt vagy a `lever-raw-max` (235)
fölött van, az szakadás vagy zárlat. Ilyenkor, mint a gyári vezérlőnél:
- nincs gáz (hibás féknél sem, mert akkor nem lehetne elektromosan fékezni);
- hibás fékkarnál az elektromos fék sincs, csak a mechanikus;
- a hiba megszűnése után a jelnek 1 másodpercig jónak kell lennie, a gáz pedig
  csak az elengedése után működik újra;
- hibás gázkarral a 2-es profil nem kapcsolható be, és az Advanced Balance
  sem hibás fékkarral.

Az 57-es kódhoz az első vezérlőre is az új `elso_vezerlo.lisp` kell, mert az
küldi el a saját hibakódját a visszajelzésben. A régi verzióval is működik
minden, csak az 57-es kód nem jelenik meg.

## Első próba (felemelt kerékkel)

1. Bekapcsolás után 1 sípolás. A kijelzőn az akku % és a D mód látszik, a
   féklámpa világít.
2. Gáz álló helyzetben: a motor **nem** indul (1-es profil). Kézzel pörgesd fel a
   hátsó kereket 3 km/h fölé, ekkor a gáz működik.
3. Fékkar: a féklámpa villog, a motor fékez.
4. Gomb 1x: az első lámpa és a lámpa ikon bekapcsol. Gomb 2x: a mód S lesz,
   1 sípolással.
5. Kikapcsolás, majd bekapcsolás nyomva tartott gázzal: 2 sípolás. Amíg nyomod a
   gázt, semmi nem történik. Elengedés után a gáz álló helyzetből is működik, és
   mindkét motor hajt. Álló helyzetben a kijelző az akku %-ot mutatja.
6. A `(status)` paranccsal ellenőrizd, hogy az első vezérlő válaszol-e
   (`elso-hiba` = nil).

## Advanced Balance (kísérleti)

> ⚠️ **Kísérleti funkció, valódi rolleren még nincs kipróbálva.** Egy hibás
> beállítás (rossz tengely vagy előjel, rossz célszög, túl nagy erősítés)
> váratlan fékezést, gázelvételt vagy hátraborulást okozhat. Csak
> védőfelszerelésben, üres, sík területen próbáld, a lenti lépések sorrendjében.

**Mit csinál:** két keréken a roller teljesen normál. Ha felemeled az elejét, a
gázkar továbbra is a motor nyomatékát adja, de a rendszer **elveszi a gázt,
vagy fékez is**, hogy az eleje ne emelkedjen a beállított **célszög** fölé.
Teljes gázzal így a roller a célszög körül tartja az elejét, mint egy
balanszer. Kevesebb gázzal az eleje lejjebb ereszkedik: a gáz a te kezedben
marad, a rendszer csak felülről korlátoz. Sebességkorlátja nincs.

**Be- és kikapcsolás:** csak a **2-es profilban**, a **fékkar behúzása közben 2x
gombnyomással**. Bekapcsoláskor 2 sípolás szól, és a kijelzőn a **lakat
ikon** világít. Kikapcsoláskor 1 sípolás szól. Minden bekapcsoláskor
(indulásnál) ki van kapcsolva. Fék nélkül a 2x gombnyomás továbbra is
módváltás.

**Ilyenkor:**
- **A fék teljesen normál:** ugyanaz a kalibráció és rámpa, mint az ADC appban,
  mindkét motoron.
- **A gáz** a VESC Tool kalibrációja, holtjátéka és rámpái szerint jut a
  motorokhoz. A VESC Tool gázgörbéje helyett az `ab-throttle-exp` /
  `ab-curve-mode` paraméter él, alapból lineáris.
- **A hátsó motor árama** = a kisebbik a gáz és a szögkorlát közül. A korlát a
  célszög alatt nagy, a célszög felé 0-ra csökken, fölötte negatív (fékez). A
  gyors emelkedést a szögsebesség alapján előre fékezi. Az ab-engage-angle (3°)
  alatt, két keréken nem szól bele.
- **Az első motor** ugyanazt a gázt kapja, mint normál menetben. Egy laza
  **kipörgésgátló** a két kerék sebességét figyeli: ha az egyik
  `ab-tc-slip`-nél (3 km/h) gyorsabban forog, a hajtása fokozatosan csökken,
  `ab-tc-range`-nyi (5 km/h) további különbségnél 0. Felemelt elejénél így az
  első kerék nagyjából együtt forog a hátsóval, nem pörög fel.
- **Hátramenet:** a szögkorlát legfeljebb 3 km/h-ig tolathat hátra
  (`ab-max-reverse`), hogy állva is meg tudja fogni az átfordulást.

**Lekapcsolás:** **60° oldalra dőlésnél** vagy **60° hátradőlésnél** (és 60°
előredőlésnél is) mindkét motor elenged, az Advanced Balance kikapcsol (3
sípolás), a gáz pedig a felengedéséig hatástalan. Akkor is kikapcsol, ha
eltűnik az IMU adat. Ha a kijelző elhallgat, a motorok nem kapnak gázt, de a
mód bekapcsolva marad.

### A célszög beállítása

A célszöget a script elején írd be: `(def ab-target-angle 20.0)` (fok).
- **Ne legyen nagyobb a balanszpontnál**, vagyis annál a szögnél, ahol a súlypontod
  pont a hátsó kerék fölött van. A balanszpont mögött a roller csak folyamatos
  fékezéssel tartható, és ez a motorból hamar elfogy (a modellben átfordul).
  Kezdd kicsivel (10–15°), és lépésenként növeld.
- **Legyen jóval nagyobb a legmeredekebb emelkedőnél, amin jársz.** A szöget az IMU
  a gravitációhoz méri, ezért egy 10°-os emelkedőn a roller két keréken is
  10°-ot mutat. Ha a célszög ennek közelében van, emelkedőn elveszi a gázt.
- Erős gyorsításnál az IMU szögmérése elcsúszhat (ld. lent: AHRS beállítás).

### Előfeltétel: IMU a hátsó vezérlőben

A hátsó VESC-nek kell, hogy legyen IMU-ja (gyorsulásmérő + giroszkóp), beépítve
vagy külső modulként. A VESC Tool-ban: **App Settings → IMU**:
- **IMU Type:** a vezérlőn lévő IMU (ha `Off`, az Advanced Balance nem kapcsol be).
- **AHRS Mode:** `Madgwick Fusion`. Az **Accel Confidence Decay**-jel csökkenthető,
  hogy gyorsításkor elcsússzon a szög.
- Futtasd a giroszkóp kalibrációt (a roller álljon mozdulatlanul).
- A vezérlő legyen mereven rögzítve, a rezgés zavarja a szögmérést.

### Szögkalibráció

A Lisp konzolban: `(szog)`. Öt másodpercig kiírja a nyers roll/pitch értékeket
és a számolt szöget.
1. Nézd meg, melyik tengely változik, amikor megemeled az elejét. Ha a `roll`,
   állítsd a script elején `(def balance-axis 0)`-ra (alapból `1` = pitch).
2. Ha az eleje emelésekor a szög **csökken**, állítsd: `(def balance-invert t)`.
3. Vízszintes rollernél a nyers szöget írd be: `(def balance-level-offset ...)`.
   Utána vízszintesen ~0°-ot, felemelt elejével pozitív szöget kell mutatnia.

### Lakat ikon

Bekapcsolt Advanced Balance-nál a kijelzőn a **lakat ikon** világít: a script
a mód bájt 32-es bitjét (LOCK) kapcsolja be a sebességmód mellé, a sebesség
és az akku ugyanúgy látszik. A gyári vezérlő a zárolt állapotot ezzel a bittel
jelzi.
- Ha a kijelződön a lakat mellett más is történik (pl. eltűnik a sebesség),
  vagy más ikont szeretnél, írd be a konzolba: `(ikon-teszt)`. 2
  másodpercenként egy-egy bitet kapcsol be (elsőként a lakatot), a konzol
  kiírja, melyik fut éppen. A választott bitet így állítsd be:
  `(def ab-icon-field ...)` (0 = mód, 2 = lámpa, 3 = sípolás mező) és
  `(def ab-icon-bit ...)`.
- Ha nem kell jelzés: `(def ab-icon-mode nil)`.

Ez a teszt arra is jó, hogy kiderüljön, a lámpa ikon nálad melyik bitre
gyullad: a lucidnx mérései szerint a gyári vezérlő a lámpa mezőbe 0x64-et küld
(6-os bit), a script pedig most 1-et.

### Első próbák (ebben a sorrendben)

1. **Szögellenőrzés:** `(szog)` – emeléskor nőjön, vízszintesen ~0.
2. **Irányteszt felemelt hátsó kerékkel:** támaszd alá a rollert úgy, hogy a
   hátsó kerék szabadon forogjon. Kapcsold be az Advanced Balance-t, és adj
   egy kis gázt.
   - **Vízszintes vázzal** a kerék a gáz szerint forog.
   - Ha a vázat a **célszög fölé** döntöd, a gáz ellenére **fékezzen** (lassuljon,
     álljon meg).
   - Ha **fordítva** viselkedik, ne menj tovább: javítsd a `balance-invert`-et.
   - Közben nézd a `(status)` `korlat` értékét: a célszög alatt pozitív, fölötte
     negatív.
3. **Óvatos próba a földön:** alacsony célszöggel (10°), védőfelszerelésben,
   segítővel. Lassan emeld az elejét, és figyeld, hogy a célszögnél a
   rendszer elveszi-e a gázt.
4. **Hangolás:**
   - ha a célszögön túllendül: `ab-kd` növelése (1,5 → 2,0), vagy `ab-kp`
     növelése;
   - ha a célszög környékén rángat vagy billeg: `ab-kp` csökkentése (10 → 8);
   - ha két keréken, gyorsításnál vagy emelkedőn is beleszól: nagyobb
     célszög, nagyobb `ab-engage-angle`, vagy az AHRS beállítás javítása.

Az alapértékek (Kp 10 A/fok, Kd 1,5 A·s/fok, 1000 A/s) a modell szerint 0,3 és
1,2 Nm/A közötti motornál megfogják a teljes gázos emelést, és menet közben a
80°/s-os felrántást is (`python3 tools/balansz_modell.py`). Egy ennél
erősebb rántást vagy egy balanszpont mögötti célszöget a hátsó motor nyomatéka
már nem tud megfogni.

## Beállítható paraméterek

Mindegyik a `lisp/hatso_vezerlo.lisp` elején van, magyarázattal:

- `p1-eco`, `p1-drive`, `p1-sport`, `p2-eco`, `p2-drive`, `p2-sport`: a módok
  korlátai `(km/h watt fázisáram-szorzó)` formában.
- `boot-mode`: induló mód (1 = D, 2 = ECO, 4 = S).
- `light-default`: az első lámpa induláskor be legyen-e kapcsolva.
- `kick-speed`, `kick-release-speed`: a berúgás sebessége (3 km/h), és hogy ez
  alá lassulva mikor kell újra berúgni (1 km/h).
- `p2-detect-throttle`, `p2-detect-hold`, `p2-detect-window`: a 2-es profil
  aktiválásához szükséges gázmérték, tartási idő és időablak.
- `p2-idle-speed`: e sebesség alatt mutatja a kijelző az akku %-ot a 2-es profilban.
- `button-pin`: a gomb lába (alapból `'pin-rx`). Digitálisan olvassa, lenyomva 0,
  pergésmentesítéssel (lenyomás 3, felengedés 2 minta, 20 ms-onként).
- `double-click-time`, `long-press-time`: a dupla és a hosszú nyomás időzítése.
- `button-log`: a gombesemények kiírása a Lisp konzolra (hibakereséshez).
- `brake-level`, `brake-blink-half`: a féklámpa érzékenysége és villogási
  sebessége.
- `temp-warn-fet`, `temp-warn-motor`: a hőfok ikon határai.
- `front-enabled`, `p1-front-brake`: az első vezérlő használata, és hogy az
  1-es profilban fékezzen-e az első motor (alapból nem, csak a hátsó dolgozik).
- `lever-raw-min`, `lever-raw-max`, `lever-fault-time`, `lever-ok-time`,
  `error-hold-time`: a kar hibák (14/15/16) határai és a hibakód kijelzési
  ideje ([Hibakódok](#hibakódok)).
- `ab-...` és `balance-axis`/`-invert`/`-level-offset`: az Advanced Balance
  beállításai (célszög, erősítések, áramváltozás, hátramenet, lekapcsolási
  szögek, be/ki fékküszöb, gázgörbe, kipörgésgátló, lakat ikon), mind
  magyarázattal a script elején.

## Bluetooth (VESC Tool)

A kijelző Bluetooth-a **nem használható** a VESC Tool-hoz:
- A VESC Tool csak a Nordic UART szolgáltatást (NUS) hirdető eszközöket
  listázza (Windows alatt mindet), és azon keresztül a VESC saját csomagjait
  küldi. Ehhez VESC-firmware-es Bluetooth-modul kell: NRF modul vagy VESC Express.
- A kijelző Bluetooth-a a Xiaomi zárt firmware-ét futtatja. Csak
  Xiaomi-formátumú kereteket ad tovább a busz felé, és azokat is átalakítja (az
  app olvasási kérésébe beleteszi a gáz- és fékértéket). A VESC-csomagokat
  nem engedi át. A firmware-t nem lehet úgy lecserélni, hogy a kijelző közben
  működjön.
- Elvben egy saját, PC-n futó „híd” program a VESC-üzeneteket
  Xiaomi-keretekbe csomagolva átjuttathatná. Ez viszont nagyon lassú lenne,
  mert a kijelző a saját ütemében, másodpercenként néhányszor közvetít, és csak
  PC-ről működne, a VESC Tool mobilappal nem. PC-n pedig az USB-kábel egyszerűbb.

**Ajánlott megoldás: VESC Express a CAN-buszon.** A VESC Tool telefonról és
PC-ről is Bluetooth-on kapcsolódik hozzá, és a CAN-en keresztül mindkét
vezérlőt eléri (beállítás, firmware, Lisp, naplózás). A kijelző UART-ját nem
érinti, és a scripteken sem kell változtatni.
- **Kész modul:** hivatalos VESC Express vagy egy vele kompatibilis modul.
- **Házilag:** egy ESP32-S3 fejlesztőpanel és egy 3,3 V-os CAN transceiver
  (pl. SN65HVD230). A [VESC Express](https://github.com/vedderb/vesc_express)
  firmware `S3 N16R8` (ESP32-S3-DevKitC-1 N16R8) és `S3 FH4R2` célhardvere a
  CAN-t a **GPIO16 (TX)** és **GPIO17 (RX)** lábon használja. A firmware az
  ESP32 USB-portján tölthető fel. A tápot a VESC 5V-járól kaphatja. A CAN ID
  legyen egyedi, a CAN sebesség pedig ugyanaz, mint a két vezérlőé.

## Fejlesztés, tesztek

```bash
python3 tools/lisp_check.py lisp/*.lisp
```

```bash
python3 -m unittest discover -s tests -v
```

- `tools/lisp_check.py`: zárójelezés, ismeretlen függvény- és változónevek,
  hibás `conf-set`/`gpio` paraméternevek a 7.00-s firmware forrásából generált
  listához (`tools/fw7_00_symbols.txt`) mérve.
- `tests/`: egy kis LispBM-értelmező szimulált VESC-cel. A valódi Lisp fájlokat
  futtatja, és ellenőrzi a kijelzőprotokollt (CRC, válaszok, visszhang), a
  profilválasztást, a berúgást, a gombot, a féklámpát, a kijelző mezőit és a
  két vezérlő közötti CAN-üzeneteket. Ez nem a valódi LispBM, a hardveres próbát
  nem váltja ki.

A projekt állapota és a döntések: [CLAUDE.md](CLAUDE.md).
