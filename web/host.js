const root = document.getElementById("axiom-root");
const textDecoder = new TextDecoder();
const textEncoder = new TextEncoder();
const operations = new Map();
const invalidationListeners = new Map();
let model;
let currentPath = location.pathname;
let history = [currentPath];
let statesByPage = new Map();
let wasm;
let nextRequestId = 1;
const pending = new Map();
let responsePump;
let renderCleanups = [];
let initializedCollections = new Set();
let overlayVisibility = new Map();
let overlayFocusOrigins = new Map();
const reducedMotionQuery = matchMedia("(prefers-reduced-motion: reduce)");

function applyStylesheet() {
  let style = document.getElementById("axiom-authored-styles");
  if (!style) {
    style = document.createElement("style");
    style.id = "axiom-authored-styles";
    document.head.append(style);
  }
  style.textContent = String(model?.stylesheet || "")
    .replaceAll("list-main-axis-gap:", "--axiom-list-main-axis-gap:")
    .replaceAll("list-cross-axis-gap:", "--axiom-list-cross-axis-gap:");
}

function diagnostic(code, message, severity = "error") {
  console[severity === "warning" ? "warn" : "error"](`[Axiom ${code}] ${message}`);
  fetch("/__axiom/diagnostics", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ severity, code, message, graphRevision: model?.graphRevision || "" }),
  }).catch(() => {});
}
window.addEventListener("error", event => diagnostic("WEB_RUNTIME", event.message));
window.addEventListener("unhandledrejection", event => diagnostic("WEB_PROMISE", String(event.reason?.message || event.reason)));

function unquote(value) {
  const source = String(value ?? "").trim();
  if (source.startsWith('"') && source.endsWith('"')) {
    try { return JSON.parse(source); } catch (_) {}
  }
  return source;
}

function lookup(path, scope) {
  const parts = path.split(".");
  let value = Object.prototype.hasOwnProperty.call(scope, parts[0]) ? scope[parts[0]] : undefined;
  for (const part of parts.slice(1)) value = value?.[part];
  return value;
}

function evaluate(expression, scope = {}) {
  const source = String(expression ?? "").trim();
  if (!source) return undefined;
  if (source === "true") return true;
  if (source === "false") return false;
  if (source === "null") return null;
  if (source === "[]") return [];
  if ((source.startsWith("[") && source.endsWith("]")) || (source.startsWith("{") && source.endsWith("}"))) {
    try { return JSON.parse(source); } catch (_) {}
  }
  if (/^-?\d+(\.\d+)?$/.test(source)) return Number(source);
  if (source.startsWith('"') && source.endsWith('"')) return unquote(source);
  const asset = source.match(/^asset\("([^"]+)"\)$/);
  if (asset) return `/__axiom/assets/${asset[1].split("/").map(encodeURIComponent).join("/")}`;
  const value = lookup(source, scope);
  return value === undefined ? source : value;
}

function parseRecord(source, scope) {
  const result = {};
  for (const entry of String(source || "").split(",")) {
    const separator = entry.indexOf(":");
    if (separator < 0) continue;
    result[entry.slice(0, separator).trim()] = evaluate(entry.slice(separator + 1), scope);
  }
  return result;
}

function allocBytes(bytes) {
  if (!bytes.length) return 0;
  const pointer = wasm.axiom_malloc(bytes.length);
  new Uint8Array(wasm.memory.buffer).set(bytes, pointer);
  return pointer;
}
function allocString(value) {
  const bytes = textEncoder.encode(value || "");
  return { pointer: allocBytes(bytes), length: bytes.length };
}
function free(value) { if (value.pointer) wasm.axiom_free_memory(value.pointer, value.length); }

async function initializeRuntime(config) {
  if (!config.contracts.length) return;
  try {
    wasm = await window.wasm_bindgen({ module_or_path: fetch("/axiom_runtime_bg.wasm") });
  } catch (error) {
    throw new Error(`embedded WASM download or instantiation failed: ${error.message || error}`);
  }
  window.axiom_web_callback = (requestId, eventType, status, dataPointer, dataLength, errorPointer, errorLength) => {
    const request = pending.get(requestId);
    const copy = (pointer, length) => pointer && length ? new Uint8Array(new Uint8Array(wasm.memory.buffer).slice(pointer, pointer + length)) : null;
    const data = copy(dataPointer, dataLength);
    const error = copy(errorPointer, errorLength);
    if (dataPointer) wasm.axiom_free_memory(dataPointer, dataLength);
    if (errorPointer) wasm.axiom_free_memory(errorPointer, errorLength);
    if (!request) return;
    if (eventType === 4) {
      let failure;
      try {
        const details = error ? JSON.parse(textDecoder.decode(error)) : null;
        failure = new Error(details?.message || `Runtime status ${status}`);
        failure.details = details;
      } catch (_) {
        failure = new Error(error ? textDecoder.decode(error) : `Runtime status ${status}`);
      }
      request.failure = failure;
      request.onError?.(failure);
      return;
    }
    if (eventType === 5 && data) {
      const text = textDecoder.decode(data);
      let chunk;
      try { chunk = JSON.parse(text); } catch (_) { chunk = text; }
      request.chunks.push(chunk);
      request.onChunk?.(chunk);
      return;
    }
    if ([1, 2, 3].includes(eventType) && data) {
      const text = textDecoder.decode(data);
      try { request.value = JSON.parse(text); } catch (_) { request.value = text; }
      return;
    }
    // ABI v1 guarantees exactly one Complete event after either success or
    // Error. Keep failures and stream chunks until that terminal boundary.
    if (eventType === 0) {
      pending.delete(requestId);
      if (request.failure) request.reject(request.failure);
      else if (status === 15) request.reject(new Error("Axiom request was cancelled."));
      else request.resolve(request.kind === "stream" ? request.chunks : request.value);
    }
  };
  responsePump = setInterval(() => wasm?.axiom_process_responses(), 16);
  const db = allocString("");
  let initialized;
  try {
    initialized = wasm.axiom_wasm_initialize(db.pointer, db.length);
  } catch (error) {
    throw new Error(`embedded WASM initialization trapped: ${error.message || error}`);
  }
  free(db);
  if (initialized !== 0) throw new Error(`Axiom WASM initialization failed (${initialized})`);
  for (const contract of config.contracts) {
    const namespace = allocString(contract.namespace);
    const baseUrl = allocString(contract.baseUrl);
    const bytes = Uint8Array.from(atob(contract.artifactBase64), character => character.charCodeAt(0));
    const artifact = { pointer: allocBytes(bytes), length: bytes.length };
    const signature = allocString(contract.signature);
    const publicKey = allocString(contract.publicKey);
    let status;
    try {
      status = wasm.axiom_wasm_load_contract(namespace.pointer, namespace.length, baseUrl.pointer, baseUrl.length, artifact.pointer, artifact.length, signature.pointer, signature.length, publicKey.pointer, publicKey.length);
    } catch (error) {
      throw new Error(`embedded WASM contract load trapped for ${contract.localName}: ${error.message || error}`);
    }
    [namespace, baseUrl, artifact, signature, publicKey].forEach(free);
    if (status !== 0 && status !== -1) throw new Error(`Contract ${contract.localName} failed to load (${status})`);
    for (const operation of contract.operations) operations.set(`${contract.localName}.${operation.name}`, { ...operation, contract });
  }
}

