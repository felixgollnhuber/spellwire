#ifndef GhosttyBridge_h
#define GhosttyBridge_h

#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt.h>

GhosttyTerminal ghostty_bridge_terminal_create(uint16_t cols, uint16_t rows, size_t max_scrollback);
GhosttyResult ghostty_bridge_terminal_set_userdata(GhosttyTerminal terminal, void *userdata);
GhosttyResult ghostty_bridge_terminal_set_write_pty(GhosttyTerminal terminal, GhosttyTerminalWritePtyFn callback);
GhosttyRenderState ghostty_bridge_render_state_create(void);
GhosttyRenderStateRowIterator ghostty_bridge_row_iterator_create(void);
GhosttyRenderStateRowCells ghostty_bridge_row_cells_create(void);
GhosttyResult ghostty_bridge_render_state_colors(GhosttyRenderState state, GhosttyRenderStateColors *colors);
void ghostty_bridge_terminal_set_colors(GhosttyTerminal terminal, GhosttyColorRgb background, GhosttyColorRgb foreground, GhosttyColorRgb cursor);
void ghostty_bridge_terminal_scroll_delta(GhosttyTerminal terminal, intptr_t delta);
void ghostty_bridge_terminal_scroll_bottom(GhosttyTerminal terminal);
bool ghostty_bridge_terminal_mouse_tracking_enabled(GhosttyTerminal terminal);
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
);

#endif /* GhosttyBridge_h */
