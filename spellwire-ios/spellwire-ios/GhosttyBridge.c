#include "GhosttyBridge.h"

GhosttyTerminal ghostty_bridge_terminal_create(uint16_t cols, uint16_t rows, size_t max_scrollback) {
    GhosttyTerminal terminal = NULL;
    GhosttyTerminalOptions options = {
        .cols = cols,
        .rows = rows,
        .max_scrollback = max_scrollback,
    };

    if (ghostty_terminal_new(NULL, &terminal, options) != GHOSTTY_SUCCESS) {
        return NULL;
    }

    return terminal;
}

GhosttyResult ghostty_bridge_terminal_set_userdata(GhosttyTerminal terminal, void *userdata) {
    return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdata);
}

GhosttyResult ghostty_bridge_terminal_set_write_pty(GhosttyTerminal terminal, GhosttyTerminalWritePtyFn callback) {
    return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, callback);
}

GhosttyRenderState ghostty_bridge_render_state_create(void) {
    GhosttyRenderState state = NULL;
    if (ghostty_render_state_new(NULL, &state) != GHOSTTY_SUCCESS) {
        return NULL;
    }

    return state;
}

GhosttyRenderStateRowIterator ghostty_bridge_row_iterator_create(void) {
    GhosttyRenderStateRowIterator iterator = NULL;
    if (ghostty_render_state_row_iterator_new(NULL, &iterator) != GHOSTTY_SUCCESS) {
        return NULL;
    }

    return iterator;
}

GhosttyRenderStateRowCells ghostty_bridge_row_cells_create(void) {
    GhosttyRenderStateRowCells cells = NULL;
    if (ghostty_render_state_row_cells_new(NULL, &cells) != GHOSTTY_SUCCESS) {
        return NULL;
    }

    return cells;
}

GhosttyResult ghostty_bridge_render_state_colors(GhosttyRenderState state, GhosttyRenderStateColors *colors) {
    colors->size = sizeof(GhosttyRenderStateColors);
    return ghostty_render_state_colors_get(state, colors);
}

void ghostty_bridge_terminal_set_colors(GhosttyTerminal terminal, GhosttyColorRgb background, GhosttyColorRgb foreground, GhosttyColorRgb cursor) {
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor);
}

void ghostty_bridge_terminal_scroll_delta(GhosttyTerminal terminal, intptr_t delta) {
    GhosttyTerminalScrollViewport viewport = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_DELTA,
    };
    viewport.value.delta = delta;
    ghostty_terminal_scroll_viewport(terminal, viewport);
}

void ghostty_bridge_terminal_scroll_bottom(GhosttyTerminal terminal) {
    GhosttyTerminalScrollViewport viewport = {
        .tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM,
    };
    ghostty_terminal_scroll_viewport(terminal, viewport);
}
