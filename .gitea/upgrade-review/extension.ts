// Renovate 升级评审的 pi 扩展：联网读取（fetch_url）与结构化结论（submit_review）。
//
// fetch_url 是 agent 唯一能出网的路径（不给 bash），所以 SSRF 防线都在这里：runner Pod 在
// homelab 集群里，能直接访问 Bao、Gitea API 等内网服务。只允许 GET http(s)，每一跳重定向都
// 重新解析并拒绝非公网地址与 ddupan.top / 集群内名字，响应截断到 MAX_BYTES。
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";

const MAX_BYTES = 200_000;
const MAX_REDIRECTS = 5;
const BLOCKED_SUFFIXES = [".ddupan.top", ".cluster.local", ".svc", ".internal", ".local"];

function isPublic(ip: string): boolean {
  if (isIP(ip) === 4) {
    const [a, b] = ip.split(".").map(Number);
    return !(
      a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) || // CGNAT
      (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) ||
      (a === 192 && b === 168)
    );
  }
  const v6 = ip.toLowerCase();
  if (v6.startsWith("::ffff:")) return isPublic(v6.slice(7));
  // 只放行全局单播 2000::/3；::1、fc00::/7、fe80::/10、组播等全部拒绝。
  return /^[23]/.test(v6);
}

async function checkUrl(raw: string): Promise<URL> {
  const url = new URL(raw);
  if (url.protocol !== "https:" && url.protocol !== "http:") throw new Error(`只允许 http(s)：${url.protocol}`);
  if (url.username || url.password) throw new Error("URL 不能带凭据");
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "ddupan.top" || BLOCKED_SUFFIXES.some((s) => host.endsWith(s)) || !host.includes(".")) {
    throw new Error(`拒绝访问内部主机：${host}`);
  }
  // ponytail: 解析与连接之间仍有 DNS rebinding 窗口；要彻底堵上需固定解析结果连接，或在 NetworkPolicy 层拦。
  const addrs = isIP(host) ? [{ address: host }] : await lookup(host, { all: true });
  const bad = addrs.find((a) => !isPublic(a.address));
  if (bad) throw new Error(`拒绝访问非公网地址：${host} -> ${bad.address}`);
  return url;
}

function toText(body: string, contentType: string): string {
  if (!contentType.includes("html")) return body;
  return body
    .replace(/<(script|style|noscript)[\s\S]*?<\/\1>/gi, "")
    .replace(/<br\s*\/?>|<\/(p|div|li|h\d|tr)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&amp;/g, "&")
    .replace(/\n\s*\n\s*\n+/g, "\n\n");
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "fetch_url",
    label: "Fetch URL",
    description:
      "GET 一个公网 http(s) URL，返回文本（HTML 去标签，截断到 200KB）。用于读取上游 release notes、changelog、" +
      "GitHub API（如 https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>）、chart 源码中的 values.yaml 等。" +
      "内网地址与 ddupan.top 一律拒绝。",
    parameters: Type.Object({ url: Type.String({ description: "完整的 http(s) URL" }) }),
    async execute(_id, params, signal) {
      let url = await checkUrl(params.url);
      for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
        // 单跳 30 秒上限：WAN 随机断（CLAUDE.md），慢响应不能拖住整次评审。
        const res = await fetch(url, {
          redirect: "manual",
          signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(30_000)]) : AbortSignal.timeout(30_000),
          headers: { "user-agent": "homelab-upgrade-review", accept: "text/html,application/json,text/plain,*/*" },
        });
        const location = res.headers.get("location");
        if (res.status >= 300 && res.status < 400 && location) {
          url = await checkUrl(new URL(location, url).toString());
          continue;
        }
        const buf = new Uint8Array(await res.arrayBuffer()).slice(0, MAX_BYTES);
        const text = toText(new TextDecoder().decode(buf), res.headers.get("content-type") ?? "");
        return {
          content: [{ type: "text", text: `HTTP ${res.status} ${url}\n\n${text}` }],
          details: { status: res.status, url: url.toString() },
        };
      }
      throw new Error(`重定向超过 ${MAX_REDIRECTS} 次`);
    },
  });

  pi.registerTool({
    name: "submit_review",
    label: "Submit review",
    description: "提交最终评审结论。评审结束时必须调用且只调用一次；调用后即结束，不再输出其他内容。",
    parameters: Type.Object({
      verdict: Type.Union([Type.Literal("safe"), Type.Literal("needs_review"), Type.Literal("unsafe")]),
      summary: Type.String({ description: "一两句话：升级了什么、结论的主要依据" }),
      breaking_changes: Type.Array(Type.String(), { description: "与我们配置相关的上游破坏性变更；无则为空" }),
      risks: Type.Array(Type.String(), { description: "其他风险或不确定之处" }),
      human_checks: Type.Array(Type.String(), { description: "合并前建议人工确认的具体事项" }),
      sources: Type.Array(Type.String(), { description: "实际查阅过的 URL 与仓库文件路径" }),
    }),
    async execute() {
      // 结论由外层脚本从 tool_execution_start 事件的参数里取，这里只确认收到。
      return { content: [{ type: "text", text: "已提交。" }], details: {} };
    },
  });
}
