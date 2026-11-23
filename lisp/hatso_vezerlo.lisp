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
;      1x nyomás = lámpa: a kijelző saját lámpája + az első vezérlő PPM lábán
;                  lévő külső lámpa (MOSFET)
;      2x nyomás = módváltás  D -> S -> ECO -> D
;      3x nyomás = kipörgésgátló be/ki (csak 2-es profilban), 3 sípolás
;  - PPM láb: féklámpa MOSFET. Alapból folyamatosan világít, fékezéskor villog.
;  - Kijelzőn: sebesség, akku töltöttség, mód (ECO/D/S), hőfok ikon, hibakód.
;  - 1-es profil (alapértelmezett, "rendőr mód"): csak a hátsó motor megy,
;    3 km/h-s berúgás kell az induláshoz.
;  - 2-es profil: bekapcsoláskor nyomva tartott gázkarral. Mindkét motor megy,
;    nincs berúgás, álló helyzetben a kijelző az akku %-ot mutatja.
;    Kipörgésgátló: ha az egyik kerék a megengedettnél gyorsabban forog, mint
;    a másik, annak a hajtását csökkenti (induláskor bekapcsolva, 3x gomb).
;  - Advanced Balance (csak 2-es profilban, KÍSÉRLETI): be/ki a fék behúzása
;    közben 2x gombnyomással, induláskor mindig ki van kapcsolva, bekapcsolva a
;    lakat ikon világít. Két keréken a roller teljesen normál. Ha az eleje
;    felemelkedik, a gáz továbbra is a nyomatékot adja, de egy szögfigyelő
;    szabályzó elveszi a gázt, vagy fékez is, hogy a roller ne lépje át a
;    beállított célszöget. Az első kerék egy laza AB-kipörgésgátlóval nagyjából
;    együtt forog a hátsóval (ez a 3x gombos kipörgésgátlótól függetlenül
;    mindig működik). Lekapcsol: 60° oldalra vagy 60° hátra dőlésnél.
;    Célszög mentése: álló helyzetben fék + 5x gomb -> a pillanatnyi szög lesz
;    a célszög (EEPROM, újraindítás után is megmarad).
;    A szöget alapból az első vezérlőre kötött BNO085 IMU adja (CAN-en).
;  - Hibakódok a kijelzőn (gyári Xiaomi kódok, ahol van megfelelő): 14 gázkar,
;    15 fékkar, 16 mindkét kar hibás; a VESC hibái átfordítva; táblázat: README.
;  - Lisp konzol: (status), (hibak), (gomb-teszt), (lampa-teszt), (tc-teszt),
;    (szog), (ikon-teszt), (celszog-torles)
;
; Bekötés (COMM port):
;   kijelző piros  -> 5V        kijelző fekete -> GND
;   kijelző sárga  -> TX (half-duplex adatvonal)
;   kijelző zöld (gomb) -> RX + 470 Ohm felhúzó ellenállás 3.3V-ra
;   PPM jel -> féklámpa MOSFET gate
;   ADC1, ADC2 -> szabad (10 kOhm-mal GND-re ajánlott)
;   Első lámpa: az ELSŐ vezérlő PPM lábán (MOSFET gate), CAN-en kapcsolva
;   (headlight-on-front). nil esetén a hátsó vezérlő headlight-pin lábán.
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
(def light-default nil)       ; első lámpa induláskor: t = be, nil = ki
(def headlight-on-front t)    ; t = a lámpa MOSFET az első vezérlő PPM lábán (CAN-en kapcsolva),
                              ; nil = a hátsó vezérlő headlight-pin lábán
