# rules

| 文件 | 内容 | 来源 |
|---|---|---|
| `cn-extra.json` / `cn-extra.srs` | 自动发现的"不在公共名单、但在国内有解析"的域名（供直连 + DNS real-IP 使用） | 本项目自动生成（判据：直连 DNS 与经代理的干净解析都判为国内） |
| `cn-extra.srs` | 上者的 sing-box 二进制格式，供客户端 `type: remote` 直接下载 | 由 `cn-extra.json` 用 `sing-box rule-set compile` 生成 |

更新方式：清单变更时同时提交 `cn-extra.json` 与重新编译的 `cn-extra.srs`。
客户端引用示例（`route.rule_set`）：

```json
{ "type": "remote", "tag": "cn-extra", "format": "binary",
  "url": "https://raw.githubusercontent.com/c000127/isongwrt/main/rules/cn-extra.srs",
  "update_interval": "1d", "download_detour": "代理连接" }
```
