#include "native_drawing_renderer.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <hilog/log.h>
#include <inttypes.h>
#include <mutex>
#include <native_buffer/buffer_common.h>
#include <native_buffer/native_buffer.h>
#include <poll.h>
#include <rawfile/raw_file_manager.h>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

#undef LOG_TAG
#define LOG_TAG "NativeDrawingRenderer"

namespace {
// CPU_WRITE: we render into the mapped buffer on the CPU.
// CPU_READ: lets the compositor read the pixels back.
// MEM_DMA: allocate the buffer in DMA memory the Render Service can access
// directly. A buffer tagged CPU_WRITE only would, on some devices, sit in
// memory the compositor cannot scan out, so a freshly flushed frame is not
// recomposited until an unrelated event (a key press waking ArkUI) forces a
// pass — the "typed character only appears on the next keystroke" symptom.
constexpr uint64_t kBufferUsage =
    NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA;

constexpr size_t kMaxGlyphCacheEntries = 4096;
std::atomic<uint64_t> g_frameCounter {0};

// The font collection from OH_Drawing_CreateSharedFontCollection() is a
// process-wide shared object. With multiple terminal tabs (each its own
// renderer) it MUST NOT be destroyed when one renderer tears down — doing so
// frees fonts the other live renderers are still drawing with, which
// intermittently freezes/crashes the app on tab close. So we hold it as a
// process singleton: created once, never destroyed by an instance.
std::mutex g_fontCollectionMutex;
OH_Drawing_FontCollection* g_sharedFontCollection = nullptr;

OH_Drawing_FontCollection* AcquireSharedFontCollection()
{
    std::lock_guard<std::mutex> lock(g_fontCollectionMutex);
    if (!g_sharedFontCollection) {
        g_sharedFontCollection = OH_Drawing_CreateSharedFontCollection();
        if (!g_sharedFontCollection) {
            g_sharedFontCollection = OH_Drawing_CreateFontCollection();
        }
    }
    return g_sharedFontCollection;
}

bool IsSuspiciousCodepoint(uint32_t codepoint)
{
    return codepoint > 0x10FFFF || (codepoint >= 0xD800 && codepoint <= 0xDFFF);
}

std::string HexPreview(const std::string& text, size_t maxBytes = 24)
{
    std::ostringstream out;
    out << "len=" << text.size() << " hex=";
    const size_t limit = std::min(text.size(), maxBytes);
    for (size_t i = 0; i < limit; ++i) {
        char buf[4];
        std::snprintf(buf, sizeof(buf), "%02X", static_cast<unsigned char>(text[i]));
        if (i > 0) {
            out << ' ';
        }
        out << buf;
    }
    if (text.size() > limit) {
        out << " ...";
    }
    return out.str();
}

std::string Utf8FromCodepoint(uint32_t codepoint)
{
    std::string out;
    if (codepoint <= 0x7F) {
        out.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7FF) {
        out.push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else if (codepoint <= 0xFFFF) {
        out.push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (codepoint >> 18)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    }
    return out;
}

bool IsBlankText(const std::string& text)
{
    return text.empty() || (text.size() == 1 && text[0] == ' ');
}

bool IsBuiltinGeometryCodepoint(uint32_t codepoint)
{
    return (codepoint >= 0x2500 && codepoint <= 0x259F);
}

bool EnsureDirectory(const std::string& path)
{
    struct stat st {};
    if (stat(path.c_str(), &st) == 0) {
        return S_ISDIR(st.st_mode);
    }
    return mkdir(path.c_str(), 0755) == 0;
}

bool ExtractRawFileToPath(
    NativeResourceManager* resourceManager,
    const std::string& rawPath,
    const std::string& outputPath)
{
    if (!resourceManager || rawPath.empty() || outputPath.empty()) {
        return false;
    }

    RawFile* file = OH_ResourceManager_OpenRawFile(resourceManager, rawPath.c_str());
    if (!file) {
        return false;
    }

    const size_t fileSize = OH_ResourceManager_GetRawFileSize(file);
    if (fileSize == 0) {
        OH_ResourceManager_CloseRawFile(file);
        return false;
    }

    std::vector<uint8_t> data(fileSize);
    const int readSize = OH_ResourceManager_ReadRawFile(file, data.data(), fileSize);
    OH_ResourceManager_CloseRawFile(file);
    if (readSize <= 0 || static_cast<size_t>(readSize) != fileSize) {
        return false;
    }

    FILE* out = fopen(outputPath.c_str(), "wb");
    if (!out) {
        return false;
    }
    const size_t written = fwrite(data.data(), 1, data.size(), out);
    fclose(out);
    return written == data.size();
}
}

NativeDrawingRenderer::NativeDrawingRenderer() = default;

NativeDrawingRenderer::~NativeDrawingRenderer()
{
    cleanup();
}

size_t NativeDrawingRenderer::GlyphKeyHash::operator()(const GlyphKey& key) const
{
    size_t h = std::hash<std::string>{}(key.text);
    h = (h * 1315423911u) ^ static_cast<size_t>(key.fg);
    h = (h * 1315423911u) ^ static_cast<size_t>(key.styleBits);
    h = (h * 1315423911u) ^ static_cast<size_t>(key.span);
    return h;
}

bool NativeDrawingRenderer::init(OHNativeWindow* window, uint32_t width, uint32_t height)
{
    m_window = window;
    m_width = width;
    m_height = height;

    if (!m_window) {
        OH_LOG_ERROR(LOG_APP, "init failed: window is null");
        return false;
    }

    if (!configureWindow()) {
        return false;
    }

    if (!ensureDrawingObjects()) {
        return false;
    }

    if (!m_fontCollection) {
        // Process-wide shared singleton (see AcquireSharedFontCollection).
        m_fontCollection = AcquireSharedFontCollection();
    }

    updateCellDimensions();
    OH_LOG_INFO(LOG_APP, "Native drawing renderer ready: %ux%u", m_width, m_height);
    return true;
}

void NativeDrawingRenderer::cleanup()
{
    if (m_currentBuffer && m_window) {
        if (m_currentNativeBuffer) {
            OH_NativeBuffer_Unmap(m_currentNativeBuffer);
        }
        OH_NativeWindow_NativeWindowAbortBuffer(m_window, m_currentBuffer);
    }
    if (m_currentFenceFd >= 0) {
        close(m_currentFenceFd);
    }
    m_currentFenceFd = -1;
    m_currentBuffer = nullptr;
    m_currentNativeBuffer = nullptr;
    m_currentPixels = nullptr;
    m_currentConfig = {};

    clearGlyphCache();

    if (m_rect) {
        OH_Drawing_RectDestroy(m_rect);
        m_rect = nullptr;
    }
    if (m_brush) {
        OH_Drawing_BrushDestroy(m_brush);
        m_brush = nullptr;
    }
    if (m_canvas) {
        OH_Drawing_CanvasDestroy(m_canvas);
        m_canvas = nullptr;
    }
    // Do NOT destroy m_fontCollection here: it is the process-wide shared
    // collection (AcquireSharedFontCollection) that other live renderers/tabs
    // keep using. Just drop our reference.
    m_fontCollection = nullptr;

    m_lastCursorRectValid = false;
    m_window = nullptr;
    m_fontsConfigured = false;
}

void NativeDrawingRenderer::resize(uint32_t width, uint32_t height)
{
    m_width = width;
    m_height = height;
    configureWindow();
}

bool NativeDrawingRenderer::loadFontAtlas(NativeResourceManager* resourceManager, const std::string& filesDir)
{
    if (!m_fontCollection) {
        return false;
    }
    if (m_fontsConfigured) {
        return true;
    }

    {
        std::lock_guard<std::mutex> lock(g_fontCollectionMutex);
        static bool s_fontsRegistered = false;
        if (!s_fontsRegistered) {
            auto registerBundledFont = [&](const char* rawfileName, const char* familyName, const char* destFilename) {
                if (!resourceManager || filesDir.empty()) {
                    OH_LOG_WARN(LOG_APP, "FT_FONT Cannot register %{public}s: resourceManager=%{public}p filesDir empty=%{public}d",
                                familyName, resourceManager, (int)filesDir.empty());
                    return;
                }
                const std::string fontDir = filesDir + "/fonts";
                const std::string destPath = fontDir + "/" + destFilename;
                const std::string rawPath = std::string("fonts/") + rawfileName;
                if (EnsureDirectory(fontDir) &&
                    ExtractRawFileToPath(resourceManager, rawPath, destPath)) {
                    uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection, familyName, destPath.c_str());
                    OH_LOG_INFO(LOG_APP, "FT_FONT Registered %{public}s rc=%{public}u (0=success)", familyName, rc);
                } else {
                    OH_LOG_WARN(LOG_APP, "FT_FONT %{public}s not found in rawfile, skipping", familyName);
                }
            };

            OH_LOG_INFO(LOG_APP, "FT_FONT filesDir='%{public}s'", filesDir.c_str());
            registerBundledFont("JetBrainsMono-Regular.ttf", "JetBrains Mono", "JetBrainsMono-Regular.ttf");
            registerBundledFont("FiraCode-Regular.ttf", "Fira Code", "FiraCode-Regular.ttf");
            registerBundledFont("CascadiaCode-Regular.ttf", "Cascadia Code", "CascadiaCode-Regular.ttf");
            registerBundledFont("SourceCodePro-Regular.ttf", "Source Code Pro", "SourceCodePro-Regular.ttf");
            registerBundledFont("ClaudeSans-Regular.ttf", "Claude Sans", "ClaudeSans-Regular.ttf");

            // 2. System Noto Sans Mono — always available on HarmonyOS
            const char* sysMonoPath = "/system/fonts/NotoSansMono[wdth,wght].ttf";
            if (access(sysMonoPath, R_OK) == 0) {
                uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection, "Noto Sans Mono", sysMonoPath);
                OH_LOG_INFO(LOG_APP, "Registered Noto Sans Mono rc=%u", rc);
            } else {
                OH_LOG_WARN(LOG_APP, "System mono font unavailable: %{public}s", sysMonoPath);
            }

            // 3. UI fonts — Inter (sans) and Source Serif 4 (serif), bundled as rawfile
            if (resourceManager && !filesDir.empty()) {
                const std::string fontDir = filesDir + "/fonts";
                const std::string interPath = fontDir + "/Inter-Regular.otf";
                if (EnsureDirectory(fontDir) &&
                    ExtractRawFileToPath(resourceManager, "fonts/Inter-Regular.otf", interPath)) {
                    uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection, "Inter", interPath.c_str());
                    OH_LOG_INFO(LOG_APP, "Registered Inter rc=%u", rc);
                } else {
                    OH_LOG_WARN(LOG_APP, "Inter not found in rawfile, skipping");
                }
                const std::string sourceSerifPath = fontDir + "/SourceSerif4-Regular.otf";
                if (EnsureDirectory(fontDir) &&
                    ExtractRawFileToPath(resourceManager, "fonts/SourceSerif4-Regular.otf", sourceSerifPath)) {
                    uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection, "Source Serif 4", sourceSerifPath.c_str());
                    OH_LOG_INFO(LOG_APP, "Registered Source Serif 4 rc=%u", rc);
                } else {
                    OH_LOG_WARN(LOG_APP, "Source Serif 4 not found in rawfile, skipping");
                }
            }

            // 4. Nerd Font Symbols (already bundled for powerline / nerd glyphs)
            if (resourceManager && !filesDir.empty()) {
                const std::string fontDir = filesDir + "/fonts";
                const std::string symbolFontPath = fontDir + "/SymbolsNerdFontMono-Regular.ttf";
                if (EnsureDirectory(fontDir) &&
                    ExtractRawFileToPath(resourceManager, "fonts/SymbolsNerdFontMono-Regular.ttf", symbolFontPath)) {
                    uint32_t rc = OH_Drawing_RegisterFont(m_fontCollection,
                        m_symbolFontFamily.c_str(), symbolFontPath.c_str());
                    OH_LOG_INFO(LOG_APP, "Registered symbol font rc=%u", rc);
                } else {
                    OH_LOG_WARN(LOG_APP, "Failed to extract bundled symbol font");
                }
            }

            s_fontsRegistered = true;
        }
    }

    if (m_primaryFontFamily.empty()) {
        m_primaryFontFamily = "Noto Sans Mono";
    }

    m_fontsConfigured = true;
    updateCellDimensions();
    return true;
}