function callOperation(binding, scope, page) {
  const spec = operations.get(`${binding.contractLocalName}.${binding.operation}`);
  if (!spec) return Promise.reject(new Error(`Unknown verified operation ${binding.operation}`));
  const args = parseRecord(binding.arguments, scope);
  const pathNames = [...spec.path.matchAll(/\{([^}]+)\}/g)].map(match => match[1]);
  let path = spec.path;
  for (const name of pathNames) { path = path.replace(`{${name}}`, encodeURIComponent(String(args[name]))); delete args[name]; }
  const body = textEncoder.encode(Object.keys(args).length ? JSON.stringify(args) : "");
  const requestId = nextRequestId++;
  return new Promise((resolve, reject) => {
    pending.set(requestId, {
      resolve, reject, kind: spec.kind, chunks: [], failure: null, page: page.name,
      onChunk: value => {
        binding.__state.data = [...binding.__state.data, value];
        render(false);
      },
      onError: error => {
        binding.__state.error = error;
        render(false);
      },
    });
    const namespace = allocString(spec.contract.namespace), method = allocString(spec.method), requestPath = allocString(path), trace = allocString(""), headers = allocString("");
    const payload = { pointer: allocBytes(body), length: body.length };
    const status = wasm.axiom_wasm_call(requestId, namespace.pointer, namespace.length, spec.endpointId, method.pointer, method.length, requestPath.pointer, requestPath.length, trace.pointer, trace.length, headers.pointer, headers.length, payload.pointer, payload.length);
    [namespace, method, requestPath, trace, headers, payload].forEach(free);
    if (status !== 0) { pending.delete(requestId); reject(new Error(`Axiom runtime rejected request ${requestId} (${status})`)); }
  });
}

function cancelPendingOperations(reason = "Axiom web runtime was torn down.") {
  for (const [requestId, request] of pending) {
    try { wasm?.axiom_wasm_cancel?.(requestId); } catch (_) {}
    request.reject(new Error(reason));
  }
  pending.clear();
  try { wasm?.axiom_wasm_reset_session?.(); } catch (_) {}
  if (responsePump) clearInterval(responsePump);
  responsePump = undefined;
}

function cancelPageOperations(page) {
  for (const [requestId, request] of pending) {
    if (request.page !== page.name) continue;
    try { wasm?.axiom_wasm_cancel?.(requestId); } catch (_) {}
    const error = new Error("Axiom operation was cancelled during page teardown.");
    error.axiomCancelled = true;
    request.reject(error);
    pending.delete(requestId);
  }
  for (const binding of page.operations) {
    if (binding.kind !== "mutation") binding.__started = false;
    if (binding.__state) binding.__state.pending = false;
  }
}

function pageScope(page) {
  const scope = Object.fromEntries(pageState(page));
  for (const binding of page.operations) scope[binding.name] = binding.__state;
  return scope;
}

function pageState(page) {
  if (!statesByPage.has(page.name)) statesByPage.set(page.name, new Map());
  return statesByPage.get(page.name);
}

function styleFor(node, scope) {
  const style = {};
  const mapping = { background: "backgroundColor", color: "color", padding: "padding", radius: "borderRadius", font_size: "fontSize" };
  for (const property of node.properties) {
    if (!mapping[property.name]) continue;
    let value = evaluate(property.expression, scope);
    if (typeof value === "string" && model.tokens[value] !== undefined) value = model.tokens[value];
    if (["padding", "radius", "font_size"].includes(property.name) && typeof value === "number") value = `${value}px`;
    style[mapping[property.name]] = value;
  }
  return style;
}

function renderNode(node, page, scope) {
  if (node.condition && !evaluate(node.condition, scope)) {
    for (const branch of node.elseIf || []) if (evaluate(branch.condition, scope)) return renderChildren(branch.children, page, scope);
    return renderChildren(node.elseChildren || [], page, scope);
  }
  if (node.componentName) {
    const component = model.ir.components.find(candidate => candidate.name === node.componentName);
    const props = Object.fromEntries(node.properties.map(property => [property.name, evaluate(property.expression, scope)]));
    return renderChildren(component?.view || [], page, { ...scope, ...props });
  }
  const properties = Object.fromEntries(node.properties.map(property => [property.name, property.expression]));
  const tags = {
    page: "main", text: "span", image: "img", svg: "div", input: "input", text_area: "textarea",
    button: "button", pressable: "button", scroll: "div", scroll_view: "div",
    list: "div", refresh: "div", refresh_header: "div", view_pager: "div",
    scroll_coordinator: "div", scroll_coordinator_header: "header",
    scroll_coordinator_toolbar: "nav", scroll_coordinator_slot: "section",
    overlay: "div", view: "div", safe_area: "section",
    form: "form", form_submit: "button", input_field: "input",
  };
  let tag = tags[node.primitive] || "div";
  if (node.primitive === "form_field") {
    const control = String(evaluate(properties.control, scope) || "").replaceAll('"', "");
    if (control === "InputField") tag = "input";
    else if (control === "TextArea") tag = "textarea";
    else if (control === "Checkbox" || control === "Switch") tag = "input";
  }
  const element = document.createElement(tag);
  element.dataset.axiomId = node.semanticId.value;
  const authoredClass = evaluate(properties.class, scope);
  element.className = [`axiom-${node.primitive.replaceAll("_", "-")}`, typeof authoredClass === "string" ? authoredClass : ""].filter(Boolean).join(" ");
  const authoredId = evaluate(properties.id, scope);
  if (typeof authoredId === "string" && authoredId) element.id = authoredId;
  Object.assign(element.style, styleFor(node, scope));
  applyCoreAttributes(element, properties, scope);
  bindCoreEvents(element, properties, page);
  if (node.primitive === "text") {
    element.append(document.createTextNode(String(evaluate(properties.value, scope) ?? "")));
    element.append(renderChildren(node.children, page, scope));
  }
  else if (node.primitive === "image") {
    element.src = evaluate(properties.source, scope);
    element.alt = properties.decorative === "true" ? "" : unquote(properties.alt);
    if (properties.placeholder) element.style.backgroundImage = `url("${evaluate(properties.placeholder, scope)}")`;
    const modes = { scaleToFill: "fill", aspectFit: "contain", aspectFill: "cover", center: "none" };
    if (modes[unquote(properties.mode)]) element.style.objectFit = modes[unquote(properties.mode)];
  }
  else if (node.primitive === "svg") {
    element.setAttribute("role", properties.decorative === "true" ? "presentation" : "img");
    if (properties.decorative !== "true") element.setAttribute("aria-label", unquote(properties.alt));
    if (properties.content) element.innerHTML = evaluate(properties.content, scope);
    else if (properties.source) {
      const image = document.createElement("img");
      image.src = evaluate(properties.source, scope);
      image.alt = properties.decorative === "true" ? "" : unquote(properties.alt);
      image.addEventListener("load", () => runAction(page, properties.on_load));
      element.append(image);
    }
  }
  else if (["input", "text_area", "input_field"].includes(node.primitive)) {
    bindInputBehavior(element, node, properties, page, scope);
  } else if (node.primitive === "form_field") {
    const control = String(evaluate(properties.control, scope) || "").replaceAll('"', "");
    if (control === "Checkbox" || control === "Switch") element.type = "checkbox";
    else if (control === "InputField") element.type = String(evaluate(properties.input_type, scope) || "text");
    if (properties.placeholder) element.placeholder = String(evaluate(properties.placeholder, scope) || "");
    if (properties.disabled) element.disabled = evaluate(properties.disabled, scope) === true;
    if (properties.read_only) element.readOnly = evaluate(properties.read_only, scope) === true;
    if (properties.max_length) element.maxLength = Number(evaluate(properties.max_length, scope));
    if (properties.on_change) addManagedListener(element, "input", () => runAction(page, properties.on_change));
    element.append(renderChildren(node.children, page, scope));
  } else if (node.primitive === "overlay") {
    bindOverlayBehavior(element, node, properties, page, scope);
    element.append(renderChildren(node.children, page, scope));
  } else if (["button", "pressable"].includes(node.primitive)) {
    element.type = "button";
    element.textContent = String(evaluate(properties.label || properties.accessibility_label, scope) ?? "Action");
    element.disabled = Boolean(evaluate(properties.disabled, scope));
    element.addEventListener("click", () => runAction(page, properties.on_press));
  } else if (["list", "list_view", "feed_list", "sortable", "swiper"].includes(node.primitive)) {
    renderIteratedChildren(element, node, properties, page, scope);
  } else element.append(renderChildren(node.children, page, scope));
  bindStandardComponent(element, node, properties, page, scope);
  bindCollectionBehavior(element, node, properties, page, scope);
  return element;
}

