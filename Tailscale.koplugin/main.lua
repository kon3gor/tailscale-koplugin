local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local BIN_DIR = "/mnt/us/tailscale"
local STATE_DIR = BIN_DIR .. "/state"
local SOCKET = "/tmp/tailscaled.sock"
local PID_FILE = "/tmp/tailscaled_koreader.pid"
local DAEMON_LOG = BIN_DIR .. "/tailscaled.log"
local UP_LOG = "/tmp/tailscale_up.log"
local TS_PORT = "41641"

-- No binaries, no plugin.
if not util.pathExists(BIN_DIR .. "/tailscaled") then
    return { disabled = true, }
end

local Tailscale = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
}

-- Runs a command, returns its combined output (or nil).
local function capture(cmd)
    local pipe = io.popen(cmd .. " 2>&1", "r")
    if not pipe then return nil end
    local out = pipe:read("*a")
    pipe:close()
    return out
end

-- Single-quote a value for the shell, the hard way.
local function shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

local function cli(args)
    return string.format("%s/tailscale --socket=%s %s", BIN_DIR, SOCKET, args)
end

function Tailscale:init()
    self.hostname = G_reader_settings:readSetting("tailscale_hostname") or "kindle"
    self.authkey = G_reader_settings:readSetting("tailscale_authkey") or ""
    self.autostart = G_reader_settings:isTrue("tailscale_autostart")
    -- The kernel may have no TUN device; fall back to userspace networking.
    local userspace = G_reader_settings:readSetting("tailscale_userspace")
    if userspace == nil then
        userspace = not util.pathExists("/dev/net/tun")
    end
    self.userspace = userspace

    if self.autostart and not self:isRunning() then
        self:startDaemon(true)
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function Tailscale:readPid()
    local file = io.open(PID_FILE, "r")
    if not file then return nil end
    local line = file:read("*l")
    file:close()
    return line and tonumber(line) or nil
end

function Tailscale:isRunning()
    local pid = self:readPid()
    return pid ~= nil and util.pathExists("/proc/" .. pid)
end

-- Asking tailscale for our address forks a process, and the menu asks several
-- times per render, so cache it briefly. invalidateState() drops the cache when
-- we do something that changes it.
local STATE_TTL = 2

function Tailscale:invalidateState()
    self.ip_cache = nil
    self.ip_cached_at = nil
end

function Tailscale:getIP()
    local now = os.time()
    if self.ip_cached_at and (now - self.ip_cached_at) < STATE_TTL then
        return self.ip_cache
    end
    local ip
    if self:isRunning() then
        local out = capture(cli("ip -4"))
        ip = out and out:match("(%d+%.%d+%.%d+%.%d+)") or nil
    end
    self.ip_cache = ip
    self.ip_cached_at = now
    return ip
end

-- True once the node has authenticated and holds a tailnet address.
function Tailscale:isConnected()
    return self:getIP() ~= nil
end

-- Menu items render from checked_func/enabled_func, which only re-run when the
-- open menu is told to update. Without this, the daemon checkbox and the
-- Connect/Disconnect entries keep showing stale state until the menu is
-- reopened. The stored instance may outlive the menu, hence the pcall.
function Tailscale:refreshMenu(touchmenu_instance)
    if touchmenu_instance then
        self.touchmenu_instance = touchmenu_instance
    end
    self:invalidateState()
    local instance = self.touchmenu_instance
    if instance then
        pcall(function() instance:updateItems() end)
    end
end

