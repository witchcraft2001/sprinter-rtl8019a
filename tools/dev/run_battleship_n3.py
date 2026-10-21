#!/usr/bin/env python3
"""Run final UNETRTL Battleship n3 acceptance without changing its sibling tree.

Requires the existing MAME pcap feth0/feth1 setup and tcpdump access. Keeps a
private stand copy under build/, patches only its consumer SEND deadline to
60 seconds, and saves raw captures plus text/JSON reports under build/evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

from check_unetrtl_capture import check
from prepare_battleship_n3 import prepare


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stand', type=Path, default=root.parent / 'sources/games/battleship')
    parser.add_argument('--observer', type=Path, help='optional read-only Lua observer appended to the private stand')
    parser.add_argument('--pauses', type=int, nargs='+', default=[6, 15, 30])
    parser.add_argument('--cases', nargs='+', default=['n3'], help='Battleship cases; n3 runs each --pauses value')
    parser.add_argument('--work', type=Path, default=root / 'build/unet044-battleship')
    parser.add_argument('--evidence', type=Path, default=root / 'build/evidence/unetrtl',
                        help='raw results directory (default: build/evidence/unetrtl)')
    args = parser.parse_args()
    work = args.work.resolve()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    (work / 'build/mame').mkdir(parents=True, exist_ok=True)
    shutil.copytree(args.stand / 'tools', work / 'tools', dirs_exist_ok=True)
    if args.observer:
        lua = work / 'tools/mame_bstand.lua'
        lua.write_text(lua.read_text() + args.observer.read_text())
    for name in ['BSTAND_NET.img', 'bstand.sym']:
        shutil.copy2(args.stand / 'build' / name, work / 'build' / name)
    patch = prepare(args.stand / 'build/BSTAND.EXE', work / 'build/bstand.sym', work / 'build/BSTAND60.EXE')
    (evidence / 'stand-patch.json').write_text(json.dumps(patch, indent=2) + '\n')
    image = str(work / 'build/BSTAND_NET.img')
    for source, dest in [(root / 'UNETRTL.DLL', 'UNETRTL.DLL'), (work / 'build/BSTAND60.EXE', 'BSTAND.EXE')]:
        subprocess.run(['mcopy', '-o', '-i', image, str(source), '::BSHIP/' + dest], check=True)
    digest = hashlib.sha256((root / 'UNETRTL.DLL').read_bytes()).hexdigest()
    print('DLL SHA-256: ' + digest, flush=True)
    for case, pause in [(c, p) for c in args.cases for p in (args.pauses if c == 'n3' else [0])]:
        label = f'stall{pause}' if case == 'n3' else case
        report = evidence / f'{label}.txt'
        pcap = evidence / f'{label}.pcap'
        env = dict(os.environ, BS_STALL=str(pause), BS_BAT=case, MAME_NET='rtl', SECONDS_TO_RUN='200',
                   REPORT=str(report), SHOTS_DIR=str(work / f'shots{pause}'))
        with (evidence / f'tcpdump-{label}.txt').open('w') as caplog:
            capture = subprocess.Popen(['tcpdump', '-i', 'feth1', '-U', '-w', str(pcap), 'tcp port 7777'],
                                       stdout=subprocess.DEVNULL, stderr=caplog)
            try:
                time.sleep(0.2)
                with (evidence / f'mame-{label}.log').open('w') as out:
                    proc = subprocess.Popen([str(work / 'tools/run_mame.sh'), 'test', image,
                                             str(work / 'build/bstand.sym'), 'net'],
                                            env=env, stdout=out, stderr=subprocess.STDOUT)
                    for tick in range(240):
                        if proc.poll() is not None:
                            break
                        if tick in (1, 30, 40):
                            ps = subprocess.check_output(['ps', '-Ao', 'pid,ppid,etime,command'], text=True)
                            relevant = [x for x in ps.splitlines() if ' -isa1 rtl8019as ' in x and '/mame sprinter ' in x]
                            (evidence / f'processes-{label}-{tick}.txt').write_text('\n'.join(relevant) + '\n')
                        time.sleep(1)
                    else:
                        proc.terminate()
                    rc = proc.wait(timeout=10)
            finally:
                capture.send_signal(signal.SIGINT)
                capture.wait(timeout=10)
        checked = check(pcap) if case == 'n3' else {'passed': rc == 0}
        (evidence / f'capture-{label}.json').write_text(json.dumps(checked, indent=2) + '\n')
        print(f'{label}: MAME rc={rc}, capture passed={checked["passed"]}', flush=True)
        for line in report.read_text().splitlines():
            if any(x in line for x in ['done,', 'NT_SEND_MAX', 'NT_AGERR', 'NT_AGDE', 'RESULT:']):
                print(line, flush=True)
        if rc or not checked['passed']:
            return 1
    assert hashlib.sha256((root / 'UNETRTL.DLL').read_bytes()).hexdigest() == digest, 'DLL changed during acceptance'
    return 0


if __name__ == '__main__':
    sys.exit(main())