void NativeDrawingRenderer::beginFrame()
{
    if (!m_window || !m_canvas) {
        return;
    }

    m_currentFrameId = ++g_frameCounter;

    if (m_currentFenceFd >= 0) {
        close(m_currentFenceFd);
        m_currentFenceFd = -1;
    }

    m_currentBuffer = nullptr;
    m_currentNativeBuffer = nullptr;
    m_currentPixels = nullptr;
    m_currentConfig = {};
    int fenceFd = -1;
    if (OH_NativeWindow_NativeWindowRequestBuffer(m_window, &m_currentBuffer, &fenceFd) != 0 || !m_currentBuffer) {
        OH_LOG_ERROR(LOG_APP, "RequestBuffer failed frame=%{public}" PRIu64 " window=%{public}p",
            m_currentFrameId, m_window);
        return;
    }

    // RequestBuffer returns the ACQUIRE fence: it signals when the previous
    // consumer (the Render Service) has finished reading this buffer and it is
    // safe for us to write. We render on the CPU, so we must wait for that fence
    // before drawing — otherwise we scribble into a buffer RS is still
    // compositing. Critically, we must NOT pass this acquire fence back to
    // FlushBuffer as if it were the producer's release fence: doing so makes RS
    // wait on a fence with the wrong semantics, which can stall the surface's
    // BufferQueue and starve the whole window of vsync (the "no vsync received
    // in 500ms" / WMS OnVsyncTimeOut symptom). After waiting we close it and
    // flush with no fence, since CPU writes are complete once Unmap returns.
    if (fenceFd >= 0) {
        struct pollfd pfd {};
        pfd.fd = fenceFd;
        pfd.events = POLLIN;
        // Bounded wait; if the fence never signals we proceed rather than hang.
        poll(&pfd, 1, 100);
        close(fenceFd);
    }
    m_currentFenceFd = -1;

    if (OH_NativeBuffer_FromNativeWindowBuffer(m_currentBuffer, &m_currentNativeBuffer) != 0 || !m_currentNativeBuffer) {
        OH_LOG_ERROR(LOG_APP, "FromNativeWindowBuffer failed frame=%{public}" PRIu64 " buffer=%{public}p fence=%{public}d",
            m_currentFrameId, m_currentBuffer, m_currentFenceFd);
        OH_NativeWindow_NativeWindowAbortBuffer(m_window, m_currentBuffer);
        if (m_currentFenceFd >= 0) {
            close(m_currentFenceFd);
        }
        m_currentFenceFd = -1;
        m_currentBuffer = nullptr;
        m_currentNativeBuffer = nullptr;
        return;
    }

    OH_NativeBuffer_GetConfig(m_currentNativeBuffer, &m_currentConfig);
    const uint32_t seqNum = OH_NativeBuffer_GetSeqNum(m_currentNativeBuffer);
    if (OH_NativeBuffer_Map(m_currentNativeBuffer, &m_currentPixels) != 0 || !m_currentPixels) {
        OH_LOG_ERROR(LOG_APP, "NativeBuffer map failed frame=%{public}" PRIu64 " seq=%{public}u",
            m_currentFrameId, seqNum);
        OH_NativeWindow_NativeWindowAbortBuffer(m_window, m_currentBuffer);
        if (m_currentFenceFd >= 0) {
            close(m_currentFenceFd);
        }
        m_currentFenceFd = -1;
        m_currentBuffer = nullptr;
        m_currentNativeBuffer = nullptr;
        m_currentPixels = nullptr;
        m_currentConfig = {};
        return;
    }

    OH_Drawing_Image_Info info;
    info.width = m_currentConfig.width;
    info.height = m_currentConfig.height;
    info.colorType = m_currentConfig.format == NATIVEBUFFER_PIXEL_FMT_BGRA_8888
        ? COLOR_FORMAT_BGRA_8888
        : COLOR_FORMAT_RGBA_8888;
    info.alphaType = ALPHA_FORMAT_PREMUL;

    OH_Drawing_Bitmap* bitmap = OH_Drawing_BitmapCreateFromPixels(
        &info,
        m_currentPixels,
        static_cast<uint32_t>(m_currentConfig.stride));
    if (!bitmap) {
        OH_LOG_ERROR(LOG_APP, "BitmapCreateFromPixels failed frame=%{public}" PRIu64 " seq=%{public}u stride=%{public}d",
            m_currentFrameId, seqNum, m_currentConfig.stride);
        OH_NativeBuffer_Unmap(m_currentNativeBuffer);
        OH_NativeWindow_NativeWindowAbortBuffer(m_window, m_currentBuffer);
        if (m_currentFenceFd >= 0) {
            close(m_currentFenceFd);
        }
        m_currentFenceFd = -1;
        m_currentBuffer = nullptr;
        m_currentNativeBuffer = nullptr;
        m_currentPixels = nullptr;
        m_currentConfig = {};
        return;
    }

    OH_Drawing_CanvasBind(m_canvas, bitmap);
    OH_Drawing_CanvasClear(m_canvas, m_defaultBgColor);
    OH_Drawing_BitmapDestroy(bitmap);
}

