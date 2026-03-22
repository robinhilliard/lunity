/**
 * Browser bootstrap for Lunity.Web.PlayerSocket — mirrors `Lunity.Player.WsClient`.
 * Transcript lines are logged to #log for parity with `mix lunity.player` (verbose).
 */

const WS_PATH = "/ws/player/websocket";

function log(line) {
  const el = document.getElementById("log");
  if (!el) return;
  el.textContent += line + "\n";
}

function parseQuery() {
  const s = new URLSearchParams(window.location.search);
  if (s.has("no_mint_form")) {
    const form = document.getElementById("mint-form");
    if (form) form.style.display = "none";
  }
  return {
    token: s.get("token") || "",
    jwt: s.get("jwt") || "",
    mintKey: s.get("mint_key") || "",
    userId: s.get("user_id") || "",
    playerId: s.get("player_id") || "",
    authOnly: s.get("auth_only") === "1" || s.get("auth_only") === "true",
    hintsRaw: s.get("hints") || "",
    skip_followup:
      s.get("skip_followup") === "1" || s.get("skip_followup") === "true",
    resume: s.get("resume") === "1" || s.get("resume") === "true",
    /** `live=1` — keep WebSocket open; show periodic `state.ecs` in #state (Phase 3). */
    live:
      s.get("live") === "1" ||
      s.get("live") === "true" ||
      s.get("stream_state") === "1"
  };
}

function parseHints(raw) {
  if (!raw || raw.trim() === "") return null;
  try {
    const h = JSON.parse(raw);
    if (h !== null && typeof h === "object" && !Array.isArray(h)) return h;
    throw new Error("hints must be a JSON object");
  } catch (e) {
    throw new Error(`invalid hints JSON: ${e.message}`);
  }
}

/** @param {string} baseUrl http(s)://host[:port] */
function buildWsUrl(baseUrl, wsToken) {
  const u = new URL(baseUrl, window.location.origin);
  const wsScheme = u.protocol === "https:" ? "wss" : "ws";
  const portPart = u.port ? `:${u.port}` : "";
  const q = new URLSearchParams({ token: wsToken });
  return `${wsScheme}://${u.hostname}${portPart}${WS_PATH}?${q.toString()}`;
}

async function mintJwt(baseUrl, mintKey, userId, playerId) {
  const url = new URL("/api/player/token", baseUrl).toString();
  const body = { user_id: userId, player_id: playerId || userId };
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-player-mint-key": mintKey
    },
    body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(`mint HTTP ${res.status}: ${JSON.stringify(data)}`);
  }
  if (typeof data.token !== "string") {
    throw new Error(`mint: missing token in body: ${JSON.stringify(data)}`);
  }
  return data.token;
}

/**
 * @param {{ wsUrl: string, jwt: string, hints: object | null, authOnly: boolean, followup?: boolean, resume?: boolean, streamState?: boolean }} opts
 * @returns {Promise<object>} Resolves with `assigned` / `subscribeAck` / `actionsAck`; `fromResume` is true when the resume branch skipped `join`. With `streamState`, the promise stays pending until the socket closes.
 */
