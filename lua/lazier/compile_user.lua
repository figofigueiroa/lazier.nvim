local fs = require "lazier.util.fs"
local bundler = require "lazier.util.bundler"
local serializer = require "lazier.util.serializer"
local compiler = require "lazier.util.compiler"
local constants = require "lazier.constants"
local wrap = require "lazier.wrap"
local state = require "lazier.state"

table.unpack = table.unpack or unpack

local function has_index(obj, index)
    while obj do
        if obj == index then
            return true
        end
        obj = getmetatable(obj)
        obj = obj and obj.__index
    end
    return false
end

local function fragment_functions(parent, obj, path, i)
    for k, v in pairs(obj) do
        path[i] = k
        if type(v) == "function" then
            local code = "function(...) return " .. parent
            for j = 1, i do
                if serializer.valid_identifier(path[j]) then
                    code = code .. "." .. path[j]
                else
                    code = code .. "[" .. serializer.serialize(path[j]) .. "]"
                end
            end
            code = code .. "(...) end"
            obj[k] = serializer.fragment(code)
        elseif type(v) == "table" then
            fragment_functions(parent, v, path, i + 1)
        end
        path[i] = nil
    end
end

local function compile_user(module, opts, cache, rtps, has_lazier_rtp)
    vim.loader.enable()
    local required_mods = {}
    local _require = require
    --- @diagnostic disable-next-line
    function _G.require(mod)
        if not vim.startswith("mod", "vim.") then
            required_mods[mod] = true
        end
        return _require(mod)
    end

    if opts.lazier.before then
        opts.lazier.before()
    end

    _G.require = _require

    if opts.lazier.generate_lazy_mappings ~= false then
        local Spec = require("lazy.core.plugin").Spec
        local parse = Spec.parse
        function Spec:parse(spec)
            parse(self, spec)
            for _, plugin in pairs(self.plugins) do
                wrap(plugin)
            end
        end
    end

    local lazy_util = require("lazy.core.util")
    local plugin_modules = {}
    local plugin_paths = {}
    lazy_util.lsmod(module, function(plugin_path, modpath)
        local mod = require(plugin_path)
        plugin_paths[modpath] = mod
        plugin_modules[plugin_path] = mod
    end)
    -- captures the return value of every spec module loaded by lazy.nvim
    -- during setup (lazy loads spec modules with `loadfile`, bypassing the
    -- `require` cache, so their tables are otherwise unreachable afterwards
    -- and cannot be matched against the resolved plugins).
    local module_cache = {}
    local loadfile = _G.loadfile
    function _G.loadfile(path, ...)
        if plugin_paths[path] then
            return function()
                return plugin_paths[path]
            end
        end
        local chunk = loadfile(path, ...)
        if type(chunk) == "function" then
            return function(...)
                local ret = chunk(...)
                if module_cache[path] == nil then
                    module_cache[path] = ret
                end
                return ret
            end
        end
        return chunk
    end

    local lazy = require("lazy")
    -- LazyVim's import-order check reads lazy.nvim's import ledger; the
    -- bootstrap below uses a root `plugins` import, which is always recorded
    -- first, so the check can never pass on compile runs (the fast path's
    -- flat spec + trailing distro import passes it legitimately)
    vim.g.lazyvim_check_order = false
    lazy.setup(module, opts)
    _G.loadfile = loadfile

    -- lazy.nvim's import ledger and resolved plugin map, replayed below as a
    -- seed before the compiled spec is constructed: spec modules may read
    -- lazy.nvim's config at require time (e.g. LazyVim's `has_extra`/`has`),
    -- and in the fast path the spec table is built before lazy.setup()
    -- creates the real loader (which then replaces the seed with
    -- `Config.spec = Spec.new()`). Plugins are seeded as `{ name, dir }`
    -- stubs: enough for `has`/`get_plugin_path` at require time.
    local lazy_config = require("lazy.core.config")
    local spec_modules = lazy_config.spec.modules
    local spec_plugin_stubs = {}
    for name, plugin in pairs(lazy_config.spec.plugins) do
        spec_plugin_stubs[name] = { name = name, dir = plugin.dir }
    end

    local loader = require("lazy.core.loader")

    local spec_plugins = {}
    local colors_name = vim.g.colors_name
    local color_rtp
    local non_lazy_plugins = {}
    local lazy_plugins = lazy.plugins()

    -- Modules required while walking the spec, in lazy.nvim's import order.
    -- Emitted as a prologue in the compiled spec so that import-time side
    -- effects still run in order (e.g. LazyVim's `lazyvim.plugins.xtras`
    -- initializes its defaults registry before extras call into it).
    local prologue = {}
    local prologue_seen = {}
    local function add_prologue(name)
        if not prologue_seen[name] then
            prologue_seen[name] = true
            prologue[#prologue + 1] = name
        end
    end

    -- Collects the spec entries of a module (and its child modules, mirroring
    -- lazy.nvim's `Spec:import` lsmod expansion and alphabetical ordering),
    -- preferring tables captured during setup for identity matching.
    local function module_specs(modname)
        local specs
        local mods = {}
        lazy_util.lsmod(modname, function(child, modpath)
            mods[#mods + 1] = { name = child, path = modpath }
        end)
        table.sort(mods, function(a, b)
            return a.name < b.name
        end)
        for _, mod in ipairs(mods) do
            local loaded = module_cache[mod.path]
            if loaded == nil then
                local ok, req = pcall(require, mod.name)
                if ok then
                    loaded = req
                end
            end
            if type(loaded) == "table" then
                add_prologue(mod.name)
                local list = loaded
                local list_schema = true
                if
                    type(list[1]) == "string"
                    or type(list.url) == "string"
                    or type(list.dir) == "string"
                    or type(list.import) == "string"
                then
                    list_schema = false
                    list = { list }
                end
                specs = specs or {}
                for idx, spec in ipairs(list) do
                    specs[#specs + 1] = {
                        spec = spec,
                        mod = mod.name,
                        idx = idx,
                        list_schema = list_schema,
                    }
                end
            end
        end
        return specs
    end

    -- Expands a spec entry into flat records, resolving `import` specs
    -- recursively (including lazy.nvim spec.import functions created by
    -- LazyVim's extras). Without this, specs imported from other plugins
    -- (e.g. a distro's `{ import = "lazyvim.plugins" }`) resolve to the
    -- imported module's list, never match a single plugin and get dropped
    -- from the compiled spec.
    local function expand_entry(entry, out, seen)
        local spec = entry.spec
        if type(spec) ~= "table" then
            return
        end
        local import = type(spec.import) == "string" and spec.import
            or (
                type(spec.import) == "function"
                and type(spec.name) == "string"
                and spec.name
            )
            or nil
        if import then
            if not seen[import] then
                seen[import] = true
                local imported = module_specs(import)
                if imported then
                    for _, child in ipairs(imported) do
                        expand_entry(child, out, seen)
                    end
                end
            end
            -- the import spec itself may also define a plugin
            if spec[1] or spec.url or spec.dir then
                out[#out + 1] = entry
            end
            return
        end
        out[#out + 1] = entry
    end

    local entries = {}
    local seen = {}
    -- tracks, per resolved plugin, how many spec entries matched and whether
    -- every matched schema is simple (plain `opts` table or none, no config
    -- function). Only simple single-entry plugins can be safely configured
    -- before the first frame; anything else needs lazy.nvim's opts merging
    -- and must be left to the deferred lazy.nvim setup.
    local matched_counts = {}
    local all_simple = {}
    local module_names = {}
    for plugins_path in pairs(plugin_modules) do
        module_names[#module_names + 1] = plugins_path
    end
    table.sort(module_names)
    for _, plugins_path in ipairs(module_names) do
        add_prologue(plugins_path)
        local plugins = plugin_modules[plugins_path]
        local list_schema = true
        if
            type(plugins[1]) == "string"
            or type(plugins.url) == "string"
            or type(plugins.dir) == "string"
            or type(plugins.import) == "string"
        then
            list_schema = false
            plugins = { plugins }
        end
        package.loaded[plugins_path] = plugins
        for plugin_idx, plugin in ipairs(plugins) do
            expand_entry({
                spec = plugin,
                mod = plugins_path,
                idx = plugin_idx,
                list_schema = list_schema,
            }, entries, seen)
        end
    end

    for _, entry in ipairs(entries) do
        local plugin = entry.spec
        local plugins_path = entry.mod
        local plugin_idx = entry.idx
        local listSchema = entry.list_schema
        local lazy_plugin
        for _, candidate in ipairs(lazy_plugins) do
            if has_index(candidate, plugin)
                or candidate.dir and plugin.dir
                and fs.abspath(candidate.dir)
                    == fs.abspath(plugin.dir)
            then
                lazy_plugin = candidate
                break
            end
        end

        if lazy_plugin ~= nil then
            local name = lazy_plugin.name
            matched_counts[name] = (matched_counts[name] or 0) + 1
            local simple = (plugin.config == nil or plugin.config == true)
                and (plugin.opts == nil or type(plugin.opts) == "table")
            if not simple then
                all_simple[name] = false
            elseif all_simple[name] == nil then
                all_simple[name] = true
            end
            if colors_name and not color_rtp then
                local extensions = { "vim", "lua" }
                for _, extension in ipairs(extensions) do
                    local path = fs.join(
                        lazy_plugin.dir, "colors", colors_name .. "." .. extension)
                    if fs.stat(path) then
                        color_rtp = lazy_plugin.dir
                        break
                    end
                end
            end

                local function push_non_lazy_plugin(non_lazy_plugin)
                    for i, existing in ipairs(non_lazy_plugins) do
                        if existing.name == non_lazy_plugin.name then
                            -- prefer the entry whose schema can configure the
                            -- plugin (has `opts`/`config`), so that import
                            -- carriers pointing at the same plugin do not
                            -- replace the richer spec that actually
                            -- configures it before the first frame
                            if non_lazy_plugin.rich or not existing.rich then
                                non_lazy_plugin.dep = existing.dep and non_lazy_plugin.dep
                                non_lazy_plugins[i] = non_lazy_plugin
                            end
                            return
                        end
                    end
                    table.insert(non_lazy_plugins, non_lazy_plugin)
                end

                if lazy_plugin.lazy == false and color_rtp ~= lazy_plugin.dir then
                    for _, dep in ipairs(lazy_plugin.dependencies or {}) do
                        for _, dep_lazy_plugin in ipairs(lazy_plugins) do
                            if dep_lazy_plugin.name == dep then
                                push_non_lazy_plugin({
                                    name = dep_lazy_plugin.name,
                                    rtp = dep_lazy_plugin.dir,
                                    dep = true,
                                })
                            end
                        end
                    end
                    push_non_lazy_plugin({
                        name = lazy_plugin.name,
                        rtp = lazy_plugin.dir,
                        priority = lazy_plugin.priority,
                        path = plugins_path,
                        idx = listSchema and plugin_idx or nil,
                        main = loader.get_main(lazy_plugin),
                        rich = plugin.opts ~= nil or plugin.config ~= nil,
                    })
                end
            local spec = vim.deepcopy(plugin)
            spec.keys = lazy_plugin.keys
            spec.event = lazy_plugin.event
            spec.ft = lazy_plugin.ft
            spec.cmd = lazy_plugin.cmd
            local parent = serializer.function_call("require", plugins_path);
            if listSchema then
                parent = serializer.index(parent, plugin_idx)
            end
            fragment_functions(serializer.serialize(parent), spec, {}, 1)
            for _, v in pairs(spec) do
                if type(v) == "table"
                    and getmetatable(v) ~= serializer.Fragment
                then
                    setmetatable(v, nil)
                end
            end
            if serializer.can_serialize(spec) then
                table.insert(spec_plugins, spec)
            else
                table.insert(spec_plugins, parent)
            end
        end
    end

    -- only single-entry plugins whose schema is simple (plain `opts` table or
    -- none, no config function) can be safely configured before the first
    -- frame; anything that needs lazy.nvim's opts merging must run in the
    -- deferred lazy.nvim setup instead.
    for _, non_lazy in ipairs(non_lazy_plugins) do
        if non_lazy.dep then
            non_lazy.simple = false
        else
            non_lazy.simple = matched_counts[non_lazy.name] == 1
                and all_simple[non_lazy.name] == true
        end
    end

    local prologue_src = {
        'local LazyConfig = require("lazy.core.config")',
        "LazyConfig.spec = LazyConfig.spec or { modules = "
            .. serializer.serialize(spec_modules)
            .. ", plugins = "
            .. serializer.serialize(spec_plugin_stubs)
            .. " }",
        "LazyConfig.options = LazyConfig.options or {}",
    }
    for _, mod in ipairs(prologue) do
        prologue_src[#prologue_src + 1] = ("require(%q)"):format(mod)
    end
    local compiled_plugin_spec = table.concat(prologue_src, "\n")
        .. "\nreturn " .. serializer.serialize(spec_plugins, 0, 80 - 7)

    local paths = {
        vim.fn.stdpath("config") .. "/lua"
    }
    if opts.lazier.bundle_plugins then
        local prefix = fs.join(vim.fn.stdpath("data"), "lazy")
        for _, plugin in ipairs(require("lazy").plugins()) do
            if plugin.dir and vim.startswith(plugin.dir, prefix) then
                table.insert(paths, fs.join(plugin.dir, "lua"))
            end
        end
    end

    -- if opts.lazier.compile_api == nil then
    --     opts.lazier.compile_api = true
    -- end
    -- local api_mods = opts.lazier.compile_api and (type(opts.lazier.compile_api) == "boolean" and {
    --     'vim.filetype',
    --     'vim.filetype.detect',
    --     'vim.treesitter.language',
    --     'vim.func',
    --     'vim.func._memoize',
    --     'vim.treesitter.query',
    --     'vim.treesitter._range',
    --     'vim.treesitter.languagetree',
    --     'vim.treesitter',
    --     'vim.F',
    --     'vim.treesitter.highlighter',
    -- } or opts.lazier.compile_api) or {}
    --
    -- for _, mod in ipairs(api_mods) do
    --     required_mods[mod] = true
    -- end

    local custom_modules = {
        lazier_plugin_spec = compiled_plugin_spec
    }

    for mod, _ in pairs(state.const_modules) do
        custom_modules[mod] = "return " .. serializer.serialize(package.loaded[mod])
    end
    for mod, src in pairs(state.compile_modules) do
        custom_modules[mod] = src
    end

    local bundled = bundler.bundle({
        -- modules = api_mods,
        paths = paths,
        filter = required_mods,
        custom_modules = custom_modules
    })

    compiler.try_compile(
        bundled,
        constants.user_bundle_path,
        constants.user_compiled_path
    )

    table.sort(non_lazy_plugins, function(a, b)
        return (a.priority or 50) > (b.priority or 50)
    end)

    local result = {
        non_lazy_plugins = #non_lazy_plugins > 0
            and non_lazy_plugins or nil,
        color_rtp = color_rtp
    }

    if not has_lazier_rtp() then
        vim.opt.rtp:append(rtps.lazier)
    end
    require("lazier.commands")
    if opts.lazier.after then
        opts.lazier.after()
    end
    cache.colorscheme = vim.g.colors_name
    cache.color_rtp = result.color_rtp
    cache.non_lazy_plugins = result.non_lazy_plugins
    cache.bundle_plugins = opts.lazier.bundle_plugins
    fs.write_file(constants.cache_path, vim.json.encode(cache))
end

return compile_user