void NativeDrawingRenderer::renderGrid(const std::vector<Cell>& cells, int cols, int rows,
                                       int cursorRow, int cursorCol, bool cursorVisible)
{
    if (!m_canvas || !m_currentPixels) {
        return;
    }

    // Hold the cache lock for the entire render pass so that font-family
    // changes (setFontFamily → clearGlyphCache) cannot free typography
    // objects while the VSync thread is still painting with them.
    std::lock_guard<std::recursive_mutex> cacheLock(m_glyphCacheMutex);

    const bool drawCursor = shouldRenderCursor(cursorVisible);

    const float cellWidth = getCellWidth();
    const float cellHeight = getCellHeight();

    // For proportional fonts each cell is positioned by the actual glyph advance
    // of the preceding cells in the row. Compute these offsets once per frame.
    if (m_isProportionalFont) {
        computeRowMetrics(cells, cols, rows);
    }

    m_lastCursorRectValid = false;
    if (drawCursor && cursorRow >= 0 && cursorRow < rows && cursorCol >= 0 && cursorCol < cols) {
        m_lastCursorLeft = cellX(cursorRow, cursorCol);
        m_lastCursorTop = static_cast<float>(cursorRow) * cellHeight;
        m_lastCursorWidth = cellW(cursorRow, cursorCol, 1);
        m_lastCursorHeight = cellHeight;
        m_lastCursorRectValid = true;
    }
    std::vector<uint8_t> geometryMask(static_cast<size_t>(rows * cols), 0);

    for (int row = 0; row < rows; ++row) {
        uint32_t rowBg = m_defaultBgColor;
        bool rowBgSeen = false;
        for (int col = 0; col < cols; ++col) {
            const Cell& cell = cells[row * cols + col];
            if (cell.width == 3 || cell.width == 4) {
                continue;
            }

            const uint8_t span = cell.width == 2 ? 2 : 1;
            uint32_t fg = cell.attrs.inverse ? cell.attrs.bg : cell.attrs.fg;
            uint32_t bg = cell.attrs.inverse ? cell.attrs.fg : cell.attrs.bg;
            const bool cursorHere = drawCursor && row == cursorRow && col == cursorCol;

            if (cursorHere && m_cursorStyle == 0) {
                fg = m_cursorFgColor;
                bg = m_cursorBgColor;
            }

            const float left = cellX(row, col);
            const float top = row * cellHeight;
            const float width = cellW(row, col, span);
            CellAttributes visualAttrs = cell.attrs;
            visualAttrs.fg = fg;
            visualAttrs.bg = bg;
            visualAttrs.inverse = false;
            rowBg = bg;
            rowBgSeen = true;

            paintCellBackground(left, top, width, cellHeight, bg);

            if (paintBuiltinGlyph(cell, visualAttrs, left, top, width, cellHeight)) {
                geometryMask[static_cast<size_t>(row * cols + col)] = 1;
            }

            if (cursorHere && m_cursorStyle != 0) {
                const uint32_t cursorColor = m_cursorBgColor ? m_cursorBgColor : m_defaultFgColor;
                if (m_cursorStyle == 1) {
                    paintCursor(left, top + cellHeight - std::max(2.0f, cellHeight * 0.08f),
                                width, std::max(2.0f, cellHeight * 0.08f), cursorColor);
                } else {
                    paintCursor(left, top, std::max(2.0f, width * 0.12f), cellHeight, cursorColor);
                }
            }

            if (span == 2) {
                ++col;
            }
        }

        const float paintedWidth = m_isProportionalFont ? cellX(row, cols) : cols * cellWidth;
        if (paintedWidth < static_cast<float>(m_width)) {
            paintCellBackground(
                paintedWidth,
                row * cellHeight,
                static_cast<float>(m_width) - paintedWidth,
                cellHeight,
                rowBgSeen ? rowBg : m_defaultBgColor);
        }
    }

    for (int row = 0; row < rows; ++row) {
        int col = 0;
        while (col < cols) {
            const Cell& cell = cells[row * cols + col];
            if (cell.width == 3 || cell.width == 4) {
                ++col;
                continue;
            }
            if (geometryMask[static_cast<size_t>(row * cols + col)] != 0) {
                col += (cell.width == 2 ? 2 : 1);
                continue;
            }

            const uint8_t span = cell.width == 2 ? 2 : 1;
            CellAttributes visualAttrs = cell.attrs;
            visualAttrs.fg = cell.attrs.inverse ? cell.attrs.bg : cell.attrs.fg;
            visualAttrs.bg = cell.attrs.inverse ? cell.attrs.fg : cell.attrs.bg;
            visualAttrs.inverse = false;
            const bool cursorHere = drawCursor && row == cursorRow && col == cursorCol;
            if (cursorHere && m_cursorStyle == 0) {
                visualAttrs.fg = m_cursorFgColor;
                visualAttrs.bg = m_cursorBgColor;
            }

            const std::string firstText = cellText(cell);
            if (visualAttrs.hidden || IsBlankText(firstText)) {
                col += span;
                continue;
            }

            GlyphLayout* layout = getGlyphLayout(firstText, visualAttrs, span);
            if (layout && layout->typography) {
                const float left = cellX(row, col);
                const float top = row * cellHeight;
                const float y = top + std::max(0.0f, (cellHeight - layout->height) * 0.5f);
                // Claude Sans + CJK fallback combination tends to place CJK
                // glyphs visually lower than Latin/digit glyphs; nudge them up.
                const bool isClaudeSans = (m_primaryFontFamily.find("Claude Sans") != std::string::npos);
                const float cjkNudge = (isClaudeSans && isCJKCodepoint(cell.codepoint))
                    ? m_cjkVerticalOffset * m_density
                    : 0.0f;
                OH_Drawing_TypographyPaint(layout->typography, m_canvas, left, y + cjkNudge);
            }

            col += span;
        }
    }
}

int NativeDrawingRenderer::mapXToCol(int row, float x) const
{
    if (!m_isProportionalFont || row < 0 || row >= static_cast<int>(m_rowOffsets.size())) {
        return static_cast<int>(x / m_cellWidth);
    }
    const std::vector<float>& offsets = m_rowOffsets[row];
    if (offsets.empty()) {
        return static_cast<int>(x / m_cellWidth);
    }
    // Binary search the cell whose horizontal range contains x.
    int lo = 0;
    int hi = static_cast<int>(offsets.size()) - 2; // last valid cell index
    while (lo <= hi) {
        int mid = lo + (hi - lo) / 2;
        if (x < offsets[mid]) {
            hi = mid - 1;
        } else if (x >= offsets[mid + 1]) {
            lo = mid + 1;
        } else {
            return mid;
        }
    }
    return std::clamp(lo, 0, static_cast<int>(offsets.size()) - 2);
}

void NativeDrawingRenderer::endFrame()
{
    if (!m_window || !m_currentBuffer) {
        return;
    }

    // rectNumber=0 tells the OHOS compositor to treat the whole buffer as dirty.
    Region dirtyRegion {};
    dirtyRegion.rects = nullptr;
    dirtyRegion.rectNumber = 0;
    if (m_currentNativeBuffer) {
        OH_NativeBuffer_Unmap(m_currentNativeBuffer);
        m_currentPixels = nullptr;
    }
    const uint32_t seqNum = m_currentNativeBuffer ? OH_NativeBuffer_GetSeqNum(m_currentNativeBuffer) : 0;
    const int32_t flushRet =
        OH_NativeWindow_NativeWindowFlushBuffer(m_window, m_currentBuffer, m_currentFenceFd, dirtyRegion);
    if (flushRet != 0) {
        OH_LOG_ERROR(LOG_APP, "FlushBuffer failed frame=%{public}" PRIu64 " seq=%{public}u ret=%{public}d fence=%{public}d",
            m_currentFrameId, seqNum, flushRet, m_currentFenceFd);
        OH_NativeWindow_NativeWindowAbortBuffer(m_window, m_currentBuffer);
        if (m_currentFenceFd >= 0) {
            close(m_currentFenceFd);
        }
    }

    m_currentFenceFd = -1;
    m_currentBuffer = nullptr;
    if (m_currentNativeBuffer) {
        m_currentNativeBuffer = nullptr;
    }
    m_currentPixels = nullptr;
    m_currentConfig = {};
}

