#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *bytes;
    size_t length;
    long status;
    char *redirect;
} GlancemarkHTTPResponse;

int glancemark_is_public_address(const char *address);
int glancemark_fetch_https(const char *url, const char *host, size_t limit, long timeout_ms, GlancemarkHTTPResponse *response);
void glancemark_free_response(GlancemarkHTTPResponse *response);
