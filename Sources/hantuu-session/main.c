// hantuu-session keeps a coding agent's terminal alive when hantuu quits or crashes.
//
// It's a small session holder in the spirit of dtach and abduco, written from scratch for
// hantuu (MIT). One server process per chat owns a pseudo-terminal with the agent in it and
// listens on a Unix socket. hantuu's Ghostty surface runs a client that puts its own terminal
// in raw mode and relays bytes both ways. When the app goes away, the client dies with its
// terminal and the server carries on in its own session. The next client to attach gets a
// replay of recent output, with the terminal modes the agent had set, and a resize nudge so
// the agent redraws.
//
//   hantuu-session attach --socket-dir DIR --id ID [--create --cwd DIR -- COMMAND...]
//   hantuu-session create --socket-dir DIR --id ID --cwd DIR [--size ROWSxCOLS] -- COMMAND...
//   hantuu-session list   --socket-dir DIR [--json]
//   hantuu-session kill   --socket-dir DIR --id ID
//   hantuu-session debug-replay [--ring BYTES] [--first]    reads stdin, prints what a
//                                                            reattaching client would get
//
// The client never interprets keys (there is no detach key), so every byte reaches the agent.
// The agent gets the client's environment, because the server is forked from the client.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <util.h>

#define VERSION "1.0"
#define PROTO 1

enum {
    MSG_HELLO = 1,      // client -> server: u16 proto, rows, cols, xpixel, ypixel
    MSG_INPUT = 2,      // client -> server: bytes for the agent
    MSG_WINCH = 3,      // client -> server: u16 rows, cols, xpixel, ypixel
    MSG_INFO = 4,       // client -> server: asks for MSG_INFO_REPLY
    MSG_KILL = 5,       // client -> server: stop the agent, answer with MSG_EXIT
    MSG_OUTPUT = 6,     // server -> client: bytes from the agent
    MSG_EXIT = 7,       // server -> client: i32 exit status, then the server is gone
    MSG_KICKED = 8,     // server -> client: another client attached
    MSG_INFO_REPLY = 9, // server -> client: one JSON object
};

#define FRAME_HDR 5
#define FRAME_MAX (64 * 1024)
#define RING_DEFAULT (1024 * 1024)
#define CLIENT_HIGH_WATER (4 * 1024 * 1024)
#define PTY_QUEUE_MAX (1024 * 1024)
#define MAX_CONNS 8
#define SEQ_MAX 4096

static void complain(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void complain(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("hantuu-session: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void set_nonblock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK); }
static void set_cloexec(int fd) { fcntl(fd, F_SETFD, FD_CLOEXEC); }

// MARK: Byte buffers

typedef struct {
    unsigned char *p;
    size_t off, len, cap; // valid bytes are p[off..len)
} buf_t;

static size_t buf_pending(const buf_t *b) { return b->len - b->off; }

static void buf_append(buf_t *b, const void *d, size_t n) {
    if (n == 0) return;
    if (b->off > 0 && (b->off == b->len || b->off > 65536)) {
        memmove(b->p, b->p + b->off, b->len - b->off);
        b->len -= b->off;
        b->off = 0;
    }
    if (b->len + n > b->cap) {
        size_t nc = b->cap ? b->cap : 4096;
        while (nc < b->len + n) nc *= 2;
        unsigned char *np = realloc(b->p, nc);
        if (!np) abort();
        b->p = np;
        b->cap = nc;
    }
    memcpy(b->p + b->len, d, n);
    b->len += n;
}

static void buf_str(buf_t *b, const char *s) { buf_append(b, s, strlen(s)); }

static void buf_consume(buf_t *b, size_t n) {
    b->off += n;
    if (b->off >= b->len) b->off = b->len = 0;
}

static void buf_free(buf_t *b) {
    free(b->p);
    memset(b, 0, sizeof *b);
}

static void put_u16(unsigned char *p, unsigned v) { p[0] = (unsigned char)(v >> 8); p[1] = (unsigned char)v; }
static unsigned get_u16(const unsigned char *p) { return ((unsigned)p[0] << 8) | p[1]; }
static void put_u32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16); p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v;
}
static uint32_t get_u32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static void frame_append(buf_t *b, int type, const void *d, size_t n) {
    const unsigned char *src = d;
    do {
        size_t chunk = n > FRAME_MAX ? FRAME_MAX : n;
        unsigned char hdr[FRAME_HDR];
        hdr[0] = (unsigned char)type;
        put_u32(hdr + 1, (uint32_t)chunk);
        buf_append(b, hdr, FRAME_HDR);
        buf_append(b, src, chunk);
        src += chunk;
        n -= chunk;
    } while (n > 0);
}

static void ws_put(unsigned char *p, const struct winsize *ws) {
    put_u16(p, ws->ws_row); put_u16(p + 2, ws->ws_col); put_u16(p + 4, ws->ws_xpixel); put_u16(p + 6, ws->ws_ypixel);
}
static void ws_get(const unsigned char *p, struct winsize *ws) {
    ws->ws_row = (unsigned short)get_u16(p); ws->ws_col = (unsigned short)get_u16(p + 2);
    ws->ws_xpixel = (unsigned short)get_u16(p + 4); ws->ws_ypixel = (unsigned short)get_u16(p + 6);
}

static bool write_all(int fd, const void *d, size_t n) {
    const unsigned char *p = d;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN) {
                struct pollfd pf = {fd, POLLOUT, 0};
                poll(&pf, 1, 1000);
                continue;
            }
            return false;
        }
        p += w;
        n -= (size_t)w;
    }
    return true;
}

static void json_str(buf_t *b, const char *s) {
    buf_str(b, "\"");
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') {
            char t[2] = {'\\', (char)c};
            buf_append(b, t, 2);
        } else if (c < 0x20) {
            char t[8];
            snprintf(t, sizeof t, "\\u%04x", c);
            buf_append(b, t, 6);
        } else {
            buf_append(b, &c, 1);
        }
    }
    buf_str(b, "\"");
}

// MARK: Terminal output parsing
//
// A small tokenizer for what the agent writes: plain text, BEL, ESC sequences, CSI, OSC and
// the string sequences (DCS, APC, PM, SOS). Two things use it. A tracker follows the modes the
// agent sets (alternate screen, bracketed paste, keyboard protocols, title) for output that has
// already fallen out of the replay buffer. A sanitizer drops queries, bells and notifications
// from a replay, so a reattached terminal doesn't answer old questions into the agent's input
// or raise old alerts.

enum { VS_GROUND, VS_ESC, VS_ESC_INTER, VS_CSI, VS_OSC, VS_OSC_ESC, VS_STR, VS_STR_ESC };
enum { TK_TEXT, TK_BEL, TK_ESC, TK_CSI, TK_OSC, TK_STR };

typedef struct {
    int state;
    unsigned char seq[SEQ_MAX];
    size_t len;
    bool overflow;
} vt_t;

typedef void (*vt_cb)(void *ctx, int kind, const unsigned char *raw, size_t n, bool overflow);

static void vt_push(vt_t *v, unsigned char c) {
    if (v->len < SEQ_MAX) v->seq[v->len++] = c;
    else v->overflow = true;
}

