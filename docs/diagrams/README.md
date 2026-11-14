# Diagrams

Each `.mmd` file is the Mermaid source; the `.png` next to it is rendered from it. Edit the source,
then re-render. Explained in [design.md](../design.md).

| Diagram | Shows | Used in |
|---|---|---|
| `architecture` | End-to-end system today: Codespace, long-lived and nightly AWS resources, internet dependencies, numbered flow | design.md §3 |
| `components` | Code modules, what calls what, and which tests cover which part | §4 |
| `sequence-spike` | One `make spike` run from the owner's command to destroy | §5 |
| `target-architecture` | Planned Kubernetes setup for Day 2 to 4 | §10 |
| `router-loop` | How the results feed the triage agent's model router (planned) | §11 |
| `verification` | The five testing layers, cheapest first | §13 |

Render (needs Node, Playwright and `npm install mermaid@11.4.1` anywhere on the machine):

```bash
node docs/diagrams/render.cjs <path>/node_modules/mermaid/dist/mermaid.min.js
```

Mermaid gotchas met here: `;` ends a statement inside sequence-diagram messages; long subgraph
titles are clipped, so keep them to a few words.
