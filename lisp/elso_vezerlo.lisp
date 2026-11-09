; =============================================================================
; Xiaomi M365 PRO 2 kijelző -> VESC 7.00  |  ELSŐ (slave) vezérlő
; Repo: https://github.com/JamesstudioV2/vesc-xiaomi-display
;
; A gázt és a féket a hátsó vezérlő ADC app-ja küldi CAN-en ("Multiple VESCs
; over CAN"). Ez a script a hátsó vezérlőtől kapott CAN üzenet alapján állítja
; az első motor korlátait:
;   1-es profil: hajtás kikapcsolva (áram-szorzó 0), fék a beállítás szerint
;   2-es profil: hajtás és fék be, ugyanazok a sebesség/watt/áram korlátok,
;                mint a hátsón
; Ha 1 másodpercig nem jön üzenet (vagy induláskor), az első motor tiltva van.
; =============================================================================

(def cmd-sid 0x4D0)   ; hátsó -> első (egyezzen a hátsó script front-cmd-sid értékével)
(def ack-sid 0x4D1)   ; első -> hátsó (front-ack-sid)
(def rx-timeout 1.0)  ; s

(def last-rx 0)
(def cur-flags -1)
(def cur-scale -1)
(def cur-kmh10 -1)
(def cur-watt100 -1)

@const-start

; flags: bit0 = hajtás, bit1 = fék; scale: %; kmh10: km/h*10; watt100: watt/100
(defun apply-limits (flags scale kmh10 watt100)
    (if (not (and (= flags cur-flags) (= scale cur-scale)
                (= kmh10 cur-kmh10) (= watt100 cur-watt100))) {
            (conf-set 'l-current-max-scale
                (if (= (bitwise-and flags 1) 1) (/ scale 100.0) 0.0))
            (conf-set 'l-current-min-scale
                (if (= (bitwise-and flags 2) 2) 1.0 0.0))
            (conf-set 'max-speed (/ (/ kmh10 10.0) 3.6))
            (conf-set 'l-watt-max (* watt100 100.0))
            (setq cur-flags flags)
            (setq cur-scale scale)
            (setq cur-kmh10 kmh10)
            (setq cur-watt100 watt100)
}))

(defun on-cmd (data)
    (if (and (>= (buflen data) 8) (= (bufget-u8 data 0) 0xA5)) {
            (setq last-rx (systime))
            (apply-limits (bufget-u8 data 1) (bufget-u8 data 2)
                (bufget-u16 data 3) (bufget-u16 data 5))
            (bufset-u8 ack 0 0xA5)
            (bufset-u8 ack 1 cur-flags)
            (bufset-u8 ack 2 cur-scale)
            (can-send-sid ack-sid ack)
}))

(defun event-loop ()
    (loopwhile t
        (recv
            ((event-can-sid . ((? id) . (? data)))
                (if (= id cmd-sid) (on-cmd data)))
            (_ nil)
)))

(defun watchdog-step ()
    (if (and (> (secs-since last-rx) rx-timeout) (not (= cur-flags 0)))
        (apply-limits 0 cur-scale cur-kmh10 cur-watt100))
)

(defun init () {
        (def ack (bufcreate 3))
        (apply-limits 0 0 250 5) ; induláskor tiltva, amíg a hátsó nem szól
        (event-register-handler (spawn event-loop))
        (event-enable 'event-can-sid)
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
