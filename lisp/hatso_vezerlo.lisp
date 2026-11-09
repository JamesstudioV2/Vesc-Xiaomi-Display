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
;      1x nyomás = első lámpa (ADC2 MOSFET) + lámpa ikon
;      2x nyomás = módváltás  D -> S -> ECO -> D
;  - PPM láb: féklámpa MOSFET. Alapból folyamatosan világít, fékezéskor villog.
;  - Kijelzőn: sebesség, akku töltöttség, mód (ECO/D/S), hőfok ikon, hibakód.
;  - 1-es profil (alapértelmezett, "rendőr mód"): csak a hátsó motor megy,
;    3 km/h-s berúgás kell az induláshoz.
;  - 2-es profil: bekapcsoláskor nyomva tartott gázkarral. Mindkét motor megy,
;    nincs berúgás, álló helyzetben a kijelző az akku %-ot mutatja.
;  - Advanced Balance (csak 2-es profilban, KÍSÉRLETI): be/ki a fék behúzása
;    közben 2x gombnyomással, induláskor mindig ki van kapcsolva, bekapcsolva a
;    csavarkulcs ikon világít. Két keréken a roller teljesen normál. Ha az eleje
;    felemelkedik, a gáz továbbra is a nyomatékot adja, de egy szögfigyelő
;    szabályzó elveszi a gázt, vagy fékez is, hogy a roller ne lépje át a
;    beállított célszöget. Az első kerék egy laza kipörgésgátlóval nagyjából
;    együtt forog a hátsóval. Lekapcsol: 60° oldalra vagy 60° hátra dőlésnél.
;
; Bekötés (COMM port):
;   kijelző piros  -> 5V        kijelző fekete -> GND
;   kijelző sárga  -> TX (half-duplex adatvonal)
;   kijelző zöld (gomb) -> RX + 470 Ohm felhúzó ellenállás 3.3V-ra
;   PPM jel -> féklámpa MOSFET gate,   ADC2 -> első lámpa MOSFET gate
;   ADC1 -> szabad (10 kOhm-mal GND-re ajánlott)
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

(def beep-on-start t)          ; induláskor sípol: 1x = 1-es profil, 2x = 2-es profil

