#include "ReaderHTTPS.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <netdb.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int glancemark_is_public_address(const char *address) {
    unsigned char bytes[16];
    if (inet_pton(AF_INET, address, bytes) == 1) {
        unsigned a = bytes[0], b = bytes[1], c = bytes[2];
        if (a == 0 || a == 10 || a == 127 || a >= 224 ||
            (a == 100 && b >= 64 && b <= 127) ||
            (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99))) ||
            (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
            (a == 203 && b == 0 && c == 113)) return 0;
        return 1;
    }
    if (inet_pton(AF_INET6, address, bytes) != 1 || (bytes[0] & 0xe0) != 0x20) return 0;
    if (bytes[0] == 0x20 && (bytes[1] == 0x02 ||
        (bytes[1] == 0x01 && (bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8))))) return 0;
    return !(bytes[0] == 0x3f && bytes[1] == 0xff);
}

static int resolve_host(const char *host, char *result, size_t capacity) {
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM};
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, NULL, &hints, &addresses) != 0) return 0;
    size_t used = 0;
    int valid = 1;
    for (struct addrinfo *entry = addresses; entry; entry = entry->ai_next) {
        const void *raw;
        if (entry->ai_family == AF_INET) raw = &((struct sockaddr_in *)entry->ai_addr)->sin_addr;
        else if (entry->ai_family == AF_INET6) raw = &((struct sockaddr_in6 *)entry->ai_addr)->sin6_addr;
        else continue;

        char candidate[INET6_ADDRSTRLEN];
        if (!inet_ntop(entry->ai_family, raw, candidate, sizeof(candidate)) ||
            !glancemark_is_public_address(candidate)) {
            valid = 0;
            break;
        }
        // Continue validating every answer even after filling the bounded pin list.
        size_t length = strlen(candidate) + (entry->ai_family == AF_INET6 ? 2 : 0) + (used ? 1 : 0);
        if (length + 1 > capacity - used) continue;
        if (used) result[used++] = ',';
        if (entry->ai_family == AF_INET6) result[used++] = '[';
        size_t addressLength = strlen(candidate);
        memcpy(result + used, candidate, addressLength);
        used += addressLength;
        if (entry->ai_family == AF_INET6) result[used++] = ']';
        result[used] = '\0';
    }
    freeaddrinfo(addresses);
    return valid && used > 0;
}

typedef struct {
    GlancemarkHTTPResponse *response;
    size_t limit;
    size_t capacity;
} Receiver;

static size_t collect(char *incoming, size_t size, size_t count, void *context) {
    Receiver *receiver = context;
    GlancemarkHTTPResponse *response = receiver->response;
    if (size && count > (receiver->limit - response->length) / size) return 0;
    size_t length = size * count;
    size_t needed = response->length + length;
    if (needed > receiver->capacity) {
        size_t next = receiver->capacity ? receiver->capacity * 2 : 8192;
        if (next < needed) next = needed;
        if (next > receiver->limit) next = receiver->limit;
        uint8_t *bytes = realloc(response->bytes, next);
        if (!bytes) return 0;
        response->bytes = bytes;
        receiver->capacity = next;
    }
    if (length) memcpy(response->bytes + response->length, incoming, length);
    response->length = needed;
    return length;
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static CURLcode setup;
static void initialize(void) { setup = curl_global_init(CURL_GLOBAL_DEFAULT); }

int glancemark_fetch_https(const char *url, const char *host, size_t limit, long timeout_ms, GlancemarkHTTPResponse *response) {
    memset(response, 0, sizeof(*response));
    char addresses[768];
    if (!resolve_host(host, addresses, sizeof(addresses))) return 0;

    pthread_once(&once, initialize);
    if (setup != CURLE_OK) return 0;
    CURL *curl = curl_easy_init();
    if (!curl) return 0;
    char rule[1040];
    int written = snprintf(rule, sizeof(rule), "%s:443:%s", host, addresses);
    struct curl_slist *resolved = NULL;
    Receiver receiver = {.response = response, .limit = limit, .capacity = 0};
    int success = 0;
    if (written < 0 || (size_t)written >= sizeof(rule) || !(resolved = curl_slist_append(NULL, rule))) goto cleanup;
#define SET(option, value) if (curl_easy_setopt(curl, option, value) != CURLE_OK) goto cleanup
    SET(CURLOPT_URL, url);
    SET(CURLOPT_RESOLVE, resolved);
    SET(CURLOPT_PROTOCOLS_STR, "https");
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_NETRC, (long)CURL_NETRC_IGNORED);
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_CONNECTTIMEOUT_MS, 3500L);
    SET(CURLOPT_TIMEOUT_MS, timeout_ms);
    SET(CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
    SET(CURLOPT_USERAGENT, "Glancemark");
    SET(CURLOPT_WRITEFUNCTION, collect);
    SET(CURLOPT_WRITEDATA, &receiver);
#undef SET
    if (curl_easy_perform(curl) != CURLE_OK) goto cleanup;
    if (curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response->status) != CURLE_OK) goto cleanup;
    char *redirect = NULL;
    if (curl_easy_getinfo(curl, CURLINFO_REDIRECT_URL, &redirect) == CURLE_OK && redirect) {
        response->redirect = strdup(redirect);
        if (!response->redirect) goto cleanup;
    }
    success = 1;
cleanup:
    curl_easy_cleanup(curl);
    curl_slist_free_all(resolved);
    if (!success) glancemark_free_response(response);
    return success;
}

void glancemark_free_response(GlancemarkHTTPResponse *response) {
    free(response->bytes);
    free(response->redirect);
    memset(response, 0, sizeof(*response));
}
