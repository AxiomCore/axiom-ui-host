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
  if (node.primitive === "list") {
    const container = document.createElement("div"); container.className = "axiom-list";
    const items = evaluate(properties.items, scope);
    for (const item of Array.isArray(items) ? items : []) container.append(renderChildren(node.children, page, { ...scope, [node.iterator || "item"]: item }));
    return container;
  }
  const tags = { text: "span", image: "img", input: "input", button: "button", pressable: "button", scroll: "div", view: "div", safe_area: "section" };
  const element = document.createElement(tags[node.primitive] || "div");
  element.dataset.axiomId = node.semanticId.value;
  element.className = `axiom-${node.primitive.replaceAll("_", "-")}`;
  Object.assign(element.style, styleFor(node, scope));
  if (node.primitive === "text") element.textContent = String(evaluate(properties.value, scope) ?? "");
  else if (node.primitive === "image") { element.src = evaluate(properties.source, scope); element.alt = unquote(properties.alt); }
  else if (node.primitive === "input") {
    element.type = "text"; element.value = String(evaluate(properties.value, scope) ?? ""); element.placeholder = unquote(properties.placeholder);
    element.setAttribute("aria-label", unquote(properties.accessibility_label));
    element.addEventListener("input", () => { pageState(page).set(properties.value, element.value); });
  } else if (["button", "pressable"].includes(node.primitive)) {
    element.textContent = String(evaluate(properties.label || properties.accessibility_label, scope) ?? "Action");
    element.disabled = Boolean(evaluate(properties.disabled, scope));
    element.addEventListener("click", () => runAction(page, properties.on_press));
  } else element.append(renderChildren(node.children, page, scope));
  return element;
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
  for (const step of action.steps) {
    if (step.kind === "operation_run") {
      const binding = page.operations.find(candidate => candidate.name === step.operation);
      if (binding) void runOperation(binding, page).then(() => {
        const spec = operations.get(`${binding.contractLocalName}.${binding.operation}`);
        if (spec?.kind === "mutation") page.operations.filter(candidate => candidate.kind === "query").forEach(query => void runOperation(query, page));
      });
    } else if (step.kind === "state_assign") pageState(page).set(step.state, evaluate(step.expression, pageScope(page)));
    else if (step.kind === "navigate") { cancelPageOperations(page); history.push(step.path); currentPath = step.path; window.history.pushState({}, "", step.path); }
    else if (step.kind === "navigate_back" && history.length > 1) { cancelPageOperations(page); history.pop(); currentPath = history.at(-1); window.history.back(); }
  }
  render(false);
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
  if (resetState) statesByPage = new Map();
  const route = model.ir.routes.find(candidate => candidate.path === currentPath) || model.ir.routes[0];
  const page = model.ir.pages.find(candidate => candidate.name === route?.page) || model.ir.pages[0];
  if (!page) throw new Error("Axiom web host received no page");
  initializePage(page);
  const shell = document.createElement("div"); shell.className = "axiom-page";
  shell.append(renderChildren(page.view, page, pageScope(page)));
  root.replaceChildren(shell);
}

async function load() {
  model = await fetch("/__axiom/app.json", { cache: "no-store" }).then(response => response.json());
  model.tokens = Object.fromEntries(model.ir.theme.map(token => [`${token.namespace}.${token.name}`, /^\d+(\.\d+)?$/.test(token.value) ? Number(token.value) : unquote(token.value)]));
  await initializeRuntime(model.runtimeConfig);
  render(true);
  if (model.hotReload === true) {
    new EventSource("/__axiom/events").addEventListener("reload", async event => {
      const update = JSON.parse(event.data);
      if (update.graphRevision === model.graphRevision) return;
      model = await fetch("/__axiom/app.json", { cache: "no-store" }).then(response => response.json());
      model.tokens = Object.fromEntries(model.ir.theme.map(token => [`${token.namespace}.${token.name}`, /^\d+(\.\d+)?$/.test(token.value) ? Number(token.value) : unquote(token.value)]));
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
window.addEventListener("pagehide", () => cancelPendingOperations());
load().catch(error => { diagnostic("WEB_BOOT", error.message || String(error)); root.textContent = `Axiom UI failed to start: ${error.message || error}`; });
