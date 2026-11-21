"use strict";
(() => {
  const main = document.getElementById("main"),
    nav = document.getElementById("navigation"),
    link = document.getElementById("link-state");
  const views = [
    ["map", "Map", "◎"],
    ["team", "Team", "♟"],
    ["orders", "Orders", "⚑"],
    ["notes", "Notes", "☷"],
    ["zones", "Zones", "◌"],
    ["video", "Video", "▣"],
    ["dashboard", "Dashboard", "▤"],
  ];
  let inviteDraft = "";
  let snapshot = { squads: [], nearby: [] },
    access = { canManage: false },
    events,
    mapView,
    lastSquad,
    streamConnected = false;
  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  };
  const time = (value) =>
    value
      ? new Date(value).toLocaleTimeString([], {
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
        })
      : "Unknown";
  const age = (value) => {
    if (!value) return "No position";
    const s = Math.max(0, Math.floor((Date.now() - value) / 1000));
    return s < 60
      ? "Now"
      : s < 3600
        ? Math.floor(s / 60) + " min ago"
        : Math.floor(s / 3600) + " h ago";
  };
  const route = () => {
    const parts = location.pathname.split("/").filter(Boolean);
    return {
      id: parts[1],
      view: parts[2] === "wall" ? "dashboard" : parts[2] || "dashboard",
    };
  };
  const path = (id, view) => "/squads/" + encodeURIComponent(id) + "/" + view;
  const names = (s, id) =>
    s.members.find((m) => m.id === id)?.name || "Former member";
  const empty = (title, text) => {
    const box = el("div", "empty");
    box.append(el("h2", "", title), el("p", "", text));
    return box;
  };
  const badge = (text, cls = "") => el("span", "badge " + cls, text);
  const formatCoords = (p) =>
    p ? p.latitude.toFixed(5) + ", " + p.longitude.toFixed(5) : "—";
  const notify = (text) => {
    const n = document.getElementById("toast");
    n.textContent = text;
    setTimeout(() => {
      if (n.textContent === text) n.textContent = "";
    }, 4500);
  };
  async function api(url, body) {
    const response = await fetch(
      url,
      body === undefined
        ? {}
        : {
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "X-Theater-Request": "1",
            },
            body: JSON.stringify(body),
          },
    );
    const data = await response.json();
    if (!response.ok)
      throw new Error(data.error || "Could not complete the request.");
    return data;
  }
  function login() {
    nav.replaceChildren();
    main.replaceChildren();
    const box = el("section", "login");
    box.append(
      el("div", "kicker", "SQUADZ THEATER"),
      el("h1", "", "Watch from this screen"),
      el(
        "p",
        "subtitle",
        "Enter the view passcode shown on the Mac running Theater.",
      ),
    );
    const form = el("form"),
      label = el("label", "", "View passcode"),
      input = el("input");
    input.type = "password";
    input.autocomplete = "current-password";
    input.required = true;
    label.append(input);
    const button = el("button", "primary", "Open Theater");
    button.type = "submit";
    const error = el("p", "error-text");
    error.setAttribute("role", "alert");
    form.append(label, button, error);
    form.onsubmit = async (e) => {
      e.preventDefault();
      button.disabled = true;
      try {
        await api("/api/login", { passcode: input.value });
        input.value = "";
        await start();
      } catch (e) {
        error.textContent = e.message;
        button.disabled = false;
      }
    };
    box.append(form);
    main.append(box);
    link.textContent = "Passcode required";
  }
  async function start() {
    try {
      access = await api("/api/access");
      snapshot = await api("/api/state");
      render();
      events?.close();
      events = new EventSource("/events");
      events.addEventListener("state", (e) => {
        snapshot = JSON.parse(e.data);
        streamConnected = true;
        link.textContent = "Live · observer only";
        render();
      });
      events.onopen = () => {
        streamConnected = true;
        link.textContent = "Live · observer only";
      };
      events.onerror = () => {
        streamConnected = false;
        link.textContent = "Host link lost · reconnecting";
      };
    } catch (e) {
      if (e.message.includes("passcode")) login();
      else {
        main.replaceChildren(empty("Cannot reach Theater", e.message));
        link.textContent = "Disconnected";
      }
    }
  }
  function header(s, title) {
    const box = el("div", "view-header"),
      left = el("div");
    left.append(
      el("div", "kicker", s.name.toUpperCase()),
      el("h1", "", title),
      el(
        "p",
        "subtitle",
        s.members.length +
          " members · " +
          s.observers.filter((o) => o.connected).length +
          " observers · read only",
      ),
    );
    box.append(
      left,
      badge(
        s.connection === "connected" ? "Squad linked" : s.connection,
        s.connection === "connected" ? "" : "warning",
      ),
    );
    return box;
  }
  function navigation(s, view) {
    nav.replaceChildren(el("div", "nav-caption", "SQUAD VIEWS"));
    for (const [key, label, mark] of views) {
      const a = el("a", "nav-link");
      a.href = path(s.id, key);
      a.append(el("span", "mark", mark), el("span", "", label));
      if (view === key) a.setAttribute("aria-current", "page");
      nav.append(a);
    }
    const home = el("div", "nav-home"),
      a = el("a", "nav-link", "All squads");
    a.href = "/";
    home.append(a);
    nav.append(home);
  }
  function landing() {
    const focused = document.activeElement?.id === "join-invite",
      cursor = focused ? document.activeElement.selectionStart : null;
    nav.replaceChildren();
    const box = el("div", "landing");
    box.append(
      el("div", "kicker", "LOCAL OBSERVATION DESK"),
      el("h1", "", "Your squads, across your screens"),
      el(
        "p",
        "intro",
        "Open a squad view in any browser window. Move it to another monitor; its address keeps the same squad and view after a reload.",
      ),
    );
    if (snapshot.problem) box.append(el("p", "notice", snapshot.problem));
    const grid = el("div", "squad-grid");
    for (const s of snapshot.squads) {
      const card = el("article", "squad-card");
      card.append(
        badge(
          s.connection === "connected" ? "Linked" : s.connection,
          s.connection === "connected" ? "" : "warning",
        ),
      );
      const a = el("a", "open-squad", s.name);
      a.href = path(s.id, "dashboard");
      card.append(
        a,
        el(
          "p",
          "small muted",
          s.members.length +
            " members · " +
            s.orders.filter((o) => !o.cancelled).length +
            " orders",
        ),
      );
      const links = el("div", "quick-views");
      for (const v of ["map", "orders", "dashboard"]) {
        const a = el("a", "", v[0].toUpperCase() + v.slice(1));
        a.href = path(s.id, v);
        links.append(a);
      }
      card.append(links);
      if (access.canManage) {
        const forget = el(
          "button",
          "text-button",
          "Stop watching on this host",
        );
        forget.onclick = async () => {
          if (!confirm("Stop watching " + s.name + " from this host?")) return;
          try {
            await api("/api/forget", { squad: s.id });
          } catch (e) {
            notify(e.message);
          }
        };
        card.append(forget);
      }
      if (s.problem) card.append(el("p", "small muted", s.problem));
      grid.append(card);
    }
    if (!snapshot.squads.length)
      grid.append(
        empty(
          "No squads connected",
          "An invite from a squad leader lets this host join as a visible, read-only observer.",
        ),
      );
    box.append(grid);
    const pairing = el("section", "pairing");
    pairing.append(
      el(
        "h2",
        "",
        snapshot.demoMap ? "Sample squads only" : "Watch another squad",
      ),
    );
    if (access.canManage) {
      pairing.append(
        el(
          "p",
          "small muted",
          "Paste the invite link from the leader. Joining adds this host to the leader’s observer list.",
        ),
      );
      const form = el("form"),
        label = el("label", "", "Squad invite link"),
        input = el("input");
      input.type = "password";
      input.id = "join-invite";
      input.value = inviteDraft;
      input.oninput = () => {
        inviteDraft = input.value;
      };
      input.autocomplete = "off";
      input.spellcheck = false;
      input.required = true;
      input.placeholder = "squadz://join?…";
      label.append(input);
      const submit = el("button", "primary", "Join as observer");
      submit.type = "submit";
      const error = el("p", "error-text");
      error.setAttribute("role", "alert");
      form.append(label, submit, error);
      form.onsubmit = async (e) => {
        e.preventDefault();
        submit.disabled = true;
        try {
          await api("/api/join", { invite: input.value });
          inviteDraft = "";
          input.value = "";
          notify("Joining as an observer…");
        } catch (e) {
          error.textContent = e.message;
        } finally {
          submit.disabled = false;
        }
      };
      pairing.append(form);
    } else
      pairing.append(
        el(
          "p",
          "small muted",
          snapshot.demoMap
            ? "Online maps are enabled for these sample squads. Run without --demo-map to join a real squad."
            : "Pair squads on the Mac running the host. This screen can only watch.",
        ),
      );
    if (snapshot.nearby.length) {
      pairing.append(el("p", "subtitle", "Nearby on this network"));
      const found = el("div", "discovered");
      for (const s of snapshot.nearby)
        found.append(
          el("span", "", s.name + (s.compatible ? "" : " · different version")),
        );
      pairing.append(found);
    }
    box.append(pairing);
    main.replaceChildren(box);
    if (focused) {
      inputFocus();
    }
    function inputFocus() {
      const target = document.getElementById("join-invite");
      if (target) {
        target.focus();
        if (cursor !== null) target.setSelectionRange(cursor, cursor);
      }
    }
  }
  function orderCard(s, entry) {
    const o = entry.order,
      card = el("article", "item"),
      head = el("div", "item-head"),
      title = el("div");
    title.append(
      el(
        "h2",
        "",
        o.kind === "moveTo"
          ? "Move to"
          : o.kind === "holdPosition"
            ? "Hold position"
            : o.kind === "note"
              ? "Note"
              : o.kind === "squadz.video.stream"
                ? "Stream video"
                : o.kind,
      ),
      el(
        "p",
        "small muted",
        o.to ? o.to.map((id) => names(s, id)).join(", ") : "Whole squad",
      ),
    );
    head.append(title, el("time", "", time(o.time)));
    card.append(head);
    if (o.text) card.append(el("p", "", o.text));
    if (o.at) card.append(el("p", "small muted", formatCoords(o.at)));
    if (entry.cancelled) card.append(badge("Cancelled"));
    else {
      const answers = el("div", "answers");
      for (const m of s.members.filter(
        (m, i) => i > 0 && (!o.to || o.to.includes(m.id)),
      )) {
        const a = entry.answers.find((a) => a.member === m.id);
        answers.append(
          el(
            "span",
            "answer " +
              (!a ? "waiting" : a.response === "cannot" ? "cannot" : ""),
            m.name +
              ": " +
              (!a
                ? "No answer"
                : a.response === "seen"
                  ? "Seen"
                  : a.response === "done"
                    ? "Done"
                    : "Can’t"),
          ),
        );
      }
      card.append(answers);
    }
    return card;
  }
  function orders(s) {
    const list = el("div", "list");
    if (!s.orders.length)
      list.append(
        empty(
          "No orders yet",
          "Orders and each member’s answers appear here. Theater cannot send or change them.",
        ),
      );
    for (const o of s.orders) list.append(orderCard(s, o));
    return list;
  }
  function notes(s, compact = false) {
    const list = el("div", "list");
    if (!s.notes.length)
      list.append(
        empty(
          "Nothing said yet",
          "Squad notes appear here as they arrive. This is a read-only chat view.",
        ),
      );
    for (const note of compact ? s.notes.slice(-8) : s.notes) {
      const card = el("article", "item"),
        head = el("div", "item-head");
      head.append(el("h2", "", note.author), el("time", "", time(note.time)));
      card.append(head, el("p", "", note.text));
      if (note.at) card.append(el("p", "small muted", formatCoords(note.at)));
      list.append(card);
    }
    return list;
  }
  function team(s) {
    const wrap = el("div", "table-wrap"),
      table = el("table"),
      head = el("tr");
    for (const label of [
      "Member",
      "Connection",
      "Position age",
      "Accuracy",
      "Coordinates",
    ])
      head.append(el("th", "", label));
    const thead = el("thead");
    thead.append(head);
    table.append(thead);
    const body = el("tbody");
    s.members.forEach((m, i) => {
      const tr = el("tr"),
        p = m.position;
      for (const [value, cls] of [
        [m.name + (i === 0 ? " · leader" : ""), ""],
        [
          m.connected === undefined
            ? "Unknown"
            : m.connected
              ? "Connected"
              : "Disconnected",
          "",
        ],
        [age(p?.time), "age-cell"],
        [p ? "±" + Math.round(p.accuracy) + " m" : "—", ""],
        [formatCoords(p?.at), "coords"],
      ])
        tr.append(el("td", cls, value));
      body.append(tr);
    });
    table.append(body);
    wrap.append(table);
    if (s.observers.length) {
      wrap.append(el("h2", "section-heading", "Observers"));
      const list = el("div", "list");
      for (const o of s.observers) {
        const row = el("div", "item item-head");
        row.append(
          el("span", "", o.name),
          badge(
            o.connected ? "Watching" : "Disconnected",
            o.connected ? "" : "warning",
          ),
        );
        list.append(row);
      }
      wrap.append(list);
    }
    return wrap;
  }
  function zones(s) {
    const box = el("div"),
      list = el("div", "list");
    if (!s.zones.length)
      list.append(
        empty(
          "No zones defined",
          "The commander can add labeled circles and polygons. Theater shows them and confirmed crossings without editing them.",
        ),
      );
    for (const z of s.zones) {
      const card = el("article", "item"),
        head = el("div", "item-head");
      head.append(
        el("h2", "", z.name),
        badge(
          z.rule === "goal" ? "Goal arrival" : "Allowed area",
          z.rule === "goal" ? "" : "warning",
        ),
      );
      card.append(
        head,
        el(
          "p",
          "small muted",
          z.shape === "circle"
            ? Math.round(z.radius) + " m radius"
            : z.vertices.length + " polygon corners",
        ),
        el(
          "p",
          "small muted",
          z.members
            ? z.members.map((id) => names(s, id)).join(", ")
            : "Whole squad",
        ),
      );
      list.append(card);
    }
    box.append(list, el("h2", "section-heading", "Zone crossings"));
    if (!s.crossings.length)
      box.append(el("p", "muted", "No confirmed crossings yet."));
    for (const x of [...s.crossings].reverse()) {
      const row = el("div", "item item-head");
      row.append(
        el(
          "span",
          "",
          x.memberName +
            (x.kind === "arrived" ? " reached " : " left ") +
            x.zoneName,
        ),
        el("time", "", time(x.time)),
      );
      box.append(row);
    }
    return box;
  }
  function video(s) {
    const box = el("div", "video-placeholder");
    box.append(
      el("div", "symbol", "▣"),
      el("h2", "", "Video is leader-only"),
      el(
        "p",
        "",
        "Observer video sharing has not been enabled. No camera frames are requested or forwarded to this host.",
      ),
    );
    if (s.streams.length)
      for (const stream of s.streams)
        box.append(
          el(
            "p",
            "",
            names(s, stream.member) +
              " is streaming to the leader" +
              (stream.recording ? " · recording" : ""),
          ),
        );
    return box;
  }
  function render() {
    const r = route();
    if (!r.id) {
      mapView?.destroy();
      mapView = null;
      landing();
      return;
    }
    const s = snapshot.squads.find((s) => s.id === r.id);
    if (!s) {
      nav.replaceChildren();
      main.replaceChildren(
        empty(
          "Waiting for this squad",
          "Open All squads to pair or select a connected squad.",
        ),
      );
      const a = el("a", "", "All squads");
      a.href = "/";
      main.append(a);
      return;
    }
    navigation(s, r.view);
    document.title =
      s.name + " · " + (views.find((v) => v[0] === r.view)?.[1] || "Theater");
    if (
      mapView &&
      lastSquad === s.id &&
      ["map", "dashboard"].includes(r.view)
    ) {
      mapView.update(s, snapshot);
      const old = document.getElementById("squad-problem");
      if (s.problem) {
        if (old) old.textContent = s.problem;
        else {
          const warning = el("div", "notice", s.problem);
          warning.id = "squad-problem";
          main.prepend(warning);
        }
      } else old?.remove();
      const status = main.querySelector(".view-header .badge");
      if (status) {
        status.textContent =
          s.connection === "connected" ? "Squad linked" : s.connection;
        status.className =
          "badge " + (s.connection === "connected" ? "" : "warning");
      }
      if (r.view === "dashboard") fillWall(s);
      return;
    }
    mapView?.destroy();
    mapView = null;
    lastSquad = s.id;
    main.replaceChildren(
      header(s, views.find((v) => v[0] === r.view)?.[1] || "Theater"),
    );
    if (s.problem) {
      const warning = el("div", "notice", s.problem);
      warning.id = "squad-problem";
      main.append(warning);
    }
    if (r.view === "map" || r.view === "dashboard") {
      const grid = el("div", r.view === "dashboard" ? "wall-grid" : ""),
        holder = el("div", "map-panel");
      grid.append(holder);
      if (r.view === "dashboard") {
        const strip = el("aside", "wall-strip");
        strip.id = "wall-strip";
        strip.setAttribute("aria-label", "Orders and notes");
        grid.append(strip);
      }
      main.append(grid);
      mapView = new SquadMap(holder, s, snapshot);
      if (r.view === "dashboard") fillWall(s);
    } else
      main.append(
        r.view === "team"
          ? team(s)
          : r.view === "orders"
            ? orders(s)
            : r.view === "notes"
              ? notes(s)
              : r.view === "zones"
                ? zones(s)
                : video(s),
      );
  }
  function fillWall(s) {
    const strip = document.getElementById("wall-strip");
    if (!strip) return;
    strip.replaceChildren(el("h2", "section-heading", "Orders"));
    for (const order of s.orders.filter((o) => !o.cancelled).slice(0, 4))
      strip.append(orderCard(s, order));
    if (!s.orders.length)
      strip.append(el("p", "small muted", "No orders yet."));
    strip.append(el("h2", "section-heading", "Latest notes"), notes(s, true));
  }

  class SquadMap {
    constructor(holder, squad, config) {
      this.holder = holder;
      this.squad = squad;
      this.config = config;
      this.center = null;
      this.zoom = 16;
      this.images = new Map();
      this.canvas = el("canvas");
      this.canvas.tabIndex = 0;
      this.canvas.setAttribute("role", "img");
      this.canvas.setAttribute(
        "aria-label",
        "Squad members, order flags and zone boundaries. Arrow keys pan; plus and minus zoom.",
      );
      holder.append(this.canvas);
      this.ctx = this.canvas.getContext("2d");
      this.legend = el("div", "map-legend");
      holder.append(this.legend);
      const tools = el("div", "map-tools");
      for (const [label, action] of [
        ["+", () => this.changeZoom(1)],
        ["−", () => this.changeZoom(-1)],
        ["Fit squad", () => this.fit()],
      ]) {
        const b = el("button", "", label);
        b.setAttribute(
          "aria-label",
          label === "+" ? "Zoom in" : label === "−" ? "Zoom out" : label,
        );
        b.onclick = action;
        tools.append(b);
      }
      holder.append(tools);
      this.caption = el("div", "map-caption");
      holder.append(this.caption);
      this.canvas.onpointerdown = (e) => {
        this.drag = { x: e.clientX, y: e.clientY, center: { ...this.center } };
        this.canvas.setPointerCapture(e.pointerId);
      };
      this.canvas.onpointermove = (e) => {
        if (!this.drag) return;
        this.center = {
          x: this.drag.center.x - (e.clientX - this.drag.x),
          y: this.drag.center.y - (e.clientY - this.drag.y),
        };
        this.draw();
      };
      this.canvas.onpointerup = () => {
        this.drag = null;
      };
      this.canvas.onpointercancel = () => {
        this.drag = null;
      };
      this.canvas.onwheel = (e) => {
        e.preventDefault();
        this.changeZoom(e.deltaY < 0 ? 1 : -1);
      };
      this.canvas.onkeydown = (e) => {
        if (
          [
            "ArrowUp",
            "ArrowDown",
            "ArrowLeft",
            "ArrowRight",
            "+",
            "-",
            "=",
          ].includes(e.key)
        ) {
          e.preventDefault();
          if (e.key === "+" || e.key === "=") this.changeZoom(1);
          else if (e.key === "-") this.changeZoom(-1);
          else {
            this.center.x +=
              e.key === "ArrowLeft" ? -80 : e.key === "ArrowRight" ? 80 : 0;
            this.center.y +=
              e.key === "ArrowUp" ? -80 : e.key === "ArrowDown" ? 80 : 0;
            this.draw();
          }
        }
      };
      this.observer = new ResizeObserver(() => {
        this.resize();
        if (!this.fitted) this.fit();
        else this.draw();
      });
      this.observer.observe(holder);
      this.resize();
      this.fit();
    }
    project(p, z = this.zoom) {
      const lat =
          (Math.max(-85.0511, Math.min(85.0511, p.latitude)) * Math.PI) / 180,
        size = 256 * 2 ** z;
      return {
        x: ((p.longitude + 180) / 360) * size,
        y:
          ((1 - Math.log(Math.tan(lat) + 1 / Math.cos(lat)) / Math.PI) / 2) *
          size,
      };
    }
    unproject(p, z = this.zoom) {
      const size = 256 * 2 ** z,
        n = Math.PI - (2 * Math.PI * p.y) / size;
      return {
        longitude: (p.x / size) * 360 - 180,
        latitude: (180 / Math.PI) * Math.atan(Math.sinh(n)),
      };
    }
    screen(p) {
      const q = this.project(p);
      return {
        x: q.x - this.center.x + this.width / 2,
        y: q.y - this.center.y + this.height / 2,
      };
    }
    resize() {
      this.width = this.holder.clientWidth;
      this.height = this.holder.clientHeight;
      const dpr = Math.min(2, devicePixelRatio || 1);
      this.canvas.width = this.width * dpr;
      this.canvas.height = this.height * dpr;
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    points() {
      const points = this.squad.members
        .filter((m) => m.position)
        .map((m) => m.position.at);
      for (const o of this.squad.orders)
        if (!o.cancelled && o.order.at) points.push(o.order.at);
      for (const z of this.squad.zones) {
        if (z.shape === "polygon") points.push(...z.vertices);
        else {
          const latDelta = z.radius / 111195,
            lonDelta =
              latDelta /
              Math.max(0.01, Math.cos((z.center.latitude * Math.PI) / 180));
          points.push(
            {
              latitude: z.center.latitude - latDelta,
              longitude: z.center.longitude - lonDelta,
            },
            {
              latitude: z.center.latitude + latDelta,
              longitude: z.center.longitude + lonDelta,
            },
          );
        }
      }
      return points;
    }
    fit() {
      const points = this.points();
      if (!points.length) {
        this.center = this.project({ latitude: 0, longitude: 0 });
        this.zoom = Math.min(
          2,
          this.config.tiles ? this.config.tileMaxZoom : 20,
        );
        this.fitted = false;
        this.draw();
        return;
      }
      let z = Math.min(18, this.config.tileMaxZoom ?? 18);
      let projected;
      for (; z > 0; z--) {
        projected = points.map((p) => this.project(p, z));
        if (
          Math.max(...projected.map((p) => p.x)) -
            Math.min(...projected.map((p) => p.x)) <
            this.width - 120 &&
          Math.max(...projected.map((p) => p.y)) -
            Math.min(...projected.map((p) => p.y)) <
            this.height - 140
        )
          break;
      }
      this.zoom = z;
      projected = points.map((p) => this.project(p, z));
      this.center = {
        x:
          (Math.max(...projected.map((p) => p.x)) +
            Math.min(...projected.map((p) => p.x))) /
          2,
        y:
          (Math.max(...projected.map((p) => p.y)) +
            Math.min(...projected.map((p) => p.y))) /
          2,
      };
      this.fitted = true;
      this.draw();
    }
    changeZoom(by) {
      const z = Math.max(
          0,
          Math.min(
            this.config.tiles ? this.config.tileMaxZoom : 20,
            this.zoom + by,
          ),
        ),
        scale = 2 ** (z - this.zoom);
      this.center = { x: this.center.x * scale, y: this.center.y * scale };
      this.zoom = z;
      this.draw();
    }
    update(s, config) {
      this.squad = s;
      this.config = config;
      if (!this.fitted && this.points().length) this.fit();
      else this.draw();
    }
    label(text, x, y, color = "#21382d") {
      const ctx = this.ctx;
      ctx.font = "600 14px system-ui";
      const width = ctx.measureText(text).width;
      ctx.fillStyle = "#fffdf4";
      ctx.fillRect(x - width / 2 - 6, y - 15, width + 12, 21);
      ctx.fillStyle = color;
      ctx.textAlign = "center";
      ctx.fillText(text, x, y);
    }
    draw() {
      if (!this.center || !this.width) return;
      const ctx = this.ctx,
        w = this.width,
        h = this.height;
      ctx.clearRect(0, 0, w, h);
      ctx.fillStyle = "#edf0e7";
      ctx.fillRect(0, 0, w, h);
      let available = 0,
        missing = 0;
      if (this.config.tiles) {
        const left = this.center.x - w / 2,
          top = this.center.y - h / 2,
          n = 2 ** this.zoom;
        for (
          let x = Math.floor(left / 256);
          x <= Math.floor((left + w) / 256);
          x++
        )
          for (
            let y = Math.floor(top / 256);
            y <= Math.floor((top + h) / 256);
            y++
          ) {
            if (x < 0 || y < 0 || x >= n || y >= n) continue;
            const key = this.zoom + "/" + x + "/" + y;
            let image = this.images.get(key);
            if (!image) {
              image = new Image();
              image.onload = () => {
                image.ok = true;
                if (!this.destroyed) this.draw();
              };
              image.onerror = () => {
                image.bad = true;
                if (!this.destroyed) this.draw();
              };
              // Only generated sample squads can enable online demo tiles. Image requests
              // use the browser cache and send only the origin as Referer, never squad URLs.
              image.referrerPolicy = "origin";
              image.src = this.config.demoMap
                ? "https://tile.openstreetmap.org/" + key + ".png"
                : "/tiles/" + key + ".png";
              this.images.set(key, image);
              if (this.images.size > 256) {
                const oldest = this.images.keys().next().value;
                this.images.delete(oldest);
              }
            }
            if (image.ok) {
              ctx.drawImage(image, x * 256 - left, y * 256 - top, 256, 256);
              available++;
            } else missing++;
          }
      }
      if (!available) {
        ctx.strokeStyle = "#d8dfd3";
        ctx.lineWidth = 1;
        for (let x = (-this.center.x + w / 2) % 80; x < w; x += 80) {
          ctx.beginPath();
          ctx.moveTo(x, 0);
          ctx.lineTo(x, h);
          ctx.stroke();
        }
        for (let y = (-this.center.y + h / 2) % 80; y < h; y += 80) {
          ctx.beginPath();
          ctx.moveTo(0, y);
          ctx.lineTo(w, y);
          ctx.stroke();
        }
      }
      this.legend.textContent = !this.config.tiles
        ? "No tiles configured · coordinate grid"
        : this.config.demoMap
          ? missing
            ? "OpenStreetMap · loading or unavailable tiles"
            : "OpenStreetMap · online demo"
          : missing
            ? "Local tiles · some tiles unavailable"
            : "Local offline map";
      for (const zone of this.squad.zones) {
        ctx.beginPath();
        if (zone.shape === "circle") {
          const p = this.screen(zone.center),
            pixels =
              zone.radius /
              ((156543.03392 *
                Math.cos((zone.center.latitude * Math.PI) / 180)) /
                2 ** this.zoom);
          ctx.arc(p.x, p.y, pixels, 0, Math.PI * 2);
        } else {
          zone.vertices.forEach((point, i) => {
            const p = this.screen(point);
            if (i === 0) ctx.moveTo(p.x, p.y);
            else ctx.lineTo(p.x, p.y);
          });
          ctx.closePath();
        }
        ctx.fillStyle = zone.rule === "goal" ? "#42804c22" : "#dc9a2925";
        ctx.strokeStyle = zone.rule === "goal" ? "#3b7546" : "#ad7527";
        ctx.lineWidth = 2;
        ctx.setLineDash(zone.rule === "goal" ? [] : [7, 5]);
        ctx.fill();
        ctx.stroke();
        ctx.setLineDash([]);
        const anchor = zone.shape === "circle" ? zone.center : zone.vertices[0];
        const p = this.screen(anchor);
        this.label(zone.name, p.x, p.y - 22);
      }
      for (const item of this.squad.orders) {
        const o = item.order;
        if (item.cancelled || !o.at) continue;
        const p = this.screen(o.at);
        ctx.strokeStyle = "#865421";
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(p.x, p.y + 5);
        ctx.lineTo(p.x, p.y - 21);
        ctx.stroke();
        ctx.fillStyle = "#d9962b";
        ctx.fillRect(p.x, p.y - 21, 16, 10);
        this.label(o.text || "Order", p.x, p.y + 28, "#80551c");
      }
      this.squad.members.forEach((m, i) => {
        if (!m.position) return;
        const p = this.screen(m.position.at);
        ctx.save();
        ctx.globalAlpha =
          this.squad.connection !== "connected" ||
          Date.now() - m.position.time > 120000
            ? 0.45
            : 1;
        ctx.fillStyle = i === 0 ? "#2677b6" : "#29583d";
        ctx.strokeStyle = "#fffdf4";
        ctx.lineWidth = 3;
        ctx.beginPath();
        ctx.arc(p.x, p.y, 13, 0, Math.PI * 2);
        ctx.fill();
        ctx.stroke();
        if (Number.isFinite(m.position.heading)) {
          ctx.save();
          ctx.translate(p.x, p.y);
          ctx.rotate((m.position.heading * Math.PI) / 180);
          ctx.beginPath();
          ctx.moveTo(0, -8);
          ctx.lineTo(5, 5);
          ctx.lineTo(0, 2);
          ctx.lineTo(-5, 5);
          ctx.closePath();
          ctx.fillStyle = "#fffdf4";
          ctx.fill();
          ctx.restore();
        }
        this.label(m.name, p.x, p.y + 32);
        ctx.restore();
      });
      const center = this.unproject(this.center);
      const credit = el(
        this.config.demoMap ? "a" : "span",
        "",
        this.config.tiles
          ? this.config.tileAttribution
          : "Coordinate grid · no internet map requests",
      );
      if (this.config.demoMap) {
        credit.href = "https://www.openstreetmap.org/copyright";
        credit.target = "_blank";
        credit.rel = "noopener";
      }
      this.caption.replaceChildren(
        credit,
        el("span", "", formatCoords(center) + " · zoom " + this.zoom),
      );
      ctx.fillStyle = "#314e3b";
      ctx.font = "600 14px system-ui";
      ctx.textAlign = "left";
      ctx.fillText("N", 18, 78);
    }
    destroy() {
      this.destroyed = true;
      this.observer.disconnect();
      for (const image of this.images.values()) {
        image.onload = null;
        image.onerror = null;
      }
      this.images.clear();
    }
  }
  setInterval(() => {
    if (mapView) mapView.draw();
    else if (route().view === "team" && snapshot.squads.length) render();
  }, 15000);
  start();
})();