function addManagedListener(element, event, listener, options) {
  element.addEventListener(event, listener, options);
  renderCleanups.push(() => element.removeEventListener(event, listener, options));
}

function assignControlledState(page, expression, value, action) {
  const stateName = String(expression || "").trim();
  if (stateName && page.states.some(state => state.name === stateName)) pageState(page).set(stateName, value);
  if (action) runAction(page, action);
  render(false);
}

function setComponentStateClass(element, name, enabled) {
  element.classList.toggle(`ui-${name}`, enabled);
  element.dataset[`ui${name[0].toUpperCase()}${name.slice(1)}`] = String(enabled);
}

function renderIteratedChildren(element, node, properties, page, scope) {
  const items = evaluate(properties.items, scope);
  const iterator = node.iterator || "item";
  for (const item of Array.isArray(items) ? items : []) {
    const itemScope = { ...scope, [iterator]: item };
    const cell = document.createElement("div");
    const keyExpression = String(properties.key || "").split("|").at(-1).trim();
    const key = evaluate(keyExpression, itemScope);
    cell.className = `axiom-${node.primitive.replaceAll("_", "-")}-item`;
    cell.dataset.itemKey = String(key);
    cell.dataset.reuseIdentifier = String(evaluate(properties.item_reuse_identifier, itemScope) || "default");
    cell.style.contentVisibility = "auto";
    if (properties.item_estimated_main_axis_size_px) {
      cell.style.containIntrinsicSize = `${Number(evaluate(properties.item_estimated_main_axis_size_px, itemScope)) || 0}px`;
    }
    if (evaluate(properties.item_sticky_top, itemScope) === true) { cell.style.position = "sticky"; cell.style.top = `${Number(evaluate(properties.sticky_offset, scope)) || 0}px`; }
    if (evaluate(properties.item_sticky_bottom, itemScope) === true) { cell.style.position = "sticky"; cell.style.bottom = `${Number(evaluate(properties.sticky_offset, scope)) || 0}px`; }
    if (evaluate(properties.item_full_span, itemScope) === true) cell.style.gridColumn = "1 / -1";
    cell.append(renderChildren(node.children, page, itemScope));
    element.append(cell);
  }
}

function bindStandardComponent(element, node, properties, page, scope) {
  const primitive = node.primitive;
  const disabled = evaluate(properties.disabled, scope) === true || evaluate(properties.enabled, scope) === false;
  if (disabled) { element.setAttribute("aria-disabled", "true"); element.tabIndex = -1; }
  setComponentStateClass(element, "disabled", disabled);

  if (primitive === "checkbox" || primitive === "switch") {
    const checked = evaluate(properties.checked, scope) === true;
    const indeterminate = primitive === "checkbox" && evaluate(properties.indeterminate, scope) === true;
    element.setAttribute("role", primitive === "switch" ? "switch" : "checkbox");
    element.setAttribute("aria-checked", indeterminate ? "mixed" : String(checked));
    element.tabIndex = disabled ? -1 : 0;
    setComponentStateClass(element, "checked", checked);
    setComponentStateClass(element, "indeterminate", indeterminate);
    element.querySelectorAll(`.axiom-${primitive === "switch" ? "switch-thumb,.axiom-switch-track" : "checkbox-indicator"}`)
      .forEach(indicator => { indicator.hidden = !checked && !indeterminate; });
    const toggle = event => {
      if (disabled) return;
      if (event.type === "keydown" && !["Enter", " "].includes(event.key)) return;
      event.preventDefault();
      assignControlledState(page, properties.checked, !checked, properties.on_change);
    };
    addManagedListener(element, "click", toggle);
    addManagedListener(element, "keydown", toggle);
    return;
  }

  if (primitive === "radio_group") {
    element.setAttribute("role", "radiogroup");
    const value = evaluate(properties.value, scope);
    for (const radio of element.querySelectorAll(":scope > .axiom-radio")) {
      const radioNode = node.children.find(child => child.semanticId.value === radio.dataset.axiomId);
      const radioProperties = Object.fromEntries((radioNode?.properties || []).map(property => [property.name, property.expression]));
      const radioValue = evaluate(radioProperties.value, scope);
      const selected = Object.is(radioValue, value);
      radio.setAttribute("role", "radio"); radio.setAttribute("aria-checked", String(selected));
      radio.tabIndex = disabled ? -1 : (selected ? 0 : -1);
      setComponentStateClass(radio, "checked", selected);
      radio.querySelectorAll(".axiom-radio-indicator").forEach(indicator => { indicator.hidden = !selected; });
      const select = event => {
        if (disabled) return;
        if (event.type === "keydown" && !["Enter", " "].includes(event.key)) return;
        event.preventDefault();
        assignControlledState(page, properties.value, radioValue, properties.on_change);
      };
      addManagedListener(radio, "click", select); addManagedListener(radio, "keydown", select);
    }
    return;
  }

  if (primitive === "form") {
    element.noValidate = true;
    addManagedListener(element, "submit", event => { event.preventDefault(); runAction(page, properties.on_submit); });
    addManagedListener(element, "input", () => properties.on_change && runAction(page, properties.on_change));
    return;
  }
  if (primitive === "form_submit") {
    element.type = "submit";
    element.textContent = String(evaluate(properties.label || properties.accessibility_label, scope) ?? "");
    if (properties.on_submit) addManagedListener(element, "click", () => runAction(page, properties.on_submit));
    return;
  }

  if (["dialog", "popover", "sheet"].includes(primitive)) {
    bindDisclosureComponent(element, node, properties, page, scope);
    return;
  }
  if (["dialog_trigger", "dialog_close", "popover_trigger", "sheet_handle"].includes(primitive)) {
    element.setAttribute("role", "button"); element.tabIndex = disabled ? -1 : 0;
    return;
  }
  if (["dialog_content", "popover_content", "sheet_content"].includes(primitive)) {
    element.setAttribute("role", primitive === "dialog_content" ? "dialog" : "group");
    if (primitive === "dialog_content") element.setAttribute("aria-modal", "true");
    return;
  }
  if (primitive === "overlay_panel") { element.setAttribute("role", "presentation"); return; }

  if (primitive === "draggable") { bindDraggableComponent(element, properties, page, scope); return; }
  if (primitive === "sortable") { bindSortableComponent(element, properties, page, scope); return; }
  if (primitive === "swipe_action") { bindSwipeActionComponent(element, properties, page, scope); return; }
  if (primitive === "lazy_component") {
    const width = Number(evaluate(properties.estimated_width, scope));
    const height = Number(evaluate(properties.estimated_height, scope));
    element.style.contentVisibility = "auto";
    if (Number.isFinite(width) || Number.isFinite(height)) element.style.containIntrinsicSize = `${Number.isFinite(width) ? width : 0}px ${Number.isFinite(height) ? height : 0}px`;
    return;
  }
  if (primitive === "swiper" && evaluate(properties.autoplay, scope) === true) {
    const interval = Math.max(1, Number(evaluate(properties.autoplay_interval, scope)) || 3000);
    const timer = setInterval(() => {
      if (!element.isConnected || reducedMotionQuery.matches) return;
      const itemWidth = Number(evaluate(properties.item_width, scope)) || element.clientWidth;
      const maximum = Math.max(0, element.scrollWidth - element.clientWidth);
      const next = element.scrollLeft + itemWidth;
      element.scrollTo({ left: next > maximum && evaluate(properties.loop, scope) === true ? 0 : Math.min(next, maximum), behavior: "smooth" });
    }, interval);
    renderCleanups.push(() => clearInterval(timer));
  }
}

