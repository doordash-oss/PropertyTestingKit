//
//  ScheduleHooks.c
//  ScheduleControl
//
//  C helpers for reading Swift runtime internals from the enqueue hook.
//  These read job metadata, task-local storage, and actor pointers using
//  verified ABI offsets from the Swift runtime source.
//

#include "ScheduleHooks.h"
#include <string.h>
#include <stdint.h>

// MARK: - ABI offsets (verified on arm64, Swift 6.x)
//
// Job layout (64 bytes on 64-bit):
//   Offset 0:  HeapObject base (16 bytes)
//   Offset 16: SchedulerPrivate[2] (16 bytes)
//   Offset 32: JobFlags (4 bytes) — low byte is JobKind
//   Offset 36: Id (4 bytes)
//   Offset 40: Voucher (8 bytes)
//   Offset 48: Reserved (8 bytes)
//   Offset 56: RunJob/ResumeTask (8 bytes)
//
// AsyncTask extends Job:
//   Offset 64: ResumeContext (8 bytes)
//   Offset 72: Reserved64 (8 bytes)
//   Offset 80: OpaquePrivateStorage (contains TaskLocal::Storage)
//
// Within PrivateStorage, TaskLocal::Storage.head is at offset 56.
// Total: 80 + 56 = 136 bytes from Job* to task-local head pointer.
//
// ProcessOutOfLineJob extends Job:
//   Offset 64: DefaultActorImpl* Actor

#define JOB_FLAGS_OFFSET 32
#define TASK_LOCAL_HEAD_OFFSET 136
#define PROCESS_JOB_ACTOR_OFFSET 64
#define MAX_TRACKED_ACTORS 256

// JobKind values from MetadataValues.h
#define JOB_KIND_TASK 0
#define JOB_KIND_DEFAULT_ACTOR_INLINE 192
#define JOB_KIND_DEFAULT_ACTOR_SEPARATE 193
#define JOB_KIND_DEFAULT_ACTOR_OVERRIDE 194

// TaskLocal::Item::Kind values
#define ITEM_KIND_VALUE 0
#define ITEM_KIND_VALUE_IN_GROUP 1
#define ITEM_KIND_PARENT_MARKER 2
#define ITEM_KIND_STOP_MARKER 3

// MARK: - Pointer validation

static bool is_valid_pointer(const void *ptr) {
    uintptr_t p = (uintptr_t)ptr;
    // Reasonable heap range for user-space on arm64 macOS
    return p >= 0x100000000ULL && p < 0x800000000000ULL;
}

static uint32_t read_job_flags(const void *job) {
    uint32_t flags;
    memcpy(&flags, (const char *)job + JOB_FLAGS_OFFSET, sizeof(flags));
    return flags;
}

static unsigned read_job_kind(const void *job) {
    return read_job_flags(job) & 0xFF;
}

// MARK: - Job introspection

bool schedule_job_is_async_task(const void *job) {
    if (!job) return false;
    return read_job_kind(job) == JOB_KIND_TASK;
}

const void *schedule_read_actor_from_job(const void *job) {
    if (!job) return NULL;
    unsigned kind = read_job_kind(job);
    if (kind < JOB_KIND_DEFAULT_ACTOR_INLINE || kind > JOB_KIND_DEFAULT_ACTOR_OVERRIDE) {
        return NULL;
    }
    const void *actor;
    memcpy(&actor, (const char *)job + PROCESS_JOB_ACTOR_OFFSET, sizeof(actor));
    return actor;
}

// MARK: - Task-local reading