; Advanced Balance - csak 2-es profilban. KÍSÉRLETI!
; Be/ki: fékkar behúzva + 2x gombnyomás. Induláskor mindig ki van kapcsolva.
; Az alapértékek egy egyszerű modellből becsültek (tools/balansz_modell.py),
; a rolleredre hangolni kell (README: "Advanced Balance").
; A szög: fok, az eleje emelésekor nő, vízszintes rollernél 0 (ld. (szog)).
(def balance-axis 1)              ; IMU tengely a get-imu-rpy listából: 0 = roll, 1 = pitch
(def balance-invert nil)          ; t, ha az eleje emelésekor a nyers szög csökken
(def balance-level-offset 0.0)    ; fok - ennyit mutat a nyers szög vízszintes rollernél
(def ab-target-angle 20.0)        ; fok - CÉLSZÖG: az elejét e fölé nem engedi
                                  ;   (a balanszpontnál ne legyen nagyobb, és jóval nagyobb
                                  ;   legyen a legmeredekebb emelkedőnél, amin jársz)
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
; Kipörgésgátló az első és a hátsó kerék között (csak AB módban). A két kerék
; azonos legyen (a canget-speed a hátsó vezérlő kerékadataival számol).
(def ab-tc-enabled t)
(def ab-tc-slip 3.0)              ; km/h - eddig a sebességkülönbségig nem szól bele
(def ab-tc-range 5.0)             ; km/h - a csúszás fölött ennyivel a gyorsabb kerék hajtása 0
(def ab-tc-filter 0.2)            ; 0-1 - simítás (kisebb = lazább, lassabb)
(def front-can-id -1)             ; az első vezérlő CAN ID-je, -1 = automatikus (az első talált)
; Csavarkulcs ikon AB módban. A Xiaomi protokollban nincs rá külön bit, a
; kijelzők a hibakód mezőhöz kötik (ilyenkor a kód is megjelenhet). Ha a
; kijelződön mással gyullad ki, keresd meg az (ikon-teszt) paranccsal.
(def ab-icon-mode 'error)         ; 'error = hibakód mező, 'bit = bit egy mezőben, nil = nincs
(def ab-icon-code 88)             ; 'error módban ezt a kódot küldi, ha nincs valódi hiba
(def ab-icon-field 0)             ; 'bit módban: 0 = mód, 2 = lámpa, 3 = sípolás mező
(def ab-icon-bit 0)               ; 'bit módban ezt az értéket (bitet) kapcsolja be a mezőben

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

(defun mode-limits (prof mode)
    (if (= prof 2)
        (cond ((= mode 2) p2-eco) ((= mode 4) p2-sport) (t p2-drive))
        (cond ((= mode 2) p1-eco) ((= mode 4) p1-sport) (t p1-drive)) ; 0 = még nincs profil -> 1-es
))

(defun front-flags () ; bit0 = hajtás, bit1 = fék
    (if (= profile 2) 3 (if p1-front-brake 2 0))
)

; -> Módok és az első vezérlő

(defun apply-mode-limits () {
        (var lim (mode-limits profile speedmode))
        (conf-set 'max-speed (/ (ix lim 0) 3.6))
        (conf-set 'l-watt-max (ix lim 1))
        (conf-set 'l-current-max-scale (ix lim 2))
})

(defun apply-mode () {
        (apply-mode-limits)
        (send-front)
})

; 8 bájt: A5, flags, áram %, km/h*10 (u16), watt/100 (u16), profil
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
            (bufset-u8 can-tx 2 (to-i (round (* 100.0 (ix lim 2)))))
            (bufset-u16 can-tx 3 (to-i (round (* 10.0 (ix lim 0)))))
            (bufset-u16 can-tx 5 (to-i (round (/ (ix lim 1) 100.0))))
            (bufset-u8 can-tx 7 profile)
            (can-send-sid front-cmd-sid can-tx)
}))

(defun on-front-ack (id data)
    (if (and (= id front-ack-sid) (>= (buflen data) 2) (= (bufget-u8 data 0) 0xA5)) {
            (setq front-ack-time (systime))
            (setq front-ack-flags (bufget-u8 data 1))
}))

(defun can-event-loop ()
    (loopwhile t
        (recv
            ((event-can-sid . ((? id) . (? data))) (on-front-ack id data))
            (_ nil)
)))

(defun update-front-warn ()
    (setq front-warn
        (and front-enabled
            (> (secs-since boot-time) 4.0)
            (> (length (can-list-devs)) 0)
            (or (> (secs-since front-ack-time) 1.0)
                (and (not (= front-ack-flags (front-flags)))
                    (> (secs-since front-flags-time) 1.0)))))
)

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
        (setq brk-start (conf-get 'adc-v2-start))
        (setq brk-end (conf-get 'adc-v2-end))
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

(defun send-dash () {
        (var spd (speed-kmh))
        (var batt (to-i (clamp (* (get-batt) 100.0) 0.0 100.0)))
        (var shown (if (and (= profile 2) (< spd p2-idle-speed)) batt (to-i (+ spd 0.5))))
        (var fault (get-fault))
        (var beep 0)
        (if (> beep-count 0) {
                (setq beep 1)
                (setq beep-count (- beep-count 1))
        })
        ; mód bájt: 1 = D, 2 = ECO, 4 = S, +128 = hőfok ikon
        (bufset-u8 tx-frame 6 (+ speedmode (if temp-warn 128 0)))
        (bufset-u8 tx-frame 7 batt)
        (bufset-u8 tx-frame 8 (if light 1 0))
        (bufset-u8 tx-frame 9 beep)
        (bufset-u8 tx-frame 10 (clamp shown 0 255))
        (bufset-u8 tx-frame 11
            (cond
                ((> fault 0) fault)
                (front-warn front-error-code)
                ((and ab-on (eq ab-icon-mode 'error)) ab-icon-code) ; csavarkulcs ikon
                (t 0)))
        (if (and ab-on (eq ab-icon-mode 'bit))
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
    (if (= clicks 1)
        {
            (setq light (not light))
            (button-log-msg (if light "1x -> lampa BE" "1x -> lampa KI"))
        }
        (if (>= brk-lvl ab-toggle-brake)
            { ; behúzott fékkel 2x: Advanced Balance be/ki
                (button-log-msg (if ab-on "fek + 2x -> AB KI" "fek + 2x -> AB BE"))
                (setq ab-toggle-req t) ; az AB szál kapcsol, hogy a motorparancsok ne keveredjenek
            }
            { ; 2 vagy több nyomás: D -> S -> ECO -> D
                (setq speedmode (cond ((= speedmode 1) 4) ((= speedmode 4) 2) (t 1)))
                (apply-mode)
                (setq beep-count 1)
                (button-log-msg (str-merge (str-from-n clicks "%d") "x -> mod "
                        (cond ((= speedmode 2) "ECO") ((= speedmode 4) "S") (t "D"))))
            })
))

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
        (gpio-write 'pin-adc2 (if light 1 0))
})

; -> Advanced Balance (csak 2-es profilban)
; Bekapcsolva a script vezérli mindkét motort 100 Hz-en (az ADC app kimenete
; tiltva). A gáz és a fék ugyanúgy jut a motorokhoz, mint az ADC appban
; (kalibráció, holtjáték, görbe, rámpa), de a hátsó motor áramát a szögkorlát
; felülről korlátozza: min(gáz, korlát). A korlát a célszög alatt nagy, a
; célszög körül 0-ra csökken, fölötte negatív (fékez). Két keréken (a szög az
; ab-engage-angle alatt) nem szól bele. A fék mindig a normál fék.

(defun read-imu () {
        (var rpy (get-imu-rpy))
        (var raw (rad2deg (ix rpy balance-axis)))
        (setq bal-roll (rad2deg (ix rpy (if (= balance-axis 0) 1 0))))
        (setq bal-angle (- (if balance-invert (- 0.0 raw) raw) balance-level-offset))
        ; IMU nélkül (vagy kikapcsolt IMU-val) a gyorsulásmérő 0-t ad
        (var acc (get-imu-acc))
        (setq bal-imu-ok (> (+ (* (ix acc 0) (ix acc 0)) (* (ix acc 1) (ix acc 1))
                    (* (ix acc 2) (ix acc 2))) 0.09))
})

(defun update-rate (dt) {
        (setq bal-rate (+ bal-rate (* 0.3 (- (/ (- bal-angle bal-prev-angle) dt) bal-rate))))
        (setq bal-prev-angle bal-angle)
})

(defun ab-refresh () ; 0,5 s-onként: a VESC Tool beállításai és az első vezérlő ID-je
    {
        (setq ab-imax (* (conf-get 'l-current-max) (conf-get 'l-current-max-scale)))
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
                (var d (* 3.6 (- (canget-speed ab-front-id) (get-speed)))) ; + = az első gyorsabb
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
                (var want (min2 (* ab-pwr ab-imax ab-tc-rear) ab-lim))
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

(defun ab-tick () {
    (if ab-toggle-req {
            (setq ab-toggle-req nil)
            (ab-toggle)
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
                            (print (list 'hiba-advanced-balance (cdr res)))
                    })
            })
            (sleep 0.01)
}))

; REPL-ből hívható: (szog) - 5 másodpercig írja a nyers és a számolt szöget
(defun szog () {
        (print "Szog teszt 5 s: emeld meg a roller elejet, a szognek nonie kell")
        (looprange i 0 25 {
                (var rpy (get-imu-rpy))
                (print (str-merge "roll " (str-from-n (rad2deg (ix rpy 0)) "%.1f")
                        "  pitch " (str-from-n (rad2deg (ix rpy 1)) "%.1f")
                        "  -> szog " (str-from-n bal-angle "%.1f")
                        (if bal-imu-ok "" "  (NINCS IMU ADAT)")))
                (sleep 0.2)
        })
})

; REPL-ből hívható: (ikon-teszt) - sorban bekapcsol egy-egy bitet a kijelző
; mezőiben, 2 s-ig mindegyiket. Figyeld, melyiknél gyullad ki a csavarkulcs,
; és azt állítsd be: ab-icon-mode 'bit, ab-icon-field, ab-icon-bit
; (a hibakódnál: ab-icon-mode 'error, ab-icon-code).
(defun ikon-teszt () {
        (loopforeach c '((0 1) (0 8) (2 1) (2 2) (2 4) (2 8) (2 16) (2 32) (2 64) (2 128) (3 2) (5 88))
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
        (if (and ab-thr-lock (< thr-lvl 0.05)) (setq ab-thr-lock nil))
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
        (lights-step)

        (if (> (secs-since t-front) 0.1) {
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
                (gpio-configure 'pin-adc2 'pin-mode-out)
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
            (list 'gomb-lab (gpio-read button-pin) 'lenyomva btn-state 'nyomasok btn-presses
                'lampa light)
            (list 'elso-ack-s (secs-since front-ack-time) 'elso-flags front-ack-flags 'elso-hiba front-warn)
            (list 'ab ab-on 'szog bal-angle 'oldal bal-roll 'cel ab-target-angle 'korlat ab-lim
                'aram ab-cur 'gaz-fek ab-pwr 'imax ab-imax)
            (list 'tc-elso ab-tc-front 'tc-hatso ab-tc-rear 'elso-id ab-front-id 'imu bal-imu-ok
                'utolso-kilepes ab-reason 'gaz-zar ab-thr-lock)
)))

(defun init () {
        (setq boot-time (systime))

        ; ADC app: a bemenetet mi adjuk, a kimenet a profil eldöntéséig tiltva
        (app-adc-detach 3 1)
        (app-disable-output -1)

        (gpio-configure 'pin-ppm 'pin-mode-out)     ; féklámpa
        (gpio-write 'pin-ppm 1)
        (gpio-configure 'pin-adc2 'pin-mode-out)    ; első lámpa
        (gpio-write 'pin-adc2 (if light 1 0))

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

        (refresh-gate)
        (apply-mode) ; induláskor az 1-es profil korlátai élnek

        (event-register-handler (spawn can-event-loop))
        (event-enable 'event-can-sid)

        ; half-duplex módban csak a TX láb kell, az RX szabad: ezen van a gomb
        (uart-start 115200 'half-duplex)
        (gpio-configure button-pin 'pin-mode-in-pu)
        (spawn 200 rx-thread)
        (ab-refresh)
        (spawn 200 ab-thread)
})

(defun main () {
        (init)
        (control-loop)
})

@const-end

(image-save)
(main)