float NativeDrawingRenderer::measureAverageGlyphWidth()
{
    if (!m_fontCollection || !m_fontsConfigured) {
        return m_cellWidth;
    }

    Cell probeCell;
    probeCell.codepoint = 'M';
    probeCell.textLen = 1;
    probeCell.attrs.fg = m_defaultFgColor;

    // Use a representative sample of ASCII characters to compute an average
    // glyph advance. This makes proportional fonts usable in the terminal grid
    // by reducing the oversized gaps that occur when cell width is based on 'M'.
    const char* sample =
        "abcdefghijklmnopqrstuvwxyz"
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        "0123456789"
        "!@#$%^&*()_+-=[]{}|;':\",./<>?";
    double total = 0.0;
    int count = 0;
    for (const char* p = sample; *p != '\0'; ++p) {
        char text[2] = { *p, '\0' };
        std::memcpy(probeCell.text, text, sizeof(text));
        GlyphLayout* layout = getGlyphLayout(text, probeCell.attrs, 1);
        if (layout && layout->width > 0.0f) {
            total += layout->width;
            ++count;
        }
    }
    if (count == 0) {
        return m_cellWidth;
    }
    return static_cast<float>(total / static_cast<double>(count));
}

float NativeDrawingRenderer::effectiveFontSize() const
{
    // Claude Sans has a relatively small visual size; give it a gentle boost
    // so English text does not look tiny next to CJK glyphs or other fonts.
    if (m_primaryFontFamily.find("Claude Sans") != std::string::npos) {
        return m_fontSize * m_fontScaleBoost;
    }
    return m_fontSize;
}

bool NativeDrawingRenderer::isCJKCodepoint(uint32_t cp)
{
    return (cp >= 0x4E00 && cp <= 0x9FFF) ||   // CJK Unified Ideographs
           (cp >= 0x3400 && cp <= 0x4DBF) ||   // CJK Unified Ideographs Extension A
           (cp >= 0xF900 && cp <= 0xFAFF) ||   // CJK Compatibility Ideographs
           (cp >= 0x20000 && cp <= 0x2EBEF) || // CJK Unified Ideographs Extensions B-F
           (cp >= 0x3000 && cp <= 0x303F) ||   // CJK Symbols and Punctuation
           (cp >= 0x3040 && cp <= 0x309F) ||   // Hiragana
           (cp >= 0x30A0 && cp <= 0x30FF) ||   // Katakana
           (cp >= 0xAC00 && cp <= 0xD7AF) ||   // Hangul Syllables
           (cp >= 0xFF01 && cp <= 0xFF5E);     // Fullwidth ASCII variants
}

void NativeDrawingRenderer::updateCellDimensions()
{
    Renderer::updateCellDimensions();

    if (!m_fontCollection || !m_fontsConfigured) {
        return;
    }

    // Glyph layouts are cached by text/color/style/span but NOT by font size or
    // density, so a font-size or density change must invalidate the cache.
    // Otherwise both the probe below and every subsequent glyph would return a
    // stale layout sized for the previous font, making font-size changes a no-op.
    clearGlyphCache();

    Cell probeCell;
    probeCell.codepoint = 'M';
    const char probe[] = "M";
    std::memcpy(probeCell.text, probe, sizeof(probe));
    probeCell.textLen = 1;
    probeCell.attrs.fg = m_defaultFgColor;
    GlyphLayout* layoutM = getGlyphLayout("M", probeCell.attrs, 1);
    if (!layoutM || layoutM->width <= 0.0f || layoutM->height <= 0.0f) {
        return;
    }

    // Detect proportional fonts by comparing the widths of a narrow and a wide
    // glyph. For monospace fonts these will be identical; for proportional fonts
    // we fall back to the average glyph width so character spacing is reasonable.
    const char probeI[] = "i";
    std::memcpy(probeCell.text, probeI, sizeof(probeI));
    GlyphLayout* layoutI = getGlyphLayout("i", probeCell.attrs, 1);
    const float widthM = layoutM->width;
    const float widthI = (layoutI && layoutI->width > 0.0f) ? layoutI->width : widthM;
    const bool isMonospace = std::fabs(widthM - widthI) < 0.5f;
    m_isProportionalFont = !isMonospace;
    if (isMonospace) {
        // Drop stale proportional offsets so the fixed grid is used immediately
        // and memory is not wasted once we switch back to monospace.
        m_rowOffsets.clear();
        m_rowWidths.clear();
    }
    const float cellWidth = isMonospace ? widthM : measureAverageGlyphWidth();

    m_cellWidth = std::ceil(std::max(cellWidth, 1.0f));
    m_cellHeight = std::ceil(std::max(layoutM->height * m_lineSpacing, 1.0f));

    OH_LOG_INFO(LOG_APP,
        "FT_FONT cellSize family='%{public}s' mono=%{public}d proportional=%{public}d lineSpacing=%.2f widthM=%.2f widthI=%.2f cellW=%.2f cellH=%.2f",
        m_primaryFontFamily.c_str(), static_cast<int>(isMonospace), static_cast<int>(m_isProportionalFont),
        m_lineSpacing, widthM, widthI, m_cellWidth, m_cellHeight);
}

void NativeDrawingRenderer::computeRowMetrics(const std::vector<Cell>& cells, int cols, int rows)
{
    m_rowOffsets.assign(rows, std::vector<float>(cols + 1, 0.0f));
    m_rowWidths.assign(rows, std::vector<float>(cols, 0.0f));

    Cell probeCell;
    probeCell.textLen = 1;
    probeCell.attrs.fg = m_defaultFgColor;

    for (int row = 0; row < rows; ++row) {
        float x = 0.0f;
        for (int col = 0; col < cols; ++col) {
            m_rowOffsets[row][col] = x;
            const Cell& cell = cells[row * cols + col];
            if (cell.width == 3 || cell.width == 4) {
                // Continuation of a wide character: no advance.
                m_rowWidths[row][col] = 0.0f;
                continue;
            }
            const uint8_t span = cell.width == 2 ? 2 : 1;
            const std::string text = cellText(cell);
            float w = m_cellWidth * span;
            if (m_isProportionalFont && !text.empty() && text.find_first_not_of(' ') != std::string::npos) {
                GlyphLayout* layout = getGlyphLayout(text, probeCell.attrs, span);
                if (layout && layout->width > 0.0f) {
                    // Add a small amount of horizontal breathing room between
                    // proportional glyphs so the terminal grid does not feel
                    // cramped; leave wide (CJK) glyphs at their natural width.
                    const float extra = (span == 1) ? m_characterSpacing : 0.0f;
                    w = layout->width + extra;
                }
            }
            m_rowWidths[row][col] = w;
            x += w;
            if (span == 2) {
                // Skip the continuation cell on the next iteration; it shares this offset.
                if (col + 1 < cols) {
                    m_rowOffsets[row][col + 1] = x;
                    m_rowWidths[row][col + 1] = 0.0f;
                }
                ++col;
            }
        }
        m_rowOffsets[row][cols] = x;
    }
}

float NativeDrawingRenderer::cellX(int row, int col) const
{
    if (!m_isProportionalFont || row < 0 || row >= static_cast<int>(m_rowOffsets.size())) {
        return col * m_cellWidth;
    }
    if (col < 0 || col > static_cast<int>(m_rowOffsets[row].size()) - 1) {
        return col * m_cellWidth;
    }
    return m_rowOffsets[row][col];
}

float NativeDrawingRenderer::cellW(int row, int col, uint8_t span) const
{
    if (!m_isProportionalFont || row < 0 || row >= static_cast<int>(m_rowWidths.size()) ||
        col < 0 || col >= static_cast<int>(m_rowWidths[row].size())) {
        return m_cellWidth * span;
    }
    if (span == 1) {
        return m_rowWidths[row][col];
    }
    // For wide cells, return the measured width stored at the leading cell.
    return m_rowWidths[row][col];
}

