--- ai.lua — Async OpenAI-compatible API client with model fallback chain

---@diagnostic disable-next-line: undefined-global
local hs = hs

local log = hs.logger.new("AgentMenu.ai", "debug")

local M = {}

--- Build the model chain (primary first, then fallbacks) for a profile.
--@param cfg     table   Normalised config (from config.lua)
--@param profile string  Profile name (or nil → first profile)
--@return table  Ordered list of model name strings
local function buildChain(cfg, profile)
  local prof = cfg._profileByName[profile]
  if not prof then
    error("[AgentMenu] ai: unknown profile: " .. tostring(profile))
  end
  local chain = { prof.primaryModel }
  for _, fb in ipairs(prof.fallbacks) do
    chain[#chain + 1] = fb
  end
  return chain
end

--- Attempt one model call; on any error invoke onFail.
--@param cfg       table    Normalised config
--@param modelId   string   Model id (as defined in config; may differ from API name)
--@param messages  table    Array of {role, content} tables
--@param onSuccess function(content: string)
--@param onFail    function(errMsg: string)
local function attemptModel(cfg, modelId, messages, onSuccess, onFail)
  local model    = cfg._modelById[modelId]
  local provider = cfg._providerByName[model.provider]
  local url      = provider.baseUrl .. "/chat/completions"
  local headers  = {
    ["Content-Type"]  = "application/json",
    ["Authorization"] = "Bearer " .. provider.apiKey,
  }
  local body = hs.json.encode({
    model    = model.name,  -- send the API model name, not the id
    messages = messages,
    stream   = false,
  })

  log.d("attemptModel: POST " .. url .. " model=" .. model.name .. " (id: " .. modelId .. ")")
  hs.http.asyncPost(url, body, headers, function(code, responseBody, _responseHeaders)
    log.d("attemptModel: response HTTP " .. tostring(code) .. " body_len=" .. tostring(responseBody and #responseBody or 0))
    if code ~= 200 then
      log.w("attemptModel: HTTP error " .. code .. " body: " .. tostring(responseBody):sub(1, 300))
      onFail(string.format("HTTP %d from model '%s' (id: %s)", code, model.name, modelId))
      return
    end
    local ok, decoded = pcall(hs.json.decode, responseBody)
    log.d("attemptModel: json decode ok=" .. tostring(ok) .. " decoded_type=" .. type(decoded))
    if not ok or type(decoded) ~= "table" then
      log.w("attemptModel: json decode failed. body[:500]=" .. tostring(responseBody):sub(1, 500))
      onFail("invalid JSON response from model id: " .. modelId)
      return
    end
    local choices = decoded.choices
    log.d("attemptModel: choices type=" .. type(choices) .. " len=" .. tostring(type(choices) == "table" and #choices or "n/a"))
    if type(choices) ~= "table" or #choices == 0 then
      log.w("attemptModel: empty/missing choices. decoded keys: " .. (function() local k={} for kk in pairs(decoded) do k[#k+1]=kk end return table.concat(k,",") end)())
      onFail("empty choices from model id: " .. modelId)
      return
    end
    local msg = choices[1].message
    log.d("attemptModel: msg type=" .. type(msg) .. " content=" .. tostring(msg and msg.content ~= nil))
    if type(msg) ~= "table" or msg.content == nil then
      log.w("attemptModel: missing message.content. choices[1] keys: " .. (function() local k={} for kk in pairs(choices[1]) do k[#k+1]=kk end return table.concat(k,",") end)())
      onFail("missing message.content from model id: " .. modelId)
      return
    end
    log.d("attemptModel: success, content len=" .. #tostring(msg.content))
    onSuccess(tostring(msg.content), model.name, model.provider)
  end)
end

--- Call the AI with a full model fallback chain.
-- Tries the primary model first; on failure tries each fallback in order.
-- Invokes callback(err, result):
--   • On success: callback(nil, contentString)
--   • On total failure: callback(errorString, nil)
--@param cfg      table    Normalised config (from config.lua)
--@param profile  string   modelSetProfile name (or nil → first profile)
--@param messages table    Array of {role=string, content=string}
--@param callback function
function M.call(cfg, profile, messages, callback)
  -- Resolve nil profile to first defined profile
  if not profile then
    profile = cfg.modelSetProfiles[1].name
  end

  local chain = buildChain(cfg, profile)
  local index = 1

  local function tryNext(lastErr)
    if index > #chain then
      callback(lastErr or "all models failed", nil)
      return
    end
    local modelId = chain[index]
    index = index + 1
    attemptModel(cfg, modelId, messages,
      function(content, modelName, providerName)
        callback(nil, content, modelName, providerName)
      end,
      function(errMsg)
        -- Log and try next model
        hs.logger.new("AgentMenu", "warning").w(
          string.format("[AgentMenu] model id '%s' failed: %s — trying next", modelId, errMsg))
        tryNext(errMsg)
      end
    )
  end

  tryNext(nil)
end

return M
