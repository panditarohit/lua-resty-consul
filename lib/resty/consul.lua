local pcall = pcall
local tostring = tostring
local cjson = require('cjson')
local json_decode = cjson.decode
local json_encode = cjson.encode
local tbl_concat = table.concat
local tbl_insert = table.insert
local ngx = ngx
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_DEBUG = ngx.DEBUG
local ngx_encode_args = ngx.encode_args
local http = require('resty.http')

local _M = {
    _VERSION = '0.01',
}

local API_VERSION     = "v1"
local DEFAULT_HOST    = "127.0.0.1"
local DEFAULT_PORT    = 8500
local DEFAULT_TIMEOUT = 60*1000 -- 60s efault timeout

local mt = { __index = _M }


function _M.new(_, opts)
    local self = {
        host            = opts.host            or DEFAULT_HOST,
        port            = opts.port            or DEFAULT_PORT,
        connect_timeout = opts.connect_timeout or DEFAULT_TIMEOUT,
        read_timeout    = opts.read_timeout    or DEFAULT_TIMEOUT
    }
    return setmetatable(self, mt)
end


function _M.get_client_body_reader(self, ...)
    return http:get_client_body_reader(...)
end


local function safe_json_decode(json_str)
    local ok, json = pcall(json_decode, json_str)
    if ok then
        return json
    else
        ngx_log(ngx_ERR, json)
    end
end


local function build_uri(key, opts)
    local uri = "/"..API_VERSION..key

    if opts then
        if opts.wait then
            opts.wait = opts.wait.."s"
        end

        local params = ngx_encode_args(opts)
        if #params > 0 then
            uri = uri.."?"..params
        end
    end

    return uri
end

local function connect(self)
    local httpc = http.new()

    local connect_timeout = self.connect_timeout
    if connect_timeout then
        httpc:set_timeout(connect_timeout)
    end

    local ok, err = httpc:connect(self.host, self.port)
    if not ok then
        return nil, err
    end
    return httpc
end


local function _get(httpc, key, opts)
    local uri = build_uri(key, opts)

    local res, err = httpc:request({path = uri})
    if not res then
        return nil, err
    end

    local status = res.status
    if not status then
        return nil, "No status from consul"
    elseif status ~= 200 then
        if status == 404 then
            return nil, "Key not found"
        else
            return nil, "Consul returned: HTTP "..status
        end
    end

    local body, err = res:read_body()
    if not body then
        return nil, err
    end

    local response = safe_json_decode(body)
    local headers = res.headers
    return response, headers["X-Consul-Lastcontact"], headers["X-Consul-Knownleader"]
end


function _M.get(self, key, opts)
    local httpc, err = connect(self)
    if not httpc then
        ngx_log(ngx_ERR, err)
        return nil, err
    end

    if opts and (opts.wait or opts.index) then
        -- Blocking request, increase timeout
        local timeout = 10 * 60 * 1000 -- Default timeout is 10m
        if opts.wait then
            timeout = opts.wait * 1000
        end
        httpc:set_timeout(timeout)
    else
        httpc:set_timeout(self.read_timeout)
    end

    local res, lastcontact_or_err, knownleader = _get(httpc, key, opts)
    httpc:set_keepalive()
    if not res then
        return nil, lastcontact_or_err
    end

    return res, {lastcontact_or_err, knownleader}
end


function _M.get_decoded(self, key, opts)
    local res, err = self:get(key, opts)
    if not res then
        return nil, err
    end
    for _,entry in ipairs(res) do
        if type(entry.Value) == "string" then
            local decoded = ngx.decode_base64(entry.Value)
            if decoded ~= nil then
                entry.Value = decoded
            end
        end
    end
    return res, err
end


function _M.get_json_decoded(self, key, opts)
    local res, err = self:get_decoded(key, opts)
    if not res then
        return nil, err
    end
    for _,entry in ipairs(res) do
        if entry.Value ~= nil then
            local decoded = safe_json_decode(entry.Value)
            if decoded ~= nil then
                entry.Value = decoded
            end
        end
    end
    return res, err
end


function _M.put(self, key, value, opts,lock,session_id)
    if not opts then
        opts = {}
    end

    if lock ~= nil then
        if lock then
            opts.acquire = session_id
        else
            opts.release = session_id
        end
    end

    local httpc, err = connect(self)
    if not httpc then
        ngx_log(ngx_ERR, err)
        return nil, err
    end

    local uri = build_uri(key, opts)

    local body_in
    if type(value) == "table" or type(value) == "boolean" then
        body_in = json_encode(value)
    else
        body_in = value
    end

    local res, err = httpc:request({
        method = "PUT",
        path = uri,
        body = body_in
    })
    if not res then
        return nil, err
    end

    if not res.status then
        return nil, "No status from consul"
    end

    local body, err = res:read_body()
    if not body then
        return nil, err
    end

    httpc:set_keepalive()

    -- If status is not 200 then body is most likely an error message
    if res.status ~= 200 then
        return nil, body
    elseif body and #body > 0 then
        return safe_json_decode(body)
    else
        return true
    end
end


function _M.delete(self, key, recurse)
    local httpc, err = connect(self)
    if not httpc then
        ngx_log(ngx_ERR, err)
        return nil, err
    end

    if recurse then
        recurse = {recurse = true}
    end
    local uri = build_uri(key, recurse)

    local res, err = httpc:request({
        method = "DELETE",
        path = uri,
    })
    if not res then
        return nil, err
    end

    if not res.status then
        return nil, "No status from consul"
    end

    local body, err = res:read_body()
    if not body then
        return nil, err
    end

    httpc:set_keepalive()

    if res.status == 200 then
        return true
    end
        -- DELETE seems to return 200 regardless, but just in case
    return {status = res.status, body = body, headers = res.headers}, err
end

return _M