bool NativeDrawingRenderer::configureWindow()
{
    if (!m_window) {
        return false;
    }

    if (OH_NativeWindow_NativeWindowHandleOpt(m_window, SET_BUFFER_GEOMETRY,
                                              static_cast<int32_t>(m_width),
                                              static_cast<int32_t>(m_height)) != 0) {
        OH_LOG_ERROR(LOG_APP, "SET_BUFFER_GEOMETRY failed");
        return false;
    }
    if (OH_NativeWindow_NativeWindowHandleOpt(m_window, SET_FORMAT,
                                              static_cast<int32_t>(NATIVEBUFFER_PIXEL_FMT_RGBA_8888)) != 0) {
        OH_LOG_ERROR(LOG_APP, "SET_FORMAT failed");
        return false;
    }
    if (OH_NativeWindow_NativeWindowHandleOpt(m_window, SET_USAGE, static_cast<uint64_t>(kBufferUsage)) != 0) {
        OH_LOG_ERROR(LOG_APP, "SET_USAGE failed");
        return false;
    }
    return true;
}

bool NativeDrawingRenderer::ensureDrawingObjects()
{
    if (!m_canvas) {
        m_canvas = OH_Drawing_CanvasCreate();
    }
    if (!m_brush) {
        m_brush = OH_Drawing_BrushCreate();
    }
    if (!m_rect) {
        m_rect = OH_Drawing_RectCreate(0.0f, 0.0f, 0.0f, 0.0f);
    }
    return m_canvas && m_brush && m_rect;
}

void NativeDrawingRenderer::clearGlyphCache()
{
    std::lock_guard<std::recursive_mutex> lock(m_glyphCacheMutex);
    for (auto& entry : m_glyphCache) {
        if (entry.second.typography) {
            OH_Drawing_DestroyTypography(entry.second.typography);
        }
    }
    m_glyphCache.clear();
}

void NativeDrawingRenderer::trimGlyphCache()
{
    if (m_glyphCache.size() <= kMaxGlyphCacheEntries) {
        return;
    }
    clearGlyphCache();
}

NativeDrawingRenderer::GlyphLayout* NativeDrawingRenderer::getGlyphLayout(
    const std::string& text,
    const CellAttributes& attrs,
    uint8_t span)
{
    std::lock_guard<std::recursive_mutex> lock(m_glyphCacheMutex);
    if (!m_fontCollection) {
        return nullptr;
    }

    GlyphKey key;
    key.text = text;
    key.fg = attrs.fg;
    key.styleBits = makeStyleBits(attrs);
    key.span = span;

    auto it = m_glyphCache.find(key);
    if (it != m_glyphCache.end()) {
        return &it->second;
    }

    OH_Drawing_TypographyStyle* typographyStyle = OH_Drawing_CreateTypographyStyle();
    OH_Drawing_TextStyle* textStyle = OH_Drawing_CreateTextStyle();
    if (!typographyStyle || !textStyle) {
        if (typographyStyle) {
            OH_Drawing_DestroyTypographyStyle(typographyStyle);
        }
        if (textStyle) {
            OH_Drawing_DestroyTextStyle(textStyle);
        }
        return nullptr;
    }

    OH_Drawing_SetTypographyTextDirection(typographyStyle, TEXT_DIRECTION_LTR);
    OH_Drawing_SetTypographyTextAlign(typographyStyle, TEXT_ALIGN_START);
    OH_Drawing_SetTypographyTextMaxLines(typographyStyle, 1);

    OH_Drawing_SetTextStyleColor(textStyle, attrs.fg);
    OH_Drawing_SetTextStyleFontSize(textStyle, std::max(1.0, static_cast<double>(effectiveFontSize() * m_density)));
    OH_Drawing_SetTextStyleFontWeight(textStyle, attrs.bold ? FONT_WEIGHT_700 : FONT_WEIGHT_400);
    OH_Drawing_SetTextStyleFontStyle(textStyle, attrs.italic ? FONT_STYLE_ITALIC : FONT_STYLE_NORMAL);
    OH_Drawing_SetTextStyleBaseLine(textStyle, TEXT_BASELINE_ALPHABETIC);
    if (attrs.underline) {
        OH_Drawing_AddTextStyleDecoration(textStyle, TEXT_DECORATION_UNDERLINE);
    }
    if (attrs.strikethrough) {
        OH_Drawing_AddTextStyleDecoration(textStyle, TEXT_DECORATION_LINE_THROUGH);
    }
    OH_Drawing_SetTextStyleDecorationColor(textStyle, attrs.fg);
    OH_Drawing_TextStyleAddFontFeature(textStyle, "liga", 1);
    OH_Drawing_TextStyleAddFontFeature(textStyle, "clig", 1);
    OH_Drawing_TextStyleAddFontFeature(textStyle, "calt", 1);
    const std::array<const char*, 7> fontFamilies = {
        m_primaryFontFamily.c_str(),
        m_symbolFontFamily.c_str(),
        "Noto Sans SC",
        "Source Han Sans SC",
        "HarmonyOS Sans",
        "monospace",
        "sans-serif"
    };
    // Log the active font family once per renderer instance (first glyph only).
    {
        static std::atomic<int> s_fontLogCount{0};
        if (s_fontLogCount.fetch_add(1) < 3) {
            OH_LOG_INFO(LOG_APP, "FT_FONT getGlyphLayout primary='%{public}s' symbol='%{public}s' fontSize=%.1f eff=%.1f density=%.2f",
                        m_primaryFontFamily.c_str(), m_symbolFontFamily.c_str(),
                        static_cast<double>(m_fontSize), static_cast<double>(effectiveFontSize()), static_cast<double>(m_density));
        }
    }
    const char* families[fontFamilies.size()];
    for (size_t i = 0; i < fontFamilies.size(); ++i) {
        families[i] = fontFamilies[i];
    }
    OH_Drawing_SetTextStyleFontFamilies(textStyle,
                                        static_cast<int>(fontFamilies.size()),
                                        families);
    OH_Drawing_SetTextStyleLocale(textStyle, "en-US");

    OH_Drawing_TypographyCreate* handler = OH_Drawing_CreateTypographyHandler(typographyStyle, m_fontCollection);
    if (!handler) {
        OH_Drawing_DestroyTextStyle(textStyle);
        OH_Drawing_DestroyTypographyStyle(typographyStyle);
        return nullptr;
    }

    const std::string glyph = key.text.empty() ? std::string(" ") : key.text;
    OH_Drawing_TypographyHandlerPushTextStyle(handler, textStyle);
    OH_Drawing_TypographyHandlerAddText(handler, glyph.c_str());
    OH_Drawing_TypographyHandlerPopTextStyle(handler);

    OH_Drawing_Typography* typography = OH_Drawing_CreateTypography(handler);
    OH_Drawing_DestroyTypographyHandler(handler);
    OH_Drawing_DestroyTextStyle(textStyle);
    OH_Drawing_DestroyTypographyStyle(typographyStyle);
    if (!typography) {
        return nullptr;
    }

    // OH_Drawing lays out and clips against this width. A terminal cell width
    // measured from a probe glyph is not a strict upper bound for every glyph's
    // advance/overhang, and an exact width can clip the rightmost glyph in a
    // freshly typed run. Give layout a small overhang budget while keeping the
    // paint origin snapped to the terminal cell.
    // For proportional fonts we lay out at the full viewport width so wider
    // glyphs are not clipped, since cells are positioned by their natural advance.
    const double overhang = std::max(2.0, static_cast<double>(effectiveFontSize() * m_density) * 0.25);
    const double maxWidth = m_isProportionalFont
        ? static_cast<double>(std::max(1u, m_width))
        : std::max(1.0, static_cast<double>(m_cellWidth * span) + overhang);
    OH_Drawing_TypographyLayout(typography, maxWidth);
    const size_t unresolvedCount = OH_Drawing_TypographyGetUnresolvedGlyphsCount(typography);
    if (unresolvedCount > 0) {
        const std::string preview = HexPreview(glyph);
        OH_LOG_ERROR(LOG_APP,
            "Unresolved glyphs frame=%{public}" PRIu64 " count=%{public}zu cp=0x%{public}X span=%{public}u text=%{public}s preview=%{public}s",
            m_currentFrameId,
            unresolvedCount,
            0u,
            span,
            glyph.c_str(),
            preview.c_str());
    }
    if (glyph.size() == 1 && IsSuspiciousCodepoint(static_cast<uint8_t>(glyph[0]))) {
        const std::string preview = HexPreview(glyph);
        OH_LOG_ERROR(LOG_APP,
            "Suspicious cell frame=%{public}" PRIu64 " cp=0x%{public}X span=%{public}u preview=%{public}s",
            m_currentFrameId,
            static_cast<unsigned int>(static_cast<uint8_t>(glyph[0])),
            span,
            preview.c_str());
    }

    GlyphLayout layout;
    layout.typography = typography;
    layout.width = static_cast<float>(std::max(0.0, OH_Drawing_TypographyGetLongestLine(typography)));
    layout.height = static_cast<float>(std::max(0.0, OH_Drawing_TypographyGetHeight(typography)));

    auto [inserted, _] = m_glyphCache.emplace(key, layout);
    trimGlyphCache();
    return &inserted->second;
}

