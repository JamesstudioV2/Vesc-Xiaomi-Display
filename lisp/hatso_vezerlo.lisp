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
;  - Lisp konzol: (status), (gomb-teszt), (lampa-teszt), (ikon-teszt), (tc-teszt)
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

(defun front-flags () ; bit0 = hajtás, bit1 = fék
    (if (= profile 2) 3 (if p1-front-brake 2 0))
)

; -> Módok és az első vezérlő

; A hátsó áram-szorzó: a mód szorzója (a kipörgésgátló a hátsóba nem szól bele).
; Ez a VESC "instant" konfigurációs útja (nem indítja újra az ADC app-ot), és
; csak változáskor írjuk.
(defun apply-scale () {
        (var s (/ (round (* 100.0 (ix (mode-limits profile speedmode) 2))) 100.0))
        (if (not (= s rear-scale)) {
                (conf-set 'l-current-max-scale s)
                (setq rear-scale s)
        })
})

(defun apply-mode () {
        (var lim (mode-limits profile speedmode))
        (conf-set 'max-speed (/ (ix lim 0) 3.6))
        (conf-set 'l-watt-max (ix lim 1))
        (setq rear-scale -1.0) ; mindenképp újraírjuk
        (apply-scale)
        (send-front)
})

; 8 bájt: A5, flags, áram %, km/h*10 (u16), watt/100 (u16), profil
; flags: bit0 = hajtás, bit1 = fék (a 2-es bit a korábbi, első vezérlős lámpáé volt)
; Az áram % a mód szorzója x a kipörgésgátló első szorzója.
(defun send-front ()
    (if front-enabled {
            (var lim (mode-limits profile speedmode))
            (bufset-u8 can-tx 0 0xA5)
            (bufset-u8 can-tx 1 (front-flags))
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

(defun can-event-loop ()
    (loopwhile t
        (recv
            ((event-can-sid . ((? id) . (? data))) (on-front-ack id data))
            (_ nil)
)))

(defun update-front-warn () {
        (var on (and front-enabled
                (> (secs-since boot-time) 4.0)
                (> (length (can-list-devs)) 0)))
        (setq front-warn
            (and on
                (or (> (secs-since front-ack-time) 1.0)
                    (not (= front-ack-flags (front-flags))))))
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
        (setq thr-gate-inv (> start (conf-get 'adc-v1-end)))
        (setq thr-gate-v start)
})

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
                (button-log-msg (if light "1x -> lampa BE" "1x -> lampa KI"))
        })
        ((= clicks 2) { ; D -> S -> ECO -> D
                (setq speedmode (cond ((= speedmode 1) 4) ((= speedmode 4) 2) (t 1)))
                (apply-mode)
                (setq beep-count 1)
                (button-log-msg (str-merge "2x -> mod "
                        (cond ((= speedmode 2) "ECO") ((= speedmode 4) "S") (t "D"))))
        })
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
        (setq thr-gate (not kick-engaged))
})

(defun control-step () {
        (var spd (speed-kmh))
        (var fresh (< (secs-since last-lever-time) 0.5))
        (var thr (if fresh (get-adc-decoded 0) 0.0))
        (var brk (if fresh (get-adc-decoded 1) 0.0))
        (var was-braking braking)
        (setq braking (> brk brake-level))
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
