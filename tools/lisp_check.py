#!/usr/bin/env python3
"""Static checker for the LispBM scripts in this repo.

It does not run the code. It checks:
  * balanced (), {} and [] (strings and ; comments are skipped),
  * every symbol is either defined in the file (def/define/defun/var/
    parameters/loop variables/recv pattern variables) or exists in
    VESC firmware 7.00 (LispBM core + VESC extensions),
  * the quoted names passed to conf-set/conf-get, gpio-*, event-enable
    are names the firmware actually knows.

Usage:
  python3 tools/lisp_check.py lisp/*.lisp
  python3 tools/lisp_check.py --gen /path/to/bldc   # regenerate the symbol list
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SYMFILE = os.path.join(HERE, "fw7_00_symbols.txt")


def gen_symbols(bldc):
    funcs, consts = set(), set()
    src_dirs = [
        os.path.join(bldc, "lispBM"),
        os.path.join(bldc, "lispBM", "lispBM", "src"),
        os.path.join(bldc, "lispBM", "lispBM", "src", "extensions"),
    ]
    for d in src_dirs:
        for name in sorted(os.listdir(d)):
            if not name.endswith(".c"):
                continue
            text = open(os.path.join(d, name), encoding="utf-8", errors="replace").read()
            funcs.update(re.findall(r'lbm_add_extension\("([^"]+)"', text))
            consts.update(re.findall(r'lbm_add_symbol_const\("([^"]+)"', text))
            consts.update(re.findall(r'lbm_add_symbol\("([^"]+)"', text))
            if name == "symrepr.c":
                funcs.update(re.findall(r'\{"([^"]+)"\s*,\s*SYM_', text))
            # functions the firmware defines in Lisp and loads on first use
            funcs.update(re.findall(r'"\((?:define|defun) ([^ ()",]+)', text))
    with open(SYMFILE, "w") as f:
        f.write("# Generated from VESC bldc firmware 7.00 sources by lisp_check.py --gen\n")
        for s in sorted(funcs):
            f.write("F %s\n" % s)
        for s in sorted(consts - funcs):
            f.write("C %s\n" % s)
    print("wrote %d functions, %d constants to %s" % (len(funcs), len(consts - funcs), SYMFILE))


def load_symbols():
    funcs, consts = set(), set()
    for line in open(SYMFILE):
        if line.startswith("F "):
            funcs.add(line[2:].strip())
        elif line.startswith("C "):
            consts.add(line[2:].strip())
    return funcs, consts


TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<comment>;[^\n]*)
  | (?P<string>"(?:\\.|[^"\\])*")
  | (?P<char>\\\#\S)
  | (?P<open>[({\[])
  | (?P<close>[)}\]])
  | (?P<quote>,@|['`,])
  | (?P<atom>[^\s(){}\[\]'`,;"]+)
""", re.X)

PAIRS = {"(": ")", "{": "}", "[": "]"}


def tokenize(text, errors, path):
    pos, line = 0, 1
    toks = []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            errors.append("%s:%d: unreadable text %r" % (path, line, text[pos:pos + 20]))
            break
        kind = m.lastgroup
        val = m.group(kind)
        if kind not in ("ws", "comment"):
            toks.append((kind, val, line))
        line += val.count("\n")
        pos = m.end()
    return toks


def parse(toks, errors, path):
    """Build nested lists; quoted forms become ('quote', form)."""
    stack = [[]]
    opens = []
    pending_quote = [[]]
    for kind, val, line in toks:
        if kind == "open":
            stack.append([])
            opens.append((val, line))
            pending_quote.append([])
            continue
        if kind == "close":
            if not opens:
                errors.append("%s:%d: extra '%s'" % (path, line, val))
                continue
            o, oline = opens.pop()
            if PAIRS[o] != val:
                errors.append("%s:%d: '%s' opened on line %d closed with '%s'" % (path, line, o, oline, val))
            form = ("list" if o != "[" else "array", stack.pop(), oline)
            pending_quote.pop()
            item = form
        elif kind == "quote":
            pending_quote[-1].append(val)
            continue
        elif kind == "string":
            item = ("string", val, line)
        elif kind == "atom":
            item = ("atom", val, line)
        else:
            item = ("char", val, line)
        while pending_quote[-1]:
            q = pending_quote[-1].pop()
            item = ("quote", q, item, line)
        stack[-1].append(item)
    for o, oline in opens:
        errors.append("%s:%d: '%s' is never closed" % (path, oline, o))
    return stack[0]