void NativeDrawingRenderer::paintCellBackground(float left, float top, float width, float height, uint32_t color)
{
    OH_Drawing_BrushSetColor(m_brush, color);
    OH_Drawing_CanvasAttachBrush(m_canvas, m_brush);
    OH_Drawing_RectSetLeft(m_rect, left);
    OH_Drawing_RectSetTop(m_rect, top);
    OH_Drawing_RectSetRight(m_rect, left + width);
    OH_Drawing_RectSetBottom(m_rect, top + height);
    OH_Drawing_CanvasDrawRect(m_canvas, m_rect);
    OH_Drawing_CanvasDetachBrush(m_canvas);
}

void NativeDrawingRenderer::paintCursor(float left, float top, float width, float height, uint32_t color)
{
    paintCellBackground(left, top, width, height, color);
}

void NativeDrawingRenderer::paintBuiltinRect(float left, float top, float width, float height, uint32_t color)
{
    if (width <= 0.0f || height <= 0.0f) {
        return;
    }
    paintCellBackground(left, top, width, height, color);
}

uint32_t NativeDrawingRenderer::blendColor(uint32_t bg, uint32_t fg, uint8_t alpha)
{
    const uint32_t inv = 255 - alpha;
    const uint32_t br = (bg >> 16) & 0xFF;
    const uint32_t bgc = (bg >> 8) & 0xFF;
    const uint32_t bb = bg & 0xFF;
    const uint32_t fr = (fg >> 16) & 0xFF;
    const uint32_t fgc = (fg >> 8) & 0xFF;
    const uint32_t fb = fg & 0xFF;
    const uint32_t r = (br * inv + fr * alpha) / 255;
    const uint32_t g = (bgc * inv + fgc * alpha) / 255;
    const uint32_t b = (bb * inv + fb * alpha) / 255;
    return 0xFF000000u | (r << 16) | (g << 8) | b;
}

void NativeDrawingRenderer::paintBuiltinLineHorizontal(
    float left, float top, float width, float cellHeight, LineStyle style,
    bool upperHalf, bool lowerHalf, uint32_t color)
{
    if (style == LineStyle::None) {
        return;
    }
    const float light = std::max(1.0f, std::round(cellHeight * 0.08f));
    const float heavy = std::max(light + 1.0f, std::round(cellHeight * 0.14f));
    const float thick = style == LineStyle::Heavy ? heavy : light;
    const float centerY = top + std::floor((cellHeight - thick) * 0.5f);
    if (style == LineStyle::Double) {
        const float gap = std::max(1.0f, light);
        paintBuiltinRect(left, centerY - gap, width, light, color);
        paintBuiltinRect(left, centerY + gap, width, light, color);
        return;
    }
    if (upperHalf || lowerHalf) {
        const float lineTop = upperHalf ? centerY : (centerY + thick * 0.5f);
        const float lineHeight = upperHalf && lowerHalf ? thick : std::max(1.0f, thick * 0.5f);
        paintBuiltinRect(left, lineTop, width, lineHeight, color);
        return;
    }
    paintBuiltinRect(left, centerY, width, thick, color);
}

void NativeDrawingRenderer::paintBuiltinLineVertical(
    float left, float top, float cellWidth, float height, LineStyle style,
    bool leftHalf, bool rightHalf, uint32_t color)
{
    if (style == LineStyle::None) {
        return;
    }
    const float light = std::max(1.0f, std::round(cellWidth * 0.08f));
    const float heavy = std::max(light + 1.0f, std::round(cellWidth * 0.14f));
    const float thick = style == LineStyle::Heavy ? heavy : light;
    const float centerX = left + std::floor((cellWidth - thick) * 0.5f);
    if (style == LineStyle::Double) {
        const float gap = std::max(1.0f, light);
        paintBuiltinRect(centerX - gap, top, light, height, color);
        paintBuiltinRect(centerX + gap, top, light, height, color);
        return;
    }
    if (leftHalf || rightHalf) {
        const float lineLeft = leftHalf ? centerX : (centerX + thick * 0.5f);
        const float lineWidth = leftHalf && rightHalf ? thick : std::max(1.0f, thick * 0.5f);
        paintBuiltinRect(lineLeft, top, lineWidth, height, color);
        return;
    }
    paintBuiltinRect(centerX, top, thick, height, color);
}

void NativeDrawingRenderer::paintBuiltinDiagonal(
    float left, float top, float width, float height, bool forwardSlash, uint32_t color)
{
    const float thickness = std::max(1.0f, std::round(std::min(width, height) * 0.08f));
    const int steps = std::max(1, static_cast<int>(std::ceil(std::max(width, height))));
    for (int i = 0; i < steps; ++i) {
        const float t = steps == 1 ? 0.0f : static_cast<float>(i) / static_cast<float>(steps - 1);
        const float x = left + t * (width - thickness);
        const float y = forwardSlash
            ? top + (1.0f - t) * (height - thickness)
            : top + t * (height - thickness);
        paintBuiltinRect(x, y, thickness, thickness, color);
    }
}

NativeDrawingRenderer::BoxGlyphEdges NativeDrawingRenderer::getBoxGlyphEdges(uint32_t codepoint)
{
    using S = LineStyle;
    switch (codepoint) {
        case 0x2500: return { S::None, S::Light, S::None, S::Light };
        case 0x2501: return { S::None, S::Heavy, S::None, S::Heavy };
        case 0x2502: return { S::Light, S::None, S::Light, S::None };
        case 0x2503: return { S::Heavy, S::None, S::Heavy, S::None };
        case 0x250C: return { S::None, S::Light, S::Light, S::None };
        case 0x2510: return { S::None, S::None, S::Light, S::Light };
        case 0x2514: return { S::Light, S::Light, S::None, S::None };
        case 0x2518: return { S::Light, S::None, S::None, S::Light };
        case 0x251C: return { S::Light, S::Light, S::Light, S::None };
        case 0x2524: return { S::Light, S::None, S::Light, S::Light };
        case 0x252C: return { S::None, S::Light, S::Light, S::Light };
        case 0x2534: return { S::Light, S::Light, S::None, S::Light };
        case 0x253C: return { S::Light, S::Light, S::Light, S::Light };
        case 0x2550: return { S::None, S::Double, S::None, S::Double };
        case 0x2551: return { S::Double, S::None, S::Double, S::None };
        case 0x2554: return { S::None, S::Double, S::Double, S::None };
        case 0x2557: return { S::None, S::None, S::Double, S::Double };
        case 0x255A: return { S::Double, S::Double, S::None, S::None };
        case 0x255D: return { S::Double, S::None, S::None, S::Double };
        case 0x2560: return { S::Double, S::Double, S::Double, S::None };
        case 0x2563: return { S::Double, S::None, S::Double, S::Double };
        case 0x2566: return { S::None, S::Double, S::Double, S::Double };
        case 0x2569: return { S::Double, S::Double, S::None, S::Double };
        case 0x256C: return { S::Double, S::Double, S::Double, S::Double };
        case 0x2574: return { S::None, S::None, S::None, S::Light };
        case 0x2575: return { S::Light, S::None, S::None, S::None };
        case 0x2576: return { S::None, S::Light, S::None, S::None };
        case 0x2577: return { S::None, S::None, S::Light, S::None };
        case 0x2578: return { S::None, S::None, S::None, S::Heavy };
        case 0x2579: return { S::Heavy, S::None, S::None, S::None };
        case 0x257A: return { S::None, S::Heavy, S::None, S::None };
        case 0x257B: return { S::None, S::None, S::Heavy, S::None };
        case 0x257C: return { S::None, S::Heavy, S::None, S::Light };
        case 0x257D: return { S::Light, S::None, S::Heavy, S::None };
        case 0x257E: return { S::None, S::Light, S::None, S::Heavy };
        case 0x257F: return { S::Heavy, S::None, S::Light, S::None };
        default: return {};
    }
}