function Tailscale:startDaemon(quiet)
    if self:isRunning() then
        logger.dbg("[Tailscale] daemon already running")
        return true
    end

    local tun = self.userspace and "userspace-networking" or "tailscale0"
    local proxies = self.userspace
        and " --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055"
        or ""

    -- Let Tailscale's UDP port back in through the Kindle's firewall, so peers
    -- can reach us directly instead of bouncing everything off a DERP relay.
    if Device:isKindle() then
        os.execute("iptables -A INPUT -p udp --dport " .. TS_PORT .. " -j ACCEPT")
    end

    local cmd = string.format(
        "mkdir -p %s && cd %s && (./tailscaled --state=%s/tailscaled.state --statedir=%s --socket=%s --tun=%s%s >>%s 2>&1 & echo $! >%s)",
        STATE_DIR, BIN_DIR, STATE_DIR, STATE_DIR, SOCKET, tun, proxies, DAEMON_LOG, PID_FILE)
    logger.dbg("[Tailscale] starting daemon:", cmd)
    os.execute(cmd)
    self:invalidateState()

    -- The socket takes a moment to appear; wait for it rather than guessing.
    for _ = 1, 20 do
        if util.pathExists(SOCKET) then break end
        ffiutil.sleep(0.25)
    end

    if self:isRunning() then
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = self.userspace
                    and _("Tailscale daemon started (userspace networking).")
                    or _("Tailscale daemon started."),
                timeout = 3,
            })
        end
        return true
    end

    if not quiet then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Failed to start the Tailscale daemon.\n\nSee %1"), DAEMON_LOG),
        })
    end
    return false
end

function Tailscale:stopDaemon(quiet)
    if not self:isRunning() then
        os.remove(PID_FILE)
        return true
    end

    os.execute(cli("down"))

    local pid = self:readPid()
    os.execute(string.format("kill -TERM %d", pid))
    for _ = 1, 20 do
        if not util.pathExists("/proc/" .. pid) then break end
        ffiutil.sleep(0.1)
    end
    if util.pathExists("/proc/" .. pid) then
        os.execute(string.format("kill -KILL %d", pid))
        ffiutil.sleep(0.5)
    end

    if Device:isKindle() then
        os.execute("iptables -D INPUT -p udp --dport " .. TS_PORT .. " -j ACCEPT")
    end

    os.remove(PID_FILE)
    os.remove(SOCKET)
    self:invalidateState()

    if not quiet then
        UIManager:show(InfoMessage:new{
            text = _("Tailscale daemon stopped."),
            timeout = 2,
        })
    end
    return true
end

function Tailscale:onToggleTailscale()
    if self:isRunning() then
        self:stopDaemon()
    else
        if self:startDaemon() then
            self:connect()
        end
    end
end

-- Brings the node up. With an auth key this is unattended; without one we have
-- to surface the login URL, which `tailscale up` only prints once it has it.
function Tailscale:connect()
    if not self:startDaemon() then return end

    if self:isConnected() then
        self:showStatus()
        return
    end

    local args = string.format("up --accept-dns=false --hostname=%s", shellQuote(self.hostname))
    if self.authkey ~= "" then
        args = args .. " --authkey=" .. shellQuote(self.authkey)
    end

    os.remove(UP_LOG)
    os.execute(string.format("(%s >%s 2>&1 &)", cli(args), UP_LOG))

    self.waiting = InfoMessage:new{
        text = _("Connecting to Tailscale…"),
        timeout = 60,
    }
    UIManager:show(self.waiting)
    self:pollForLogin(0)
end

function Tailscale:pollForLogin(elapsed)
    if elapsed > 60 then
        self:dismissWaiting()
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Timed out waiting for Tailscale.\n\nSee %1"), UP_LOG),
        })
        return
    end

    local log = capture("cat " .. UP_LOG) or ""
    local url = log:match("(https://login%.tailscale%.com/%S+)")

    if url then
        self:dismissWaiting()
        UIManager:show(InfoMessage:new{
            timeout = 300,
            text = T(_("Open this URL on your phone or computer to authorize this Kindle:\n\n%1"), url),
        })
        -- Keep watching: once authorized, report the address we were given.
        self:refreshMenu()
        self:pollForConnected(0)
        return
    end

    if self:isConnected() then
        self:dismissWaiting()
        self:refreshMenu()
        self:showStatus()
        return
    end

    UIManager:scheduleIn(2, function() self:pollForLogin(elapsed + 2) end)
end

function Tailscale:pollForConnected(elapsed)
    if elapsed > 300 then return end
    self:invalidateState()
    if self:isConnected() then
        self:refreshMenu()
        self:showStatus()
        return
    end
    UIManager:scheduleIn(5, function() self:pollForConnected(elapsed + 5) end)
end

