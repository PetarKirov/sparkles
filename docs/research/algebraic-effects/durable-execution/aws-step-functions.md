# AWS Step Functions (Amazon States Language)

The contrast case for this catalog: a managed orchestration service in which the workflow is not code at all but a JSON state machine that the service interprets, so there is nothing to replay, no determinism rule to obey, and a history that is an audit log rather than the program's memory.

| Field             | Value                                                                                                                                                                                                                                                                                                                             |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Amazon States Language (ASL), a JSON document; data plumbing in JSONPath or JSONata 2.0.6 ([`transforming-data`][jsonata]); task bodies are whatever the `Resource` URI names (Lambda, SDK calls, activities, HTTP)                                                                                                               |
| License           | Proprietary managed service; the ASL specification is published openly at [states-language.net][spec]                                                                                                                                                                                                                             |
| Repository        | None public. The closest artefact, Step Functions Local (`amazon/aws-stepfunctions-local`, `2.0.0`, build 2024-05-18), is marked unsupported ([`sfn-local`][sfn-local])                                                                                                                                                           |
| Documentation     | [Developer Guide][dg] · [API Reference][api-history-event] · [ASL specification][spec]                                                                                                                                                                                                                                            |
| Category          | contrast case                                                                                                                                                                                                                                                                                                                     |
| Persistence model | explicit state machine (the service checkpoints interpreter state per transition; no user code is re-executed)                                                                                                                                                                                                                    |
| Journal store     | The service-owned execution event history: a numbered `HistoryEvent` list per execution read through `GetExecutionHistory`, capped at 25,000 events, retained 90 days after close ([`service-quotas`][quotas]). Express workflows keep no history; they emit CloudWatch Logs instead ([`choosing-workflow-type`][std-vs-express]) |
| Latest release    | Continuously deployed service. Milestones cited here: versions and aliases (June 22, 2023, [announcement][versions-whatsnew]); redrive (November 15, 2023, [launch post][redrive-blog]); `TestState` mocking and Map/Parallel testing (November 2025, [`test-state-isolation`][teststate-dg])                                     |
| Local clone       | None (no source to clone; every citation below is an official AWS documentation URL or the ASL specification)                                                                                                                                                                                                                     |

**Last reviewed:** September 12, 2026.

---

## Overview

### What it solves

Every other subject in this catalog ([Temporal][temporal], [DBOS][dbos], [Restate][restate], [Azure Durable Functions][adf], [Effect Workflow][effect-workflow]) starts from the same premise: the workflow is a function in a general-purpose language, and durability is bolted on by journaling its effects and re-running it. Step Functions starts from the opposite premise. The ASL specification's first sentence is the whole design: "This document describes a JSON-based language used to describe state machines declaratively." ([ASL spec][spec]). The user submits a graph of named states; the service walks the graph, invokes each `Task` state's `Resource`, threads JSON from state to state, and records every transition. There is no user-supplied control flow to re-execute after a crash, because the control flow is a data structure the service already holds.

That one move dissolves three of this catalog's eight questions. Replay matching does not exist because there is no replay. Determinism is not enforced because there is no user code between journaled steps. "Replay or snapshot" is answered by neither: the interpreter checkpoints its own position and the current JSON payload after every transition, and the history is a separate audit log. What remains, and what this page examines, is what the model costs: every decision the workflow makes must be expressible in ASL's `Choice`, `Map`, `Parallel`, `Retry` and `Catch` vocabulary, every value must fit a 256 KiB JSON payload, and the "program" lives outside any language that can type-check, test or refactor it.

### Design philosophy

Two guarantees define the product, and the developer guide states them in one paragraph ([`choosing-workflow-type`][std-vs-express]):

> "Standard Workflows follow an _exactly-once_ model, where your tasks and states are never run more than once, unless you have specified `Retry` behavior in ASL. The exactly-once model makes Standard Workflows suited to orchestrating **non-idempotent** actions, such as starting an Amazon EMR cluster or processing payments."

and, for the cheaper tier:

> "Express Workflows use an _at-least-once_ model, so an execution could potentially run more than once. The at-least-once model makes Express Workflows better suited for orchestrating **idempotent** actions, such as transforming input data to store in Amazon DynamoDB using a PUT action."

The execution-guarantees table on the same page gives the mechanism behind the difference: for Standard, "Execution state internally persists between state transitions."; for both Express variants, "Execution state doesn't persist between state transitions." Standard is the durable product; Express is a fast interpreter with no checkpoint, and it is excluded from every durability feature discussed below (no history, no redrive, no `.waitForTaskToken`, no Distributed Map, no `GetExecutionHistory`).

The second philosophical commitment is that _the definition is the unit of versioning_, not the code that tasks run. "A _version_ is a numbered, **immutable** snapshot of a state machine." ([`concepts-state-machine-version`][versions]) and an execution is bound to one at start: "Step Functions associates an execution with a version or alias based on the Amazon Resource Name (ARN) that you use to invoke the StartExecution API action. Step Functions performs this action at the execution start time." ([`execution-alias-version-associate`][assoc]).

---

## How it works

### The definition is the program

