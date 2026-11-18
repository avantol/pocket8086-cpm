#!/usr/bin/env python3
"""Small two-pass Intel 8080 assembler accepting Digital Research ASM syntax.

Usage: asm8080.py source.asm out.bin [-D NAME=VALUE ...] [--lst out.lst] [--sym out.sym]

The output binary starts at the first ORG address and extends to the highest
byte emitted.  Extra pseudo-op: CALLN n  (NEC V20/V30 'call native', ED ED n).
"""
import re
import sys

REG8 = {'B': 0, 'C': 1, 'D': 2, 'E': 3, 'H': 4, 'L': 5, 'M': 6, 'A': 7}
RP_SP = {'B': 0, 'D': 1, 'H': 2, 'SP': 3}
RP_PSW = {'B': 0, 'D': 1, 'H': 2, 'PSW': 3}

NOARG = {
    'NOP': 0x00, 'RLC': 0x07, 'RRC': 0x0F, 'RAL': 0x17, 'RAR': 0x1F,
    'SHLD': None, 'DAA': 0x27, 'CMA': 0x2F, 'STC': 0x37, 'CMC': 0x3F,
    'HLT': 0x76, 'RNZ': 0xC0, 'RZ': 0xC8, 'RET': 0xC9, 'RNC': 0xD0,
    'RC': 0xD8, 'RPO': 0xE0, 'XTHL': 0xE3, 'RPE': 0xE8, 'PCHL': 0xE9,
    'XCHG': 0xEB, 'RP': 0xF0, 'DI': 0xF3, 'RM': 0xF8, 'SPHL': 0xF9,
    'EI': 0xFB,
}
del NOARG['SHLD']
IMM8 = {'ADI': 0xC6, 'ACI': 0xCE, 'SUI': 0xD6, 'SBI': 0xDE, 'ANI': 0xE6,
        'XRI': 0xEE, 'ORI': 0xF6, 'CPI': 0xFE, 'OUT': 0xD3, 'IN': 0xDB}
ADDR16 = {'SHLD': 0x22, 'LHLD': 0x2A, 'STA': 0x32, 'LDA': 0x3A,
          'JNZ': 0xC2, 'JMP': 0xC3, 'CNZ': 0xC4, 'JZ': 0xCA, 'CZ': 0xCC,
          'CALL': 0xCD, 'JNC': 0xD2, 'CNC': 0xD4, 'JC': 0xDA, 'CC': 0xDC,
          'JPO': 0xE2, 'CPO': 0xE4, 'JPE': 0xEA, 'CPE': 0xEC, 'JP': 0xF2,
          'CP': 0xF4, 'JM': 0xFA, 'CM': 0xFC}
ALU = {'ADD': 0x80, 'ADC': 0x88, 'SUB': 0x90, 'SBB': 0x98, 'ANA': 0xA0,
       'XRA': 0xA8, 'ORA': 0xB0, 'CMP': 0xB8}


class AsmError(Exception):
    pass


# ---------------------------------------------------------------- expressions
TOKEN_RE = re.compile(r"""
    \s*(?:
      (?P<str>'(?:[^']|'')*')             |
      (?P<num>[0-9][0-9A-Fa-f]*[HhOoQqBbDd]?) |
      (?P<id>[A-Za-z_?@.][A-Za-z0-9_?@.$]*)  |
      (?P<dollar>\$)                      |
      (?P<op>[-+*/()])
    )""", re.X)

WORD_OPS = {'MOD', 'SHL', 'SHR', 'NOT', 'AND', 'OR', 'XOR', 'HIGH', 'LOW'}


def parse_number(text):
    t = text.upper()
    try:
        if t.endswith('H'):
            return int(t[:-1], 16)
        if t.endswith('O') or t.endswith('Q'):
            return int(t[:-1], 8)
        if t.endswith('B') and re.fullmatch(r'[01]+B', t):
            return int(t[:-1], 2)
        if t.endswith('D') and re.fullmatch(r'[0-9]+D', t):
            return int(t[:-1], 10)
        return int(t, 10)
    except ValueError:
        raise AsmError('bad number %r' % text)


