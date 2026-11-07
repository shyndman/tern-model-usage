-- model-usage — live omp model usage in Tern's status line.
--
-- Polls `omp usage --json` (coding-plan quota windows) and renders a status-line
-- segment: "usage codex 30% · cc 12%", tinted warn/error as a window fills.
-- Click the segment to see the full per-window breakdown; the "Model Usage" palette commands refresh,
-- show the per-window breakdown, hide the segment, or show the status line.

local POLL_MS = 180000 -- quota windows move slowly, and omp caches reports ~5 min

local PROVIDER_LABELS = {
	["openai-codex"] = "codex",
	["opencode-go"] = "opencode",
	["commandcode"] = "cc",
	["anthropic"] = "claude",
	["google-gemini-cli"] = "gemini-cli",
	["google-antigravity"] = "antigravity",
}

local state = { segments = nil, text = nil, detail = nil, err = nil, raw = nil, canvasPane = nil }
local enabled = true
local polling = false
local lastPoll = nil

local function providerLabel(id)
	return PROVIDER_LABELS[id] or id
end

local function kvGet(key)
	local ok, value = pcall(tern.kv.get, key)
	return ok and value or nil
end

local function kvSet(key, value)
	pcall(tern.kv.set, key, value)
end

local function formatReset(resetsAt, nowMs)
	if type(resetsAt) ~= "number" or type(nowMs) ~= "number" then
		return ""
	end
	local mins = math.floor((resetsAt - nowMs) / 60000)
	if mins < 0 then
		return ""
	end
	if mins >= 1440 then
		return string.format(", resets in %dd %dh", math.floor(mins / 1440), math.floor(mins % 1440 / 60))
	end
	if mins >= 60 then
		return string.format(", resets in %dh %dm", math.floor(mins / 60), mins % 60)
	end
	return string.format(", resets in %dm", mins)
end

local HOUR_MS = 3600000
local SHORT_WINDOW_SHOWN_BELOW = 0.25 -- the short (5h) window only appears under this much remaining

local function usedFraction(limit)
	local amount = limit.amount or {}
	local used = amount.usedFraction
	if type(used) ~= "number" then
		used = (type(amount.used) == "number" and type(amount.limit) == "number" and amount.limit > 0)
				and amount.used / amount.limit
			or 0
	end
	return math.min(1, math.max(0, used))
end

local function windowMs(limit)
	local window = limit.window or {}
	if type(window.durationMs) == "number" then
		return window.durationMs
	end
	local n, unit = tostring(window.id or ""):match("^(%d+)(%a)$")
	if n then
		return tonumber(n) * (unit == "d" and 24 * HOUR_MS or HOUR_MS)
	end
	return 0
end

-- Antigravity's Claude & GPT quota is shared and always shown as noise.
local function hiddenLimit(report, limit)
	if report.provider ~= "google-antigravity" then
		return false
	end
	local id = tostring(limit.id or "")
	local label = tostring(limit.label or "")
	return id:find(":anthropic:", 1, true) ~= nil
		or id:find(":openai:", 1, true) ~= nil
		or label:find("Claude", 1, true) ~= nil
		or label:find("GPT", 1, true) ~= nil
end