function runBootstrap(opts) {
  const {
    wsUrl,
    jwt,
    hints,
    authOnly,
    followup = true,
    resume = false,
    streamState = false
  } = opts;

  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    let phase = "welcome";
    let settled = false;
    /** @type {object | null} */
    let lastAssigned = null;
    /** @type {object | null} */
    let lastSubscribeAck = null;
    /** Whether we took the resume branch (skip join). */
    let fromResume = false;

    const finish = (fn, arg) => {
      if (settled) return;
      settled = true;
      fn(arg);
    };

    log(`-> ${wsUrl.replace(/token=[^&]+/, "token=…")}`);

    ws.onopen = () => {
      log("[lunity.player] tcp + ws handshake ok");
    };

    ws.onerror = () => {
      finish(
        reject,
        new Error(
          "WebSocket error (connection rejected or failed — e.g. Phoenix check_origin if host differs from page URL)"
        )
      );
    };

    ws.onclose = (ev) => {
      if (phase === "streaming") {
        log(`(WebSocket closed, code ${ev.code})`);
        return;
      }
      if (!settled && phase !== "done") {
        finish(reject, new Error(`WebSocket closed prematurely (code ${ev.code})`));
      }
    };

    ws.onmessage = (ev) => {
      const raw = ev.data;
      log(`<- ${raw}`);

      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        reject(new Error("invalid JSON from server"));
        return;
      }

      if (msg.t === "error") {
        finish(reject, errFromServer(msg));
        return;
      }

      try {
        if (phase === "welcome") {
          if (msg.t !== "welcome") {
            throw new Error(`expected welcome, got ${msg.t}`);
          }
          const out = JSON.stringify({ v: 1, t: "hello" });
          log(`-> ${out}`);
          ws.send(out);
          phase = "expect_hello_ack";
        } else if (phase === "expect_hello_ack") {
          if (msg.t !== "hello_ack") {
            throw new Error(`expected hello_ack, got ${msg.t}`);
          }
          const authObj = { v: 1, t: "auth", token: jwt };
          if (resume) authObj.resume = true;
          const out = JSON.stringify(authObj);
          log(`-> ${out.replace(/"token":"[^"]*"/, '"token":"…"')}`);
          ws.send(out);
          phase = "expect_auth_ack";
        } else if (phase === "expect_auth_ack") {
          if (msg.t !== "ack") {
            throw new Error(`expected ack, got ${msg.t}`);
          }
          if (authOnly) {
            phase = "done";
            ws.close();
            finish(resolve, { authenticated: msg });
            return;
          }
          if (msg.resumed && msg.instance_id) {
            fromResume = true;
            lastAssigned = {
              t: "assigned",
              instance_id: msg.instance_id,
              entity_id: msg.entity_id != null ? msg.entity_id : null,
              spawn: msg.spawn != null ? msg.spawn : null
            };
            log("(resume) skip join — ack carried instance_id; subscribe_state …");
            if (!followup && !streamState) {
              phase = "done";
              ws.close();
              finish(resolve, { assigned: lastAssigned, fromResume: true });
              return;
            }
            const sub = JSON.stringify({ v: 1, t: "subscribe_state", filter: null });
            log(`-> ${sub}`);
            ws.send(sub);
            phase = "expect_subscribe_ack";
            return;
          }
          const join = { v: 1, t: "join" };
          if (hints && Object.keys(hints).length > 0) {
            join.hints = hints;
          }
          const out = JSON.stringify(join);
          log(`-> ${out}`);
          ws.send(out);
          phase = "expect_assigned";
        } else if (phase === "expect_assigned") {
          if (msg.t !== "assigned") {
            throw new Error(`expected assigned, got ${msg.t}`);
          }
          lastAssigned = msg;
          if (!followup && !streamState) {
            phase = "done";
            ws.close();
            finish(resolve, { assigned: msg });
            return;
          }
          const sub = JSON.stringify({ v: 1, t: "subscribe_state", filter: null });
          log(`-> ${sub}`);
          ws.send(sub);
          phase = "expect_subscribe_ack";
        } else if (phase === "expect_subscribe_ack") {
          if (msg.t === "state") {
            log("(ignoring state before subscribe_ack)");
            return;
          }
          if (msg.t !== "subscribe_ack") {
            throw new Error(`expected subscribe_ack, got ${msg.t}`);
          }
          lastSubscribeAck = msg;
          if (streamState) {
            const st = document.getElementById("state");
            if (st) st.textContent = "Subscribed — waiting for ecs snapshots…\n";
            phase = "streaming";
            log("(live) subscribed — streaming `state.ecs`");
            return;
          }
          const ent = lastAssigned.entity_id != null ? String(lastAssigned.entity_id) : "paddle_left";
          const act = JSON.stringify({
            v: 1,
            t: "actions",
            frame: 1,
            actions: [{ op: "move", entity: ent, dz: 0.25 }]
          });
          log(`-> ${act}`);
          ws.send(act);
          phase = "expect_actions_ack";
        } else if (phase === "streaming") {
          if (msg.t === "state") {
            const ecs = msg.ecs != null ? msg.ecs : {};
            const st = document.getElementById("state");
            if (st) st.textContent = JSON.stringify(ecs, null, 2);
            return;
          }
          if (msg.t === "error") {
            finish(reject, errFromServer(msg));
            return;
          }
          log(`(streaming, ignored: ${msg.t})`);
        } else if (phase === "expect_actions_ack") {
          if (msg.t === "state") {
            log("(periodic state push)");
            return;
          }
          if (msg.t !== "actions_ack") {
            throw new Error(`expected actions_ack, got ${msg.t}`);
          }
          phase = "done";
          ws.close();
          finish(resolve, {
            assigned: lastAssigned,
            subscribeAck: lastSubscribeAck,
            actionsAck: msg,
            fromResume
          });
        }
      } catch (e) {
        finish(reject, e);
      }
    };
  });
}

