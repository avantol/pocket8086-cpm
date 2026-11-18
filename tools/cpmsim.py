#!/usr/bin/env python3
"""Test harness: run the built CP/M system on a simulated 8080.

The 8080 side (CCP, BDOS, BIOS.ASM) runs unmodified; each CALLN (ED ED nn)
is serviced by Python code that mirrors LOADER.ASM, working on the card image.

    python tools/cpmsim.py [--img build/cpm.img] [--keys "DIR\\rSTAT\\r"] [--write]
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, 'build')

PARITY = [0] * 256
for i in range(256):
    PARITY[i] = 0 if bin(i).count('1') & 1 else 1


class Halt(Exception):
    pass


class CPU8080:
    def __init__(self, mem):
        self.m = mem
        self.a = self.b = self.c = self.d = self.e = self.h = self.l = 0
        self.sp = 0
        self.pc = 0
        self.fs = self.fz = self.fac = self.fp = self.fc = 0
        self.callns = None
        self.steps = 0

    # flags --------------------------------------------------------------
    def getf(self):
        return (self.fs << 7) | (self.fz << 6) | (self.fac << 4) | \
               (self.fp << 2) | 2 | self.fc

    def setf(self, v):
        self.fs, self.fz, self.fac = (v >> 7) & 1, (v >> 6) & 1, (v >> 4) & 1
        self.fp, self.fc = (v >> 2) & 1, v & 1

    def szp(self, v):
        self.fs = v >> 7
        self.fz = 1 if v == 0 else 0
        self.fp = PARITY[v]

    # registers ----------------------------------------------------------
    def getr(self, r):
        if r == 0: return self.b
        if r == 1: return self.c
        if r == 2: return self.d
        if r == 3: return self.e
        if r == 4: return self.h
        if r == 5: return self.l
        if r == 6: return self.m[(self.h << 8) | self.l]
        return self.a

    def setr(self, r, v):
        v &= 0xFF
        if r == 0: self.b = v
        elif r == 1: self.c = v
        elif r == 2: self.d = v
        elif r == 3: self.e = v
        elif r == 4: self.h = v
        elif r == 5: self.l = v
        elif r == 6: self.m[(self.h << 8) | self.l] = v
        else: self.a = v

    def getrp(self, p):
        if p == 0: return (self.b << 8) | self.c
        if p == 1: return (self.d << 8) | self.e
        if p == 2: return (self.h << 8) | self.l
        return self.sp

    def setrp(self, p, v):
        v &= 0xFFFF
        if p == 0: self.b, self.c = v >> 8, v & 0xFF
        elif p == 1: self.d, self.e = v >> 8, v & 0xFF
        elif p == 2: self.h, self.l = v >> 8, v & 0xFF
        else: self.sp = v

    def rd16(self, a):
        return self.m[a & 0xFFFF] | (self.m[(a + 1) & 0xFFFF] << 8)

    def wr16(self, a, v):
        self.m[a & 0xFFFF] = v & 0xFF
        self.m[(a + 1) & 0xFFFF] = (v >> 8) & 0xFF

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.wr16(self.sp, v)

    def pop(self):
        v = self.rd16(self.sp)
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    def imm8(self):
        v = self.m[self.pc]
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def imm16(self):
        v = self.rd16(self.pc)
        self.pc = (self.pc + 2) & 0xFFFF
        return v

    def cond(self, cc):
        return [not self.fz, self.fz, not self.fc, self.fc,
                not self.fp, self.fp, not self.fs, self.fs][cc]

    def alu(self, op, v):
        a = self.a
        if op in (0, 1):                       # ADD, ADC
            c = self.fc if op == 1 else 0
            r = a + v + c
            self.fac = ((a & 0xF) + (v & 0xF) + c) >> 4 & 1
            self.fc = r >> 8
            self.a = r & 0xFF
            self.szp(self.a)
        elif op in (2, 3, 7):                  # SUB, SBB, CMP
            c = self.fc if op == 3 else 0
            r = a - v - c
            self.fac = 0 if ((a & 0xF) - (v & 0xF) - c) < 0 else 1
            self.fc = 1 if r < 0 else 0
            r &= 0xFF
            self.szp(r)
            if op != 7:
                self.a = r
        elif op == 4:                          # ANA
            r = a & v
            self.fac = ((a | v) >> 3) & 1
            self.fc = 0
            self.a = r
            self.szp(r)
        elif op == 5:                          # XRA
            self.a = a ^ v
            self.fc = self.fac = 0
            self.szp(self.a)
        else:                                  # ORA
            self.a = a | v
            self.fc = self.fac = 0
            self.szp(self.a)

    def step(self):
        op = self.imm8()
        self.steps += 1
        if 0x40 <= op < 0x80:
            if op == 0x76:
                raise Halt('HLT at %04X' % ((self.pc - 1) & 0xFFFF))
            self.setr((op >> 3) & 7, self.getr(op & 7))
            return
        if 0x80 <= op < 0xC0:
            self.alu((op >> 3) & 7, self.getr(op & 7))
            return
        if op < 0x40:
            lo = op & 7
            r = (op >> 3) & 7
            p = op >> 4
            if lo == 0:
                return                              # NOP (and undocumented)
            if lo == 1:
                if op & 8:                          # DAD
                    v = self.getrp(2) + self.getrp(p)
                    self.fc = v >> 16
                    self.setrp(2, v)
                else:
                    self.setrp(p, self.imm16())     # LXI
                return
            if lo == 2:
                if op == 0x02: self.m[self.getrp(0)] = self.a
                elif op == 0x12: self.m[self.getrp(1)] = self.a
                elif op == 0x0A: self.a = self.m[self.getrp(0)]
                elif op == 0x1A: self.a = self.m[self.getrp(1)]
                elif op == 0x22: self.wr16(self.imm16(), self.getrp(2))
                elif op == 0x2A: self.setrp(2, self.rd16(self.imm16()))
                elif op == 0x32: self.m[self.imm16()] = self.a
                else: self.a = self.m[self.imm16()]
                return
            if lo == 3:
                self.setrp(p, self.getrp(p) + (-1 if op & 8 else 1))
                return
            if lo == 4:                             # INR
                v = (self.getr(r) + 1) & 0xFF
                self.fac = 1 if (v & 0xF) == 0 else 0
                self.setr(r, v)
                self.szp(v)
                return
            if lo == 5:                             # DCR
                v = (self.getr(r) - 1) & 0xFF
                self.fac = 0 if (v & 0xF) == 0xF else 1
                self.setr(r, v)
                self.szp(v)
                return
            if lo == 6:
                self.setr(r, self.imm8())
                return
            # lo == 7: rotates and friends
            a = self.a
            if op == 0x07:
                self.fc = a >> 7; self.a = ((a << 1) | self.fc) & 0xFF
            elif op == 0x0F:
                self.fc = a & 1; self.a = (a >> 1) | (self.fc << 7)
            elif op == 0x17:
                c = self.fc; self.fc = a >> 7; self.a = ((a << 1) | c) & 0xFF
            elif op == 0x1F:
                c = self.fc; self.fc = a & 1; self.a = (a >> 1) | (c << 7)
            elif op == 0x27:                        # DAA
                corr, c = 0, self.fc
                if (a & 0xF) > 9 or self.fac:
                    corr |= 0x06
                if a > 0x99 or self.fc:
                    corr |= 0x60
                    c = 1
                self.fac = 1 if ((a & 0xF) + (corr & 0xF)) > 0xF else 0
                self.a = (a + corr) & 0xFF
                self.fc = c
                self.szp(self.a)
            elif op == 0x2F:
                self.a = a ^ 0xFF
            elif op == 0x37:
                self.fc = 1
            else:
                self.fc ^= 1
            return
        # 0xC0-0xFF
        lo = op & 7
        cc = (op >> 3) & 7
        if lo == 0:
            if self.cond(cc):
                self.pc = self.pop()
        elif lo == 1:
            if op & 8:
                if op == 0xC9 or op == 0xD9: self.pc = self.pop()
                elif op == 0xE9: self.pc = self.getrp(2)
                elif op == 0xF9: self.sp = self.getrp(2)
            else:
                p = (op >> 4) & 3
                v = self.pop()
                if p == 3:
                    self.a = v >> 8; self.setf(v & 0xFF)
                else:
                    self.setrp(p, v)
        elif lo == 2:
            t = self.imm16()
            if self.cond(cc):
                self.pc = t
        elif lo == 3:
            if op in (0xC3, 0xCB): self.pc = self.imm16()
            elif op == 0xD3: self.imm8()            # OUT: ignored
            elif op == 0xDB: self.imm8(); self.a = 0xFF   # IN
            elif op == 0xE3:
                v = self.rd16(self.sp); self.wr16(self.sp, self.getrp(2)); self.setrp(2, v)
            elif op == 0xEB:
                self.d, self.h = self.h, self.d; self.e, self.l = self.l, self.e
            # F3 DI / FB EI: ignored
        elif lo == 4:
            t = self.imm16()
            if self.cond(cc):
                self.push(self.pc); self.pc = t
        elif lo == 5:
            if op & 8:
                if op == 0xED and self.m[self.pc] == 0xED:   # CALLN
                    self.pc = (self.pc + 1) & 0xFFFF
                    self.callns(self, self.imm8())
                    return
                t = self.imm16()                    # CALL (and aliases)
                self.push(self.pc); self.pc = t
            else:
                p = (op >> 4) & 3
                self.push(((self.a << 8) | self.getf()) if p == 3 else self.getrp(p))
        elif lo == 6:
            self.alu(cc, self.imm8())
        else:
            self.push(self.pc); self.pc = cc * 8


class Machine:
    VBASE = 0xE0

    def __init__(self, img, keys, writeback):
        self.mem = bytearray(65536)
        self.ccp = open(os.path.join(BUILD, 'cpm22.bin'), 'rb').read()
        bios = open(os.path.join(BUILD, 'bios.bin'), 'rb').read()
        self.mem[0xF600:0xF600 + len(bios)] = bios
        self.mem[0xE000:0xE000 + len(self.ccp)] = self.ccp
        self.imgpath = img
        self.img = bytearray(open(img, 'rb').read())
        self.writeback = writeback
        lay = open(os.path.join(BUILD, 'layout.inc')).read()
        self.bases = [int(x) for x in re.search(r'drv_base:\s*dd\s*(.*)', lay).group(1).split(',')]
        self.tracks = [int(x) for x in re.search(r'drv_tracks:\s*dw\s*(.*)', lay).group(1).split(',')]
        self.spt = int(re.search(r'SPT equ (\d+)', lay).group(1))
        self.keys = list(keys)
        self.out = []
        self.drive = self.track = self.sector = 0
        self.dma = 0x80
        self.cpu = CPU8080(self.mem)
        self.cpu.callns = self.calln
        self.cpu.pc = 0xF600
        self.cpu.sp = 0xFFFE
        self.reads = self.writes = 0

    def lba(self):
        if self.drive >= len(self.bases) or self.sector >= self.spt or \
                self.track >= self.tracks[self.drive]:
            return None
        return self.bases[self.drive] + self.track * 16 + self.sector // 4

    def calln(self, cpu, n):
        f = n - self.VBASE
        if f == 1:                              # WBOOT
            self.mem[0xE000:0xE000 + len(self.ccp)] = self.ccp
        elif f == 2:                            # CONST (no type-ahead in tests,
            cpu.a = 0                           # or DIR/TYPE would abort)
        elif f == 3:                            # CONIN
            if not self.keys:
                raise Halt('end of input')
            cpu.a = ord(self.keys.pop(0))
        elif f == 4:                            # CONOUT
            self.out.append(chr(cpu.c & 0x7F))
        elif f in (5, 6):                       # LIST, PUNCH
            pass
        elif f == 7:
            cpu.a = 0x1A
        elif f == 8:
            self.track = 0
        elif f == 9:
            self.drive = cpu.c
        elif f == 10:
            self.track = (cpu.b << 8) | cpu.c
        elif f == 11:
            self.sector = (cpu.b << 8) | cpu.c
        elif f == 12:
            self.dma = (cpu.b << 8) | cpu.c
        elif f == 13:                           # READ
            l = self.lba()
            if l is None:
                cpu.a = 1
                return
            off = l * 512 + (self.sector & 3) * 128
            self.mem[self.dma:self.dma + 128] = self.img[off:off + 128]
            cpu.a = 0
            self.reads += 1
        elif f == 14:                           # WRITE
            l = self.lba()
            if l is None:
                cpu.a = 1
                return
            off = l * 512 + (self.sector & 3) * 128
            self.img[off:off + 128] = self.mem[self.dma:self.dma + 128]
            cpu.a = 0
            self.writes += 1
        elif f == 15:
            cpu.a = 0xFF
        else:
            raise Halt('unknown CALLN %02X' % n)

    def run(self, limit):
        try:
            while self.cpu.steps < limit:
                self.cpu.step()
            reason = 'step limit'
        except Halt as e:
            reason = str(e)
        if self.writeback:
            open(self.imgpath, 'wb').write(self.img)
        return reason


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--img', default=os.path.join(BUILD, 'cpm.img'))
    ap.add_argument('--keys', default='DIR\r')
    ap.add_argument('--limit', type=int, default=50_000_000)
    ap.add_argument('--write', action='store_true', help='save disk changes to the image')
    a = ap.parse_args()
    keys = a.keys.encode().decode('unicode_escape')
    m = Machine(a.img, keys, a.write)
    reason = m.run(a.limit)
    sys.stdout.write(''.join(m.out).replace('\r', ''))
    print('\n[stopped: %s; %d instructions, %d reads, %d writes]' % (
        reason, m.cpu.steps, m.reads, m.writes))


if __name__ == '__main__':
    main()
