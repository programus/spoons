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

--- Stream one model call via hs.task + curl SSE.
-- onChunk(deltaText) is called for each content delta.
-- onSuccess(fullContent, modelName, providerName) is called when the stream ends.
-- onFail(errMsg) is called when no content was received (triggers fallback).
-- Returns a cancel function.
local function attemptModelStream(cfg, modelId, messages, onChunk, onSuccess, onFail)
  local model    = cfg._modelById[modelId]
  local provider = cfg._providerByName[model.provider]
  local url      = provider.baseUrl .. "/chat/completions"
  local body     = hs.json.encode({
    model    = model.name,
    messages = messages,
    stream   = true,
  })

  log.d("attemptModelStream: POST " .. url .. " model=" .. model.name .. " (id: " .. modelId .. ")")

  local fullContent = ""
  local lineBuffer  = ""

  local function processLine(line)
    if line:sub(1, 5) ~= "data:" then return end
    -- SSE allows optional single space after "data:" — strip it if present
    local data = line:sub(6)
    if data:sub(1, 1) == " " then data = data:sub(2) end
    if data == "[DONE]" then return end
    local ok, decoded = pcall(hs.json.decode, data)
    if not ok or type(decoded) ~= "table" then return end
    if decoded.error then
      log.w("attemptModelStream: API error in stream: " .. hs.json.encode(decoded.error))
    end
    local choices = decoded.choices
    if type(choices) ~= "table" or #choices == 0 then return end
    local delta = choices[1].delta
    if type(delta) == "table" and type(delta.content) == "string" and #delta.content > 0 then
      fullContent = fullContent .. delta.content
      onChunk(delta.content)
    end
  end

  local streamCb = function(_task, stdout, stderr)
    if stderr and #stderr > 0 then
      log.w("attemptModelStream: stderr: " .. stderr:sub(1, 500))
    end
    if stdout and #stdout > 0 then
      lineBuffer = lineBuffer .. stdout
      while true do
        local nl = lineBuffer:find("\n", 1, true)
        if not nl then break end
        local line = lineBuffer:sub(1, nl - 1):gsub("\r$", "")
        lineBuffer  = lineBuffer:sub(nl + 1)
        processLine(line)
      end
    end
    return true
  end

  local doneCb = function(exitCode, _stdout, stderr)
    if stderr and #stderr > 0 then
      log.w("attemptModelStream: final stderr: " .. stderr:sub(1, 500))
    end
    -- Flush any remaining partial line
    if #lineBuffer > 0 then
      processLine(lineBuffer:gsub("\r$", ""))
      lineBuffer = ""
    end
    log.d("attemptModelStream: done exitCode=" .. tostring(exitCode) .. " contentLen=" .. #fullContent)
    if #fullContent > 0 then
      onSuccess(fullContent, model.name, model.provider)
    else
      onFail(string.format("no content from model '%s' (id: %s) exitCode=%d",
        model.name, modelId, exitCode))
    end
  end

  local args = {
    "-s", "-S", "-N",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. provider.apiKey,
    "-d", body,
    url,
  }

  local task = hs.task.new("/usr/bin/curl", doneCb, streamCb, args)
  task:start()
  return function() task:terminate() end
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

--- Stream the AI with a full model fallback chain.
-- onChunk(deltaText) is called for each streamed token.
-- callback(err, fullContent, modelName, providerName) is called when the stream ends.
-- Returns a cancel function.
--@param cfg      table    Normalised config (from config.lua)
--@param profile  string   modelSetProfile name (or nil → first profile)
--@param messages table    Array of {role=string, content=string}
--@param onChunk  function(deltaText: string)
--@param callback function(err, content, modelName, providerName)
--@return function  cancel()
function M.callStream(cfg, profile, messages, onChunk, callback)
  if not profile then
    profile = cfg.modelSetProfiles[1].name
  end

  local chain = buildChain(cfg, profile)
  local index = 1
  ---@type function|nil
  local currentCancel = nil

  local function tryNext(lastErr)
    if index > #chain then
      callback(lastErr or "all models failed", nil)
      return
    end
    local modelId = chain[index]
    index = index + 1
    -- Guard flag: prevents stale callbacks from a failed attempt reaching the
    -- caller after tryNext() has already moved on to the next model.
    -- This handles a race where hs.task streamCb chunks are still queued on
    -- the main run-loop when doneCb fires with empty content and triggers
    -- fallback — those late chunks must not be forwarded as duplicate output.
    local attemptActive = true
    currentCancel = attemptModelStream(cfg, modelId, messages,
      function(chunk)
        if attemptActive then onChunk(chunk) end
      end,
      function(content, modelName, providerName)
        if attemptActive then
          callback(nil, content, modelName, providerName)
        end
      end,
      function(errMsg)
        attemptActive = false   -- discard any late streamCb chunks for this attempt
        hs.logger.new("AgentMenu", "warning").w(
          string.format("[AgentMenu] model id '%s' stream failed: %s — trying next", modelId, errMsg))
        tryNext(errMsg)
      end
    )
  end

  tryNext(nil)

  return function()
    if currentCancel then currentCancel() end
  end
end

return M