class Expr:
    def __init__(self, asm, text):
        self.asm = asm
        self.toks = []
        pos = 0
        text = text.strip()
        while pos < len(text):
            m = TOKEN_RE.match(text, pos)
            if not m or m.end() == pos:
                if text[pos:].strip() == '':
                    break
                raise AsmError('bad expression %r' % text)
            pos = m.end()
            if m.group('str') is not None:
                s = m.group('str')[1:-1].replace("''", "'")
                if len(s) == 1:
                    self.toks.append(('num', ord(s)))
                elif len(s) == 2:
                    self.toks.append(('num', (ord(s[0]) << 8) | ord(s[1])))
                else:
                    raise AsmError('string in expression %r' % text)
            elif m.group('num') is not None:
                self.toks.append(('num', parse_number(m.group('num'))))
            elif m.group('id') is not None:
                u = m.group('id').upper()
                if u in WORD_OPS:
                    self.toks.append(('op', u))
                else:
                    self.toks.append(('id', u))
            elif m.group('dollar') is not None:
                self.toks.append(('num', asm.pc))
            else:
                self.toks.append(('op', m.group('op')))
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self):
        t = self.peek()
        self.i += 1
        return t

    def value(self):
        v = self.p_or()
        if self.i != len(self.toks):
            raise AsmError('junk in expression')
        return v & 0xFFFF

    def p_or(self):
        v = self.p_and()
        while self.peek() in (('op', 'OR'), ('op', 'XOR')):
            op = self.take()[1]
            r = self.p_and()
            v = (v | r) if op == 'OR' else (v ^ r)
        return v

    def p_and(self):
        v = self.p_not()
        while self.peek() == ('op', 'AND'):
            self.take()
            v &= self.p_not()
        return v

    def p_not(self):
        if self.peek() == ('op', 'NOT'):
            self.take()
            return (~self.p_not()) & 0xFFFF
        return self.p_add()

    def p_add(self):
        v = self.p_mul()
        while self.peek() in (('op', '+'), ('op', '-')):
            op = self.take()[1]
            r = self.p_mul()
            v = (v + r) if op == '+' else (v - r)
        return v & 0xFFFF

    def p_mul(self):
        v = self.p_unary()
        while self.peek() in (('op', '*'), ('op', '/'), ('op', 'MOD'),
                              ('op', 'SHL'), ('op', 'SHR')):
            op = self.take()[1]
            r = self.p_unary()
            if op == '*':
                v = v * r
            elif op in ('/', 'MOD'):
                if r == 0:
                    if self.asm.final:
                        raise AsmError('division by zero')
                    v = 0
                else:
                    v = v // r if op == '/' else v % r
            elif op == 'SHL':
                v = v << r
            else:
                v = v >> r
            v &= 0xFFFF
        return v

    def p_unary(self):
        t = self.peek()
        if t == ('op', '-'):
            self.take()
            return (-self.p_unary()) & 0xFFFF
        if t == ('op', '+'):
            self.take()
            return self.p_unary()
        if t == ('op', 'HIGH'):
            self.take()
            return (self.p_unary() >> 8) & 0xFF
        if t == ('op', 'LOW'):
            self.take()
            return self.p_unary() & 0xFF
        return self.p_atom()

    def p_atom(self):
        kind, val = self.take()
        if kind == 'num':
            return val
        if kind == 'id':
            if val in self.asm.symbols:
                return self.asm.symbols[val]
            if val in REG8 or val in ('SP', 'PSW'):
                return {'B': 0, 'C': 1, 'D': 2, 'E': 3, 'H': 4, 'L': 5,
                        'M': 6, 'A': 7, 'SP': 6, 'PSW': 6}[val]
            if self.asm.final:
                raise AsmError('undefined symbol %s' % val)
            self.asm.unresolved = True
            return 0
        if (kind, val) == ('op', '('):
            v = self.p_or()
            if self.take() != ('op', ')'):
                raise AsmError('missing )')
            return v
        raise AsmError('unexpected token %r' % (val,))


# ---------------------------------------------------------------- line split
def split_operands(text):
    """Split an operand field on commas that are not inside quotes."""
    out, cur, q = [], '', False
    for ch in text:
        if ch == "'":
            q = not q
            cur += ch
        elif ch == ',' and not q:
            out.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip() or out:
        out.append(cur.strip())
    return out


def strip_comment(line):
    q = False
    for i, ch in enumerate(line):
        if ch == "'":
            q = not q
        elif ch == ';' and not q:
            return line[:i]
    return line