-- One entry per provider, in report order, each holding its accounts. A report is
-- an account; reports that show the same windows (Antigravity lists one per
-- project) collapse into one. An account's `long` window is its longest (7d) and
-- `short` its shortest (5h), when that is a different window.
local function collectAccounts(data)
	local order, byProvider, seen = {}, {}, {}
	for _, report in ipairs(data.reports or {}) do
		local provider = report.provider or "?"
		local windows, signature = {}, {}
		for _, limit in ipairs(report.limits or {}) do
			if not hiddenLimit(report, limit) then
				local window = limit.window or {}
				local w = {
					used = usedFraction(limit),
					ms = windowMs(limit),
					id = window.id,
					label = window.label or limit.label or "window",
					resetsAt = window.resetsAt,
					status = limit.status,
					group = limit.label,
				}
				windows[#windows + 1] = w
				signature[#signature + 1] = string.format("%s|%s|%s|%.4f", w.group or "", w.id or "", w.resetsAt or "", w.used)
			end
		end
		if #windows > 0 then
			local key = provider .. "\n" .. table.concat(signature, "\n")
			if not seen[key] then
				seen[key] = true
				local long, short = windows[1], windows[1]
				for _, w in ipairs(windows) do
					if w.ms > long.ms or (w.ms == long.ms and w.used > long.used) then
						long = w
					end
					if w.ms < short.ms or (w.ms == short.ms and w.used > short.used) then
						short = w
					end
				end
				if not byProvider[provider] then
					byProvider[provider] = {}
					order[#order + 1] = provider
				end
				local list = byProvider[provider]
				list[#list + 1] = { windows = windows, long = long, short = short.ms < long.ms and short or nil }
			end
		end
	end
	return order, byProvider
end

-- White at full quota down to red at none, quantised so the stylesheet stays small.
local TONE_STEPS = 20
local RED = { 239, 68, 68 }

local function remainingTone(used)
	local remaining = 1 - used
	return "r" .. math.floor(remaining * TONE_STEPS + 0.5)
end

local function toneCss()
	local rules = {}
	for step = 0, TONE_STEPS do
		local t = step / TONE_STEPS
		local rgb = {}
		for i = 1, 3 do
			rgb[i] = math.floor(RED[i] + (255 - RED[i]) * t + 0.5)
		end
		rules[#rules + 1] = string.format(
			"#statusline .sl-plugin[data-plugin='model-usage'][data-tone='r%d'] { color: rgb(%d, %d, %d); }",
			step,
			rgb[1],
			rgb[2],
			rgb[3]
		)
	end
	return table.concat(rules, "\n")
end

local function remainingPct(used)
	return math.floor((1 - used) * 100 + 0.5)
end

-- omp's UsageReport[] -> status segments (each number with its own colour), the
-- same as plain text for the log, and a one-line detail for the toast fallback.
local function summarize(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local order, byProvider = collectAccounts(data)
	if #order == 0 then
		return nil
	end
	local segments, plain, details = {}, {}, {}
	local command = "plugin.model-usage.details"
	local function push(text, tone)
		segments[#segments + 1] = { text = text, tone = tone, command = command }
		plain[#plain + 1] = text
	end
	for index, provider in ipairs(order) do
		if index > 1 then
			push("|", "muted")
		end
		push(providerLabel(provider), nil)
		local parts = {}
		for n, account in ipairs(byProvider[provider]) do
			if n > 1 then
				push("•", "muted")
			end
			push(remainingPct(account.long.used) .. "%", remainingTone(account.long.used))
			parts[#parts + 1] = remainingPct(account.long.used) .. "%"
			local short = account.short
			if short and 1 - short.used < SHORT_WINDOW_SHOWN_BELOW then
				push("(" .. remainingPct(short.used) .. "%)", remainingTone(short.used))
				parts[#parts] = parts[#parts] .. " (" .. remainingPct(short.used) .. "%)"
			end
		end
		details[#details + 1] = providerLabel(provider) .. " " .. table.concat(parts, " • ") .. " left"
	end
	return segments, table.concat(plain, " "), table.concat(details, " | ")
end

-- The last good report is cached in the plugin's data directory, trimmed to the
-- fields the plugin renders (report metadata carries account ids and an email,
-- which have no business in a status line cache). A fresh window — or a plugin
-- reload — paints the segment and opens the details pane from this instead of
-- going blank until omp answers again.
local CACHE_PATH = nil

local function cachePath()
	if not CACHE_PATH then
		CACHE_PATH = tern.plugin.data .. "/usage.json"
	end
	return CACHE_PATH
end

local function trimReport(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local reports = {}
	for _, report in ipairs(data.reports or {}) do
		local limits = {}
		for _, limit in ipairs(report.limits or {}) do
			local amount = limit.amount or {}
			local window = limit.window
			limits[#limits + 1] = {
				id = limit.id,
				label = limit.label,
				window = window and { id = window.id, label = window.label, resetsAt = window.resetsAt },
				amount = {
					used = amount.used,
					limit = amount.limit,
					usedFraction = amount.usedFraction,
				},
				status = limit.status,
			}
		end
		reports[#reports + 1] = { provider = report.provider, limits = limits }
	end
	return tern.json.encode({ generatedAt = data.generatedAt, reports = reports }, true)
end

local function saveCache(raw)
	local trimmed = trimReport(raw)
	if trimmed then
		pcall(tern.fs.write, cachePath(), trimmed .. "\n")
	end
end

-- Restores the segment and the detail list from the cache. `tern.now()` is a
-- monotonic clock, not wall time, so the cache cannot be aged against the
-- report's epoch stamp; instead the stamp stays part of the data, which keeps
-- every "resets in …" string correct, and any live window replaces the restored
-- numbers within one poll.
local function restoreCache()
	local okRead, text = pcall(tern.fs.read, cachePath())
	if not okRead or type(text) ~= "string" or text == "" then
		return false
	end
	local okDecode, data = pcall(tern.json.decode, text)
	if not okDecode or type(data) ~= "table" or type(data.generatedAt) ~= "number" then
		return false
	end
	local segments, plain, detail = summarize(text)
	if not segments then
		return false
	end
	state.raw, state.segments, state.text, state.detail = text, segments, plain, detail
	return true
end

-- Candidate invocations, most reliable first: a bun interpreter beats an omp
-- shim whose `#!/usr/bin/env bun` needs bun on PATH, which Tern's own env may lack.
local function ompCommands()
	local home = tern.getenv("HOME") or ""
	local cmds = {}
	local function file(path)
		return tern.fs.exists(path)
	end
	if home ~= "" then
		local bun = home .. "/.bun/bin/bun"
		if file(bun) then
			for _, cli in ipairs({
				home .. "/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
				home .. "/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
			}) do
				if file(cli) then
					cmds[#cmds + 1] = { bun, cli, "usage", "--json" }
				end
			end
		end
		for _, bin in ipairs({ home .. "/.bun/bin/omp", home .. "/.local/bin/omp" }) do
			if file(bin) then
				cmds[#cmds + 1] = { bin, "usage", "--json" }
			end
		end
	end
	cmds[#cmds + 1] = { "omp", "usage", "--json" }
	cmds[#cmds + 1] = { "sh", "-lc", "omp usage --json" }
	return cmds
end

-- Polls omp, falling through to the next candidate when a spawn fails or the
-- command itself cannot be found (126/127).
local function fetchUsage(cb)
	local cmds = ompCommands()
	local index = 0
	local function attempt()
		index = index + 1
		local argv = cmds[index]
		if not argv then
			cb(nil, "omp not found")
			return
		end
		local ok, awaitable = pcall(tern.process.run, argv, { timeout_ms = 60000 })
		if not ok then
			attempt()
			return
		end
		awaitable:next(function(result, err, cx)
			if err or not result then
				attempt()
				return
			end
			if result.status == 126 or result.status == 127 then
				attempt()
				return
			end
			if result.status ~= 0 or result.stdout == "" then
				local why = (result.stderr or ""):match("^[^\n]*") or ""
				cb(nil, string.format("%s usage failed (exit %s%s)", argv[1], tostring(result.status), why ~= "" and (": " .. why) or ""))
				return
			end
			cb(result.stdout, nil, cx)
		end)
	end
	attempt()
end

-- Flattens collectAccounts into rows per provider; with several accounts the
-- row name is prefixed "#n" so windows of different accounts stay apart.
local function usageRows(data)
	local order, byProvider = collectAccounts(data)
	local rows = {}
	for _, provider in ipairs(order) do
		rows[provider] = {}
		local accounts = byProvider[provider]
		for n, account in ipairs(accounts) do
			for _, w in ipairs(account.windows) do
				local label = w.id and string.format("%s (%s)", w.label, w.id) or w.label
				rows[provider][#rows[provider] + 1] = {
					name = #accounts > 1 and string.format("#%d %s", n, label) or label,
					used = w.used,
					resetsAt = w.resetsAt,
					status = w.status,
				}
			end
		end
	end
	return order, rows
end

-- Full multi-line usage breakdown: every visible window for every provider.
local function fullUsageText(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local nowMs = data.generatedAt
	local order, rows = usageRows(data)
	local lines = {}
	for _, provider in ipairs(order) do
		lines[#lines + 1] = providerLabel(provider) .. ":"
		for _, w in ipairs(rows[provider]) do
			local status = w.status and w.status ~= "ok" and (" [" .. w.status .. "]") or ""
			lines[#lines + 1] =
				string.format("  %s: %d%% left%s%s", w.name, remainingPct(w.used), formatReset(w.resetsAt, nowMs), status)
		end
		lines[#lines + 1] = ""
	end
	return table.concat(lines, "\n")
end

-- A rich, persistent canvas view: one card per provider with a table row per
-- quota window (bar, percent, reset, status). Returns nil when unsupported.
local function buildUsageView(text)
	local ui = tern.ui
	if not ui then
		return nil
	end
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local nowMs = data.generatedAt
	local order, byProvider = usageRows(data)
	if #order == 0 then
		return nil
	end
	-- Plain `ui.text` lines instead of `ui.table`: with the table node, every
	-- card after the first laid out its frame but painted nothing — no header
	-- row, no cells — while the view itself held every row. Text lines avoid
	-- that node entirely.
	local cards = {}
	for _, provider in ipairs(order) do
		local lines = {}
		for _, w in ipairs(byProvider[provider]) do
			local pct = remainingPct(w.used)
			local name = w.name
			local reset = formatReset(w.resetsAt, nowMs)
			reset = (reset:gsub("^, ", ""))
			local status = w.status or "ok"
			-- Warn at 75% used, error at 90% used.
			local pctTone
			if w.used >= 0.9 then
				pctTone = "error"
			elseif w.used >= 0.75 then
				pctTone = "warn"
			end
			local bar = math.min(10, math.max(0, math.floor((1 - w.used) * 10 + 0.5)))
			lines[#lines + 1] = ui.text({
				ui.span(name, "strong"),
				ui.span(string.format("  %d%% left  ", pct), pctTone),
				ui.span(string.rep("█", bar) .. string.rep("·", 10 - bar), pctTone or "muted"),
				ui.span(reset ~= "" and ("  " .. reset) or "", "muted"),
				ui.span("  " .. status, (w.status and w.status ~= "ok") and "error" or "muted"),
			})
		end
		cards[#cards + 1] = ui.card(providerLabel(provider), { ui.col(lines) })
	end
	return ui.col({
		ui.text({ ui.span("omp model usage", "strong"), ui.span(string.format(" · %d provider(s)", #order), "muted") }),
		ui.col(cards),
	})
end

-- What the pane shows while there is nothing to tabulate: the first poll is
-- still running, or it failed. Kept as a view so the pane opens on the click
-- and fills itself in when the poll lands, instead of showing nothing.
local function noticeView(message)
	return tern.ui.col({
		tern.ui.text({ tern.ui.span("omp model usage", "strong") }),
		tern.ui.text({ tern.ui.span(message, "muted") }),
	})
end

-- The current pane view: the tables once a report is in, otherwise a notice.
local function paneView()
	if state.raw then
		return buildUsageView(state.raw)
	end
	return noticeView(state.err and ("no usage: " .. state.err) or "reading quota windows from omp…")
end

-- The canvas pane showing this plugin's usage, reused across reloads.
local function findCanvas(cx)
	if not cx or not cx.canvas then
		return nil
	end
	if state.canvasPane and cx.canvas:get(state.canvasPane) then
		return state.canvasPane
	end
		state.canvasPane = nil
	local ok, list = pcall(function()
		return cx.canvas:list()
	end)
	if ok and type(list) == "table" then
		for _, info in ipairs(list) do
			local owner = tostring(info.owner or "")
			if info.title == "Model Usage" and (owner == "model-usage" or owner == "plugin:model-usage") then
				state.canvasPane = info.pane
				return info.pane
			end
		end
	end
	return nil
end

-- Opens or refreshes the canvas with the current view. `open` forces a new pane
-- when none exists; returns the pane id, or nil when the host has no canvas.
local function showUsage(cx)
	if not cx or not cx.canvas then
		return nil
	end
	local view = paneView()
	if not view then
		return nil
	end
	local pane = findCanvas(cx)
	if pane then
		local ok = pcall(function()
			cx.canvas:set(pane, { view = view })
		end)
		if ok then
			return pane
		end
		state.canvasPane = nil
	end
	local opened, err = cx.canvas:open({
		title = "Model Usage",
		about = "Live omp coding-plan usage: one row per quota window, read-only.",
		view = view,
		how = "below",
	})
	if opened then
		state.canvasPane = opened
		return opened
	end
	if err then
		tern.log.warn("model-usage: canvas open failed: " .. tostring(err))
	end
	return nil
end

-- `force` skips the gap check: a click on an empty segment must not wait out a
-- poll that already started before the click.
local function poll(cx, force)
	if polling then
		return
	end
	-- window_start and module load can both ask for a first poll within the same
	-- process; one spawn is enough.
	if not force and lastPoll and tern.now() - lastPoll < 30000 then
		return
	end
	lastPoll = tern.now()
	polling = true
	fetchUsage(function(out, err, cx)
		polling = false
		if out then
			local segments, plain, detail = summarize(out)
			if segments then
				state.segments, state.text, state.detail, state.err = segments, plain, detail, nil
				state.raw = out
				saveCache(out)
			else
				state.err = "no usage reported"
			end
		else
			state.err = err or "omp usage failed"
		end
		-- Keep an open canvas in sync without reopening one unprompted: a pane
		-- opened while the first poll was still running shows the report as soon
		-- as it lands, and a failed poll leaves the reason in the pane.
		if state.canvasPane and cx and cx.canvas then
			local pane = state.canvasPane
			pcall(function()
				if cx.canvas:get(pane) then
					local view = paneView()
					if view then
						cx.canvas:set(pane, { view = view })
					end
				else
					state.canvasPane = nil
				end
			end)
		end
		tern.chrome.refresh()
		if state.err then
			tern.log.warn("model-usage: " .. tostring(state.err))
		else
			tern.log.info("model-usage: " .. tostring(state.text))
		end
	end)
end

-- Registration and polling run at module scope: Tern loads a plugin's window entry
-- into an already-running window, where window_start never fires again.
if kvGet("enabled") == false then
	enabled = false
end

tern.chrome.status(function(_pane)
	if not enabled or not state.segments then
		return nil
	end
	return state.segments
end)

tern.css("tones", toneCss())

tern.command({
	id = "refresh",
	title = "Model Usage: Refresh",
	group = "Model Usage",
	run = function(cx)
		cx:toast("info", "Model usage", "Refreshing…")
		poll(cx, true)
	end,
})

tern.command({
	id = "details",
	title = "Model Usage: Details",
	group = "Model Usage",
	-- Never gated: before the first poll the pane still opens and fills itself.
	run = function(cx)
		local pane = showUsage(cx)
		if pane then
			-- Nothing to draw yet: the poll that fills it may have started before
			-- the click, so ask for one now unless one is already in flight.
			if not state.raw then
				poll(cx, true)
			end
			return
		end
		local detail = state.raw and fullUsageText(state.raw) or state.detail
		if not detail or detail == "" then
			detail = state.err and ("no usage: " .. state.err) or "no usage yet"
		end
		cx:toast("info", "Model usage", detail)
	end,
})

tern.command({
	id = "toggle",
	title = "Model Usage: Toggle",
	group = "Model Usage",
	run = function(cx)
		enabled = not enabled
		kvSet("enabled", enabled)
		tern.chrome.refresh()
		cx:toast("info", enabled and "Model usage segment shown" or "Model usage segment hidden")
	end,
})

tern.command({
	id = "status-line",
	title = "Model Usage: Show Status Line",
	group = "Model Usage",
	run = function(cx)
		cx.settings:set("status_bar", true)
		tern.chrome.refresh()
		cx:toast("info", "Status line enabled")
	end,
})

-- Fires only when a window starts with the plugin already installed.
tern.on("window_start", function(cx)
	local ok, shown = pcall(function()
		return cx.settings:get("status_bar")
	end)
	if ok and shown ~= true then
		pcall(function()
			cx.settings:set("status_bar", true)
		end)
	end
	poll(cx)
end)

local function loop()
	tern.timer(POLL_MS, function(cx)
		if enabled then
			poll(cx)
		end
		loop()
	end)
end

-- Paint from the cache first: a window that starts, or a reload, shows the last
-- known windows instead of a blank segment until this process's first poll.
if restoreCache() then
	tern.chrome.refresh()
end

poll()
loop()

tern.log.info("model-usage: ready")
