/* =============================================================================
 * sim_tcp_dpi.c
 * DPI-C TCP backend for RTL simulation — implements the server side of the
 * READ/WRITE/STREAM/INJECT text protocol spoken by host/sim_backend.py.
 *
 * This is simulation-only glue (testbench infrastructure), not synthesizable
 * RTL. It is imported into SystemVerilog via `import "DPI-C"` and driven from
 * a forever-loop in a testbench initial block (see tb_accel_server.sv).
 *
 * Wire protocol (one client at a time, mirrors host/stub_sim_server.py):
 *   READ   0x<addr>\n                  -> reply "DATA 0x<val>\n"
 *   WRITE  0x<addr> 0x<val>\n          -> reply "OK\n"
 *   STREAM <n>\n<n raw bytes>          -> reply "OK\n"
 *   INJECT <mem_id> <addr> <bit_idx>\n -> reply "OK\n"
 *   anything else                      -> reply "ERR ...\n"
 *
 * dpi_next_cmd() blocks (real wall-clock time, not simulation time) until a
 * full command is available, decodes it, and reports it back to SV via
 * scalar output args. STREAM payload bytes are buffered internally and
 * fetched one at a time through dpi_stream_byte().
 * =============================================================================
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#ifdef __cplusplus
extern "C" {
#endif

#define CMD_READ    0
#define CMD_WRITE   1
#define CMD_STREAM  2
#define CMD_INJECT  3
#define CMD_UNKNOWN 9

#define LINEBUF_SIZE   256
#define STREAM_MAX     (1 << 20)   /* 1 MiB — plenty for weight/image blobs */

static int listen_fd = -1;
static int client_fd = -1;

static unsigned char stream_buf[STREAM_MAX];
static int           stream_len = 0;

/* ---------------------------------------------------------------------------
 * Low-level helpers
 * ------------------------------------------------------------------------- */

/* Reads one '\n'-terminated line (line excludes the trailing newline).
 * Returns line length, or -1 on EOF/error. */
static int recv_line(char *buf, int maxlen) {
    int n = 0;
    while (n < maxlen - 1) {
        char c;
        ssize_t r = recv(client_fd, &c, 1, 0);
        if (r <= 0) return -1;          /* peer closed or error */
        if (c == '\n') break;
        if (c != '\r') buf[n++] = c;
    }
    buf[n] = '\0';
    return n;
}

/* Reads exactly n raw bytes into stream_buf. Returns 0 on success, -1 on EOF. */
static int recv_exact(unsigned char *buf, int n) {
    int got = 0;
    while (got < n) {
        ssize_t r = recv(client_fd, buf + got, n - got, 0);
        if (r <= 0) return -1;
        got += (int)r;
    }
    return 0;
}

static void send_line(const char *s) {
    if (client_fd < 0) return;
    send(client_fd, s, strlen(s), 0);
}

/* ---------------------------------------------------------------------------
 * DPI-exported entry points
 * ------------------------------------------------------------------------- */

/* Bind + listen. Returns 0 on success, -1 on failure. */
int dpi_listen(int port) {
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("dpi_listen: socket");
        return -1;
    }

    int yes = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((unsigned short)port);

    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("dpi_listen: bind");
        close(listen_fd);
        listen_fd = -1;
        return -1;
    }

    if (listen(listen_fd, 1) < 0) {
        perror("dpi_listen: listen");
        close(listen_fd);
        listen_fd = -1;
        return -1;
    }

    printf("[sim_tcp_dpi] Listening on port %d (Ctrl-C to stop)\n", port);
    fflush(stdout);
    return 0;
}

/* Blocks until a client connects. Returns 0 on success. */
int dpi_accept(void) {
    struct sockaddr_in peer;
    socklen_t peer_len = sizeof(peer);

    client_fd = accept(listen_fd, (struct sockaddr *)&peer, &peer_len);
    if (client_fd < 0) {
        perror("dpi_accept");
        return -1;
    }

    int yes = 1;
    setsockopt(client_fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));

    printf("[sim_tcp_dpi] Client connected: %s:%d\n",
           inet_ntoa(peer.sin_addr), ntohs(peer.sin_port));
    fflush(stdout);
    return 0;
}

