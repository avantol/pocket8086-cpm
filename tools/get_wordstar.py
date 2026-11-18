#!/usr/bin/env python3
"""Download WordStar 3.30 for CP/M-80 and set it up in extras/ for the card.

    python tools/get_wordstar.py
    python tools/build.py --sectors N          # or: cpmfiles.py D: put extras/*

WordStar is still copyrighted (originally MicroPro International) and is not
part of this repository.  This script fetches the WS330.zip that
retroarchive.org has hosted for many years, checks that it is exactly the
expected file, and copies the needed pieces into extras/ (which git ignores).

The Kaypro II build (WSkayproii.COM) becomes WS.COM: it uses the ADM-3A /
Kaypro codes that the Pocket8086 console understands.  WordStar 3.30 is pure
8080 code and runs in the NEC V30's 8080 mode.
"""
import hashlib
import os
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = 'http://www.retroarchive.org/cpm/text/WS330.zip'
SHA256 = 'c1c7fa042d4b4585adec4c686a23f90b5b8cf6cb9e74393969327b9fe43531f2'

# zip member -> name on the CP/M disk
FILES = {
    'WSkayproii.COM': 'WS.COM',          # installed for ADM-3A/Kaypro II screen
    'WSOVLY1.OVR': 'WSOVLY1.OVR',        # required overlays
    'WSMSGS.OVR': 'WSMSGS.OVR',
    'MAILMRGE.OVR': 'MAILMRGE.OVR',      # MailMerge
    'SPELSTAR.OVR': 'SPELSTAR.OVR',      # SpellStar
    'SPELSTAR.DCT': 'SPELSTAR.DCT',
    'WINSTALL.COM': 'WINSTALL.COM',      # re-install terminal/printer
    'WS.INS': 'WS.INS',
    'WSU.COM': 'WSU.COM',                # uninstalled copy for WINSTALL
    'PRINT.TST': 'PRINT.TST',
    'SAMPLE.TXT': 'SAMPLE.TXT',
    'DEMO.TXT': 'DEMO.TXT',
}


def main():
    cache = os.path.join(ROOT, 'build', 'downloads')
    os.makedirs(cache, exist_ok=True)
    zpath = os.path.join(cache, 'WS330.zip')
    if not os.path.isfile(zpath):
        print('downloading', URL)
        with urllib.request.urlopen(URL, timeout=60) as r:
            data = r.read()
        with open(zpath, 'wb') as f:
            f.write(data)
    data = open(zpath, 'rb').read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != SHA256:
        os.remove(zpath)
        sys.exit('WS330.zip checksum mismatch (got %s) - not using it' % digest)

    out = os.path.join(ROOT, 'extras')
    os.makedirs(out, exist_ok=True)
    with zipfile.ZipFile(zpath) as z:
        names = set(z.namelist())
        for member, cpmname in FILES.items():
            if member not in names:
                sys.exit('WS330.zip is missing %s' % member)
            with open(os.path.join(out, cpmname), 'wb') as f:
                f.write(z.read(member))
            print('  %-14s -> extras/%s' % (member, cpmname))
    print('WordStar 3.30 ready in extras/. Next: python tools/build.py --sectors N')
    print('or copy onto an existing card: python tools/cpmfiles.py D: put extras/* --force')


if __name__ == '__main__':
    main()