function errFromServer(msg) {
  const code = msg.code || "?";
  const m = msg.message || "";
  return new Error(`server error ${code}: ${m}`);
}

async function runFromQuery() {
  const q = parseQuery();
  let jwt = q.jwt;
  const baseUrl = window.location.origin;

  if (!q.token) {
    log("Missing token (player_ws_token). Use query ?token=… or the dev form.");
    return;
  }

  if (!jwt && q.mintKey && q.userId) {
    jwt = await mintJwt(baseUrl, q.mintKey, q.userId, q.playerId);
    log(`(minted JWT, length ${jwt.length})`);
  }

  if (!jwt) {
    log("Missing jwt. Add ?jwt=… or ?mint_key=…&user_id=… or use the dev form.");
    return;
  }

  const hints = q.hintsRaw ? parseHints(q.hintsRaw) : null;
  const wsUrl = buildWsUrl(baseUrl, q.token);
  const streamState = q.live === true;
  const followup = streamState ? true : !q.skip_followup;

  const result = await runBootstrap({
    wsUrl,
    jwt,
    hints,
    authOnly: q.authOnly,
    followup,
    resume: q.resume,
    streamState
  });

  if (result.assigned && result.actionsAck) {
    const label = result.fromResume ? "parity (resume)" : "parity";
    log(
      `OK ${label}: assigned + subscribe_ack + actions_ack (${JSON.stringify(result.actionsAck)})`
    );
  } else if (result.assigned) {
    log(`OK assigned: ${JSON.stringify(result.assigned)}`);
  } else if (result.authenticated) {
    log(`OK authenticated (auth_only): ${JSON.stringify(result.authenticated)}`);
  }
}

function wireMintForm() {
  const form = document.getElementById("mint-form");
  if (!form) return;

  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const fd = new FormData(form);
    const mintKey = String(fd.get("mint_key") || "").trim();
    const userId = String(fd.get("user_id") || "").trim();
    const token = String(fd.get("token") || "").trim();
    const baseUrl = window.location.origin;

    document.getElementById("log").textContent = "";

    if (!token || !mintKey || !userId) {
      log("Fill token, mint key, and user_id.");
      return;
    }

    try {
      const jwt = await mintJwt(baseUrl, mintKey, userId, userId);
      log(`(minted JWT)`);
      const wsUrl = buildWsUrl(baseUrl, token);
      const result = await runBootstrap({
        wsUrl,
        jwt,
        hints: null,
        authOnly: false,
        followup: true
      });
      if (result.assigned && result.actionsAck) {
        log(
          `OK parity: assigned + subscribe_ack + actions_ack (${JSON.stringify(result.actionsAck)})`
        );
      } else if (result.assigned) {
        log(`OK assigned: ${JSON.stringify(result.assigned)}`);
      }
    } catch (e) {
      log(`Error: ${e.message || e}`);
    }
  });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}

function init() {
  wireMintForm();
  const q = parseQuery();
  if (q.token && (q.jwt || (q.mintKey && q.userId))) {
    runFromQuery().catch((e) => {
      log(`Error: ${e.message || e}`);
    });
  }
}
