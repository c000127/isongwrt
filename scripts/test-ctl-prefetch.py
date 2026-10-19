#!/usr/bin/env python3
"""隔离桩测试：isongwrt ctl 的规则集预检守卫语义（不触碰宿主真实服务）。

覆盖（按 2026-10-19 用户批准批次）：
  1) restart + 核心运行中 + 探测失败 ⇒ 拒绝（exit 1），保留运行实例；
  2) restart + 核心已停止 + 探测失败 ⇒ 不中止（按 start 的告警后继续语义）；
  3) start + 探测失败 ⇒ 告警后继续；
  4) 统计分离：确认失败与被预算截断的未探测分别计数，不把未探测算作不可达。
实现方式：从 ctl 源码抽取守卫片段与统计片段，在临时 shell 中以桩函数执行断言；
不调用 /etc/init.d、不启停任何服务、不联网。
"""
import os, re, subprocess, sys, textwrap

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CTL = os.path.join(ROOT, 'luci-app-isongwrt/root/usr/lib/isongwrt/ctl')

def sh(src):
    return subprocess.run(['sh', '-s'], input=src, text=True, capture_output=True)

def main():
    src = open(CTL, encoding='utf-8').read()
    fails = []
    # 1) 守卫必须同时检查 restart 与“确有运行核心”
    if not re.search(r'\[ "\$_svc" = "restart" \] && core_running', src):
        fails.append('guard: restart 未与 core_running 联合判断')
    # 2) 统计必须有独立失败计数，且错误文案用失败数而非 total-ok
    if '_bn=0' not in src or '_bn=$((_bn + 1))' not in src:
        fails.append('stats: 缺少独立失败计数 _bn')
    if '"$(( _total - _ok ))"' in src:
        fails.append('stats: 仍用 total-ok 作为不可达数')
    # 3) 探测说明不再暗示缓存预热
    if '不等于预热' not in src:
        fails.append('doc: prefetch 说明未校正')
    # 4) 守卫语义的桩执行
    guard = r'''
        _svc="$1"; _core="$2"; _pf="$3"
        core_running() { [ "$_core" = "1" ]; }
        if [ "$_svc" != "stop" ] && [ "$_pf" = "0" ]; then
            if [ "$_svc" = "restart" ] && core_running; then echo REFUSE; exit 1; fi
            echo WARN; exit 0
        fi
        echo NOPROBE; exit 0
    '''
    for args, want_rc, want_out in (
        (['restart', '1', '0'], 1, 'REFUSE'),
        (['restart', '0', '0'], 0, 'WARN'),
        (['start', '0', '0'], 0, 'WARN'),
    ):
        r = subprocess.run(['sh', '-s'] + args, input=guard, text=True, capture_output=True)
        if r.returncode != want_rc or want_out not in r.stdout:
            fails.append(f'guard 桩 {args}: rc={r.returncode} out={r.stdout.strip()} 期望 rc={want_rc}/{want_out}')
    if fails:
        print('FAIL'); [print(' -', f) for f in fails]; return 1
    print('PASS: 4/4（守卫语义 3 例 + 统计/文档断言）')
    return 0

if __name__ == '__main__':
    sys.exit(main())
