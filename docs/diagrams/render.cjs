// Render every docs/diagrams/*.mmd to a PNG next to it with headless Chromium.
//   NODE_PATH=$(npm root -g) node docs/diagrams/render.cjs <path-to-mermaid.min.js>
// mermaid.min.js comes from `npm install mermaid@11.4.1` anywhere on the machine.
const { chromium } = require("playwright");
const fs = require("node:fs");
const path = require("node:path");

(async () => {
  const mermaidJs = process.argv[2];
  if (!mermaidJs) throw new Error("usage: node render.cjs <mermaid.min.js>");
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 3200, height: 2000 } });
  for (const file of fs.readdirSync(__dirname).filter((f) => f.endsWith(".mmd"))) {
    const source = fs.readFileSync(path.join(__dirname, file), "utf8");
    await page.setContent(`<!doctype html><html><body style="margin:0;background:#fff">
      <div id="out" style="display:inline-block;padding:24px;background:#fff"></div></body></html>`);
    await page.addScriptTag({ path: mermaidJs });
    await page.evaluate(async (src) => {
      window.mermaid.initialize({
        startOnLoad: false, theme: "default", securityLevel: "loose",
        flowchart: { htmlLabels: true, curve: "basis", nodeSpacing: 40, rankSpacing: 55 },
        themeVariables: { fontFamily: "Helvetica, Arial, sans-serif", fontSize: "15px" },
      });
      const { svg } = await window.mermaid.render("d", src);
      const out = document.getElementById("out");
      out.innerHTML = svg;
      // Mermaid sizes the SVG to its container; use the diagram's natural width instead.
      const el = out.querySelector("svg");
      const natural = parseFloat(el.style.maxWidth) || el.viewBox.baseVal.width;
      el.style.maxWidth = "none";
      el.setAttribute("width", String(natural));
      el.removeAttribute("height");
    }, source);
    const out = path.join(__dirname, file.replace(/\.mmd$/, ".png"));
    await page.locator("#out").screenshot({ path: out });
    console.log(`rendered ${path.basename(out)}`);
  }
  await browser.close();
})();
