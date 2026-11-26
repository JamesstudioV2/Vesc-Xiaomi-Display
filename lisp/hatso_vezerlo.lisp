; =============================================================================
; Xiaomi M365 PRO 2 kijelző -> VESC 7.00  |  HÁTSÓ (fő) vezérlő
; Repo: https://github.com/JamesstudioV2/vesc-xiaomi-display
;
; Mit csinál:
;  - Half-duplex UART-on beszélget a PRO 2 kijelzővel (COMM port, TX láb).
;  - A kijelzőre kötött gázkar/fékkar értékét az ADC app-ba küldi
;    (app-adc-override), így a görbék, tartományok, rámpák a VESC Tool-ban
;    (App Settings -> ADC) hangolhatók.
;  - Kijelző gomb a kijelző zöld vezetékén, a COMM port RX lábán (felhúzó
;    ellenállás 3.3V-ra, lenyomva a kijelző GND-re húzza):
;      1x nyomás = lámpa: a kijelző saját lámpája + a hátsó vezérlő SWD
;                  csatlakozóján lévő külső lámpa (MOSFET; az SWCLK és az
;                  SWDIO láb is a lámpa jelét adja)
;      2x nyomás = módváltás  D -> S -> ECO -> D
;      3x nyomás = kipörgésgátló be/ki (csak 2-es profilban), 3 sípolás;
;                  (jelzés a kijelzőn: tc-icon-field, alapból nincs)
;  - PPM láb: féklámpa MOSFET. Alapból folyamatosan világít, fékezéskor villog.
;  - Kijelzőn: sebesség, akku töltöttség, mód (ECO/D/S), hőfok ikon, hibakód.
;  - 1-es profil (alapértelmezett, "rendőr mód"): csak a hátsó motor megy,
;    3 km/h-s berúgás kell az induláshoz.
;  - 2-es profil: bekapcsoláskor nyomva tartott gázkarral. Mindkét motor megy,
;    nincs berúgás, álló helyzetben a kijelző az akku %-ot mutatja.
;    Kipörgésgátló: ha az első kerék a megengedettnél gyorsabban forog, mint a
;    hátsó, az első hajtását csökkenti; a hátsóba nem avatkozik bele
;    (induláskor bekapcsolva).
;  - Balansz mód (csak 2-es profilban, KÍSÉRLETI): álló rollernél, felemelt
;    elejével gáz + fék tövig 1 másodpercig -> a hátsó motor az IMU alapján
;    tartja a szöget (egykerekezés), az első motor áll. Kilépés: gáz elengedése
;    vagy a fék újbóli behúzása, utána 2 s-ig nem indítható újra.
;    A szöget alapból az első vezérlőre kötött BNO085 IMU adja (CAN-en),
;    imu-source = 'vesc esetén a VESC belső IMU-ja.
;  - Egyedi kijelző-firmware-rel (M365_Display_Costum_BLE): a kipörgésgátló a
;    Bluetooth ikonon, a futó balansz mód a lakat ikonon jelez, fehér/piros
;    számjegyek, Bluetooth név, és VESC Tool a kijelző Bluetooth-án keresztül
;    (cmds-proc alagút). Gyári kijelzővel is megy.
;  - Lisp konzol: (status), (gomb-teszt), (lampa-teszt), (ikon-teszt), (tc-teszt), (szog),
;    egyedi kijelzővel: (led-teszt), (szin-teszt)
;
; Bekötés (COMM port):
;   kijelző piros  -> 5V        kijelző fekete -> GND
;   kijelző sárga  -> TX (half-duplex adatvonal)
;   kijelző zöld (gomb) -> RX + 470 Ohm felhúzó ellenállás 3.3V-ra
;   PPM jel -> féklámpa MOSFET gate
;   ADC1, ADC2 -> szabad (10 kOhm-mal GND-re ajánlott)
;   Külső lámpa: a hátsó vezérlő SWD csatlakozójának SWCLK (vagy SWDIO) lábán
;   (MOSFET gate, headlight-pin / headlight-pin2). Az első vezérlőn nincs lámpa.
;
; Az első (slave) vezérlőre az elso_vezerlo.lisp kerül.
; Részletes leírás és VESC Tool beállítások: README.md
; =============================================================================

; -> Felhasználói beállítások ---------------------------------------------------

