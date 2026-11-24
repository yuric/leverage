const travelTime = 1250;
const stopTime = 950;
const legTime = travelTime + stopTime;

function initializeHandoff(diagram) {
  const token = diagram.querySelector("[data-handoff-token]");
  const playback = diagram.querySelector("[data-handoff-playback]");
  const providers = [...diagram.querySelectorAll("[data-handoff-provider]")].map(element => ({
    element,
    name: element.dataset.handoffProvider,
    usage: element.querySelector("[data-handoff-usage]"),
    status: element.querySelector("[data-handoff-status]"),
  }));
  const legs = [...diagram.querySelectorAll("[data-from][data-to]")].map(path => ({
    path,
    length: path.getTotalLength(),
    from: path.dataset.from,
    to: path.dataset.to,
  }));
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const initialPosition = token.getAttribute("transform");
  let visible = false;
  let paused = false;
  let elapsed = 0;
  let highlightedPath;
  let lastTime;
  let frame;

  function showStatus(from, resumed) {
    for (const { element, name, usage, status } of providers) {
      const state = name === from ? "limit" : name === resumed ? "resumed" : "ready";
      if (element.dataset.state !== state) {
        element.dataset.state = state;
        usage.textContent = state === "limit" ? "100%" : element.dataset.usage;
        status.textContent = { limit: "Limit", resumed: "Resumed", ready: "Ready" }[state];
      }
    }
  }

  function highlight(path) {
    if (highlightedPath === path) return;
    highlightedPath?.removeAttribute("data-handoff-current");
    path?.setAttribute("data-handoff-current", "");
    highlightedPath = path;
  }

  function draw(time) {
    const leg = legs[Math.floor(time / legTime)];
    highlight(leg.path);
    const progress = Math.min((time % legTime) / travelTime, 1);
    const distance = leg.length * progress ** 2 * (3 - 2 * progress);
    const point = leg.path.getPointAtLength(distance);
    const before = leg.path.getPointAtLength(Math.max(0, distance - 1));
    const after = leg.path.getPointAtLength(Math.min(leg.length, distance + 1));
    const direction = Math.atan2(after.y - before.y, after.x - before.x) * 180 / Math.PI;
    token.setAttribute("transform", `translate(${point.x} ${point.y}) rotate(${direction})`);
    showStatus(leg.from, progress === 1 ? leg.to : undefined);
  }

  function animate(time) {
    if (lastTime !== undefined) {
      elapsed = (elapsed + Math.min(time - lastTime, 100)) % (legs.length * legTime);
    }
    lastTime = time;
    draw(elapsed);
    frame = requestAnimationFrame(animate);
  }

  function syncPlayback() {
    playback.hidden = reducedMotion.matches;
    playback.textContent = paused ? "Play" : "Pause";
    playback.setAttribute("aria-label", paused ? "Play handoff animation" : "Pause handoff animation");
    if (visible && !paused && !reducedMotion.matches) {
      frame ??= requestAnimationFrame(animate);
      return;
    }
    cancelAnimationFrame(frame);
    frame = undefined;
    lastTime = undefined;
    if (reducedMotion.matches) {
      highlight(undefined);
      token.setAttribute("transform", initialPosition);
      showStatus(legs[0].from, legs[0].to);
    }
  }

  playback.addEventListener("click", () => {
    paused = !paused;
    syncPlayback();
  });
  reducedMotion.addEventListener("change", syncPlayback);
  new IntersectionObserver(([entry]) => {
    visible = entry.intersectionRatio >= .45;
    syncPlayback();
  }, { threshold: .45 }).observe(diagram);
  syncPlayback();
}

if ("IntersectionObserver" in window) {
  document.querySelectorAll("[data-handoff-diagram]").forEach(initializeHandoff);
}