function bindDisclosureComponent(element, node, properties, page, scope) {
  const primitive = node.primitive;
  const show = evaluate(properties.show, scope) === true;
  const forceMount = evaluate(properties.force_mount, scope) === true;
  const surfaceClass = primitive === "popover" ? "popover-positioner" : `${primitive}-view`;
  const view = element.querySelector(`:scope > .axiom-${surfaceClass}`);
  const popoverBackdrop = primitive === "popover" ? element.querySelector(":scope > .axiom-popover-backdrop") : null;
  const trigger = element.querySelector(`:scope > .axiom-${primitive}-trigger`);
  const close = element.querySelector(`.axiom-${primitive}-close`);
  const backdrop = element.querySelector(`.axiom-${primitive}-backdrop`);
  const stateAction = properties.on_show_change || properties.on_visible_change;
  const setOpen = next => {
    assignControlledState(page, properties.show, next, stateAction);
    runAction(page, next ? properties.on_open : properties.on_close);
  };
  if (view) { view.hidden = !show && !forceMount; view.setAttribute("aria-hidden", String(!show)); }
  if (popoverBackdrop) { popoverBackdrop.hidden = !show && !forceMount; popoverBackdrop.setAttribute("aria-hidden", String(!show)); }
  if (trigger) {
    trigger.setAttribute("aria-expanded", String(show));
    const activate = event => {
      if (event.type === "keydown" && !["Enter", " "].includes(event.key)) return;
      event.preventDefault(); setOpen(!show);
    };
    addManagedListener(trigger, "click", activate); addManagedListener(trigger, "keydown", activate);
  }
  if (close) addManagedListener(close, "click", event => { event.preventDefault(); setOpen(false); });
  if (backdrop) {
    const backdropNode = [...node.children].flatMap(child => child.children || [])
      .find(child => child.semanticId.value === backdrop.dataset.axiomId);
    const backdropProperties = Object.fromEntries((backdropNode?.properties || []).map(property => [property.name, property.expression]));
    if (evaluate(backdropProperties.click_to_close, scope) === true) addManagedListener(backdrop, "click", event => { if (event.target === backdrop) setOpen(false); });
  }
  setComponentStateClass(element, "open", show);
  if (show && view) {
    const keydown = event => { if (event.key === "Escape") { event.preventDefault(); setOpen(false); } };
    addManagedListener(view, "keydown", keydown);
    queueMicrotask(() => view.querySelector("button,input,textarea,[tabindex]")?.focus({ preventScroll: true }));
  }
}

function bindDraggableComponent(element, properties, page, scope) {
  if (evaluate(properties.enabled, scope) === false) return;
  let origin = null;
  const direction = unquote(properties.direction) || "all";
  const down = event => { origin = { x: event.clientX, y: event.clientY }; element.setPointerCapture?.(event.pointerId); runAction(page, properties.on_drag_start); };
  const move = event => {
    if (!origin) return;
    const clamp = (value, min, max) => Math.min(Number.isFinite(max) ? max : value, Math.max(Number.isFinite(min) ? min : value, value));
    let x = clamp(event.clientX - origin.x, Number(evaluate(properties.min_x, scope)), Number(evaluate(properties.max_x, scope)));
    let y = clamp(event.clientY - origin.y, Number(evaluate(properties.min_y, scope)), Number(evaluate(properties.max_y, scope)));
    if (direction === "horizontal") y = 0; if (direction === "vertical") x = 0;
    element.style.transform = `translate(${x}px, ${y}px)`; runAction(page, properties.on_drag);
  };
  const up = () => { if (!origin) return; origin = null; if (evaluate(properties.reset_on_end, scope) === true) element.style.transform = ""; runAction(page, properties.on_drag_end); };
  addManagedListener(element, "pointerdown", down); addManagedListener(element, "pointermove", move);
  addManagedListener(element, "pointerup", up); addManagedListener(element, "pointercancel", up);
}

function bindSortableComponent(element, properties, page, scope) {
  if (evaluate(properties.enabled, scope) === false) return;
  let dragged = null;
  for (const item of element.children) {
    item.draggable = true;
    addManagedListener(item, "dragstart", () => { dragged = item; setComponentStateClass(item, "dragging", true); runAction(page, properties.on_sort_start); });
    addManagedListener(item, "dragover", event => { event.preventDefault(); if (dragged && dragged !== item) element.insertBefore(dragged, item); });
    addManagedListener(item, "dragend", () => { if (dragged) setComponentStateClass(dragged, "dragging", false); dragged = null; runAction(page, properties.on_sort_end); });
  }
}

function bindSwipeActionComponent(element, properties, page, scope) {
  if (evaluate(properties.enabled, scope) === false) return;
  const display = element.querySelector(":scope > .axiom-swipe-display");
  const actions = element.querySelector(":scope > .axiom-swipe-actions");
  if (!display || !actions) return;
  actions.hidden = true;
  let startX = null;
  const down = event => { startX = event.clientX; runAction(page, properties.on_swipe_start); };
  const up = event => {
    if (startX == null) return;
    const opened = Math.abs(event.clientX - startX) >= 32;
    startX = null; actions.hidden = !opened; display.hidden = opened;
    setComponentStateClass(element, "open", opened);
    runAction(page, properties.on_swipe_end);
    if (opened) runAction(page, properties.on_action);
  };
  addManagedListener(element, "pointerdown", down); addManagedListener(element, "pointerup", up); addManagedListener(element, "pointercancel", () => { startX = null; });
}