An ASL document is a `States` map plus a `StartAt`. Eight state types exist: `Pass`, `Task`, `Choice`, `Wait`, `Succeed`, `Fail`, `Parallel`, `Map` ([ASL spec][spec]). Transitions are by name: "All non-terminal states MUST have a 'Next' field, except for the Choice State. The value of the 'Next' field MUST exactly and case-sensitively match the name of another state." A `Task` names its effect by URI: "A Task State MUST include a 'Resource' field, whose value MUST be a URI that uniquely identifies the specific task to execute." The following is the developer guide's callback example, which is also the shape of every "ask a human" step ([`connect-to-resource`][callback]):

```json
{
  "StartAt": "Push to SQS",
  "States": {
    "Push to SQS": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sqs:sendMessage.waitForTaskToken",
      "HeartbeatSeconds": 600,
      "Parameters": {
        "MessageBody": { "myTaskToken.$": "$$.Task.Token" },
        "QueueUrl": "https://sqs.us-east-1.amazonaws.com/123456789012/push-based-queue"
      },
      "ResultPath": "$.SQS",
      "End": true
    }
  }
}
```

Everything a code-first workflow would express with local variables, `if`, loops and exceptions has an ASL counterpart, and the counterpart is data:

| Code-first construct       | ASL construct                                                                                                                                                                                                                                 |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Local variable             | `Assign` field (any state except `Succeed`/`Fail`); workflow-local scope; 256 KiB per variable, 10 MiB per execution ([`workflow-variables`][variables])                                                                                      |
| Argument / return plumbing | JSONPath: `InputPath` → `Parameters` → `ResultSelector` → `ResultPath` → `OutputPath`; JSONata collapses these to `Arguments` and `Output` ([`transforming-data`][jsonata])                                                                   |
| `if`                       | `Choice` state with comparison rules (JSONPath) or a `Condition` JSONata expression                                                                                                                                                           |
| `try`/`catch`, retry loop  | `Retry` (array of retriers: `ErrorEquals`, `IntervalSeconds`, `MaxAttempts`, `BackoffRate`, `MaxDelaySeconds`, `JitterStrategy`) and `Catch` (array of catchers with `Next`) on `Task`/`Parallel`/`Map` ([`concepts-error-handling`][errors]) |
| Fork/join                  | `Parallel` with `Branches`; output is an array, one element per branch                                                                                                                                                                        |
| `for`/`map`                | `Map` with `ItemProcessor` (inline) or Distributed mode (child executions), `MaxConcurrency`, `ToleratedFailurePercentage`                                                                                                                    |
| `sleep`                    | `Wait` with `Seconds`, `Timestamp`, `SecondsPath` or `TimestampPath`                                                                                                                                                                          |
| Await an external event    | `Task` with `.waitForTaskToken`; the token comes from the context object `$$.Task.Token`                                                                                                                                                      |
| Subroutine                 | `Task` with `arn:aws:states:::states:startExecution.sync` (nested workflow)                                                                                                                                                                   |

The JSONPath pipeline is the tax the model levies for having no expressions. The guide's own pitch for JSONata is an admission of it: "After selecting JSONata, your workflow fields will be reduced from five JSONPath fields (`InputPath`, `Parameters`, `ResultSelector`, `ResultPath`, and `OutputPath`) to only two fields: `Arguments` and `Output`." ([`transforming-data`][jsonata]). JSONata brings its own runtime: a `States.QueryEvaluationError` on type errors, a one-second expression timeout, and non-deterministic built-ins (`$random()` with an optional seed, `$uuid()`), which is relevant to determinism below.

### The history is the journal

A Standard execution's history is a flat list of `HistoryEvent` objects: "The id of the event. Events are numbered sequentially, starting at one." plus a `previousEventId` ("The id of the previous event."), a `timestamp`, a `type`, and one details object matching the type ([`API_HistoryEvent`][api-history-event]). The allowed `type` values, verbatim:

```text
ActivityFailed | ActivityScheduled | ActivityScheduleFailed | ActivityStarted |
ActivitySucceeded | ActivityTimedOut | ChoiceStateEntered | ChoiceStateExited |
ExecutionAborted | ExecutionFailed | ExecutionStarted | ExecutionSucceeded |
ExecutionTimedOut | FailStateEntered | LambdaFunctionFailed | LambdaFunctionScheduled |
LambdaFunctionScheduleFailed | LambdaFunctionStarted | LambdaFunctionStartFailed |
LambdaFunctionSucceeded | LambdaFunctionTimedOut | MapIterationAborted |
MapIterationFailed | MapIterationStarted | MapIterationSucceeded | MapStateAborted |
MapStateEntered | MapStateExited | MapStateFailed | MapStateStarted | MapStateSucceeded |
ParallelStateAborted | ParallelStateEntered | ParallelStateExited | ParallelStateFailed |
ParallelStateStarted | ParallelStateSucceeded | PassStateEntered | PassStateExited |
SucceedStateEntered | SucceedStateExited | TaskFailed | TaskScheduled | TaskStarted |
TaskStartFailed | TaskStateAborted | TaskStateEntered | TaskStateExited |
TaskSubmitFailed | TaskSubmitted | TaskSucceeded | TaskTimedOut | WaitStateAborted |
WaitStateEntered | WaitStateExited | MapRunAborted | MapRunFailed | MapRunStarted |
MapRunSucceeded | ExecutionRedriven | MapRunRedriven | EvaluationFailed
```

