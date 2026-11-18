; =============================================================================
; Xiaomi M365 PRO 2 kijelző -> VESC 7.00  |  ELSŐ (slave) vezérlő
; Repo: https://github.com/JamesstudioV2/vesc-xiaomi-display
;
; A gázt és a féket a hátsó vezérlő ADC app-ja küldi CAN-en ("Multiple VESCs
; over CAN"). Ez a script a hátsó vezérlőtől kapott CAN üzenet alapján állítja
; az első motor korlátait:
;   1-es profil: hajtás kikapcsolva (áram-szorzó 0), fék a beállítás szerint
;   2-es profil: hajtás és fék be, ugyanazok a sebesség/watt/áram korlátok,
;                mint a hátsón (a kipörgésgátló az áram-szorzót csökkentheti)
; Ha 1 másodpercig nem jön üzenet (vagy induláskor), az első motor tiltva van.
; Az első lámpa MOSFET-je ennek a vezérlőnek a PPM lábán van (light-pin), a
; hátsó a CAN üzenet flags 2-es bitjével kapcsolja. Üzenetkiesésnél a lámpa
; az utolsó állapotában marad (ne aludjon ki menet közben).
; A visszajelzésben a hátsó megkapja ennek a scriptnek a verzióját, a lámpa
; állapotát, az első kerék sebességét (kipörgésgátló) és a VESC hibakódot.
;
; Opcionális: BNO085 IMU ennek a vezérlőnek a COMM portján (bno-enabled). A
; szögek CAN-en mennek a hátsónak (a balansz ágak használják, a main ágon nem
; kell). A VESC Tool IMU listájában a BNO085 nincs benne, ezért olvassa a script.
;
; Lisp konzol: (lampa-teszt) - a lámpa kimenet 5x ki-be, a hátsótól függetlenül
;              (bno) - a BNO085 állapota és szögei
; =============================================================================

(def script-version 2)   ; a hátsó script ellenőrzi (front-min-version)
(def cmd-sid 0x4D0)      ; hátsó -> első (egyezzen a hátsó script front-cmd-sid értékével)
(def ack-sid 0x4D1)      ; első -> hátsó (front-ack-sid)
(def imu-sid 0x4D2)      ; első -> hátsó: BNO085 szögek (a hátsó imu-sid értéke)
(def rx-timeout 1.0)     ; s
(def light-pin 'pin-ppm) ; az első lámpa MOSFET gate-je (App to Use: No App, Servo Output: ki)

; BNO085 a COMM porton (a main ágon nem kell, a balansz ágakon t)
;  I2C (alap, PS0 = PS1 = 0):  SDA -> RX, SCL -> TX, VIN -> 3.3V, GND -> GND
;                              cím 0x4A vagy 0x4B (automatikusan megtalálja)
;  UART-RVC (PS0 = 1, PS1 = 0): a BNO085 SDA (TX) lába -> RX, 115200 baud
(def bno-enabled nil)        ; t = a BNO085 olvasása
(def bno-mode 'i2c)          ; 'i2c (SHTP) vagy 'rvc (UART-RVC)
(def bno-sda 'pin-rx)        ; I2C SDA láb
(def bno-scl 'pin-tx)        ; I2C SCL láb
(def bno-i2c-rate 'rate-400k)
(def bno-interval-ms 10)     ; ms - mintavétel I2C módban (10 = 100 Hz; RVC mindig 100 Hz)

(def last-rx 0)
(def cur-flags -1)
(def cur-scale -1)
(def cur-kmh10 -1)
(def cur-watt100 -1)
(def front-light nil)
(def lamp-test nil)          ; (lampa-teszt) alatt a parancs nem írja a lámpa lábát

(def bno-state 'detect)      ; 'detect -> 'boot -> 'run
(def bno-state-time 0)
(def bno-first t)            ; az első keresés azonnal, utána 1 s-onként
(def bno-addr -1)            ; a megtalált I2C cím, -1 = nincs
(def bno-i2c-on nil)
(def bno-seq-exec 0)         ; SHTP sorszámok csatornánként
(def bno-seq-ctrl 0)
(def bno-bufs nil)           ; olvasópufferek méret szerint: ((méret . puffer) ...)
(def bno-roll 0.0)           ; fok
(def bno-pitch 0.0)
(def bno-yaw 0.0)
(def bno-time 0)             ; az utolsó minta ideje
(def bno-count 0)            ; beérkezett minták
(def bno-restarts 0)         ; újraindítások (diagnosztika)

@const-start

(defun clamp (x lo hi)
    (cond
        ((< x lo) lo)
        ((> x hi) hi)
        (t x)
))

; flags: bit0 = hajtás, bit1 = fék; scale: %; kmh10: km/h*10; watt100: watt/100
; Csak a megváltozott értéket írjuk (a kipörgésgátló gyakran állítja a szorzót).
(defun apply-limits (flags scale kmh10 watt100) {
        (if (not (and (= flags cur-flags) (= scale cur-scale))) {
                (conf-set 'l-current-max-scale
                    (if (= (bitwise-and flags 1) 1) (/ scale 100.0) 0.0))
                (conf-set 'l-current-min-scale
                    (if (= (bitwise-and flags 2) 2) 1.0 0.0))
        })
        (if (not (= kmh10 cur-kmh10)) (conf-set 'max-speed (/ (/ kmh10 10.0) 3.6)))
        (if (not (= watt100 cur-watt100)) (conf-set 'l-watt-max (* watt100 100.0)))
        (setq cur-flags flags)
        (setq cur-scale scale)
        (setq cur-kmh10 kmh10)
        (setq cur-watt100 watt100)
})

(defun bno-fresh () (and bno-enabled (< (secs-since bno-time) 0.2)))

; visszajelzés, 8 bájt: A5, flags, áram %, VESC hibakód, állapot, verzió,
; sebesség (0,1 km/h, előjeles). Állapot: bit0 = lámpa parancs, bit1 = BNO085
; adat friss, bit2 = a lámpa láb visszaolvasott szintje.
(defun send-ack () {
        (bufset-u8 ack 0 0xA5)
        (bufset-u8 ack 1 cur-flags)
        (bufset-u8 ack 2 cur-scale)
        (bufset-u8 ack 3 (clamp (get-fault) 0 255))
        (bufset-u8 ack 4 (+ (if front-light 1 0) (if (bno-fresh) 2 0)
                (if (= (gpio-read light-pin) 1) 4 0)))
        (bufset-u8 ack 5 script-version)
        (bufset-i16 ack 6 (clamp (to-i (round (* (get-speed) 36.0))) -32000 32000))
        (can-send-sid ack-sid ack)
})

(defun on-cmd (data)
    (if (and (>= (buflen data) 8) (= (bufget-u8 data 0) 0xA5)) {
            (setq last-rx (systime))
            (setq front-light (= (bitwise-and (bufget-u8 data 1) 4) 4))
            (if (not lamp-test) (gpio-write light-pin (if front-light 1 0)))
            (apply-limits (bitwise-and (bufget-u8 data 1) 3) (bufget-u8 data 2)
                (bufget-u16 data 3) (bufget-u16 data 5))
            (send-ack)
}))

(defun event-loop ()
    (loopwhile t
        (recv
            ((event-can-sid . ((? id) . (? data)))
                (if (= id cmd-sid) (on-cmd data)))
            (_ nil)
)))

(defun watchdog-step () {
    ; ha egy App vagy Servo Output váltás visszaállítaná, újra kimenet
    (gpio-configure light-pin 'pin-mode-out)
    (if (and (> (secs-since last-rx) rx-timeout) (not (= cur-flags 0)))
        (apply-limits 0 cur-scale cur-kmh10 cur-watt100))
})

; REPL-ből hívható: (lampa-teszt) - a lámpa kimenetet 5x 1 s-ra bekapcsolja,
; a hátsó parancsától függetlenül. Ha a lámpa ettől sem világít: bekötés vagy
; MOSFET hiba. A "lab" a láb visszaolvasott szintje (BE alatt 1 kell legyen).
(defun lampa-teszt () {
        (setq lamp-test t)
        (print "Lampa teszt: 5x 1 s BE, 1 s KI a PPM labon")
        (looprange i 0 5 {
                (gpio-configure light-pin 'pin-mode-out)
                (gpio-write light-pin 1)
                (sleep 0.05)
                (print (str-merge "BE  (lab = " (str-from-n (gpio-read light-pin) "%d") ")"))
                (sleep 0.95)
                (gpio-write light-pin 0)
                (sleep 0.05)
                (print (str-merge "KI  (lab = " (str-from-n (gpio-read light-pin) "%d") ")"))
                (sleep 0.95)
        })
        (setq lamp-test nil)
        (gpio-write light-pin (if front-light 1 0))
        (print "Lampa teszt vege")
})

; -> BNO085 (CEVA SH-2, SHTP protokoll)
; I2C-n minden olvasás a 4 bájtos SHTP fejléccel kezdődik (hossz, csatorna,
; sorszám). Először csak a fejlécet olvassuk, aztán a csomagot (a fejléccel
; együtt). A hosszú csomagot (bekapcsoláskori hirdetés) darabokban dobjuk el.
; Csak a "game rotation vector" jelentést kérjük (0x08): magnetométer nélküli
; szög, a motorok mágneses tere nem zavarja.

(defun bno-set-state (s) {
        (setq bno-state s)
        (setq bno-state-time (systime))
})

(defun bno-buf (n) { ; n bájtos olvasópuffer, méretenként egyszer foglalva
        (var b (assoc bno-bufs n))
        (if b b {
                (var nb (bufcreate n))
                (setq bno-bufs (acons n nb bno-bufs))
                nb
        })
})

(defun bno-send (buf ch) { ; SHTP fejléc kitöltése és küldés
        (var seq (if (= ch 1) bno-seq-exec bno-seq-ctrl))
        (bufset-u16 buf 0 (buflen buf) 'little-endian)
        (bufset-u8 buf 2 ch)
        (bufset-u8 buf 3 seq)
        (if (= ch 1)
            (setq bno-seq-exec (bitwise-and (+ seq 1) 255))
            (setq bno-seq-ctrl (bitwise-and (+ seq 1) 255)))
        (= (i2c-tx-rx bno-addr buf) 1)
})

(defun bno-reset () { ; szoftveres újraindítás: 1-es (executable) csatorna, 1-es parancs
        (bufset-u8 bno-tx-reset 4 1)
        (bno-send bno-tx-reset 1)
})

(defun bno-enable-report () { ; Set Feature: game rotation vector, bno-interval-ms időközzel
        (bufclear bno-tx-feat)
        (bufset-u8 bno-tx-feat 4 0xFD)
        (bufset-u8 bno-tx-feat 5 0x08)
        (bufset-u32 bno-tx-feat 9 (* bno-interval-ms 1000) 'little-endian)
        (bno-send bno-tx-feat 2)
})

(defun bno-quat (buf o) { ; i, j, k, valós rész (Q14, little-endian) -> fok
        (var x (/ (bufget-i16 buf o 'little-endian) 16384.0))
        (var y (/ (bufget-i16 buf (+ o 2) 'little-endian) 16384.0))
        (var z (/ (bufget-i16 buf (+ o 4) 'little-endian) 16384.0))
        (var w (/ (bufget-i16 buf (+ o 6) 'little-endian) 16384.0))
        (bno-sample
            (rad2deg (atan2 (* 2.0 (+ (* w x) (* y z))) (- 1.0 (* 2.0 (+ (* x x) (* y y))))))
            (rad2deg (asin (clamp (* 2.0 (- (* w y) (* z x))) -1.0 1.0)))
            (rad2deg (atan2 (* 2.0 (+ (* w z) (* x y))) (- 1.0 (* 2.0 (+ (* y y) (* z z)))))))
})

; 8 bájt: roll, pitch, yaw (0,01 fok, előjeles), állapot (1 = érvényes), számláló
(defun bno-sample (roll pitch yaw) {
        (setq bno-roll roll)
        (setq bno-pitch pitch)
        (setq bno-yaw yaw)
        (setq bno-time (systime))
        (setq bno-count (+ bno-count 1))
        (bufset-i16 imu-tx 0 (to-i (round (* roll 100.0))))
        (bufset-i16 imu-tx 2 (to-i (round (* pitch 100.0))))
        (bufset-i16 imu-tx 4 (to-i (round (* yaw 100.0))))
        (bufset-u8 imu-tx 6 1)
        (bufset-u8 imu-tx 7 (bitwise-and bno-count 255))
        (can-send-sid imu-sid imu-tx)
})

(defun bno-parse (buf len) { ; 3-as csatorna: időbélyegek és jelentések egymás után
        (var i 4)
        (loopwhile (< i len) {
                (var id (bufget-u8 buf i))
                (cond
                    ((or (= id 0xFB) (= id 0xFA)) (setq i (+ i 5)))   ; időbélyeg
                    ((= id 0x08) {                                     ; game rotation vector
                            (if (<= (+ i 12) len) (bno-quat buf (+ i 4)))
                            (setq i (+ i 12))
                    })
                    ((or (= id 0x05) (= id 0x09)) {                    ; rotation vector
                            (if (<= (+ i 14) len) (bno-quat buf (+ i 4)))
                            (setq i (+ i 14))
                    })
                    ((and (>= id 0x01) (<= id 0x06)) (setq i (+ i 10))) ; egyéb 3 tengelyes
                    (t (setq i len)))                                  ; ismeretlen: eldobjuk
        })
})

; Egy csomag olvasása. Visszatér: t = volt csomag, nil = nincs adat vagy hiba.
(defun bno-read () {
        (var hdr (bno-buf 4))
        (var len 0)
        (if (= (i2c-tx-rx bno-addr nil hdr) 1)
            (setq len (bitwise-and (bufget-u16 hdr 0 'little-endian) 0x7FFF)))
        (cond
            ((or (< len 5) (> len 1024)) nil)     ; 0 = nincs adat, 0x7FFF = hiba
            ((<= len 128) {
                    (var buf (bno-buf len))
                    (if (= (i2c-tx-rx bno-addr nil buf) 1) {
                            (var ch (bufget-u8 buf 2))
                            (if (or (= ch 3) (= ch 4)) (bno-parse buf len))
                            t
                        }
                        nil)
            })
            (t { ; hosszú csomag: darabokban eldobjuk (minden darab saját fejléccel)
                    (var rem (- len 128))
                    (i2c-tx-rx bno-addr nil (bno-buf 128))
                    (loopwhile (> rem 0) {
                            (var n (if (> (+ rem 4) 128) 128 (+ rem 4)))
                            (i2c-tx-rx bno-addr nil (bno-buf n))
                            (setq rem (- rem (- n 4)))
                    })
                    t
            }))
})

(defun bno-drain () { ; a várakozó csomagok kiolvasása (legfeljebb 20)
        (var k 0)
        (loopwhile (and (< k 20) (bno-read)) (setq k (+ k 1)))
})

(defun bno-restart () {
        (setq bno-restarts (+ bno-restarts 1))
        (setq bno-addr -1)
        (bno-set-state 'detect)
})

(defun bno-step () ; I2C mód, a BNO szálból
    (cond
        ((eq bno-state 'detect)
            (if (or bno-first (> (secs-since bno-state-time) 1.0)) {
                    (setq bno-first nil)
                    (if (not bno-i2c-on) {
                            (i2c-start bno-i2c-rate bno-sda bno-scl)
                            (setq bno-i2c-on t)
                    })
                    (setq bno-addr
                        (cond
                            ((i2c-detect-addr 0x4A) 0x4A)
                            ((i2c-detect-addr 0x4B) 0x4B)
                            (t -1)))
                    (if (>= bno-addr 0)
                        {
                            (bno-reset)
                            (bno-set-state 'boot)
                        }
                        (bno-set-state 'detect)) ; 1 s múlva újra
            }))
        ((eq bno-state 'boot) ; újraindulás után: hirdetés és üzenetek kiolvasása, majd a jelentés kérése
            (if (> (secs-since bno-state-time) 0.3) {
                    (bno-drain)
                    (if (> (secs-since bno-state-time) 0.8) {
                            (bno-enable-report)
                            (bno-set-state 'run)
                    })
            }))
        (t { ; 'run
                (var k 0)
                (loopwhile (and (< k 4) (bno-read)) (setq k (+ k 1)))
                ; 1 s-ig nincs minta: újraindítás
                (if (and (> (secs-since bno-state-time) 1.0) (> (secs-since bno-time) 1.0)) {
                        (trap (i2c-restore))
                        (bno-restart)
                })
        }))
)

(defun bno-thread ()
    (loopwhile t {
            (if (eq (car (trap (bno-step))) 'exit-error) (bno-restart))
            (sleep (/ bno-interval-ms 2000.0))
}))

; UART-RVC: 19 bájtos keret 100 Hz-en: AA AA, sorszám, yaw, pitch, roll
; (0,01 fok, little-endian), gyorsulás x, y, z (mg), 3 bájt, összeg
; (a sorszámtól a 3 bájtig a bájtok összege, alsó 8 bit).
(defun rvc-frame () {
        (uart-read-bytes rvc-buf 17 0)
        (var sum 0)
        (looprange i 0 16 (setq sum (+ sum (bufget-u8 rvc-buf i))))
        (if (= (bitwise-and sum 255) (bufget-u8 rvc-buf 16))
            (bno-sample
                (/ (bufget-i16 rvc-buf 5 'little-endian) 100.0)
                (/ (bufget-i16 rvc-buf 3 'little-endian) 100.0)
                (/ (bufget-i16 rvc-buf 1 'little-endian) 100.0)))
})

(defun rvc-loop () {
        (var prev 0)
        (loopwhile t {
                (uart-read-bytes rvc-one 1 0)
                (var b (bufget-u8 rvc-one 0))
                (if (and (= prev 0xAA) (= b 0xAA))
                    {
                        (setq prev 0)
                        (rvc-frame)
                    }
                    (setq prev b))
        })
})

(defun rvc-thread ()
    (loopwhile t {
            (trap (rvc-loop))
            (sleep 0.01)
}))

; REPL-ből hívható: (bno) - BNO085 állapot és szögek
(defun bno () {
        (print (list 'bno-enabled bno-enabled 'mod bno-mode 'allapot bno-state
                'cim bno-addr 'mintak bno-count 'ujrainditas bno-restarts
                'friss (bno-fresh)))
        (print (str-merge "roll " (str-from-n bno-roll "%.1f")
                "  pitch " (str-from-n bno-pitch "%.1f")
                "  yaw " (str-from-n bno-yaw "%.1f")))
})

(defun init () {
        (def ack (bufcreate 8))
        (def imu-tx (bufcreate 8))
        (def bno-tx-reset (bufcreate 5))
        (def bno-tx-feat (bufcreate 21))
        (def rvc-one (bufcreate 2))   ; uart-read-bytes: +1 bájt a záró 0-nak
        (def rvc-buf (bufcreate 18))
        (gpio-configure light-pin 'pin-mode-out)
        (gpio-write light-pin 0)
        (apply-limits 0 0 250 5) ; induláskor tiltva, amíg a hátsó nem szól
        (event-register-handler (spawn event-loop))
        (event-enable 'event-can-sid)
        (if bno-enabled
            (if (eq bno-mode 'rvc)
                {
                    (uart-start 115200)
                    (spawn 150 rvc-thread)
                }
                {
                    (bno-set-state 'detect)
                    (spawn 150 bno-thread)
                }))
})

(defun main () {
        (init)
        (loopwhile t {
                (watchdog-step)
                (sleep 0.1)
        })
})

@const-end

(image-save)
(main)
