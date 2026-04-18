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

bool ghostty_bridge_terminal_mouse_tracking_enabled(GhosttyTerminal terminal) {
    bool enabled = false;
    return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &enabled) == GHOSTTY_SUCCESS && enabled;
}

size_t ghostty_bridge_terminal_encode_mouse_scroll(
    GhosttyTerminal terminal,
    float x,
    float y,
    int direction,
    uint32_t screen_width,
    uint32_t screen_height,
    uint32_t cell_width,
    uint32_t cell_height,
    uint8_t *buffer,
    size_t buffer_size
) {
    if (terminal == NULL || buffer == NULL || buffer_size == 0 || direction == 0) {
        return 0;
    }

    GhosttyMouseEncoder encoder = NULL;
    GhosttyMouseEvent event = NULL;
    size_t written = 0;

    if (ghostty_mouse_encoder_new(NULL, &encoder) != GHOSTTY_SUCCESS || encoder == NULL) {
        return 0;
    }

    ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal);

    GhosttyMouseEncoderSize size = {
        .size = sizeof(GhosttyMouseEncoderSize),
        .screen_width = screen_width,
        .screen_height = screen_height,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .padding_top = 0,
        .padding_bottom = 0,
        .padding_right = 0,
        .padding_left = 0,
    };
    ghostty_mouse_encoder_setopt(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);

    if (ghostty_mouse_event_new(NULL, &event) != GHOSTTY_SUCCESS || event == NULL) {
        ghostty_mouse_encoder_free(encoder);
        return 0;
    }

    ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS);
    ghostty_mouse_event_set_button(
        event,
        direction < 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
    );
    ghostty_mouse_event_set_position(event, (GhosttyMousePosition){ .x = x, .y = y });

    if (ghostty_mouse_encoder_encode(encoder, event, (char *)buffer, buffer_size, &written) != GHOSTTY_SUCCESS) {
        written = 0;
    }

    ghostty_mouse_event_free(event);
    ghostty_mouse_encoder_free(encoder);
    return written;
}
