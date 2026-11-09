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

@const-start

; -> Segédfüggvények

(defun clamp (x lo hi)
    (cond
        ((< x lo) lo)
        ((> x hi) hi)
        (t x)
))

(defun speed-kmh () (abs (* (get-speed) 3.6)))

(defun mode-limits (prof mode)
    (if (= prof 2)
        (cond ((= mode 2) p2-eco) ((= mode 4) p2-sport) (t p2-drive))
        (cond ((= mode 2) p1-eco) ((= mode 4) p1-sport) (t p1-drive)) ; 0 = még nincs profil -> 1-es
))

(defun front-flags () ; bit0 = hajtás, bit1 = fék
    (if (= profile 2) 3 (if p1-front-brake 2 0))
)

; -> Módok és az első vezérlő

(defun apply-mode () {
        (var lim (mode-limits profile speedmode))
        (conf-set 'max-speed (/ (ix lim 0) 3.6))
        (conf-set 'l-watt-max (ix lim 1))
        (conf-set 'l-current-max-scale (ix lim 2))
        (send-front)
})

; 8 bájt: A5, flags, áram %, km/h*10 (u16), watt/100 (u16), profil
(defun send-front ()
    (if front-enabled {
            (var lim (mode-limits profile speedmode))
            (bufset-u8 can-tx 0 0xA5)
            (bufset-u8 can-tx 1 (front-flags))
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
                (not (= front-ack-flags (front-flags))))))
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
        (bufset-u8 tx-frame 11 (if (> fault 0) fault (if front-warn front-error-code 0)))
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
        { ; 2 vagy több nyomás: D -> S -> ECO -> D
            (setq speedmode (cond ((= speedmode 1) 4) ((= speedmode 4) 2) (t 1)))
            (apply-mode)
            (setq beep-count 1)
            (button-log-msg (str-merge (str-from-n clicks "%d") "x -> mod "
                    (cond ((= speedmode 2) "ECO") ((= speedmode 4) "S") (t "D"))))
        }
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
})

(defun main () {
        (init)
        (control-loop)
})

@const-end

(image-save)
(main)