static void vt_emit(vt_t *v, int kind, vt_cb cb, void *ctx) {
    cb(ctx, kind, v->seq, v->len, v->overflow);
    v->len = 0;
    v->overflow = false;
    v->state = VS_GROUND;
}

static void vt_feed(vt_t *v, const unsigned char *d, size_t n, vt_cb cb, void *ctx) {
    size_t text_start = 0;
    bool in_text = false;
#define FLUSH_TEXT(end) do { if (in_text) { cb(ctx, TK_TEXT, d + text_start, (end) - text_start, false); in_text = false; } } while (0)
    for (size_t i = 0; i < n; i++) {
        unsigned char c = d[i];
        switch (v->state) {
        case VS_GROUND:
            if (c == 0x1b) {
                FLUSH_TEXT(i);
                v->len = 0;
                v->overflow = false;
                vt_push(v, c);
                v->state = VS_ESC;
            } else if (c == 0x07) {
                FLUSH_TEXT(i);
                cb(ctx, TK_BEL, d + i, 1, false);
            } else if (!in_text) {
                in_text = true;
                text_start = i;
            }
            break;
        case VS_ESC:
            vt_push(v, c);
            if (c == '[') v->state = VS_CSI;
            else if (c == ']') v->state = VS_OSC;
            else if (c == 'P' || c == '_' || c == '^' || c == 'X') v->state = VS_STR;
            else if (c >= 0x20 && c <= 0x2f) v->state = VS_ESC_INTER;
            else if (c == 0x1b) { v->len = 0; vt_push(v, c); }
            else vt_emit(v, TK_ESC, cb, ctx);
            break;
        case VS_ESC_INTER:
            vt_push(v, c);
            if (c < 0x20 || c > 0x2f) vt_emit(v, TK_ESC, cb, ctx);
            break;
        case VS_CSI:
            vt_push(v, c);
            if (c >= 0x40 && c <= 0x7e) vt_emit(v, TK_CSI, cb, ctx);
            else if (c == 0x18 || c == 0x1a) vt_emit(v, TK_TEXT, cb, ctx); // CAN/SUB cancel it
            break;
        case VS_OSC:
            vt_push(v, c);
            if (c == 0x07) vt_emit(v, TK_OSC, cb, ctx);
            else if (c == 0x1b) v->state = VS_OSC_ESC;
            else if (c == 0x18 || c == 0x1a) vt_emit(v, TK_TEXT, cb, ctx);
            break;
        case VS_OSC_ESC:
            vt_push(v, c);
            vt_emit(v, TK_OSC, cb, ctx); // ESC \ ends it; anything else ends it too
            break;
        case VS_STR:
            vt_push(v, c);
            if (c == 0x1b) v->state = VS_STR_ESC;
            else if (c == 0x18 || c == 0x1a) vt_emit(v, TK_TEXT, cb, ctx);
            break;
        case VS_STR_ESC:
            vt_push(v, c);
            if (c == '\\') vt_emit(v, TK_STR, cb, ctx);
            else if (c != 0x1b) v->state = VS_STR;
            break;
        }
    }
    FLUSH_TEXT(n);
#undef FLUSH_TEXT
}

typedef struct {
    char marker; // one of < = > ? or 0
    int p[16];   // -1 means the parameter was left out
    int np;
    char inter;
    char final;
} csi_t;

static void csi_parse(const unsigned char *s, size_t n, csi_t *c) {
    memset(c, 0, sizeof *c);
    if (n < 3) return;
    size_t i = 2;
    if (s[i] == '<' || s[i] == '=' || s[i] == '>' || s[i] == '?') c->marker = (char)s[i++];
    int cur = -1;
    bool any = false;
    for (; i < n - 1; i++) {
        unsigned char ch = s[i];
        if (ch >= '0' && ch <= '9') {
            cur = (cur < 0 ? 0 : cur) * 10 + (ch - '0');
            if (cur > 1000000) cur = 1000000;
            any = true;
        } else if (ch == ';' || ch == ':') {
            if (c->np < 16) c->p[c->np++] = cur;
            cur = -1;
            any = true;
        } else if (ch >= 0x20 && ch <= 0x2f) {
            c->inter = (char)ch;
        }
    }
    if (any && c->np < 16) c->p[c->np++] = cur;
    c->final = (char)s[n - 1];
}

// The parts of an OSC: its number and its payload without the terminator.
static void osc_parse(const unsigned char *raw, size_t n, int *num, const unsigned char **pl, size_t *pln) {
    size_t i = 2;
    int v = -1;
    while (i < n && raw[i] >= '0' && raw[i] <= '9') {
        v = (v < 0 ? 0 : v) * 10 + (raw[i] - '0');
        if (v > 1000000) v = 1000000;
        i++;
    }
    size_t end = n;
    if (end > 0 && raw[end - 1] == 0x07) end--;
    else if (end >= 2 && raw[end - 2] == 0x1b) end -= 2;
    if (i < end && raw[i] == ';') i++;
    *num = v;
    *pl = raw + i;
    *pln = end > i ? end - i : 0;
}

static const int tracked_modes[] = {1, 25, 47, 1047, 1049, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 2004};
#define NMODES ((int)(sizeof tracked_modes / sizeof tracked_modes[0]))

typedef struct {
    vt_t vt;
    bool mode[NMODES];
    bool keypad;
    int kitty[16];
    int nkitty;
    int modify_other_keys; // -1 when never set
    char title[1024];
    bool has_title;
} term_state_t;

static int mode_index(int m) {
    for (int i = 0; i < NMODES; i++)
        if (tracked_modes[i] == m) return i;
    return -1;
}

static void ts_reset_modes(term_state_t *t) {
    for (int i = 0; i < NMODES; i++) t->mode[i] = tracked_modes[i] == 25;
    t->keypad = false;
    t->nkitty = 0;
    t->modify_other_keys = -1;
}

static void ts_init(term_state_t *t) {
    memset(t, 0, sizeof *t);
    ts_reset_modes(t);
}