NUM = re.compile(r"^[-+]?(0x[0-9a-fA-F]+|\d+\.?\d*(e[-+]?\d+)?|\.\d+)(i32|u32|i64|u64|f32|f64|b|u|i)?$")


def atom_name(node):
    return node[1] if node[0] == "atom" else None


def collect_defs(forms, defs):
    """Names bound anywhere in the file (good enough for a flat script)."""
    for node in forms:
        if node[0] in ("list", "array"):
            items = node[1]
            head = atom_name(items[0]) if items else None
            if head in ("def", "define", "defun", "defunret", "defmacro", "var",
                        "looprange", "loopforeach", "loopfor") and len(items) > 1:
                n = atom_name(items[1])
                if n:
                    defs.add(n)
            if head in ("defun", "defunret", "defmacro", "lambda", "fn") and len(items) > 2:
                params = items[2] if head in ("defun", "defunret", "defmacro") else items[1]
                if params[0] == "list":
                    for p in params[1]:
                        if atom_name(p):
                            defs.add(atom_name(p))
            if head == "let" and len(items) > 1 and items[1][0] == "list":
                for b in items[1][1]:
                    if b[0] == "list" and b[1] and atom_name(b[1][0]):
                        defs.add(atom_name(b[1][0]))
            if head == "?" and len(items) > 1 and atom_name(items[1]):
                defs.add(atom_name(items[1]))
            collect_defs(items, defs)
        elif node[0] == "quote":
            collect_defs([node[2]], defs)


QUOTED_ARG_FUNCS = {
    "conf-set": [0], "conf-get": [0],
    "gpio-configure": [0, 1], "gpio-write": [0], "gpio-read": [0],
    "event-enable": [0],
}


def check_uses(forms, defs, funcs, consts, errors, path, in_quote=False):
    for node in forms:
        kind = node[0]
        if kind == "atom":
            name = node[1]
            if in_quote or NUM.match(name) or name in defs or name in funcs or name in consts:
                continue
            if name.startswith("@const"):
                continue
            errors.append("%s:%d: unknown symbol '%s'" % (path, node[2], name))
        elif kind in ("list", "array"):
            items = node[1]
            head = atom_name(items[0]) if items else None
            if head in QUOTED_ARG_FUNCS and not in_quote:
                for idx in QUOTED_ARG_FUNCS[head]:
                    if idx + 1 < len(items):
                        arg = items[idx + 1]
                        if arg[0] == "quote" and arg[2][0] == "atom":
                            sym = arg[2][1]
                            if sym not in consts and sym not in funcs:
                                errors.append("%s:%d: '%s' does not know '%s"
                                              % (path, arg[3], head, sym))
            # recv clauses: the pattern part is data, only the body is code
            if head == "recv" and not in_quote:
                for clause in items[1:]:
                    if clause[0] == "list" and clause[1]:
                        check_uses(clause[1][1:], defs, funcs, consts, errors, path, in_quote)
                continue
            check_uses(items, defs, funcs, consts, errors, path, in_quote)
        elif kind == "quote":
            q = node[1]
            # a pin name kept in a variable, e.g. (def button-pin 'pin-rx)
            if (q == "'" and node[2][0] == "atom" and node[2][1].startswith("pin-")
                    and node[2][1] not in consts):
                errors.append("%s:%d: unknown pin name '%s" % (path, node[3], node[2][1]))
            if q == "`":
                # quasiquote: only , and ,@ parts are code
                check_uses([node[2]], defs, funcs, consts, errors, path, True)
            elif q in (",", ",@"):
                check_uses([node[2]], defs, funcs, consts, errors, path, False)
            else:
                check_uses([node[2]], defs, funcs, consts, errors, path, True)


def main(argv):
    if len(argv) >= 2 and argv[0] == "--gen":
        gen_symbols(argv[1])
        return 0
    funcs, consts = load_symbols()
    total = 0
    for path in argv:
        errors = []
        text = open(path, encoding="utf-8").read()
        toks = tokenize(text, errors, path)
        forms = parse(toks, errors, path)
        defs = set()
        collect_defs(forms, defs)
        fw_lower = {f.lower() for f in funcs}
        for name in sorted(defs):
            if name.lower() in fw_lower:  # LispBM symbols are case-insensitive
                errors.append("%s: '%s' shadows a firmware function" % (path, name))
        check_uses(forms, defs, funcs, consts, errors, path)
        for e in errors:
            print(e)
        print("%s: %d problem(s)" % (path, len(errors)))
        total += len(errors)
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
