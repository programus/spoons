--- === QuickRef ===
---
--- Open a always on top quick reference window from the clipboard, current window, etc.
---

local obj={}
obj.__index = obj

-- Metadata
obj.name = "QuickRef"
obj.version = "0.1"
obj.author = "programus <programus@gmail.com>"
obj.homepage = "https://github.com/programus/spoons"
obj.license = "MIT - https://opensource.org/licenses/MIT"


local function getHtml(type, content, alpha)
  local htmlTemplate = [[
    <!DOCTYPE html>
    <html>
      <head>
        <title>QuickRef[%s]</title>
        <style>
          html {
            height: 100%%;
          }

          body {
            overflow: hidden;
            padding: 0;
            margin: 0;
            width: 100%%;
            height: 100%%;
          }

          %s
        </style>
      </head>
      <body>
        <div class="slider">
          <input type="range" min="10" max="100" value="%d" id="opacity-slider" />
        </div>
        <div class="content">
          %s
        </div>
        <script>
          var setOpacity = function() {
            this.title = this.value;
            setAlpha(this.value / 100);
          };

          var slider = document.getElementById('opacity-slider');
          slider.oninput = setOpacity;
          setOpacity.call(slider);
        </script>
      </body>
    </html>
  ]]

  local cssTable = {
    text = [[
          body {
            display: flex;
            flex-direction: column;
            background: white;
          }

          div {
            display: flex;
          }

          div * {
            flex: 1 1 auto;
          }

          div.slider {
            flex-grow: 0;
            flex-shrink: 0;
            padding: 0 5px;
            background: #eee;
          }

          div.content {
            flex-grow: 1;
            flex-shrink: 1;
          }

          textarea {
            margin: 0;
            padding: 0;
            border: 0;
            width: 100%;
          }
    ]],
    img = [[
          body {
            background-image: linear-gradient(45deg, #808080 25%, transparent 25%), linear-gradient(-45deg, #808080 25%, transparent 25%), linear-gradient(45deg, transparent 75%, #808080 75%), linear-gradient(-45deg, transparent 75%, #808080 75%);
            background-size: 20px 20px;
            background-position: 0 0, 0 10px, 10px -10px, -10px 0px;            
          }

          div.slider {
            padding: 0 5px;
            background: #eee;
            opacity: 0;
            z-index: 9;
            position: absolute;
            top: 1px;
            left: 0;
            right: 0;
            transition: 0.5s;
          }

          div.slider:hover {
            opacity: 1;
          }

          div.slider * {
            width: 100%;
          }

          div.content {
            width: 100%;
            height: 100%;
          }

          img {
            height: 100%;
            width: 100%;
            object-fit: contain;
          }
    ]]
  }
  local contentTable = {
    text = function () return string.format('<textarea autofocus="autofocus">%s</textarea>', content:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;')) end,
    img = function () return string.format('<img src="%s"></img>', content:encodeAsURLString()) end
  }
  return htmlTemplate:format(type, cssTable[type], alpha or 85, contentTable[type]())
end


local function setupWebview(wv, uc)
  wv:transparent(true)
  wv:windowStyle(15)
  wv:allowGestures(true)
  wv:allowMagnificationGestures(true)
  wv:allowTextEntry(true)
  wv:bringToFront(true)
  wv:deleteOnClose(true)

  uc:injectScript({
      source = [[
        function setAlpha(value) {
          try {
            webkit.messageHandlers.alpha.postMessage(value);
          } catch (err) {
            console.log('The controller does not exist yet');
          }
        }
      ]]
    })
  uc:setCallback(function (msg) wv:alpha(msg.body) end)
end

local function defaultRect(size)
  if not size then
    size = {w = 400, h = 200}
  end
  local point = hs.mouse.getRelativePosition()
  return {
    x = point.x - size.w / 2,
    y = point.y + 10,
    w = size.w,
    h = size.h
  }
end

local function getWebview(rect)
  local uc = hs.webview.usercontent.new('alpha')
  local wv = hs.webview.new(rect, {developerExtrasEnabled = true}, uc)
  setupWebview(wv, uc)
  return wv
end

local function showImage(rect, img, scale, alpha)
  if not scale then
    scale = hs.screen.mainScreen():currentMode().scale
  end
  if not rect then
    local size = img:size()
    rect = defaultRect({
        w = size.w / scale,
        h = size.h / scale
      })
  end
  local wv = getWebview(rect)
  wv:html(getHtml('img', img, alpha))
  wv:show()
  return wv
end

local function showText(rect, text, alpha)
  if not rect then
    rect = defaultRect()
  end
  local wv = getWebview(rect)
  wv:html(getHtml('text', text, alpha))
  wv:show()
  return wv
end

--- QuickRef.showBlank([rect], [alpha])
--- Function
--- Show a new text window with blank content.
---
--- Parameters:
---  * rect - The position of the window, default at the mouse pointer with 400 x 200 size.
---  * alpha - The alpha of the window. 0 is transparent, 100 is solid, default: 85
function obj.showBlank(rect, alpha)
  return showText(redt, '', alpha)
end

--- QuickRef.showTopMostWindow([rect])
--- Function
--- Show a new image window with snapshot of current top most window as its content.
---
--- Parameters:
---  * rect - The position of the window, default at the mouse pointer and the same size as the target window.
---  * alpha - The alpha of the window. 0 is transparent, 100 is solid, default: 85
function obj.showTopMostWindowCapture(rect, alpha)
  local window = hs.window.frontmostWindow()
  local image = window:snapshot()
  return showImage(rect, image, nil, alpha)
end

--- QuickRef.showPasteboard([rect])
--- Function
--- Show a new window with content of pasteboard. If there is nothing in pasteboard, a blank window will be shown.
---
--- Parameters:
---  * rect - The position of the window, default at the mouse pointer.
---  * alpha - The alpha of the window. 0 is transparent, 100 is solid, default: 85
function obj.showPasteboard(rect, alpha)
  local clipType = hs.pasteboard.typesAvailable()
  if clipType.image then
    local image = hs.pasteboard.readImage()
    return showImage(rect, image, 1, alpha)
  elseif clipType.string then
    local text = hs.pasteboard.readString()
    return showText(rect, text, alpha)
  else
    return showText(rect, '', alpha)
  end
end

return obj

