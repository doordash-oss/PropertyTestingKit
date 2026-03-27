#ifndef SCHEDULE_HOOKS_H
#define SCHEDULE_HOOKS_H

#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Job introspection

/// Check if a Job pointer is an AsyncTask (JobKind == 0).
/// AsyncTasks have task-local storage; plain Jobs (like ProcessOutOfLineJob) do not.
bool schedule_job_is_async_task(const void *job);

/// Read a session ID from an AsyncTask's task-local storage chain.
/// Walks the linked list at offset 136 (verified on arm64) looking for a
/// ValueItem whose key matches `expected_key`.
/// Returns the session ID (>= 0) or -1 if not found.
int64_t schedule_read_session_from_task(const void *job, const void *expected_key);

/// Read the actor pointer from a ProcessOutOfLineJob (DefaultActorSeparate/Inline/Override).
/// Returns NULL if the job is not an actor processing job.
const void *schedule_read_actor_from_job(const void *job);

// MARK: - Session key capture

/// Capture the task-local key pointer from a task known to have a session value.
/// Call this with the result of swift_task_getCurrent() while inside a
/// SessionTag.$id.withValue scope.
const void *schedule_capture_session_key(const void *task);

// MARK: - Thread-local session marker

/// Set the thread-local session ID for the current thread.
/// Called from the hook when a tagged job is processed, so that
/// ProcessOutOfLineJob on the same thread can inherit the session.
void schedule_tls_set_session(int64_t session_id);

/// Get the thread-local session ID for the current thread.
/// Returns -1 if no session is set.
int64_t schedule_tls_get_session(void);

/// Initialize the pthread TLS key. Call once at startup.
void schedule_tls_init(void);

// MARK: - Actor → session registry

/// Register an actor pointer as belonging to a session.
void schedule_actor_registry_register(const void *actor, int64_t session_id);

/// Look up the session ID for an actor pointer.
/// Returns -1 if not found.
int64_t schedule_actor_registry_lookup(const void *actor);

/// Clear the actor registry. Call between runs.
void schedule_actor_registry_clear(void);

#ifdef __cplusplus
}
#endif

#endif // SCHEDULE_HOOKS_H
