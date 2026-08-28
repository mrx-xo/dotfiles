(() => {
  "use strict";

  const overlayId = "mr-x-mermaid-viewer";
  const viewHashPattern = /^#mr-x-mermaid-view=(\d+)$/;
  const chromeQueryPattern = /(?:^|[?&])mr-x-mermaid-chrome=(app|tab):(\d+)(?:&|$)/;
  let overlay;
  let stage;
  let canvas;
  let title;
  let diagrams = [];
  let activeIndex = null;
  let sourceSvg = null;
  let sourceWidth = 1;
  let sourceHeight = 1;
  let scale = 1;
  let offsetX = 0;
  let offsetY = 0;
  let drag = null;
  let pendingExternalIndex = null;
  let previousBodyOverflow = "";

  const clamp = (value, minimum, maximum) =>
    Math.min(maximum, Math.max(minimum, value));

  function diagramSvgs() {
    return Array.from(document.querySelectorAll("pre > code.mermaid > svg"));
  }

  function diagramSize(svg) {
    const viewBox = svg.viewBox && svg.viewBox.baseVal;
    if (viewBox && viewBox.width > 0 && viewBox.height > 0) {
      return { width: viewBox.width, height: viewBox.height };
    }

    const rectangle = svg.getBoundingClientRect();
    return {
      width: Math.max(1, rectangle.width),
      height: Math.max(1, rectangle.height),
    };
  }

  function diagramLabel(index) {
    const diagram = diagrams[index];
    const section = diagram && diagram.closest("pre")?.previousElementSibling;
    const heading = section && /^H[1-6]$/.test(section.tagName) ? section : null;
    return heading?.textContent?.trim() || `Diagram ${index + 1}`;
  }

  function applyTransform() {
    if (!canvas) return;
    canvas.style.transform =
      `translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
    overlay.dataset.scale = String(scale);
  }

  function fitDiagram() {
    if (!stage || !sourceSvg) return;
    const rectangle = stage.getBoundingClientRect();
    const availableWidth = Math.max(1, rectangle.width - 64);
    const availableHeight = Math.max(1, rectangle.height - 64);
    scale = clamp(
      Math.min(availableWidth / sourceWidth, availableHeight / sourceHeight),
      0.03,
      12,
    );
    offsetX = (rectangle.width - sourceWidth * scale) / 2;
    offsetY = (rectangle.height - sourceHeight * scale) / 2;
    applyTransform();
  }

  function zoomAt(factor, clientX, clientY) {
    if (!stage || !sourceSvg) return;
    const rectangle = stage.getBoundingClientRect();
    const pointerX = (clientX ?? rectangle.left + rectangle.width / 2) - rectangle.left;
    const pointerY = (clientY ?? rectangle.top + rectangle.height / 2) - rectangle.top;
    const diagramX = (pointerX - offsetX) / scale;
    const diagramY = (pointerY - offsetY) / scale;
    const nextScale = clamp(scale * factor, 0.03, 12);
    offsetX = pointerX - diagramX * nextScale;
    offsetY = pointerY - diagramY * nextScale;
    scale = nextScale;
    applyTransform();
  }

  function closeViewer() {
    if (!overlay || overlay.hidden) return;
    overlay.hidden = true;
    overlay.setAttribute("aria-hidden", "true");
    canvas.replaceChildren();
    sourceSvg = null;
    activeIndex = null;
    drag = null;
    document.body.style.overflow = previousBodyOverflow;
  }

  function openViewer(index) {
    diagrams = diagramSvgs();
    const diagram = diagrams[index];
    if (!diagram) return false;

    activeIndex = index;
    sourceSvg = diagram;
    const size = diagramSize(diagram);
    sourceWidth = size.width;
    sourceHeight = size.height;

    const clone = diagram.cloneNode(true);
    clone.removeAttribute("style");
    clone.setAttribute("width", "100%");
    clone.setAttribute("height", "100%");
    clone.setAttribute("aria-hidden", "true");
    canvas.style.width = `${sourceWidth}px`;
    canvas.style.height = `${sourceHeight}px`;
    canvas.replaceChildren(clone);
    title.textContent = diagramLabel(index);

    previousBodyOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    overlay.hidden = false;
    overlay.setAttribute("aria-hidden", "false");
    requestAnimationFrame(fitDiagram);
    return true;
  }

  function requestChrome(mode) {
    if (activeIndex === null) return;
    const route = mode === "app"
      ? "mr-x-mermaid-chrome=app:"
      : "mr-x-mermaid-chrome=tab:";
    const baseUrl = window.location.href.replace(/[?#].*$/, "");
    // WebKit emits no xwidget event for same-document hash changes.  A
    // same-file query navigation produces one reliable `load-started' event,
    // which Emacs uses as the bridge to /usr/bin/open.  setup() removes the
    // temporary query and reopens this diagram after the refresh.
    window.location.href = `${baseUrl}?${route}${activeIndex}`;
  }

  function handleAction(action) {
    switch (action) {
      case "zoom-in":
        zoomAt(1.2);
        break;
      case "zoom-out":
        zoomAt(1 / 1.2);
        break;
      case "fit":
        fitDiagram();
        break;
      case "chrome-app":
        requestChrome("app");
        break;
      case "chrome-tab":
        requestChrome("tab");
        break;
      case "close":
        closeViewer();
        break;
      default:
        break;
    }
  }

  function createOverlay() {
    overlay = document.createElement("div");
    overlay.id = overlayId;
    overlay.hidden = true;
    overlay.setAttribute("aria-hidden", "true");
    overlay.innerHTML = `
      <div class="mr-x-mermaid-viewer-shell" role="dialog" aria-modal="true"
           aria-label="Diagram viewer">
        <div class="mr-x-mermaid-viewer-toolbar">
          <span class="mr-x-mermaid-viewer-title"></span>
          <button type="button" data-mr-x-action="zoom-out" title="Zoom out">−</button>
          <button type="button" data-mr-x-action="zoom-in" title="Zoom in">+</button>
          <button type="button" data-mr-x-action="fit" title="Fit diagram">Fit</button>
          <button type="button" data-mr-x-action="chrome-app">Chrome Window</button>
          <button type="button" data-mr-x-action="chrome-tab">Chrome Tab</button>
          <button type="button" data-mr-x-action="close" title="Close (Escape)">Close</button>
        </div>
        <div class="mr-x-mermaid-viewer-stage">
          <div class="mr-x-mermaid-viewer-canvas"></div>
        </div>
      </div>`;
    document.body.appendChild(overlay);
    stage = overlay.querySelector(".mr-x-mermaid-viewer-stage");
    canvas = overlay.querySelector(".mr-x-mermaid-viewer-canvas");
    title = overlay.querySelector(".mr-x-mermaid-viewer-title");

    overlay.addEventListener("click", (event) => {
      const button = event.target.closest("button[data-mr-x-action]");
      if (button) handleAction(button.dataset.mrXAction);
    });

    stage.addEventListener(
      "wheel",
      (event) => {
        event.preventDefault();
        zoomAt(event.deltaY < 0 ? 1.12 : 1 / 1.12, event.clientX, event.clientY);
      },
      { passive: false },
    );

    stage.addEventListener("pointerdown", (event) => {
      if (event.button !== 0 || !sourceSvg) return;
      drag = {
        pointerId: event.pointerId,
        clientX: event.clientX,
        clientY: event.clientY,
        offsetX,
        offsetY,
      };
      stage.setPointerCapture(event.pointerId);
      stage.classList.add("is-dragging");
    });

    stage.addEventListener("pointermove", (event) => {
      if (!drag || event.pointerId !== drag.pointerId) return;
      offsetX = drag.offsetX + event.clientX - drag.clientX;
      offsetY = drag.offsetY + event.clientY - drag.clientY;
      applyTransform();
    });

    const finishDrag = (event) => {
      if (!drag || event.pointerId !== drag.pointerId) return;
      drag = null;
      stage.classList.remove("is-dragging");
    };
    stage.addEventListener("pointerup", finishDrag);
    stage.addEventListener("pointercancel", finishDrag);
  }

  function decorateDiagrams() {
    diagrams = diagramSvgs();
    diagrams.forEach((diagram, index) => {
      const container = diagram.closest("pre");
      container.tabIndex = 0;
      container.setAttribute("role", "button");
      container.setAttribute("aria-label", `${diagramLabel(index)} — open diagram viewer`);
      container.title = "Click to inspect this diagram";
      container.dataset.mrXMermaidIndex = String(index);
    });

    if (pendingExternalIndex !== null && diagrams[pendingExternalIndex]) {
      const index = pendingExternalIndex;
      pendingExternalIndex = null;
      openViewer(index);
    }
  }

  function setup() {
    if (document.getElementById(overlayId)) return;
    createOverlay();

    document.addEventListener("click", (event) => {
      const diagram = event.target.closest?.("pre > code.mermaid > svg");
      if (!diagram || overlay.contains(diagram)) return;
      const index = diagramSvgs().indexOf(diagram);
      if (index >= 0) {
        event.preventDefault();
        openViewer(index);
      }
    });

    document.addEventListener("keydown", (event) => {
      const container = event.target.closest?.("pre[data-mr-x-mermaid-index]");
      if (container && (event.key === "Enter" || event.key === " ")) {
        event.preventDefault();
        openViewer(Number(container.dataset.mrXMermaidIndex));
        return;
      }
      if (overlay.hidden) return;
      if (event.key === "Escape") closeViewer();
      if (event.key === "+" || event.key === "=") zoomAt(1.2);
      if (event.key === "-") zoomAt(1 / 1.2);
      if (event.key === "0" || event.key.toLowerCase() === "f") fitDiagram();
    });

    window.addEventListener("resize", () => {
      if (!overlay.hidden) fitDiagram();
    });

    const chromeRequest = window.location.search.match(chromeQueryPattern);
    if (chromeRequest) {
      pendingExternalIndex = Number(chromeRequest[2]);
      const cleanUrl = new URL(window.location.href);
      cleanUrl.searchParams.delete("mr-x-mermaid-chrome");
      history.replaceState(null, "", cleanUrl.href);
    }

    const requestedView = window.location.hash.match(viewHashPattern);
    if (requestedView) {
      pendingExternalIndex = Number(requestedView[1]);
      document.documentElement.classList.add("mr-x-mermaid-external-view");
    }

    const observer = new MutationObserver(decorateDiagrams);
    observer.observe(document.body, { childList: true, subtree: true });
    decorateDiagrams();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", setup, { once: true });
  } else {
    setup();
  }
})();
