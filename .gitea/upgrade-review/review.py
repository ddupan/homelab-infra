#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "opentelemetry-sdk==1.45.2",
#   "opentelemetry-exporter-otlp-proto-http==1.45.2",
# ]
# ///
"""Renovate PR 升级评审：在 PR 检出上运行 pi（coding agent），判断升级在我们的配置下会不会坏，结论贴到 PR。

  uv run --script review.py                      CI（flux-diff.yml 的 upgrade-review job）
  uv run --script review.py --pr 748 --dry-run   本地：读公开 API，结论打印到 stdout

pi 只给只读工具：read/grep/find/ls 读仓库，extension.ts 的 fetch_url 读公网（带 SSRF 防线），
submit_review 交结论。不给 bash/edit/write。pi 以最小环境变量启动：拿得到的只有网关 key，
拿不到 GITEA_TOKEN、BAO_TOKEN；checkout 不保留凭据（persist-credentials: false）。

报告模式：只评论、不合并，也不让 job 失败——Renovate 的 automerge 要求全部 check 通过，
评审失败不能挡住它。

每次评审是一条 trace：根 span 下每轮模型调用与每次工具调用各一个 span，traceparent 经
models.json 的请求头带给 AI 网关，网关的 GenAI span 落在同一条 trace 里。
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import urllib.request
from pathlib import Path

from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'scripts'))
from tf import bao_kv, comment, request  # noqa: E402

MARKER = '<!-- upgrade-review -->'
FLUX_DIFF_MARKER = '<!-- flux-diff -->'
REPO = 'panxiao81/homelab-infra'
# OpenAI 兼容端点（apps/ai-gateway/README.md）；gpt-* 走 ChatGPT 订阅。
GATEWAY = 'https://ai.lab.ddupan.top/v1'
MODEL = os.environ.get('UPGRADE_REVIEW_MODEL', 'gpt-6-luna')
# kv/k8s/ai-gateway-keys/<id>，由 key UI 签发；吊销即停用评审。
KEY_ID = os.environ.get('UPGRADE_REVIEW_KEY_ID', 'upgrade-agent')
TOOLS = 'read,grep,find,ls,fetch_url,submit_review'
# 一次评审的墙钟上限。超时即杀掉 pi，按失败处理。
TIMEOUT = 900
LABEL = {'safe': '✅ safe', 'needs_review': '⚠️ needs_review', 'unsafe': '❌ unsafe'}
# CI 的 pod job 跑在 sandbox 集群，解析不了 homelab 的 Service 名：走 LAN 入口（collector 的
# 4319，bearer token，只进 traces 管道；platform/observability/traces/httproute-lan.yaml）。
OTLP = os.environ.get('OTEL_EXPORTER_OTLP_TRACES_ENDPOINT', 'https://otlp.lab.ddupan.top/v1/traces')


def gateway_key():
    if key := os.environ.get('UPGRADE_REVIEW_API_KEY'):  # 本地运行
        return key
    secret = bao_kv(f'k8s/ai-gateway-keys/{KEY_ID}')
    if not secret:
        raise RuntimeError(f'kv/k8s/ai-gateway-keys/{KEY_ID} 不存在（key 被撤销？）')
    return secret['key']


def comment_token():
    """评论以独立的 Bot 账号 upgrade-agent 发出（README 的 Bootstrap）；读不到时退回 job token。"""
    try:
        if token := (bao_kv('k8s/upgrade-agent') or {}).get('token'):
            return token
    except (Exception, SystemExit) as e:
        print(f'::warning::读取 upgrade-agent token 失败，改用 job token 评论：{e!r}')
    return os.environ.get('GITEA_TOKEN')


def otlp_token():
    if token := os.environ.get('UPGRADE_REVIEW_OTLP_TOKEN'):  # 本地运行
        return token
    try:
        return (bao_kv('k8s/otel-collector') or {}).get('public_token')
    except (Exception, SystemExit) as e:  # 拿不到就不导出 trace，评审照常
        print(f'::warning::读取 OTLP token 失败，不导出 trace：{e!r}')
        return None


def fetch_text(url, auth):
    with urllib.request.urlopen(urllib.request.Request(url, headers=auth), timeout=30) as r:
        return r.read().decode(errors='replace')


def build_context(api, auth, pr):
    """agent 的初始输入：PR 描述、diff、渲染 diff。我们的配置与上游信息由 agent 自己去读。"""
    diff = fetch_text(f"{api}/pulls/{pr['number']}.diff", auth)
    comments = request(f"{api}/issues/{pr['number']}/comments", headers=auth)
    flux = next((c['body'] for c in comments if c['body'].startswith(FLUX_DIFF_MARKER)),
                '（没有 flux-diff 评论：本 PR 未触发渲染，或渲染尚未完成）')
    files = sorted({line[6:] for line in diff.splitlines() if line.startswith('+++ b/')})
    return (f"<pr_title>{pr['title']}</pr_title>\n\n"
            f"<changed_files>\n" + '\n'.join(files) + "\n</changed_files>\n\n"
            f"<pr_description>\n{pr.get('body') or ''}\n</pr_description>\n\n"
            f"<pr_diff>\n{diff}\n</pr_diff>\n\n"
            f"<flux_diff>\n{flux}\n</flux_diff>\n")


def traceparent(span):
    c = span.get_span_context()
    return f'00-{c.trace_id:032x}-{c.span_id:016x}-01'


def run_agent(context, key, tracer, root):
    """运行 pi，把事件流转成 span；返回 (submit_review 的参数或 None, 统计)。"""
    stats = {'turns': 0, 'input': 0, 'output': 0, 'cache_read': 0, 'tools': {}}
    review = None
    with tempfile.TemporaryDirectory() as tmp:
        agent_dir = Path(tmp, 'agent')
        agent_dir.mkdir()
        (agent_dir / 'models.json').write_text(json.dumps({'providers': {'gateway': {
            'baseUrl': GATEWAY, 'api': 'openai-completions', 'authHeader': True,
            # 值由 pi 在请求时从环境变量解析，key 不落盘。
            'apiKey': '$AI_GATEWAY_KEY', 'headers': {'traceparent': '$TRACEPARENT'},
            'models': [{'id': MODEL}],
        }}}))
        ctx_file = Path(tmp, 'context.md')
        ctx_file.write_text(context)
        env = {
            'PATH': os.environ['PATH'], 'HOME': tmp, 'LANG': 'C.UTF-8',
            'AI_GATEWAY_KEY': key, 'TRACEPARENT': traceparent(root),
            'PI_CODING_AGENT_DIR': str(agent_dir),
            # 不访问 pi.dev：无版本检查、无安装统计、无模型目录刷新。
            'PI_OFFLINE': '1', 'PI_TELEMETRY': '0', 'PI_SKIP_VERSION_CHECK': '1',
        }
        cmd = [str(HERE / 'node_modules/.bin/pi'), '--model', f'gateway/{MODEL}', '--no-session',
               '--no-skills', '--no-extensions', '-e', str(HERE / 'extension.ts'), '--tools', TOOLS,
               '--append-system-prompt', str(HERE / 'prompt.md'), '--mode', 'json',
               f'@{ctx_file}', '开始评审。']
        # stdin 必须关掉：非终端 stdin 会被 pi 当成管道输入一直等待。
        # stderr 写文件：用管道时没人读，写满缓冲区会让 pi 卡住。
        err_file = Path(tmp, 'pi.err')
        with err_file.open('w') as err:
            proc = subprocess.Popen(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=err, text=True)
        timer = threading.Timer(TIMEOUT, proc.kill)
        timer.start()
        parent = trace.set_span_in_context(root)
        turn, tools = None, {}
        try:
            for line in proc.stdout:
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = e.get('type')
                if t == 'turn_start':
                    stats['turns'] += 1
                    turn = tracer.start_span(f"turn {stats['turns']}", context=parent)
                elif t == 'turn_end' and turn:
                    m = e.get('message') or {}
                    u = m.get('usage') or {}
                    stats['input'] += u.get('input', 0)
                    stats['output'] += u.get('output', 0)
                    stats['cache_read'] += u.get('cacheRead', 0)
                    turn.set_attributes({
                        'gen_ai.request.model': MODEL, 'gen_ai.response.model': m.get('model', ''),
                        'gen_ai.usage.input_tokens': u.get('input', 0),
                        'gen_ai.usage.output_tokens': u.get('output', 0),
                        'gen_ai.usage.cache_read.input_tokens': u.get('cacheRead', 0),
                        'pi.stop_reason': m.get('stopReason', ''),
                    })
                    turn.end()
                    turn = None
                elif t == 'tool_execution_start':
                    name = e.get('toolName', '')
                    stats['tools'][name] = stats['tools'].get(name, 0) + 1
                    args = e.get('args') or {}
                    if name == 'submit_review':
                        review = args
                    span = tracer.start_span(f'tool {name}', context=trace.set_span_in_context(turn or root))
                    span.set_attributes({'gen_ai.tool.name': name,
                                         'pi.tool.args': json.dumps(args, ensure_ascii=False)[:1000]})
                    tools[e.get('toolCallId')] = span
                elif t == 'tool_execution_end' and (span := tools.pop(e.get('toolCallId'), None)):
                    if e.get('isError'):
                        result = e.get('result') or {}
                        text = ''.join(c.get('text', '') for c in result.get('content') or [] if isinstance(c, dict))
                        span.set_status(Status(StatusCode.ERROR, text[:300]))
                    span.end()
        finally:
            timer.cancel()
            for span in [*tools.values(), *([turn] if turn else [])]:
                span.end()
            proc.wait()
        if proc.returncode != 0:
            raise RuntimeError(f'pi 退出码 {proc.returncode}：{err_file.read_text()[-2000:]}')
    return review, stats


def render(review, stats, trace_id):
    lines = [f"## 升级评审：{LABEL[review['verdict']]}", '', review['summary'], '']
    for title, key in (('与我们配置相关的破坏性变更', 'breaking_changes'), ('风险与不确定', 'risks'),
                       ('合并前建议确认', 'human_checks')):
        if review.get(key):
            lines += [f'### {title}', ''] + [f'- {x}' for x in review[key]] + ['']
    if review.get('sources'):
        lines += ['<details><summary>查阅来源</summary>', ''] + [f'- {x}' for x in review['sources']] + ['', '</details>', '']
    tools = '、'.join(f'{k}×{v}' for k, v in sorted(stats['tools'].items()))
    lines.append(f"<sub>{MODEL} · {stats['turns']} 轮 · 输入 {stats['input']}（缓存 {stats['cache_read']}）/ "
                 f"输出 {stats['output']} tokens · 工具 {tools} · trace {trace_id} · "
                 '报告模式：仅供参考，不会自动合并。</sub>')
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--pr', type=int, help='本地运行：PR 编号（不读 GITHUB_EVENT_PATH）')
    parser.add_argument('--dry-run', action='store_true', help='结论打印到 stdout，不评论')
    opts = parser.parse_args()

    server = os.environ.get('GITHUB_SERVER_URL', 'https://git.ddupan.top')
    api = f"{server}/api/v1/repos/{os.environ.get('GITHUB_REPOSITORY', REPO)}"
    # 仓库公开：本地 dry-run 不需要 token。
    auth = {'Authorization': f"token {os.environ['GITEA_TOKEN']}"} if os.environ.get('GITEA_TOKEN') else {}
    if opts.pr:
        pr = request(f'{api}/pulls/{opts.pr}', headers=auth)
    else:
        pr = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())['pull_request']

    provider = TracerProvider(resource=Resource.create({'service.name': 'upgrade-review'}))
    if token := otlp_token():
        provider.add_span_processor(BatchSpanProcessor(
            OTLPSpanExporter(endpoint=OTLP, headers={'Authorization': f'Bearer {token}'})))
    tracer = provider.get_tracer('upgrade-review')
    try:
        with tracer.start_as_current_span('upgrade_review') as root:
            root.set_attributes({'vcs.change.id': str(pr['number']), 'vcs.change.title': pr['title'],
                                 'gen_ai.request.model': MODEL})
            review, stats = run_agent(build_context(api, auth, pr), gateway_key(), tracer, root)
            if not review:
                raise RuntimeError(f'agent 未调用 submit_review（{stats}）')
            root.set_attribute('upgrade_review.verdict', review['verdict'])
            body = render(review, stats, f'{root.get_span_context().trace_id:032x}')
    finally:
        provider.shutdown()  # 导出失败只记日志，不影响评审结果
    if opts.dry_run:
        print(body)
        return
    out = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'upgrade-review.md'
    out.write_text(body)
    # tf.comment 从 GITEA_TOKEN 取凭据；只在发评论这一步换成 bot 的 token。
    os.environ['GITEA_TOKEN'] = comment_token()
    comment(out, MARKER)


if __name__ == '__main__':
    try:
        main()
    # 报告模式：任何失败只记日志，不让 job 变红挡住 automerge。tf.bao_kv 出错抛 SystemExit。
    except (Exception, SystemExit) as e:
        print(f'::warning::升级评审失败：{e!r}')