function bindOverlayBehavior(element, node, properties, page, scope) {
  const visible = evaluate(properties.visible, scope) === true;
  const previous = overlayVisibility.get(node.semanticId.value);
  overlayVisibility.set(node.semanticId.value, visible);
  element.hidden = !visible;
  element.setAttribute("role", "dialog");
  element.setAttribute("aria-modal", "true");
  if (properties.accessibility_label) element.setAttribute("aria-label", unquote(properties.accessibility_label));
  if (previous === false && visible) {
    const origin = document.activeElement?.dataset?.axiomId;
    if (origin) overlayFocusOrigins.set(node.semanticId.value, origin);
  }
  if (!visible) {
    if (previous === true) queueMicrotask(() => {
      const origin = overlayFocusOrigins.get(node.semanticId.value);
      const target = origin && [...root.querySelectorAll("[data-axiom-id]")]
        .find(candidate => candidate.dataset.axiomId === origin);
      target?.focus({ preventScroll: true });
      overlayFocusOrigins.delete(node.semanticId.value);
      if (properties.on_dismiss) runAction(page, properties.on_dismiss);
    });
    return;
  }
  const touch = () => properties.on_overlay_touch && runAction(page, properties.on_overlay_touch);
  const keydown = event => {
    if (event.key !== "Tab") return;
    const focusable = [...element.querySelectorAll("button,input,textarea,select,a[href],[tabindex]")]
      .filter(candidate => !candidate.disabled && candidate.tabIndex >= 0);
    if (!focusable.length) { event.preventDefault(); element.focus(); return; }
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  };
  element.tabIndex = -1;
  element.addEventListener("pointerdown", touch);
  element.addEventListener("keydown", keydown);
  renderCleanups.push(() => {
    element.removeEventListener("pointerdown", touch);
    element.removeEventListener("keydown", keydown);
  });
  queueMicrotask(() => {
    if (!element.isConnected) return;
    (element.querySelector("button,input,textarea,select,a[href],[tabindex]") || element).focus({ preventScroll: true });
    if (previous === false && properties.on_show) runAction(page, properties.on_show);
  });
}

function bindInputBehavior(element, node, properties, page, scope) {
  const multiline = node.primitive === "text_area";
  const stateName = String(properties.value || "").trim();
  element.value = String(evaluate(properties.value, scope) ?? "");
  element.placeholder = unquote(properties.placeholder);
  element.disabled = evaluate(properties.disabled, scope) === true;
  element.readOnly = evaluate(properties.read_only, scope) === true;
  const maxLength = Number(evaluate(properties.max_length, scope));
  if (Number.isInteger(maxLength) && maxLength > 0) element.maxLength = maxLength;
  if (properties.autofill) element.autocomplete = unquote(properties.autofill);
  if (properties.accessibility_label) element.setAttribute("aria-label", unquote(properties.accessibility_label));
  const inputType = unquote(properties.input_type) || "text";
  if (!multiline) {
    element.type = ["password", "email", "tel"].includes(inputType) ? inputType : "text";
    if (inputType === "digit") element.inputMode = "numeric";
    if (inputType === "number") element.inputMode = "decimal";
  } else {
    if (inputType !== "text") element.inputMode = { number: "decimal", digit: "numeric", tel: "tel", email: "email" }[inputType] || "text";
    const maxLines = Number(evaluate(properties.max_lines, scope));
    if (Number.isInteger(maxLines) && maxLines > 0) element.rows = maxLines;
    const lineSpacing = Number(evaluate(properties.line_spacing, scope));
    if (Number.isFinite(lineSpacing)) element.style.lineHeight = `${lineSpacing}px`;
  }
  let composing = false;
  const setBoundState = (property, value) => {
    const binding = String(properties[property] || "").trim();
    if (binding) pageState(page).set(binding, value);
  };
  const add = (event, listener) => {
    element.addEventListener(event, listener);
    renderCleanups.push(() => element.removeEventListener(event, listener));
  };
  const updateSelection = () => {
    setBoundState("selection_start", element.selectionStart ?? 0);
    setBoundState("selection_end", element.selectionEnd ?? 0);
  };
  add("compositionstart", () => { composing = true; setBoundState("composing", true); });
  add("compositionend", () => { composing = false; setBoundState("composing", false); render(false); });
  add("input", event => {
    if (!event.isComposing && !composing && properties.input_filter) {
      const allowed = new RegExp(unquote(properties.input_filter));
      element.value = Array.from(element.value).filter(character => { allowed.lastIndex = 0; return allowed.test(character); }).join("");
    }
    if (multiline && properties.max_lines) {
      const maxLines = Number(evaluate(properties.max_lines, scope));
      if (Number.isInteger(maxLines) && maxLines > 0) element.value = element.value.split("\n").slice(0, maxLines).join("\n");
    }
    pageState(page).set(stateName, element.value);
    updateSelection();
    setBoundState("composing", Boolean(event.isComposing || composing));
    if (properties.on_input) runAction(page, properties.on_input);
    if (!event.isComposing && !composing) render(false);
  });
  add("select", () => { updateSelection(); if (properties.on_selection) runAction(page, properties.on_selection); });
  add("focus", () => { setBoundState("focused", true); if (properties.on_focus) runAction(page, properties.on_focus); });
  add("blur", () => { setBoundState("focused", false); if (properties.on_blur) runAction(page, properties.on_blur); });
  add("keydown", event => {
    if (event.key === "Enter" && (!multiline || properties.confirm_type)) {
      if (properties.on_confirm) runAction(page, properties.on_confirm);
    }
  });
}