; Módok: (max km/h  max watt  fázisáram-szorzó 0.0-1.0)
; 1000 km/h és 1500000 W gyakorlatilag "korlátlan" - ilyenkor a VESC Tool-ban
; beállított áram- és akkuáram-limitek maradnak érvényben.
(def p1-eco   '(6.0    100.0     1.0)) ; rendőr mód ECO
(def p1-drive '(20.0   300.0     1.0)) ; rendőr mód D  (nem volt megadva, módosítható)
(def p1-sport '(25.0   500.0     1.0)) ; rendőr mód S
(def p2-eco   '(25.0   1500000.0 0.5)) ; 2-es profil ECO (nem volt megadva, módosítható)
(def p2-drive '(1000.0 1500000.0 0.6)) ; 2-es profil D: korlátlan sebesség, 60% fázisáram
(def p2-sport '(1000.0 1500000.0 1.0)) ; 2-es profil S: korlátlan

(def boot-mode 1)             ; induló mód: 1 = D, 2 = ECO, 4 = S
(def light-default nil)       ; a lámpa induláskor: t = be, nil = ki
(def headlight-pin 'pin-swclk) ; a hátsó vezérlő lámpa lába: az SWD csatlakozó SWCLK lába
                              ; (közvetlen MCU láb, 3,3 V; induláskor a processzor lehúzza, így
                              ; bootoláskor a lámpa nem villan fel). Az ADC lábak a védőkörük
                              ; miatt nem jók. Az SWD programozó ezután újraindításig nem megy.
(def headlight-pin2 'pin-swdio) ; ugyanaz a jel az SWD csatlakozó másik jellábán is, így a
                              ; MOSFET bármelyikre köthető (a feliratok lapnként eltérnek).
                              ; nil = csak a headlight-pin. (Az SWDIO-t induláskor a processzor
                              ; felhúzza: ott a lámpa a script indulásáig halványan éghet.)
(def headlight-mode 'pin-mode-out) ; 'pin-mode-out = 3,3 V-os kimenet (logikai szintű MOSFET kell).
                              ; 'pin-mode-od = nyitott drain: egy 1 kOhm-os ellenállás a láb és
                              ; az 5 V közé, így a gate 5 V-ot kap (ha a MOSFET 3,3 V-tal nem
                              ; nyit ki). Az SWD lábak 5 V-tűrők. Ilyenkor bootoláskor a lámpa
                              ; a script indulásáig világít.
(def dash-light-value 100)    ; a kijelzőnek küldött lámpa érték bekapcsolt lámpánál.
                              ; 100 (0x64) = mint a gyári vezérlő: a 6-os bit kapcsolja a
                              ; kijelző saját lámpáját. 1 = csak az ikon világít.
                              ; Ha a kijelző lámpája nem gyullad ki: (ikon-teszt), README.

; Kipörgésgátló (csak 2-es profilban). Csak az első kereket korlátozza a
; hátsóhoz képest: ha az első tc-slip-nél többel gyorsabban forog, mint a hátsó,
; az első hajtását tc-range alatt lineárisan 0-ig csökkenti. A hátsó kerékbe
; nem avatkozik bele. 3 gyors gombnyomás: be/ki.
(def tc-default t)            ; induláskor bekapcsolva
(def tc-slip 2.0)             ; km/h - az első legfeljebb ennyivel lehet gyorsabb (eddig nem szól bele)
(def tc-range 3.0)            ; km/h - e fölött ennyi további különbségnél a hajtás 0
(def tc-recover 0.3)          ; s - a csúszás után ennyi idő alatt jön vissza a teljes hajtás
; Jelzés a kijelzőn: amíg a kipörgésgátló be van kapcsolva (2-es profilban), ez a
; bit is megy a kijelzőnek. A Bluetooth ikont a kijelző nem engedi (a saját BLE
; modulja kapcsolja; az (ikon-teszt) egyik lépésnél sem gyújtotta ki, 2026-11-25),
; a lámpa mező bármely bitje pedig a lámpa ikont gyújtja ki. Ezért alapból nincs
; jelzés (a 3x gombos kapcsoláskor 3 sípolás van). Ha egy ikon jelezze: az
; (ikon-teszt) lépései közül válassz, pl. mód mező (0) + 128 = hőmérő ikon.
(def tc-icon-field -1)        ; 0 = mód, 2 = lámpa mező; -1 = nincs jelzés
(def tc-icon-bit 0)           ; ezt a bitet kapcsolja be a mezőben

; Egyedi kijelző-firmware (github.com/JamesstudioV2/M365_Display_Costum_BLE). A
; script felismeri (HELLO -> HELLO_ACK keret), és ha ott van, bővítő parancsokkal
; használja: minden LED külön kapcsolható, fehér/piros számjegyek, Bluetooth név,
; VESC Tool a kijelző Bluetooth-án át. Gyári kijelzővel ezek nem mennek, de nem is
; zavarnak (a HELLO keretet a gyári kijelző figyelmen kívül hagyja).
(def dash-ext t)              ; t = az egyedi kijelző-firmware keresése és használata
(def ble-vesc-tool t)         ; t = VESC Tool a kijelző Bluetooth-án keresztül (cmds-proc)
(def ble-name nil)            ; Bluetooth név, pl. "Roller-VESC" (nil = a kijelző alapneve)
(def speed-color 0)           ; a sebesség számjegyei: 0 = fehér, 1 = piros, 2 = mindkettő
(def tc-seg-byte 5)           ; egyedi kijelzőn a kipörgésgátló jelzése egy LED: bájt (0-5)
(def tc-seg-bit 64)           ;   és bit érték (5. bájt 64 = Bluetooth ikon); -1 = nincs.
                              ;   Bekapcsolt kipörgésgátlónál (2-es profil) folyamatosan ég.
(def tc-seg-blink nil)        ;   t = beavatkozás közben villog (nil = mindig folyamatos)

; Berúgás (csak 1-es profil)
(def kick-speed 3.0)          ; km/h - eddig kell berúgni, hogy a gáz működjön
(def kick-release-speed 1.0)  ; km/h - ez alatt újra berúgás kell

; 2-es profil aktiválása: bekapcsoláskor nyomva tartott gáz
(def p2-detect-throttle 0.7)  ; ennyi gáz kell (0-1, a VESC Tool ADC kalibráció szerint)
(def p2-detect-hold 0.5)      ; s - ennyi ideig folyamatosan
(def p2-detect-window 2.0)    ; s - az első kijelzőkerettől számítva eddig lehet
(def throttle-released 0.05)  ; 2-es profilban ez alá kell engedni a gázt az induláshoz
(def p2-idle-speed 1.0)       ; km/h - 2-es profilban ez alatt akku %-ot mutat

; Kijelző gomb: a zöld vezeték a COMM port RX lábán, felhúzóval 3.3V-ra.
; Lenyomva a kijelző GND-re húzza (0), elengedve 1.
(def button-pin 'pin-rx)       ; a gomb lába
(def double-click-time 0.4)    ; s - ennyi idő alatt jöhet a második nyomás
(def long-press-time 1.5)      ; s - ennél hosszabb nyomás nem számít kattintásnak
(def button-log t)             ; t = gombesemények kiírása a VESC Tool Lisp konzolra

; Féklámpa (PPM)
(def brake-level 0.05)         ; fékkar (0-1) e fölött = fékezés
(def brake-blink-half 0.1)     ; s - villogás fél periódus (0.1 s = 5 Hz)

; Hőfok ikon
(def temp-warn-fet 80.0)       ; °C vezérlő
(def temp-warn-motor 100.0)    ; °C motor

; Dual motor (első vezérlő CAN-en, elso_vezerlo.lisp)
(def front-enabled t)          ; nil, ha nincs első vezérlő
(def p1-front-brake nil)       ; 1-es profilban fékezzen-e az első motor (t / nil)
(def front-cmd-sid 0x4D0)      ; CAN SID: hátsó -> első parancs
(def front-ack-sid 0x4D1)      ; CAN SID: első -> hátsó visszajelzés
(def front-error-code 50)      ; ezt mutatja a kijelző, ha az első vezérlő nem válaszol
(def front-min-version 2)      ; az első script legalább ilyen verziójú legyen
(def front-old-error-code 60)  ; ezt mutatja a kijelző, ha az első script régi (nincs lámpa, TC)

(def beep-on-start t)          ; induláskor sípol: 1x = 1-es profil, 2x = 2-es profil
(def beep-spacing 0.15)        ; s - a sípolások között legalább ennyi szünet (külön hallatszanak)

; Balansz mód (egykerekezés a hátsó keréken) - csak 2-es profilban. KÍSÉRLETI!
; Az alapértékek egy egyszerű modellből becsültek, a rolleredre hangolni kell
; (README: "Balansz mód"). A szög: fok, az eleje emelésekor nő, vízszintesen 0.
; IMU: a balansz szöge. 'bno085 = az első vezérlő COMM portjára kötött BNO085
; (az elso_vezerlo.lisp olvassa és CAN-en küldi), 'vesc = a VESC belső IMU-ja.
(def imu-source 'bno085)
(def imu-sid 0x4D2)               ; az első vezérlő BNO085 üzenete (elso_vezerlo.lisp imu-sid)
(def imu-period 0.01)             ; s - a BNO085 mintavétele (az első script bno-interval-ms-e)

(def balance-enabled t)
(def balance-axis 1)              ; IMU tengely a get-imu-rpy listából: 0 = roll, 1 = pitch
(def balance-invert nil)          ; t, ha az eleje emelésekor a nyers szög csökken
(def balance-level-offset 0.0)    ; fok - ennyit mutat a nyers szög vízszintes rollernél
(def balance-start-min 10.0)      ; fok - indításhoz legalább ennyire legyen fent az eleje
(def balance-start-max 35.0)      ; fok - és legfeljebb ennyire
(def balance-max-start-speed 1.0) ; km/h - csak álló helyzetből indul
(def balance-activate-level 0.9)  ; gáz és fék legalább ennyi (0-1)...
(def balance-activate-time 1.0)   ; s - ...ennyi ideig egyszerre
(def balance-hold-level 0.7)      ; a gáz e fölött (70%) tartja a balansz módot
(def balance-brake-level 0.3)     ; a fék e fölött (felengedése után) kilép
(def balance-cooldown 2.0)        ; s - kilépés után ennyi ideig nem indul újra
(def balance-kp 8.0)              ; A / fok - arányos tag
(def balance-ki 0.0)              ; A / (fok*s) - integráló tag
(def balance-kd 1.0)              ; A / (fok/s) - differenciáló tag (csillapítás)
(def balance-max-current 40.0)    ; A - fázisáram korlát (a VESC Tool limitje is érvényes)
(def balance-slew 400.0)          ; A/s - az áram legnagyobb változási sebessége
(def balance-ramp-in 0.3)         ; s - indításkor ennyi idő alatt jön fel a szabályzás
(def balance-land-angle 4.0)      ; fok - ez alatt az eleje leért: kilép
(def balance-max-angle 50.0)      ; fok - e fölött hátraborulás veszélye: kilép
(def balance-max-roll 30.0)       ; fok - oldalra dőlés: kilép
(def balance-max-speed 30.0)      ; km/h - e fölött sípol és lejjebb engedi az elejét (de nem teszi le)
(def balance-cutoff-speed 35.0)   ; km/h - e fölött kilép
(def balance-max-reverse 3.0)     ; km/h - ennél gyorsabb hátramenet: kilép
(def balance-land-rate 15.0)      ; fok/s - sebességkorlátnál ilyen gyorsan változik a célszög
(def balance-limit-drop 10.0)     ; fok - sebességkorlátnál legfeljebb ennyivel engedi lejjebb az elejét
(def balance-limit-min-angle 8.0) ; fok - de ennél lejjebb soha (a leszállás 4°-nál van)
(def balance-limit-beep 0.5)      ; s - sebességkorlátnál ilyen időközönként sípol

; -> Belső állapot (ne módosítsd) -----------------------------------------------

(def profile 0)                ; 0 = még nincs eldöntve, 1 vagy 2
(def state 'detect)            ; 'detect -> ('release) -> 'run
(def speedmode boot-mode)
(def light light-default)
(def beep-count 0)
(def kick-engaged nil)
(def thr-gate nil)             ; t = a gázt az ADC app "nulla" feszültségére fogjuk
(def thr-gate-v 0.0)
(def thr-gate-inv nil)
(def braking nil)
(def blink-on t)
(def blink-time 0)
(def temp-warn nil)
(def front-warn nil)
(def front-ack-time 0)
(def front-ack-flags -1)
(def boot-time 0)
(def lever-frames 0)
(def dash-ready nil)
(def first-lever-time 0)
(def last-lever-time 0)
(def last-0x64-time 0)
(def last-dash-tx 0)
(def thr-raw 0)
(def brk-raw 0)
(def thr-held nil)
(def thr-hold-start 0)
(def thr-release-start 0)
(def btn-state nil)
(def btn-cnt 0)
(def btn-presses 0)            ; összes észlelt lenyomás (diagnosztika)
(def btn-clicks 0)
(def btn-press-time 0)
(def btn-release-time 0)
(def btn-long-done nil)
(def t-front 0)
(def t-slow 0)
(def t-err 0)
(def front-last-flags -1)
(def front-flags-time 0)
(def thr-lvl 0.0)              ; gáz és fék 0-1 a nyers kijelzőértékből (a fogástól függetlenül)
(def brk-lvl 0.0)
(def thr-start 0.8)
(def thr-end 2.0)
(def brk-start 0.8)
(def brk-end 2.0)
(def bal-state 'off)           ; 'off, 'arming, 'on, 'limit (sebességkorlát)
(def bal-arm-start 0)
(def bal-start-time 0)
(def bal-exit-time 0)
(def bal-last-time 0)
(def bal-angle 0.0)
(def bal-roll 0.0)
(def bal-imu-ok nil)
(def bal-prev-angle 0.0)
(def bal-rate 0.0)
(def bal-setpoint 0.0)
(def bal-base-setpoint 0.0)      ; a bekapcsoláskori célszög
(def bal-beep-time 0)
(def bal-integral 0.0)
(def bal-current 0.0)
(def bal-brake-released nil)
(def bal-thr-lock nil)         ; balansz után a gáz a felengedéséig fogva marad
(def bal-reason 'nincs)        ; az utolsó kilépés oka
(def t-bal-err 0)
(def imu-roll 0.0)             ; BNO085 (első vezérlő): fok
(def imu-pitch 0.0)
(def imu-rate 0.0)             ; fok/s a balance-axis tengelyen, a mintákból
(def imu-cnt -1)               ; az utolsó minta sorszáma
(def imu-time 0)
(def bal-imu-rate 0.0)
(def last-beep 0)
(def front-version 0)          ; az első script verziója (a visszajelzésből), 0 = még nincs
(def front-old nil)            ; t = az első script régebbi, mint front-min-version
(def front-fault 0)            ; az első vezérlő VESC hibakódja
(def front-speed 0.0)          ; km/h, előjeles, az első vezérlő saját kerékadataival
(def front-speed-time 0)
(def tc-on tc-default)         ; kipörgésgátló be/ki (3x gomb)
(def tc-front 1.0)             ; az első kerék kipörgésgátló szorzója (1 = nincs beavatkozás)
(def tc-time 0)
(def rear-scale -1.0)          ; a hátsón utoljára beállított áram-szorzó
(def conf-missing nil)         ; a firmware által nem ismert paraméterek ((név . t) ...)
(def dash-test-field -1)       ; (ikon-teszt) alatt: a felülírt kijelző mező (-1 = nincs teszt)
(def dash-test-value 0)
(def dash-test-or t)           ; t = a bitet hozzáadja a mezőhöz, nil = a mezőt lecseréli
(def dash-test-step -1)        ; a teszt lépés száma, a sebesség helyén látszik (-1 = nincs)
(def dash-custom nil)          ; t = egyedi kijelző-firmware válaszolt (HELLO_ACK)
(def dash-fw 0)                ; a kijelző firmware verziója (fő * 10 + al)
(def dash-ext-time 0)          ; az utolsó bővítő keret a kijelzőtől
(def dash-hello-time 0)
(def dash-keep-time 0)         ; életjel (STYLE) a kijelzőnek másodpercenként
(def dash-name-pending nil)
(def dash-ble 0)               ; a kijelző Bluetooth-a: 0 = hirdet, 1 = kapcsolódva, 2 = nincs
(def dash-ble-mode 0)          ; 1 = Xiaomi app, 2 = VESC Tool
(def dash-credit 0)            ; ennyi bájtot küldhetünk még a VESC Tool felé
(def dash-cmd nil)             ; egy elküldésre váró kész bővítő keret (dash-text)
(def dash-seg-test -1)         ; (led-teszt): az égő LED sorszáma, -1 = nincs teszt
(def seg-sent 0)               ; a kijelzőn élő LED felülírás kulcsa
(def seg-time 0)
(def tun-size 1536)            ; a VESC Tool felé váró bájtok gyűrűje
(def tun-buf nil)
(def tun-head 0)               ; az eseménykezelő írja
(def tun-tail 0)               ; a soros szál olvassa
(def cmds-started nil)

@const-start

; -> Segédfüggvények

(defun clamp (x lo hi)
    (cond
        ((< x lo) lo)
        ((> x hi) hi)
        (t x)
))

(defun speed-kmh () (abs (* (get-speed) 3.6)))

(defun min2 (a b) (if (< a b) a b))

; Konfiguráció olvasása hibatűréssel. A kiadott 7.00-s firmware (2026-05-15)
; nem ismer néhány később hozzáadott paramétert (adc-tc, adc-v2-...): ezekre
; a conf-get hibát dob, ami az egész szálat leállítaná. Ilyenkor dflt.
; A trap-pel elkapott hibát a 7.00 a konzolra is kiírja ("Error (trapped):
; eval_error ... Parameter not recognized"), ezért erre az egy hívásra
; elrejtjük, és a nem ismert nevet megjegyezzük: legközelebb meg sem kérdezzük
; (a felhasználó képernyőképe, 2026-11-26; a fékkar kalibrációját 0,5 s-onként olvassuk).
(defun conf-try (name dflt)
    (if (assoc conf-missing name) dflt {
            (hide-trapped-error)
            (var r (trap (conf-get name)))
            (show-trapped-error)
            (if (eq (car r) 'exit-ok)
                (ix r 1)
                {
                    (setq conf-missing (acons name t conf-missing))
                    dflt
                })
}))

(defun conf-set-try (name val) ; t, ha sikerült
    (if (assoc conf-missing name) nil {
            (hide-trapped-error)
            (var r (trap (conf-set name val)))
            (show-trapped-error)
            (if (eq (car r) 'exit-ok)
                t
                {
                    (setq conf-missing (acons name t conf-missing))
                    nil
                })
}))

(defun mode-limits (prof mode)
    (if (= prof 2)
        (cond ((= mode 2) p2-eco) ((= mode 4) p2-sport) (t p2-drive))
        (cond ((= mode 2) p1-eco) ((= mode 4) p1-sport) (t p1-drive)) ; 0 = még nincs profil -> 1-es
))

(defun balancing () (or (eq bal-state 'on) (eq bal-state 'limit)))

(defun front-flags () ; bit0 = hajtás, bit1 = fék
    (cond
        ((balancing) 0) ; balansz: az első motor nem csinál semmit
        ((= profile 2) 3)
        (t (if p1-front-brake 2 0)))
)

; -> Módok és az első vezérlő

; A hátsó áram-szorzó: a mód szorzója (a kipörgésgátló a hátsóba nem szól bele).
; Ez a VESC "instant" konfigurációs útja (nem indítja újra az ADC app-ot), és
; csak változáskor írjuk. Balansz alatt a balansz állítja (teljes áram), ahhoz nem nyúlunk.
(defun apply-scale ()
    (if (not (balancing)) {
            (var s (/ (round (* 100.0 (ix (mode-limits profile speedmode) 2))) 100.0))
            (if (not (= s rear-scale)) {
                    (conf-set 'l-current-max-scale s)
                    (setq rear-scale s)
            })
}))

; A mód korlátai. Balansz alatt a balansz korlátai élnek; kilépéskor a
; balance-stop ezzel állítja vissza őket.
(defun apply-mode-limits ()
    (if (not (balancing)) {
            (var lim (mode-limits profile speedmode))
            (conf-set 'max-speed (/ (ix lim 0) 3.6))
            (conf-set 'l-watt-max (ix lim 1))
            (setq rear-scale -1.0) ; mindenképp újraírjuk
            (apply-scale)
}))

(defun apply-mode () {
        (apply-mode-limits)
        (send-front)
})

; 8 bájt: A5, flags, áram %, km/h*10 (u16), watt/100 (u16), profil
; flags: bit0 = hajtás, bit1 = fék (a 2-es bit a korábbi, első vezérlős lámpáé volt)
; Az áram % a mód szorzója x a kipörgésgátló első szorzója.
(defun send-front ()
    (if front-enabled {
            (var lim (mode-limits profile speedmode))
            (var flags (front-flags))
            (if (not (= flags front-last-flags)) {
                    (setq front-last-flags flags)
                    (setq front-flags-time (systime))
            })
            (bufset-u8 can-tx 0 0xA5)
            (bufset-u8 can-tx 1 flags)
            (bufset-u8 can-tx 2 (to-i (round (* 100.0 (ix lim 2) tc-front))))
            (bufset-u16 can-tx 3 (to-i (round (* 10.0 (ix lim 0)))))
            (bufset-u16 can-tx 5 (to-i (round (/ (ix lim 1) 100.0))))
            (bufset-u8 can-tx 7 profile)
            (can-send-sid front-cmd-sid can-tx)
}))

; Visszajelzés: A5, flags, áram %, VESC hibakód, állapot, verzió, sebesség
; (0,1 km/h, i16). A régi (1-es verziójú) első script csak 3-4 bájtot küld.
(defun on-front-ack (id data)
    (if (and (= id front-ack-sid) (>= (buflen data) 3) (= (bufget-u8 data 0) 0xA5)) {
            (setq front-ack-time (systime))
            (setq front-ack-flags (bufget-u8 data 1))
            (if (>= (buflen data) 8)
                {
                    (setq front-fault (bufget-u8 data 3))
                    (setq front-version (bufget-u8 data 5))
                    (setq front-speed (/ (bufget-i16 data 6) 10.0))
                    (setq front-speed-time (systime))
                }
                (setq front-version 1))
}))

; BNO085 minta az első vezérlőtől: roll, pitch, yaw (0,01 fok, i16), állapot,
; sorszám. A szögsebességet a sorszámok különbségéből és a mintavételből
; számoljuk, nem a beérkezés idejéből (a CAN/Lisp késése ingadozik).
(defun on-imu-frame (data)
    (if (and (>= (buflen data) 8) (= (bufget-u8 data 6) 1)) {
            (var roll (/ (bufget-i16 data 0) 100.0))
            (var pitch (/ (bufget-i16 data 2) 100.0))
            (var cnt (bufget-u8 data 7))
            (var dn (bitwise-and (- cnt imu-cnt) 255))
            (if (and (>= imu-cnt 0) (> dn 0) (< dn 10) (< (secs-since imu-time) 0.2))
                (setq imu-rate (/ (- (if (= balance-axis 0) roll pitch)
                            (if (= balance-axis 0) imu-roll imu-pitch))
                        (* dn imu-period))))
            (setq imu-roll roll)
            (setq imu-pitch pitch)
            (setq imu-cnt cnt)
            (setq imu-time (systime))
}))

(defun can-event-loop () ; CAN visszajelzés, IMU és a VESC Tool alagút válaszai
    (loopwhile t
        (recv
            ((event-can-sid . ((? id) . (? data)))
                (if (= id imu-sid) (on-imu-frame data) (on-front-ack id data)))
            ((event-cmds-data-tx (? data)) (tun-push data))
            (_ nil)
)))

(defun update-front-warn () {
        (var on (and front-enabled
                (> (secs-since boot-time) 4.0)
                (> (length (can-list-devs)) 0)))
        (setq front-warn
            (and on
                (or (> (secs-since front-ack-time) 1.0)
                    (and (not (= front-ack-flags (front-flags)))
                        (> (secs-since front-flags-time) 1.0)))))
        ; válaszol, de régi scripttel: a lámpa és a kipörgésgátló nem megy
        (setq front-old (and on (not front-warn) (< front-version front-min-version)))
})

; -> Kipörgésgátló (csak 2-es profilban, csak az első kerékre)
; A hátsó kerék sebessége helyben, az elsőé a visszajelzésből jön (az első
; vezérlő saját kerékadataival számolva, 50 Hz-en). Ha az első gyorsabban forog
; a megengedettnél, az első vezérlő áram-szorzóját csökkentjük (a CAN parancs
; áram %-a). A hátsó kerékbe nem avatkozik bele, a VESC Tool beállításai
; (görbe, rámpa) maradnak. Csökkenés azonnal, visszaállás tc-recover alatt.

(defun tc-factor (excess) ; az első kerék hajtásának szorzója (0-1)
    (clamp (- 1.0 (/ (- excess tc-slip) tc-range)) 0.0 1.0)
)

(defun tc-active () ; balansz alatt az első áll, a hátsót a balansz vezérli
    (and tc-on (= profile 2) (eq state 'run) front-enabled (not (balancing))
        (< (secs-since front-speed-time) 0.2))
)

(defun tc-follow (cur k dt)
    (if (< k cur) k (min2 k (+ cur (if (> tc-recover 0.01) (/ dt tc-recover) 1.0))))
)

(defun tc-step () {
        (var dt (clamp (secs-since tc-time) 0.0 0.1))
        (setq tc-time (systime))
        (var kf 1.0)
        (if (tc-active) {
                (var rear (* (get-speed) 3.6))
                (var d (- front-speed rear))          ; + = az első forog gyorsabban
                (if (< rear 0.0) (setq d (- 0.0 d)))  ; hátrafelé gurulva fordítva
                (setq kf (tc-factor d))
        })
        (setq tc-front (tc-follow tc-front kf dt))
})

(defun tc-toggle () ; 3 gyors gombnyomás
    (if (= profile 2)
        {
            (setq tc-on (not tc-on))
            (setq beep-count 3)
            (button-log-msg (if tc-on "3x -> kiporgesgatlo BE" "3x -> kiporgesgatlo KI"))
        }
        (button-log-msg "3x -> a kiporgesgatlo csak 2-es profilban van"))
)

; REPL-ből hívható: (tc-teszt) - 10 s-ig írja a két kerék sebességét és a
; kipörgésgátló szorzóit (hangoláshoz: tc-slip, tc-range, tc-recover)
(defun tc-teszt () {
        (print (str-merge "Kiporgesgatlo: " (if tc-on "BE" "KI")
                (if (tc-active) " (aktiv)" " (most nem aktiv: csak 2-es profilban, futas kozben)")
                ", slip " (str-from-n tc-slip "%.1f") " km/h, tartomany "
                (str-from-n tc-range "%.1f") " km/h"))
        (looprange i 0 50 {
                (print (str-merge "elso " (str-from-n front-speed "%.1f")
                        "  hatso " (str-from-n (* (get-speed) 3.6) "%.1f")
                        " km/h  ->  elso hajtas x" (str-from-n tc-front "%.2f")))
                (sleep 0.2)
        })
})

(defun update-temp-warn () {
        (var fet (get-temp-fet))
        (var mot (get-temp-mot))
        (loopforeach id (can-list-devs) {
                (var f (canget-temp-fet id))
                (var m (canget-temp-motor id))
                (if (> f fet) (setq fet f))
                (if (> m mot) (setq mot m))
        })
        (setq temp-warn (or (> fet temp-warn-fet) (> mot temp-warn-motor)))
})

; A berúgás-tiltásnál a gázt az ADC app "start" feszültségére fogjuk vissza,
; ami a VESC Tool kalibráció szerint pont 0 gáz. Fordított (start > end)
; kalibrációnál a másik irányba fogunk.
(defun refresh-gate () {
        (var start (conf-get 'adc-v1-start))
        (setq thr-start start)
        (setq thr-end (conf-get 'adc-v1-end))
        ; A fékkar (ADC2) kalibrációját a kiadott 7.00-s firmware nem adja ki a
        ; Lispnek: ott a gázkarét használjuk (a két kar azonos típusú).
        (setq brk-start (conf-try 'adc-v2-start start))
        (setq brk-end (conf-try 'adc-v2-end thr-end))
        (setq thr-gate-inv (> start thr-end))
        (setq thr-gate-v start)
})

(defun lever-level (v start end) ; 0-1 a VESC Tool ADC kalibrációja szerint (fordítottan is)
    (if (= start end) 0.0 (clamp (/ (- v start) (- end start)) 0.0 1.0))
)

; -> Kijelző protokoll (Xiaomi)
; Keret: 55 AA len addr cmd arg payload... crc_lo crc_hi
; len = payload + 2, crc = (len + addr..payload összege) XOR 0xFFFF, low byte elöl

(defun read-u8 () {
        (uart-read-bytes rx-one 1 0)
        (bufget-u8 rx-one 0)
})

(defun lever-input (off) { ; gáz és fék nyers bájt: rx-buf[off], rx-buf[off+1]
        (setq thr-raw (bufget-u8 rx-buf off))
        (setq brk-raw (bufget-u8 rx-buf (+ off 1)))
        (var thr-v (clamp (/ thr-raw 77.27) 0.0 3.3)) ; 255 -> 3.3 V
        (var brk-v (clamp (/ brk-raw 77.27) 0.0 3.3))
        (setq thr-lvl (lever-level thr-v thr-start thr-end))
        (setq brk-lvl (lever-level brk-v brk-start brk-end))
        ; A még éledő kijelző 0x0a-t küld mindkét karra, az még nem valós érték.
        (if (and (not dash-ready) (or (> thr-raw 16) (> brk-raw 16))) {
                (setq dash-ready t)
                (setq first-lever-time (systime))
        })
        (setq lever-frames (+ lever-frames 1))
        (setq last-lever-time (systime))
        (if thr-gate
            (setq thr-v
                (if thr-gate-inv
                    (if (> thr-v thr-gate-v) thr-v thr-gate-v)
                    (if (< thr-v thr-gate-v) thr-v thr-gate-v))))
        ; Csak friss keretre írjuk felül: ha a kijelző elhallgat, a VESC
        ; timeout leállítja a motort.
        (app-adc-override 0 thr-v)
        (app-adc-override 1 brk-v)
})

; A kijelzőnek küldött mező (0 = mód, 1 = akku, 2 = lámpa, 3 = sípolás,
; 4 = sebesség, 5 = hibakód) egy bitjét bekapcsolja.
(defun dash-or (field bits)
    (bufset-u8 tx-frame (+ 6 field) (bitwise-or (bufget-u8 tx-frame (+ 6 field)) bits)))

; A kipörgésgátló jelzése (tc-icon-field): a kapcsoló állása 2-es profilban.
(defun tc-icon-on ()
    (and tc-on (= profile 2) (>= tc-icon-field 0) (<= tc-icon-field 5)))

(defun send-dash () {
        (var spd (speed-kmh))
        (var batt (to-i (clamp (* (get-batt) 100.0) 0.0 100.0)))
        (var shown (if (and (= profile 2) (< spd p2-idle-speed)) batt (to-i (+ spd 0.5))))
        (var fault (get-fault))
        (var beep 0)
        ; minden sípolás egy keret, köztük legalább beep-spacing szünettel
        (if (and (> beep-count 0) (> (secs-since last-beep) beep-spacing)) {
                (setq beep 1)
                (setq beep-count (- beep-count 1))
                (setq last-beep (systime))
        })
        ; mód bájt: 1 = D, 2 = ECO, 4 = S, +128 = hőfok ikon
        (bufset-u8 tx-frame 6 (+ speedmode (if temp-warn 128 0)))
        (bufset-u8 tx-frame 7 batt)
        (bufset-u8 tx-frame 8 (if light dash-light-value 0)) ; a kijelző lámpája + ikon
        (bufset-u8 tx-frame 9 beep)
        (bufset-u8 tx-frame 10 (clamp shown 0 255))
        (bufset-u8 tx-frame 11
            (cond
                ((> fault 0) fault)
                (front-warn front-error-code)
                (front-old front-old-error-code)
                (t 0)))
        (if (< dash-test-field 0)
            (if (tc-icon-on) (dash-or tc-icon-field tc-icon-bit)) ; kipörgésgátló jelzés
            (if dash-test-or ; (ikon-teszt)
                (dash-or dash-test-field dash-test-value)
                (bufset-u8 tx-frame (+ 6 dash-test-field) dash-test-value)))
        (if (>= dash-test-step 0) (bufset-u8 tx-frame 10 dash-test-step))
        (var sum 0)
        (looprange i 2 12 (setq sum (+ sum (bufget-u8 tx-frame i))))
        (var crc (bitwise-xor sum 0xFFFF))
        (bufset-u8 tx-frame 12 (bitwise-and crc 0xFF))
        (bufset-u8 tx-frame 13 (bitwise-and (shr crc 8) 0xFF))
        (uart-write tx-frame)
        (setq last-dash-tx (systime))
})

; -> Egyedi kijelző-firmware: bővítő keretek (cmd 0x7A, alparancs az arg bájtban)
; Leírás: a kijelző repójában docs/protokoll.md. A kijelző minden bővítő kerete
; gáz/fék keret is ([04 gáz fék 00 00] a payload elején). Kijelzőnként (keretenként)
; legfeljebb egy bővítő keretet küldünk válaszként, a 0x64-re az állapotkeret után.

(defun tun-used () { ; a gyűrűben váró bájtok (az író és az olvasó külön mutatót állít)
        (var n (- tun-head tun-tail))
        (if (< n 0) (+ n tun-size) n)
})

; A VESC parancsfeldolgozó válasza (event-cmds-data-tx) a gyűrűbe. Ha nem fér el,
; eldobjuk (a VESC Tool újrakéri).
(defun tun-push (data) {
        (var n (buflen data))
        (if (and tun-buf (< (+ (tun-used) n) tun-size)) {
                (var n1 (min2 n (- tun-size tun-head)))
                (bufcpy tun-buf tun-head data 0 n1)
                (if (> n n1) (bufcpy tun-buf 0 data n1 (- n n1)))
                (setq tun-head (mod (+ tun-head n) tun-size))
        })
})

; Fejléc és CRC a kész payload köré (a payload a 6. bájttól már a helyén van).
(defun dx-fill (f sub) {
        (var n (- (buflen f) 8))
        (bufset-u16 f 0 0x55AA)
        (bufset-u8 f 2 (+ n 2))
        (bufset-u8 f 3 0x21) ; ESC -> kijelző
        (bufset-u8 f 4 0x7A)
        (bufset-u8 f 5 sub)
        (var sum 0)
        (looprange i 2 (+ n 6) (setq sum (+ sum (bufget-u8 f i))))
        (var crc (bitwise-xor (bitwise-and sum 0xFFFF) 0xFFFF))
        (bufset-u8 f (+ n 6) (bitwise-and crc 0xFF))
        (bufset-u8 f (+ n 7) (bitwise-and (shr crc 8) 0xFF))
        f
})

(defun dx-send (f sub) {
        (uart-write (dx-fill f sub))
        (free f)
})

; LED felülírás: be[6] ki[6] villog[6], ttl x100 ms (0 = törlés)
(defun dx-segments (ttl seg-byte bits off-all blink) {
        (var f (bufcreate 27))
        (bufset-u8 f 6 ttl)
        (if (>= seg-byte 0) (bufset-u8 f (+ (if blink 19 7) seg-byte) bits))
        (if off-all (looprange i 13 19 (bufset-u8 f i 0xFF)))
        (dx-send f 0x10)
})

(defun tc-seg-on () (and tc-on (= profile 2) (>= tc-seg-byte 0) (> tc-seg-bit 0)))

; A kívánt LED felülírások bitjei: 1 = kipörgésgátló, 2 = az villog. Egy keretben
; mind egyszerre megy (a SEGMENTS keret a kijelző teljes felülírását cseréli).
(defun seg-flags ()
    (+ (if (tc-seg-on) 1 0)
        (if (and (tc-seg-on) tc-seg-blink (< tc-front 0.99)) 2 0)))

(defun seg-key () ; a kívánt LED felülírás azonosítója, 0 = nincs
    (if (>= dash-seg-test 0) (+ 1000 dash-seg-test) (seg-flags)))

(defun seg-or (f base seg-byte bits) ; f: SEGMENTS keret; base 7 = be, 19 = villog
    (bufset-u8 f (+ base seg-byte) (bitwise-or (bufget-u8 f (+ base seg-byte)) bits)))

(defun seg-due () {
        (var k (seg-key))
        (or (not (= k seg-sent)) (and (> k 0) (> (secs-since seg-time) 0.5)))
})

(defun send-seg () {
        (var k (seg-key))
        (setq seg-sent k)
        (setq seg-time (systime))
        (cond
            ((>= dash-seg-test 0)
                (dx-segments 30 (/ dash-seg-test 8) (shl 1 (mod dash-seg-test 8)) t nil))
            ((> k 0) {
                    (var f (bufcreate 27))
                    (bufset-u8 f 6 15) ; ttl 1,5 s, 0,5 s-onként frissítjük
                    (if (= (bitwise-and k 1) 1)
                        (seg-or f (if (= (bitwise-and k 2) 2) 19 7) tc-seg-byte tc-seg-bit))
                    (dx-send f 0x10)
            })
            (t (dx-segments 0 -1 0 nil nil)))
})

(defun tunnel-down () { ; a VESC Tool felé váró bájtokból legfeljebb 100, ha a kijelzőnek van helye
        (var k (min2 (min2 (tun-used) 100) dash-credit))
        (if (> k 0) {
                (var f (bufcreate (+ k 8)))
                (var n1 (min2 k (- tun-size tun-tail)))
                (bufcpy f 6 tun-buf tun-tail n1)
                (if (> k n1) (bufcpy f (+ 6 n1) tun-buf 0 (- k n1)))
                (setq tun-tail (mod (+ tun-tail k) tun-size))
                (setq dash-credit (- dash-credit k))
                (dx-send f 0x20)
        })
})

; Egy kijelzőkeret után legfeljebb egy bővítő keret: HELLO (amíg nem ismert az
; egyedi firmware), név, LED felülírás, életjel/stílus, egyszeri parancs, alagút.
(defun dx-reply (cmd) {
        (cond
            ((not dash-ext) nil)
            ((not dash-custom)
                (if (and (= cmd 0x64)
                        (or (= dash-hello-time 0) (> (secs-since dash-hello-time) 1.0))) {
                        (setq dash-hello-time (systime))
                        (var f (bufcreate 10))
                        (bufset-u8 f 6 1) ; protokoll verzió
                        (dx-send f 0x01)
                }))
            ((and dash-name-pending ble-name) {
                    (setq dash-name-pending nil)
                    (var n (min2 (- (buflen ble-name) 1) 20)) ; a lezáró 0 nélkül
                    (var f (bufcreate (+ n 8)))
                    (bufcpy f 6 ble-name 0 n)
                    (dx-send f 0x17)
            })
            ((seg-due) (send-seg))
            ((> (secs-since dash-keep-time) 1.0) {
                    (setq dash-keep-time (systime))
                    (var f (bufcreate 11))
                    (bufset-u8 f 6 speed-color)
                    (bufset-u8 f 7 1) ; hibakód: piros
                    (bufset-u8 f 8 0) ; töltés: fehér
                    (dx-send f 0x13)
            })
            (dash-cmd {
                    (var f dash-cmd)
                    (setq dash-cmd nil)
                    (uart-write f)
                    (free f)
            })
            (t (tunnel-down))
        )
})

; Bővítő keret a kijelzőtől. rx-buf: [0] cím, [1] 0x7A, [2] alparancs,
; [3..7] gáz/fék blokk, [8..] adat.
(defun dash-ext-frame (len) {
        (var sub (bufget-u8 rx-buf 2))
        (setq dash-ext-time (systime))
        (cond
            ((and (= sub 0x81) (>= len 12)) { ; HELLO_ACK
                    (if (not dash-custom) (print "Egyedi kijelzo-firmware felismerve"))
                    (setq dash-custom t)
                    (setq dash-fw (+ (* 10 (bufget-u8 rx-buf 9)) (bufget-u8 rx-buf 10)))
                    (setq dash-name-pending (not (eq ble-name nil))) ; nil = a kijelző alapneve
                    (setq dash-keep-time 0)
                    (setq seg-sent -1)
            })
            ((and (= sub 0x82) (>= len 11)) { ; STATUS
                    (setq dash-custom t)
                    (setq dash-ble (bufget-u8 rx-buf 8))
                    (setq dash-ble-mode (bufget-u8 rx-buf 9))
                    (setq dash-credit (bufget-u16 rx-buf 10 'little-endian))
            })
            ((and (= sub 0xA0) (>= len 9)) { ; TUNNEL_UP: VESC Tool -> VESC
                    (setq dash-custom t)
                    (setq dash-credit (bufget-u16 rx-buf 8 'little-endian))
                    (var n (- len 9))
                    (if (and (> n 0) cmds-started) {
                            (var d (bufcreate n))
                            (bufcpy d 0 rx-buf 10 n)
                            (trap (cmds-proc d))
                            (free d)
                    })
            })
        )
})

; REPL-ből hívható: (dash-text "P2" 1 20) - két karakter a sebesség helyén
; (egyedi kijelzőn). color: 0 = fehér, 1 = piros, 2 = mindkettő; ttl x100 ms, 0 = törlés.
(defun dash-text (txt color ttl) {
        (var f (bufcreate 13))
        (bufset-u8 f 6 ttl)
        (bufset-u8 f 8 color)
        (bufset-u8 f 9 (bufget-u8 txt 0))
        (bufset-u8 f 10 (bufget-u8 txt 1))
        (setq dash-cmd (dx-fill f 0x12))
})

(defun process-frame (len) {
        (var addr (bufget-u8 rx-buf 0))
        (var cmd (bufget-u8 rx-buf 1))
        (if (not (= addr 0x21)) { ; 0x21 = ESC -> kijelző, a saját keretünk
                ; gáz/fék a 0x64, 0x65 (és az egyedi kijelző 0x7A) keretében a 4-5. bájton,
                ; app olvasásnál (0x61) eggyel arrébb
                (cond
                    ((and (or (= cmd 0x64) (= cmd 0x65) (= cmd 0x7A)) (>= len 5)) (lever-input 4))
                    ((and (= cmd 0x61) (>= len 6)) (lever-input 5))
                )
                (if (= cmd 0x64) (setq last-0x64-time (systime)))
                (if (= cmd 0x7A) (dash-ext-frame len))
                ; A gyári vezérlő a 0x64-re válaszol. Ha nem jön 0x64, a 0x65-re válaszolunk.
                (if (and (> (secs-since last-dash-tx) 0.04)
                        (or (= cmd 0x64)
                            (and (= cmd 0x65) (> (secs-since last-0x64-time) 0.5))))
                    (send-dash))
                (if (or (= cmd 0x64) (= cmd 0x65) (= cmd 0x7A)) (dx-reply cmd))
        })
})

(defun read-frame () {
        (var len (read-u8))
        (if (>= len 2) { ; len <= 255: az rx-buf 260 bájtos
                (uart-read-bytes rx-buf (+ len 3) 0) ; addr..payload + 2 crc bájt
                (var sum len)
                (looprange i 0 (+ len 1) (setq sum (+ sum (bufget-u8 rx-buf i))))
                (var crc (+ (bufget-u8 rx-buf (+ len 1)) (shl (bufget-u8 rx-buf (+ len 2)) 8)))
                (if (= crc (bitwise-xor sum 0xFFFF))
                    (process-frame len))
        })
})

(defun rx-loop () {
        (var prev 0)
        (loopwhile t {
                (var b (read-u8))
                (if (and (= prev 0x55) (= b 0xAA)) { ; fejléc, bájtonként szinkronizálva
                        (setq prev 0)
                        (read-frame)
                    }
                    (setq prev b))
        })
})

(defun rx-thread ()
    (loopwhile t {
            (trap (rx-loop)) ; egy hiba ne állítsa le az olvasást
            (sleep 0.01)
}))

; -> Gomb (RX láb, digitális)

(defun button-log-msg (what) ; csak ASCII a konzolra
    (if button-log (print (str-merge "gomb " what)))
)

(defun button-action (clicks)
    (cond
        ((= clicks 1) {
                (setq light (not light))
                (button-log-msg (if light "1x -> lampa BE" "1x -> lampa KI"))
        })
        ((= clicks 2)
            (if (balancing)
                (button-log-msg "balansz alatt nincs modvaltas") ; az áramkorlátot nem vesszük el
                { ; D -> S -> ECO -> D
                    (setq speedmode (cond ((= speedmode 1) 4) ((= speedmode 4) 2) (t 1)))
                    (apply-mode)
                    (setq beep-count 1)
                    (button-log-msg (str-merge "2x -> mod "
                            (cond ((= speedmode 2) "ECO") ((= speedmode 4) "S") (t "D"))))
                }))
        ((= clicks 3) (tc-toggle))
        (t (button-log-msg (str-merge (str-from-n clicks "%d") "x -> nincs funkcio"))))
)

(defun button-step () {
        (var raw (= (gpio-read button-pin) 0)) ; lenyomva = 0
        ; pergésmentesítés: lenyomás 3, elengedés 2 egymás utáni minta (20 ms-onként)
        (if (eq raw btn-state)
            (setq btn-cnt 0)
            (setq btn-cnt (+ btn-cnt 1)))
        (if (>= btn-cnt (if raw 3 2)) {
                (setq btn-cnt 0)
                (setq btn-state raw)
                (if raw
                    {
                        (setq btn-press-time (systime))
                        (setq btn-long-done nil)
                        (setq btn-presses (+ btn-presses 1))
                        (button-log-msg "le")
                    }
                    {
                        (button-log-msg "fel")
                        (if (not btn-long-done) {
                                (setq btn-clicks (+ btn-clicks 1))
                                (setq btn-release-time (systime))
                        })
                    })
        })
        (if (and btn-state (not btn-long-done) (> (secs-since btn-press-time) long-press-time)) {
                (setq btn-long-done t) ; hosszú nyomás: nincs funkció, eldobjuk
                (setq btn-clicks 0)
                (button-log-msg "hosszu nyomas, eldobva")
        })
        (if (and (not btn-state) (> btn-clicks 0) (> (secs-since btn-release-time) double-click-time)) {
                (button-action btn-clicks)
                (setq btn-clicks 0)
        })
})

; REPL-ből hívható: (gomb-teszt) - 5 másodpercig írja a gomb lábának állapotát
(defun gomb-teszt () {
        (var start btn-presses)
        (print "Gomb teszt 5 s: nyomogasd a gombot (1 = felengedve, 0 = lenyomva)")
        (looprange i 0 25 {
                (print (if (= (gpio-read button-pin) 0) "lab = 0  LENYOMVA" "lab = 1"))
                (sleep 0.2)
        })
        (print (str-merge "Eszlelt lenyomasok: " (str-from-n (- btn-presses start) "%d")))
})

; -> Lámpák

; A külső lámpa lábai a hátsó vezérlő SWD csatlakozóján.
(defun lamp-config () {
        (gpio-configure headlight-pin headlight-mode)
        (if headlight-pin2 (gpio-configure headlight-pin2 headlight-mode))
})

(defun lamp-write (v) {
        (gpio-write headlight-pin v)
        (if headlight-pin2 (gpio-write headlight-pin2 v))
})

(defun lights-step () {
        (if braking
            (if (> (secs-since blink-time) brake-blink-half) {
                    (setq blink-on (not blink-on))
                    (setq blink-time (systime))
            })
            (setq blink-on t)) ; nem fékez: folyamatosan világít
        (gpio-write 'pin-ppm (if blink-on 1 0))
        (lamp-write (if light 1 0))
})

; -> Balansz mód (egykerekezés, csak 2-es profilban)
; A hátsó motor egy PID szabályzóval tartja a roller dőlésszögét, mint egy
; önegyensúlyozó jármű: ha az eleje lejjebb kerül a célszögnél, gyorsít (ez
; visszaemeli), ha feljebb, fékez. A sebességet a versenyző a testsúlyával
; adja (előre dőlve gyorsít, hátra dőlve lassít). Saját szálon fut 100 Hz-en.

(defun read-imu ()
    (if (eq imu-source 'bno085)
        { ; az első vezérlő BNO085-je: 0,1 s-nál régebbi adat = nincs IMU
            (var raw (if (= balance-axis 0) imu-roll imu-pitch))
            (setq bal-roll (if (= balance-axis 0) imu-pitch imu-roll))
            (setq bal-angle (- (if balance-invert (- 0.0 raw) raw) balance-level-offset))
            (setq bal-imu-rate (if balance-invert (- 0.0 imu-rate) imu-rate))
            (setq bal-imu-ok (< (secs-since imu-time) 0.1))
        }
        {
            (var rpy (get-imu-rpy))
            (var raw (rad2deg (ix rpy balance-axis)))
            (setq bal-roll (rad2deg (ix rpy (if (= balance-axis 0) 1 0))))
            (setq bal-angle (- (if balance-invert (- 0.0 raw) raw) balance-level-offset))
            ; IMU nélkül (vagy kikapcsolt IMU-val) a gyorsulásmérő 0-t ad
            (var acc (get-imu-acc))
            (setq bal-imu-ok (> (+ (* (ix acc 0) (ix acc 0)) (* (ix acc 1) (ix acc 1))
                        (* (ix acc 2) (ix acc 2))) 0.09))
        })
)

(defun balance-can-arm ()
    (and balance-enabled (= profile 2) (eq state 'run) bal-imu-ok
        (< (secs-since last-lever-time) 0.3)
        (> (secs-since bal-exit-time) balance-cooldown)
        (< (speed-kmh) balance-max-start-speed)
        (>= bal-angle balance-start-min)
        (<= bal-angle balance-start-max)
        (< (abs bal-roll) balance-max-roll)
        (= (get-fault) 0)
        (>= thr-lvl balance-activate-level)
        (>= brk-lvl balance-activate-level))
)

(defun balance-start () {
        (setq bal-setpoint (clamp bal-angle balance-start-min balance-start-max))
        (setq bal-base-setpoint bal-setpoint)
        (setq bal-integral 0.0)
        (setq bal-current 0.0)
        (setq bal-prev-angle bal-angle)
        (setq bal-rate 0.0)
        (setq bal-brake-released nil)
        (setq bal-start-time (systime))
        (setq bal-last-time (systime))
        (setq bal-state 'on)
        ; Az ADC app kimenete tiltva: a hátsó motort innen vezéreljük, az első
        ; motor így nem kap parancsot (és a CAN üzenet is tiltja, front-flags).
        (app-disable-output -1)
        ; teljes fázisáram, és a VESC sebességkorlátja ne vágjon bele a
        ; balansz saját sebességkorlátja előtt (kilépéskor a mód korlátai visszaállnak)
        (conf-set 'l-current-max-scale 1.0)
        (conf-set 'max-speed (/ (+ balance-cutoff-speed 5.0) 3.6))
        (setq beep-count 2)
        (print (list 'balansz-be 'celszog bal-setpoint))
})

(defun balance-stop (reason) {
        (setq bal-state 'off)
        (setq bal-exit-time (systime))
        (setq bal-reason reason)
        (setq bal-thr-lock t) ; a gáz a felengedéséig fogva marad, a fék működik
        (setq thr-gate t)
        (set-current 0.0)
        (setq bal-current 0.0)
        (apply-mode-limits)
        (app-disable-output 0)
        (setq beep-count 1)
        (print (list 'balansz-ki reason))
})

(defun balance-control (dt spd) {
        ; Sebességkorlát: sípol, és a célszöget lassan lejjebb viszi (a lejjebb
        ; engedett eleje fékezéssel jár), de nem teszi le. 2 km/h-val a korlát
        ; alatt a célszög visszaáll a bekapcsoláskorira.
        (if (and (eq bal-state 'on) (> spd balance-max-speed)) (setq bal-state 'limit))
        (if (and (eq bal-state 'limit) (< spd (- balance-max-speed 2.0))) (setq bal-state 'on))
        (var target (if (eq bal-state 'limit)
                (if (> (- bal-base-setpoint balance-limit-drop) balance-limit-min-angle)
                    (- bal-base-setpoint balance-limit-drop)
                    balance-limit-min-angle)
                bal-base-setpoint))
        (var sstep (* balance-land-rate dt))
        (setq bal-setpoint (+ bal-setpoint (clamp (- target bal-setpoint) (- 0.0 sstep) sstep)))
        (if (and (eq bal-state 'limit) (> (secs-since bal-beep-time) balance-limit-beep)) {
                (setq bal-beep-time (systime))
                (setq beep-count 1)
        })
        (var err (- bal-setpoint bal-angle)) ; + = az eleje lejjebb van -> gyorsítani kell
        (var ilim (if (> balance-ki 0.0) (/ (* 0.5 balance-max-current) balance-ki) 0.0))
        (setq bal-integral (clamp (+ bal-integral (* err dt)) (- 0.0 ilim) ilim))
        (var out (- (+ (* balance-kp err) (* balance-ki bal-integral)) (* balance-kd bal-rate)))
        (var ramp (if (> balance-ramp-in 0.0)
                (clamp (/ (secs-since bal-start-time) balance-ramp-in) 0.0 1.0)
                1.0))
        (setq out (clamp (* out ramp) (- 0.0 balance-max-current) balance-max-current))
        (var step (* balance-slew dt))
        (setq bal-current (+ bal-current (clamp (- out bal-current) (- 0.0 step) step)))
        (set-current bal-current 0.05)
})

(defun balance-step () {
        (read-imu)
        (var dt (clamp (secs-since bal-last-time) 0.001 0.05))
        (setq bal-last-time (systime))
        (var raw-rate (if (eq imu-source 'bno085) bal-imu-rate (/ (- bal-angle bal-prev-angle) dt)))
        (setq bal-rate (+ bal-rate (* 0.3 (- raw-rate bal-rate))))
        (setq bal-prev-angle bal-angle)
        (var spd (* (get-speed) 3.6)) ; előjeles: hátramenet negatív
        (if (< brk-lvl 0.2) (setq bal-brake-released t))
        (cond
            ((< thr-lvl balance-hold-level) (balance-stop 'gaz-elengedve))
            ((and bal-brake-released (> brk-lvl balance-brake-level)) (balance-stop 'fek))
            ((and (not bal-brake-released) (> (secs-since bal-start-time) 2.0)) (balance-stop 'fek-nincs-elengedve))
            ((> (secs-since last-lever-time) 0.3) (balance-stop 'nincs-kijelzo))
            ((not (= (get-fault) 0)) (balance-stop 'vezerlo-hiba))
            ((not bal-imu-ok) (balance-stop 'imu))
            ((> bal-angle balance-max-angle) (balance-stop 'tul-nagy-szog))
            ((> (abs bal-roll) balance-max-roll) (balance-stop 'oldaldoles))
            ((< spd (- 0.0 balance-max-reverse)) (balance-stop 'hatramenet))
            ((> spd balance-cutoff-speed) (balance-stop 'tul-gyors))
            ((< bal-angle balance-land-angle) (balance-stop 'leszallt))
            (t (balance-control dt spd)))
})

(defun balance-arm-step ()
    (if (balance-can-arm)
        (if (eq bal-state 'arming)
            (if (> (secs-since bal-arm-start) balance-activate-time) (balance-start))
            {
                (setq bal-state 'arming)
                (setq bal-arm-start (systime))
            })
        (setq bal-state 'off))
)

(defun balance-tick ()
    (if (balancing)
        (balance-step)
        {
            (read-imu)
            (balance-arm-step)
        })
)

(defun balance-thread ()
    (loopwhile t {
            (var res (trap (balance-tick)))
            (if (eq (car res) 'exit-error) {
                    (if (balancing) (trap (balance-stop 'script-hiba)) (setq bal-state 'off))
                    (if (> (secs-since t-bal-err) 1.0) {
                            (setq t-bal-err (systime))
                            (print (list 'hiba-balansz (cdr res)))
                    })
            })
            (sleep 0.01)
}))

; REPL-ből hívható: (szog) - 5 másodpercig írja a nyers és a balansz szöget
(defun szog () {
        (print "Szog teszt 5 s: emeld meg a roller elejet, a balansz szognek nonie kell")
        (print (if (eq imu-source 'bno085) "IMU: BNO085 az elso vezerlon" "IMU: a VESC belso IMU-ja"))
        (looprange i 0 25 {
                (var rpy (get-imu-rpy))
                (var r (if (eq imu-source 'bno085) imu-roll (rad2deg (ix rpy 0))))
                (var p (if (eq imu-source 'bno085) imu-pitch (rad2deg (ix rpy 1))))
                (print (str-merge "roll " (str-from-n r "%.1f")
                        "  pitch " (str-from-n p "%.1f")
                        "  -> balansz szog " (str-from-n bal-angle "%.1f")
                        (if bal-imu-ok "" "  (NINCS IMU ADAT)")))
                (sleep 0.2)
        })
})

; -> Profil választás és vezérlés

(defun choose-profile (p) {
        (setq profile p)
        (apply-mode)
        (if (= p 2)
            {
                (setq beep-count (if beep-on-start 2 0))
                (setq thr-release-start (systime))
                (setq state 'release) ; amíg a gáz nincs elengedve, nincs kimenet
            }
            {
                (setq beep-count (if beep-on-start 1 0))
                (setq kick-engaged nil)
                (setq thr-gate t) ; a kimenet engedélyezése előtt már fogjuk a gázt
                (app-disable-output 0)
                (setq state 'run)
            })
        (print (str-merge "Profil: " (str-from-n p "%d")
                ", gomb lab: " (str-from-n (gpio-read button-pin) "%d") " (1 = felengedve)"))
})

(defun detect-step (thr) {
        ; a gáznak folyamatosan p2-detect-hold ideig fent kell lennie
        (if (and dash-ready (> thr p2-detect-throttle))
            (if thr-held
                (if (> (secs-since thr-hold-start) p2-detect-hold) (choose-profile 2))
                {
                    (setq thr-held t)
                    (setq thr-hold-start (systime))
                })
            (setq thr-held nil))
        (if (eq state 'detect)
            (if dash-ready
                (if (> (secs-since first-lever-time) p2-detect-window) (choose-profile 1))
                (if (> (secs-since boot-time) 6.0) (choose-profile 1)))) ; nincs kijelző
})

(defun release-step (thr)
    (if (< thr throttle-released)
        (if (> (secs-since thr-release-start) 0.3) {
                (app-disable-output 0)
                (setq state 'run)
        })
        (setq thr-release-start (systime))
))

(defun run-step (spd) {
        (if (= profile 1)
            (if kick-engaged
                (if (< spd kick-release-speed) (setq kick-engaged nil))
                (if (>= spd kick-speed) (setq kick-engaged t)))
            (setq kick-engaged t))
        ; balansz után a gáz addig fogva marad, amíg el nem engedik (a fék közben működik)
        (if (and bal-thr-lock (not (balancing)) (< thr-lvl 0.05)) (setq bal-thr-lock nil))
        (setq thr-gate (or (not kick-engaged) bal-thr-lock))
})

(defun control-step () {
        (var spd (speed-kmh))
        (var fresh (< (secs-since last-lever-time) 0.5))
        (var thr (if fresh (get-adc-decoded 0) 0.0))
        (var brk (if fresh (get-adc-decoded 1) 0.0))
        (var was-braking braking)
        (setq braking (or (> brk brake-level) (and (balancing) (< bal-current -5.0))))
        (if (and braking (not was-braking)) { ; fékezés kezdete: azonnal kialszik, utána villog
                (setq blink-on nil)
                (setq blink-time (systime))
        })

        (cond
            ((eq state 'detect) (detect-step thr))
            ((eq state 'release) (release-step thr))
            (t (run-step spd)))

        (button-step)
        (lights-step)
        (tc-step)

        ; 2-es profilban 50 Hz (a kipörgésgátlónak friss első sebesség és
        ; gyors első szorzó kell), egyébként 10 Hz
        (if (or (= profile 2) (> (secs-since t-front) 0.1)) {
                (setq t-front (systime))
                (send-front)
        })
        (if (> (secs-since t-slow) 0.5) {
                (setq t-slow (systime))
                ; Ha a VESC Tool-ban az App típusa vagy a Servo Output változik, a
                ; firmware újraindítja az appokat: az ADC lábakat analógra, a PPM
                ; lábat bemenetre állítja. Ezért a lábakat újra beállítjuk, a
                ; kimeneti szint közben nem változik.
                (gpio-configure 'pin-ppm 'pin-mode-out)
                (lamp-config)
                (gpio-configure button-pin 'pin-mode-in-pu)
                (refresh-gate)
                (update-temp-warn)
                (update-front-warn)
                ; az egyedi kijelző 1 s-onként jelentkezik; 5 s csend után gyárinak vesszük
                (if (and dash-custom (> (secs-since dash-ext-time) 5.0)) {
                        (setq dash-custom nil)
                        (setq dash-credit 0)
                })
        })
})

(defun control-loop ()
    (loopwhile t {
            ; egy váratlan hiba ne állítsa le a gombot és a lámpákat: kiírjuk és megyünk tovább
            (var res (trap (control-step)))
            (if (and (eq (car res) 'exit-error) (> (secs-since t-err) 1.0)) {
                    (setq t-err (systime))
                    (print (list 'hiba-control-step (cdr res)))
            })
            (sleep 0.02)
}))

; REPL-ből hívható: (status)
(defun status ()
    (print (list
            (list 'profil profile 'allapot state 'mod speedmode)
            (list 'km/h (speed-kmh) 'berugva kick-engaged 'gaz-fogva thr-gate)
            (list 'gaz-nyers thr-raw 'fek-nyers brk-raw 'keretek lever-frames)
            (list 'gaz (get-adc-decoded 0) 'fek (get-adc-decoded 1))
            (list 'gomb-lab (gpio-read button-pin) 'lenyomva btn-state 'nyomasok btn-presses)
            (list 'lampa light 'lampa-lab (gpio-read headlight-pin)
                'lampa-lab2 (if headlight-pin2 (gpio-read headlight-pin2) -1))
            (list 'elso-ack-s (secs-since front-ack-time) 'elso-flags front-ack-flags 'elso-hiba front-warn
                'elso-verzio front-version 'elso-regi front-old 'elso-vesc-hiba front-fault)
            (list 'tc tc-on 'tc-aktiv (tc-active) 'tc-elso tc-front
                'elso-km/h front-speed 'tc-ikon (tc-icon-on))
            (list 'balansz bal-state 'szog bal-angle 'oldal bal-roll 'cel bal-setpoint
                'aram bal-current 'imu bal-imu-ok 'imu-forras imu-source 'utolso-kilepes bal-reason
                'gaz-zar bal-thr-lock)
            (list 'kijelzo (if dash-custom 'egyedi 'gyari) 'fw dash-fw 'ble dash-ble
                'ble-mod dash-ble-mode 'kredit dash-credit 'alagut (tun-used) 'cmds cmds-started)
)))

(defun pin-label (p) ; a láb neve a konzolra, a csatlakozó felirata szerint
    (cond
        ((eq p 'pin-swclk) "SWCLK")
        ((eq p 'pin-swdio) "SWDIO")
        ((eq p 'pin-ppm) "PPM")
        (t (sym2str p))))

; Egy lámpa láb eredménye a (lampa-teszt) végén.
(defun lamp-verdict (pin hi ons lo offs)
    (str-merge (pin-label pin)
        (cond
            ((and (= hi ons) (= lo offs)) " rendben kapcsol")
            ((= hi 0) " bekapcsolva sem megy magasra")
            (t " bizonytalanul kapcsol"))))

; REPL-ből hívható: (lampa-teszt) - hatszor be- és kikapcsolja a lámpát (2 s-onként,
; bekapcsoláskor egy sípolás), és kiírja a lámpa lábak (headlight-pin, headlight-pin2)
; visszaolvasott szintjét, a végén pedig, mire lehet következtetni (README: "A lámpa
; nem működik"). A kijelző lámpája és ikonja is vele villog.
; A lámpát a vezérlőszál kapcsolja (legfeljebb 0,1 s), itt csak a lámpát állítjuk.
(defun lampa-teszt () {
        (var orig light)
        (var ons 0)    ; bekapcsolt lépések
        (var hi1 0)    ; ezek közül hányszor volt magas a láb (1 = headlight-pin, 2 = headlight-pin2)
        (var hi2 0)
        (var offs 0)
        (var lo1 0)
        (var lo2 0)
        (var two headlight-pin2)
        (print (str-merge "A lampa a hatso vezerlo labain van: " (pin-label headlight-pin)
                (if two (str-merge " es " (pin-label headlight-pin2)) "")
                ", mod " (sym2str headlight-mode)
                ". Kozben merd a lab es a GND kozott: BE kb. 3,3 V (od modban 5 V), KI 0 V."))
        (print "6x BE/KI 2 s-onkent, bekapcsolaskor egy sipolas. A kijelzo lampaja is vele villog.")
        (looprange i 0 12 {
                (setq light (not light))
                (if light (setq beep-count 1))
                (sleep 0.5)
                (var l1 (gpio-read headlight-pin))
                (var l2 (if two (gpio-read headlight-pin2) -1))
                (if light
                    {
                        (setq ons (+ ons 1))
                        (if (= l1 1) (setq hi1 (+ hi1 1)))
                        (if (= l2 1) (setq hi2 (+ hi2 1)))
                    }
                    {
                        (setq offs (+ offs 1))
                        (if (= l1 0) (setq lo1 (+ lo1 1)))
                        (if (= l2 0) (setq lo2 (+ lo2 1)))
                    })
                (print (str-merge "lampa " (if light "BE" "KI") " -> lab " (str-from-n l1 "%d")
                        (if two (str-merge ", masik lab " (str-from-n l2 "%d")) "")))
                (sleep 1.5)
        })
        (setq light orig)
        (print (str-merge "EREDMENY: " (lamp-verdict headlight-pin hi1 ons lo1 offs)
                (if two (str-merge ", " (lamp-verdict headlight-pin2 hi2 ons lo2 offs)) "")))
        ; (A 7.00-s olvasóban egy szöveg legfeljebb 256 karakter: a hosszabb
        ; betöltéskor read_error. Ezért több rövid sor.)
        (cond
            ((or (and (= hi1 ons) (= lo1 offs)) (and two (= hi2 ons) (= lo2 offs)))
                {
                    (print "-> A vezerlo oldala jo. Ha a lampa megsem villogott, merd a MOSFET gate es a GND kozott.")
                    (print "   Nincs fesz: a vezetek nem az SWCLK/SWDIO labon van (3,3 V, GND, NRST nem jo), vagy szakadt.")
                    (print "   Van fesz, megsem kapcsol: a MOSFET-nek 3,3 V keves (headlight-mode 'pin-mode-od + 1 kOhm 5 V-ra,")
                    (print "   vagy logikai szintu MOSFET), vagy a lampa tapjanak GND-je nincs a VESC GND-jen.")
                })
            ((eq headlight-mode 'pin-mode-od)
                (print "-> Nyitott drain modban egy 1 kOhm-os ellenallas kell a lab es az 5 V koze: ez hianyzik, vagy a gate-et GND-re huzo ellenallas tul kicsi."))
            ((= hi1 0)
                (print "-> Huzd le a lampa vezeteket es futtasd ujra: ha ugy jo, a MOSFET gate zarlatos, vagy tul kicsi ellenallas huzza GND-re."))
            (t (print "-> Laza erintkezes vagy tulterheles?")))
})

; REPL-ből hívható: (ikon-teszt) - 3 s-onként más értéket küld a kijelzőnek, a
; lépés száma a sebesség helyén látszik. Figyeld, melyik lépésnél gyullad ki a
; kipörgésgátló jelzésére választott ikon (-> tc-icon-field, tc-icon-bit) és a kijelző lámpája
; (-> dash-light-value). A lámpa mezőt lecseréli, a mód mezőhöz hozzáadja a bitet.
(defun ikon-teszt () {
        (var n 0)
        (print "Ikon teszt: 3 s-onkent uj ertek, a lepes szama a sebesseg helyen latszik.")
        (loopforeach c '((2 1) (2 2) (2 4) (2 8) (2 16) (2 32) (2 64) (2 128) (2 100) (2 255)
                         (0 8) (0 32) (0 64) (0 128)) {
                (setq n (+ n 1))
                (print (str-merge (str-from-n n "%d") ". lepes: "
                        (if (= (ix c 0) 2)
                            (str-merge "lampa mezo = " (str-from-n (ix c 1) "%d")
                                "  (TC jelzes: tc-icon-field 2, tc-icon-bit " (str-from-n (ix c 1) "%d")
                                "; lampa: dash-light-value " (str-from-n (ix c 1) "%d") ")")
                            (str-merge "mod mezo + " (str-from-n (ix c 1) "%d")
                                "  (tc-icon-field 0, tc-icon-bit " (str-from-n (ix c 1) "%d") ")"))))
                (setq dash-test-step n)
                (setq dash-test-or (= (ix c 0) 0))
                (setq dash-test-value (ix c 1))
                (setq dash-test-field (ix c 0))
                (sleep 3.0)
        })
        (setq dash-test-field -1)
        (setq dash-test-step -1)
        (print "Ikon teszt vege. A kiporgesgatlo jelzesere valasztott ikon lepesenek ertekeit ird a tc-icon-field / tc-icon-bit sorba, a lampaet a dash-light-value sorba.")
})

; REPL-ből hívható: (led-teszt) - egyedi kijelző-firmware kell. Egyesével kigyújtja a
; 48 LED-bitet (6 bájt x 8 bit) 1,5 s-onként, a többi LED ilyenkor nem ég. A konzol
; írja a bájtot és a bit értékét: így kideríthető, melyik bit melyik ikon
; (tc-seg-byte, tc-seg-bit).
(defun led-teszt () {
        (if (not dash-custom)
            (print "Ehhez az egyedi kijelzo-firmware kell (M365_Display_Costum_BLE).")
            {
                (print "LED teszt: 1,5 s-onkent egy LED, a konzol irja a bajtot es a bit erteket.")
                (looprange i 0 48 {
                        (print (str-merge (str-from-n (+ i 1) "%d") ". LED: bajt "
                                (str-from-n (/ i 8) "%d") ", bit ertek " (str-from-n (shl 1 (mod i 8)) "%d")))
                        (setq dash-seg-test i)
                        (sleep 1.5)
                })
                (setq dash-seg-test -1)
                (print "LED teszt vege. A valasztott LED adatait ird a tc-seg-byte / tc-seg-bit sorba.")
        })
})

; REPL-ből hívható: (szin-teszt) - "88" fehéren, pirosan, majd mindkét színnel
; (egyedi kijelző-firmware kell). A sebesség színe: speed-color.
(defun szin-teszt () {
        (if (not dash-custom)
            (print "Ehhez az egyedi kijelzo-firmware kell (M365_Display_Costum_BLE).")
            {
                (print "Szin teszt: 88 feheren, pirosan, majd mindket szinnel (3-3 s).")
                (dash-text "88" 0 30)
                (sleep 3.0)
                (dash-text "88" 1 30)
                (sleep 3.0)
                (dash-text "88" 2 30)
                (sleep 3.0)
                (dash-text "88" 0 0)
                (print "Szin teszt vege. A sebesseg szine: speed-color (0 feher, 1 piros, 2 mindketto).")
        })
})

(defun init () {
        (setq boot-time (systime))

        ; ADC app: a bemenetet mi adjuk, a kimenet a profil eldöntéséig tiltva
        (app-adc-detach 3 1)
        (app-disable-output -1)

        ; Előbb a kimeneti szint, utána a kimenet mód: a firmware (board.h) az SWD
        ; lábak kimeneti regiszterét induláskor 1-re állítja, így fordított
        ; sorrendben a lámpa egy pillanatra felvillanna.
        (gpio-write 'pin-ppm 1)                      ; féklámpa
        (gpio-configure 'pin-ppm 'pin-mode-out)
        (lamp-write (if light 1 0))                  ; első lámpa a hátsó vezérlő lábain
        (lamp-config)

        ; uart-read-bytes az olvasott bájtok után egy 0-t is ír, ezért +1 hely kell
        (def rx-one (bufcreate 2))
        (def rx-buf (bufcreate 260))         ; a leghosszabb keret: len 255 + 3 + lezáró 0
        (if ble-vesc-tool (setq tun-buf (bufcreate tun-size)))
        (def can-tx (bufcreate 8))
        (def tx-frame (bufcreate 14))
        (bufset-u16 tx-frame 0 0x55AA)
        (bufset-u8 tx-frame 2 0x08) ; len
        (bufset-u8 tx-frame 3 0x21) ; ESC -> kijelző
        (bufset-u8 tx-frame 4 0x64) ; cmd
        (bufset-u8 tx-frame 5 0x00) ; arg

        ; A kijelző kommunikáció a lehető leghamarabb indul, a beállítások előtt:
        ; ha azokban valami hibát dob, a kijelző akkor is választ kap.
        ; half-duplex módban csak a TX láb kell, az RX szabad: ezen van a gomb
        (uart-start 115200 'half-duplex)
        (gpio-configure button-pin 'pin-mode-in-pu)
        (spawn 200 rx-thread)
        (setq tc-time (systime))
})

; Indulás, 2. rész: beállítások és CAN.
(defun init-rest () {
        ; A VESC ADC app saját kipörgésgátlóját kikapcsoljuk (csak a RAM-ban), a
        ; script kipörgésgátlója helyettesíti; különben a 3x gombos kikapcsolás
        ; nem kapcsolná ki teljesen. Most még nincs kimenet, a beállítás biztonságos.
        ; A kiadott 7.00-s firmware ezt a paramétert nem ismeri: ott a VESC Tool-ban
        ; kell kikapcsolni (App Settings -> ADC -> Traction Control: False).
        (if (= (conf-try 'adc-tc 0) 1) {
                (conf-set-try 'adc-tc 0)
                (print "ADC app Traction Control kikapcsolva, a script kiporgesgatloja mukodik helyette")
        })
        (refresh-gate)
        (apply-mode) ; induláskor az 1-es profil korlátai élnek
        (event-register-handler (spawn can-event-loop))
        (event-enable 'event-can-sid)
        (spawn 200 balance-thread)
        ; VESC Tool a kijelző Bluetooth-án át: a VESC parancsfeldolgozója (kb. 3 KB)
        (if ble-vesc-tool {
                (setq cmds-started (eq (car (trap (cmds-start-stop t))) 'exit-ok))
                (if cmds-started
                    (event-enable 'event-cmds-data-tx)
                    (print "VESC Tool alagut: a cmds-start-stop nem indult (memoria?)"))
        })
})

; Indulás: mindkét rész védve, a hibát a konzol kiírja, és a vezérlés akkor is
; elindul (a kijelző, a gomb és a lámpák működjenek).
(defun boot () {
        (var r (trap (init)))
        (if (eq (car r) 'exit-error) (print (list 'hiba-init (ix r 1))))
        (setq r (trap (init-rest)))
        (if (eq (car r) 'exit-error) (print (list 'hiba-init-rest (ix r 1))))
})

(defun main () {
        (boot)
        (control-loop)
})

@const-end

; A LispBM 7.00 a looprange, loopwhile, loopforeach makrót és a str-merge, abs
; függvényt az első használatkor szövegből tölti be, és az ehhez kellő új neveket
; (pl. "it", "start") a flash-képbe írja. Ha ez csak futás közben, az image-save
; után történik, a képbe mentett írási mutató elavul, és egy újraindítás után a
; következő ilyen betöltés "Attempted to write to const heap ... already occupied"
; + read_error hibával leállítja az éppen futó szálat (első vezérlő, (lampa-teszt),
; 2026-11-25). Ezért itt, az image-save előtt mindet betöltjük: így a képbe
; kerülnek, és futás közben nincs flash-írás.
(looprange i 0 1 nil)
(loopwhile nil nil)
(loopforeach x nil nil)
(str-merge "")
(abs 0)

(image-save)
(main)