def split_statements(line):
    """DR ASM allows '!' as a statement separator."""
    out, cur, q = [], '', False
    for ch in line:
        if ch == "'":
            q = not q
        if ch == '!' and not q:
            out.append(cur)
            cur = ' '          # following statements have no label
        else:
            cur += ch
    out.append(cur)
    return out


LABEL_RE = re.compile(r'^([A-Za-z_?@.][A-Za-z0-9_?@.$]*):?')


class Assembler:
    def __init__(self, defines=None):
        self.symbols = dict(defines or {})
        self.predef = dict(defines or {})

    def assemble(self, lines):
        self.lines = lines
        prev = None
        for _ in range(6):
            self.final = False
            self.run_pass()
            snap = dict(self.symbols)
            if snap == prev:
                break
            prev = snap
        self.final = True
        self.run_pass()
        return self

    def define(self, name, value, redefinable=False):
        name = name.upper()
        if self.final and name in self.symbols and self.symbols[name] != value \
                and name not in self.setsyms:
            raise AsmError('symbol %s changed value in final pass' % name)
        if not redefinable and name in self.defined_this_pass:
            raise AsmError('duplicate symbol %s' % name)
        self.defined_this_pass.add(name)
        if redefinable:
            self.setsyms.add(name)
        self.symbols[name] = value & 0xFFFF

    def run_pass(self):
        self.pc = 0
        self.mem = {}
        self.listing = []
        self.defined_this_pass = set(self.predef)
        self.setsyms = set()
        self.cond = [True]
        self.ended = False
        for lineno, raw in enumerate(self.lines, 1):
            if self.ended:
                break
            try:
                for st in split_statements(strip_comment(raw.rstrip('\n'))):
                    self.statement(st)
            except AsmError as e:
                if self.final:
                    raise AsmError('line %d: %s\n    %s' % (lineno, e, raw.rstrip()))

    def ev(self, text):
        self.unresolved = False
        return Expr(self, text).value()

    def emit(self, *bs):
        for b in bs:
            if self.pc in self.mem and self.final:
                raise AsmError('overlapping output at %04X' % self.pc)
            self.mem[self.pc] = b & 0xFF
            self.pc = (self.pc + 1) & 0xFFFF

    def statement(self, st):
        if not st.strip():
            return
        label = None
        if st[0] not in ' \t':
            m = LABEL_RE.match(st)
            if not m:
                raise AsmError('bad label')
            label = m.group(1).upper()
            st = st[m.end():]
        parts = st.strip().split(None, 1)
        op = parts[0].upper() if parts else ''
        args = parts[1].strip() if len(parts) > 1 else ''

        # conditional assembly
        if op == 'IF':
            self.cond.append(self.cond[-1] and self.ev(args) != 0)
            return
        if op == 'ELSE':
            top = self.cond.pop()
            self.cond.append(self.cond[-1] and not top)
            return
        if op == 'ENDIF':
            self.cond.pop()
            return
        if not self.cond[-1]:
            return

        if op in ('EQU', 'SET'):
            if not label:
                raise AsmError('%s needs a label' % op)
            self.define(label, self.ev(args), redefinable=(op == 'SET'))
            return
        if label:
            self.define(label, self.pc)
        if not op:
            return
        if op == 'ORG':
            self.pc = self.ev(args)
            return
        if op == 'END':
            self.ended = True
            return
        if op in ('TITLE', 'PAGE', 'MACLIB', 'NAME', 'EJECT'):
            return
        if op == 'DS':
            self.pc = (self.pc + self.ev(args)) & 0xFFFF
            return
        if op == 'DB':
            for a in split_operands(args):
                if len(a) >= 2 and a[0] == "'" and a[-1] == "'" and \
                        len(a[1:-1].replace("''", "'")) != 1:
                    for ch in a[1:-1].replace("''", "'"):
                        self.emit(ord(ch))
                else:
                    self.emit(self.ev(a))
            return
        if op == 'DW':
            for a in split_operands(args):
                v = self.ev(a)
                self.emit(v & 0xFF, v >> 8)
            return
        self.instruction(op, split_operands(args))

    def reg8(self, text):
        t = text.strip().upper()
        if t in REG8:
            return REG8[t]
        v = self.ev(text)
        if v > 7:
            raise AsmError('bad register %r' % text)
        return v

    def rp(self, text, table):
        t = text.strip().upper()
        if t in table:
            return table[t]
        v = self.ev(text)
        if v not in (0, 2, 4, 6):
            raise AsmError('bad register pair %r' % text)
        return v // 2

    def instruction(self, op, a):
        def need(n):
            if len(a) != n:
                raise AsmError('%s expects %d operand(s)' % (op, n))
        if op in NOARG:
            need(0)
            self.emit(NOARG[op])
        elif op in IMM8:
            need(1)
            self.emit(IMM8[op], self.ev(a[0]))
        elif op in ADDR16:
            need(1)
            v = self.ev(a[0])
            self.emit(ADDR16[op], v & 0xFF, v >> 8)
        elif op in ALU:
            need(1)
            self.emit(ALU[op] | self.reg8(a[0]))
        elif op == 'MOV':
            need(2)
            d, s = self.reg8(a[0]), self.reg8(a[1])
            if d == 6 and s == 6:
                raise AsmError('MOV M,M is HLT')
            self.emit(0x40 | (d << 3) | s)
        elif op == 'MVI':
            need(2)
            self.emit(0x06 | (self.reg8(a[0]) << 3), self.ev(a[1]))
        elif op in ('INR', 'DCR'):
            need(1)
            self.emit((0x04 if op == 'INR' else 0x05) | (self.reg8(a[0]) << 3))
        elif op in ('INX', 'DCX', 'DAD'):
            need(1)
            base = {'INX': 0x03, 'DCX': 0x0B, 'DAD': 0x09}[op]
            self.emit(base | (self.rp(a[0], RP_SP) << 4))
        elif op == 'LXI':
            need(2)
            v = self.ev(a[1])
            self.emit(0x01 | (self.rp(a[0], RP_SP) << 4), v & 0xFF, v >> 8)
        elif op in ('PUSH', 'POP'):
            need(1)
            self.emit((0xC5 if op == 'PUSH' else 0xC1) | (self.rp(a[0], RP_PSW) << 4))
        elif op in ('STAX', 'LDAX'):
            need(1)
            r = self.rp(a[0], {'B': 0, 'D': 1})
            if r > 1:
                raise AsmError('%s only B or D' % op)
            self.emit((0x02 if op == 'STAX' else 0x0A) | (r << 4))
        elif op == 'RST':
            need(1)
            n = self.ev(a[0])
            if n > 7:
                raise AsmError('RST 0-7')
            self.emit(0xC7 | (n << 3))
        elif op == 'CALLN':
            need(1)
            self.emit(0xED, 0xED, self.ev(a[0]))
        else:
            raise AsmError('unknown opcode %s' % op)

    def image(self):
        if not self.mem:
            return 0, b''
        lo, hi = min(self.mem), max(self.mem)
        return lo, bytes(self.mem.get(i, 0) for i in range(lo, hi + 1))