Three groups matter for this survey. The `*StateEntered`/`*StateExited` pairs record the interpreter's position and the JSON at each boundary: `StateEnteredEventDetails` carries `name` and `input`; `StateExitedEventDetails` carries `name`, `output` and, since variables were added, `assignedVariables` ([`API_StateEnteredEventDetails`][api-state-entered], [`API_GetExecutionHistory`][api-get-history]). The `TaskScheduled`/`TaskStarted`/`TaskSucceeded`/`TaskFailed`/`TaskTimedOut` group records each effect: `TaskScheduledEventDetails.parameters` is "The JSON data passed to the resource referenced in a task state." and `TaskSucceededEventDetails.output` is "The full JSON response from a resource when a task has succeeded. This response becomes the output of the related task." ([`API_TaskScheduledEventDetails`][api-task-scheduled], [`API_TaskSucceededEventDetails`][api-task-succeeded]). And `ExecutionRedriven`/`MapRunRedriven` are appended, never inserted, when an operator resumes a failed run. A minimal history, from the API reference's own example ([`API_GetExecutionHistory`][api-get-history]):

```json
{
  "events": [
    {
      "id": 1,
      "previousEventId": 0,
      "type": "ExecutionStarted",
      "executionStartedEventDetails": {
        "input": "{}",
        "roleArn": "arn:aws:iam::123456789123:role/..."
      }
    },
    {
      "id": 2,
      "previousEventId": 0,
      "type": "PassStateEntered",
      "stateEnteredEventDetails": { "name": "HelloWorld", "input": "{}" }
    },
    {
      "id": 3,
      "previousEventId": 2,
      "type": "PassStateExited",
      "stateExitedEventDetails": {
        "name": "HelloWorld",
        "output": "\"Hello World!\""
      }
    },
    {
      "id": 4,
      "previousEventId": 3,
      "type": "ExecutionSucceeded",
      "executionSucceededEventDetails": { "output": "\"Hello World!\"" }
    }
  ]
}
```

Every payload in the history is capped: "256 KiB of data as a UTF-8 encoded string. This quota affects tasks (activity, Lambda function, or integrated service), state or execution output, and input data when scheduling a task, entering a state, or starting an execution." ([`service-quotas`][quotas]). The list itself is capped: "25,000 events in a single state machine execution history. If the execution history reaches this quota, the execution will fail." The best-practices page spells out the edge: "When an execution reaches 24,999 events, it waits for the next event to happen." and only an `ExecutionSucceeded` as event 25,000 ends well ([`sfn-best-practices`][best-practices]). The escape hatch is the same one Temporal calls continue-as-new: "For long-running executions, you can avoid reaching the hard quota by starting a new workflow execution from the `Task` state. You need to break your workflows up into smaller state machines which continue ongoing work in a new execution." ([`tutorial-continue-new`][continue-new]).

### Resume is redrive, not replay

Because the interpreter's position is checkpointed, a failed execution is resumed by moving the interpreter back to the failed state, not by re-running anything that succeeded ([`redrive-executions`][redrive]):

> "When you redrive an execution, Step Functions continues the failed execution from the unsuccessful step and uses the same input. Step Functions preserves the results and execution history of the successful steps, which are not rerun when you redrive an execution."

Redrive keeps identity: "Redriven executions use the same state machine definition and execution ARN that was used for the original execution attempt." It is bounded by the same history cap, since it appends: "The execution event history count is less than 24,999. Redriven executions append their event history to the existing event history." It is available for 14 days after the execution closed, for Standard only, and it resets both the state machine timeout and the `Retry` counters: "the retry attempt count for these states is reset to 0 to allow for the maximum number of attempts on redrive." The launch post positions it against `Retry` cleanly: "Use the retry mechanism for transient issues such as network connectivity problems or momentary service unavailability" versus "In scenarios where the underlying cause of an error requires longer investigation or resolution time, redrive becomes a valuable tool." ([launch post][redrive-blog]).

The per-state redrive table is the most precise statement anywhere in the docs of what "resume" means for each construct ([`redrive-executions`][redrive]):