static void ts_token(void *ctx, int kind, const unsigned char *raw, size_t n, bool overflow) {
    term_state_t *t = ctx;
    if (overflow) return;
    if (kind == TK_CSI) {
        csi_t c;
        csi_parse(raw, n, &c);
        if (c.marker == '?' && !c.inter && (c.final == 'h' || c.final == 'l')) {
            for (int i = 0; i < c.np; i++) {
                int idx = mode_index(c.p[i]);
                if (idx >= 0) t->mode[idx] = c.final == 'h';
            }
        } else if (c.marker == '>' && c.final == 'u') {
            if (t->nkitty == 16) {
                memmove(t->kitty, t->kitty + 1, sizeof(int) * 15);
                t->nkitty--;
            }
            t->kitty[t->nkitty++] = c.np && c.p[0] > 0 ? c.p[0] : 0;
        } else if (c.marker == '<' && c.final == 'u') {
            int k = c.np && c.p[0] > 0 ? c.p[0] : 1;
            t->nkitty = t->nkitty > k ? t->nkitty - k : 0;
        } else if (c.marker == '=' && c.final == 'u') {
            int flags = c.np && c.p[0] > 0 ? c.p[0] : 0;
            int how = c.np > 1 && c.p[1] > 0 ? c.p[1] : 1;
            if (t->nkitty == 0) { t->kitty[0] = 0; t->nkitty = 1; }
            int *top = &t->kitty[t->nkitty - 1];
            if (how == 1) *top = flags;
            else if (how == 2) *top |= flags;
            else if (how == 3) *top &= ~flags;
        } else if (c.marker == '>' && c.final == 'm' && c.np >= 1 && c.p[0] == 4) {
            t->modify_other_keys = c.np >= 2 && c.p[1] >= 0 ? c.p[1] : -1;
        } else if (!c.marker && c.inter == '!' && c.final == 'p') {
            // DECSTR soft reset: cursor keys and keypad back to normal, cursor shown.
            t->mode[mode_index(1)] = false;
            t->mode[mode_index(25)] = true;
            t->keypad = false;
        }
    } else if (kind == TK_ESC && n == 2) {
        if (raw[1] == '=') t->keypad = true;
        else if (raw[1] == '>') t->keypad = false;
        else if (raw[1] == 'c') ts_reset_modes(t);
    } else if (kind == TK_OSC) {
        int num;
        const unsigned char *pl;
        size_t pln;
        osc_parse(raw, n, &num, &pl, &pln);
        if (num == 0 || num == 2) {
            if (pln >= sizeof t->title) pln = sizeof t->title - 1;
            memcpy(t->title, pl, pln);
            t->title[pln] = 0;
            t->has_title = true;
        }
    }
}

// Escape sequences that put a terminal back the way the agent had set it.
static void ts_prefix(const term_state_t *t, buf_t *out) {
    char tmp[64];
    if (t->mode[mode_index(1049)]) buf_str(out, "\033[?1049h");
    else if (t->mode[mode_index(1047)]) buf_str(out, "\033[?1047h");
    else if (t->mode[mode_index(47)]) buf_str(out, "\033[?47h");
    for (int i = 0; i < NMODES; i++) {
        int m = tracked_modes[i];
        if (m == 47 || m == 1047 || m == 1049) continue;
        bool def = m == 25;
        if (t->mode[i] != def) {
            snprintf(tmp, sizeof tmp, "\033[?%d%c", m, t->mode[i] ? 'h' : 'l');
            buf_str(out, tmp);
        }
    }
    if (t->keypad) buf_str(out, "\033=");
    for (int i = 0; i < t->nkitty; i++) {
        snprintf(tmp, sizeof tmp, "\033[>%du", t->kitty[i]);
        buf_str(out, tmp);
    }
    if (t->modify_other_keys >= 0) {
        snprintf(tmp, sizeof tmp, "\033[>4;%dm", t->modify_other_keys);
        buf_str(out, tmp);
    }
    if (t->has_title) {
        buf_str(out, "\033]2;");
        buf_str(out, t->title);
        buf_str(out, "\007");
    }
}

static bool csi_is_query(const csi_t *c) {
    switch (c->final) {
    case 'c': return true;                                   // DA1, DA2, DA3
    case 'n': return c->marker == 0 || c->marker == '?';     // DSR, cursor position, colour scheme
    case 'p': return c->inter == '$';                        // DECRQM
    case 'q': return c->marker == '>';                       // XTVERSION
    case 'u': return c->marker == '?';                       // kitty keyboard flags
    case 'x': return c->marker == 0 && c->inter == 0;        // DECREQTPARM
    case 't': {                                              // window and font size reports
        int p0 = c->np ? c->p[0] : -1;
        return p0 == 11 || p0 == 13 || p0 == 14 || p0 == 15 || p0 == 16 || p0 == 18 || p0 == 19 || p0 == 20 || p0 == 21;
    }
    default: return false;
    }
}

static void san_token(void *ctx, int kind, const unsigned char *raw, size_t n, bool overflow) {
    buf_t *out = ctx;
    if (overflow) return; // huge OSC 52 or image payloads: not worth replaying
    switch (kind) {
    case TK_BEL: return;
    case TK_STR: return; // DCS, APC, PM, SOS: terminfo and DECRQSS queries, images
    case TK_ESC:
        if (n == 2 && raw[1] == 'Z') return; // DECID
        break;
    case TK_CSI: {
        csi_t c;
        csi_parse(raw, n, &c);
        if (csi_is_query(&c)) return;
        break;
    }
    case TK_OSC: {
        int num;
        const unsigned char *pl;
        size_t pln;
        osc_parse(raw, n, &num, &pl, &pln);
        if (num == 9 || num == 99 || num == 777 || num == 1337) return; // notifications, progress
        if ((pln == 1 && pl[0] == '?') || (pln >= 2 && pl[pln - 2] == ';' && pl[pln - 1] == '?')) return; // colour and clipboard queries
        break;
    }
    default: break;
    }
    buf_append(out, raw, n);
}

// MARK: Replay buffer
//
// The most recent output, up to `cap` bytes. Output that falls out goes through a tracker,
// so the modes it set are still known. Eviction stops just after a newline when it can, so a
// replay starts at the beginning of a line rather than in the middle of an escape sequence.

typedef struct {
    unsigned char *p;
    size_t len, cap;
    term_state_t base;
} ring_t;

static void ring_init(ring_t *r, size_t cap) {
    memset(r, 0, sizeof *r);
    r->cap = cap < 4096 ? 4096 : cap;
    r->p = malloc(r->cap);
    if (!r->p) abort();
    ts_init(&r->base);
}

static void ring_evict(ring_t *r, size_t ev) {
    if (ev > r->len) ev = r->len;
    size_t lim = ev + 65536 < r->len ? ev + 65536 : r->len;
    if (ev < lim) {
        unsigned char *nl = memchr(r->p + ev, '\n', lim - ev);
        if (nl) ev = (size_t)(nl - r->p) + 1;
    }
    vt_feed(&r->base.vt, r->p, ev, ts_token, &r->base);
    memmove(r->p, r->p + ev, r->len - ev);
    r->len -= ev;
}

static void ring_add(ring_t *r, const unsigned char *d, size_t n) {
    while (n > 0) {
        size_t chunk = n > r->cap / 2 ? r->cap / 2 : n;
        if (r->len + chunk > r->cap) {
            size_t need = r->len + chunk - r->cap;
            ring_evict(r, need > r->cap / 16 ? need : r->cap / 16);
        }
        memcpy(r->p + r->len, d, chunk);
        r->len += chunk;
        d += chunk;
        n -= chunk;
    }
}

static void ring_replay(ring_t *r, buf_t *out, bool sanitize) {
    ts_prefix(&r->base, out);
    if (!sanitize) {
        buf_append(out, r->p, r->len);
        return;
    }
    vt_t *v = calloc(1, sizeof *v);
    if (!v) abort();
    vt_feed(v, r->p, r->len, san_token, out); // an unfinished sequence at the very end is dropped
    free(v);
}

// MARK: Paths

static char g_socket_dir[PATH_MAX];