function bindCollectionBehavior(element, node, properties, page, scope) {
  const primitive = node.primitive;
  const collectionPrimitive = {
    scroll_area: "scroll_view", list_view: "list", feed_list: "list", sortable: "list", swiper: "view_pager",
  }[primitive] || primitive;
  const collectionProperties = { ...properties };
  collectionProperties.scroll_orientation ??= properties.orientation;
  collectionProperties.enable_scroll ??= properties.enabled;
  collectionProperties.initial_scroll_index ??= properties.initial_index;
  collectionProperties.initial_select_index ??= properties.initial_index;
  collectionProperties.on_content_size_changed ??= properties.on_content_size_change;
  if (["scroll", "scroll_view", "list", "view_pager", "scroll_coordinator_slot"].includes(collectionPrimitive)) {
    const horizontal = unquote(collectionProperties.scroll_orientation) === "horizontal" || collectionPrimitive === "view_pager";
    element.style.overflowX = evaluate(collectionProperties.enable_scroll, scope) === false ? "hidden" : (horizontal ? "auto" : "hidden");
    element.style.overflowY = evaluate(collectionProperties.enable_scroll, scope) === false ? "hidden" : (horizontal ? "hidden" : "auto");
    element.style.scrollbarWidth = evaluate(properties.scroll_bar_enable, scope) === false ? "none" : "auto";
    if (collectionPrimitive === "list") {
      const type = unquote(properties.list_type);
      const spans = Math.max(1, Number(evaluate(properties.span_count, scope)) || 1);
      element.style.display = type === "single" ? "flex" : "grid";
      element.style.flexDirection = horizontal ? "row" : "column";
      if (type !== "single") element.style.gridTemplateColumns = `repeat(${spans}, minmax(0, 1fr))`;
      queueMicrotask(() => {
        const computed = getComputedStyle(element);
        const mainGap = computed.getPropertyValue("--axiom-list-main-axis-gap");
        const crossGap = computed.getPropertyValue("--axiom-list-cross-axis-gap");
        if (horizontal) { if (mainGap) element.style.columnGap = mainGap; if (crossGap) element.style.rowGap = crossGap; }
        else { if (mainGap) element.style.rowGap = mainGap; if (crossGap) element.style.columnGap = crossGap; }
      });
      element.style.overscrollBehavior = evaluate(properties.enable_nested_scroll, scope) === true ? "auto" : "contain";
      const snap = evaluate(properties.item_snap, scope);
      if (snap && typeof snap === "object") element.style.scrollSnapType = `${horizontal ? "x" : "y"} mandatory`;
      for (const child of element.children) if (snap) child.style.scrollSnapAlign = Number(snap.factor) >= 0.5 ? "end" : "start";
    }
    if (collectionPrimitive === "view_pager") {
      element.style.display = "flex"; element.style.scrollSnapType = "x mandatory";
      const itemWidth = Number(evaluate(properties.item_width, scope));
      for (const child of element.children) { child.style.flex = `0 0 ${Number.isFinite(itemWidth) ? `${itemWidth}px` : "100%"}`; child.style.scrollSnapAlign = "start"; }
    }
    let previous = horizontal ? element.scrollLeft : element.scrollTop;
    let scrollEndTimer;
    let lastScrollEvent = 0;
    let scrolling = false;
    let listAtUpper = false;
    let listAtLower = false;
    let pagerIndex = Number(evaluate(collectionProperties.initial_select_index, scope)) || 0;
    const onScroll = () => {
      const now = performance.now();
      const offset = horizontal ? element.scrollLeft : element.scrollTop;
      const throttle = Math.max(0, Number(evaluate(properties.scroll_event_throttle, scope)) || 0);
      if (!scrolling && properties.on_scroll_state_change) runAction(page, properties.on_scroll_state_change);
      if (!scrolling && primitive === "swiper" && properties.on_swipe_start) runAction(page, properties.on_swipe_start);
      scrolling = true;
      if ((!throttle || now - lastScrollEvent >= throttle) && properties.on_scroll) { lastScrollEvent = now; runAction(page, properties.on_scroll); }
      if (properties.on_offset_change) runAction(page, properties.on_offset_change);
      if (properties.on_offset) runAction(page, properties.on_offset);
      const upper = Number(evaluate(properties.upper_threshold, scope)) || 0;
      const lower = Number(evaluate(properties.lower_threshold, scope)) || 0;
      const maximum = horizontal ? element.scrollWidth - element.clientWidth : element.scrollHeight - element.clientHeight;
      if (offset <= upper && previous > upper && properties.on_scroll_to_upper) runAction(page, properties.on_scroll_to_upper);
      if (offset >= maximum - lower && previous < maximum - lower && properties.on_scroll_to_lower) runAction(page, properties.on_scroll_to_lower);
      if (collectionPrimitive === "list") {
        const cells = [...element.children];
        const firstVisible = cells.findIndex(cell => horizontal ? cell.offsetLeft + cell.offsetWidth >= element.scrollLeft : cell.offsetTop + cell.offsetHeight >= element.scrollTop);
        const visibleCount = cells.filter(cell => horizontal ? cell.offsetLeft < element.scrollLeft + element.clientWidth && cell.offsetLeft + cell.offsetWidth > element.scrollLeft : cell.offsetTop < element.scrollTop + element.clientHeight && cell.offsetTop + cell.offsetHeight > element.scrollTop).length;
        const upperCount = Number(evaluate(properties.upper_threshold_item_count, scope)) || 0;
        const lowerCount = Number(evaluate(properties.lower_threshold_item_count, scope)) || 0;
        const atUpper = firstVisible <= upperCount;
        const atLower = cells.length - Math.max(0, firstVisible) - visibleCount <= lowerCount;
        if (atUpper && !listAtUpper && properties.on_scroll_to_upper) runAction(page, properties.on_scroll_to_upper);
        if (atLower && !listAtLower && properties.on_scroll_to_lower) runAction(page, properties.on_scroll_to_lower);
        listAtUpper = atUpper;
        listAtLower = atLower;
      }
      if (collectionPrimitive === "view_pager" && element.clientWidth > 0) {
        const itemWidth = Number(evaluate(properties.item_width, scope)) || element.clientWidth;
        const next = Math.round(element.scrollLeft / itemWidth);
        if (next !== pagerIndex && properties.on_will_change) runAction(page, properties.on_will_change);
        pagerIndex = next;
      }
      previous = offset;
      clearTimeout(scrollEndTimer);
      scrollEndTimer = setTimeout(() => {
        scrolling = false;
        if (properties.on_scroll_end) runAction(page, properties.on_scroll_end);
        if (properties.on_scroll_state_change) runAction(page, properties.on_scroll_state_change);
        if (properties.on_snap) runAction(page, properties.on_snap);
        if (primitive === "swiper" && properties.on_swipe_stop) runAction(page, properties.on_swipe_stop);
        if (collectionPrimitive === "view_pager" && properties.on_change) runAction(page, properties.on_change);
      }, 120);
    };
    element.addEventListener("scroll", onScroll, { passive: true });
    renderCleanups.push(() => { clearTimeout(scrollEndTimer); element.removeEventListener("scroll", onScroll); });
    if (!initializedCollections.has(node.semanticId.value)) {
      initializedCollections.add(node.semanticId.value);
      queueMicrotask(() => {
        if (collectionPrimitive === "view_pager") element.scrollLeft = pagerIndex * (Number(evaluate(properties.item_width, scope)) || element.clientWidth);
        else if (properties.initial_scroll_offset) {
          const offset = Number(evaluate(properties.initial_scroll_offset, scope)) || 0;
          if (horizontal) element.scrollLeft = offset; else element.scrollTop = offset;
        } else {
          const initialIndex = collectionProperties.initial_scroll_index ?? properties.initial_scroll_to_index;
          if (initialIndex !== undefined) element.children[Number(evaluate(initialIndex, scope)) || 0]?.scrollIntoView({ block: "start" });
        }
      });
    }
    if (collectionProperties.on_content_size_changed) {
      const observer = new ResizeObserver(() => runAction(page, collectionProperties.on_content_size_changed));
      observer.observe(element); renderCleanups.push(() => observer.disconnect());
    }
    if (collectionPrimitive === "list" && properties.on_layout_complete) queueMicrotask(() => runAction(page, properties.on_layout_complete));
    if (primitive === "feed_list" && properties.on_refresh) {
      const refresh = event => {
        if (element.scrollTop <= 0 && event.deltaY < 0) runAction(page, properties.on_refresh);
      };
      addManagedListener(element, "wheel", refresh, { passive: true });
    }
  }
  if (primitive === "refresh") {
    let startY = null;
    const down = event => { if (evaluate(properties.enable_refresh, scope) !== false) startY = event.clientY; };
    const move = event => {
      if (startY == null) return;
      const offset = Math.max(0, event.clientY - startY);
      element.style.setProperty("--axiom-refresh-offset", `${offset}px`);
      const header = element.querySelector(":scope > .axiom-refresh-header");
      if (header) header.style.transform = `translateY(${offset}px)`;
      if (properties.on_header_offset) runAction(page, properties.on_header_offset);
    };
    const up = event => {
      if (startY == null) return;
      const triggered = event.clientY - startY >= 48;
      startY = null;
      if (triggered) { element.dataset.refreshing = "true"; if (properties.on_refresh_state_change) runAction(page, properties.on_refresh_state_change); if (properties.on_start_refresh) runAction(page, properties.on_start_refresh); }
      else {
        element.style.removeProperty("--axiom-refresh-offset");
        const header = element.querySelector(":scope > .axiom-refresh-header");
        if (header) header.style.transform = "";
      }
    };
    element.addEventListener("pointerdown", down); element.addEventListener("pointermove", move); element.addEventListener("pointerup", up); element.addEventListener("pointercancel", up);
    renderCleanups.push(() => { element.removeEventListener("pointerdown", down); element.removeEventListener("pointermove", move); element.removeEventListener("pointerup", up); element.removeEventListener("pointercancel", up); });
  }
}

