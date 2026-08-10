#pragma once

#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>
#include <functional>
#include <memory>
#include "terminal_state.h"  // For Cell struct
#include "theme.h"
#include "../include/ghostty_vt.h"

class Renderer;

struct TerminalSearchStatus {
    bool active = false;
    size_t total = 0;
    int selected = -1;
    std::string query;
};

class Terminal {
public:
    Terminal(int cols, int rows, int maxScrollback = 10000);
    ~Terminal();

    bool start();
    void stop();

    void resize(int cols, int rows);
    void writeInput(const char* data, size_t len);
    void feedOutput(const char* data, size_t len);

    std::string getScreenContent() const;
    void getCursorPosition(int& row, int& col) const;
    std::string getLinkAt(int row, int col) const;

    // Scrollback
    void scrollView(int delta);
    // Mouse-wheel scroll that is alternate-screen aware: on the primary screen it
    // scrolls the viewport; on the alternate screen (full-screen TUIs like vim,
    // less, claude code) it translates the wheel into cursor up/down keys so the
    // running application scrolls its own content. col/row (1-based) carry the
    // pointer cell position so that mouse-tracking-aware TUIs (opencode, vim, …)
    // can route wheel events to the correct pane.
    void wheelScroll(int lines, int col = 1, int row = 1);
    // True when wheel events are forwarded to the running application (alternate
    // screen active). On the primary screen wheel scrolls the local viewport and
    // must stay immediate; on the alt screen the wheel produces network output,
    // so the caller may coalesce multiple axis events into one round-trip.
    bool shouldForwardWheel();
    void resetViewScroll();
    // Report a mouse event to the terminal application when mouse tracking is
    // active (DEC private modes 1000/1002/1003). col/row are 1-based cell
    // coordinates. button: 0=left, 1=middle, 2=right, 3=release, 35=move-no-btn.
    // pressed: true for press/move/wheel, false for release. Returns true if the
    // event was forwarded to the app (mouse tracking active on alt screen).
    bool reportMouse(int col, int row, int button, bool pressed);
    // Clear mouse tracking modes (DEC private 1000/1002/1003/1006) using the
    // ghostty mode API.  This is called after a replay completes so that stale
    // modes from a TUI app don't cause mouse events to be forwarded as escape
    // sequences to a non-TUI session.
    // Unlike feeding CSI sequences through vt_write, this directly updates the
    // terminal's mode table, ensuring GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING
    // returns false — the same flag checked by reportMouse() / wheelScroll().
    void clearMouseTracking();
    // Full RIS reset of the emulator. Used when (re)connecting to a fresh
    // server session so stale modes (mouse tracking, alt screen, …) from the
    // previous session don't leak — e.g. wheel events being reported as SGR
    // mouse sequences to a plain shell prompt.
    void resetState();
    int getScrollbackSize() const;

    // Selection
    bool hasSelection() const;
    bool isAlternateScreen() const;
    bool isSelectionAt(int row, int col) const;
    void startSelection(int row, int col);
    void updateSelection(int row, int col);
    void extendSelection(int dRow, int dCol);
    void selectWordAt(int row, int col);
    void selectLineAt(int row);
    void clearSelection();
    std::string getSelectedText() const;
    // Count visible characters (non-empty, non-spacer cells) in the active
    // selection. If excludeEnd is true, the cell at the normalized end bound
    // is excluded (used for Backspace which deletes left of cursor). Returns
    // 0 for multi-row selections or when no selection is active.
    size_t getSelectionCharCount(bool excludeEnd) const;
    int getViewportTopRow() const;
    // Returns true if the given viewport-relative cursor position is at the
    // start / end of the active selection. Used to decide whether Backspace or
    // Delete can safely erase the selected text (as opposed to the selection
    // being in remote output far from the cursor).
    bool isCursorAtSelectionStart(int viewportRow, int viewportCol) const;
    bool isCursorAtSelectionEnd(int viewportRow, int viewportCol) const;

