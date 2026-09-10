#!/usr/bin/env ruby
# frozen_string_literal: true

require "webrick"
require "json"
require "pathname"

require_relative "data_collector"

module SkillsDashboard
  # Read-only local dashboard. Binds to loopback only, sends no CORS headers
  # (so another browser tab/origin cannot read the JSON responses), and never
  # accepts any request body or mutating verb -- there is nothing here that
  # writes to the project or reads credentials.
  #
  # This is meant to be started on request and left to clean itself up, not run
  # as a standing background service: past idle_timeout seconds with no request
  # (the open-page heartbeat in INDEX_HTML counts as a request), it shuts itself
  # down and deletes its own pid/port state file, the same cleanup the adapter's
  # `stop` command would do -- so a user who opens the page and walks away does
  # not need to remember to close it, and an idle host stays free of a listening
  # port. Pass idle_timeout: 0 to disable (kept running until externally stopped).
  class Server
    DEFAULT_IDLE_TIMEOUT = 600
    MAX_IDLE_CHECK_INTERVAL = 15

    def initialize(project_root:, port:, bind: "127.0.0.1", idle_timeout: DEFAULT_IDLE_TIMEOUT, state_path: nil)
      @project_root = Pathname.new(project_root).expand_path
      @port = port
      @bind = bind
      @idle_timeout = idle_timeout.to_i
      @state_path = state_path
      @last_activity_at = Time.now
    end

    def run
      server = WEBrick::HTTPServer.new(
        Port: @port,
        BindAddress: @bind,
        Logger: WEBrick::Log.new($stdout, WEBrick::Log::WARN),
        AccessLog: []
      )

      server.mount_proc("/") { |req, res| touch!; serve_index(req, res) }
      server.mount_proc("/api/graph") { |req, res| touch!; serve_graph(req, res) }
      server.mount_proc("/api/health") { |req, res| touch!; serve_health(req, res) }

      idle_monitor = start_idle_monitor(server)
      trap("INT") { server.shutdown }
      trap("TERM") { server.shutdown }
      server.start
    ensure
      idle_monitor&.kill
    end

    private

    def touch!
      @last_activity_at = Time.now
    end

    def start_idle_monitor(server)
      return nil unless @idle_timeout.positive?

      check_interval = [MAX_IDLE_CHECK_INTERVAL, @idle_timeout / 5.0].min.clamp(1, MAX_IDLE_CHECK_INTERVAL)
      Thread.new do
        loop do
          sleep check_interval
          next if Time.now - @last_activity_at < @idle_timeout

          cleanup_state!
          server.shutdown
          break
        end
      end
    end

    def cleanup_state!
      return unless @state_path

      File.delete(@state_path) if File.exist?(@state_path)
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def serve_index(_req, res)
      res["Content-Type"] = "text/html; charset=utf-8"
      res.body = INDEX_HTML
    end

    def serve_graph(_req, res)
      data = DataCollector.new(@project_root).build
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate(data)
    rescue StandardError => e
      res.status = 500
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate({ "error" => e.message })
    end

    def serve_health(_req, res)
      res["Content-Type"] = "application/json; charset=utf-8"
      res.body = JSON.generate({ "status" => "ok", "project_root" => @project_root.to_s, "pid" => Process.pid })
    end

    INDEX_HTML = <<~'HTML'
      <!doctype html>
      <html lang="zh-CN">
      <head>
      <meta charset="utf-8">
      <title>两头乌 · Skills 拓扑</title>
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        :root {
          --bg: #12141a; --panel: #1a1d26; --panel-2: #20242f; --border: #2b303d;
          --text: #e6e8ef; --text-dim: #9aa1b2; --accent: #6ea8fe;
          --skill: #6ea8fe; --skill_set: #b892f0; --capability: #f0a860; --runtime: #6fd18a; --external: #6b7180;
          --edge-evidence: #4a5265; --edge-depends: #f0a860; --edge-available: #4f8f63; --edge-inferred: #d9738f;
        }
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font-family: -apple-system, "PingFang SC", "Helvetica Neue", Arial, sans-serif; height: 100%; overflow: hidden; }
        #app { display: flex; flex-direction: column; height: 100vh; }
        header { display: flex; align-items: center; gap: 12px; padding: 10px 16px; background: var(--panel); border-bottom: 1px solid var(--border); flex-wrap: wrap; }
        header h1 { font-size: 15px; font-weight: 600; margin: 0; white-space: nowrap; }
        header .meta { font-size: 11px; color: var(--text-dim); white-space: nowrap; }
        input[type=search] { background: var(--panel-2); border: 1px solid var(--border); color: var(--text); border-radius: 6px; padding: 6px 10px; font-size: 13px; width: 200px; }
        button { background: var(--panel-2); border: 1px solid var(--border); color: var(--text); border-radius: 6px; padding: 6px 12px; font-size: 13px; cursor: pointer; }
        button:hover { border-color: var(--accent); }
        button.active { border-color: var(--accent); color: var(--accent); }
        .spacer { flex: 1; }
        .tabs { display: flex; gap: 6px; }
        main { flex: 1; display: flex; min-height: 0; }
        #graph-pane { flex: 1; position: relative; min-width: 0; }
        #graph-pane svg { width: 100%; height: 100%; display: block; cursor: grab; }
        #graph-pane svg:active { cursor: grabbing; }
        #list-pane { flex: 1; overflow: auto; padding: 12px; display: none; }
        #list-pane table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
        #list-pane th, #list-pane td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--border); vertical-align: top; }
        #list-pane th { position: sticky; top: 0; background: var(--panel); color: var(--text-dim); font-weight: 500; cursor: pointer; }
        #list-pane tr:hover td { background: var(--panel-2); }
        #list-pane .dim { color: var(--text-dim); }
        aside#detail { width: 320px; flex-shrink: 0; background: var(--panel); border-left: 1px solid var(--border); padding: 14px; overflow-y: auto; font-size: 12.5px; }
        aside#detail h2 { font-size: 14px; margin: 0 0 4px; }
        aside#detail .kind-badge { display: inline-block; font-size: 10px; padding: 2px 6px; border-radius: 4px; background: var(--panel-2); color: var(--text-dim); margin-bottom: 10px; }
        aside#detail dl { margin: 0 0 14px; }
        aside#detail dt { color: var(--text-dim); font-size: 11px; margin-top: 6px; }
        aside#detail dd { margin: 1px 0 0; word-break: break-word; }
        aside#detail .rel-group h3 { font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; color: var(--text-dim); margin: 12px 0 4px; }
        aside#detail .rel-item { padding: 5px 0; border-top: 1px solid var(--border); }
        aside#detail .rel-item .evidence { color: var(--text-dim); font-size: 11px; margin-top: 2px; }
        aside#detail .inferred-tag { color: var(--edge-inferred); font-size: 10px; margin-left: 4px; }
        aside#detail .empty { color: var(--text-dim); }
        .filters { display: flex; gap: 10px; flex-wrap: wrap; padding: 8px 16px; background: var(--panel); border-bottom: 1px solid var(--border); font-size: 12px; }
        .filters label { display: flex; align-items: center; gap: 4px; cursor: pointer; color: var(--text-dim); }
        .filters label.on { color: var(--text); }
        .filters .dot { width: 9px; height: 9px; border-radius: 50%; display: inline-block; }
        .legend-line { width: 16px; height: 0; border-top: 2px solid; display: inline-block; }
        .legend-line.dashed { border-top-style: dashed; }
        #loading, #error { position: absolute; top: 50%; left: 50%; transform: translate(-50%,-50%); color: var(--text-dim); font-size: 13px; }
        #error { color: var(--edge-inferred); display: none; }
        .node-label { fill: var(--text); font-size: 10px; pointer-events: none; user-select: none; }
        .node-label.dim { fill: var(--text-dim); }
      </style>
      </head>
      <body>
      <div id="app">
        <header>
          <h1>两头乌 · Skills 拓扑</h1>
          <span class="meta" id="meta"></span>
          <div class="spacer"></div>
          <input type="search" id="search" placeholder="搜索 skill / capability / skill_set...">
          <div class="tabs">
            <button id="tab-graph" class="active">关系图</button>
            <button id="tab-list">列表</button>
          </div>
          <button id="refresh">刷新</button>
        </header>
        <div class="filters" id="filters"></div>
        <main>
          <div id="graph-pane">
            <div id="loading">加载中...</div>
            <div id="error"></div>
            <svg id="svg"></svg>
          </div>
          <div id="list-pane"></div>
          <aside id="detail"><p class="empty">点击图里的节点，或列表里的一行，看详细信息。</p></aside>
        </main>
      </div>
      <script>
      (function () {
        "use strict";

        var KIND_META = {
          skill: { color: "var(--skill)", label: "Skill" },
          skill_set: { color: "var(--skill_set)", label: "Skill Set" },
          capability: { color: "var(--capability)", label: "Capability" },
          runtime: { color: "var(--runtime)", label: "Runtime" },
          external: { color: "var(--external)", label: "外部依赖" }
        };
        var EDGE_META = {
          member_of: { color: "var(--edge-evidence)", dashed: false, label: "属于 skill_set" },
          owns: { color: "var(--edge-evidence)", dashed: false, label: "capability 拥有" },
          depends_on: { color: "var(--edge-depends)", dashed: false, label: "依赖" },
          available_to: { color: "var(--edge-available)", dashed: false, label: "对运行时可见" },
          inferred_uses: { color: "var(--edge-inferred)", dashed: true, label: "推测调用（未验证）" }
        };

        var state = { nodes: [], edges: [], byId: {}, selected: null, activeKinds: {}, activeTypes: {} };
        var svg = document.getElementById("svg");
        var svgNS = "http://www.w3.org/2000/svg";
        var view = { x: 0, y: 0, scale: 1 };
        var dragNode = null, panStart = null;
        var width = 0, height = 0;

        function resize() {
          var pane = document.getElementById("graph-pane");
          width = pane.clientWidth; height = pane.clientHeight;
          svg.setAttribute("viewBox", "0 0 " + width + " " + height);
        }
        window.addEventListener("resize", resize);

        function el(tag, attrs) {
          var node = document.createElementNS(svgNS, tag);
          for (var k in attrs) node.setAttribute(k, attrs[k]);
          return node;
        }

        function load() {
          document.getElementById("loading").style.display = "block";
          document.getElementById("error").style.display = "none";
          fetch("/api/graph").then(function (r) {
            if (!r.ok) throw new Error("HTTP " + r.status);
            return r.json();
          }).then(function (data) {
            if (data.error) throw new Error(data.error);
            document.getElementById("loading").style.display = "none";
            ingest(data);
          }).catch(function (err) {
            document.getElementById("loading").style.display = "none";
            var e = document.getElementById("error");
            e.textContent = "加载失败：" + err.message;
            e.style.display = "block";
          });
        }

        function ingest(data) {
          var byId = {};
          var nodes = data.nodes.map(function (n) {
            var copy = Object.assign({}, n);
            copy.x = width / 2 + (Math.random() - 0.5) * 200;
            copy.y = height / 2 + (Math.random() - 0.5) * 200;
            copy.vx = 0; copy.vy = 0;
            byId[n.id] = copy;
            return copy;
          });
          var missing = {};
          data.edges.forEach(function (e) {
            [e.source, e.target].forEach(function (id) {
              if (!byId[id] && !missing[id]) {
                missing[id] = true;
                var kind = id.split(":")[0];
                if (!KIND_META[kind]) kind = "external";
                var stub = { id: id, kind: "external", label: id.split(":").slice(1).join(":") || id,
                  x: width / 2 + (Math.random() - 0.5) * 200, y: height / 2 + (Math.random() - 0.5) * 200, vx: 0, vy: 0 };
                byId[id] = stub;
                nodes.push(stub);
              }
            });
          });
          state.nodes = nodes; state.edges = data.edges; state.byId = byId;
          Object.keys(KIND_META).forEach(function (k) { state.activeKinds[k] = true; });
          Object.keys(EDGE_META).forEach(function (t) { state.activeTypes[t] = (t !== "inferred_uses"); });
          document.getElementById("meta").textContent =
            nodes.length + " 节点 · " + data.edges.length + " 关系 · 生成于 " + new Date(data.generated_at).toLocaleString("zh-CN");
          buildFilters();
          renderList();
          resize();
          startSimulation();
        }

        function buildFilters() {
          var box = document.getElementById("filters");
          box.innerHTML = "";
          function addToggle(map, key, colorVar, label, dashed) {
            var lab = document.createElement("label");
            lab.className = map[key] ? "on" : "";
            var cb = document.createElement("input");
            cb.type = "checkbox"; cb.checked = map[key];
            cb.addEventListener("change", function () { map[key] = cb.checked; lab.className = cb.checked ? "on" : ""; render(); });
            lab.appendChild(cb);
            if (dashed === undefined) {
              var dot = document.createElement("span"); dot.className = "dot"; dot.style.background = colorVar; lab.appendChild(dot);
            } else {
              var line = document.createElement("span"); line.className = "legend-line" + (dashed ? " dashed" : "");
              line.style.borderColor = colorVar; lab.appendChild(line);
            }
            var txt = document.createTextNode(" " + label);
            lab.appendChild(txt);
            box.appendChild(lab);
          }
          Object.keys(KIND_META).forEach(function (k) { addToggle(state.activeKinds, k, KIND_META[k].color, KIND_META[k].label); });
          var sep = document.createElement("span"); sep.style.width = "1px"; sep.style.background = "var(--border)"; sep.style.margin = "0 4px"; box.appendChild(sep);
          Object.keys(EDGE_META).forEach(function (t) { addToggle(state.activeTypes, t, EDGE_META[t].color, EDGE_META[t].label, EDGE_META[t].dashed); });
        }

        function visibleNodes() { return state.nodes.filter(function (n) { return state.activeKinds[n.kind]; }); }
        function visibleEdges() {
          var vn = {}; visibleNodes().forEach(function (n) { vn[n.id] = true; });
          return state.edges.filter(function (e) {
            return state.activeTypes[e.type] && vn[e.source] && vn[e.target];
          });
        }

        // --- simple force layout ---
        var simTicks = 0, simTimer = null;
        function startSimulation() {
          simTicks = 0;
          if (simTimer) clearInterval(simTimer);
          simTimer = setInterval(function () {
            tick();
            simTicks++;
            if (simTicks > 260) { clearInterval(simTimer); simTimer = null; }
            render();
          }, 16);
        }

        function tick() {
          var nodes = visibleNodes();
          var edges = visibleEdges();
          var k = 2600;
          for (var i = 0; i < nodes.length; i++) {
            for (var j = i + 1; j < nodes.length; j++) {
              var a = nodes[i], b = nodes[j];
              var dx = a.x - b.x, dy = a.y - b.y;
              var d2 = dx * dx + dy * dy || 0.01;
              var d = Math.sqrt(d2);
              var force = k / d2;
              var fx = (dx / d) * force, fy = (dy / d) * force;
              a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
            }
          }
          edges.forEach(function (e) {
            var a = state.byId[e.source], b = state.byId[e.target];
            if (!a || !b) return;
            var dx = b.x - a.x, dy = b.y - a.y;
            var d = Math.sqrt(dx * dx + dy * dy) || 0.01;
            var ideal = 130;
            var force = (d - ideal) * 0.02;
            var fx = (dx / d) * force, fy = (dy / d) * force;
            a.vx += fx; a.vy += fy; b.vx -= fx; b.vy -= fy;
          });
          var cx = width / 2, cy = height / 2;
          nodes.forEach(function (n) {
            if (n === dragNode) return;
            n.vx += (cx - n.x) * 0.002; n.vy += (cy - n.y) * 0.002;
            n.vx *= 0.82; n.vy *= 0.82;
            n.x += n.vx; n.y += n.vy;
          });
        }

        function radius(n) { return n.kind === "skill" ? 6 : n.kind === "runtime" ? 8 : 7; }

        function render() {
          svg.innerHTML = "";
          var g = el("g", { transform: "translate(" + view.x + "," + view.y + ") scale(" + view.scale + ")" });
          svg.appendChild(g);
          var edges = visibleEdges();
          var nodes = visibleNodes();
          var connected = {};
          if (state.selected) {
            edges.forEach(function (e) {
              if (e.source === state.selected || e.target === state.selected) { connected[e.source] = true; connected[e.target] = true; }
            });
          }
          edges.forEach(function (e) {
            var a = state.byId[e.source], b = state.byId[e.target];
            if (!a || !b) return;
            var meta = EDGE_META[e.type] || { color: "#666" };
            var dim = state.selected && !(e.source === state.selected || e.target === state.selected);
            var line = el("line", {
              x1: a.x, y1: a.y, x2: b.x, y2: b.y,
              stroke: meta.color, "stroke-width": dim ? 0.6 : 1.2,
              "stroke-dasharray": meta.dashed ? "4,3" : "none",
              opacity: dim ? 0.15 : 0.65
            });
            g.appendChild(line);
          });
          nodes.forEach(function (n) {
            var dim = state.selected && n.id !== state.selected && !connected[n.id];
            var meta = KIND_META[n.kind] || KIND_META.external;
            var circle = el("circle", {
              cx: n.x, cy: n.y, r: radius(n),
              fill: meta.color, stroke: n.id === state.selected ? "#fff" : "none", "stroke-width": 1.5,
              opacity: dim ? 0.25 : (n.status === "pending-delete" ? 0.4 : 1)
            });
            circle.style.cursor = "pointer";
            circle.addEventListener("mousedown", function (ev) { startDrag(n, ev); });
            circle.addEventListener("click", function (ev) { ev.stopPropagation(); select(n.id); });
            g.appendChild(circle);
            var label = el("text", { x: n.x + radius(n) + 3, y: n.y + 3, class: "node-label" + (dim ? " dim" : "") });
            label.textContent = n.label;
            g.appendChild(label);
          });
        }

        function select(id) {
          state.selected = id;
          renderDetail(id);
          render();
        }

        function renderDetail(id) {
          var n = state.byId[id];
          var box = document.getElementById("detail");
          if (!n) { box.innerHTML = '<p class="empty">未找到节点。</p>'; return; }
          var meta = KIND_META[n.kind] || KIND_META.external;
          var html = "<h2>" + escapeHtml(n.label) + "</h2>";
          html += '<span class="kind-badge" style="color:' + meta.color + '">' + meta.label + "</span>";
          html += "<dl>";
          function field(label, value) { if (value === undefined || value === null || value === "") return; html += "<dt>" + label + "</dt><dd>" + escapeHtml(String(value)) + "</dd>"; }
          field("状态", n.status);
          field("分类", n.category);
          field("来源", n.provenance);
          field("路径", n.path);
          field("激活路径", n.active_path);
          field("入口", n.entrypoint);
          field("风险等级", n.risk_level);
          field("网络访问", n.network_access);
          field("文件系统访问", n.filesystem_access);
          field("说明", n.purpose || n.description || n.summary);
          field("版本", n.version);
          html += "</dl>";

          var out = state.edges.filter(function (e) { return e.source === id; });
          var incoming = state.edges.filter(function (e) { return e.target === id; });
          html += relGroup("对外关系", out, function (e) { return state.byId[e.target] ? state.byId[e.target].label : e.target; });
          html += relGroup("被引用", incoming, function (e) { return state.byId[e.source] ? state.byId[e.source].label : e.source; });
          box.innerHTML = html;
        }

        function relGroup(title, list, labelFn) {
          if (!list.length) return "";
          var html = '<div class="rel-group"><h3>' + title + " (" + list.length + ')</h3>';
          list.forEach(function (e) {
            var m = EDGE_META[e.type] || { label: e.type };
            html += '<div class="rel-item"><strong>' + m.label + "</strong> → " + escapeHtml(labelFn(e));
            if (e.confidence === "inferred") html += '<span class="inferred-tag">推测</span>';
            if (e.evidence) html += '<div class="evidence">' + escapeHtml(e.evidence) + "</div>";
            html += "</div>";
          });
          html += "</div>";
          return html;
        }

        function escapeHtml(s) { return s.replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }

        function startDrag(n, ev) {
          ev.stopPropagation();
          dragNode = n;
          document.addEventListener("mousemove", onDrag);
          document.addEventListener("mouseup", stopDrag);
        }
        function onDrag(ev) {
          if (!dragNode) return;
          var rect = svg.getBoundingClientRect();
          dragNode.x = (ev.clientX - rect.left - view.x) / view.scale;
          dragNode.y = (ev.clientY - rect.top - view.y) / view.scale;
          dragNode.vx = 0; dragNode.vy = 0;
          render();
        }
        function stopDrag() {
          dragNode = null;
          document.removeEventListener("mousemove", onDrag);
          document.removeEventListener("mouseup", stopDrag);
        }

        svg.addEventListener("mousedown", function (ev) {
          if (ev.target === svg) { panStart = { x: ev.clientX - view.x, y: ev.clientY - view.y }; }
        });
        window.addEventListener("mousemove", function (ev) {
          if (panStart) { view.x = ev.clientX - panStart.x; view.y = ev.clientY - panStart.y; render(); }
        });
        window.addEventListener("mouseup", function () { panStart = null; });
        svg.addEventListener("wheel", function (ev) {
          ev.preventDefault();
          var factor = ev.deltaY < 0 ? 1.1 : 0.9;
          view.scale = Math.max(0.2, Math.min(3, view.scale * factor));
          render();
        }, { passive: false });
        svg.addEventListener("click", function () { select(null); renderDetail(null); document.getElementById("detail").innerHTML = '<p class="empty">点击图里的节点，或列表里的一行，看详细信息。</p>'; });

        document.getElementById("search").addEventListener("input", function (ev) {
          var q = ev.target.value.trim().toLowerCase();
          if (!q) { render(); return; }
          var match = state.nodes.find(function (n) { return n.label.toLowerCase().indexOf(q) !== -1; });
          if (match) select(match.id);
        });

        document.getElementById("refresh").addEventListener("click", load);
        document.getElementById("tab-graph").addEventListener("click", function () { showTab("graph"); });
        document.getElementById("tab-list").addEventListener("click", function () { showTab("list"); });
        function showTab(which) {
          document.getElementById("graph-pane").style.display = which === "graph" ? "block" : "none";
          document.getElementById("list-pane").style.display = which === "list" ? "block" : "none";
          document.getElementById("tab-graph").className = which === "graph" ? "active" : "";
          document.getElementById("tab-list").className = which === "list" ? "active" : "";
        }

        function renderList() {
          var pane = document.getElementById("list-pane");
          var skills = state.nodes.filter(function (n) { return n.kind === "skill"; }).sort(function (a, b) { return a.label.localeCompare(b.label); });
          var html = "<table><thead><tr><th>Skill</th><th>分类</th><th>来源</th><th>状态</th><th>风险</th><th>说明</th></tr></thead><tbody>";
          skills.forEach(function (n) {
            html += "<tr data-id=\"" + n.id + "\"><td>" + escapeHtml(n.label) + "</td><td class=\"dim\">" + escapeHtml(n.category || "") +
              "</td><td class=\"dim\">" + escapeHtml(n.provenance || "") + "</td><td class=\"dim\">" + escapeHtml(n.status || "") +
              "</td><td class=\"dim\">" + escapeHtml(n.risk_level || "") + "</td><td>" + escapeHtml(n.purpose || "") + "</td></tr>";
          });
          html += "</tbody></table>";
          pane.innerHTML = html;
          pane.querySelectorAll("tr[data-id]").forEach(function (row) {
            row.style.cursor = "pointer";
            row.addEventListener("click", function () { select(row.getAttribute("data-id")); showTab("graph"); });
          });
        }

        load();

        // The server auto-shuts-down after a period with no request. As long as this tab
        // stays open, ping it periodically so "the page is open" counts as still in use --
        // closing the tab (and letting the heartbeat lapse) is what actually lets it exit.
        setInterval(function () { fetch("/api/health").catch(function () {}); }, 120000);
      })();
      </script>
      </body>
      </html>
    HTML
  end
end

if $PROGRAM_NAME == __FILE__
  project_root = ENV.fetch("SKILLS_DASHBOARD_PROJECT_ROOT") { raise "SKILLS_DASHBOARD_PROJECT_ROOT is required" }
  port = Integer(ENV.fetch("SKILLS_DASHBOARD_PORT") { raise "SKILLS_DASHBOARD_PORT is required" })
  bind = ENV.fetch("SKILLS_DASHBOARD_BIND", "127.0.0.1")
  idle_timeout = Integer(ENV.fetch("SKILLS_DASHBOARD_IDLE_TIMEOUT", SkillsDashboard::Server::DEFAULT_IDLE_TIMEOUT))
  state_path = ENV["SKILLS_DASHBOARD_STATE_PATH"]
  SkillsDashboard::Server.new(
    project_root: project_root, port: port, bind: bind, idle_timeout: idle_timeout, state_path: state_path
  ).run
end