int64_t schedule_read_session_from_task(const void *job, const void *expected_key) {
    if (!job || !schedule_job_is_async_task(job)) return -1;

    const void *head;
    memcpy(&head, (const char *)job + TASK_LOCAL_HEAD_OFFSET, sizeof(head));
    if (!head || !is_valid_pointer(head)) return -1;

    // Walk the task-local linked list (max depth to prevent runaway)
    const void *current = head;
    for (int depth = 0; depth < 30 && current; depth++) {
        uintptr_t nextAndKind;
        memcpy(&nextAndKind, current, sizeof(nextAndKind));
        unsigned kind = nextAndKind & 0x3;

        if (kind == ITEM_KIND_VALUE || kind == ITEM_KIND_VALUE_IN_GROUP) {
            // ValueItem layout: [nextAndKind: 8] [key: 8] [valueType: 8] [value: ...]
            const void *key;
            memcpy(&key, (const char *)current + 8, sizeof(key));

            if (key != NULL && key == expected_key) {
                int64_t value;
                memcpy(&value, (const char *)current + 24, sizeof(value));
                return value;
            }
        } else if (kind == ITEM_KIND_PARENT_MARKER) {
            // ParentTaskMarker: follow next to parent's chain
            uintptr_t nextPtr = nextAndKind & ~(uintptr_t)0x3;
            current = (nextPtr != 0 && is_valid_pointer((void *)nextPtr))
                ? (const void *)nextPtr : NULL;
            continue;
        } else if (kind == ITEM_KIND_STOP_MARKER) {
            break;
        }

        // Follow next pointer
        uintptr_t nextPtr = nextAndKind & ~(uintptr_t)0x3;
        current = (nextPtr != 0 && is_valid_pointer((void *)nextPtr))
            ? (const void *)nextPtr : NULL;
    }

    return -1;
}

// MARK: - Session key capture

const void *schedule_capture_session_key(const void *task) {
    if (!task || !schedule_job_is_async_task(task)) return NULL;

    const void *head;
    memcpy(&head, (const char *)task + TASK_LOCAL_HEAD_OFFSET, sizeof(head));
    if (!head || !is_valid_pointer(head)) return NULL;

    // First item should be a ValueItem
    uintptr_t nextAndKind;
    memcpy(&nextAndKind, head, sizeof(nextAndKind));
    if ((nextAndKind & 0x3) != ITEM_KIND_VALUE) return NULL;

    const void *key;
    memcpy(&key, (const char *)head + 8, sizeof(key));
    return key;
}

// MARK: - Thread-local session marker

static pthread_key_t tls_session_key;
static bool tls_initialized = false;

void schedule_tls_init(void) {
    if (!tls_initialized) {
        pthread_key_create(&tls_session_key, NULL);
        tls_initialized = true;
    }
}

void schedule_tls_set_session(int64_t session_id) {
    // Encode session_id + 1 so that 0 means "no session" (pthread default)
    pthread_setspecific(tls_session_key, (void *)(uintptr_t)(session_id + 1));
}

int64_t schedule_tls_get_session(void) {
    uintptr_t val = (uintptr_t)pthread_getspecific(tls_session_key);
    return val == 0 ? -1 : (int64_t)(val - 1);
}

// MARK: - Actor → session registry

static struct {
    const void *actor;
    int64_t session_id;
} actor_registry[MAX_TRACKED_ACTORS];
static int actor_registry_count = 0;

void schedule_actor_registry_register(const void *actor, int64_t session_id) {
    for (int i = 0; i < actor_registry_count; i++) {
        if (actor_registry[i].actor == actor) {
            actor_registry[i].session_id = session_id;
            return;
        }
    }
    if (actor_registry_count < MAX_TRACKED_ACTORS) {
        actor_registry[actor_registry_count].actor = actor;
        actor_registry[actor_registry_count].session_id = session_id;
        actor_registry_count++;
    }
}

int64_t schedule_actor_registry_lookup(const void *actor) {
    for (int i = 0; i < actor_registry_count; i++) {
        if (actor_registry[i].actor == actor) {
            return actor_registry[i].session_id;
        }
    }
    return -1;
}

void schedule_actor_registry_clear(void) {
    actor_registry_count = 0;
}