    // Search
    void startSearch(const std::string& query = std::string());
    void searchSelection();
    void updateSearch(const std::string& query);
    void navigateSearch(bool next);
    void endSearch();
    TerminalSearchStatus getSearchStatus() const;

    int getCols() const { return m_cols; }
    int getRows() const { return m_rows; }

    void setRenderer(Renderer* renderer) { m_renderer = renderer; }
    void setMaxScrollback(int lines);
    void setTheme(const TerminalTheme& theme);
    const TerminalTheme& getTheme() const;

    void setInputCallback(std::function<void(const std::string&)> callback) {
        m_inputCallback = callback;
    }
    void setRenderRequestCallback(std::function<void()> callback) {
        m_renderRequestCallback = callback;
    }
    void drawFrame();
    // Returns the current live background color (ARGB) from the render state.
    // This reflects OSC changes, unlike the theme default.
    uint32_t getCurrentBgColor() const;

private:
    void notifyRenderNeeded();
    void applyThemeLocked();
    void configureCallbacksLocked();
    void emitInput(const char* data, size_t len);
    void emitInput(const std::string& data);
    static bool IsSelectionBefore(int rowA, int colA, int rowB, int colB);
    static void HandleWritePty(ghostty_terminal_t terminal, void* userdata, const uint8_t* data, size_t len);
    static void HandleBell(ghostty_terminal_t terminal, void* userdata);
    static ghostty_string_t HandleEnquiry(ghostty_terminal_t terminal, void* userdata);
    static ghostty_string_t HandleXtversion(ghostty_terminal_t terminal, void* userdata);
    static void HandleTitleChanged(ghostty_terminal_t terminal, void* userdata);
    static bool HandleSize(ghostty_terminal_t terminal, void* userdata, ghostty_size_report_size_t* out_size);
    static bool HandleColorScheme(ghostty_terminal_t terminal, void* userdata, ghostty_color_scheme_t* out_scheme);
    static bool HandleDeviceAttributes(ghostty_terminal_t terminal, void* userdata, ghostty_device_attributes_t* out_attrs);
    void normalizeSelectionBounds(int& startRow, int& startCol, int& endRow, int& endCol) const;
    ghostty_terminal_scrollbar_t getScrollbarLocked() const;
    void scrollViewportLocked(ghostty_terminal_scroll_viewport_tag_t tag, int64_t delta = 0);
    int64_t determineScrollStepTowardsBottomLocked();
    std::vector<std::string> captureScrollbackSnapshotLocked(size_t& viewportTopRow);
    void rebuildSearchMatchesLocked();
    void syncSearchSelectionToViewportLocked();
    size_t getViewportTopRowLocked() const;

    int m_cols;
    int m_rows;

    std::atomic<bool> m_running;

    ghostty_terminal_t m_vt;
    ghostty_render_state_t m_renderState;
    ghostty_row_iterator_t m_rowIterator;
    ghostty_row_cells_t m_rowCells;
    TerminalTheme m_theme;
    mutable std::mutex m_stateMutex;

    // Reused drawFrame cell buffer (only accessed under m_stateMutex on the
    // render thread); avoids a multi-MB allocation per frame.
    std::vector<Cell> m_frameCells;

    Renderer* m_renderer;
    std::function<void(const std::string&)> m_inputCallback;
    std::function<void()> m_renderRequestCallback;
    bool m_selectionActive = false;
    int m_selStartRow = 0;
    int m_selStartCol = 0;
    int m_selEndRow = 0;
    int m_selEndCol = 0;
    int m_maxScrollback = 10000;

    struct SearchMatch {
        size_t row = 0;
        size_t startByte = 0;
        size_t endByte = 0;
    };

    bool m_searchActive = false;
    std::string m_searchQuery;
    std::vector<SearchMatch> m_searchMatches;
    size_t m_searchViewportTopRow = 0;
    int m_searchSelectedIndex = -1;
};