function Tailscale:dismissWaiting()
    if self.waiting then
        UIManager:close(self.waiting)
        self.waiting = nil
    end
end

function Tailscale:disconnect()
    os.execute(cli("down"))
    self:invalidateState()
    UIManager:show(InfoMessage:new{
        text = _("Tailscale disconnected."),
        timeout = 2,
    })
end

function Tailscale:showStatus()
    if not self:isRunning() then
        UIManager:show(InfoMessage:new{
            text = _("The Tailscale daemon is not running."),
            timeout = 3,
        })
        return
    end

    local ip = self:getIP() or _("none yet")
    local status = capture(cli("status --peers=false")) or ""
    -- Trim to something that fits on an InfoMessage.
    local lines = {}
    for line in status:gmatch("[^\n]+") do
        table.insert(lines, line)
        if #lines >= 6 then break end
    end

    UIManager:show(InfoMessage:new{
        timeout = 60,
        text = T(_("Tailscale address: %1\nMode: %2\n\n%3"),
            ip,
            self.userspace and _("userspace networking") or _("TUN"),
            table.concat(lines, "\n")),
    })
end

function Tailscale:showLog()
    local log = capture(string.format("tail -n 12 %s", DAEMON_LOG)) or ""
    UIManager:show(InfoMessage:new{
        timeout = 60,
        text = log ~= "" and log or _("The log is empty."),
    })
end

function Tailscale:showTextDialog(title, value, setting, callback)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        G_reader_settings:saveSetting(setting, text)
                        UIManager:close(dialog)
                        if callback then callback(text) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Tailscale:addToMainMenu(menu_items)
    menu_items.tailscale = {
        text = _("Tailscale"),
        sorting_hint = "network",
        checked_func = function() return self:isConnected() end,
        sub_item_table = {
            {
                text = _("Tailscale daemon"),
                checked_func = function() return self:isRunning() end,
                callback = function(touchmenu_instance)
                    if self:isRunning() then
                        self:stopDaemon()
                    else
                        self:startDaemon()
                    end
                    self:refreshMenu(touchmenu_instance)
                end,
            },
            {
                text = _("Connect"),
                keep_menu_open = true,
                enabled_func = function() return not self:isConnected() end,
                callback = function(touchmenu_instance)
                    self:connect()
                    self:refreshMenu(touchmenu_instance)
                end,
            },
            {
                text = _("Disconnect"),
                keep_menu_open = true,
                enabled_func = function() return self:isConnected() end,
                callback = function(touchmenu_instance)
                    self:disconnect()
                    self:refreshMenu(touchmenu_instance)
                end,
                separator = true,
            },
            {
                text = _("Status"),
                keep_menu_open = true,
                callback = function() self:showStatus() end,
            },
            {
                text = _("View daemon log"),
                keep_menu_open = true,
                callback = function() self:showLog() end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Hostname: %1"), self.hostname)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showTextDialog(_("Tailscale hostname"), self.hostname,
                        "tailscale_hostname", function(text)
                            self.hostname = text
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text_func = function()
                    return self.authkey ~= "" and _("Auth key: set") or _("Auth key: none")
                end,
                help_text = _("An auth key from the Tailscale admin console logs this device in without opening a URL. It is stored in plain text in KOReader's settings."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:showTextDialog(_("Tailscale auth key"), self.authkey,
                        "tailscale_authkey", function(text)
                            self.authkey = text
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text = _("Userspace networking"),
                help_text = _("Required when the kernel has no TUN device. Outbound connections and inbound connections to local ports work; routing traffic for other machines does not."),
                checked_func = function() return self.userspace end,
                enabled_func = function() return not self:isRunning() end,
                callback = function()
                    self.userspace = not self.userspace
                    G_reader_settings:saveSetting("tailscale_userspace", self.userspace)
                end,
            },
            {
                text = _("Start daemon with KOReader"),
                checked_func = function() return self.autostart end,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("tailscale_autostart")
                end,
            },
        },
    }
end

function Tailscale:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_tailscale",
        { category = "none", event = "ToggleTailscale", title = _("Toggle Tailscale"), general = true })
end

return Tailscale