static bool valid_id(const char *id) {
    size_t n = strlen(id);
    if (n == 0 || n > 64 || id[0] == '.') return false;
    for (size_t i = 0; i < n; i++) {
        char c = id[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'))
            return false;
    }
    return true;
}

// Creates the socket folder if needed. It has to be a real folder that only this user can use.
static int ensure_dir(const char *path) {
    if (mkdir(path, 0700) != 0) {
        if (errno == ENOENT) {
            char parent[PATH_MAX];
            strlcpy(parent, path, sizeof parent);
            char *slash = strrchr(parent, '/');
            if (slash && slash != parent) {
                *slash = 0;
                if (ensure_dir(parent) != 0) return -1;
            }
            if (mkdir(path, 0700) != 0 && errno != EEXIST) return -1;
        } else if (errno != EEXIST) {
            return -1;
        }
    }
    struct stat st;
    if (lstat(path, &st) != 0) return -1;
    if (!S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) {
        errno = EPERM;
        return -1;
    }
    return 0;
}

static bool sock_path(const char *id, char *out, size_t outlen, const char *suffix) {
    struct sockaddr_un sa;
    int n = snprintf(out, outlen, "%s/%s%s", g_socket_dir, id, suffix);
    return n > 0 && (size_t)n < outlen && (size_t)n < sizeof sa.sun_path;
}

static int connect_sock(const char *path) {
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strlcpy(sa.sun_path, path, sizeof sa.sun_path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    set_cloexec(fd);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) != 0) {
        int e = errno;
        close(fd);
        errno = e;
        return -1;
    }
    return fd;
}

// MARK: Server

typedef struct {
    int fd;
    bool attached;
    bool wants_exit;
    buf_t in, out;
} conn_t;

static struct {
    char id[80];
    char sock[PATH_MAX];
    char lock[PATH_MAX];
    char cwd[PATH_MAX];
    char *command;
    int listen_fd, master, sigpipe[2];
    pid_t child;
    bool child_done;
    int status;
    bool pty_open;
    conn_t conns[MAX_CONNS];
    int nconns;
    int attached; // index into conns, or -1
    bool ever_attached;
    bool linger;  // created by an attaching client: wait for it before leaving
    double linger_deadline;
    ring_t ring;
    buf_t ptyq;
    struct winsize ws;
    bool wiggle;
    double wiggle_at;
    struct winsize wiggle_ws;
    bool killing;
    double kill_deadline;
    time_t created;
} S;

static void server_signal(int sig) {
    unsigned char c = (unsigned char)sig;
    ssize_t r = write(S.sigpipe[1], &c, 1);
    (void)r;
}

static void close_inherited_fds(int keep) {
    DIR *d = opendir("/dev/fd");
    if (d) {
        int dfd = dirfd(d);
        int fds[1024];
        int nf = 0;
        struct dirent *e;
        while ((e = readdir(d)) && nf < 1024) {
            int fd = atoi(e->d_name);
            if (e->d_name[0] >= '0' && e->d_name[0] <= '9' && fd > 2 && fd != keep && fd != dfd) fds[nf++] = fd;
        }
        closedir(d);
        for (int i = 0; i < nf; i++) close(fds[i]);
    } else {
        for (int fd = 3; fd < 4096; fd++)
            if (fd != keep) close(fd);
    }
}

static void set_winsize(const struct winsize *ws) {
    S.ws = *ws;
    if (S.pty_open) ioctl(S.master, TIOCSWINSZ, ws);
}

static void send_info(conn_t *c) {
    buf_t j = {0};
    char tmp[256];
    buf_str(&j, "{\"id\":");
    json_str(&j, S.id);
    snprintf(tmp, sizeof tmp, ",\"pid\":%d,\"child\":%d,\"attached\":%s,\"exited\":%s,\"created\":%ld,\"rows\":%u,\"cols\":%u,\"cwd\":",
             (int)getpid(), (int)S.child, S.attached >= 0 ? "true" : "false", S.child_done ? "true" : "false",
             (long)S.created, S.ws.ws_row, S.ws.ws_col);
    buf_str(&j, tmp);
    json_str(&j, S.cwd);
    buf_str(&j, ",\"command\":");
    json_str(&j, S.command);
    buf_str(&j, "}");
    frame_append(&c->out, MSG_INFO_REPLY, j.p + j.off, buf_pending(&j));
    buf_free(&j);
}

static void begin_kill(void) {
    if (S.child_done || S.killing) return;
    // What a terminal does when its window closes: hang up the agent's process group and the
    // pty. The agent is the only thing this server started, so it's the only thing signalled.
    killpg(S.child, SIGHUP);
    kill(S.child, SIGHUP);
    killpg(S.child, SIGCONT);
    if (S.pty_open) {
        close(S.master);
        S.master = -1;
        S.pty_open = false;
    }
    S.killing = true;
    S.kill_deadline = now() + 3.0;
}

static void attach_client(int i, const struct winsize *ws) {
    conn_t *c = &S.conns[i];
    if (S.attached >= 0 && S.attached != i) {
        // Newest client wins, so two windows never fight over the size.
        conn_t *old = &S.conns[S.attached];
        unsigned char hdr[FRAME_HDR] = {MSG_KICKED, 0, 0, 0, 0};
        ssize_t r = write(old->fd, hdr, FRAME_HDR);
        (void)r;
        close(old->fd);
        old->fd = -1;
        buf_free(&old->in);
        buf_free(&old->out);
    }
    S.attached = i;
    c->attached = true;
    bool first = !S.ever_attached && S.linger;
    S.ever_attached = true;

    // The creating client gets everything as it was (its terminal hasn't answered anything
    // yet). A reattaching client gets the replay without queries, bells or notifications.
    buf_t rep = {0};
    ring_replay(&S.ring, &rep, !first);
    if (buf_pending(&rep)) frame_append(&c->out, MSG_OUTPUT, rep.p + rep.off, buf_pending(&rep));
    buf_free(&rep);

    if (S.child_done || !S.pty_open || ws->ws_row == 0 || ws->ws_col == 0) return;
    bool same = ws->ws_row == S.ws.ws_row && ws->ws_col == S.ws.ws_col;
    S.wiggle = false;
    if (!same) {
        set_winsize(ws);
    } else if (!first && ws->ws_col > 2) {
        // Same size as before, so the agent wouldn't hear about it. Narrow it by a column, then
        // put it back a moment later, so it gets two SIGWINCHs and redraws at the right size.
        struct winsize w2 = *ws;
        w2.ws_col--;
        set_winsize(&w2);
        S.wiggle = true;
        S.wiggle_ws = *ws;
        S.wiggle_at = now() + 0.12;
    }
}

