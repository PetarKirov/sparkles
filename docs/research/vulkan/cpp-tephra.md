# C++: `Tephra`

## Mechanism: Job Graph API + Runtime Access Tracking

`Tephra` is a high-level Vulkan abstraction that sits above raw command recording and below full engine frameworks. Its core idea is to move synchronization and resource-state tracking into a runtime job system.

## Safety Model

### 1) Typed Command Surface

`Tephra` uses typed handles, enums, and access descriptors, so many argument-shape mistakes are prevented by C++ types.

### 2) Runtime Access Tracking

The main safety feature is an internal access-tracking engine:

1. Jobs declare resource usage (read/write intent and access kinds).
2. Tephra resolves hazards and inserts barriers/layout transitions.
3. Cross-queue dependencies are coordinated with timeline semaphores.

This is closer to a runtime render graph than to a purely compile-time typestate system.

### 3) Explicit Escape Hatches

Low-level command lists remain available. The design does not force complete resource virtualization and allows users to stay close to Vulkan semantics when needed.

## Internal vs External Synchronization

### Internal GPU Synchronization

Mostly automated for declared job commands. Tephra tracks subresource-level access and performs barrier planning without requiring users to hand-write every transition.

### External Host Synchronization

Not fully encoded in types. The API documents thread-safe and non-thread-safe zones, and callers are still responsible for correct host-side coordination in those zones.

## Lifetime Strategy

Tephra uses delayed destruction tied to queue progress:

1. Destroy requests are deferred.
2. Objects are reclaimed after relevant timeline semaphore values indicate GPU completion.

This greatly reduces accidental CPU-side destruction of in-flight resources.

## Strengths

1. Strong reduction in manual barrier/semaphore boilerplate.
2. Preserves low-level control when required.
3. Practical in-flight lifetime protection via deferred destruction.

## Limitations

1. Hazard correctness depends on runtime tracking, not static proof.
2. Some external synchronization constraints remain user-managed.
3. Requires discipline when mixing high-level and low-level paths.

## D Takeaways

1. A runtime sync planner can deliver major usability gains even without full typestate encoding.
2. Deferred destruction tied to completion values is a pragmatic lifetime safety primitive.
3. Keep low-level escape hatches, but make declared-access paths the default.
