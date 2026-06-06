# Apple App Store ASO Optimization Skill

> **Moved.** This skill now lives in the consolidated [TimBroddin/skills](https://github.com/TimBroddin/skills) repo so all my agent skills install from one place.

## New install

### `skills` CLI (any agent — Claude Code, Codex, Cursor, OpenCode, …)

```bash
npx skills add TimBroddin/skills --skill app-store-aso
```

### Claude Code plugin (installs every skill in the repo)

```
/plugin install TimBroddin/skills
```

## What it does

Generate optimized Apple App Store metadata with ASO best practices:

- App name, subtitle, promotional text, description, keywords, what's new — all validated against Apple's character limits
- Competitive analysis and screenshot strategy (including caption optimization for the June 2025 OCR indexing update)
- Pairs with [astro-mcp-server](https://github.com/TimBroddin/astro-mcp-server) for keyword research and [krankie](https://github.com/timbroddin/krankie) for rank tracking

Full documentation lives in the consolidated repo: <https://github.com/TimBroddin/skills/tree/main/skills/app-store-aso>.

## License

MIT — see [LICENSE](LICENSE).
