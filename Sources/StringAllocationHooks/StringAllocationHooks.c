//
//  StringAllocationHooks.c
//  PropertyTestingKit
//
//  Hooks Swift string creation to capture magic strings at runtime.
//  Uses fishhook to rebind Swift's _builtinStringLiteral initializer.
//

#include "include/StringAllocationHooks.h"
#include "fishhook.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>

// Configuration
#define SAH_MAX_STRINGS 2048
#define SAH_MAX_STRING_LEN 512
#define SAH_MIN_STRING_LEN 2

// Storage for captured strings
static char sah_strings[SAH_MAX_STRINGS][SAH_MAX_STRING_LEN];
static size_t sah_count = 0;
static pthread_mutex_t sah_lock = PTHREAD_MUTEX_INITIALIZER;
static bool sah_enabled = false;
static bool sah_initialized = false;

// Swift's _StringGuts layout (64-bit)
typedef struct {
    uint64_t _object;
    uint64_t _otherBits;
} StringGuts;

// Original function pointer (set by fishhook)
typedef StringGuts (*builtinLiteral_fn)(const char*, size_t, bool);
static builtinLiteral_fn sah_orig_builtinLiteral = NULL;

// Check if string should be filtered out
static bool sah_is_noise(const char* str, size_t len) {
    if (len < SAH_MIN_STRING_LEN) return true;
    if (len >= SAH_MAX_STRING_LEN) return true;

    // Skip strings with leading whitespace/newlines (usually formatting)
    if (str[0] == '\n' || str[0] == '\t' || str[0] == ' ') return true;

    // Skip strings that look like debug output
    if (strstr(str, " -> ") != NULL) return true;
    if (strstr(str, "===") != NULL) return true;

    // Skip format specifiers
    if (strchr(str, '%') != NULL) return true;

    // Skip file paths
    if (str[0] == '/') return true;
    if (strstr(str, ".swift") != NULL) return true;

    // Skip URLs
    if (strncmp(str, "http", 4) == 0) return true;

    // Skip common noise patterns
    if (strncmp(str, "error", 5) == 0) return true;
    if (strncmp(str, "Error", 5) == 0) return true;
    if (strncmp(str, "fatal", 5) == 0) return true;
    if (strncmp(str, "Fatal", 5) == 0) return true;

    return false;
}

// Record a captured string
static void sah_record(const char* str, size_t len) {
    if (!sah_enabled) return;
    if (sah_is_noise(str, len)) return;

    pthread_mutex_lock(&sah_lock);

    if (sah_count < SAH_MAX_STRINGS) {
        // Check for duplicate
        bool found = false;
        for (size_t i = 0; i < sah_count; i++) {
            if (strncmp(sah_strings[i], str, len) == 0 &&
                sah_strings[i][len] == '\0') {
                found = true;
                break;
            }
        }

        if (!found) {
            memcpy(sah_strings[sah_count], str, len);
            sah_strings[sah_count][len] = '\0';
            sah_count++;
        }
    }

    pthread_mutex_unlock(&sah_lock);
}

// Hooked string literal initializer
static StringGuts sah_hooked_builtinLiteral(const char* ptr, size_t count, bool isASCII) {
    if (sah_enabled && ptr && count > 0) {
        sah_record(ptr, count);
    }

    if (sah_orig_builtinLiteral) {
        return sah_orig_builtinLiteral(ptr, count, isASCII);
    }

    // Fallback: return empty string
    StringGuts empty = {0, 0xE000000000000000ULL}; // Empty small string
    return empty;
}

// Public API

void sah_initialize(void) {
    if (sah_initialized) return;

    // Rebind Swift's string literal initializer
    int result = rebind_symbols((struct rebinding[1]){
        {
            "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC",
            (void*)sah_hooked_builtinLiteral,
            (void**)&sah_orig_builtinLiteral
        }
    }, 1);

    sah_initialized = (result == 0 && sah_orig_builtinLiteral != NULL);
}

bool sah_is_available(void) {
    if (!sah_initialized) {
        sah_initialize();
    }
    return sah_orig_builtinLiteral != NULL;
}

void sah_enable(void) {
    if (!sah_initialized) {
        sah_initialize();
    }
    sah_enabled = true;
}

void sah_disable(void) {
    sah_enabled = false;
}

bool sah_is_enabled(void) {
    return sah_enabled;
}

void sah_clear(void) {
    pthread_mutex_lock(&sah_lock);
    sah_count = 0;
    pthread_mutex_unlock(&sah_lock);
}

size_t sah_get_count(void) {
    return sah_count;
}

const char* sah_get_string(size_t index) {
    if (index >= sah_count) return NULL;
    return sah_strings[index];
}

void sah_get_all_strings(const char** out_strings, size_t* out_count) {
    pthread_mutex_lock(&sah_lock);

    if (out_count) {
        *out_count = sah_count;
    }

    if (out_strings) {
        for (size_t i = 0; i < sah_count; i++) {
            out_strings[i] = sah_strings[i];
        }
    }

    pthread_mutex_unlock(&sah_lock);
}