static void handle_frames(int i) {
    conn_t *c = &S.conns[i];
    while (c->fd >= 0 && buf_pending(&c->in) >= FRAME_HDR) {
        unsigned char *p = c->in.p + c->in.off;
        int type = p[0];
        uint32_t len = get_u32(p + 1);
        if (len > FRAME_MAX * 2) { // not one of ours
            close(c->fd);
            c->fd = -1;
            return;
        }
        if (buf_pending(&c->in) < FRAME_HDR + len) break;
        unsigned char *pl = p + FRAME_HDR;
        switch (type) {
        case MSG_HELLO:
            if (len >= 10) {
                struct winsize ws;
                ws_get(pl + 2, &ws);
                attach_client(i, &ws);
            }
            break;
        case MSG_INPUT:
            if (i == S.attached && S.pty_open) buf_append(&S.ptyq, pl, len);
            break;
        case MSG_WINCH:
            if (i == S.attached && len >= 8) {
                struct winsize ws;
                ws_get(pl, &ws);
                S.wiggle = false;
                if (ws.ws_row && ws.ws_col) set_winsize(&ws);
            }
            break;
        case MSG_INFO:
            send_info(c);
            break;
        case MSG_KILL:
            c->wants_exit = true;
            begin_kill();
            break;
        default:
            break;
        }
        if (c->fd < 0) return;
        buf_consume(&c->in, FRAME_HDR + len);
    }
}

static void close_conn(int i) {
    conn_t *c = &S.conns[i];
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
    buf_free(&c->in);
    buf_free(&c->out);
}

static void compact_conns(void) {
    int w = 0, att = -1;
    for (int r = 0; r < S.nconns; r++) {
        if (S.conns[r].fd < 0) continue;
        if (r == S.attached) att = w;
        if (w != r) S.conns[w] = S.conns[r];
        w++;
    }
    S.nconns = w;
    S.attached = att;
}

// Reads what the agent wrote. True if there may be more waiting.
static bool read_pty(void) {
    unsigned char b[65536];
    for (int rounds = 0; rounds < 8 && S.pty_open; rounds++) {
        ssize_t n = read(S.master, b, sizeof b);
        if (n > 0) {
            ring_add(&S.ring, b, (size_t)n);
            if (S.attached >= 0) frame_append(&S.conns[S.attached].out, MSG_OUTPUT, b, (size_t)n);
            if ((size_t)n < sizeof b) return false;
        } else if (n < 0 && (errno == EAGAIN || errno == EINTR)) {
            return false;
        } else {
            S.pty_open = false; // EIO: nothing holds the terminal open any more
            return false;
        }
    }
    return S.pty_open;
}

static void write_pty(void) {
    while (S.pty_open && buf_pending(&S.ptyq)) {
        ssize_t w = write(S.master, S.ptyq.p + S.ptyq.off, buf_pending(&S.ptyq));
        if (w > 0) buf_consume(&S.ptyq, (size_t)w);
        else if (w < 0 && errno == EINTR) continue;
        else return;
    }
}

static void flush_conn(conn_t *c) {
    while (c->fd >= 0 && buf_pending(&c->out)) {
        ssize_t w = write(c->fd, c->out.p + c->out.off, buf_pending(&c->out));
        if (w > 0) buf_consume(&c->out, (size_t)w);
        else if (w < 0 && errno == EINTR) continue;
        else if (w < 0 && errno == EAGAIN) return;
        else {
            close(c->fd);
            c->fd = -1;
            return;
        }
    }
}

static void finish(void) {
    for (int k = 0; k < 64 && S.pty_open && read_pty(); k++) {} // everything the agent wrote before it left
    int st = S.status;
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : (WIFSIGNALED(st) ? 128 + WTERMSIG(st) : 1);
    unlink(S.sock);
    unlink(S.lock);
    unsigned char be[4];
    put_u32(be, (uint32_t)code);
    for (int i = 0; i < S.nconns; i++) {
        conn_t *c = &S.conns[i];
        if (c->fd >= 0 && (c->attached || c->wants_exit)) frame_append(&c->out, MSG_EXIT, be, 4);
    }
    double deadline = now() + 2.0;
    for (int i = 0; i < S.nconns; i++) {
        conn_t *c = &S.conns[i];
        while (c->fd >= 0 && buf_pending(&c->out) && now() < deadline) {
            struct pollfd pf = {c->fd, POLLOUT, 0};
            poll(&pf, 1, 100);
            flush_conn(c);
        }
        if (c->fd >= 0) close(c->fd);
    }
    _exit(0);
}

static void handle_signals(void) {
    unsigned char sigs[64];
    ssize_t n;
    while ((n = read(S.sigpipe[0], sigs, sizeof sigs)) > 0) {
        for (ssize_t k = 0; k < n; k++) {
            if (sigs[k] == SIGCHLD) {
                int st;
                pid_t p;
                while ((p = waitpid(-1, &st, WNOHANG)) > 0) {
                    if (p == S.child) {
                        S.child_done = true;
                        S.status = st;
                        S.linger_deadline = now() + 5.0;
                    }
                }
            } else {
                begin_kill(); // SIGTERM or SIGINT to the server: stop the agent, then leave
            }
        }
    }
}

static void server_loop(void) {
    for (;;) {
        if (S.child_done) {
            bool waiting_for_creator = S.linger && !S.ever_attached && now() < S.linger_deadline;
            if (!waiting_for_creator) finish();
        }

        struct pollfd fds[3 + MAX_CONNS];
        int conn_idx[MAX_CONNS];
        int nf = 0;
        fds[nf++] = (struct pollfd){S.listen_fd, POLLIN, 0};
        fds[nf++] = (struct pollfd){S.sigpipe[0], POLLIN, 0};
        int pty_idx = -1;
        if (S.pty_open) {
            short ev = 0;
            bool backlog = S.attached >= 0 && buf_pending(&S.conns[S.attached].out) > CLIENT_HIGH_WATER;
            if (!backlog) ev |= POLLIN;
            if (buf_pending(&S.ptyq)) ev |= POLLOUT;
            if (ev) {
                pty_idx = nf;
                fds[nf++] = (struct pollfd){S.master, ev, 0};
            }
        }
        for (int i = 0; i < S.nconns; i++) {
            short ev = POLLIN;
            if (i == S.attached && buf_pending(&S.ptyq) > PTY_QUEUE_MAX) ev = 0;
            if (buf_pending(&S.conns[i].out)) ev |= POLLOUT;
            conn_idx[i] = nf;
            fds[nf++] = (struct pollfd){S.conns[i].fd, ev, 0};
        }

        double t = now(), next = -1;
        if (S.wiggle) next = S.wiggle_at;
        if (S.killing && !S.child_done && (next < 0 || S.kill_deadline < next)) next = S.kill_deadline;
        if (S.child_done && (next < 0 || S.linger_deadline < next)) next = S.linger_deadline;
        int timeout = next < 0 ? -1 : (next <= t ? 0 : (int)((next - t) * 1000) + 1);

        int r = poll(fds, (nfds_t)nf, timeout);
        if (r < 0 && errno != EINTR) _exit(1);
        t = now();
        if (S.wiggle && t >= S.wiggle_at) {
            S.wiggle = false;
            set_winsize(&S.wiggle_ws);
        }
        if (S.killing && !S.child_done && t >= S.kill_deadline) {
            killpg(S.child, SIGKILL);
            kill(S.child, SIGKILL);
            S.kill_deadline = t + 3600;
        }
        if (r <= 0) continue;

        if (fds[1].revents) handle_signals();
        if (pty_idx >= 0) {
            if (fds[pty_idx].revents & POLLOUT) write_pty();
            if (fds[pty_idx].revents & (POLLIN | POLLHUP | POLLERR)) read_pty();
        }
        for (int i = 0; i < S.nconns; i++) {
            conn_t *c = &S.conns[i];
            if (c->fd < 0) continue;
            short re = fds[conn_idx[i]].revents;
            if (re & POLLOUT) flush_conn(c);
            if (c->fd >= 0 && (re & (POLLIN | POLLHUP | POLLERR))) {
                unsigned char b[65536];
                ssize_t n = read(c->fd, b, sizeof b);
                if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                    close_conn(i);
                } else if (n > 0) {
                    buf_append(&c->in, b, (size_t)n);
                    handle_frames(i);
                    if (buf_pending(&S.ptyq)) write_pty();
                }
            }
            if (c->fd >= 0 && buf_pending(&c->out)) flush_conn(c);
        }
        compact_conns();
        if (fds[0].revents & POLLIN) {
            int fd = accept(S.listen_fd, NULL, NULL);
            if (fd >= 0) {
                uid_t uid;
                gid_t gid;
                if (getpeereid(fd, &uid, &gid) != 0 || uid != getuid() || S.nconns == MAX_CONNS) {
                    close(fd);
                } else {
                    set_cloexec(fd);
                    set_nonblock(fd);
                    memset(&S.conns[S.nconns], 0, sizeof(conn_t));
                    S.conns[S.nconns++].fd = fd;
                }
            }
        }
    }
}