bool NativeDrawingRenderer::paintBuiltinGlyph(
    const Cell& cell,
    const CellAttributes& attrs,
    float left,
    float top,
    float width,
    float height)
{
    if (cell.selected || cell.attrs.hidden) {
        return false;
    }

    // Powerline separators/caps (Nerd Font PUA) must tile edge-to-edge with no
    // gap. Drawing them through the font typography path leaves them shifted and
    // mis-scaled because the symbol font's glyph metrics do not match the
    // terminal cell box. Render them as exact cell geometry instead.
    if (paintPowerlineGlyph(cell.codepoint, attrs, left, top, width, height)) {
        return true;
    }

    if (!IsBuiltinGeometryCodepoint(cell.codepoint)) {
        return false;
    }

    const uint32_t fg = attrs.fg;
    const uint32_t bg = attrs.bg;
    const uint32_t cp = cell.codepoint;

    if (cp >= 0x2580 && cp <= 0x259F) {
        switch (cp) {
            case 0x2580: paintBuiltinRect(left, top, width, height * 0.5f, fg); return true;
            case 0x2581: paintBuiltinRect(left, top + height * 0.875f, width, std::ceil(height * 0.125f), fg); return true;
            case 0x2582: paintBuiltinRect(left, top + height * 0.75f, width, std::ceil(height * 0.25f), fg); return true;
            case 0x2583: paintBuiltinRect(left, top + height * 0.625f, width, std::ceil(height * 0.375f), fg); return true;
            case 0x2584: paintBuiltinRect(left, top + height * 0.5f, width, std::ceil(height * 0.5f), fg); return true;
            case 0x2585: paintBuiltinRect(left, top + height * 0.375f, width, std::ceil(height * 0.625f), fg); return true;
            case 0x2586: paintBuiltinRect(left, top + height * 0.25f, width, std::ceil(height * 0.75f), fg); return true;
            case 0x2587: paintBuiltinRect(left, top + height * 0.125f, width, std::ceil(height * 0.875f), fg); return true;
            case 0x2588: paintBuiltinRect(left, top, width, height, fg); return true;
            case 0x2589: paintBuiltinRect(left, top, width * 0.875f, height, fg); return true;
            case 0x258A: paintBuiltinRect(left, top, width * 0.75f, height, fg); return true;
            case 0x258B: paintBuiltinRect(left, top, width * 0.625f, height, fg); return true;
            case 0x258C: paintBuiltinRect(left, top, width * 0.5f, height, fg); return true;
            case 0x258D: paintBuiltinRect(left, top, width * 0.375f, height, fg); return true;
            case 0x258E: paintBuiltinRect(left, top, width * 0.25f, height, fg); return true;
            case 0x258F: paintBuiltinRect(left, top, width * 0.125f, height, fg); return true;
            case 0x2590: paintBuiltinRect(left + width * 0.5f, top, width * 0.5f, height, fg); return true;
            case 0x2591: paintBuiltinRect(left, top, width, height, blendColor(bg, fg, 64)); return true;
            case 0x2592: paintBuiltinRect(left, top, width, height, blendColor(bg, fg, 128)); return true;
            case 0x2593: paintBuiltinRect(left, top, width, height, blendColor(bg, fg, 192)); return true;
            case 0x2594: paintBuiltinRect(left, top, width, std::ceil(height * 0.125f), fg); return true;
            case 0x2595: paintBuiltinRect(left + width * 0.875f, top, std::ceil(width * 0.125f), height, fg); return true;
            case 0x2596: paintBuiltinRect(left, top + height * 0.5f, width * 0.5f, height * 0.5f, fg); return true;
            case 0x2597: paintBuiltinRect(left + width * 0.5f, top + height * 0.5f, width * 0.5f, height * 0.5f, fg); return true;
            case 0x2598: paintBuiltinRect(left, top, width * 0.5f, height * 0.5f, fg); return true;
            case 0x2599:
                paintBuiltinRect(left, top, width * 0.5f, height, fg);
                paintBuiltinRect(left + width * 0.5f, top + height * 0.5f, width * 0.5f, height * 0.5f, fg);
                return true;
            case 0x259A:
                paintBuiltinRect(left, top, width * 0.5f, height * 0.5f, fg);
                paintBuiltinRect(left + width * 0.5f, top + height * 0.5f, width * 0.5f, height * 0.5f, fg);
                return true;
            case 0x259B:
                paintBuiltinRect(left, top, width, height * 0.5f, fg);
                paintBuiltinRect(left, top + height * 0.5f, width * 0.5f, height * 0.5f, fg);
                return true;
            case 0x259C:
                paintBuiltinRect(left, top, width, height * 0.5f, fg);
                paintBuiltinRect(left + width * 0.5f, top + height * 0.5f, width * 0.5f, height * 0.5f, fg);
                return true;
            case 0x259D: paintBuiltinRect(left + width * 0.5f, top, width * 0.5f, height * 0.5f, fg); return true;
            case 0x259E:
                paintBuiltinRect(left + width * 0.5f, top, width * 0.5f, height * 0.5f, fg);
                paintBuiltinRect(left, top + height * 0.5f, width * 0.5f, height * 0.5f, fg);
                return true;
            case 0x259F:
                paintBuiltinRect(left + width * 0.5f, top, width * 0.5f, height, fg);
                paintBuiltinRect(left, top + height * 0.5f, width * 0.5f, height * 0.5f, fg);
                return true;
            default:
                break;
        }
    }

    if (cp == 0x2571 || cp == 0x2572 || cp == 0x2573) {
        if (cp == 0x2571 || cp == 0x2573) {
            paintBuiltinDiagonal(left, top, width, height, true, fg);
        }
        if (cp == 0x2572 || cp == 0x2573) {
            paintBuiltinDiagonal(left, top, width, height, false, fg);
        }
        return true;
    }

    BoxGlyphEdges edges = getBoxGlyphEdges(cp);
    if (edges.up != LineStyle::None || edges.right != LineStyle::None ||
        edges.down != LineStyle::None || edges.left != LineStyle::None) {
        if (edges.left != LineStyle::None) {
            paintBuiltinLineHorizontal(left, top, width * 0.5f, height, edges.left, false, false, fg);
        }
        if (edges.right != LineStyle::None) {
            paintBuiltinLineHorizontal(left + width * 0.5f, top, width * 0.5f, height, edges.right, false, false, fg);
        }
        if (edges.up != LineStyle::None) {
            paintBuiltinLineVertical(left, top, width, height * 0.5f, edges.up, false, false, fg);
        }
        if (edges.down != LineStyle::None) {
            paintBuiltinLineVertical(left, top + height * 0.5f, width, height * 0.5f, edges.down, false, false, fg);
        }
        return true;
    }

    if (cp >= 0x2500 && cp <= 0x257F) {
        switch (cp) {
            case 0x256D:
                paintBuiltinLineHorizontal(left + width * 0.5f, top, width * 0.5f, height, LineStyle::Light, false, false, fg);
                paintBuiltinLineVertical(left, top + height * 0.5f, width, height * 0.5f, LineStyle::Light, false, false, fg);
                return true;
            case 0x256E:
                paintBuiltinLineHorizontal(left, top, width * 0.5f, height, LineStyle::Light, false, false, fg);
                paintBuiltinLineVertical(left, top + height * 0.5f, width, height * 0.5f, LineStyle::Light, false, false, fg);
                return true;
            case 0x256F:
                paintBuiltinLineHorizontal(left, top, width * 0.5f, height, LineStyle::Light, false, false, fg);
                paintBuiltinLineVertical(left, top, width, height * 0.5f, LineStyle::Light, false, false, fg);
                return true;
            case 0x2570:
                paintBuiltinLineHorizontal(left + width * 0.5f, top, width * 0.5f, height, LineStyle::Light, false, false, fg);
                paintBuiltinLineVertical(left, top, width, height * 0.5f, LineStyle::Light, false, false, fg);
                return true;
            default:
                break;
        }
    }

    return false;
}

void NativeDrawingRenderer::fillTrianglePath(
    float ax, float ay, float bx, float by, float cx, float cy, uint32_t color)
{
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (!path) {
        return;
    }
    OH_Drawing_PathMoveTo(path, ax, ay);
    OH_Drawing_PathLineTo(path, bx, by);
    OH_Drawing_PathLineTo(path, cx, cy);
    OH_Drawing_PathClose(path);

    OH_Drawing_BrushSetColor(m_brush, color);
    OH_Drawing_BrushSetAntiAlias(m_brush, true);
    OH_Drawing_CanvasAttachBrush(m_canvas, m_brush);
    OH_Drawing_CanvasDrawPath(m_canvas, path);
    OH_Drawing_CanvasDetachBrush(m_canvas);
    OH_Drawing_BrushSetAntiAlias(m_brush, false);
    OH_Drawing_PathDestroy(path);
}