| State             | Redrive behaviour (verbatim)                                                                                                                                                                   |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Task`            | "Schedules and starts the Task state again."                                                                                                                                                   |
| `Choice`          | "Reevaluates the Choice state rules."                                                                                                                                                          |
| `Wait`            | "If the state specifies `Timestamp` or `TimestampPath` that refers to a timestamp in the past, redrive causes the Wait state to be exited and enters the state specified in the `Next` field." |
| `Parallel`        | "Reschedules and redrives only those branches that failed or aborted."                                                                                                                         |
| Inline `Map`      | "Reschedules and redrives only those iterations that failed or aborted."                                                                                                                       |
| Distributed `Map` | "redrives the unsuccessful child workflow executions in a Map Run."                                                                                                                            |
| `Fail`            | "Reenters the Fail state and fails again."                                                                                                                                                     |

### External steps: task tokens and callbacks

The `.waitForTaskToken` integration is how a human gate or an out-of-band process becomes a state: "Callback tasks provide a way to pause a workflow until a task token is returned. A task might need to wait for a human approval, integrate with a third party, or call legacy systems." The task "will pause until it receives that task token back with a `SendTaskSuccess` or `SendTaskFailure` call." ([`connect-to-resource`][callback]). Two details matter for resume semantics. The token is regenerated on timeout: "If a `Task` state using the callback task token times out, a new random token is generated." And the wait is unbounded by default: "A task that is waiting for a task token will wait until the execution reaches the one year service quota", so the guide prescribes `HeartbeatSeconds`, after which "the task fails with a `States.Timeout` error name." The token is the idempotency key for the callback: a stale token from a timed-out attempt cannot complete the retried attempt.

### Versions, aliases and in-flight executions

Versions are immutable snapshots of definition plus IAM role, numbered monotonically (up to 1000 per state machine); "An _alias_ is a pointer for up to two versions of the same state machine." with weighted routing: "When you start an execution from an alias, Step Functions randomly chooses the state machine version to run from the versions specified in the routing configuration." ([`concepts-state-machine-alias`][aliases]). An execution started from an unqualified ARN is not pinned: "If you start a state machine execution without using a version, Step Functions uses the most recent revision of the state machine for the execution." ([`concepts-state-machine-version`][versions]). Even then, a redrive stays on the definition the run began with: "Even if you update your alias to point to a different version, the redriven execution continues to use the version associated with the original execution attempt. Because redriven executions use the same state machine definition, you must start a new execution if you update your state machine definition." ([`redrive-executions`][redrive]). Express, having no checkpoint, has no such pin: "State machine definitions for past executions are not stored for Express workflows." ([`concepts-view-execution-details`][exec-details]).

### Concurrency: `Parallel`, inline `Map`, Distributed `Map`

"A Parallel State causes the interpreter to execute each branch starting with the state named in its 'StartAt' field, as concurrently as possible, and wait until each branch terminates." ([ASL spec][spec]). Branch events land in the parent's single history, linked by `previousEventId`; `Map` iteration events carry `MapIterationEventDetails` with `index` ("The index of the array belonging to the Map state iteration.") and `name` ("The name of the iteration's parent Map state.") ([`API_MapIterationEventDetails`][api-map-iter]). Distributed mode moves each iteration out of the parent history entirely: "In Distributed mode, the `Map` state processes the items in the dataset in iterations called _child workflow executions_. … Each child workflow execution has its own, separate execution history from that of the parent workflow. If you don't specify, Step Functions runs 10,000 parallel child workflow executions in parallel." ([`state-map-distributed`][dist-map]). The guide lists "The workflow's execution event history would exceed 25,000 entries." as one of the three reasons to choose it, which makes Distributed Map a history-sharding device as much as a concurrency one.

---

## Analysis

### 1. Step identity and replay matching

Not applicable, and the absence is the finding. A step is a named state in the definition; the history records `stateEnteredEventDetails.name` and the interpreter resumes _at_ that name with the recorded input ([`redrive-executions`][redrive]). Nothing is matched against a journal because nothing is re-executed to produce a match: successful states are "not rerun", full stop. The only identity questions that exist are at the boundaries. At the execution boundary, the execution `name` is the idempotency key: "`StartExecution` is idempotent for `STANDARD` workflows. For a `STANDARD` workflow, if you call `StartExecution` with the same name and input as a running execution, the call succeeds and return the same response as the original request. If the execution is closed or if the input is different, it returns a `400 ExecutionAlreadyExists` error. You can reuse the name 90 days after it closes." ([`API_StartExecution`][api-start]). Note the "and input": the key is name plus input, which is the same name-plus-args-hash shape the `release` design proposes for individual steps, applied one level up. At the callback boundary, the task token is the key, regenerated per attempt ([`connect-to-resource`][callback]).

### 2. Journal versus world

The journal wins, unconditionally, and the world is never re-observed by the service. Redrive "uses the same input" recorded for the failed state; a `Choice` on redrive "Reevaluates the Choice state rules" against that recorded input, not against fresh data ([`redrive-executions`][redrive]). There is no reconciliation rule, no conflict detection, and no built-in way for a resumed run to notice that a downstream side effect from the failed attempt did happen. The exactly-once guarantee is at the transition level, and the guide's own qualifier, "unless you have specified `Retry` behavior", concedes that a `Retry` re-invokes a `Resource` whose first invocation may have half-completed ([`choosing-workflow-type`][std-vs-express]). The `Parallel` page is blunt about the world outliving the journal's view of it: "When a parallel state fails, invoked Lambda functions continue to run and activity workers processing a task token are not stopped." and "Running Lambda functions cannot be stopped. If you have implemented a fallback, use a `Wait` state so that cleanup work happens after the Lambda function has finished." ([`state-parallel`][parallel]). Reconciliation, where it exists, is the operator's: fix the world, then redrive.

### 3. Determinism enforcement

Not required, because there is no user code between journaled events: the interpreter is the only thing that runs between a `TaskSucceeded` and the next `TaskScheduled`, and it is the service's. This is the model's single largest benefit and the reason the question is moot. Two residues remain. First, ASL is not itself deterministic: `Wait` on a `Timestamp`, `Choice` rules over timestamps, JSONata's `$random()` and `$uuid()`, and `JitterStrategy: FULL` on retries all produce values that differ run to run ([`transforming-data`][jsonata], [`concepts-error-handling`][errors]). They do not need to be deterministic because nothing replays them; on redrive a `Choice` is simply re-decided. Second, determinism is pushed into the tasks: a `Resource` invoked twice by `Retry` must be idempotent, and the service offers no help beyond the token. Language enforcement: none (JSON). Runtime enforcement: none needed. Discipline: entirely on task authors.

### 4. Compensation and failure handling

Explicit only, expressed as graph edges. The default is total failure: "When a state reports an error, Step Functions defaults to failing the **entire** state machine execution." ([`concepts-error-handling`][errors]). `Retry` and `Catch` on `Task`/`Parallel`/`Map` are the only handlers, evaluated in array order with `States.ALL` required last, retriers before catchers: "When a state has both `Retry` and `Catch` fields, Step Functions uses any appropriate retriers first." A catcher is a jump: `ErrorEquals` plus `Next`, with the error output `{ "Error", "Cause" }` merged into the payload by `ResultPath` (default `$`, which "selects and overwrites the entire input"). Some errors are uncatchable by wildcard: "A `States.Runtime` error isn't retriable, and will always cause the execution to fail. A retry or catch on `States.ALL` won't catch `States.Runtime` errors." And catchers do not exist at the top: "Step Functions catchers are available for **Task**, **Parallel** and **Map** states, but not for top-level state machine execution failures."

There is no compensation primitive, no scope, no LIFO. The saga is a hand-drawn graph: AWS's prescriptive guidance describes it as "Each step (for example, 'ProcessPayment') also has separate steps to handle the success (for example, 'UpdateCustomerAccount') or failure (for example, 'Cancel Order') of the process." and warns that "The pattern requires a complex programming model that develops and designs compensating transactions for rolling back and undoing changes." ([Saga pattern][saga-aws]). Compensation order is whatever order the `Catch` chains encode; a compensating step is itself a `Task` that can fail, with its own `Retry`/`Catch`, and nothing tracks which forward steps have completed except the history the human reads. Compare [Sagas][sagas] and [compensation calculi][compensation] for what a first-class construct would provide.

### 5. Versioning against old histories

Solved by pinning, not by patching. An execution is bound to a version (or the revision current at start) at start time ([`execution-alias-version-associate`][assoc]), redrive stays on that definition even after the alias moves ([`redrive-executions`][redrive]), and a changed definition means a new execution. Because the history is not consumed by code, a new version never has to interpret an old history; the two-version alias exists for gradual rollout of new executions, not for migrating in-flight ones. The cost is the flip side: an in-flight run cannot pick up a fix. If a definition bug caused the failure, redrive will fail identically ("Reenters the Fail state and fails again."), and the operator must start over with the new version. Express workflows do not even keep the old definition ([`concepts-view-execution-details`][exec-details]).

### 6. Concurrency under replay

No replay, so no interleaving problem. `Parallel` branches and inline `Map` iterations run "as concurrently as possible" and write to one history, but each event is attributed to its branch or iteration (`previousEventId` chains; `MapIterationEventDetails.index`), and resume is per-branch: "Reschedules and redrives only those branches that failed or aborted." ([`redrive-executions`][redrive], [`API_MapIterationEventDetails`][api-map-iter]). Shared state is designed away: variables use "a _workflow-local scope_", and "`Parallel` branches and `Map` iterations can access variable values from **outer scopes**, but they do not have access to variable values from other concurrent branches or iterations." ([`workflow-variables`][variables]). Failure semantics are all-or-nothing per `Parallel`: "If any branch fails, because of an unhandled error or by transitioning to a `Fail` state, the entire `Parallel` state is considered to have failed and all its branches are stopped." ([`state-parallel`][parallel]), softened for `Map` by `ToleratedFailurePercentage`/`ToleratedFailureCount` ([`state-map-distributed`][dist-map]). Distributed `Map` shards history per child execution, which is how the model keeps a 10,000-way fan-out under the 25,000-event cap.

### 7. Replay or snapshot

Neither: the persistence model is the interpreter's own checkpoint. "Execution state internally persists between state transitions." ([`choosing-workflow-type`][std-vs-express]) is the whole mechanism; the execution's live state is its current position, the current JSON payload (256 KiB), and its variables (10 MiB), and the history is a write-once audit trail alongside it. The costs are exactly the caps: payloads that exceed 256 KiB must go to S3 by reference ([`sfn-best-practices`][best-practices]), and runs that exceed 25,000 events must be split ([`tutorial-continue-new`][continue-new]). What the model rules out is any workflow whose control flow cannot be drawn as ASL ahead of time. What it buys is a history that any tool can read without the code: `GetExecutionHistory` returns it in order with `includeExecutionData` defaulting to `true` ([`API_GetExecutionHistory`][api-get-history]), and the console renders it as a graph, a table with a per-state timeline, and a "Retries & redrives" tab per state ([`concepts-view-execution-details`][exec-details]).

### 8. Testing

Two tiers, and the durable one is the weaker. Unit testing is `TestState`: "Accepts the definition of a single state and executes it." with `inspectionLevel` `INFO`/`DEBUG`/`TRACE` exposing `afterInputPath`, `afterParameters`, `afterResultSelector`, `afterResultPath`, and a `status` of `SUCCEEDED | FAILED | RETRIABLE | CAUGHT_ERROR` plus `nextState` ([`API_TestState`][api-teststate]). Since November 2025 it takes a `mock` (`result` or `errorOutput`, validated against the service's API model with `fieldValidationMode`), a `context`, and a `stateConfiguration` with `retrierRetryCount`, `errorCausedByState` and `mapIterationFailureCount`, so a test can assert "which Retry applies (via `retryIndex` in the response)" and which catcher fired ([`test-state-isolation`][teststate-dg]). A whole-machine test is a chain of single-state tests by hand: "You can also chain tests by using the output and nextState from one test as input to the next." `Map` and `Parallel` are tested as black boxes: "you are testing the Map state's input and output processing without executing the iterations inside." Crash-and-resume is not testable at all below production: `TestState` runs one state for at most five minutes in the real service, and the local emulator is disowned: "Step Functions Local does **not** provide feature parity and is **unsupported**." ([`sfn-local`][sfn-local]). There is no equivalent of the crash-at-every-event-index sweep this catalog's design proposes, and no way to run an execution against a mutated world short of doing it in an account.

---

## Strengths

- **No determinism problem, by construction.** The only code between journaled events is the service's interpreter; task authors need idempotency, not determinism, and only under `Retry` ([`choosing-workflow-type`][std-vs-express]).
- **Resume is a cursor move.** Redrive resumes at the failed state with its recorded input and re-runs nothing that succeeded, per branch and per iteration ([`redrive-executions`][redrive]).
- **The history is a public, typed, ordered data structure** (`HistoryEvent` with 70-odd enumerated types, sequential ids, `previousEventId`), readable by any client and rendered by the console without the program ([`API_HistoryEvent`][api-history-event]).
- **Versioning is pinning.** Immutable versions, weighted aliases, execution-time association, and redrive that ignores alias moves ([`concepts-state-machine-version`][versions], [`execution-alias-version-associate`][assoc]).
- **Idempotent start** keyed by execution name plus input, for 90 days ([`API_StartExecution`][api-start]).
- **Human and external gates are first-class** (`.waitForTaskToken`, heartbeats, per-attempt tokens) ([`connect-to-resource`][callback]).
- **Fan-out that shards the journal** (Distributed `Map`, separate child histories, tolerated-failure thresholds) ([`state-map-distributed`][dist-map]).

## Weaknesses

- **Control flow lives outside any language.** Every branch, loop and handler is JSON; there is no type checker, no refactoring tool, no local unit-test runner, and a `Choice` cannot call a function. This is the reason every code-first subject in this catalog exists ([Temporal][temporal], [DBOS][dbos], [Restate][restate]).
- **Data plumbing is a second language.** Five JSONPath fields per state, or JSONata with its own error class and one-second timeout ([`transforming-data`][jsonata]).
- **Hard caps shape the program.** 256 KiB per payload, 10 MiB of variables, 25,000 events, one year; exceeding any of them is an execution failure, and the workaround is restructuring into nested executions ([`service-quotas`][quotas], [`sfn-best-practices`][best-practices]).
- **The world is never reconciled.** Redrive replays the recorded input; side effects of the failed attempt (still-running Lambdas, half-applied `Retry`s) are the operator's problem ([`state-parallel`][parallel]).
- **No compensation primitive.** Sagas are hand-drawn `Catch` graphs with no ordering, no scope and no record of what to undo ([Saga pattern][saga-aws]).
- **Cannot resume onto a fix.** In-flight executions are pinned to their definition; a definition bug means a new execution from the start ([`redrive-executions`][redrive]).
- **Express is not durable.** No checkpoint, no history, no redrive, no callbacks, no definition retention ([`choosing-workflow-type`][std-vs-express]).
- **Crash testing does not exist below production.** `TestState` is single-state and cloud-bound; the local emulator is unsupported ([`sfn-local`][sfn-local]).
- **Closed source, cloud-only, priced per transition** for the durable tier.

---

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                                         | Trade-off                                                                                       |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Workflow is a JSON state machine interpreted by the service   | No user code to replay, no determinism rules, history readable without the program ([ASL spec][spec])             | All control flow must be pre-drawn; two data-plumbing dialects; no language tooling             |
| Checkpoint interpreter state per transition (Standard)        | Exactly-once transitions; redrive from the failed state ([`choosing-workflow-type`][std-vs-express])              | Priced per transition; 256 KiB payload and 25,000-event caps; Express drops all of it for speed |
| History is an append-only audit log, not the program's memory | Redrive appends `ExecutionRedriven`; nothing is rewritten ([`redrive-executions`][redrive])                       | The cap counts redrives too; long runs must continue-as-new                                     |
| Recorded input wins on redrive; `Choice` re-decides           | Simple, predictable resume ([`redrive-executions`][redrive])                                                      | No world reconciliation; a decision can be re-made against stale data                           |
| Execution pinned to its definition version at start           | Old histories never meet new code ([`execution-alias-version-associate`][assoc])                                  | Cannot resume onto a fixed definition; must restart                                             |
| Idempotency by execution name + input, and by task token      | Duplicate starts and stale callbacks are rejected by the service ([`API_StartExecution`][api-start])              | Name reuse blocked for 90 days; tokens regenerate on timeout                                    |
| Error handling as `Retry`/`Catch` edges only                  | Everything visible in the graph; `TestState` can assert which edge fires ([`test-state-isolation`][teststate-dg]) | No compensation scope or ordering; `States.Runtime` and top-level failures uncatchable          |
| Distributed `Map` as child executions                         | 10,000-way fan-out without hitting the parent's event cap ([`state-map-distributed`][dist-map])                   | Outer-scope variables unavailable; results routed through S3 `ResultWriter`                     |
| Testing = one state at a time in the cloud                    | Real service semantics, mockable since 2025 ([`API_TestState`][api-teststate])                                    | No local emulator with parity; no crash/resume test at all                                      |

---

## Relevance to sparkles

This is option (b) from the `release` design in the [catalog umbrella][index]: an explicit event-sourced state machine instead of a replayed pure function over the capability row of [`event-horizon`][eh-spec].

- **What (b) would buy, concretely.** No determinism requirement on `release`'s code at all: the one property the replay design has to enforce by discipline and test (Analysis 3) disappears because the reducer, not user code, sits between journaled events. Redrive-from-state (Analysis 1): the four ad-hoc resume mechanisms in [`release`][release-spec] (`--stage` ladder, backlog shrink, `--plan`, publish manifest) collapse into "move the cursor to the failed state and re-run it with its recorded input", per branch for `--split`. A trivially inspectable history: `HistoryEvent` is proof that a typed, sequential, `previousEventId`-linked log needs no program to render; the `journal.jsonl`-as-UI-projection goal is easier under (b) than under replay, where the journal is only meaningful next to the code that wrote it.
- **What (b) would cost, concretely.** The release logic becomes a graph or a D reducer over an event stream: scan tags → summarize → suggest bump → notes → confirm → tag → publish, with `--split` as a `Map` with `MaxConcurrency: 1`. Every decision the current code makes inline (bump policy, conventional-commit parsing, editor seeding) becomes a `Task` whose result is data, and every conditional becomes a `Choice` over that data. Agent prompts and user gates become callback tasks (`.waitForTaskToken` with a heartbeat), which is fine for a CLI that already blocks on `$EDITOR`, but it means the gate's identity is a token, and a re-asked gate is a new token, not a replayed answer. The JSON-plumbing tax is real: Step Functions needed a second query language to make it bearable, and a D reducer would need typed event payloads to avoid the same.
- **Argues against "journal wins" as a complete answer.** Step Functions is the purest "journal wins" system in the catalog (Analysis 2), and its own docs concede the gap: still-running side effects after a `Parallel` failure, `Retry` re-invoking half-done resources, `Choice` re-decided on stale input. The design's re-observe-and-reconcile rule table for git tags and `HEAD` is something no explicit-state-machine service offers, and the release tool's world (git, GitHub) is edited by humans between crash and resume far more often than a Lambda's is. Keep the rule table under either option.
- **Confirms name-plus-args-hash as the key, one level up.** `StartExecution` idempotency is exactly name plus input, with a different input for the same name rejected loudly rather than silently reusing the old run ([`API_StartExecution`][api-start]). The proposed per-op key (`name + attempt + args hash`) is the same rule applied per step; the `ExecutionAlreadyExists` behaviour, fail on same-name-different-input, is the tripwire to copy.
- **Confirms pinning the journal to a code version, and shows the cost of pinning too hard.** Step Functions binds an execution to a definition version and refuses to redrive onto a new one (Analysis 5). The design should stamp `journal.jsonl` with a schema version, but unlike Step Functions it can afford a migration path, because the journal is a local file and the reader is the same binary: a resumed run on new code with a compatible journal is precisely the case `release` needs when the fix is in `release` itself.
- **Compensation: (b) does not get it for free either.** Step Functions has no compensation construct; sagas are `Catch` edges the author draws and orders by hand (Analysis 4). The design's explicit, LIFO, scope-registered compensations are strictly more structured than what the explicit-state-machine model provides, so choosing (b) would not remove the need to design them.
- **Testing is where replay wins outright.** The explicit-state-machine model, as shipped by its largest vendor, offers single-state tests in the cloud and no crash/resume harness (Analysis 8). The design's crash-at-every-event-index and mutate-the-world tests are cheap under replay because the journal is a file and the workflow is a function; under (b) they would need the reducer to be driven from a recorded event stream, which is possible in D but is exactly the harness Step Functions never built.
- **Adopt from Step Functions regardless of option:** per-state redrive semantics as a table (what `Task`, `Choice`, `Wait`, `Parallel` and `Map` each do on resume); the `ExecutionRedriven` event so resumes are visible in the history rather than implied; the "history cap plus continue-as-new" rule turned into a journal-size budget for `--split` runs; and heartbeat-bounded gates so an abandoned confirmation fails with a named error instead of hanging for a year.

---

## Sources

- [Amazon States Language specification][spec]
- [Choosing workflow type in Step Functions (Standard vs Express, execution guarantees)][std-vs-express]
- [`HistoryEvent` API reference (event types)][api-history-event] · [`GetExecutionHistory`][api-get-history] · [`StateEnteredEventDetails`][api-state-entered] · [`TaskScheduledEventDetails`][api-task-scheduled] · [`TaskSucceededEventDetails`][api-task-succeeded] · [`MapIterationEventDetails`][api-map-iter]
- [`StartExecution` API reference (idempotency by name)][api-start]
- [Restarting state machine executions with redrive][redrive] · [Introducing AWS Step Functions redrive (launch post, November 15, 2023)][redrive-blog]
- [Discover service integration patterns (`.sync`, `.waitForTaskToken`, task token, heartbeat)][callback]
- [Handling errors in Step Functions workflows (`Retry`, `Catch`, error names)][errors] · [Parallel workflow state][parallel]
- [State machine versions][versions] · [State machine aliases][aliases] · [How Step Functions associates executions with a version or alias][assoc] · [AWS Step Functions launches Versions and Aliases (June 22, 2023)][versions-whatsnew]
- [Step Functions service quotas][quotas] · [Best practices (history quota, timeouts, payload size)][best-practices] · [Continue long-running workflows using Step Functions API][continue-new]
- [Using Map state in Distributed mode][dist-map] · [Transforming data with JSONata][jsonata] · [Passing data between states with variables][variables]
- [Viewing execution details in the console][exec-details]
- [`TestState` API reference][api-teststate] · [Testing state machines with TestState API][teststate-dg] · [Testing state machines with Step Functions Local (unsupported)][sfn-local]
- [AWS Prescriptive Guidance: Saga pattern][saga-aws]
- Related in this catalog: [umbrella][index] · [Temporal][temporal] · [DBOS][dbos] · [Restate][restate] · [Azure Durable Functions][adf] · [Effect Workflow][effect-workflow] · [Sagas][sagas] · [Compensation calculi][compensation]
- Sparkles specs: [`event-horizon` SPEC][eh-spec] · [`release` SPEC][release-spec]

<!-- References -->

[spec]: https://states-language.net/spec.html
[dg]: https://docs.aws.amazon.com/step-functions/latest/dg/
[std-vs-express]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-standard-vs-express.html
[api-history-event]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_HistoryEvent.html
[api-get-history]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_GetExecutionHistory.html
[api-state-entered]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_StateEnteredEventDetails.html
[api-task-scheduled]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_TaskScheduledEventDetails.html
[api-task-succeeded]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_TaskSucceededEventDetails.html
[api-map-iter]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_MapIterationEventDetails.html
[api-start]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_StartExecution.html
[api-teststate]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_TestState.html
[redrive]: https://docs.aws.amazon.com/step-functions/latest/dg/redrive-executions.html
[redrive-blog]: https://aws.amazon.com/blogs/compute/introducing-aws-step-functions-redrive-a-new-way-to-restart-workflows/
[callback]: https://docs.aws.amazon.com/step-functions/latest/dg/connect-to-resource.html
[errors]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-error-handling.html
[parallel]: https://docs.aws.amazon.com/step-functions/latest/dg/state-parallel.html
[versions]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-state-machine-version.html
[aliases]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-state-machine-alias.html
[assoc]: https://docs.aws.amazon.com/step-functions/latest/dg/execution-alias-version-associate.html
[versions-whatsnew]: https://aws.amazon.com/about-aws/whats-new/2023/06/aws-step-functions-versions-aliases/
[quotas]: https://docs.aws.amazon.com/step-functions/latest/dg/service-quotas.html
[best-practices]: https://docs.aws.amazon.com/step-functions/latest/dg/sfn-best-practices.html
[continue-new]: https://docs.aws.amazon.com/step-functions/latest/dg/tutorial-continue-new.html
[dist-map]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-orchestrate-large-scale-parallel-workloads.html
[jsonata]: https://docs.aws.amazon.com/step-functions/latest/dg/transforming-data.html
[variables]: https://docs.aws.amazon.com/step-functions/latest/dg/workflow-variables.html
[exec-details]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-view-execution-details.html
[teststate-dg]: https://docs.aws.amazon.com/step-functions/latest/dg/test-state-isolation.html
[sfn-local]: https://docs.aws.amazon.com/step-functions/latest/dg/sfn-local.html
[saga-aws]: https://docs.aws.amazon.com/prescriptive-guidance/latest/modernization-data-persistence/saga-pattern.html
[index]: ./index.md
[temporal]: ./temporal.md
[dbos]: ./dbos.md
[restate]: ./restate.md
[adf]: ./azure-durable-functions.md
[effect-workflow]: ./effect-workflow.md
[sagas]: ./sagas.md
[compensation]: ./compensation-calculi.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[release-spec]: ../../../specs/release/SPEC.md