static void report(int fd, const char *what) {
    char msg[512];
    snprintf(msg, sizeof msg, "%s: %s\n", what, strerror(errno));
    ssize_t r = write(fd, msg, strlen(msg));
    (void)r;
}

// Runs in the detached grandchild. Never returns.
static void server_main(int ready, const char *id, const char *cwd, char **argv, const struct winsize *ws,
                        const struct termios *tio, mode_t umask_orig, bool linger) {
    close_inherited_fds(ready);
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, 0);
        dup2(devnull, 1);
        dup2(devnull, 2);
        if (devnull > 2) close(devnull);
    }
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    signal(SIGHUP, SIG_IGN);
    signal(SIGPIPE, SIG_IGN);
    signal(SIGQUIT, SIG_IGN);
    signal(SIGTSTP, SIG_IGN);
    signal(SIGTTIN, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);

    memset(&S, 0, sizeof S);
    S.attached = -1;
    S.master = -1;
    S.linger = linger;
    S.created = time(NULL);
    strlcpy(S.id, id, sizeof S.id);
    strlcpy(S.cwd, cwd, sizeof S.cwd);
    if (!sock_path(id, S.sock, sizeof S.sock, ".sock") || !sock_path(id, S.lock, sizeof S.lock, ".lock")) {
        errno = ENAMETOOLONG;
        report(ready, "socket path");
        _exit(1);
    }
    buf_t cmd = {0};
    for (int i = 0; argv[i]; i++) {
        if (i) buf_str(&cmd, " ");
        buf_str(&cmd, argv[i]);
    }
    buf_append(&cmd, "", 1);
    S.command = (char *)cmd.p;
    ring_init(&S.ring, RING_DEFAULT);

    if (pipe(S.sigpipe) != 0) { report(ready, "pipe"); _exit(1); }
    set_cloexec(S.sigpipe[0]);
    set_cloexec(S.sigpipe[1]);
    set_nonblock(S.sigpipe[0]);
    set_nonblock(S.sigpipe[1]);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = server_signal;
    sa.sa_flags = SA_RESTART;
    sigaction(SIGCHLD, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    S.listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (S.listen_fd < 0) { report(ready, "socket"); _exit(1); }
    set_cloexec(S.listen_fd);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, S.sock, sizeof addr.sun_path);
    umask(077);
    int b = bind(S.listen_fd, (struct sockaddr *)&addr, sizeof addr);
    umask(umask_orig);
    if (b != 0) { report(ready, "bind"); _exit(1); }
    if (listen(S.listen_fd, 8) != 0) { report(ready, "listen"); unlink(S.sock); _exit(1); }
    set_nonblock(S.listen_fd);

    S.ws = *ws;
    pid_t pid = forkpty(&S.master, NULL, (struct termios *)tio, (struct winsize *)ws);
    if (pid < 0) { report(ready, "forkpty"); unlink(S.sock); _exit(1); }
    if (pid == 0) {
        // The agent: default signals, the user's umask, the chat's folder, then exec.
        for (int s = 1; s < NSIG; s++)
            if (s != SIGKILL && s != SIGSTOP) signal(s, SIG_DFL);
        sigprocmask(SIG_SETMASK, &none, NULL);
        umask(umask_orig);
        if (chdir(cwd) != 0) {
            fprintf(stderr, "hantuu-session: can't open %s: %s\r\n", cwd, strerror(errno));
            _exit(1);
        }
        setenv("PWD", cwd, 1);
        execvp(argv[0], argv);
        fprintf(stderr, "hantuu-session: can't run %s: %s\r\n", argv[0], strerror(errno));
        _exit(127);
    }
    S.child = pid;
    S.pty_open = true;
    set_cloexec(S.master);
    set_nonblock(S.master);
    if (chdir("/") != 0) { /* not important */ }

    ssize_t r = write(ready, "ok\n", 3);
    (void)r;
    close(ready);
    server_loop();
    _exit(0);
}

// Forks the server off in its own session. Returns 0 once it's listening.
static int spawn_server(const char *id, const char *cwd, char **argv, const struct winsize *ws, bool linger) {
    struct termios tio;
    bool have_tio = isatty(0) && tcgetattr(0, &tio) == 0;
    int p[2];
    if (pipe(p) != 0) return -1;
    set_cloexec(p[0]);
    set_cloexec(p[1]);
    mode_t um = umask(0);
    umask(um);
    fflush(NULL);
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        close(p[0]);
        if (setsid() < 0) _exit(1);
        pid_t g = fork();
        if (g < 0) _exit(1);
        if (g > 0) _exit(0); // the server is reparented to launchd, outside hantuu's process tree
        server_main(p[1], id, cwd, argv, ws, have_tio ? &tio : NULL, um, linger);
    }
    close(p[1]);
    int st;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
    char buf[512];
    size_t got = 0;
    ssize_t n;
    while (got < sizeof buf - 1 && (n = read(p[0], buf + got, sizeof buf - 1 - got)) != 0) {
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        got += (size_t)n;
    }
    close(p[0]);
    buf[got] = 0;
    if (strncmp(buf, "ok", 2) == 0) return 0;
    if (got && buf[got - 1] == '\n') buf[got - 1] = 0;
    complain("the session server didn't start%s%s", got ? ": " : "", buf);
    return -1;
}