function applyCoreAttributes(element, properties, scope) {
  const aria = {
    accessibility_label: "aria-label",
    accessibility_elements_hidden: "aria-hidden",
  };
  for (const [property, attribute] of Object.entries(aria)) {
    if (properties[property] !== undefined) element.setAttribute(attribute, String(evaluate(properties[property], scope)));
  }
  if (evaluate(properties.accessibility_element, scope) === false) element.setAttribute("role", "presentation");
  if (properties.accessibility_trait) element.setAttribute("role", unquote(properties.accessibility_trait).split(/\s+/)[0]);
  if (evaluate(properties.user_interaction_enabled, scope) === false || evaluate(properties.native_interaction_enabled, scope) === false) {
    element.style.pointerEvents = "none";
  }
  if (evaluate(properties.event_through, scope) === true) element.style.pointerEvents = "none";
  if (evaluate(properties.block_native_event, scope) === true) {
    const block = event => { event.preventDefault(); event.stopPropagation(); };
    ["pointerdown", "pointermove", "pointerup", "click"].forEach(event => element.addEventListener(event, block));
  }
  for (const [name, expression] of Object.entries(properties)) {
    if (!name.startsWith("data_")) continue;
    element.setAttribute(`data-${name.slice(5).replaceAll("_", "-")}`, String(evaluate(expression, scope)));
  }
}

function bindCoreEvents(element, properties, page) {
  const events = {
    on_touch_start: "pointerdown", on_touch_move: "pointermove", on_touch_end: "pointerup",
    on_touch_cancel: "pointercancel", on_tap: "click", on_click: "click",
    on_animation_start: "animationstart", on_animation_end: "animationend",
    on_animation_cancel: "animationcancel", on_animation_iteration: "animationiteration",
    on_transition_start: "transitionstart", on_transition_end: "transitionend",
    on_transition_cancel: "transitioncancel", on_load: "load", on_error: "error",
  };
  for (const [property, event] of Object.entries(events)) {
    if (properties[property]) element.addEventListener(event, () => runAction(page, properties[property]));
  }
  if (properties.on_long_press) {
    let timer;
    const cancel = () => clearTimeout(timer);
    element.addEventListener("pointerdown", () => { timer = setTimeout(() => runAction(page, properties.on_long_press), 500); });
    ["pointerup", "pointercancel", "pointerleave"].forEach(event => element.addEventListener(event, cancel));
  }
  if (properties.on_layout_change || properties.on_layout) {
    const observer = new ResizeObserver(() => runAction(page, properties.on_layout_change || properties.on_layout));
    observer.observe(element); renderCleanups.push(() => observer.disconnect());
  }
  if (properties.on_ui_appear || properties.on_ui_disappear) {
    let visible = false;
    const observer = new IntersectionObserver(entries => {
      const next = Boolean(entries[0]?.isIntersecting);
      if (next && !visible && properties.on_ui_appear) runAction(page, properties.on_ui_appear);
      if (!next && visible && properties.on_ui_disappear) runAction(page, properties.on_ui_disappear);
      visible = next;
    });
    observer.observe(element); renderCleanups.push(() => observer.disconnect());
  }
  if (properties.on_selection_change) {
    const listener = () => {
      const selection = window.getSelection();
      if (selection && (element.contains(selection.anchorNode) || element.contains(selection.focusNode))) {
        runAction(page, properties.on_selection_change);
      }
    };
    document.addEventListener("selectionchange", listener);
    renderCleanups.push(() => document.removeEventListener("selectionchange", listener));
  }
}

function renderChildren(children, page, scope) {
  const fragment = document.createDocumentFragment();
  for (const child of children) fragment.append(renderNode(child, page, scope));
  return fragment;
}

async function runOperation(binding, page) {
  const state = binding.__state;
  state.pending = true; state.error = null; render(false);
  try {
    const value = await callOperation(binding, pageScope(page), page);
    if (binding.kind !== "stream") state.data = Array.isArray(value) ? value : value == null ? [] : [value];
  }
  catch (error) {
    if (!error.axiomCancelled) {
      state.error = error;
      diagnostic("WEB_CONTRACT", error.message || String(error));
    }
  }
  finally { state.pending = false; render(false); }
}

function runAction(page, expression) {
  const action = page.actions.find(candidate => candidate.name === expression);
  if (!action) return;
  let needsRender = false;
  for (const step of action.steps) {
    if (step.kind === "operation_run") {
      const binding = page.operations.find(candidate => candidate.name === step.operation);
      if (binding) void runOperation(binding, page).then(() => {
        const spec = operations.get(`${binding.contractLocalName}.${binding.operation}`);
        if (spec?.kind === "mutation") page.operations.filter(candidate => candidate.kind === "query").forEach(query => void runOperation(query, page));
      });
    } else if (step.kind === "state_assign") {
      const next = evaluate(step.expression, pageScope(page));
      if (!Object.is(pageState(page).get(step.state), next)) {
        pageState(page).set(step.state, next);
        needsRender = true;
      }
    }
    else if (step.kind === "navigate") { cancelPageOperations(page); history.push(step.path); currentPath = step.path; window.history.pushState({}, "", step.path); needsRender = true; }
    else if (step.kind === "navigate_back" && history.length > 1) { cancelPageOperations(page); history.pop(); currentPath = history.at(-1); window.history.back(); needsRender = true; }
    else if (step.kind === "node_invoke") invokeElementMethod(step, page);
  }
  if (needsRender) render(false);
}