def read_with_includes(path, depth=0):
    import os
    if depth > 8:
        raise SystemExit('include nesting too deep')
    out = []
    with open(path, encoding='latin-1') as f:
        for line in f:
            m = re.match(r'\s+INCLUDE\s+(\S+)', strip_comment(line), re.I)
            if m:
                inc = os.path.join(os.path.dirname(path), m.group(1))
                out.extend(read_with_includes(inc, depth + 1))
            else:
                out.append(line)
    return out


def main(argv):
    args, defines, lst, sym = [], {}, None, None
    it = iter(argv)
    for x in it:
        if x == '-D':
            k, v = next(it).split('=', 1)
            defines[k.upper()] = parse_number(v)
        elif x == '--sym':
            sym = next(it)
        else:
            args.append(x)
    if len(args) != 2:
        print(__doc__)
        return 2
    src, out = args
    lines = read_with_includes(src)
    try:
        asm = Assembler(defines).assemble(lines)
    except AsmError as e:
        print('%s: error: %s' % (src, e), file=sys.stderr)
        return 1
    lo, data = asm.image()
    with open(out, 'wb') as f:
        f.write(data)
    if sym:
        with open(sym, 'w') as f:
            for k in sorted(asm.symbols, key=lambda k: (asm.symbols[k], k)):
                f.write('%04X %s\n' % (asm.symbols[k], k))
    print('%s: %04XH-%04XH (%d bytes)' % (out, lo, lo + len(data) - 1, len(data)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