// Connects to a session, starting it first when asked to. Uses a lock so two clients can't
// start the same session at once, and clears a socket left behind by a server that was killed.
static int open_session(const char *id, const char *cwd, char **argv, const struct winsize *ws, bool create, bool linger, bool *created) {
    char path[PATH_MAX], lock[PATH_MAX];
    if (!sock_path(id, path, sizeof path, ".sock") || !sock_path(id, lock, sizeof lock, ".lock")) {
        complain("socket path too long for %s", g_socket_dir);
        return -1;
    }
    if (created) *created = false;
    int fd = connect_sock(path);
    if (fd >= 0 || !create) return fd;
    int lk = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lk >= 0) flock(lk, LOCK_EX);
    fd = connect_sock(path);
    if (fd < 0) {
        if (errno == ECONNREFUSED) unlink(path);
        if (spawn_server(id, cwd, argv, ws, linger) == 0) {
            fd = connect_sock(path);
            if (created) *created = fd >= 0;
        }
    }
    if (lk >= 0) {
        flock(lk, LOCK_UN);
        close(lk);
    }
    return fd;
}

// MARK: Client

static int g_client_sig[2] = {-1, -1};
static struct termios g_saved_tio;
static bool g_raw = false;

static void client_signal(int sig) {
    unsigned char c = (unsigned char)sig;
    ssize_t r = write(g_client_sig[1], &c, 1);
    (void)r;
}

static void restore_tty(void) {
    if (g_raw) {
        tcsetattr(0, TCSAFLUSH, &g_saved_tio);
        g_raw = false;
    }
}

static void get_ws(int fd, struct winsize *ws) {
    memset(ws, 0, sizeof *ws);
    if (ioctl(fd, TIOCGWINSZ, ws) != 0) memset(ws, 0, sizeof *ws);
}

static int client_loop(int fd) {
    if (isatty(0) && tcgetattr(0, &g_saved_tio) == 0) {
        struct termios raw = g_saved_tio;
        cfmakeraw(&raw);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(0, TCSAFLUSH, &raw) == 0) g_raw = true;
        atexit(restore_tty);
    }
    if (pipe(g_client_sig) != 0) return 1;
    set_cloexec(g_client_sig[0]);
    set_cloexec(g_client_sig[1]);
    set_nonblock(g_client_sig[0]);
    set_nonblock(g_client_sig[1]);
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = client_signal;
    sa.sa_flags = SA_RESTART;
    sigaction(SIGWINCH, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGQUIT, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);
    set_nonblock(fd);

    buf_t out = {0}, in = {0};
    struct winsize ws;
    get_ws(0, &ws);
    unsigned char hello[10];
    put_u16(hello, PROTO);
    ws_put(hello + 2, &ws);
    frame_append(&out, MSG_HELLO, hello, sizeof hello);

    bool stdin_open = true;
    for (;;) {
        struct pollfd fds[3];
        fds[0] = (struct pollfd){0, (short)(stdin_open && buf_pending(&out) < PTY_QUEUE_MAX ? POLLIN : 0), 0};
        fds[1] = (struct pollfd){fd, (short)(POLLIN | (buf_pending(&out) ? POLLOUT : 0)), 0};
        fds[2] = (struct pollfd){g_client_sig[0], POLLIN, 0};
        if (poll(fds, 3, -1) < 0) {
            if (errno == EINTR) continue;
            return 1;
        }
        if (fds[2].revents & POLLIN) {
            unsigned char sigs[32];
            ssize_t n = read(g_client_sig[0], sigs, sizeof sigs);
            for (ssize_t k = 0; k < n; k++) {
                if (sigs[k] == SIGWINCH) {
                    unsigned char w[8];
                    get_ws(0, &ws);
                    ws_put(w, &ws);
                    frame_append(&out, MSG_WINCH, w, sizeof w);
                } else {
                    return 0; // our terminal went away: detach and leave the agent running
                }
            }
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            unsigned char b[65536];
            ssize_t n = read(0, b, sizeof b);
            if (n > 0) frame_append(&out, MSG_INPUT, b, (size_t)n);
            else if (n == 0 || (errno != EAGAIN && errno != EINTR)) return 0;
        }
        if (fds[1].revents & POLLOUT) {
            while (buf_pending(&out)) {
                ssize_t w = write(fd, out.p + out.off, buf_pending(&out));
                if (w > 0) buf_consume(&out, (size_t)w);
                else if (w < 0 && errno == EINTR) continue;
                else break;
            }
        }
        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            unsigned char b[65536];
            ssize_t n = read(fd, b, sizeof b);
            if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                restore_tty();
                const char *msg = "\r\n[hantuu-session: lost the session]\r\n";
                write_all(1, msg, strlen(msg));
                return 1;
            }
            if (n > 0) buf_append(&in, b, (size_t)n);
            while (buf_pending(&in) >= FRAME_HDR) {
                unsigned char *p = in.p + in.off;
                uint32_t len = get_u32(p + 1);
                if (buf_pending(&in) < FRAME_HDR + len) break;
                unsigned char *pl = p + FRAME_HDR;
                if (p[0] == MSG_OUTPUT) {
                    if (!write_all(1, pl, len)) return 0;
                } else if (p[0] == MSG_EXIT) {
                    int code = len >= 4 ? (int)get_u32(pl) : 0;
                    restore_tty();
                    return code;
                } else if (p[0] == MSG_KICKED) {
                    restore_tty();
                    const char *msg = "\r\n[hantuu-session: attached somewhere else]\r\n";
                    write_all(1, msg, strlen(msg));
                    return 0;
                }
                buf_consume(&in, FRAME_HDR + len);
            }
        }
    }
}

// Sends one request and waits for a reply of the given type (or the server leaving).
static int request(int fd, int type, int want, double timeout, buf_t *reply) {
    unsigned char hdr[FRAME_HDR] = {(unsigned char)type, 0, 0, 0, 0};
    if (!write_all(fd, hdr, FRAME_HDR)) return -1;
    buf_t in = {0};
    double deadline = now() + timeout;
    for (;;) {
        double left = deadline - now();
        if (left <= 0) { buf_free(&in); return -2; }
        struct pollfd pf = {fd, POLLIN, 0};
        int r = poll(&pf, 1, (int)(left * 1000) + 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) continue;
        unsigned char b[65536];
        ssize_t n = read(fd, b, sizeof b);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { buf_free(&in); return 0; } // the server closed the connection
        buf_append(&in, b, (size_t)n);
        while (buf_pending(&in) >= FRAME_HDR) {
            unsigned char *p = in.p + in.off;
            uint32_t len = get_u32(p + 1);
            if (buf_pending(&in) < FRAME_HDR + len) break;
            if (p[0] == want) {
                if (reply) buf_append(reply, p + FRAME_HDR, len);
                buf_free(&in);
                return 1;
            }
            buf_consume(&in, FRAME_HDR + len);
        }
    }
}

// MARK: Commands

typedef struct {
    const char *cmd;
    const char *id;
    const char *cwd;
    bool create;
    bool json;
    bool first;
    size_t ring;
    struct winsize size;
    char **argv;
} opts_t;

static void usage(void) {
    fputs("hantuu-session " VERSION ": keeps an agent's terminal running when hantuu quits\n"
          "\n"
          "  attach --socket-dir DIR --id ID [--create --cwd DIR -- COMMAND...]\n"
          "  create --socket-dir DIR --id ID --cwd DIR [--size ROWSxCOLS] -- COMMAND...\n"
          "  list   --socket-dir DIR [--json]\n"
          "  kill   --socket-dir DIR --id ID\n"
          "  version\n", stderr);
}

