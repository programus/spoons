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

-- curl writes this sentinel to stdout once the transfer finishes (see the -w
-- argument below).  Without it there is no way to see the HTTP status of a
-- streamed request: -s suppresses it and the body is consumed as SSE.
local HTTP_SENTINEL = "__AGENTMENU_HTTP:"
-- Cap on how much provider error output we keep for the error message.
local ERRBUF_MAX    = 2048

--- Stream one model call via hs.task + curl SSE.
-- onChunk(deltaText) is called for each content delta.
-- onSuccess(fullContent, modelName, providerName, warning) is called when the
--   stream ends with content; `warning` is nil normally, or
--   { kind = "incomplete", detail = string } when the response looks truncated.
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

  local fullContent  = ""
  local lineBuffer   = ""
  local errBuf       = ""
  ---@type number|nil
  local httpCode     = nil
  local reasoningLen = 0

  -- Remember anything that looks like a diagnostic so failures can say why.
  local function noteError(s)
    if s == nil or s == "" or #errBuf >= ERRBUF_MAX then return end
    errBuf = errBuf .. (errBuf == "" and "" or "\n") .. s
    if #errBuf > ERRBUF_MAX then errBuf = errBuf:sub(1, ERRBUF_MAX) .. "…" end
  end

  local function processLine(line)
    if line == "" then return end

    if line:sub(1, #HTTP_SENTINEL) == HTTP_SENTINEL then
      httpCode = tonumber(line:sub(#HTTP_SENTINEL + 1))
      return
    end

    if line:sub(1, 5) ~= "data:" then
      -- Not an SSE data line.  On 401/429/5xx curl prints the provider's error
      -- JSON here; discarding it (as this code used to) is what turned every
      -- API failure into an unhelpful "no content … exitCode=0".
      if line:sub(1, 6) ~= "event:" and line:sub(1, 3) ~= "id:" and line:sub(1, 1) ~= ":" then
        noteError(line)
      end
      return
    end

    -- SSE allows optional single space after "data:" — strip it if present
    local data = line:sub(6)
    if data:sub(1, 1) == " " then data = data:sub(2) end
    if data == "[DONE]" then return end
    local ok, decoded = pcall(hs.json.decode, data)
    if not ok or type(decoded) ~= "table" then return end
    if decoded.error then
      local e = decoded.error
      local msg = (type(e) == "table" and (e.message or hs.json.encode(e))) or tostring(e)
      log.w("attemptModelStream: API error in stream: " .. tostring(msg))
      noteError("API error: " .. tostring(msg))
      return
    end
    local choices = decoded.choices
    if type(choices) ~= "table" or #choices == 0 then return end
    local choice = choices[1]
    local delta  = type(choice.delta) == "table" and choice.delta or nil

    -- Field compatibility: OpenAI uses delta.content; some compatibility layers
    -- send delta.text, and the legacy completions shape puts it on choice.text.
    -- Reasoning tokens are counted but never merged into the answer.
    local piece = nil
    if delta then
      if type(delta.content) == "string" then
        piece = delta.content
      elseif type(delta.text) == "string" then
        piece = delta.text
      end
      if type(delta.reasoning_content) == "string" then
        reasoningLen = reasoningLen + #delta.reasoning_content
      end
    end
    if piece == nil and type(choice.text) == "string" then
      piece = choice.text
    end

    if piece and #piece > 0 then
      fullContent = fullContent .. piece
      onChunk(piece)
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
      noteError("curl: " .. stderr:sub(1, 300):gsub("%s+$", ""))
    end
    -- Flush any remaining partial line (the -w sentinel has no trailing newline)
    if #lineBuffer > 0 then
      processLine((lineBuffer:gsub("\r$", "")))
      lineBuffer = ""
    end
    log.d("attemptModelStream: done exitCode=" .. tostring(exitCode)
      .. " http=" .. tostring(httpCode) .. " contentLen=" .. #fullContent)

    local detail = {}
    if httpCode then detail[#detail + 1] = "HTTP " .. httpCode end
    if exitCode ~= 0 then detail[#detail + 1] = "curl exit " .. tostring(exitCode) end
    if #fullContent == 0 and reasoningLen > 0 then
      detail[#detail + 1] = reasoningLen .. " reasoning chars but no answer content"
    end
    if errBuf ~= "" then detail[#detail + 1] = errBuf end
    local detailStr = table.concat(detail, " | ")

    local httpBad = httpCode ~= nil and httpCode ~= 200
    if #fullContent == 0 or httpBad then
      onFail(string.format("model '%s' (id: %s) failed%s",
        model.name, modelId, detailStr ~= "" and (": " .. detailStr) or ""))
      return
    end

    -- Content arrived but the transfer did not end cleanly: keep the text and
    -- let the caller warn that it may be truncated, rather than silently
    -- presenting a half answer as complete.
    local warning = nil
    if exitCode ~= 0 then
      warning = { kind = "incomplete", detail = detailStr }
    end
    onSuccess(fullContent, model.name, model.provider, warning)
  end

  local args = {
    "-s", "-S", "-N",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. provider.apiKey,
    "-d", body,
    "-w", "\n" .. HTTP_SENTINEL .. "%{http_code}",
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
-- callback(err, fullContent, modelName, providerName, warning) is called when
-- the stream ends; `warning` is nil normally, or { kind, detail } when the
-- response arrived but looks truncated.
-- Returns a cancel function.
--@param cfg      table    Normalised config (from config.lua)
--@param profile  string   modelSetProfile name (or nil → first profile)
--@param messages table    Array of {role=string, content=string}
--@param onChunk  function(deltaText: string)
--@param callback function(err, content, modelName, providerName, warning)
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
      function(content, modelName, providerName, warning)
        if attemptActive then
          callback(nil, content, modelName, providerName, warning)
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
