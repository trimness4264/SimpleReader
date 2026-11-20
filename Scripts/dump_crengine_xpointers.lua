-- From the lib/koreader directory of the official KOReader v2026.07.1 Linux release:
-- LD_LIBRARY_PATH=libs ./luajit /path/to/Scripts/dump_crengine_xpointers.lua /path/to/Tests/Fixtures/xpointer-unicode.epub
-- The EPUB's first chapter is the input to both this probe and ReadingPositionTests.
require("setupkoenv")
local cre = require("libs/libkoreader-cre")
cre.registerFont("fonts/noto/NotoSerif-Regular.ttf")
cre.registerFont("fonts/noto/NotoSans-Regular.ttf")

local doc = cre.newDocView(600, 800, 1)
local version = cre.getLatestDomVersion()
print("DOM version", version)
doc:setIntProperty("crengine.render.requested_dom_version", version)
doc:setStyleSheet("./data/epub.css")
assert(arg[1], "expected path to xpointer-unicode.epub")
assert(doc:loadDocument(arg[1], false), "cannot open EPUB")
doc:renderDocument()

local start = doc:getNextVisibleWordStart("/body/DocFragment/body")
while start do
    local finish = doc:getNextVisibleWordEnd(start)
    if finish then
        print(start, finish, doc:getTextFromXPointers(start, finish))
    end
    local next_word = doc:getNextVisibleWordStart(start)
    if next_word == start then break end
    start = next_word
end