static int cmd_attach(const opts_t *o) {
    struct winsize ws;
    get_ws(0, &ws);
    if (!ws.ws_row || !ws.ws_col) { ws.ws_row = 24; ws.ws_col = 80; }
    bool can_create = o->create && o->argv && o->argv[0];
    if (o->create && !can_create) { complain("--create needs a command after --"); return 2; }
    int fd = open_session(o->id, o->cwd ? o->cwd : ".", o->argv, &ws, can_create, true, NULL);
    if (fd < 0) {
        complain("no session %s", o->id);
        return 1;
    }
    return client_loop(fd);
}

static int cmd_create(const opts_t *o) {
    if (!o->argv || !o->argv[0]) { complain("create needs a command after --"); return 2; }
    struct winsize ws = o->size;
    if (!ws.ws_row || !ws.ws_col) { ws.ws_row = 24; ws.ws_col = 80; }
    bool created = false;
    int fd = open_session(o->id, o->cwd ? o->cwd : ".", o->argv, &ws, true, false, &created);
    if (fd < 0) return 1;
    close(fd);
    if (!created) { complain("session %s already exists", o->id); return 3; }
    return 0;
}

static int cmd_list(const opts_t *o) {
    DIR *d = opendir(g_socket_dir);
    if (!d) return 0;
    struct dirent *e;
    bool header = false;
    while ((e = readdir(d))) {
        size_t n = strlen(e->d_name);
        if (n < 6 || strcmp(e->d_name + n - 5, ".sock") != 0) continue;
        char path[PATH_MAX];
        snprintf(path, sizeof path, "%s/%s", g_socket_dir, e->d_name);
        int fd = connect_sock(path);
        if (fd < 0) {
            if (errno == ECONNREFUSED) unlink(path); // its server is gone
            continue;
        }
        buf_t reply = {0};
        int r = request(fd, MSG_INFO, MSG_INFO_REPLY, 2.0, &reply);
        close(fd);
        if (r == 1) {
            buf_append(&reply, "", 1);
            if (o->json) {
                printf("%s\n", (char *)reply.p + reply.off);
            } else {
                if (!header) {
                    printf("%-38s %8s %8s  %-9s %s\n", "ID", "SERVER", "AGENT", "STATE", "COMMAND");
                    header = true;
                }
                // The human-readable form only needs a few fields; pull them out loosely.
                const char *j = (char *)reply.p + reply.off;
                const char *pid = strstr(j, "\"pid\":"), *child = strstr(j, "\"child\":"), *cmd = strstr(j, "\"command\":\"");
                char id[80];
                strlcpy(id, e->d_name, sizeof id);
                id[n - 5 < sizeof id ? n - 5 : sizeof id - 1] = 0;
                char cmdtxt[256] = "";
                if (cmd) {
                    cmd += 11;
                    size_t k = 0;
                    while (*cmd && *cmd != '"' && k < sizeof cmdtxt - 1) {
                        if (*cmd == '\\' && cmd[1]) cmd++; // \" and \\ from json_str
                        cmdtxt[k++] = *cmd++;
                    }
                    cmdtxt[k] = 0;
                }
                printf("%-38s %8d %8d  %-9s %s\n", id, pid ? atoi(pid + 6) : 0, child ? atoi(child + 8) : 0,
                       strstr(j, "\"attached\":true") ? "attached" : "detached", cmdtxt);
            }
        }
        buf_free(&reply);
    }
    closedir(d);
    return 0;
}

static int cmd_kill(const opts_t *o) {
    char path[PATH_MAX];
    if (!sock_path(o->id, path, sizeof path, ".sock")) return 1;
    int fd = connect_sock(path);
    if (fd < 0) {
        if (errno == ECONNREFUSED) unlink(path);
        return 1;
    }
    int r = request(fd, MSG_KILL, MSG_EXIT, 8.0, NULL);
    close(fd);
    return r >= 0 ? 0 : 2;
}

static int cmd_debug_replay(const opts_t *o) {
    ring_t r;
    ring_init(&r, o->ring ? o->ring : RING_DEFAULT);
    unsigned char b[4096];
    ssize_t n;
    while ((n = read(0, b, sizeof b)) > 0) ring_add(&r, b, (size_t)n);
    buf_t out = {0};
    ring_replay(&r, &out, !o->first);
    write_all(1, out.p + out.off, buf_pending(&out));
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    opts_t o;
    memset(&o, 0, sizeof o);
    o.cmd = argv[1];
    const char *dir = NULL;
    for (int i = 2; i < argc; i++) {
        const char *a = argv[i];
        bool has_value = i + 1 < argc;
        if (strcmp(a, "--") == 0) { o.argv = argv + i + 1; break; }
        else if (strcmp(a, "--socket-dir") == 0 && has_value) dir = argv[++i];
        else if (strcmp(a, "--id") == 0 && has_value) o.id = argv[++i];
        else if (strcmp(a, "--cwd") == 0 && has_value) o.cwd = argv[++i];
        else if (strcmp(a, "--create") == 0) o.create = true;
        else if (strcmp(a, "--json") == 0) o.json = true;
        else if (strcmp(a, "--first") == 0) o.first = true;
        else if (strcmp(a, "--ring") == 0 && has_value) o.ring = (size_t)strtoull(argv[++i], NULL, 10);
        else if (strcmp(a, "--size") == 0 && has_value) {
            unsigned rows = 0, cols = 0;
            if (sscanf(argv[++i], "%ux%u", &rows, &cols) == 2) { o.size.ws_row = (unsigned short)rows; o.size.ws_col = (unsigned short)cols; }
        } else { complain("unknown option %s", a); usage(); return 2; }
    }

    if (strcmp(o.cmd, "version") == 0 || strcmp(o.cmd, "--version") == 0) { printf("hantuu-session %s\n", VERSION); return 0; }
    if (strcmp(o.cmd, "help") == 0 || strcmp(o.cmd, "--help") == 0) { usage(); return 0; }
    if (strcmp(o.cmd, "debug-replay") == 0) return cmd_debug_replay(&o);

    if (dir) strlcpy(g_socket_dir, dir, sizeof g_socket_dir);
    else snprintf(g_socket_dir, sizeof g_socket_dir, "/tmp/hantuu-%u/default", (unsigned)getuid());
    if (ensure_dir(g_socket_dir) != 0) {
        complain("can't use %s as the socket folder: %s", g_socket_dir, strerror(errno));
        return 1;
    }
    bool needs_id = strcmp(o.cmd, "attach") == 0 || strcmp(o.cmd, "create") == 0 || strcmp(o.cmd, "kill") == 0;
    if (needs_id && (!o.id || !valid_id(o.id))) { complain("--id needs letters, digits, '-', '_' or '.'"); return 2; }

    if (strcmp(o.cmd, "attach") == 0) return cmd_attach(&o);
    if (strcmp(o.cmd, "create") == 0) return cmd_create(&o);
    if (strcmp(o.cmd, "list") == 0) return cmd_list(&o);
    if (strcmp(o.cmd, "kill") == 0) return cmd_kill(&o);
    usage();
    return 2;
}
