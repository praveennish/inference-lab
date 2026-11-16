// Same renderer as docs/diagrams/render.cjs, for the guide's diagrams.
//   node docs/guide/render.cjs <path-to-mermaid.min.js>
const { chromium } = require("playwright");
const fs = require("node:fs");
const path = require("node:path");
(async () => {
  const mermaidJs = process.argv[2];
  const browser = await chromium.launch();
  const page = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: 1800, height: 1200 } });
  for (const file of fs.readdirSync(__dirname).filter((f) => f.endsWith(".mmd"))) {
    const source = fs.readFileSync(path.join(__dirname, file), "utf8");
    await page.setContent(`<!doctype html><html><body style="margin:0;background:#fff">
      <div id="out" style="display:inline-block;padding:20px;background:#fff"></div></body></html>`);
    await page.addScriptTag({ path: mermaidJs });
    await page.evaluate(async (src) => {
      window.mermaid.initialize({ startOnLoad: false, theme: "default",
        flowchart: { htmlLabels: true, curve: "basis", nodeSpacing: 35, rankSpacing: 45 },
        themeVariables: { fontFamily: "Helvetica, Arial, sans-serif", fontSize: "16px" } });
      const { svg } = await window.mermaid.render("d", src);
      const out = document.getElementById("out");
      out.innerHTML = svg;
      const el = out.querySelector("svg");
      const natural = parseFloat(el.style.maxWidth) || el.viewBox.baseVal.width;
      el.style.maxWidth = "none"; el.setAttribute("width", String(natural)); el.removeAttribute("height");
    }, source);
    await page.locator("#out").screenshot({ path: path.join(__dirname, file.replace(/\.mmd$/, ".png")) });
    console.log("rendered", file);
  }
  await browser.close();
})();