void NativeDrawingRenderer::fillHalfEllipse(
    float left, float top, float width, float height, bool bulgeRight, uint32_t color)
{
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (!path) {
        return;
    }
    const float midY = top + height * 0.5f;
    if (bulgeRight) {
        // Flat edge on the left (x = left), bulge to the right (x = left+width).
        OH_Drawing_PathMoveTo(path, left, top);
        OH_Drawing_PathArcTo(path, left - width, top, left + width, top + height, -90.0f, 180.0f);
        OH_Drawing_PathLineTo(path, left, midY);
        OH_Drawing_PathClose(path);
    } else {
        // Flat edge on the right (x = left+width), bulge to the left (x = left).
        const float right = left + width;
        OH_Drawing_PathMoveTo(path, right, top + height);
        OH_Drawing_PathArcTo(path, right - width, top, right + width, top + height, 90.0f, 180.0f);
        OH_Drawing_PathLineTo(path, right, midY);
        OH_Drawing_PathClose(path);
    }

    OH_Drawing_BrushSetColor(m_brush, color);
    OH_Drawing_BrushSetAntiAlias(m_brush, true);
    OH_Drawing_CanvasAttachBrush(m_canvas, m_brush);
    OH_Drawing_CanvasDrawPath(m_canvas, path);
    OH_Drawing_CanvasDetachBrush(m_canvas);
    OH_Drawing_BrushSetAntiAlias(m_brush, false);
    OH_Drawing_PathDestroy(path);
}

void NativeDrawingRenderer::strokePolyline(
    const float* xs, const float* ys, int count, float thickness, uint32_t color)
{
    if (count < 2) {
        return;
    }
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (!path) {
        return;
    }
    OH_Drawing_PathMoveTo(path, xs[0], ys[0]);
    for (int i = 1; i < count; ++i) {
        OH_Drawing_PathLineTo(path, xs[i], ys[i]);
    }

    OH_Drawing_Pen* pen = OH_Drawing_PenCreate();
    if (!pen) {
        OH_Drawing_PathDestroy(path);
        return;
    }
    OH_Drawing_PenSetColor(pen, color);
    OH_Drawing_PenSetWidth(pen, std::max(1.0f, thickness));
    OH_Drawing_PenSetAntiAlias(pen, true);
    OH_Drawing_CanvasAttachPen(m_canvas, pen);
    OH_Drawing_CanvasDrawPath(m_canvas, path);
    OH_Drawing_CanvasDetachPen(m_canvas);
    OH_Drawing_PenDestroy(pen);
    OH_Drawing_PathDestroy(path);
}

void NativeDrawingRenderer::strokeHalfEllipse(
    float left, float top, float width, float height, bool bulgeRight, float thickness, uint32_t color)
{
    OH_Drawing_Path* path = OH_Drawing_PathCreate();
    if (!path) {
        return;
    }
    if (bulgeRight) {
        OH_Drawing_PathMoveTo(path, left, top);
        OH_Drawing_PathArcTo(path, left - width, top, left + width, top + height, -90.0f, 180.0f);
    } else {
        const float right = left + width;
        OH_Drawing_PathMoveTo(path, right, top + height);
        OH_Drawing_PathArcTo(path, right - width, top, right + width, top + height, 90.0f, 180.0f);
    }

    OH_Drawing_Pen* pen = OH_Drawing_PenCreate();
    if (!pen) {
        OH_Drawing_PathDestroy(path);
        return;
    }
    OH_Drawing_PenSetColor(pen, color);
    OH_Drawing_PenSetWidth(pen, std::max(1.0f, thickness));
    OH_Drawing_PenSetAntiAlias(pen, true);
    OH_Drawing_CanvasAttachPen(m_canvas, pen);
    OH_Drawing_CanvasDrawPath(m_canvas, path);
    OH_Drawing_CanvasDetachPen(m_canvas);
    OH_Drawing_PenDestroy(pen);
    OH_Drawing_PathDestroy(path);
}

bool NativeDrawingRenderer::paintPowerlineGlyph(
    uint32_t codepoint,
    const CellAttributes& attrs,
    float left,
    float top,
    float width,
    float height)
{
    // Powerline glyph block: triangles, half-circle caps, and diagonal
    // ("slant") separators. The cell background has already been painted with
    // the "into" segment color; here we draw the glyph with the foreground
    // color so the separator tiles seamlessly against the neighboring segment.
    if (codepoint < 0xE0B0 || codepoint > 0xE0BF) {
        return false;
    }

    const uint32_t fg = attrs.fg;
    const float l = left;
    const float r = left + width;
    const float t = top;
    const float b = top + height;
    const float midY = top + height * 0.5f;
    const float lineW = std::max(1.0f, width * 0.14f);

    switch (codepoint) {
        // Right-pointing solid triangle.
        case 0xE0B0:
            fillTrianglePath(l, t, r, midY, l, b, fg);
            return true;
        // Right-pointing hollow triangle (chevron).
        case 0xE0B1: {
            const float xs[] = {l, r, l};
            const float ys[] = {t, midY, b};
            strokePolyline(xs, ys, 3, lineW, fg);
            return true;
        }
        // Left-pointing solid triangle.
        case 0xE0B2:
            fillTrianglePath(r, t, l, midY, r, b, fg);
            return true;
        // Left-pointing hollow triangle (chevron).
        case 0xE0B3: {
            const float xs[] = {r, l, r};
            const float ys[] = {t, midY, b};
            strokePolyline(xs, ys, 3, lineW, fg);
            return true;
        }
        // Right half-circle solid cap.
        case 0xE0B4:
            fillHalfEllipse(l, t, width, height, true, fg);
            return true;
        // Right half-circle hollow cap.
        case 0xE0B5:
            strokeHalfEllipse(l, t, width, height, true, lineW, fg);
            return true;
        // Left half-circle solid cap.
        case 0xE0B6:
            fillHalfEllipse(l, t, width, height, false, fg);
            return true;
        // Left half-circle hollow cap.
        case 0xE0B7:
            strokeHalfEllipse(l, t, width, height, false, lineW, fg);
            return true;
        // Bottom-left filled triangle (diagonal).
        case 0xE0B8:
            fillTrianglePath(l, t, l, b, r, b, fg);
            return true;
        // Bottom-left hollow triangle (diagonal).
        case 0xE0B9: {
            const float xs[] = {l, r};
            const float ys[] = {t, b};
            strokePolyline(xs, ys, 2, lineW, fg);
            return true;
        }
        // Bottom-right filled triangle (diagonal).
        case 0xE0BA:
            fillTrianglePath(r, t, r, b, l, b, fg);
            return true;
        // Bottom-right hollow triangle (diagonal).
        case 0xE0BB: {
            const float xs[] = {r, l};
            const float ys[] = {t, b};
            strokePolyline(xs, ys, 2, lineW, fg);
            return true;
        }
        // Top-left filled triangle (diagonal).
        case 0xE0BC:
            fillTrianglePath(l, t, r, t, l, b, fg);
            return true;
        // Top-left hollow triangle (diagonal).
        case 0xE0BD: {
            const float xs[] = {r, l};
            const float ys[] = {t, b};
            strokePolyline(xs, ys, 2, lineW, fg);
            return true;
        }
        // Top-right filled triangle (diagonal).
        case 0xE0BE:
            fillTrianglePath(l, t, r, t, r, b, fg);
            return true;
        // Top-right hollow triangle (diagonal).
        case 0xE0BF: {
            const float xs[] = {l, r};
            const float ys[] = {t, b};
            strokePolyline(xs, ys, 2, lineW, fg);
            return true;
        }
        default:
            return false;
    }
}

uint8_t NativeDrawingRenderer::makeStyleBits(const CellAttributes& attrs)
{
    return static_cast<uint8_t>((attrs.bold ? 1 : 0) |
                                (attrs.italic ? 2 : 0) |
                                (attrs.underline ? 4 : 0) |
                                (attrs.strikethrough ? 8 : 0));
}

std::string NativeDrawingRenderer::cellText(const Cell& cell)
{
    if (cell.textLen > 0) {
        return std::string(cell.text, cell.text + cell.textLen);
    }
    if (cell.codepoint != 0) {
        return Utf8FromCodepoint(cell.codepoint);
    }
    return {};
}
