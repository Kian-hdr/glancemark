"use strict";

// HTML emitted by the bundled lexer is parsed in an inert template. Only text
// and token classes cross the bridge; no HTML is inserted in the page.
window.glancemarkHighlight = function (code, language) {
  if (!hljs.getLanguage(language)) return null;
  const html = hljs.highlight(code, { language, ignoreIllegals: true }).value;
  const template = document.createElement("template");
  template.innerHTML = html;
  const tokens = [];
  let tokenCount = 0;

  function visit(node, inherited) {
    if (++tokenCount > 32000) throw Error("Highlight output limit");
    if (node.nodeType === Node.TEXT_NODE) {
      const text = node.textContent;
      if (!text) return;
      const previous = tokens[tokens.length - 1];
      if (previous && previous.scope === inherited) previous.text += text;
      else tokens.push({ text, scope: inherited });
      return;
    }
    if (node.nodeType === Node.ELEMENT_NODE && node.localName !== "span") {
      throw Error("Unexpected highlight markup");
    }
    const syntaxClass = node.classList && Array.from(node.classList)
      .find(name => name.startsWith("hljs-"));
    const scope = syntaxClass ? syntaxClass.slice(5) : inherited;
    for (const child of node.childNodes) visit(child, scope);
  }

  visit(template.content, "");
  return tokens;
};