function invokeElementMethod(step, page) {
  const element = document.getElementById(step.node_id);
  if (!element) { diagnostic("WEB_ELEMENT_METHOD", `Element #${step.node_id} is unavailable`); return; }
  const params = parseRecord(step.arguments, pageScope(page));
  switch (step.method) {
    case "bounding_client_rect": element.getBoundingClientRect(); break;
    case "request_accessibility_focus": element.focus({ preventScroll: false }); break;
    case "pause_animation": case "stop_animation": element.style.animationPlayState = "paused"; break;
    case "resume_animation": case "start_animate": element.style.animationPlayState = "running"; break;
    case "set_text_selection": {
      const selection = window.getSelection(); const range = document.createRange();
      const text = element.firstChild;
      if (selection && text?.nodeType === Node.TEXT_NODE) { range.setStart(text, Math.max(0, params.start_x || 0)); range.setEnd(text, Math.max(0, params.end_x || 0)); selection.removeAllRanges(); selection.addRange(range); }
      break;
    }
    case "get_text_bounding_rect": case "get_selected_text": break;
    case "auto_scroll": {
      const rate = Number.parseFloat(params.rate) || 0;
      const horizontal = element.scrollWidth > element.clientWidth && element.scrollHeight <= element.clientHeight;
      if (element.__axiomAutoScroll) clearInterval(element.__axiomAutoScroll);
      if (params.start !== false && rate !== 0) {
        element.__axiomAutoScroll = setInterval(() => {
          if (horizontal) element.scrollLeft += rate / 60; else element.scrollTop += rate / 60;
          const atEnd = horizontal ? element.scrollLeft + element.clientWidth >= element.scrollWidth : element.scrollTop + element.clientHeight >= element.scrollHeight;
          if (params.auto_stop !== false && atEnd) { clearInterval(element.__axiomAutoScroll); element.__axiomAutoScroll = null; }
        }, 1000 / 60);
        renderCleanups.push(() => { clearInterval(element.__axiomAutoScroll); element.__axiomAutoScroll = null; });
      }
      break;
    }
    case "get_scroll_info": element.getBoundingClientRect(); break;
    case "scroll_by": element.scrollBy({ [element.scrollWidth > element.clientWidth ? "left" : "top"]: Number(params.offset) || 0, behavior: "auto" }); break;
    case "scroll_to": {
      const child = element.children[Number(params.index) || 0];
      if (child) child.scrollIntoView({ behavior: params.smooth ? "smooth" : "auto", block: "start" });
      else element.scrollTo({ top: Number(params.offset) || 0, behavior: params.smooth ? "smooth" : "auto" });
      break;
    }
    case "scroll_to_position": {
      const cells = [...element.children];
      const child = params.item_key == null ? cells[Number(params.position) || 0] : cells.find(cell => cell.dataset.itemKey === String(params.item_key));
      child?.scrollIntoView({ behavior: params.smooth ? "smooth" : "auto", block: params.align_to === "middle" ? "center" : (params.align_to || "start") });
      if (params.offset) element.scrollBy({ top: Number(params.offset), behavior: "auto" });
      break;
    }
    case "get_visible_cells": [...element.children].filter(child => { const item = child.getBoundingClientRect(), bounds = element.getBoundingClientRect(); return item.bottom > bounds.top && item.top < bounds.bottom && item.right > bounds.left && item.left < bounds.right; }); break;
    case "auto_start_refresh": element.dataset.refreshing = "true"; break;
    case "finish_refresh": {
      element.dataset.refreshing = "false";
      element.style.removeProperty("--axiom-refresh-offset");
      const header = element.querySelector(":scope > .axiom-refresh-header");
      if (header) header.style.transform = "";
      break;
    }
    case "select_tab": element.scrollTo({ left: (Number(params.index) || 0) * element.clientWidth, behavior: params.smooth === false ? "auto" : "smooth" }); break;
    case "set_fold_expanded": element.scrollTo({ top: Number.parseFloat(params.offset) || 0, behavior: params.smooth ? "smooth" : "auto" }); break;
    case "blur": element.blur(); break;
    case "focus": element.focus({ preventScroll: false }); break;
    case "get_value": ({ value: element.value, selectionStart: element.selectionStart, selectionEnd: element.selectionEnd, isComposing: false }); break;
    case "set_selection_range": element.setSelectionRange(Number(params.selection_start) || 0, Number(params.selection_end) || 0); break;
    case "set_value": {
      element.value = String(params.value ?? "");
      element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText", data: null }));
      break;
    }
    case "take_screenshot": diagnostic("WEB_ELEMENT_METHOD", "take_screenshot is delegated to browser tooling on Web", "warning"); break;
  }
}

function initializePage(page) {
  const states = pageState(page);
  for (const state of page.states) if (!states.has(state.name)) states.set(state.name, evaluate(state.initializer));
  for (const binding of page.operations) {
    binding.__state ||= { pending: false, data: [], error: null };
    if (binding.kind !== "mutation" && !binding.__started) { binding.__started = true; queueMicrotask(() => runOperation(binding, page)); }
  }
}

function render(resetState) {
  if (resetState) { statesByPage = new Map(); initializedCollections = new Set(); overlayVisibility = new Map(); overlayFocusOrigins = new Map(); }
  // Keep teardown for the currently mounted tree separate from listeners and
  // observers registered while constructing its replacement. Clearing one
  // shared array after construction silently detached every new component.
  const previousCleanups = renderCleanups;
  renderCleanups = [];
  const route = model.ir.routes.find(candidate => candidate.path === currentPath) || model.ir.routes[0];
  const page = model.ir.pages.find(candidate => candidate.name === route?.page) || model.ir.pages[0];
  if (!page) throw new Error("Axiom web host received no page");
  initializePage(page);
  const active = document.activeElement?.dataset?.axiomId ? {
    semanticId: document.activeElement.dataset.axiomId,
    selectionStart: document.activeElement.selectionStart,
    selectionEnd: document.activeElement.selectionEnd,
  } : null;
  const scrollPositions = new Map([...root.querySelectorAll("[data-axiom-id]")]
    .filter(element => element.scrollTop || element.scrollLeft)
    .map(element => [element.dataset.axiomId, [element.scrollLeft, element.scrollTop]]));
  const shell = document.createElement("div");
  shell.className = `axiom-page${reducedMotionQuery.matches ? " axiom-reduced-motion" : ""}`;
  shell.append(renderChildren(page.view, page, pageScope(page)));
  previousCleanups.forEach(cleanup => cleanup());
  root.replaceChildren(shell);
  for (const element of root.querySelectorAll("[data-axiom-id]")) {
    const position = scrollPositions.get(element.dataset.axiomId);
    if (position) { element.scrollLeft = position[0]; element.scrollTop = position[1]; }
  }
  if (active) {
    const input = [...root.querySelectorAll("input[data-axiom-id], textarea[data-axiom-id]")]
      .find(element => element.dataset.axiomId === active.semanticId);
    if (input) {
      input.focus({ preventScroll: true });
      if (Number.isInteger(active.selectionStart) && Number.isInteger(active.selectionEnd)) {
        input.setSelectionRange(active.selectionStart, active.selectionEnd);
      }
    } else {
      const focused = [...root.querySelectorAll("[data-axiom-id]")]
        .find(element => element.dataset.axiomId === active.semanticId);
      focused?.focus({ preventScroll: true });
    }
  }
}

async function load() {
  model = await fetch("/__axiom/app.json", { cache: "no-store" }).then(response => response.json());
  model.tokens = Object.fromEntries(model.ir.theme.map(token => [`${token.namespace}.${token.name}`, /^\d+(\.\d+)?$/.test(token.value) ? Number(token.value) : unquote(token.value)]));
  applyStylesheet();
  await initializeRuntime(model.runtimeConfig);
  render(true);
  if (model.hotReload === true) {
    new EventSource("/__axiom/events").addEventListener("reload", async event => {
      const update = JSON.parse(event.data);
      if (update.graphRevision === model.graphRevision) return;
      model = await fetch("/__axiom/app.json", { cache: "no-store" }).then(response => response.json());
      model.tokens = Object.fromEntries(model.ir.theme.map(token => [`${token.namespace}.${token.name}`, /^\d+(\.\d+)?$/.test(token.value) ? Number(token.value) : unquote(token.value)]));
      applyStylesheet();
      if (!update.preserveState) { cancelPendingOperations("Axiom web UI reset during hot reload."); location.reload(); return; }
      render(false);
    });
  }
}
window.addEventListener("popstate", () => {
  const current = model.ir.routes.find(candidate => candidate.path === currentPath);
  const page = model.ir.pages.find(candidate => candidate.name === current?.page);
  if (page) cancelPageOperations(page);
  currentPath = location.pathname;
  render(false);
});
window.addEventListener("pagehide", () => { renderCleanups.forEach(cleanup => cleanup()); renderCleanups = []; cancelPendingOperations(); });
reducedMotionQuery.addEventListener("change", () => { if (model) render(false); });
load().catch(error => { diagnostic("WEB_BOOT", error.message || String(error)); root.textContent = `Axiom UI failed to start: ${error.message || error}`; });
