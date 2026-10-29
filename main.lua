--[[
halfpageturn.koplugin

Tourne de page en deux temps pour les partitions (PDF, DjVu, CBZ...).

Principe, pour une tourne N -> N+1 marquée :
  1er tap : le HAUT de la page N+1 apparaît en haut de l'écran, le BAS de la
            page N reste en bas (il ne bouge pas et n'est donc pas rafraîchi).
  2e tap  : la page N+1 complète s'affiche (seule la moitié basse est
            rafraîchie, le haut de N+1 est déjà en place).
  Retour  : exactement l'inverse.

Utilisation :
  - Par défaut, toutes les tournes sont normales.
  - Action "Half-page turn: toggle on current page" : active / désactive la
    demi-tourne pour la tourne de la page courante. À assigner dans
    Réglages > Appuis et gestes > Gestionnaire de gestes > Appui dans un coin >
    Coin inférieur droit (ou à n'importe quel autre geste).
    Un petit symbole (mini-page dont la moitié haute est grisée) s'affiche
    alors dans ce coin.
  - En demi-tourne, la démarcation se déplace en faisant glisser sa POIGNÉE
    (la partie élargie, au centre de la ligne). La position est mémorisée
    pour cette tourne.
  - Les informations du bas de page (pied de page KOReader : pages restantes,
    batterie...) sont masquées dès qu'un document contient au moins une
    demi-tourne (option désactivable dans le menu). Si elles restent
    affichées, le symbole se place au-dessus d'elles.
  - Menu : onglet "typeset" > Half-page turn.

Compatibilité avec les plugins qui dessinent par-dessus la page (annotations,
surlignages...) : en demi-état, la vue COMPLÈTE de ReaderView (page + modules
d'affichage) est rendue séparément pour chaque moitié, avec la bonne page.

Les réglages sont enregistrés dans le fichier .sdr du document.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local SETTING_KEY = "halfpageturn"                      -- clé dans doc_settings (.sdr)
local REFRESH_SETTING = "halfpageturn_refresh"          -- global : "ui" | "partial"
local HIDE_FOOTER_SETTING = "halfpageturn_hide_footer"  -- global : masquer la barre d'état
local INK_SETTING = "halfpageturn_ink_mode"      -- global : "integrate" | "suspend"
local RATIO_DEFAULT, RATIO_MIN, RATIO_MAX = 0.5, 0.15, 0.85
local OVERRIDE_WINDOW = 0.8     -- s : durée pendant laquelle on restreint le rafraîchissement

local HalfPageTurn = WidgetContainer:extend{
    name = "halfpageturn",
    is_doc_only = true,
    phase = 0,             -- 0 = page complète, 1 = demi-état
    pending_half = false,  -- on recule et on veut finir en demi-état
    cfg = nil,             -- { enabled = bool, turns = { [N] = { ratio = 0.5 } } }
    drag = nil,
    region_override = nil,
    hooked = false,
    footer_hidden = false,
    saved_footer_mode = nil,
    in_strip = false,      -- vrai pendant le rendu d'une moitié
}

-- ───────────── Initialisation ─────────────

function HalfPageTurn:init()
    self.clear_override_fn = function() self.region_override = nil end

    Dispatcher:registerAction("halfpageturn_toggle", {
        category = "none", event = "ToggleHalfPageTurn",
        title = _("Half-page turn: on/off (this document)"), reader = true,
    })
    Dispatcher:registerAction("halfpageturn_toggle_here", {
        category = "none", event = "ToggleHalfPageTurnHere",
        title = _("Half-page turn: toggle on current page"), reader = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

function HalfPageTurn:onReaderReady()
    if not (self.ui.paging and self.ui.document.info.has_pages) then
        return -- documents reflowables (EPUB...) : plugin inactif
    end
    self.view = self.ui.view
    self:loadConfig()
    self:installHooks()
    self:registerZones()
    self:updateFooter()
end

function HalfPageTurn:loadConfig()
    local s = self.ui.doc_settings:readSetting(SETTING_KEY)
    if type(s) ~= "table" then s = {} end
    s.turns = type(s.turns) == "table" and s.turns or {}
    if s.enabled == nil then s.enabled = true end
    self.cfg = s
end

function HalfPageTurn:persist()
    if self.cfg and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(SETTING_KEY, self.cfg)
    end
end

function HalfPageTurn:onSaveSettings()
    -- n'écrit dans le .sdr que si l'utilisateur a réellement utilisé le plugin
    if self.cfg and (next(self.cfg.turns) ~= nil or self.cfg.enabled == false) then
        self:persist()
    end
end

-- ───────────── Réglages / état ─────────────

function HalfPageTurn:isEnabled()  return self.cfg ~= nil and self.cfg.enabled ~= false end
function HalfPageTurn:isMarked(n)  return self.cfg ~= nil and self.cfg.turns[n] ~= nil end

function HalfPageTurn:refreshType()
    return G_reader_settings:readSetting(REFRESH_SETTING) or "ui"
end

function HalfPageTurn:getRatio(n)
    if self.drag and self.drag.n == n then return self.drag.ratio end
    local t = self.cfg and self.cfg.turns[n]
    return (t and t.ratio) or RATIO_DEFAULT
end

local function clampRatio(r)
    return math.max(RATIO_MIN, math.min(RATIO_MAX, r))
end

function HalfPageTurn:setRatio(n, ratio)
    ratio = math.floor(clampRatio(ratio) * 100 + 0.5) / 100
    local t = self.cfg.turns[n] or {}
    t.ratio = ratio
    self.cfg.turns[n] = t
    self:persist()
    return ratio
end

-- Mode dessin d'Ink Away : "integrate" (défaut) = le dessin voit les deux pages,
-- "suspend" = la demi-tourne est suspendue pendant le dessin.
function HalfPageTurn:inkIntegrated()
    return (G_reader_settings:readSetting(INK_SETTING) or "integrate") == "integrate"
end

-- Une fenêtre Ink Away (mode dessin / annotation, canvas) est-elle ouverte ?
function HalfPageTurn:inkModeOpen()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for i = 1, #stack do
        local w = stack[i] and stack[i].widget
        local name = type(w) == "table" and w.name
        if type(name) == "string" and name:find("^inkaway") then return true end
    end
    return false
end

-- Quitte le demi-état (retour à la page N complète) et redessine
function HalfPageTurn:leaveHalf()
    if self.phase == 1 then
        self.phase, self.drag = 0, nil
        UIManager:setDirty(self.view.dialog, "ui")
    end
end

function HalfPageTurn:isActive()
    if not (self:isEnabled() and self.view) then return false end
    -- mode "suspend" : la demi-tourne est suspendue (tournes normales) le temps du dessin
    if not self:inkIntegrated() and self:inkModeOpen() then return false end
    if self.view.page_scroll then return false end
    local zm = self.ui.zooming and self.ui.zooming.zoom_mode
    -- la page doit tenir entièrement à l'écran
    return zm == "page" or zm == "content"
end

function HalfPageTurn:toast(msg)
    UIManager:show(Notification:new{ text = msg, timeout = 1.5 })
end

-- ───────────── Barre d'état ─────────────
-- Masquée dès que le document contient au moins une demi-tourne
-- (cohérent sur toutes les pages : la zone d'affichage ne change pas entre
-- pages marquées et non marquées).

function HalfPageTurn:getFooter()
    return self.ui.footer or (self.view and self.view.footer)
end

function HalfPageTurn:relayout()
    self.phase, self.pending_half, self.drag = 0, false, nil
    pcall(function() self.view:recalculate() end)
    pcall(function() self.ui:handleEvent(Event:new("SetDimensions", Screen:getSize())) end)
    UIManager:setDirty(self.view.dialog, "partial")
end

function HalfPageTurn:updateFooter()
    local footer = self:getFooter()
    if not (self.cfg and footer and footer.applyFooterMode and footer.mode_list) then return end
    local want_hidden = G_reader_settings:nilOrTrue(HIDE_FOOTER_SETTING)
        and self:isEnabled() and next(self.cfg.turns) ~= nil
    local off = footer.mode_list.off
    if want_hidden and not self.footer_hidden then
        if footer.mode == off then return end  -- déjà masquée par l'utilisateur
        self.saved_footer_mode = footer.mode
        self.footer_hidden = true
        footer:applyFooterMode(off)
        self:relayout()
    elseif not want_hidden and self.footer_hidden then
        self.footer_hidden = false
        footer:applyFooterMode(self.saved_footer_mode)
        self:relayout()
    end
end

-- à la fermeture : on rétablit le mode d'origine (sans redessiner)
function HalfPageTurn:restoreFooterState()
    if not self.footer_hidden then return end
    self.footer_hidden = false
    local footer = self:getFooter()
    if footer and footer.mode_list then
        pcall(function()
            footer.mode = self.saved_footer_mode
            self.view.footer_visible = (self.saved_footer_mode ~= footer.mode_list.off)
        end)
    end
end

-- ───────────── Signets ─────────────

function HalfPageTurn:isBookmarked(page)
    local bm = self.ui.bookmark
    if bm and bm.isPageBookmarked then
        local ok, res = pcall(bm.isPageBookmarked, bm, page)
        if ok then return res and true or false end
    end
    local list = (self.ui.annotation and self.ui.annotation.annotations)
        or (bm and bm.bookmarks) or {}
    for _i, item in ipairs(list) do
        if item.page == page and not item.drawer then return true end
    end
    return false
end

-- Rend muet le dessin de l'indicateur de signet pendant le rendu d'une moitié
-- (quel que soit le réglage qui le commande) ; retourne la fonction de rétablissement.
function HalfPageTurn:muteDogear()
    local view = self.view
    local saved = {}
    local function mute(obj)
        if type(obj) == "table" and type(obj.paintTo) == "function" and saved[obj] == nil then
            saved[obj] = rawget(obj, "paintTo") or false
            obj.paintTo = function() end
        end
    end
    mute(self.ui.dogear)
    mute(view.dogear)
    mute(view.view_modules and view.view_modules.dogear)
    return function()
        for obj, orig in pairs(saved) do
            obj.paintTo = orig or nil
        end
    end
end

-- Dessine l'indicateur de signet (coin supérieur droit) à sa place habituelle
function HalfPageTurn:paintDogear(bb, x, y, bookmarked)
    local view = self.view
    local dg = self.ui.dogear or view.dogear
    if not (bookmarked and dg and dg.paintTo) then return end
    local saved = view.dogear_visible
    view.dogear_visible = true
    local ok, err = pcall(dg.paintTo, dg, bb, x, y)
    view.dogear_visible = saved
    if not ok then logger.warn("halfpageturn: indicateur de signet:", err) end
end

-- ───────────── Géométrie ─────────────

-- origine (écran) de la zone de page affichée
function HalfPageTurn:pageOrigin()
    local view = self.view
    local off = view.state.offset
    return (view.dimen.x or 0) + off.x, (view.dimen.y or 0) + off.y
end

-- y (écran) de la démarcation pour la tourne n
function HalfPageTurn:dividerY(n)
    local _x, y0 = self:pageOrigin()
    return y0 + math.floor(self.view.visible_area.h * self:getRatio(n))
end

-- région (écran) du haut ou du bas de la page pour la tourne n
function HalfPageTurn:getRegion(which, n)
    local va = self.view.visible_area
    local x0, y0 = self:pageOrigin()
    local h_top = math.floor(va.h * self:getRatio(n))
    -- Les deux régions débordent de part et d'autre de la démarcation : la ligne
    -- et sa poignée (dessinées à cheval) sont ainsi toujours rafraîchies, donc
    -- bien effacées quand on repasse à une page complète.
    local pad = Screen:scaleBySize(10)
    -- Largeur : tout l'écran (l'indicateur de signet, le pied de page et le
    -- symbole sont ancrés aux bords de l'écran, parfois hors de la zone de page).
    -- Hauteur : la moitié haute commence au bord haut de l'écran, la moitié basse
    -- va jusqu'au bord bas.
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if which == "top" then
        return Geom:new{ x = 0, y = 0, w = sw, h = math.min(sh, y0 + h_top + pad) }
    end
    local y_start = y0 + math.max(0, h_top - pad)
    return Geom:new{ x = 0, y = y_start, w = sw, h = sh - y_start }
end

-- poignée de la démarcation (partie élargie, au centre de la ligne)
function HalfPageTurn:handleRect(n)
    local va = self.view.visible_area
    local x0 = self:pageOrigin()
    local hw, hh = Screen:scaleBySize(44), Screen:scaleBySize(6)
    return Geom:new{
        x = x0 + math.floor((va.w - hw) / 2),
        y = self:dividerY(n) - math.floor(hh / 2),
        w = hw, h = hh,
    }
end

-- (x, y) écran est-il sur la poignée (avec une petite tolérance pour le doigt) ?
function HalfPageTurn:onHandle(x, y, n)
    local r = self:handleRect(n)
    local tol = Screen:scaleBySize(12)
    return x >= r.x - tol and x <= r.x + r.w + tol
       and y >= r.y - tol and y <= r.y + r.h + tol
end

-- rectangle du petit symbole (coin inférieur droit de la page)
function HalfPageTurn:badgeRect()
    local va = self.view.visible_area
    local x0, y0 = self:pageOrigin()
    local s = Screen:scaleBySize(18)
    local m = Screen:scaleBySize(6)
    local bottom = y0 + va.h
    -- si le pied de page est visible et recouvre le bas de la page,
    -- le symbole se place juste au-dessus
    local footer = self:getFooter()
    if self.view.footer_visible and footer and footer.getHeight then
        local ok, fh = pcall(footer.getHeight, footer)
        if ok and type(fh) == "number" and fh > 0 then
            bottom = math.min(bottom, Screen:getHeight() - fh)
        end
    end
    return Geom:new{ x = x0 + va.w - s - m, y = bottom - s - m, w = s, h = s }
end

-- ───────────── Hooks ─────────────

function HalfPageTurn:installHooks()
    if self.hooked then return end
    self.hooked = true
    local plugin = self
    local paging = self.ui.paging
    local view = self.view

    -- 1) Tourne de page
    local orig_goto = paging.onGotoViewRel
    paging.onGotoViewRel = function(this, diff)
        -- une tourne rapide ne doit pas hériter de la restriction de la précédente
        plugin.region_override = nil
        if plugin:isActive() then
            local ret = plugin:handleTurn(this, diff, orig_goto)
            if ret ~= nil then return ret end
        end
        return orig_goto(this, diff)
    end

    -- 2) Affichage : en demi-état, on compose deux rendus COMPLETS de la vue
    --    (page + modules d'affichage : annotations, surlignages...).
    self.orig_paintTo = view.paintTo
    view.paintTo = function(this, bb, x, y)
        local done = false
        if plugin.phase == 1 and not plugin:inkIntegrated() and plugin:inkModeOpen() then plugin.phase = 0 end
        if plugin.phase == 1 and plugin:isActive() then
            local ok, err = pcall(plugin.paintHalf, plugin, bb, x, y)
            if ok then
                done = true
            else
                logger.err("halfpageturn: erreur de rendu:", err)
                plugin.phase = 0
                UIManager:show(InfoMessage:new{ text = "Half-page turn, erreur de rendu :\n" .. tostring(err) })
            end
        end
        if not done then plugin.orig_paintTo(this, bb, x, y) end
        -- petit symbole dans le coin inférieur droit
        local ok2, err2 = pcall(plugin.paintBadge, plugin, bb)
        if not ok2 then logger.warn("halfpageturn: symbole:", err2) end
    end

    -- 3) Restriction du rafraîchissement lors du saut de page.
    --    Quand on passe de la demi-page à la page complète (ou inversement),
    --    une moitié de l'écran est identique avant/après : on ne rafraîchit
    --    que l'autre moitié, ce qui évite le flash sur la partie inchangée.
    self.orig_setDirty = UIManager.setDirty
    self.setdirty_wrapper = function(um, widget, refreshtype, refreshregion, refreshdither)
        local ov = plugin.region_override
        if ov and refreshregion == nil
                and (widget == view.dialog or widget == view or widget == plugin.ui) then
            return plugin.orig_setDirty(um, widget, ov.rtype, ov.region, refreshdither)
        end
        return plugin.orig_setDirty(um, widget, refreshtype, refreshregion, refreshdither)
    end
    UIManager.setDirty = self.setdirty_wrapper

    -- 4) Ink Away (mode dessin sur le livre)
    local okink, errink = pcall(function() self:installInkSupport() end)
    if not okink then logger.warn("halfpageturn: support Ink Away:", errink) end

    logger.info("halfpageturn: hooks installés")
end

function HalfPageTurn:restoreSetDirty()
    if self.setdirty_wrapper and UIManager.setDirty == self.setdirty_wrapper then
        UIManager.setDirty = self.orig_setDirty
    end
end
function HalfPageTurn:onCloseDocument()
    self:restoreSetDirty()
    self:restoreFooterState()
end
function HalfPageTurn:onCloseWidget()
    self:restoreSetDirty()
    self:restoreFooterState()
end

-- ───────────── Ink Away : mode dessin sur le livre ─────────────
-- Ink Away (ink/reader/book.lua) montre en mode dessin la page courante (via
-- view.paintTo, donc notre rendu en deux moitiés) et l'encre des "pages
-- visibles" (Book:visiblePages -> Book:pageOps). En demi-état on lui fait donc
-- voir les deux pages, chacune ne gardant que son encre de SA moitié d'écran, et
-- on adapte les transformations écran <-> page pour que ce qu'on dessine dans la
-- moitié haute soit rattaché à la page N+1 (et dans la moitié basse à la page N).
-- Aucun fichier d'Ink Away n'est modifié ; chaque adaptation est protégée.

function HalfPageTurn:installInkSupport()
    local plugin = self
    local ink = self.ui.inkaway
    local book = ink and ink.book
    if not book then return end
    local view = self.view

    -- mode "suspend" : on quitte le demi-état AVANT l'ouverture du mode annotation
    if type(book.annotate) == "function" then
        local orig_annotate = book.annotate
        book.annotate = function(this, ...)
            if not plugin:inkIntegrated() then plugin:leaveHalf() end
            return orig_annotate(this, ...)
        end
    end

    -- demi-état visible (hors rendu d'une moitié) et mode intégré
    local function halfNow()
        return plugin.phase == 1 and not plugin.in_strip and plugin:inkIntegrated()
            and plugin:isActive() and view.state and view.state.page ~= nil
    end

    -- 1) les deux pages sont "visibles"
    if type(book.visiblePages) == "function" then
        local orig = book.visiblePages
        book.visiblePages = function(this)
            local pages = orig(this)
            if halfNow() then return { view.state.page, view.state.page + 1 } end
            return pages
        end
    end

    -- 2) page -> écran, aussi pour la page N+1 (même géométrie que la page N)
    local doc = book:doc()
    if doc and type(doc.toScreen) == "function" then
        local orig = doc.toScreen
        doc.toScreen = function(d, page, px, py)
            local st = view.state
            if halfNow() and page == st.page + 1 then
                st.page = page
                local ok, a, b, c = pcall(orig, d, page, px, py)
                st.page = page - 1
                if ok then return a, b, c end
                return nil
            end
            return orig(d, page, px, py)
        end
    end

    -- 3) écran -> page : au-dessus de la démarcation, c'est la page N+1
    if type(view.screenToPageTransform) == "function" then
        local orig = view.screenToPageTransform
        view.screenToPageTransform = function(this, pos, ...)
            if halfNow() and type(pos) == "table" and pos.y then
                local st = this.state
                local n = st.page
                if pos.y < plugin:dividerY(n) then
                    st.page = n + 1
                    local ok, r = pcall(orig, this, pos, ...)
                    st.page = n
                    if ok then return r end
                    return nil
                end
            end
            return orig(this, pos, ...)
        end
    end

    -- 4) l'encre de la page N+1 ne reste que dans la moitié haute, celle de la
    --    page N que dans la moitié basse
    if type(book.pageOps) == "function" then
        local orig = book.pageOps
        book.pageOps = function(this)
            local placed = orig(this)
            if not (placed and placed.ops and halfNow()) then return placed end
            local okc, Canvas = pcall(require, "ink/canvas")
            if not (okc and type(Canvas) == "table" and Canvas.opBox) then return placed end
            local n = view.state.page
            local split = plugin:dividerY(n)
            local out = { key = placed.key, pages = placed.pages, ops = {}, items = {} }
            for i, op in ipairs(placed.ops) do
                local item = placed.items and placed.items[i]
                local pg = item and item.a and item.a.page
                local keep = true
                local okb, _x0, y0, _x1, y1 = pcall(Canvas.opBox, op)
                if okb and y0 and y1 then
                    if pg == n + 1 and y0 >= split then keep = false end
                    if pg == n and y1 <= split then keep = false end
                end
                if keep then
                    out.ops[#out.ops + 1] = op
                    out.items[#out.items + 1] = item
                end
            end
            return out
        end
    end
    logger.info("halfpageturn: support Ink Away installé")
end

-- ───────────── Zones tactiles (glisser la poignée) ─────────────

function HalfPageTurn:registerZones()
    local full = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }
    self.ui:registerTouchZones({
        {
            id = "halfpageturn_pan",
            ges = "pan",
            screen_zone = full,
            overrides = { "paging_pan", "paging_swipe" },
            handler = function(ges) return self:onDividerPan(ges) end,
        },
        {
            id = "halfpageturn_pan_release",
            ges = "pan_release",
            screen_zone = full,
            overrides = { "paging_pan_release" },
            handler = function(ges) return self:onDividerRelease(ges) end,
        },
        {
            id = "halfpageturn_swipe",
            ges = "swipe",
            screen_zone = full,
            overrides = { "paging_swipe" },
            handler = function(ges) return self:onDividerSwipe(ges) end,
        },
    })
end

-- Rafraîchissement complet (avec flash) de l'écran
function HalfPageTurn:fullRefresh()
    UIManager:setDirty(self.view.dialog, "full")
end

function HalfPageTurn:refreshBand(y1, y2, rtype)
    local pad = Screen:scaleBySize(10)
    local top = math.min(y1, y2) - pad
    local bottom = math.max(y1, y2) + pad
    UIManager:setDirty(self.view.dialog, rtype,
        Geom:new{ x = 0, y = top, w = Screen:getWidth(), h = bottom - top })
end

-- Le glissement ne démarre QUE sur la poignée ; ailleurs, le geste est
-- laissé aux autres modules (tourne par swipe, annotation, etc.).
function HalfPageTurn:onDividerPan(ges)
    if not (self.phase == 1 and self:isActive()) then return false end
    local n = self.ui.paging.current_page
    if not self.drag then
        local rel = ges.relative or {}
        local sx = ges.pos.x - (rel.x or 0)
        local sy = ges.pos.y - (rel.y or 0)
        if not self:onHandle(sx, sy, n) then return false end
        local y_now = self:dividerY(n)
        self.drag = {
            n = n,
            ratio = self:getRatio(n),
            grab = sy - y_now,  -- écart doigt / ligne au départ
            min_y = y_now,
            max_y = y_now,
        }
    end
    local d = self.drag
    local _x, y0 = self:pageOrigin()
    local old_y = self:dividerY(n)
    d.ratio = clampRatio((ges.pos.y - d.grab - y0) / self.view.visible_area.h)
    local new_y = self:dividerY(n)
    d.min_y, d.max_y = math.min(d.min_y, new_y), math.max(d.max_y, new_y)
    self:refreshBand(old_y, new_y, "fast")
    return true
end

function HalfPageTurn:onDividerRelease(ges)
    if not self.drag then return false end
    local d = self.drag
    self.drag = nil
    self:setRatio(d.n, d.ratio)
    self:fullRefresh()
    return true
end

-- Un glissement rapide est reconnu comme "swipe" : on le traite aussi
-- (uniquement s'il démarre sur la poignée)
function HalfPageTurn:onDividerSwipe(ges)
    if not (self.phase == 1 and self:isActive()) then return false end
    if self.drag then return self:onDividerRelease(ges) end
    local n = self.ui.paging.current_page
    if not self:onHandle(ges.pos.x, ges.pos.y, n) then return false end
    local dir = ges.direction
    if dir == "north" or dir == "south" then
        local old_y = self:dividerY(n)
        local dy = (dir == "south" and 1 or -1) * (ges.distance or 0)
        local _x, y0 = self:pageOrigin()
        self:setRatio(n, (old_y + dy - y0) / self.view.visible_area.h)
        self:fullRefresh()
    end
    return true -- consommé : pas de tourne de page par swipe
end

-- ───────────── Logique de tourne ─────────────

-- Retourne true/false si l'événement est traité ici, nil pour laisser le
-- comportement standard.
function HalfPageTurn:handleTurn(paging, diff, orig_goto)
    if math.abs(diff) ~= 1 then return nil end
    local cur = paging.current_page
    local total = self.ui.document:getPageCount()

    if diff > 0 then
        if self.phase == 0 then
            if cur < total and self:isMarked(cur) then
                self.phase = 1
                -- seul le haut change (haut de N -> haut de N+1)
                UIManager:setDirty(self.view.dialog, self:refreshType(), self:getRegion("top", cur))
                return true
            end
            return nil
        end
        -- demi-état -> page N+1 complète : seule la moitié basse change
        self.phase = 0
        self:gotoWithRegion(orig_goto, paging, diff, "bottom", cur)
        return true
    end

    -- diff < 0
    if self.phase == 1 then
        -- demi-état -> page N complète : seul le haut change
        self.phase = 0
        UIManager:setDirty(self.view.dialog, self:refreshType(), self:getRegion("top", cur))
        return true
    end
    if cur > 1 and self:isMarked(cur - 1) then
        -- on recule vers N-1 directement en demi-état : seul le bas change
        self.pending_half = true
        local before = paging.current_page
        self:gotoWithRegion(orig_goto, paging, diff, "bottom", cur - 1)
        if paging.current_page == before then self.pending_half = false end
        return true
    end
    return nil
end

function HalfPageTurn:gotoWithRegion(orig_goto, paging, diff, which, turn)
    self.region_override = { region = self:getRegion(which, turn), rtype = self:refreshType() }
    UIManager:unschedule(self.clear_override_fn)
    local before = paging.current_page
    local ret = orig_goto(paging, diff)
    if paging.current_page == before then self.region_override = nil end
    UIManager:scheduleIn(OVERRIDE_WINDOW, self.clear_override_fn)
    return ret
end

function HalfPageTurn:onPageUpdate()
    self.phase = self.pending_half and 1 or 0
    self.pending_half = false
    self.drag = nil
    -- ne pas retourner true : les autres modules doivent aussi recevoir l'événement
end

-- ───────────── Rendu ─────────────
-- Écran en demi-état (tourne N -> N+1, ratio r) :
--   haut (r de la hauteur) : haut de la page N+1  (avec SES annotations)
--   bas  (1-r)             : bas de la page N     (avec SES annotations)

function HalfPageTurn:paintHalf(bb, x, y)
    local view = self.view
    local st = view.state
    local va = view.visible_area
    local n = st.page
    if n >= self.ui.document:getPageCount() then error("pas de page suivante") end

    local paging = self.ui.paging
    local saved_page, saved_offset, saved_va = st.page, st.offset, va
    local saved_current = paging.current_page
    local saved_footer, saved_dogear = view.footer_visible, view.dogear_visible
    local h_top = math.floor(va.h * self:getRatio(n))
    local h_bot = va.h - h_top
    local ox, oy = x + saved_offset.x, y + saved_offset.y

    bb:paintRect(x, y, view.dimen.w, view.dimen.h, Blitbuffer.COLOR_WHITE)

    -- Fait dessiner la vue COMPLÈTE (page + modules d'affichage, donc les
    -- annotations d'autres plugins) par le paintTo d'origine dans un buffer
    -- temporaire, pour la page et la zone voulues, puis copie le résultat.
    local function strip(page, rect, dest_y)
        local tmp = Blitbuffer.new(rect.w, rect.h, bb:getType())
        tmp:paintRect(0, 0, rect.w, rect.h, Blitbuffer.COLOR_WHITE)
        st.page = page
        paging.current_page = page   -- certains plugins lisent la page ici plutôt que dans view.state
        st.offset = Geom:new{ x = 0, y = 0, w = 0, h = 0 }
        view.visible_area = rect
        view.footer_visible = false              -- la barre d'état est redessinée à la fin
        view.dogear_visible = false              -- redessiné à part, à la fin
        local unmute = self:muteDogear()
        self.in_strip = true
        local ok, err = pcall(self.orig_paintTo, view, tmp, 0, 0)
        self.in_strip = false
        unmute()
        st.page, st.offset, view.visible_area = saved_page, saved_offset, saved_va
        paging.current_page = saved_current
        view.footer_visible, view.dogear_visible = saved_footer, saved_dogear
        if ok then bb:blitFrom(tmp, ox, dest_y, 0, 0, rect.w, rect.h) end
        tmp:free()
        if not ok then error(err, 0) end
    end

    -- haut de l'écran : haut de la page N+1
    strip(n + 1, Geom:new{ x = va.x, y = va.y, w = va.w, h = h_top }, oy)
    -- bas de l'écran : bas de la page N (mêmes lignes que dans la page complète)
    strip(n, Geom:new{ x = va.x, y = va.y + h_top, w = va.w, h = h_bot }, oy + h_top)

    -- barre d'état (si elle est affichée) à sa place habituelle
    local footer = self:getFooter()
    if saved_footer and footer and footer.paintTo then
        pcall(footer.paintTo, footer, bb, x, y)
    end

    -- indicateur de signet : celui de la page N+1, puisque le haut de l'écran
    -- montre N+1 (ainsi il est identique à celui de la page complète suivante,
    -- et le haut n'a pas besoin d'être rafraîchi à la tourne suivante)
    self:paintDogear(bb, x, y, self:isBookmarked(n + 1))

    -- ligne de démarcation + poignée (partie élargie, seule zone de saisie)
    local line_h = math.max(2, Screen:scaleBySize(1))
    bb:paintRect(ox, oy + h_top - math.floor(line_h / 2), va.w, line_h, Blitbuffer.COLOR_DARK_GRAY)
    local hr = self:handleRect(n)
    bb:paintRect(hr.x, hr.y, hr.w, hr.h, Blitbuffer.COLOR_BLACK)
end

-- Petit symbole : mini-page dont la moitié haute est grisée
function HalfPageTurn:paintBadge(bb)
    if not (self.cfg and self:isActive() and self:isMarked(self.view.state.page)) then return end
    local r = self:badgeRect()
    local bw = math.max(1, Screen:scaleBySize(2))
    local inner_w, inner_h = r.w - 2 * bw, r.h - 2 * bw
    bb:paintRect(r.x, r.y, r.w, r.h, Blitbuffer.COLOR_BLACK)
    bb:paintRect(r.x + bw, r.y + bw, inner_w, inner_h, Blitbuffer.COLOR_WHITE)
    bb:paintRect(r.x + bw, r.y + bw, inner_w, math.floor(inner_h / 2), Blitbuffer.COLOR_DARK_GRAY)
    bb:paintRect(r.x + bw, r.y + bw + math.floor(inner_h / 2), inner_w, 1, Blitbuffer.COLOR_BLACK)
end

-- ───────────── Actions ─────────────

function HalfPageTurn:toggleMark(n)
    if not self.cfg then return end
    if n >= self.ui.document:getPageCount() then
        self:toast(_("Last page: no turn to split"))
        return
    end
    local msg
    if self.cfg.turns[n] then
        if self.phase == 1 then
            -- on retire la marque depuis le demi-état : retour à la page N complète
            local region = self:getRegion("top", n)
            self.phase = 0
            UIManager:setDirty(self.view.dialog, self:refreshType(), region)
        end
        self.cfg.turns[n] = nil
        msg = string.format(_("Half-page turn OFF (page %d)"), n)
    else
        self.cfg.turns[n] = { ratio = RATIO_DEFAULT }
        msg = string.format(_("Half-page turn ON (page %d)"), n)
    end
    self:persist()
    self:updateFooter()
    self:toast(msg)
    UIManager:setDirty(self.view.dialog, "ui", self:badgeRect())
end

function HalfPageTurn:onToggleHalfPageTurnHere()
    if self:isActive() then self:toggleMark(self.ui.paging.current_page) end
    return true
end

function HalfPageTurn:onToggleHalfPageTurn()
    if not self.cfg then return true end
    self.cfg.enabled = not self:isEnabled()
    self.phase, self.pending_half, self.drag = 0, false, nil
    self:persist()
    self:updateFooter()
    UIManager:setDirty(self.view.dialog, "partial")
    self:toast(self.cfg.enabled and _("Half-page turn: ON") or _("Half-page turn: OFF"))
    return true
end

function HalfPageTurn:showReport()
    local lines = {}
    local function add(k, v) table.insert(lines, k .. " : " .. tostring(v)) end
    add("activé (document)", self:isEnabled())
    add("actif (zoom/scroll ok)", self:isActive())
    add("fenêtre Ink Away ouverte", self:inkModeOpen())
    add("Ink Away détecté", self.ui.inkaway ~= nil)
    add("mode dessin Ink Away", self:inkIntegrated() and "intégré" or "suspendu")
    add("page", self.ui.paging and self.ui.paging.current_page)
    add("rafraîchissement", self:refreshType())
    local footer = self:getFooter()
    add("barre d'état trouvée", footer ~= nil)
    add("barre d'état masquée par le plugin", self.footer_hidden)
    add("footer_visible (vue)", self.view and self.view.footer_visible)
    local mods = {}
    for k in pairs((self.view and self.view.view_modules) or {}) do mods[#mods + 1] = tostring(k) end
    table.sort(mods)
    add("modules d'affichage", #mods > 0 and table.concat(mods, ", ") or "aucun")
    local marked = {}
    if self.cfg then
        for n, t in pairs(self.cfg.turns) do
            marked[#marked + 1] = string.format("%d (%d%%)", n, math.floor((t.ratio or RATIO_DEFAULT) * 100 + 0.5))
        end
    end
    table.sort(marked, function(a, b) return tonumber(a:match("^%d+")) < tonumber(b:match("^%d+")) end)
    add("tournes en 2 temps", #marked > 0 and table.concat(marked, ", ") or "aucune")
    local text = table.concat(lines, "\n")
    logger.info("halfpageturn: rapport\n" .. text)
    UIManager:show(InfoMessage:new{ text = text })
end

-- ───────────── Menu ─────────────

function HalfPageTurn:addToMainMenu(menu_items)
    local function cur() return self.ui.paging and self.ui.paging.current_page or 0 end
    local function refresh_radio(label, rtype)
        return {
            text = label,
            radio = true,
            checked_func = function() return self:refreshType() == rtype end,
            callback = function() G_reader_settings:saveSetting(REFRESH_SETTING, rtype) end,
        }
    end
    menu_items.half_page_turn = {
        text = _("Half-page turn"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Enabled for this document"),
                enabled_func = function() return self.cfg ~= nil end,
                checked_func = function() return self:isEnabled() end,
                callback = function() self:onToggleHalfPageTurn() end,
                separator = true,
            },
            {
                text = _("Half-page turn on the current page"),
                enabled_func = function() return self:isActive() end,
                checked_func = function() return self:isMarked(cur()) end,
                keep_menu_open = true,
                callback = function(tm)
                    self:toggleMark(cur())
                    if tm then tm:updateItems() end
                end,
            },
            {
                text = _("Reset divider of the current turn (50 %)"),
                enabled_func = function() return self:isMarked(cur()) end,
                callback = function()
                    self:setRatio(cur(), RATIO_DEFAULT)
                    UIManager:setDirty(self.view.dialog, "partial")
                end,
            },
            {
                text = _("Remove all half-page turns of this document"),
                enabled_func = function() return self.cfg ~= nil and next(self.cfg.turns) ~= nil end,
                callback = function()
                    self.cfg.turns = {}
                    self.phase = 0
                    self:persist()
                    self:updateFooter()
                    UIManager:setDirty(self.view.dialog, "partial")
                end,
                separator = true,
            },
            {
                text = _("Hide bottom info (footer) in documents using half-page turns"),
                checked_func = function() return G_reader_settings:nilOrTrue(HIDE_FOOTER_SETTING) end,
                callback = function()
                    G_reader_settings:flipNilOrTrue(HIDE_FOOTER_SETTING)
                    self:updateFooter()
                end,
            },
            {
                text = _("Refresh of the changing half"),
                sub_item_table = {
                    refresh_radio(_("Fast, no flash (ui)"), "ui"),
                    refresh_radio(_("Standard (partial)"), "partial"),
                },
            },
            {
                text = _("Ink Away drawing mode"),
                sub_item_table = {
                    {
                        text = _("Show both pages while drawing"),
                        radio = true,
                        checked_func = function() return self:inkIntegrated() end,
                        callback = function() G_reader_settings:saveSetting(INK_SETTING, "integrate") end,
                    },
                    {
                        text = _("Suspend half-page turn while drawing"),
                        radio = true,
                        checked_func = function() return not self:inkIntegrated() end,
                        callback = function() G_reader_settings:saveSetting(INK_SETTING, "suspend") end,
                    },
                },
            },
            {
                text = _("Diagnostic report"),
                callback = function() self:showReport() end,
            },
        },
    }
end

return HalfPageTurn
