"use strict";

window.MathJax = {
  loader: { load: ["ui/safe"] },
  startup: { typeset: false },
  tex: {
    packages: { "[-]": ["require", "autoload", "html"] },
    maxBuffer: 32768,
    maxMacros: 1000
  },
  svg: { fontCache: "none" },
  options: {
    enableMenu: false,
    safeOptions: {
      allow: { URLs: "none", classes: "none", cssIDs: "none", styles: "none" }
    }
  }
};

window.glancemarkRender = async function (kind, source, dark) {
  const output = document.getElementById("output");
  output.replaceChildren();
  output.style.color = dark ? "#ececec" : "#1b1b1b";
  if (kind === "mermaid") {
    window.mermaid.initialize({
      startOnLoad: false, securityLevel: "strict", htmlLabels: false,
      theme: dark ? "dark" : "default",
      maxTextSize: 32768, maxEdges: 250,
      flowchart: { htmlLabels: false, useMaxWidth: false }
    });
    const { svg } = await window.mermaid.render("glancemark-diagram", source);
    const parsed = new DOMParser().parseFromString(svg, "image/svg+xml");
    const root = parsed.documentElement;
    if (root.localName !== "svg" || root.querySelector("parsererror")) throw Error("Invalid SVG");
    for (const active of root.querySelectorAll("script, foreignObject, image, a")) {
      if (active.localName === "a") active.replaceWith(...active.childNodes);
      else active.remove();
    }
    for (const item of [root, ...root.querySelectorAll("*")]) {
      for (const attribute of [...item.attributes]) {
        if (/^on/i.test(attribute.name) || (/href$/i.test(attribute.name) && !attribute.value.startsWith("#"))) {
          item.removeAttributeNode(attribute);
        }
      }
    }
    root.removeAttribute("style");
    // Mermaid's percentage width is relative to a host page. Use the diagram's
    // own dimensions before the app fits it to the document column.
    const box = root.viewBox.baseVal;
    const intrinsicLength = name => {
      const value = root.getAttribute(name);
      return /^\d+(?:\.\d+)?(?:px)?$/.test(value) ? parseFloat(value) : 0;
    };
    const width = Math.ceil(box.width > 0 ? box.width : intrinsicLength("width"));
    const height = Math.ceil(box.height > 0 ? box.height : intrinsicLength("height"));
    root.setAttribute("width", String(width));
    root.setAttribute("height", String(height));
    return rasterizeDiagram(root, width, height);
  } else if (kind === "math" || kind === "inlineMath") {
    await window.MathJax.startup.promise;
    const element = await window.MathJax.tex2svgPromise(source, { display: kind === "math" });
    if (element.querySelector("[data-mml-node='merror']")) throw Error("Invalid TeX");
    const original = element.querySelector("svg");
    if (!original) throw Error("Missing math SVG");
    output.append(original);
    const bounds = original.getBoundingClientRect();
    const box = original.viewBox.baseVal;
    if (bounds.width <= 0 || bounds.height <= 0 || box.width <= 0 || box.height <= 0) {
      throw Error("Invalid math bounds");
    }

    // Export only the math artwork. MathJax also emits an assistive text node
    // that must never be included in the visible image.
    const width = Math.ceil(bounds.width) + 6;
    const height = Math.ceil(bounds.height) + 6;
    const padX = 3 * box.width / bounds.width;
    const padY = 3 * box.height / bounds.height;
    original.setAttribute("width", String(width));
    original.setAttribute("height", String(height));
    original.setAttribute("viewBox", [box.x - padX, box.y - padY, box.width + 2 * padX, box.height + 2 * padY].join(" "));
    original.removeAttribute("style");
    for (const item of [original, ...original.querySelectorAll("*")]) {
      for (const paint of ["fill", "stroke"]) {
        if (item.getAttribute(paint)?.toLowerCase() === "currentcolor") {
          item.setAttribute(paint, dark ? "#ececec" : "#1b1b1b");
        }
      }
    }
    return { width, height, svg: new XMLSerializer().serializeToString(original) };
  } else {
    throw Error("Unsupported renderer");
  }
};

async function rasterizeDiagram(svg, width, height) {
  const area = width * height;
  if (width <= 2 || height <= 2 || width > 2048 || height > 4096 || area > 4194304) {
    throw Error("Diagram is too large to render");
  }
  // Render the generated SVG as an image onto a transparent canvas.
  // WKWebView's page snapshots flatten the page against an opaque backdrop.
  const url = URL.createObjectURL(new Blob([new XMLSerializer().serializeToString(svg)], { type: "image/svg+xml" }));
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    const scale = area <= 2097152 ? 2 : 1;
    const canvas = document.createElement("canvas");
    canvas.width = width * scale;
    canvas.height = height * scale;
    canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
    const png = canvas.toDataURL("image/png");
    const prefix = "data:image/png;base64,";
    if (!png.startsWith(prefix)) throw Error("Invalid diagram bitmap");
    return { width, height, png: png.slice(prefix.length) };
  } finally {
    URL.revokeObjectURL(url);
  }
}
