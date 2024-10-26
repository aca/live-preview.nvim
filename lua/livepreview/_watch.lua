-- Copyright Neovim contributors
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.


local uv = vim.uv

local M = {}

--- Types of events watchers will emit.
M.FileChangeType = {
	Created = 1,
	Changed = 2,
	Deleted = 3,
}

--- @class vim._watch.Opts
---
--- @field debounce? integer ms
---
--- An |lpeg| pattern. Only changes to files whose full paths match the pattern
--- will be reported. Only matches against non-directoriess, all directories will
--- be watched for new potentially-matching files. exclude_pattern can be used to
--- filter out directories. When nil, matches any file name.
--- @field include_pattern? vim.lpeg.Pattern
---
--- An |lpeg| pattern. Only changes to files and directories whose full path does
--- not match the pattern will be reported. Matches against both files and
--- directories. When nil, matches nothing.
--- @field exclude_pattern? vim.lpeg.Pattern


--- @class vim._watch.watch.Opts : vim._watch.Opts
--- @field uvflags? uv.fs_event_start.flags

--- Decides if `path` should be skipped.
---
--- @param path string
--- @param opts? vim._watch.Opts
local function skip(path, opts)
	if not opts then
		return false
	end

	if opts.include_pattern and opts.include_pattern:match(path) == nil then
		return true
	end

	if opts.exclude_pattern and opts.exclude_pattern:match(path) ~= nil then
		return true
	end

	return false
end

--- Initializes and starts a |uv_fs_event_t|
---
--- @param path string The path to watch
--- @param opts vim._watch.watch.Opts? Additional options:
---      - uvflags (table|nil)
---                 Same flags as accepted by |uv.fs_event_start()|
--- @param callback vim._watch.Callback Callback for new events
--- @return fun() cancel Stops the watcher
function M.watch(path, opts, callback)
	vim.validate('path', path, 'string')
	vim.validate('opts', opts, 'table', true)
	vim.validate('callback', callback, 'function')

	opts = opts or {}

	path = vim.fs.normalize(path)
	local uvflags = opts and opts.uvflags or {}
	local handle = assert(uv.new_fs_event())

	local _, start_err, start_errname = handle:start(path, uvflags, function(err, filename, events)
		assert(not err, err)
		local fullpath = path
		if filename then
			fullpath = vim.fs.normalize(vim.fs.joinpath(fullpath, filename))
		end

		if skip(fullpath, opts) then
			return
		end

		--- @type vim._watch.FileChangeType
		local change_type
		if events.rename then
			local _, staterr, staterrname = uv.fs_stat(fullpath)
			if staterrname == 'ENOENT' then
				change_type = M.FileChangeType.Deleted
			else
				assert(not staterr, staterr)
				change_type = M.FileChangeType.Created
			end
		elseif events.change then
			change_type = M.FileChangeType.Changed
		end
		callback(fullpath, change_type)
	end)

	if start_err then
		if start_errname == 'ENOENT' then
			-- Server may send "workspace/didChangeWatchedFiles" with nonexistent `baseUri` path.
			-- This is mostly a placeholder until we have `nvim_log` API.
			vim.notify_once(('watch.watch: %s'):format(start_err), vim.log.levels.INFO)
		end
		-- TODO(justinmk): log important errors once we have `nvim_log` API.
		return function() end
	end

	return function()
		local _, stop_err = handle:stop()
		assert(not stop_err, stop_err)
		local is_closing, close_err = handle:is_closing()
		assert(not close_err, close_err)
		if not is_closing then
			handle:close()
		end
	end
end

--- Initializes and starts a |uv_fs_event_t| recursively watching every directory underneath the
--- directory at path.
---
--- @param path string The path to watch. Must refer to a directory.
--- @param opts vim._watch.Opts? Additional options
--- @param callback vim._watch.Callback Callback for new events
--- @return fun() cancel Stops the watcher
function M.watchdirs(path, opts, callback)
	vim.validate('path', path, 'string')
	vim.validate('opts', opts, 'table', true)
	vim.validate('callback', callback, 'function')

	opts = opts or {}
	local debounce = opts.debounce or 500

	local handles = {}

	local timer = assert(uv.new_timer())

	--- Map of file path to boolean indicating if the file has been changed
	--- at some point within the debounce cycle.
	--- @type table<string, boolean>
	local filechanges = {}

	local process_changes --- @type fun()

	--- @param filepath string
	local function create_on_change(filepath)
		return function(err, filename, events)
			assert(not err, err)
			local fullpath = vim.fs.joinpath(filepath, filename)
			if skip(fullpath, opts) then
				return
			end

			if not filechanges[fullpath] then
				filechanges[fullpath] = events.change or false
			end
			timer:start(debounce, 0, process_changes)
		end
	end

	process_changes = function()
		-- Since the callback is debounced it may have also been deleted later on
		-- so we always need to check the existence of the file:
		--   stat succeeds, changed=true  -> Changed
		--   stat succeeds, changed=false -> Created
		--   stat fails                   -> Removed
		for fullpath, changed in pairs(filechanges) do
			uv.fs_stat(fullpath, function(_, stat)
				---@type vim._watch.FileChangeType
				local change_type
				if stat then
					change_type = changed and M.FileChangeType.Changed or M.FileChangeType.Created
					if stat.type == 'directory' then
						local handle = handles[fullpath]
						if not handle then
							handle = assert(uv.new_fs_event())
							handles[fullpath] = handle
							handle:start(fullpath, {}, create_on_change(fullpath))
						end
					end
				else
					change_type = M.FileChangeType.Deleted
					local handle = handles[fullpath]
					if handle then
						if not handle:is_closing() then
							handle:close()
						end
						handles[fullpath] = nil
					end
				end
				callback(fullpath, change_type)
			end)
		end
		filechanges = {}
	end

	local root_handle = assert(uv.new_fs_event())
	handles[path] = root_handle
	local _, start_err, start_errname = root_handle:start(path, {}, create_on_change(path))

	if start_err then
		if start_errname == 'ENOENT' then
			-- Server may send "workspace/didChangeWatchedFiles" with nonexistent `baseUri` path.
			-- This is mostly a placeholder until we have `nvim_log` API.
			vim.notify_once(('watch.watchdirs: %s'):format(start_err), vim.log.levels.INFO)
		end
		-- TODO(justinmk): log important errors once we have `nvim_log` API.

		-- Continue. vim.fs.dir() will return nothing, so the code below is harmless.
	end

	--- "640K ought to be enough for anyone"
	--- Who has folders this deep?
	local max_depth = 100

	for name, type in vim.fs.dir(path, { depth = max_depth }) do
		if type == 'directory' then
			local filepath = vim.fs.joinpath(path, name)
			if not skip(filepath, opts) then
				local handle = assert(uv.new_fs_event())
				handles[filepath] = handle
				handle:start(filepath, {}, create_on_change(filepath))
			end
		end
	end

	local function cancel()
		for fullpath, handle in pairs(handles) do
			if not handle:is_closing() then
				handle:close()
			end
			handles[fullpath] = nil
		end
		timer:stop()
		timer:close()
	end

	return cancel
end

return M