void dpi_close_client(void) {
    if (client_fd >= 0) {
        close(client_fd);
        client_fd = -1;
    }
    printf("[sim_tcp_dpi] Client disconnected\n");
    fflush(stdout);
}

/* Blocks until a full command line (and, for STREAM, its payload) has been
 * received. Returns 1 if a command was decoded, 0 on client disconnect.
 *
 * Outputs:
 *   cmd  — one of CMD_READ/CMD_WRITE/CMD_STREAM/CMD_INJECT/CMD_UNKNOWN
 *   arg0, arg1, arg2 — meaning depends on cmd:
 *     READ:   arg0=addr
 *     WRITE:  arg0=addr, arg1=val
 *     STREAM: arg0=n_bytes  (payload pre-buffered; fetch via dpi_stream_byte)
 *     INJECT: arg0=mem_id, arg1=addr, arg2=bit_idx
 */
int dpi_next_cmd(int *cmd, int *arg0, int *arg1, int *arg2) {
    char line[LINEBUF_SIZE];

    *cmd = CMD_UNKNOWN;
    *arg0 = 0; *arg1 = 0; *arg2 = 0;

    int n = recv_line(line, sizeof(line));
    if (n < 0) return 0;       /* client disconnected */
    if (n == 0) return 1;      /* blank line: report UNKNOWN, keep connection */

    char verb[32];
    unsigned int a0 = 0, a1 = 0;
    int matched;

    if ((matched = sscanf(line, "%31s 0x%x 0x%x", verb, &a0, &a1)) >= 2 &&
        strcasecmp(verb, "WRITE") == 0 && matched == 3) {
        *cmd = CMD_WRITE;
        *arg0 = (int)a0;
        *arg1 = (int)a1;
        return 1;
    }

    if (sscanf(line, "%31s 0x%x", verb, &a0) == 2 &&
        strcasecmp(verb, "READ") == 0) {
        *cmd = CMD_READ;
        *arg0 = (int)a0;
        return 1;
    }

    int n_bytes = 0;
    if (sscanf(line, "%31s %d", verb, &n_bytes) == 2 &&
        strcasecmp(verb, "STREAM") == 0) {
        if (n_bytes < 0 || n_bytes > STREAM_MAX) {
            send_line("ERR STREAM length out of range\n");
            return 1;
        }
        if (recv_exact(stream_buf, n_bytes) < 0) return 0;
        stream_len = n_bytes;
        *cmd = CMD_STREAM;
        *arg0 = n_bytes;
        return 1;
    }

    int mid = 0, adr = 0, bidx = 0;
    if (sscanf(line, "%31s %d %d %d", verb, &mid, &adr, &bidx) == 4 &&
        strcasecmp(verb, "INJECT") == 0) {
        *cmd = CMD_INJECT;
        *arg0 = mid;
        *arg1 = adr;
        *arg2 = bidx;
        return 1;
    }

    char errbuf[LINEBUF_SIZE + 32];
    snprintf(errbuf, sizeof(errbuf), "ERR unknown command: %s\n", line);
    send_line(errbuf);
    return 1;
}

/* Returns byte `idx` of the most recently received STREAM payload (0 if out
 * of range). */
int dpi_stream_byte(int idx) {
    if (idx < 0 || idx >= stream_len) return 0;
    return stream_buf[idx];
}

void dpi_send_ok(void) {
    send_line("OK\n");
}

void dpi_send_data(unsigned int val) {
    char buf[32];
    snprintf(buf, sizeof(buf), "DATA 0x%08X\n", val);
    send_line(buf);
}

#ifdef __cplusplus
}
#endif