(def headlight-pin 'pin-adc2) ; ha headlight-on-front nil: a hátsó vezérlő lámpa lába. Az ADC2
                              ; sok lapon a védőellenállások miatt nem tud MOSFET-et kapcsolni;
                              ; 'pin-swdio / 'pin-swclk: az SWD csatlakozó, közvetlen MCU láb
                              ; (utána az SWD programozó újraindításig nem működik)
(def dash-light-value 100)    ; a kijelzőnek küldött lámpa érték bekapcsolt lámpánál.
                              ; 100 (0x64) = mint a gyári vezérlő: a 6-os bit kapcsolja a
                              ; kijelző saját lámpáját. 1 = csak az ikon világít.

; Kipörgésgátló (csak 2-es profilban). Az első és a hátsó kerék sebességét
; hasonlítja össze. Ha az egyik tc-slip-nél többel gyorsabban forog, a hajtását
; tc-range alatt lineárisan 0-ig csökkenti. 3 gyors gombnyomás: be/ki.
(def tc-default t)            ; induláskor bekapcsolva
(def tc-slip 2.0)             ; km/h - engedélyezett sebességkülönbség (eddig nem szól bele)
(def tc-range 3.0)            ; km/h - e fölött ennyi további különbségnél a hajtás 0
(def tc-recover 0.3)          ; s - a csúszás után ennyi idő alatt jön vissza a teljes hajtás

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

; Advanced Balance - csak 2-es profilban. KÍSÉRLETI!
; Be/ki: fékkar behúzva + 2x gombnyomás. Induláskor mindig ki van kapcsolva.
; Az alapértékek egy egyszerű modellből becsültek (tools/balansz_modell.py),
; a rolleredre hangolni kell (README: "Advanced Balance").
; A szög: fok, az eleje emelésekor nő, vízszintes rollernél 0 (ld. (szog)).
; IMU: 'bno085 = az első vezérlő COMM portjára kötött BNO085 (az elso_vezerlo.lisp
; olvassa és CAN-en küldi), 'vesc = a VESC belső IMU-ja.
(def imu-source 'bno085)
(def imu-sid 0x4D2)               ; az első vezérlő BNO085 üzenete (elso_vezerlo.lisp imu-sid)
(def imu-period 0.01)             ; s - a BNO085 mintavétele (az első script bno-interval-ms-e)
(def balance-axis 1)              ; IMU tengely a get-imu-rpy listából: 0 = roll, 1 = pitch
(def balance-invert nil)          ; t, ha az eleje emelésekor a nyers szög csökken
(def balance-level-offset 0.0)    ; fok - ennyit mutat a nyers szög vízszintes rollernél
(def ab-target-angle 20.0)        ; fok - CÉLSZÖG: az elejét e fölé nem engedi
                                  ;   (a balanszpontnál ne legyen nagyobb, és jóval nagyobb
                                  ;   legyen a legmeredekebb emelkedőnél, amin jársz).
                                  ;   Ha fék + 5x gombbal elmentettél egy szöget, induláskor
                                  ;   az EEPROM-ból töltődik, és felülírja ezt az értéket.
(def ab-target-min 5.0)           ; fok - menteni csak e két érték közötti szöget lehet
(def ab-target-max 45.0)
(def ab-target-eeprom 10)         ; EEPROM cím (0-127) a mentett célszögnek
(def ab-save-max-speed 1.0)       ; km/h - menteni csak álló helyzetben lehet
(def ab-save-show-time 2.0)       ; s - mentés után a kijelző ennyi ideig a szöget mutatja
(def ab-engage-angle 3.0)         ; fok - ez alatt (két keréken) a szabályzó nem szól bele
(def ab-kp 10.0)                  ; A / fok - arányos tag
(def ab-kd 1.5)                   ; A / (fok/s) - differenciáló tag (a gyors emelkedést előre fékezi)
(def ab-slew 1000.0)              ; A/s - a hátsó áram legnagyobb változási sebessége
(def ab-max-reverse 3.0)          ; km/h - a szögkorlát eddig tolathat hátra, ennél gyorsabban nem
(def ab-cutoff-roll 60.0)         ; fok - ennyi oldalra dőlésnél lekapcsol
(def ab-cutoff-pitch 60.0)        ; fok - ennyi hátradőlésnél lekapcsol
(def ab-toggle-brake 0.5)         ; a be/ki kapcsoláshoz a fékkar legalább ennyire (0-1) legyen behúzva
(def ab-throttle-exp 0.0)         ; gázgörbe AB módban (a VESC Tool görbéje helyett), 0 = lineáris
(def ab-brake-exp 0.0)            ; fékgörbe AB módban, 0 = lineáris
(def ab-curve-mode 0)             ; görbe típusa: 0 = exponenciális, 1 = természetes, 2 = polinom
; AB-kipörgésgátló: laza szinkron az első és a hátsó kerék között, csak AB
; módban. A 3x gombos (általános) kipörgésgátlótól független, külön hangolható,
; és akkor is működik, ha azt kikapcsolod: a levegőben pörgő első kerék ne
; pörögjön túl. AB módban mindkettő hat (a szorzóik összeszorzódnak).
; Az első kerék sebessége az első vezérlő visszajelzéséből jön (régi első
; scriptnél a canget-speed-ből, a hátsó kerékadataival).
(def ab-tc-enabled t)
(def ab-tc-slip 3.0)              ; km/h - eddig a sebességkülönbségig nem szól bele
(def ab-tc-range 5.0)             ; km/h - a csúszás fölött ennyivel a gyorsabb kerék hajtása 0
(def ab-tc-filter 0.2)            ; 0-1 - simítás (kisebb = lazább, lassabb)
(def front-can-id -1)             ; az első vezérlő CAN ID-je, -1 = automatikus (az első talált)
; AB jelzés a kijelzőn: alapból a LAKAT ikon (a mód bájt 32-es bitje, LOCK).
; Ha a kijelződön mással gyullad ki, keresd meg az (ikon-teszt) paranccsal.
(def ab-icon-mode 'bit)           ; 'bit = egy bit egy mezőben, nil = nincs jelzés
(def ab-icon-field 0)             ; 0 = mód, 2 = lámpa, 3 = sípolás mező
(def ab-icon-bit 32)              ; a mód bájtban: 32 = lakat (LOCK)

; Hibakódok (táblázat: README "Hibakódok")
(def lever-raw-min 16)            ; a kar nyers jele (0-255) ez alatt hibás: szakadás, nincs táp
(def lever-raw-max 235)           ; e fölött hibás: zárlat a tápra
(def lever-fault-time 0.3)        ; s - ennyi ideig tartó hibás jel = kar hiba (14/15/16)
(def lever-ok-time 1.0)           ; s - ennyi ideig tartó jó jel után szűnik meg
(def error-hold-time 3.0)         ; s - egy hiba legalább ennyi ideig látszik a kijelzőn

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
(def bal-angle 0.0)            ; IMU szög (fok), az eleje emelésekor nő
(def bal-roll 0.0)
(def bal-imu-ok nil)
(def bal-prev-angle 0.0)
(def bal-rate 0.0)             ; szögsebesség (fok/s), szűrt
(def ab-on nil)                ; Advanced Balance - induláskor mindig ki
(def ab-toggle-req nil)        ; a gomb kérése, az AB szál hajtja végre
(def ab-last-time 0)
(def ab-pwr 0.0)               ; rámpázott gáz-fék (-1..1), mint az ADC appban
(def ab-cur 0.0)               ; a hátsó motor áramparancsa (A)
(def ab-lim 1000.0)            ; a szögkorlát (A), diagnosztika
(def ab-imax 30.0)             ; a hátsó motor aktuális max árama (A)
(def ab-ramp-pos 0.3)
(def ab-ramp-neg 0.1)
(def ab-hyst 0.15)
(def ab-front-id -1)
(def ab-tc-front 1.0)          ; kipörgésgátló szorzók (1 = nincs beavatkozás)
(def ab-tc-rear 1.0)
(def ab-thr-lock nil)          ; lekapcsolás után a gáz a felengedéséig fogva marad
(def ab-reason 'nincs)         ; az utolsó lekapcsolás oka
(def t-ab-err 0)
(def icon-test-field -1)       ; (ikon-teszt) alatt: melyik mezőt kapcsolja
(def icon-test-value 0)
(def thr-fault nil)            ; gázkar jele hibás
(def brk-fault nil)            ; fékkar jele hibás
(def thr-bad-start 0)
(def thr-ok-start 0)
(def brk-bad-start 0)
(def brk-ok-start 0)
(def front-fault 0)            ; az első vezérlő VESC hibakódja (a visszajelzésből)
(def ab-cut-time nil)          ; az utolsó AB lekapcsolás ideje (borulás, IMU), nil = még nem volt
(def script-err-time nil)      ; az utolsó script hiba ideje, nil = még nem volt
(def err-shown 0)              ; a kijelzőn látszó hibakód
(def err-time 0)               ; mikor volt utoljára aktív
(def err-last 0)               ; az előző aktív kód (új hiba felismeréséhez)
(def err-history nil)          ; az utolsó 8 hiba: ((kód mp) ...)
(def ab-save-req nil)          ; fék + 5x: célszög mentés kérése (az AB szál hajtja végre)
(def ab-save-fail-time nil)    ; az utolsó sikertelen mentés ideje (61-es esemény)
(def ab-imu-fail-time nil)     ; AB indítás IMU adat nélkül (62-es esemény)
(def ab-show-time nil)         ; mentés után a kijelző a szöget mutatja
(def ab-show-value 0)
(def ab-target-source 'kod)    ; honnan jön a célszög: 'kod vagy 'eeprom
(def imu-roll 0.0)             ; BNO085 (első vezérlő): fok
(def imu-pitch 0.0)
(def imu-rate 0.0)             ; fok/s a balance-axis tengelyen, a mintákból
(def imu-cnt -1)               ; az utolsó minta sorszáma
(def imu-time 0)
(def bal-imu-rate 0.0)
(def last-beep 0)
(def front-version 0)          ; az első script verziója (a visszajelzésből), 0 = még nincs
(def front-old nil)            ; t = az első script régebbi, mint front-min-version
(def front-lamp nil)           ; az első vezérlő szerint a lámpa parancs
(def front-pin -1)             ; a lámpa láb visszaolvasott szintje az első vezérlőn
(def front-speed 0.0)          ; km/h, előjeles, az első vezérlő saját kerékadataival
(def front-speed-time 0)
(def tc-on tc-default)         ; kipörgésgátló be/ki (3x gomb)
(def tc-front 1.0)             ; kipörgésgátló szorzók (1 = nincs beavatkozás)
(def tc-rear 1.0)
(def tc-time 0)
(def rear-scale -1.0)          ; a hátsón utoljára beállított áram-szorzó

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
(defun conf-try (name dflt) {
        (var r (trap (conf-get name)))
        (if (eq (car r) 'exit-ok) (ix r 1) dflt)
})

(defun conf-set-try (name val) ; t, ha sikerült
    (eq (car (trap (conf-set name val))) 'exit-ok))

(defun mode-limits (prof mode)
    (if (= prof 2)
        (cond ((= mode 2) p2-eco) ((= mode 4) p2-sport) (t p2-drive))
        (cond ((= mode 2) p1-eco) ((= mode 4) p1-sport) (t p1-drive)) ; 0 = még nincs profil -> 1-es
))

(defun brake-held () (and (>= brk-lvl ab-toggle-brake) (not brk-fault)))

(defun front-flags () ; bit0 = hajtás, bit1 = fék
    (if (= profile 2) 3 (if p1-front-brake 2 0))
)

; -> Módok és az első vezérlő

; A hátsó áram-szorzó: a mód szorzója x a kipörgésgátló szorzója. Ez a VESC
; "instant" konfigurációs útja (nem indítja újra az ADC app-ot), és csak
; változáskor írjuk. AB módban a script maga szorozza az áramot (ab-drive),
; ott a szorzó a mód szerinti marad.
(defun apply-scale () {
        (var s (/ (round (* 100.0 (ix (mode-limits profile speedmode) 2)
                        (if ab-on 1.0 tc-rear))) 100.0))
        (if (not (= s rear-scale)) {
                (conf-set 'l-current-max-scale s)
                (setq rear-scale s)
        })
})

(defun apply-mode-limits () {
        (var lim (mode-limits profile speedmode))
        (conf-set 'max-speed (/ (ix lim 0) 3.6))
        (conf-set 'l-watt-max (ix lim 1))
        (setq rear-scale -1.0) ; mindenképp újraírjuk
        (apply-scale)
})

(defun apply-mode () {
        (apply-mode-limits)
        (send-front)
})

; 8 bájt: A5, flags, áram %, km/h*10 (u16), watt/100 (u16), profil
; flags: bit0 = hajtás, bit1 = fék, bit2 = első lámpa
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
            (bufset-u8 can-tx 1 (+ flags (if (and headlight-on-front light) 4 0))) ; bit2 = első lámpa
            (bufset-u8 can-tx 2 (to-i (round (* 100.0 (ix lim 2) tc-front))))
            (bufset-u16 can-tx 3 (to-i (round (* 10.0 (ix lim 0)))))
            (bufset-u16 can-tx 5 (to-i (round (/ (ix lim 1) 100.0))))
            (bufset-u8 can-tx 7 profile)
            (can-send-sid front-cmd-sid can-tx)
}))

; Visszajelzés: A5, flags, áram %, VESC hibakód, állapot (bit0 = lámpa,
; bit2 = a lámpa láb szintje), verzió, sebesség (0,1 km/h, i16). A régi
; (1-es verziójú) első script csak 3-4 bájtot küld.
(defun on-front-ack (id data)
    (if (and (= id front-ack-sid) (>= (buflen data) 3) (= (bufget-u8 data 0) 0xA5)) {
            (setq front-ack-time (systime))
            (setq front-ack-flags (bufget-u8 data 1))
            (if (>= (buflen data) 8)
                {
                    (var st (bufget-u8 data 4))
                    (setq front-fault (bufget-u8 data 3))
                    (setq front-lamp (= (bitwise-and st 1) 1))
                    (setq front-pin (if (= (bitwise-and st 4) 4) 1 0))
                    (setq front-version (bufget-u8 data 5))
                    (setq front-speed (/ (bufget-i16 data 6) 10.0))
                    (setq front-speed-time (systime))
                }
                { ; régi (1-es) első script: 3-4 bájt, a 4. a hibakód
                    (setq front-version 1)
                    (setq front-fault (if (>= (buflen data) 4) (bufget-u8 data 3) 0))
                })
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

(defun can-event-loop ()
    (loopwhile t
        (recv
            ((event-can-sid . ((? id) . (? data)))
                (if (= id imu-sid) (on-imu-frame data) (on-front-ack id data)))
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

; -> Kipörgésgátló (csak 2-es profilban)
; A hátsó kerék sebessége helyben, az elsőé a visszajelzésből jön (az első
; vezérlő saját kerékadataival számolva, 50 Hz-en). A csökkentés a VESC
; áram-szorzóján át hat az ADC app kimenetére: a VESC Tool beállításai
; (görbe, rámpa) maradnak. Csökkenés azonnal, visszaállás tc-recover alatt.

(defun tc-factor (excess) ; a gyorsabb kerék hajtásának szorzója (0-1)
    (clamp (- 1.0 (/ (- excess tc-slip) tc-range)) 0.0 1.0)
)

(defun tc-active ()
    (and tc-on (= profile 2) (eq state 'run) front-enabled
        (< (secs-since front-speed-time) 0.2))
)

(defun tc-follow (cur k dt)
    (if (< k cur) k (min2 k (+ cur (if (> tc-recover 0.01) (/ dt tc-recover) 1.0))))
)

(defun tc-step () {
        (var dt (clamp (secs-since tc-time) 0.0 0.1))
        (setq tc-time (systime))
        (var kf 1.0)
        (var kr 1.0)
        (if (tc-active) {
                (var rear (* (get-speed) 3.6))
                (var d (- front-speed rear))          ; + = az első forog gyorsabban
                (if (< rear 0.0) (setq d (- 0.0 d)))  ; hátrafelé gurulva fordítva
                (setq kf (tc-factor d))
                (setq kr (tc-factor (- 0.0 d)))
        })
        (setq tc-front (tc-follow tc-front kf dt))
        (setq tc-rear (tc-follow tc-rear kr dt))
        (apply-scale)
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
                        " km/h  ->  elso x" (str-from-n tc-front "%.2f")
                        "  hatso x" (str-from-n tc-rear "%.2f")))
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
        (update-lever-faults)
        (if (or thr-fault brk-fault)
            {
                ; Hibás kar: nincs gáz (mint a gyári 14/15/16), hibás féknél
                ; elektromos fék sem; a gáz a hiba után a felengedéséig fogva.
                (setq ab-thr-lock t)
                (setq thr-v thr-gate-v)
                (if brk-fault (setq brk-v 0.0))
            }
            (if thr-gate
                (setq thr-v
                    (if thr-gate-inv
                        (if (> thr-v thr-gate-v) thr-v thr-gate-v)
                        (if (< thr-v thr-gate-v) thr-v thr-gate-v)))))
        ; Csak friss keretre írjuk felül: ha a kijelző elhallgat, a VESC
        ; timeout leállítja a motort.
        (app-adc-override 0 thr-v)
        (app-adc-override 1 brk-v)
})

(defun send-dash () {
        (var spd (speed-kmh))
        (var batt (to-i (clamp (* (get-batt) 100.0) 0.0 100.0)))
        (var shown (cond
                ((and ab-show-time (< (secs-since ab-show-time) ab-save-show-time)) ab-show-value)
                ((and (= profile 2) (< spd p2-idle-speed)) batt)
                (t (to-i (+ spd 0.5)))))
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
        (bufset-u8 tx-frame 11 err-shown) ; hibakód (update-error, táblázat: README)
        (if (and ab-on (eq ab-icon-mode 'bit)) ; AB: lakat ikon
            (bufset-u8 tx-frame (+ 6 ab-icon-field)
                (bitwise-or (bufget-u8 tx-frame (+ 6 ab-icon-field)) ab-icon-bit)))
        (if (>= icon-test-field 0) ; (ikon-teszt)
            (bufset-u8 tx-frame (+ 6 icon-test-field)
                (if (= icon-test-field 5) icon-test-value
                    (bitwise-or (bufget-u8 tx-frame (+ 6 icon-test-field)) icon-test-value))))
        (var sum 0)
        (looprange i 2 12 (setq sum (+ sum (bufget-u8 tx-frame i))))
        (var crc (bitwise-xor sum 0xFFFF))
        (bufset-u8 tx-frame 12 (bitwise-and crc 0xFF))
        (bufset-u8 tx-frame 13 (bitwise-and (shr crc 8) 0xFF))
        (uart-write tx-frame)
        (setq last-dash-tx (systime))
})

(defun process-frame (len) {
        (var addr (bufget-u8 rx-buf 0))
        (var cmd (bufget-u8 rx-buf 1))
        (if (not (= addr 0x21)) { ; 0x21 = ESC -> kijelző, a saját keretünk
                ; gáz/fék a 0x64 és 0x65 keretben a 4-5. bájton, app olvasásnál (0x61) eggyel arrébb
                (cond
                    ((and (or (= cmd 0x64) (= cmd 0x65)) (>= len 5)) (lever-input 4))
                    ((and (= cmd 0x61) (>= len 6)) (lever-input 5))
                )
                (if (= cmd 0x64) (setq last-0x64-time (systime)))
                ; A gyári vezérlő a 0x64-re válaszol. Ha nem jön 0x64, a 0x65-re válaszolunk.
                (if (and (> (secs-since last-dash-tx) 0.04)
                        (or (= cmd 0x64)
                            (and (= cmd 0x65) (> (secs-since last-0x64-time) 0.5))))
                    (send-dash))
        })
})

(defun read-frame () {
        (var len (read-u8))
        (if (and (>= len 2) (<= len 58)) {
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
                (send-front) ; az első vezérlő azonnal kapcsolja a lámpát
                (button-log-msg (if light "1x -> lampa BE" "1x -> lampa KI"))
        })
        ((and (= clicks 2) (brake-held)) { ; behúzott fékkel 2x: Advanced Balance be/ki
                (button-log-msg (if ab-on "fek + 2x -> AB KI" "fek + 2x -> AB BE"))
                (setq ab-toggle-req t) ; az AB szál kapcsol, hogy a motorparancsok ne keveredjenek
        })
        ((= clicks 2) { ; D -> S -> ECO -> D
                (setq speedmode (cond ((= speedmode 1) 4) ((= speedmode 4) 2) (t 1)))
                (apply-mode)
                (setq beep-count 1)
                (button-log-msg (str-merge "2x -> mod "
                        (cond ((= speedmode 2) "ECO") ((= speedmode 4) "S") (t "D"))))
        })
        ((= clicks 3) (tc-toggle))
        ((and (= clicks 5) (brake-held)) { ; behúzott fékkel 5x: a célszög mentése
                (button-log-msg "fek + 5x -> celszog mentese")
                (setq ab-save-req t) ; az AB szál menti (ott olvassa az IMU-t)
        })
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

(defun lights-step () {
        (if braking
            (if (> (secs-since blink-time) brake-blink-half) {
                    (setq blink-on (not blink-on))
                    (setq blink-time (systime))
            })
            (setq blink-on t)) ; nem fékez: folyamatosan világít
        (gpio-write 'pin-ppm (if blink-on 1 0))
        (if (not headlight-on-front) (gpio-write headlight-pin (if light 1 0)))
})

; -> Advanced Balance (csak 2-es profilban)
; Bekapcsolva a script vezérli mindkét motort 100 Hz-en (az ADC app kimenete
; tiltva). A gáz és a fék ugyanúgy jut a motorokhoz, mint az ADC appban
; (kalibráció, holtjáték, görbe, rámpa), de a hátsó motor áramát a szögkorlát
; felülről korlátozza: min(gáz, korlát). A korlát a célszög alatt nagy, a
; célszög körül 0-ra csökken, fölötte negatív (fékez). Két keréken (a szög az
; ab-engage-angle alatt) nem szól bele. A fék mindig a normál fék.

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

(defun update-rate (dt) {
        (var raw-rate (if (eq imu-source 'bno085) bal-imu-rate (/ (- bal-angle bal-prev-angle) dt)))
        (setq bal-rate (+ bal-rate (* 0.3 (- raw-rate bal-rate))))
        (setq bal-prev-angle bal-angle)
})

(defun ab-refresh () ; 0,5 s-onként: a VESC Tool beállításai és az első vezérlő ID-je
    {
        ; a mód szorzójából, nem a konfigurációból: azt a kipörgésgátló csökkentheti
        (setq ab-imax (* (conf-get 'l-current-max) (ix (mode-limits profile speedmode) 2)))
        (setq ab-ramp-pos (conf-get 'adc-ramp-time-pos))
        (setq ab-ramp-neg (conf-get 'adc-ramp-time-neg))
        (setq ab-hyst (conf-get 'adc-thr-hyst))
        (setq ab-front-id
            (cond
                ((not front-enabled) -1)
                ((>= front-can-id 0) front-can-id)
                (t {
                        (var devs (can-list-devs))
                        (if devs (car devs) -1)
                    })))
})

(defun ab-deadband (x h) ; mint a VESC utils_deadband
    (cond
        ((< (abs x) h) 0.0)
        ((> x 0.0) (/ (- x h) (- 1.0 h)))
        (t (/ (+ x h) (- 1.0 h))))
)

(defun ab-target-pwr () ; gáz - fék, a VESC Tool kalibrációja, holtjáték és görbe után
    (if (< (secs-since last-lever-time) 0.3)
        (throttle-curve (ab-deadband (- (get-adc-decoded 0) (get-adc-decoded 1)) ab-hyst)
            ab-throttle-exp ab-brake-exp ab-curve-mode)
        0.0) ; nincs kijelzőkeret: se gáz, se fék
)

(defun ab-tc-factor (excess) ; a gyorsabb kerék hajtásának szorzója
    (clamp (- 1.0 (/ (- excess ab-tc-slip) ab-tc-range)) 0.0 1.0)
)

(defun ab-traction () {
        (var kf 1.0)
        (var kr 1.0)
        (if (and ab-tc-enabled (>= ab-front-id 0)) {
                (var fs (if (< (secs-since front-speed-time) 0.2)
                        front-speed
                        (* 3.6 (canget-speed ab-front-id))))
                (var d (- fs (* 3.6 (get-speed)))) ; + = az első gyorsabb
                (setq kf (ab-tc-factor d))
                (setq kr (ab-tc-factor (- 0.0 d)))
        })
        (setq ab-tc-front (+ ab-tc-front (* ab-tc-filter (- kf ab-tc-front))))
        (setq ab-tc-rear (+ ab-tc-rear (* ab-tc-filter (- kr ab-tc-rear))))
})

(defun ab-limit () ; a hátsó motor legnagyobb árama a szög alapján (A)
    (if (> bal-angle ab-engage-angle)
        {
            (var lim (- (* ab-kp (- ab-target-angle bal-angle)) (* ab-kd bal-rate)))
            ; hátrafelé csak ab-max-reverse km/h-ig fékezhet/tolathat
            (if (and (< lim 0.0) (< (* (get-speed) 3.6) (- 0.0 ab-max-reverse))) 0.0 lim)
        }
        1000.0)
)

(defun ab-drive (dt) {
        (var target (ab-target-pwr))
        ; rámpa, mint az ADC appban: növekvő erőnél ramp-pos, csökkenőnél ramp-neg
        (var rt (if (> (abs target) (abs ab-pwr)) ab-ramp-pos ab-ramp-neg))
        (if (> rt 0.01)
            (setq ab-pwr (+ ab-pwr (clamp (- target ab-pwr) (- 0.0 (/ dt rt)) (/ dt rt))))
            (setq ab-pwr target))
        (ab-traction)
        (setq ab-lim (ab-limit))
        (if (>= ab-pwr 0.0)
            { ; gáz: a hátsót a szögkorlát felülről korlátozza (akár fékezésig)
                ; Kipörgésgátlók: az AB-é mindig, az általános (3x gomb) a hátsón csak két
                ; keréken (felemelt elejénél az első kerék nem viszonyítási alap). Az
                ; általános első szorzót az első vezérlő áram-szorzója már tartalmazza.
                (var kr (* ab-tc-rear (if (> bal-angle ab-engage-angle) 1.0 tc-rear)))
                (var want (min2 (* ab-pwr ab-imax kr) ab-lim))
                (var step (* ab-slew dt))
                (setq ab-cur (+ ab-cur (clamp (- want ab-cur) (- 0.0 step) step)))
                (set-current ab-cur 0.05)
                (if (>= ab-front-id 0) (canset-current-rel ab-front-id (* ab-pwr ab-tc-front) 0.05))
            }
            { ; fék: normál fék mindkét motoron
                (var b (- 0.0 ab-pwr))
                (setq ab-cur (* ab-pwr ab-imax)) ; csak kijelzéshez / féklámpához
                (set-brake-rel b)
                (if (>= ab-front-id 0) (canset-brake-rel ab-front-id b))
            })
})

(defun ab-start () {
        (ab-refresh)
        (setq ab-pwr (ab-target-pwr)) ; rámpa nélkül vesszük át: a fék nem gyengül
        (setq ab-cur 0.0)
        (setq ab-tc-front 1.0)
        (setq ab-tc-rear 1.0)
        (setq bal-prev-angle bal-angle)
        (setq bal-rate 0.0)
        (setq ab-last-time (systime))
        (setq ab-on t)
        (app-disable-output -1) ; mostantól a script vezérli mindkét motort
        (setq beep-count 2)
        (print (list 'advanced-balance-be 'celszog ab-target-angle 'elso-id ab-front-id))
})

(defun ab-stop (reason) {
        (setq ab-on nil)
        (setq ab-reason reason)
        (if (not (eq reason 'kikapcsolva)) (setq ab-cut-time (systime)))
        (set-current 0.0)
        (if (>= ab-front-id 0) (canset-current ab-front-id 0.0))
        (setq ab-cur 0.0)
        (setq ab-lim 1000.0)
        (if (> thr-lvl 0.05) { ; a gáz a felengedéséig fogva marad
                (setq ab-thr-lock t)
                (setq thr-gate t)
        })
        (app-disable-output 0) ; vissza az ADC app-ra
        (setq beep-count (if (eq reason 'kikapcsolva) 1 3))
        (print (list 'advanced-balance-ki reason))
})

(defun ab-toggle () ; fékkar behúzva + 2x gombnyomás
    (cond
        (ab-on (ab-stop 'kikapcsolva))
        ((not (= profile 2)) {
                (setq beep-count 3)
                (button-log-msg "AB csak 2-es profilban")
        })
        ((not (eq state 'run)) (setq beep-count 3))
        ((not bal-imu-ok) {
                (setq beep-count 3)
                (setq ab-imu-fail-time (systime))
                (button-log-msg "AB: nincs IMU adat")
        })
        (t (ab-start)))
)

(defun ab-step () {
        (read-imu)
        (var dt (clamp (secs-since ab-last-time) 0.001 0.05))
        (setq ab-last-time (systime))
        (update-rate dt)
        (cond
            ((> (abs bal-roll) ab-cutoff-roll) (ab-stop 'oldaldoles))
            ((> bal-angle ab-cutoff-pitch) (ab-stop 'hatradoles))
            ((< bal-angle (- 0.0 ab-cutoff-pitch)) (ab-stop 'eloredoles))
            ((not bal-imu-ok) (ab-stop 'imu))
            (t (ab-drive dt)))
})

; Fék + 5x gomb álló helyzetben: a pillanatnyi szög lesz a célszög, és az
; EEPROM-ba is mentjük (induláskor onnan töltődik). Siker: 5 sípolás, és a
; kijelző ab-save-show-time ideig a szöget mutatja. Hiba: 61-es kód.
(defun ab-save-angle () {
        (read-imu)
        (var a bal-angle)
        (var why (cond
                ((not bal-imu-ok) "nincs IMU adat")
                ((> (speed-kmh) ab-save-max-speed) "nem all a roller")
                ((not (brake-held)) "a fek nincs behuzva")
                ((< a ab-target-min) "tul kicsi szog")
                ((> a ab-target-max) "tul nagy szog")
                (t nil)))
        (if why
            {
                (setq ab-save-fail-time (systime))
                (print (str-merge "Celszog mentes SIKERTELEN: " why
                        " (szog " (str-from-n a "%.1f") ")"))
            }
            {
                (eeprom-store-f ab-target-eeprom a)
                (setq ab-target-angle a)
                (setq ab-target-source 'eeprom)
                (setq ab-show-value (to-i (+ a 0.5)))
                (setq ab-show-time (systime))
                (setq beep-count 5)
                (print (str-merge "Celszog elmentve: " (str-from-n a "%.1f") " fok"))
            })
})

; induláskor: a mentett célszög betöltése, ha van és érvényes
(defun load-target-angle () {
        (var a (eeprom-read-f ab-target-eeprom))
        (if (and a (>= a ab-target-min) (<= a ab-target-max))
            {
                (setq ab-target-angle a)
                (setq ab-target-source 'eeprom)
                (print (str-merge "Celszog az EEPROM-bol: " (str-from-n a "%.1f") " fok"))
            }
            (setq ab-target-source 'kod))
})

; REPL-ből hívható: (celszog-torles) - a mentett célszöget törli, a kódbeli
; ab-target-angle érvényes (a következő induláskor is)
(defun celszog-torles () {
        (eeprom-store-f ab-target-eeprom -1.0)
        (print "Mentett celszog torolve, a kodbeli ab-target-angle ervenyes ujrainditas utan")
})

(defun ab-tick () {
    (if ab-toggle-req {
            (setq ab-toggle-req nil)
            (ab-toggle)
    })
    (if ab-save-req {
            (setq ab-save-req nil)
            (ab-save-angle)
    })
    (if ab-on
        (ab-step)
        {
            (read-imu)
            (var dt (clamp (secs-since ab-last-time) 0.001 0.05))
            (setq ab-last-time (systime))
            (update-rate dt)
        })
})

(defun ab-thread ()
    (loopwhile t {
            (var res (trap (ab-tick)))
            (if (eq (car res) 'exit-error) {
                    (if ab-on (trap (ab-stop 'script-hiba)))
                    (if (> (secs-since t-ab-err) 1.0) {
                            (setq t-ab-err (systime))
                            (setq script-err-time (systime))
                            (print (list 'hiba-advanced-balance (cdr res)))
                    })
            })
            (sleep 0.01)
}))

; REPL-ből hívható: (szog) - 5 másodpercig írja a nyers és a számolt szöget
(defun szog () {
        (print "Szog teszt 5 s: emeld meg a roller elejet, a szognek nonie kell")
        (print (str-merge (if (eq imu-source 'bno085) "IMU: BNO085 az elso vezerlon" "IMU: a VESC belso IMU-ja")
                ", celszog " (str-from-n ab-target-angle "%.1f")
                (if (eq ab-target-source 'eeprom) " (mentett)" " (kodbol)")))
        (looprange i 0 25 {
                (var rpy (get-imu-rpy))
                (var r (if (eq imu-source 'bno085) imu-roll (rad2deg (ix rpy 0))))
                (var p (if (eq imu-source 'bno085) imu-pitch (rad2deg (ix rpy 1))))
                (print (str-merge "roll " (str-from-n r "%.1f")
                        "  pitch " (str-from-n p "%.1f")
                        "  -> szog " (str-from-n bal-angle "%.1f")
                        (if bal-imu-ok "" "  (NINCS IMU ADAT)")))
                (sleep 0.2)
        })
})

; REPL-ből hívható: (ikon-teszt) - sorban bekapcsol egy-egy bitet a kijelző
; mezőiben, 2 s-ig mindegyiket. Figyeld, melyiknél mi gyullad ki, és ha a
; lakat helyett mást szeretnél az AB jelzésére: ab-icon-field, ab-icon-bit.
(defun ikon-teszt () {
        (loopforeach c '((0 32) (0 1) (0 8) (0 16) (2 1) (2 2) (2 4) (2 8) (2 16) (2 32) (2 64) (2 128) (3 2) (5 14))
            {
                (print (str-merge "mezo " (str-from-n (ix c 0) "%d") ", ertek " (str-from-n (ix c 1) "%d")
                        (cond ((= (ix c 0) 0) " (mod)") ((= (ix c 0) 2) " (lampa)")
                            ((= (ix c 0) 3) " (sipolas)") (t " (hibakod)"))))
                (setq icon-test-value (ix c 1))
                (setq icon-test-field (ix c 0))
                (sleep 2.0)
        })
        (setq icon-test-field -1)
        (print "Ikon teszt vege")
})

; -> Hibakódok
; A kijelző hibakód mezője. Ahol van gyári Xiaomi megfelelő, azt használjuk
; (14 gáz, 15 fék, 11-13, 18, 24, 26, 28, 31, 40), a többi saját kód 50 fölött.
; A teljes táblázat a README "Hibakódok" fejezetében van.

(defun lever-bad (raw) (or (< raw lever-raw-min) (> raw lever-raw-max)))

(defun update-lever-faults () ; minden kijelzőkeretnél
    ; a még éledő kijelző (0x0a) és az első másodperc nem számít
    (if (and dash-ready (> (secs-since first-lever-time) 1.0)) {
            (if (lever-bad thr-raw)
                {
                    (setq thr-ok-start (systime))
                    (if (> (secs-since thr-bad-start) lever-fault-time) (setq thr-fault t))
                }
                {
                    (setq thr-bad-start (systime))
                    (if (> (secs-since thr-ok-start) lever-ok-time) (setq thr-fault nil))
                })
            (if (lever-bad brk-raw)
                {
                    (setq brk-ok-start (systime))
                    (if (> (secs-since brk-bad-start) lever-fault-time) (setq brk-fault t))
                }
                {
                    (setq brk-bad-start (systime))
                    (if (> (secs-since brk-ok-start) lever-ok-time) (setq brk-fault nil))
                })
        }
        {
            (setq thr-bad-start (systime))
            (setq brk-bad-start (systime))
        })
)

(defun vesc-fault-code (f) ; VESC hibakód -> kijelző kód
    (cond
        ((= f 0) 0)
        ((or (= f 1) (= f 2)) 24)                         ; túl magas / alacsony akkufeszültség
        ((or (= f 3) (= f 7) (= f 8) (= f 19)) 28)        ; DRV, kapuvezérlő táp, BRK (MOSFET)
        ((= f 4) 51)                                      ; abszolút túláram
        ((= f 5) 40)                                      ; FET túlmelegedés
        ((= f 6) 52)                                      ; motor túlmelegedés
        ((= f 9) 56)                                      ; MCU tápfeszültség alacsony
        ((= f 10) 31)                                     ; watchdog újraindulás
        ((or (= f 14) (= f 23) (= f 24)) 26)              ; flash / konfiguráció sérült
        ((= f 15) 11)                                     ; 1. áramérzékelő offset
        ((= f 16) 12)                                     ; 2. áramérzékelő offset
        ((= f 17) 13)                                     ; 3. áramérzékelő offset
        ((or (= f 18) (= f 27)) 54)                       ; kiegyensúlyozatlan áram, fázisszűrő
        ((= f 29) 55)                                     ; LV kimenet (5V/3.3V) hiba
        ((or (= f 31) (= f 32) (= f 33)) 53)              ; túlpörgés
        ((or (= f 11) (= f 12) (= f 13) (= f 20) (= f 21) (= f 22)
            (= f 25) (= f 26) (= f 28) (= f 30)) 18)      ; enkóder / pozíciószenzor
        (t 69))                                           ; egyéb (a konzol kiírja a számát)
)

(defun current-error () ; a legfontosabb aktív hiba
    (cond
        ((> (get-fault) 0) (vesc-fault-code (get-fault)))
        ((and thr-fault brk-fault) 16)
        (thr-fault 14)
        (brk-fault 15)
        ((and (> front-fault 0) (< (secs-since front-ack-time) 1.0)) 57)
        (front-warn front-error-code)
        (front-old front-old-error-code)
        ; események: rövid ideig aktívak, a kijelzőn az error-hold-time tartja kint
        ((and ab-cut-time (< (secs-since ab-cut-time) 0.5)) 58)
        ((and script-err-time (< (secs-since script-err-time) 0.5)) 59)
        ((and ab-save-fail-time (< (secs-since ab-save-fail-time) 0.5)) 61)
        ((and ab-imu-fail-time (< (secs-since ab-imu-fail-time) 0.5)) 62)
        (t 0))
)

(defun error-text (code) ; csak ASCII a konzolra
    (cond
        ((= code 0) "nincs hiba")
        ((= code 10) "a kijelzo nem kap valaszt (UART bekotes, script nem fut)")
        ((= code 11) "1. aramerzekelo offset hiba")
        ((= code 12) "2. aramerzekelo offset hiba")
        ((= code 13) "3. aramerzekelo offset hiba")
        ((= code 14) "gazkar jele hibas (szakadas vagy zarlat)")
        ((= code 15) "fekkar jele hibas (szakadas vagy zarlat)")
        ((= code 16) "gaz- es fekkar egyszerre hibas (kozos tap/GND, kabel)")
        ((= code 18) "motor enkoder / pozicioszenzor hiba")
        ((= code 24) "akkufeszultseg tul magas vagy tul alacsony")
        ((= code 26) "flash vagy konfiguracio serult")
        ((= code 28) "kapuvezerlo (DRV) / MOSFET hiba")
        ((= code 31) "a vezerlo ujraindult (watchdog)")
        ((= code 40) "vezerlo (FET) tulmelegedes")
        ((= code 50) "az elso vezerlo nem valaszol")
        ((= code 51) "tularam")
        ((= code 52) "motor tulmelegedes")
        ((= code 53) "tulporges (sebessegkorlat hiba)")
        ((= code 54) "kiegyensulyozatlan fazisaram / fazisszuro")
        ((= code 55) "5V/3.3V kimenet hiba (zarlat a csatlakozon)")
        ((= code 56) "MCU tapfeszultseg alacsony")
        ((= code 57) "az elso vezerlo hibat jelez")
        ((= code 58) "Advanced Balance lekapcsolt (borulas vagy IMU)")
        ((= code 59) "script hiba (lasd a konzolt)")
        ((= code 60) "az elso vezerlon regi script fut (toltsd fel az uj elso_vezerlo.lisp-et)")
        ((= code 61) "celszog mentes sikertelen (allj meg, fek, 5-45 fok, IMU)")
        ((= code 62) "nincs IMU adat (BNO085 az elso vezerlon / imu-source)")
        (t "egyeb VESC hiba"))
)

(defun update-error () { ; 50 Hz, a vezérlőszálban
        (var code (current-error))
        (if (> code 0)
            {
                (if (not (= code err-last)) { ; új hiba: konzol + előzmények
                        (print (str-merge "HIBA " (str-from-n code "%d") ": " (error-text code)
                                (if (> (get-fault) 0)
                                    (str-merge " (VESC hibakod " (str-from-n (get-fault) "%d") ")")
                                    "")))
                        (setq err-history (take (cons (list code (secs-since boot-time)) err-history) 8))
                })
                (setq err-shown code)
                (setq err-time (systime))
            }
            (if (> (secs-since err-time) error-hold-time) (setq err-shown 0)))
        (setq err-last code)
})

; REPL-ből hívható: (hibak) - aktív hiba, kar jelek és az utolsó 8 hiba
(defun hibak () {
        (var code (current-error))
        (print (str-merge "Aktiv: " (str-from-n code "%d") " - " (error-text code)
                ", VESC hibakod: " (str-from-n (get-fault) "%d")
                ", elso vezerlo: " (str-from-n front-fault "%d")))
        (print (str-merge "Gazkar nyers " (str-from-n thr-raw "%d") (if thr-fault " HIBAS" " ok")
                ", fekkar nyers " (str-from-n brk-raw "%d") (if brk-fault " HIBAS" " ok")
                " (jo tartomany " (str-from-n lever-raw-min "%d") "-" (str-from-n lever-raw-max "%d") ")"))
        (print "Elozmenyek (legujabb elol):")
        (loopforeach e err-history
            (print (str-merge "  " (str-from-n (ix e 0) "%d") " - " (error-text (ix e 0))
                    ", " (str-from-n (- (secs-since boot-time) (ix e 1)) "%.0f") " s-mal ezelott")))
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
        ; a gáznak folyamatosan p2-detect-hold ideig fent kell lennie, érvényes
        ; tartományban (egy tápra zárlatos gázkar nem kapcsolhatja be a 2-es profilt)
        (if (and dash-ready (> thr p2-detect-throttle) (not (lever-bad thr-raw)))
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
        (if (and ab-thr-lock (not thr-fault) (not brk-fault) (< thr-lvl 0.05)) (setq ab-thr-lock nil))
        (setq thr-gate (or (not kick-engaged) ab-thr-lock))
})

(defun control-step () {
        (var spd (speed-kmh))
        (var fresh (< (secs-since last-lever-time) 0.5))
        (var thr (if fresh (get-adc-decoded 0) 0.0))
        (var brk (if fresh (get-adc-decoded 1) 0.0))
        (var was-braking braking)
        (setq braking (or (> brk brake-level) (and ab-on (< ab-cur -5.0))))
        (if (and braking (not was-braking)) { ; fékezés kezdete: azonnal kialszik, utána villog
                (setq blink-on nil)
                (setq blink-time (systime))
        })

        (cond
            ((eq state 'detect) (detect-step thr))
            ((eq state 'release) (release-step thr))
            (t (run-step spd)))

        (button-step)
        (update-error)
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
                (if (not headlight-on-front) (gpio-configure headlight-pin 'pin-mode-out))
                (gpio-configure button-pin 'pin-mode-in-pu)
                (refresh-gate)
                (ab-refresh)
                (update-temp-warn)
                (update-front-warn)
        })
})

(defun control-loop ()
    (loopwhile t {
            ; egy váratlan hiba ne állítsa le a gombot és a lámpákat: kiírjuk és megyünk tovább
            (var res (trap (control-step)))
            (if (and (eq (car res) 'exit-error) (> (secs-since t-err) 1.0)) {
                    (setq t-err (systime))
                    (setq script-err-time (systime))
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
            (list 'lampa light 'elso-lampa front-lamp 'elso-lab front-pin)
            (list 'elso-ack-s (secs-since front-ack-time) 'elso-flags front-ack-flags 'elso-hiba front-warn
                'elso-verzio front-version 'elso-regi front-old 'elso-vesc-hiba front-fault)
            (list 'tc tc-on 'tc-aktiv (tc-active) 'tc-elso tc-front 'tc-hatso tc-rear
                'elso-km/h front-speed)
            (list 'ab ab-on 'szog bal-angle 'oldal bal-roll 'cel ab-target-angle 'korlat ab-lim
                'aram ab-cur 'gaz-fek ab-pwr 'imax ab-imax)
            (list 'ab-tc-elso ab-tc-front 'ab-tc-hatso ab-tc-rear 'elso-id ab-front-id 'imu bal-imu-ok
                'imu-forras imu-source 'utolso-kilepes ab-reason 'gaz-zar ab-thr-lock)
)))

; REPL-ből hívható: (lampa-teszt) - háromszor be- és kikapcsolja a lámpát, és
; kiírja, mit jelez vissza az első vezérlő (a parancsot és a lámpa láb
; visszaolvasott szintjét), a végén pedig, mire lehet következtetni.
; A parancsot a vezérlőszál küldi ki (legfeljebb 0,1 s), itt csak a lámpát állítjuk.
(defun lampa-teszt () {
        (var orig light)
        (var follow 0) ; hányszor követte az első a parancsot
        (var ons 0)    ; bekapcsolt lépések
        (var pinhi 0)  ; ezek közül hányszor volt magas az első vezérlő lámpa lába
        (print (str-merge "Elso script verzio: " (str-from-n front-version "%d")
                (if (< front-version front-min-version)
                    " -> REGI vagy nem valaszol: toltsd fel az uj elso_vezerlo.lisp-et az elso vezerlore!"
                    " (rendben)")))
        (if (not headlight-on-front)
            (print "A lampa a hatso vezerlo headlight-pin laban van (headlight-on-front nil)."))
        (looprange i 0 6 {
                (setq light (not light))
                (sleep 0.5)
                (if (eq front-lamp light) (setq follow (+ follow 1)))
                (if light {
                        (setq ons (+ ons 1))
                        (if (= front-pin 1) (setq pinhi (+ pinhi 1)))
                })
                (print (str-merge "lampa " (if light "BE" "KI")
                        " -> elso vezerlo: parancs " (if front-lamp "BE" "KI")
                        ", lab " (str-from-n front-pin "%d")
                        ", utolso valasz " (str-from-n (secs-since front-ack-time) "%.2f") " s"))
                (sleep 1.0)
        })
        (setq light orig)
        (if headlight-on-front
            (print (cond
                    ((< front-version front-min-version)
                        "EREDMENY: az elso vezerlo nem valaszol, vagy regi script fut rajta.")
                    ((< follow 6)
                        "EREDMENY: az elso vezerlo nem koveti a lampa parancsot (CAN kapcsolat, script).")
                    ((= pinhi ons)
                        "EREDMENY: a parancs eljut, az elso vezerlo PPM laba kapcsol. Ha a lampa nem eg: futtasd az elso vezerlon is a (lampa-teszt)-et, es merd a PPM csatlakozon a feszultseget (README).")
                    (t "EREDMENY: az elso vezerlo laba nem megy magasra (zarlatos MOSFET vagy serult lab). Futtasd az elso vezerlon a (lampa-teszt)-et lehuzott lampa vezetekkel."))))
})

(defun init () {
        (setq boot-time (systime))

        ; ADC app: a bemenetet mi adjuk, a kimenet a profil eldöntéséig tiltva
        (app-adc-detach 3 1)
        (app-disable-output -1)

        (gpio-configure 'pin-ppm 'pin-mode-out)     ; féklámpa
        (gpio-write 'pin-ppm 1)
        (if (not headlight-on-front) {               ; első lámpa a hátsó vezérlő lábán
                (gpio-configure headlight-pin 'pin-mode-out)
                (gpio-write headlight-pin (if light 1 0))
        })

        ; uart-read-bytes az olvasott bájtok után egy 0-t is ír, ezért +1 hely kell
        (def rx-one (bufcreate 2))
        (def rx-buf (bufcreate 64))
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
        (load-target-angle)
        (ab-refresh)
        (spawn 200 ab-thread)
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

(image-save)
(main)
