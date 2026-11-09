"""Small LispBM subset interpreter with a mocked VESC, for testing the scripts.

This is not LispBM. It implements only the forms the scripts in lisp/ use,
and it is strict on purpose: things that are probably bugs on the real
firmware (one-form bodies, setq on an unbound name, writing a float or an
out-of-range value into a byte buffer, indexing past the end of a buffer)
raise an error here instead of being silently accepted.
"""
import math
import re


class Symbol(str):
    pass


class LString(str):
    pass


class LispError(Exception):
    pass


class Blocked(Exception):
    """uart-read-bytes would block: no more simulated input."""


TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>;[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*")
  | (?P<open>[({\[])
  | (?P<close>[)}\]])
  | (?P<quote>')
  | (?P<atom>[^\s(){}\[\]'`,;"]+)
""", re.X)

INT = re.compile(r"^-?(0x[0-9a-fA-F]+|\d+)$")
FLOAT = re.compile(r"^-?(\d+\.\d*|\.\d+)$")


def read_all(text):
    toks = []
    pos = 0
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise LispError("cannot read near %r" % text[pos:pos + 30])
        if m.lastgroup not in ("ws", "comment"):
            toks.append((m.lastgroup, m.group(m.lastgroup)))
        pos = m.end()
    out = []
    i = 0

    def read(i):
        kind, val = toks[i]
        if kind == "open":
            if val == "[":
                raise LispError("byte array literals are not supported by the simulator")
            items = [Symbol("progn")] if val == "{" else []
            i += 1
            while toks[i][0] != "close":
                item, i = read(i)
                items.append(item)
            return items, i + 1
        if kind == "quote":
            item, i = read(i + 1)
            return [Symbol("quote"), item], i
        if kind == "string":
            return LString(bytes(val[1:-1], "utf-8").decode("unicode_escape")), i + 1
        if kind == "close":
            raise LispError("unexpected close")
        if INT.match(val):
            return int(val, 0), i + 1
        if FLOAT.match(val):
            return float(val), i + 1
        return Symbol(val), i + 1

    while i < len(toks):
        form, i = read(i)
        out.append(form)
    return out


def truthy(v):
    return not (v is None or v is False or (isinstance(v, list) and not v))


def lbool(b):
    return True if b else None


class Env:
    def __init__(self, parent=None):
        self.vars = {}
        self.parent = parent

    def find(self, name):
        e = self
        while e is not None:
            if name in e.vars:
                return e
            e = e.parent
        return None


class Closure:
    def __init__(self, name, params, body, env):
        self.name, self.params, self.body, self.env = name, params, body, env


def num(x):
    if isinstance(x, bool) or not isinstance(x, (int, float)):
        raise LispError("not a number: %r" % (x,))
    return x


class Vesc:
    """Mocked firmware state. Time is simulated, 10 kHz system ticks."""

    TICKS = 10000

    def __init__(self):
        self.now = 1.0
        self.speed_ms = 0.0
        self.adc = {0: 3.3, 1: 0.0, 2: 0.0}
        self.override = {0: 0.0, 1: 0.0}
        self.detached = None
        self.output_disabled = False
        self.conf = {
            "adc-v1-start": 0.8, "adc-v1-end": 2.0,
            "adc-v2-start": 0.8, "adc-v2-end": 2.0,
            "max-speed": 30.0, "l-watt-max": 1500000.0,
            "l-current-max-scale": 1.0, "l-current-min-scale": 1.0,
            "l-current-max": 60.0, "l-current-min": -60.0,
            "adc-ramp-time-pos": 0.3, "adc-ramp-time-neg": 0.1, "adc-thr-hyst": 0.0,
        }
        self.conf_log = []
        self.gpio_mode = {"pin-rx": "uart-af", "pin-tx": "uart-af"}
        self.gpio = {}
        self.gpio_in = {"pin-rx": 1}  # external level on input pins (button released = 1)
        self.uart_started = None
        self.rx = []
        self.tx = []
        self.can_tx = []
        self.can_devs = []
        self.batt = 0.5
        self.fault = 0
        self.temp_fet = 30.0
        self.temp_mot = 30.0
        self.can_temp_fet = {}
        self.can_temp_mot = {}
        self.printed = []
        self.events = []
        self.imu_rpy = [0.0, 0.0, 0.0]   # radians
        self.imu_acc = [0.0, 0.0, 1.0]   # g
        self.motor_current = None        # last set-current
        self.motor_brake = None          # last set-brake-rel
        self.can_cmds = []               # (kind, id, value) canset-* parancsok
        self.can_speed = {}              # id -> m/s (canget-speed)
        self.motor_log = []
        self.sleep_budget = None   # number of sleeps before Blocked is raised
        self.fail_temp = False     # get-temp-fet raises an error

    def out(self, pin):
        """Level actually driven on the pin: only an output drives its ODR value."""
        if self.gpio_mode.get(pin) != "pin-mode-out":
            return None
        return self.gpio.get(pin)

    def app_restart(self):
        """App type or servo output changed in VESC Tool: app_adc_start() sets the
        ADC pins to analog, pwm_servo_stop() sets the PPM pin to input."""
        self.gpio_mode["pin-adc1"] = "pin-mode-analog"
        self.gpio_mode["pin-adc2"] = "pin-mode-analog"
        self.gpio_mode["pin-ppm"] = "pin-mode-in"

    def decoded(self, ch):
        start = self.conf["adc-v1-start" if ch == 0 else "adc-v2-start"]
        end = self.conf["adc-v1-end" if ch == 0 else "adc-v2-end"]
        v = self.override[ch]
        d = (v - start) / (end - start)
        return min(1.0, max(0.0, d))


class Interp:
    def __init__(self, vesc=None):
        self.vesc = vesc or Vesc()
        self.g = Env()
        self.special = {
            "quote": self.f_quote, "if": self.f_if, "cond": self.f_cond,
            "and": self.f_and, "or": self.f_or, "progn": self.f_progn,
            "var": self.f_var, "def": self.f_def, "define": self.f_def,
            "defun": self.f_defun, "setq": self.f_setq,
            "loopwhile": self.f_loopwhile, "looprange": self.f_looprange,
            "loopforeach": self.f_loopforeach, "trap": self.f_trap,
            "recv": self.f_recv,
        }
        self.builtins = self.make_builtins()

    # ---------------------------------------------------------------- loading
    def load(self, path, skip_top=("main", "image-save")):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for form in read_all(text):
            if isinstance(form, Symbol) and form.startswith("@const"):
                continue
            if isinstance(form, list) and form and form[0] in skip_top and len(form) == 1:
                continue
            self.eval(form, self.g)

    def call(self, name, *args):
        return self.apply(self.eval(Symbol(name), self.g), list(args))

    def get(self, name):
        return self.g.vars[name]

    def set(self, name, value):
        self.g.vars[name] = value

    def run(self, code):
        res = None
        for form in read_all(code):
            res = self.eval(form, self.g)
        return res

    # ------------------------------------------------------------------- eval
    def eval(self, x, env):
        if isinstance(x, Symbol):
            if x in ("nil", "false"):
                return None
            if x in ("t", "true"):
                return True
            e = env.find(x)
            if e is not None:
                return e.vars[x]
            if x in self.builtins:
                return self.builtins[x]
            raise LispError("variable_not_bound: %s" % x)
        if isinstance(x, (int, float, LString)):
            return x
        if isinstance(x, list):
            if not x:
                return None
            head = x[0]
            if isinstance(head, Symbol) and head in self.special:
                return self.special[head](x, env)
            f = self.eval(head, env)
            return self.apply(f, [self.eval(a, env) for a in x[1:]])
        raise LispError("cannot eval %r" % (x,))

    def apply(self, f, args):
        if isinstance(f, Closure):
            if len(args) != len(f.params):
                raise LispError("%s: expected %d args, got %d" % (f.name, len(f.params), len(args)))
            env = Env(f.env)
            env.vars.update(zip(f.params, args))
            return self.eval(f.body, env)
        if callable(f):
            return f(*args)
        raise LispError("not a function: %r" % (f,))

    # ---------------------------------------------------------- special forms
    def f_quote(self, x, env):
        return x[1]

    def f_if(self, x, env):
        if len(x) not in (3, 4):
            raise LispError("if takes 2 or 3 arguments: %r" % (x,))
        if truthy(self.eval(x[1], env)):
            return self.eval(x[2], env)
        return self.eval(x[3], env) if len(x) == 4 else None

    def f_cond(self, x, env):
        for clause in x[1:]:
            if len(clause) != 2:
                raise LispError("cond clause must be (test expr): %r" % (clause,))
            if truthy(self.eval(clause[0], env)):
                return self.eval(clause[1], env)
        return None

    def f_and(self, x, env):
        v = True
        for a in x[1:]:
            v = self.eval(a, env)
            if not truthy(v):
                return None
        return v

    def f_or(self, x, env):
        for a in x[1:]:
            v = self.eval(a, env)
            if truthy(v):
                return v
        return None

    def f_progn(self, x, env):
        local = Env(env)
        res = None
        for a in x[1:]:
            res = self.eval(a, local)
        return res

    def f_var(self, x, env):
        env.vars[x[1]] = self.eval(x[2], env)
        return env.vars[x[1]]

    def f_def(self, x, env):
        self.g.vars[x[1]] = self.eval(x[2], env)
        return self.g.vars[x[1]]

    def f_defun(self, x, env):
        if len(x) != 4:
            raise LispError("defun %s must have exactly one body form" % x[1])
        self.g.vars[x[1]] = Closure(x[1], list(x[2]), x[3], self.g)
        return self.g.vars[x[1]]

    def f_setq(self, x, env):
        e = env.find(x[1])
        if e is None:
            raise LispError("setq on unbound variable %s" % x[1])
        e.vars[x[1]] = self.eval(x[2], env)
        return e.vars[x[1]]

    def f_loopwhile(self, x, env):
        while truthy(self.eval(x[1], env)):
            self.eval(x[2], env)
        return None

    def f_looprange(self, x, env):
        start, end = self.eval(x[2], env), self.eval(x[3], env)
        for i in range(start, end):
            local = Env(env)
            local.vars[x[1]] = i
            self.eval(x[4], local)
        return None

    def f_loopforeach(self, x, env):
        for item in self.eval(x[2], env) or []:
            local = Env(env)
            local.vars[x[1]] = item
            self.eval(x[3], local)
        return None

    def f_trap(self, x, env):
        try:
            return [Symbol("exit-ok"), self.eval(x[1], env)]
        except LispError as e:
            return [Symbol("exit-error"), str(e)]

    def f_recv(self, x, env):
        raise LispError("recv is not simulated, call the handler directly")

    # --------------------------------------------------------------- builtins
    def make_builtins(self):
        v = self.vesc

        def arith(op):
            def f(*a):
                for n in a:
                    num(n)
                return op(a)
            return f

        def add(a):
            return sum(a)

        def sub(a):
            return -a[0] if len(a) == 1 else a[0] - sum(a[1:])

        def mul(a):
            r = 1
            for n in a:
                r = r * n
            return r

        def div(a):
            r = a[0]
            for n in a[1:]:
                if n == 0:
                    raise LispError("division_by_zero")
                if isinstance(r, int) and isinstance(n, int):
                    r = int(r / n)  # C truncation
                else:
                    r = r / n
            return r

        def cmp(op):
            return lambda a, b: lbool(op(num(a), num(b)))

        def to_i(x):
            return int(num(x))

        def c_round(x):
            x = num(x)
            return float(math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5))

        def need_int(x, lo, hi, what):
            if not isinstance(x, int) or isinstance(x, bool):
                raise LispError("%s: value must be an integer, got %r" % (what, x))
            if not lo <= x <= hi:
                raise LispError("%s: value %d out of range" % (what, x))
            return x

        def need_idx(buf, i, n, what):
            if not isinstance(buf, bytearray):
                raise LispError("%s: not a buffer" % what)
            if not isinstance(i, int) or i < 0 or i + n > len(buf):
                raise LispError("%s: index %r out of bounds (len %d)" % (what, i, len(buf)))

        def bufset_u8(buf, i, x):
            need_idx(buf, i, 1, "bufset-u8")
            buf[i] = need_int(x, 0, 255, "bufset-u8")
            return True

        def bufset_u16(buf, i, x):
            need_idx(buf, i, 2, "bufset-u16")
            x = need_int(x, 0, 65535, "bufset-u16")
            buf[i], buf[i + 1] = x >> 8, x & 0xFF
            return True

        def bufget_u8(buf, i):
            need_idx(buf, i, 1, "bufget-u8")
            return buf[i]

        def bufget_u16(buf, i):
            need_idx(buf, i, 2, "bufget-u16")
            return (buf[i] << 8) | buf[i + 1]

        def str_from_n(n, fmt):
            if "%d" in fmt:
                return LString(fmt.replace("%d", str(int(n))))
            return LString(fmt % n)

        def systime():
            return int(round(v.now * Vesc.TICKS))

        def secs_since(t):
            return (systime() - t) / Vesc.TICKS

        def sleep(s):
            if v.sleep_budget is not None:
                if v.sleep_budget <= 0:
                    raise Blocked()
                v.sleep_budget -= 1
            v.now += s
            return True

        def uart_read_bytes(buf, n, ofs):
            if len(v.rx) < n:
                raise Blocked()
            for k in range(n):
                bufset_u8(buf, ofs + k, v.rx.pop(0))
            bufset_u8(buf, ofs + n, 0)  # the firmware writes a terminating 0
            return True

        def uart_write(buf):
            v.tx.append(bytes(buf))
            return True

        def conf_set(name, val):
            num(val)
            v.conf[name] = val
            v.conf_log.append((name, val))
            return True

        def conf_get(name):
            if name not in v.conf:
                raise LispError("conf-get: %s not mocked" % name)
            return v.conf[name]

        def app_adc_override(ch, val):
            v.override[need_int(ch, 0, 1, "app-adc-override")] = float(num(val))
            return True

        def app_disable_output(ms):
            v.output_disabled = (ms != 0)
            return True

        def can_send_sid(sid, data):
            v.can_tx.append((sid, bytes(data)))
            return True

        def gpio_configure(pin, mode):
            v.gpio_mode[pin] = mode
            return True

        def gpio_write(pin, val):
            if pin not in v.gpio_mode:
                raise LispError("gpio-write to %s which was never configured" % pin)
            v.gpio[pin] = need_int(val, 0, 1, "gpio-write")  # ODR, see Vesc.out()
            return True

        def uart_start(*a):
            # half-duplex: only TX is set to the UART function, RX is left alone
            v.uart_started = a
            v.gpio_mode["pin-tx"] = "uart-af"
            if "half-duplex" not in a:
                v.gpio_mode["pin-rx"] = "uart-af"
            return True

        def gpio_read(pin):
            if pin in v.gpio_in:
                return v.gpio_in[pin]
            return v.gpio.get(pin, 0)

        def set_current(amps, off_delay=None):
            v.motor_current = float(num(amps))
            v.motor_brake = None
            v.motor_log.append((v.now, v.motor_current))
            return True

        def set_brake_rel(x):
            v.motor_brake = float(num(x))
            v.motor_current = None
            return True

        def can_cmd(kind):
            def f(i, x, off_delay=None):
                v.can_cmds.append((kind, i, float(num(x))))
                return True
            return f

        def throttle_curve(val, acc, brk, mode):  # VESC utils_throttle_curve
            val = max(-1.0, min(1.0, num(val)))
            a = abs(val)
            c = acc if val >= 0 else brk
            if mode == 0:
                r = 1.0 - (1.0 - a) ** (1.0 + c) if c >= 0 else a ** (1.0 - c)
            elif mode == 1:
                if abs(c) < 1e-10:
                    r = a
                elif c >= 0:
                    r = 1.0 - ((math.exp(c * (1.0 - a)) - 1.0) / (math.exp(c) - 1.0))
                else:
                    r = (math.exp(-c * a) - 1.0) / (math.exp(-c) - 1.0)
            elif mode == 2:
                r = 1.0 - ((1.0 - a) / (1.0 + c * a)) if c >= 0 else a / (1.0 - c * (1.0 - a))
            else:
                r = a
            return -r if val < 0 else r

        def get_temp_fet():
            if v.fail_temp:
                raise LispError("eval_error (injected)")
            return v.temp_fet

        def show(*a):
            v.printed.append(a)
            return True

        return {
            "+": arith(add), "-": arith(sub), "*": arith(mul), "/": arith(div),
            "=": cmp(lambda a, b: a == b), "<": cmp(lambda a, b: a < b),
            ">": cmp(lambda a, b: a > b), "<=": cmp(lambda a, b: a <= b),
            ">=": cmp(lambda a, b: a >= b),
            "not": lambda a: lbool(not truthy(a)),
            "eq": lambda a, b: lbool(a == b),
            "list": lambda *a: list(a),
            "car": lambda lst: lst[0] if lst else None,
            "cdr": lambda lst: lst[1:] if lst else None,
            "ix": lambda lst, i: lst[i],
            "length": lambda lst: len(lst or []),
            "abs": lambda x: abs(num(x)),
            "round": c_round, "to-i": to_i,
            "bitwise-and": lambda a, b: num(a) & num(b),
            "bitwise-xor": lambda a, b: num(a) ^ num(b),
            "shl": lambda a, b: num(a) << num(b),
            "shr": lambda a, b: num(a) >> num(b),
            "bufcreate": lambda n: bytearray(n),
            "buflen": lambda b: len(b),
            "bufset-u8": bufset_u8, "bufset-u16": bufset_u16,
            "bufget-u8": bufget_u8, "bufget-u16": bufget_u16,
            "str-merge": lambda *a: LString("".join(a)),
            "str-from-n": str_from_n,
            "print": show,
            "systime": systime, "secs-since": secs_since, "sleep": sleep,
            "spawn": lambda *a: True,
            "event-register-handler": lambda *a: True,
            "event-enable": lambda *a: v.events.append(a) or True,
            "uart-start": uart_start,
            "uart-read-bytes": uart_read_bytes, "uart-write": uart_write,
            "get-speed": lambda: v.speed_ms,
            "get-adc": lambda ch: v.adc[ch],
            "get-adc-decoded": lambda ch: v.decoded(ch),
            "app-adc-detach": lambda m, s: setattr(v, "detached", (m, s)) or True,
            "app-adc-override": app_adc_override,
            "app-disable-output": app_disable_output,
            "conf-set": conf_set, "conf-get": conf_get,
            "gpio-configure": gpio_configure, "gpio-write": gpio_write,
            "gpio-read": gpio_read,
            "can-send-sid": can_send_sid,
            "can-list-devs": lambda: list(v.can_devs),
            "canget-temp-fet": lambda i: v.can_temp_fet.get(i, 0.0),
            "canget-temp-motor": lambda i: v.can_temp_mot.get(i, 0.0),
            "get-temp-fet": get_temp_fet,
            "get-imu-rpy": lambda: list(v.imu_rpy),
            "get-imu-acc": lambda: list(v.imu_acc),
            "rad2deg": lambda x: math.degrees(num(x)),
            "set-current": set_current,
            "set-brake-rel": set_brake_rel,
            "canset-current-rel": can_cmd("current-rel"),
            "canset-current": can_cmd("current"),
            "canset-brake-rel": can_cmd("brake-rel"),
            "canget-speed": lambda i: v.can_speed.get(i, v.speed_ms),
            "throttle-curve": throttle_curve,
            "bitwise-or": lambda a, b: num(a) | num(b),
            "get-temp-mot": lambda: v.temp_mot,
            "get-batt": lambda: v.batt,
            "get-fault": lambda: v.fault,
        }


def xiaomi_frame(addr, cmd, arg, payload):
    """55 AA len addr cmd arg payload crc_lo crc_hi"""
    body = [len(payload) + 2, addr, cmd, arg] + list(payload)
    crc = (sum(body) ^ 0xFFFF) & 0xFFFF
    return [0x55, 0xAA] + body + [crc & 0xFF, crc >> 8]


def check_xiaomi_crc(frame):
    body = frame[2:-2]
    crc = (sum(body) ^ 0xFFFF) & 0xFFFF
    return frame[-2] == crc & 0xFF and frame[-1] == crc >> 8
