/*
 * tb/tcp_vpi.c — iverilog VPI plugin providing four system tasks:
 *
 *   $tcp_listen(port)               — open server socket, block until connected
 *   $tcp_readline(str_var)          — read one newline-terminated line
 *   $tcp_writeline(str)             — write string + newline to client
 *   $tcp_readbytes_to_file(str_var, n) — recv n bytes, write to temp file,
 *                                         return the temp-file path in str_var
 *
 * Build:
 *   gcc -shared -fPIC -undefined dynamic_lookup -o tb/tcp_vpi.so tb/tcp_vpi.c \
 *       -I/opt/homebrew/include/iverilog
 *
 * Run testbench with plugin:
 *   vvp sim_chip.vvp -mtb/tcp_vpi
 */

#include "vpi_user.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int   server_fd  = -1;
static int   client_fd  = -1;
static FILE *client_r   = NULL;   /* line-reading stream */
static FILE *client_w   = NULL;   /* write stream */

/* -----------------------------------------------------------------------
 * $tcp_listen(port)
 * Open a TCP server socket, print the port, and block until one client
 * connects.  Call once at testbench startup.
 * --------------------------------------------------------------------- */
static PLI_INT32 tcp_listen_calltf(PLI_BYTE8 *ud) {
    vpiHandle call_h  = vpi_handle(vpiSysTfCall, NULL);
    vpiHandle args    = vpi_iterate(vpiArgument, call_h);
    vpiHandle port_h  = vpi_scan(args);
    s_vpi_value v;
    int port, opt = 1;
    struct sockaddr_in addr;

    v.format = vpiIntVal;
    vpi_get_value(port_h, &v);
    port = v.value.integer;
    vpi_free_object(args);

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((uint16_t)port);

    bind(server_fd, (struct sockaddr *)&addr, sizeof(addr));
    listen(server_fd, 1);
    vpi_printf("[tcp_vpi] listening on port %d ...\n", port);

    client_fd = accept(server_fd, NULL, NULL);
    client_r  = fdopen(dup(client_fd), "r");
    client_w  = fdopen(dup(client_fd), "w");
    setvbuf(client_w, NULL, _IONBF, 0);

    vpi_printf("[tcp_vpi] client connected\n");
    return 0;
}

/* -----------------------------------------------------------------------
 * $tcp_writeline(str_expr)
 * Write the string value of the argument followed by '\n'.
 * --------------------------------------------------------------------- */
static PLI_INT32 tcp_writeline_calltf(PLI_BYTE8 *ud) {
    vpiHandle call_h = vpi_handle(vpiSysTfCall, NULL);
    vpiHandle args   = vpi_iterate(vpiArgument, call_h);
    vpiHandle str_h  = vpi_scan(args);
    s_vpi_value v;

    v.format = vpiStringVal;
    vpi_get_value(str_h, &v);
    fprintf(client_w, "%s\n", v.value.str);
    fflush(client_w);

    vpi_free_object(args);
    return 0;
}

/* -----------------------------------------------------------------------
 * $tcp_readline(str_var)
 * Read one newline-terminated line from the client into the variable.
 * Blocks until data arrives.  On EOF, writes "QUIT" to the variable.
 * --------------------------------------------------------------------- */
static PLI_INT32 tcp_readline_calltf(PLI_BYTE8 *ud) {
    vpiHandle call_h = vpi_handle(vpiSysTfCall, NULL);
    vpiHandle args   = vpi_iterate(vpiArgument, call_h);
    vpiHandle var_h  = vpi_scan(args);
    s_vpi_value v;
    static char buf[4096];

    if (fgets(buf, sizeof(buf), client_r) == NULL)
        strncpy(buf, "QUIT\n", sizeof(buf));

    /* Strip trailing newline so $sscanf parses cleanly */
    size_t len = strlen(buf);
    if (len > 0 && buf[len-1] == '\n') buf[len-1] = '\0';

    v.format      = vpiStringVal;
    v.value.str   = buf;
    vpi_put_value(var_h, &v, NULL, vpiNoDelay);

    vpi_free_object(args);
    return 0;
}

/* -----------------------------------------------------------------------
 * $tcp_readbytes_to_file(str_var, n)
 * Receive exactly n bytes from the client (using a bulk recv loop),
 * write them to a mkstemp temp file, and store the file path in str_var.
 * Much faster than one-byte-at-a-time VPI calls for large transfers.
 * --------------------------------------------------------------------- */
static PLI_INT32 tcp_readbytes_to_file_calltf(PLI_BYTE8 *ud) {
    vpiHandle call_h  = vpi_handle(vpiSysTfCall, NULL);
    vpiHandle args    = vpi_iterate(vpiArgument, call_h);
    vpiHandle path_h  = vpi_scan(args);   /* output: temp-file path */
    vpiHandle n_h     = vpi_scan(args);   /* input:  byte count     */
    s_vpi_value v;
    static char tmppath[256];
    char buf[65536];
    int n, fd, total, got;
    FILE *tmpf;

    v.format = vpiIntVal;
    vpi_get_value(n_h, &v);
    n = v.value.integer;
    vpi_free_object(args);

    /* Open temp file */
    strcpy(tmppath, "/tmp/sim_stream_XXXXXX");
    fd = mkstemp(tmppath);
    tmpf = fdopen(fd, "wb");

    /* Bulk recv loop */
    total = 0;
    while (total < n) {
        int want = (n - total < (int)sizeof(buf)) ? n - total : (int)sizeof(buf);
        got = (int)recv(client_fd, buf, (size_t)want, 0);
        if (got <= 0) break;
        fwrite(buf, 1, (size_t)got, tmpf);
        total += got;
    }
    fclose(tmpf);

    /* Return path to SV string variable */
    v.format    = vpiStringVal;
    v.value.str = tmppath;
    vpi_put_value(path_h, &v, NULL, vpiNoDelay);
    return 0;
}

/* -----------------------------------------------------------------------
 * Registration
 * --------------------------------------------------------------------- */
static void register_tasks(void) {
    s_vpi_systf_data d = {0};
    d.type = vpiSysTask;

    d.tfname = "$tcp_listen";         d.calltf = tcp_listen_calltf;         vpi_register_systf(&d);
    d.tfname = "$tcp_writeline";      d.calltf = tcp_writeline_calltf;      vpi_register_systf(&d);
    d.tfname = "$tcp_readline";       d.calltf = tcp_readline_calltf;       vpi_register_systf(&d);
    d.tfname = "$tcp_readbytes_to_file"; d.calltf = tcp_readbytes_to_file_calltf; vpi_register_systf(&d);
}

void (*vlog_startup_routines[])(void) = { register_tasks, 0 };
