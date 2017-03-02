------------------------------------------------------
-- Session saving / loading functions               --
-- © 2010 Mason Larobina <mason.larobina@gmail.com> --
------------------------------------------------------

local window = require("window")
local webview = require("webview")
local lousy = require("lousy")
local pickle = lousy.pickle

local session = {}

local function rm(file)
    luakit.spawn(string.format("rm %q", file))
end

-- The file which we'll use for session info, $XDG_DATA_HOME/luakit/session
session.session_file = luakit.data_dir .. "/session"

-- Crash recovery session file
session.recovery_file = luakit.data_dir .. "/recovery_session"

-- Save all given windows uris to file.
session.save = function (wins, file)
    if not file then file = session.session_file end
    local state = {}
    -- Save tabs from all the given windows
    for wi, w in pairs(wins) do
        local current = w.tabs:current()
        state[wi] = { open = {}, closed = {} }
        for ti, tab in ipairs(w.tabs.children) do
            table.insert(state[wi].open, {
                ti = ti,
                current = (current == ti),
                uri = tab.uri,
                session_state = tab.session_state
            })
        end
        for i, tab in ipairs(w.closed_tabs) do
            state[wi].closed[i] = { session_state = tab.session_state, hist = tab.hist }
        end
    end

    if #state > 0 then
        local fh = io.open(file, "wb")
        fh:write(pickle.pickle(state))
        io.close(fh)
    else
        rm(file)
    end
end

-- Load window and tab state from file
session.load = function (delete, file)
    if not file then file = session.session_file end
    if not os.exists(file) then return {} end

    -- Read file
    local fh = io.open(file, "rb")
    local state = pickle.unpickle(fh:read("*all"))
    io.close(fh)
    -- Delete file
    if delete ~= false then rm(file) end

    return state
end

-- Spawn windows from saved session and return the last window
local restore_file = function (file, delete)
    local ok, wins = pcall(session.load, delete, file)
    if not ok or #wins == 0 then return end

    -- Spawn windows
    local w
    for _, win in pairs(wins) do
        w = nil
        for _, item in ipairs(win.open) do
            if not w then
                w = window.new({{ session_state = item.session_state, uri = item.uri }})
            else
                w:new_tab({ session_state = item.session_state, uri = item.uri  }, item.current)
            end
        end
        w.closed_tabs = win.closed
    end

    return w
end

session.restore = function(delete)
    return restore_file(session.session_file, delete)
        or restore_file(session.recovery_file, delete)
end

local recovery_save_timer = timer{ interval = 10*1000 }

-- Save current window session helper
window.methods.save_session = function (w)
    session.save({w,}, session.session_file)
end

local function start_timeout()
    -- Restart the timer
    if recovery_save_timer.started then
        recovery_save_timer:stop()
    end
    recovery_save_timer:start()
end

recovery_save_timer:add_signal("timeout", function ()
    recovery_save_timer:stop()
    local wins = {}
    for _, w in pairs(window.bywidget) do table.insert(wins, w) end
    session.save(wins, session.recovery_file)
end)

window.init_funcs.session_init = function(w)
    w.win:add_signal("destroy", function ()
        -- Hack: should add a luakit shutdown hook...
        local num_windows = 0
        for _, _ in pairs(window.bywidget) do num_windows = num_windows + 1 end
        -- Remove the recovery session on a successful exit
        if num_windows == 0 and os.exists(session.recovery_file) then
            rm(session.recovery_file)
        end
    end)

    w.tabs:add_signal("page-reordered", function ()
        start_timeout()
    end)
end

webview.init_funcs.session_init = function(view)
    -- Save session state after page navigation
    view:add_signal("load-status", function (_, status)
        if status == "committed" then
            start_timeout()
        end
    end)
    -- Save session state after switching page (session includes current tab)
    view:add_signal("switched-page", function ()
        start_timeout()
    end)
end

return session

-- vim: et:sw=4:ts=8:sts=4:tw=80
