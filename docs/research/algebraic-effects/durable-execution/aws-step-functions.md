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

Not applicable, and the absence is the finding. A step is a named state in the definition; the history records `stateEnteredEventDetails.name` and the interpreter resumes _at_ that name with the recorded input ([`redrive-executions`][redrive]). Nothing is matched against a journal because nothing is re-executed to produce a match: successful states are "not rerun", full stop. The only identity questions that exist are at the boundaries. At the execution boundary, the execution `name` is the idempotency key: "`StartExecution` is idempotent for `STANDARD` workflows. For a `STANDARD` workflow, if you call `StartExecution` with the same name and input as a running execution, the call succeeds and return the same response as the original request. If the execution is closed or if the input is different, it returns a `400 ExecutionAlreadyExists` error. You can reuse the name 90 days after it closes." ([`API_StartExecution`][api-start]). Note the "and input": the key is name plus input, the same shape as a per-step key of name plus argument hash, applied one level up. At the callback boundary, the task token is the key, regenerated per attempt ([`connect-to-resource`][callback]).

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

Two tiers, and the durable one is the weaker. Unit testing is `TestState`: "Accepts the definition of a single state and executes it." with `inspectionLevel` `INFO`/`DEBUG`/`TRACE` exposing `afterInputPath`, `afterParameters`, `afterResultSelector`, `afterResultPath`, and a `status` of `SUCCEEDED | FAILED | RETRIABLE | CAUGHT_ERROR` plus `nextState` ([`API_TestState`][api-teststate]). Since November 2025 it takes a `mock` (`result` or `errorOutput`, validated against the service's API model with `fieldValidationMode`), a `context`, and a `stateConfiguration` with `retrierRetryCount`, `errorCausedByState` and `mapIterationFailureCount`, so a test can assert "which Retry applies (via `retryIndex` in the response)" and which catcher fired ([`test-state-isolation`][teststate-dg]). A whole-machine test is a chain of single-state tests by hand: "You can also chain tests by using the output and nextState from one test as input to the next." `Map` and `Parallel` are tested as black boxes: "you are testing the Map state's input and output processing without executing the iterations inside." Crash-and-resume is not testable at all below production: `TestState` runs one state for at most five minutes in the real service, and the local emulator is disowned: "Step Functions Local does **not** provide feature parity and is **unsupported**." ([`sfn-local`][sfn-local]). There is no equivalent of a crash-at-every-event-index sweep, and no way to run an execution against a mutated world short of doing it in an account.

### 9. Journal integrity and the single writer

The history has exactly one writer, the service's interpreter, and no client ever appends to it: user code sees the journal only through `GetExecutionHistory`. Everything about how the append is made safe (conditional writes, checksums, torn-record handling, atomic multi-event commits) is therefore undocumented and unobservable, and that absence is the honest answer for a closed managed service. What is observable is the contract the writer keeps: events are "numbered sequentially, starting at one", each carries `previousEventId`, and the read side is explicitly weaker than the write side: "This operation is eventually consistent. The results are best effort and may not reflect very recent updates and changes." ([`API_HistoryEvent`][api-history-event], [`API_DescribeExecution`][api-describe]).

The single-writer guarantee that _is_ exposed sits one level up, at the execution. Two concurrent executions of the same durable program under the same name cannot both exist for Standard: a `StartExecution` with the same name and input returns the original execution, and a different input is refused with `ExecutionAlreadyExists` ([`API_StartExecution`][api-start]). The guide states the Express counterpart as the failure mode a library must avoid: "Idempotency is not automatically managed. Starting multiple workflows with the same name results in concurrent executions. Can result in loss of internal workflow state if state machine logic is not idempotent." ([`choosing-workflow-type`][std-vs-express]). The guard is a name, not a lease; it lasts 90 days after close and there is no way to take over a running execution.

Write-ahead discipline is visible in the event pairs. A `TaskScheduled` event, carrying the `parameters` "passed to the resource referenced in a task state", precedes `TaskStarted` and the eventual `TaskSucceeded`/`TaskFailed`/`TaskTimedOut` ([`API_TaskScheduledEventDetails`][api-task-scheduled]), and every state is bracketed by an `Entered`/`Exited` pair. Redrive relies on that structure to find unfinished work: "A parent workflow redrives unsuccessful states if there's no `<stateType>Exited` event corresponding to the `<stateType>Entered` event for a state when the parent workflow completed its execution." ([`redrive-map-run`][redrive-maprun]). The intent is durable before the effect, and "unfinished" is computed from the journal's shape, not from a status flag.

For results that arrive from outside, the write key is the task token, and a duplicate or stale append is refused rather than applied: `SendTaskSuccess` fails with `TaskTimedOut`, "The task token has either expired or the task associated with the token has already been closed.", or `InvalidToken` ([`API_SendTaskSuccess`][api-send-success]); on timeout "Step Functions invalidates the task token." ([`concepts-activities`][activities]). Writer identity is thin but present: an activity worker may pass a `workerName`, and "This name is used when it is logged in the execution history." ([`API_GetActivityTask`][api-get-activity]); redrive attempts are counted in `ExecutionRedrivenEventDetails.redriveCount` and `DescribeExecution.redriveCount` ([`API_GetExecutionHistory`][api-get-history], [`API_DescribeExecution`][api-describe]). Nothing on read checks who wrote an event; the service is trusted.

### 10. Operator recovery and intervention

The operator surface is broad for inspection and deliberately narrow for mutation. Resume is only ever from where the run stopped: redrive "continues the failed execution from the unsuccessful step and uses the same input" ([`redrive-executions`][redrive]); there is no fork-from-step, no rewind to an earlier event, and no editing or skipping of a recorded result. The one way a human can supply a step's result by hand is the task-token channel: `SendTaskSuccess` is "Used by activity workers, Task states using the callback pattern, and optionally Task states using the job run pattern to report that the task identified by the `taskToken` completed successfully." ([`API_SendTaskSuccess`][api-send-success]), so any principal in the account holding a live token can complete, fail, or heartbeat a waiting state with an arbitrary payload. That is an intervention lever, though the docs never frame it as one.

Cancellation is distinct from failure and leaves a reason. `StopExecution` takes an operator-supplied `error` and `cause` and is "not supported by `EXPRESS` state machines" ([`API_StopExecution`][api-stop]); the execution ends in `ABORTED`, one of `RUNNING | SUCCEEDED | FAILED | TIMED_OUT | ABORTED | PENDING_REDRIVE` ([`API_DescribeExecution`][api-describe]), and an `ExecutionAborted` event closes the history ([`API_HistoryEvent`][api-history-event]). Work in flight is not reliably stopped: for `.sync` tasks "Step Functions will make a best-effort attempt to cancel the task" ([`connect-to-resource`][callback]), Lambda invocations "cannot be stopped" ([`state-parallel`][parallel]), and "A Map Run can continue to run even after the parent workflow stops or times out." ([`redrive-map-run`][redrive-maprun]). Pause does not exist as a primitive; the closest is a `Wait` or a callback task placed in the definition ahead of time. The one live-tuning knob is `UpdateMapRun`, which "Updates an in-progress Map Run's configuration to include changes to the settings that control maximum concurrency and Map Run failure." ([`API_UpdateMapRun`][api-update-maprun]).

Inspection is the model's strength. `GetExecutionHistory` returns the ordered event list with payloads by default; `DescribeExecution` returns status, redrive count and date, and a `redriveStatus` of `REDRIVABLE | NOT_REDRIVABLE | REDRIVABLE_BY_MAP_RUN` with a `redriveStatusReason` such as "`Execution history event limit exceeded`" or "`Execution redrivable period exceeded`" ([`API_DescribeExecution`][api-describe]); the console renders graph, table with timeline, per-state "Retries & redrives", the full events table, and a JSON export ([`concepts-view-execution-details`][exec-details]). All of it is gone 90 days after close, and none of it exists for Express without CloudWatch Logs ([`service-quotas`][quotas]).

There is no dead-letter state for an execution; a run that cannot proceed is `FAILED` or `TIMED_OUT` and either redrivable or not. Distributed `Map` is the exception: `ResultWriter` "exports executions with the same status to their respective files in the specified Amazon S3 location", so failed items land in a queryable file ([`state-map-distributed`][dist-map]), and children waiting on the concurrency limit after a redrive sit in a "Pending redrive" state ([`redrive-map-run`][redrive-maprun]). Every intervention is traced: `ExecutionRedriven` and `MapRunRedriven` events are appended, `StopExecution`'s error and cause are recorded on the aborted execution, and redrives are countable per execution and per Map Run.

### 11. Suspension and external input

Waiting is a state type or a task pattern, never a blocked process, because there is no process. The primitives are `Wait` (`Seconds`, `Timestamp`, `SecondsPath`, `TimestampPath`; "the maximum wait time that you can specify for Standard Workflows and Express workflows is one year and five minutes respectively" ([`state-wait`][wait-state])), `.waitForTaskToken` callbacks, activities (a worker outside the service long-polls `GetActivityTask`, which "holds the HTTP connection open and responds as soon as a task becomes available" for at most 60 seconds ([`API_GetActivityTask`][api-get-activity])), `.sync` job-completion waits, and nested `startExecution.sync` for child completion ([`connect-to-resource`][callback]). While a Standard execution waits, its state "internally persists between state transitions" and it holds nothing; Standard is "Priced by number of state transitions", so a year-long wait costs no compute ([`choosing-workflow-type`][std-vs-express]). Express has no such checkpoint and its five-minute ceiling applies to waits too.

"Suspended" is not a first-class status. A waiting execution is `RUNNING`; the history shows a `TaskScheduled`/`TaskStarted` or `WaitStateEntered` with no closing event, and the console shows the state in progress ([`API_DescribeExecution`][api-describe], [`concepts-view-execution-details`][exec-details]). A caller can infer the wait from the history's shape but cannot query for it.

External input is addressed by a token, not a name. The token is minted when the task is scheduled, exposed to the definition as `$$.Task.Token`, and handed to whatever the task calls ([`connect-to-resource`][callback]). It is single-use and attempt-scoped: a second `SendTaskSuccess` after the task closed fails with `TaskTimedOut` ("the task associated with the token has already been closed") ([`API_SendTaskSuccess`][api-send-success]); an input cannot arrive early because the token does not exist until the task is scheduled; and "If a `Task` state using the callback task token times out, a new random token is generated." so a late reply to the old attempt is refused ([`connect-to-resource`][callback]). An input that never arrives is bounded only if the definition says so: by default "A task that is waiting for a task token will wait until the execution reaches the one year service quota", and `HeartbeatSeconds` or `TimeoutSeconds` turn silence into a `States.HeartbeatTimeout` or `States.Timeout` that `Retry`/`Catch` can handle ([`connect-to-resource`][callback], [`concepts-error-handling`][errors]). The timeout is journaled as its own event, `TaskTimedOut` or `ActivityTimedOut` ([`API_HistoryEvent`][api-history-event]); for activities, "the execution will fail and the execution history will contain an `ExecutionTimedOut` event. After the task times out, Step Functions invalidates the task token." ([`concepts-activities`][activities]).

Human-in-the-loop approval is the documented purpose of the callback pattern: "A task might need to wait for a human approval, integrate with a third party, or call legacy systems." ([`connect-to-resource`][callback]). It is modelled as a task whose `Resource` delivers the token somewhere a human can act on it (SQS, SNS, a Lambda that emails it) and whose completion is whichever `SendTaskSuccess`/`SendTaskFailure` returns the token. The approval's identity is the token; a re-asked approval after a timeout is a new token, so the model never has two live answers to the same question.

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

## Implications for a durable-execution library

- **Moving control flow into data removes the determinism problem outright**, and
  that is the model's single largest benefit. Nothing of the author's runs between
  one recorded event and the next, so there is no rule to obey, no sandbox to
  build, and no divergence to detect (§3). Any library that keeps control flow in
  a host language is choosing to take that problem on in exchange for writing
  programs in a real language.
- **The price is paid in expressiveness and tooling.** Branching, retry, error
  handling and iteration all become graph structure, and data plumbing becomes
  path expressions. What a replay system expresses as ordinary code, this model
  expresses as topology.
- **Per-state resume semantics deserve a table, and Step Functions publishes one.**
  `Task`, `Choice`, `Wait`, `Parallel` and `Map` each behave differently on
  redrive, and the documentation says how (§10). Any library with more than one
  kind of operation owes its users the same explicitness.
- **Intervention is recorded as an event.** A redrive appends `ExecutionRedriven`
  to the history, so a human's action is part of the record rather than invisible
  after the fact. Several systems in this survey intervene by deleting rows.
- **Idempotency belongs at the entry point too.** Starting an execution with a
  name already in use but a different input is refused rather than silently
  treated as a repeat, which is the strictest reading of "same key, same request"
  in the survey.
- **Pinning an execution to its definition version, and refusing to redrive onto a
  newer one, is the safest versioning stance available** — and it makes old
  definitions immortal. That trade is explicit here rather than accidental.
- **No compensation construct exists** in the field's largest managed offering;
  sagas are edges an author draws and orders by hand (§4). That absence is
  evidence the primitive is not table stakes, whatever its merits.
- **Testing is the model's weakest dimension** (§8): a single-state test API and
  no crash-and-resume harness. Removing the determinism problem does not remove
  the need to test recovery.

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
- Sparkles specs: [`event-horizon` SPEC][eh-spec]

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
[activities]: https://docs.aws.amazon.com/step-functions/latest/dg/concepts-activities.html
[api-describe]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_DescribeExecution.html
[api-get-activity]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_GetActivityTask.html
[api-send-success]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_SendTaskSuccess.html
[api-stop]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_StopExecution.html
[api-update-maprun]: https://docs.aws.amazon.com/step-functions/latest/apireference/API_UpdateMapRun.html
[redrive-maprun]: https://docs.aws.amazon.com/step-functions/latest/dg/redrive-map-run.html
[wait-state]: https://docs.aws.amazon.com/step-functions/latest/dg/state-wait.html
