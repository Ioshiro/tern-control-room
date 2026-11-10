--!strict
-- Control Room, window half: provider limits and disabled credentials from omp.

local common = require("./common")
local sessions = require("./sessions")

local usage = {}

local function str(value: any): string?
	return if type(value) == "string" and value ~= "" then value else nil
end

local function num(value: any): number?
	return if type(value) == "number" then value else nil
end

--- Converts an omp usage report without depending on the Tern runtime.
function usage.from_omp(value: any, now: number): common.Usage
	local out: common.Usage = { at = now, limits = {}, off = {}, errors = {} }
	if type(value) ~= "table" then
		return out
	end
	if type(value.reports) == "table" then
		for _, report in value.reports do
			if type(report) == "table" and type(report.provider) == "string" and type(report.limits) == "table" then
				local email = if type(report.metadata) == "table" then str(report.metadata.email) else nil
				for _, item in report.limits do
					if type(item) == "table" then
						local window = if type(item.window) == "table" then item.window else {}
						local scope = if type(item.scope) == "table" then item.scope else {}
						local amount = if type(item.amount) == "table" then item.amount else {}
						local used = num(amount.usedFraction)
						local quantity, limit = num(amount.used), num(amount.limit)
						if used == nil and quantity ~= nil and limit ~= nil and limit > 0 then
							used = quantity / limit
						elseif used == nil and quantity ~= nil and amount.unit == "percent" then
							used = quantity / 100
						elseif used == nil then
							local remaining = num(amount.remainingFraction)
							if remaining ~= nil then
								used = math.max(0, 1 - remaining)
							end
						end
						local given = str(item.status)
						local status: string = if given == "ok" or given == "warning" or given == "exhausted" or given == "unknown"
							then given
							elseif used == nil then "unknown"
							elseif used >= 1 then "exhausted"
							elseif used >= 0.8 then "warning"
							else "ok"
						local resets = num(window.resetsAt)
						local row: common.Limit = {
							source = "omp",
							provider = report.provider,
							account = email or str(scope.accountId),
							label = str(item.label) or str(window.label) or "",
							used = used,
							resets_at = if resets then math.floor(resets / 1000) else nil,
							status = status,
						}
						table.insert(out.limits, row)
					end
				end
			end
		end
	end
	if type(value.disabledCredentials) == "table" then
		for _, item in value.disabledCredentials do
			if type(item) == "table" and type(item.provider) == "string" then
				local at = num(item.disabledAtMs)
				local row: common.Credential = {
					source = "omp",
					provider = item.provider,
					account = str(item.email) or str(item.accountId),
					cause = common.clip(str(item.cause) or "", 200),
					at = if at then math.floor(at / 1000) else nil,
				}
				table.insert(out.off, row)
			end
		end
	end
	return out
end

--- Reads omp's usage asynchronously and always returns one report.
function usage.read(done: (report: common.Usage) -> ())
	local finished = false
	local function finish(report: common.Usage)
		if finished then
			return
		end
		finished = true
		report.limits = tern.json.array(report.limits)
		report.off = tern.json.array(report.off)
		report.errors = tern.json.array(report.errors)
		done(report)
	end
	local function fail(reason: string)
		local report: common.Usage = { at = os.time(), limits = {}, off = {}, errors = { "omp usage: " .. common.clip(reason, 160) } }
		finish(report)
	end
	local ok, err = pcall(function()
		tern.process.run({ sessions.omp_exe(), "usage", "--json" }, { timeout_ms = 45000 }, function(result: ProcessResult, _cx: WindowCx?)
			if result.status ~= 0 then
				fail(if result.stderr ~= "" then result.stderr elseif result.timed_out then "timed out" else "exit " .. tostring(result.status))
				return
			end
			local parsed, value = pcall(tern.json.decode, result.stdout)
			if not parsed then
				fail("invalid JSON: " .. tostring(value))
				return
			end
			finish(usage.from_omp(value, os.time()))
		end)
	end)
	if not ok then
		fail(tostring(err))
	end
end

return usage
